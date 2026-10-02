// Audio devices in the volume card: below the slider, the outputs (sinks) and
// the inputs (sources that are not the monitor of an output) that pactl or
// wpctl list, the one in use marked; a click makes another one the default.
// With pactl the streams that are playing move along (PipeWire moves the
// streams that follow the default by itself). Outputs whose every port is
// unplugged (an HDMI connector with nothing on it) are left out. The list is
// read when the card opens and every AUDIO_REFRESH seconds while it is open.
package bar

import "core:mem/virtual"
import "core:strings"
import tx "../tx"

@(private) AUDIO_REFRESH :: 3.0

@(private)
Audio_Backend :: enum { None, Pactl, Wpctl }

@(private)
Audio_Device :: struct {
	id:      string, // pactl: the sink/source name; wpctl: the object id
	name:    string, // what people read (the description)
	icon:    Icon,
	current: bool,   // the default one
}

Audio_State :: struct {
	backend:    Audio_Backend,
	arena:      virtual.Arena, // device strings, reset by every reading
	has_arena:  bool,
	known:      bool,
	outputs:    [dynamic]Audio_Device, // arena
	inputs:     [dynamic]Audio_Device,
	querying:   bool,
	requery:    bool,
	switching:  bool,
	busy:       string, // owned: the device being made the default
	failed:     string, // owned: the one that could not be
	next_query: f64,
	gen:        int,    // changes when the lists or their state do (the card redraws)
}

@(private)
audio_backend :: proc(b: ^Bar) -> Audio_Backend {
	switch {
	case b.tools.pactl: return .Pactl
	case b.tools.wpctl: return .Wpctl
	}
	return .None
}

@(private)
audio_destroy :: proc(b: ^Bar) {
	a := &b.audio
	if a.has_arena { virtual.arena_destroy(&a.arena) }
	delete(a.busy)
	delete(a.failed)
	a^ = {}
}

// The volume card is open (and every AUDIO_REFRESH seconds while it is).
@(private)
audio_query :: proc(b: ^Bar) {
	a := &b.audio
	a.backend = audio_backend(b)
	if a.backend == .None { return }
	a.next_query = tx.now() + AUDIO_REFRESH
	if a.querying {
		a.requery = true
		return
	}
	argv: []string
	switch a.backend {
	case .Pactl: argv = {"sh", "-c", AUDIO_PACTL_SCRIPT}
	case .Wpctl: argv = {"wpctl", "status"}
	case .None:  return
	}
	a.querying = start_job(b, .Audio_Query, argv, true) != nil
}

@(private)
AUDIO_PACTL_SCRIPT :: `export LC_ALL=C
echo @@info; pactl info
echo @@sinks; pactl list sinks
echo @@sources; pactl list sources`

// Every loop iteration while the volume card is open: refresh, animate the spinner.
@(private)
audio_tick :: proc(b: ^Bar, now: f64) -> f64 {
	a := &b.audio
	if !b.slider.card.open || b.slider.kind != .Volume || a.backend == .None { return -1 }
	if now >= a.next_query { audio_query(b) }
	next := max(a.next_query - now, 0)
	if a.switching {
		a.gen += 1 // the spinner turns
		next = min(next, 1.0 / 12)
	}
	return next
}

@(private)
audio_job_done :: proc(b: ^Bar, job: ^Job) {
	a := &b.audio
	#partial switch job.kind {
	case .Audio_Query:
		a.querying = false
		if job_succeeded(job) {
			audio_parse(b, string(job.output[:]))
		} else if a.known {
			a.known = false
			a.gen += 1
		}
		if a.requery {
			a.requery = false
			audio_query(b)
		}
	case .Audio_Set:
		a.switching = false
		if !job_succeeded(job) { set_owned(&a.failed, a.busy) }
		set_owned(&a.busy, "")
		a.gen += 1
		audio_query(b)
		request_volume_refresh(b) // the new output's volume
	}
}

// Make output (or input) `index` the default.
@(private)
audio_choose :: proc(b: ^Bar, output: bool, index: int) {
	a := &b.audio
	list := output ? a.outputs[:] : a.inputs[:]
	if a.switching || index < 0 || index >= len(list) || list[index].current { return }
	id := list[index].id
	argv: []string
	switch a.backend {
	case .Pactl:
		if output {
			// The streams playing now go along to the new output.
			argv = {"sh", "-c", `pactl set-default-sink "$1" && pactl list short sink-inputs | while read -r id _; do pactl move-sink-input "$id" "$1"; done`, "sh", id}
		} else {
			argv = {"pactl", "set-default-source", id}
		}
	case .Wpctl:
		argv = {"wpctl", "set-default", id}
	case .None:
		return
	}
	if start_job(b, .Audio_Set, argv, true, 10) == nil { return }
	a.switching = true
	set_owned(&a.busy, id)
	if a.failed == id { set_owned(&a.failed, "") }
	a.gen += 1
}

// ---------------------------------------------------------------------------
// Reading the lists
// ---------------------------------------------------------------------------
@(private)
audio_parse :: proc(b: ^Bar, output: string) {
	a := &b.audio
	if !a.has_arena {
		_ = virtual.arena_init_growing(&a.arena)
		a.has_arena = true
	}
	virtual.arena_free_all(&a.arena)
	alloc := virtual.arena_allocator(&a.arena)
	a.outputs = make([dynamic]Audio_Device, alloc)
	a.inputs = make([dynamic]Audio_Device, alloc)
	switch a.backend {
	case .Pactl: parse_pactl(a, output, alloc)
	case .Wpctl: parse_wpctl(a, output, alloc)
	case .None:
	}
	a.known = true
	a.gen += 1
}

@(private)
parse_pactl :: proc(a: ^Audio_State, output: string, alloc := context.allocator) {
	default_sink, default_source := "", ""
	for line in strings.split_lines(output_section(output, "info"), context.temp_allocator) {
		t := strings.trim_space(line)
		if strings.has_prefix(t, "Default Sink: ") { default_sink = t[len("Default Sink: "):] }
		if strings.has_prefix(t, "Default Source: ") { default_source = t[len("Default Source: "):] }
	}
	Block :: struct { name, desc: string, monitor: bool, ports, unplugged: int }
	blocks :: proc(section, header: string) -> []Block {
		out := make([dynamic]Block, context.temp_allocator)
		in_ports := false
		for line in strings.split_lines(section, context.temp_allocator) {
			if strings.has_prefix(line, header) {
				append(&out, Block{})
				in_ports = false
				continue
			}
			if len(out) == 0 { continue }
			cur := &out[len(out) - 1]
			t := strings.trim_space(line)
			// Ports are listed one per line, two tabs deep, after "Ports:".
			if in_ports && strings.has_prefix(line, "\t\t") {
				cur.ports += 1
				if strings.contains(t, "not available)") { cur.unplugged += 1 }
				continue
			}
			in_ports = false
			switch {
			case strings.has_prefix(t, "Name: "):        cur.name = t[len("Name: "):]
			case strings.has_prefix(t, "Description: "): cur.desc = t[len("Description: "):]
			case strings.has_prefix(t, "Monitor of Sink: "): cur.monitor = t != "Monitor of Sink: n/a"
			case t == "Ports:":                           in_ports = true
			}
		}
		return out[:]
	}
	for blk in blocks(output_section(output, "sinks"), "Sink #") {
		if blk.name == "" { continue }
		current := blk.name == default_sink
		if blk.ports > 0 && blk.unplugged == blk.ports && !current { continue } // nothing plugged in
		desc := blk.desc != "" ? blk.desc : blk.name
		append(&a.outputs, Audio_Device{strings.clone(blk.name, alloc), strings.clone(desc, alloc), output_icon(blk.name, desc), current})
	}
	for blk in blocks(output_section(output, "sources"), "Source #") {
		if blk.name == "" || blk.monitor || strings.has_suffix(blk.name, ".monitor") { continue }
		current := blk.name == default_source
		if blk.ports > 0 && blk.unplugged == blk.ports && !current { continue }
		desc := blk.desc != "" ? blk.desc : blk.name
		append(&a.inputs, Audio_Device{strings.clone(blk.name, alloc), strings.clone(desc, alloc), .Microphone, current})
	}
}

// `wpctl status`: under "Audio", the "Sinks:" and "Sources:" lists drawn
// with box characters, "*" before the default one:
//   │  *   50. Ryzen HD Audio Controller Analog Stereo [vol: 0.60]
@(private)
parse_wpctl :: proc(a: ^Audio_State, output: string, alloc := context.allocator) {
	in_audio := false
	list: ^[dynamic]Audio_Device
	for line in strings.split_lines(output, context.temp_allocator) {
		if len(line) > 0 && line[0] != ' ' {
			in_audio = strings.trim_space(line) == "Audio"
			list = nil
			continue
		}
		if !in_audio { continue }
		t := strings.trim_left(line, " │├└─")
		t = strings.trim_space(t)
		switch {
		case t == "Sinks:":   list = &a.outputs; continue
		case t == "Sources:": list = &a.inputs; continue
		case strings.has_suffix(t, ":"): list = nil; continue
		case t == "":         list = nil; continue
		}
		if list == nil { continue }
		current := strings.has_prefix(t, "*")
		t = strings.trim_space(strings.trim_prefix(t, "*"))
		dot := strings.index_byte(t, '.')
		if dot <= 0 { continue }
		id := t[:dot]
		name := strings.trim_space(t[dot + 1:])
		if vol := strings.last_index(name, " [vol:"); vol >= 0 { name = strings.trim_space(name[:vol]) }
		icon := list == &a.inputs ? Icon.Microphone : output_icon("", name)
		append(list, Audio_Device{strings.clone(id, alloc), strings.clone(name, alloc), icon, current})
	}
}

@(private)
output_icon :: proc(id, name: string) -> Icon {
	l := strings.to_lower(strings.concatenate({id, " ", name}, context.temp_allocator), context.temp_allocator)
	switch {
	case strings.contains(l, "hdmi"), strings.contains(l, "displayport"), strings.contains(l, " dp"): return .Device_Tv
	case strings.contains(l, "headphone"), strings.contains(l, "headset"), strings.contains(l, "bluez"),
	     strings.contains(l, "fone"), strings.contains(l, "auricular"): return .Headphones
	}
	return .Speaker
}

// ---------------------------------------------------------------------------
// The section of the volume card
// ---------------------------------------------------------------------------

// Height the device lists take in the card (0 = none to show).
@(private)
audio_height :: proc(b: ^Bar) -> i32 {
	a := &b.audio
	if !a.known || a.backend == .None { return 0 }
	h: i32
	if len(a.outputs) > 0 { h += MENU_SECTION + i32(min(len(a.outputs), MENU_MAX_ROWS)) * MENU_ROW }
	if len(a.inputs) > 0 { h += MENU_SECTION + i32(min(len(a.inputs), MENU_MAX_ROWS)) * MENU_ROW }
	if h == 0 { return 0 }
	return h + 10 // the divider above, a little room below
}

// Paint the lists from `y0` and record their rows in `hits`.
@(private)
audio_paint :: proc(b: ^Bar, pa: ^Card_Painter, y0: i32, hits: ^[dynamic]Menu_Hit, hover: Menu_Hit) {
	a := &b.audio
	th := &b.theme
	W := pa.cv.w
	paint_divider(pa, MENU_PAD, y0 + 2, W - 2 * MENU_PAD)
	y := y0 + 6
	lists := [2]struct { title: string, devices: []Audio_Device, action: Menu_Action }{
		{tr(b, "Saída", "Output"), a.outputs[:], .Audio_Output},
		{tr(b, "Entrada", "Input"), a.inputs[:], .Audio_Input},
	}
	for l in lists {
		if len(l.devices) == 0 { continue }
		paint_menu_section(pa, y, l.title)
		y += MENU_SECTION
		for d, i in l.devices {
			if i >= MENU_MAX_ROWS { break }
			busy := a.switching && a.busy == d.id
			sub, sub_color := "", th.muted
			if a.failed == d.id { sub, sub_color = tr(b, "Não foi possível trocar", "Could not switch"), th.warning }
			hovered := hover.action == l.action && hover.index == i && !d.current
			paint_menu_row(pa, y, d.icon, d.current ? th.accent : th.foreground, d.name, sub, sub_color, hovered, 30)
			mid := f32(y) + f32(MENU_ROW) / 2
			switch {
			case busy:      paint_spinner(pa, f32(W - MENU_PAD - 11), mid, 7, th.foreground)
			case d.current: paint_icon(pa, .Check, {W - MENU_PAD - 24, y, 24, MENU_ROW}, th.accent)
			}
			append(hits, Menu_Hit{{8, y, W - 16, MENU_ROW}, l.action, i})
			y += MENU_ROW
		}
	}
}
