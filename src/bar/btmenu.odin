// Bluetooth menu (left click on the bluetooth widget): a card with the power
// switch (rfkill unblock first when the radio is blocked), the paired devices
// with their type icon, connection and battery (click connects or
// disconnects), and "Search for devices", a timed scan listing the unpaired
// devices nearby; clicking one pairs, trusts and connects it, showing each
// step in its row. Everything goes through bluetoothctl jobs with timeouts.
package bar

import "core:mem/virtual"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:fmt"
import xlib "vendor:x11/xlib"
import tx "../tx"

@(private) BT_SCAN_SECONDS :: 10
@(private) BT_REFRESH      :: 5.0 // seconds between state refreshes while open
@(private) BT_SCAN_REFRESH :: 2.0 // while scanning

@(private)
Bt_Device :: struct {
	mac:       string,
	name:      string,
	icon:      Icon,
	paired:    bool,
	connected: bool,
	battery:   int, // -1 = unknown
}

@(private)
Bt_Op :: enum { Power, Connect, Disconnect, Pair, Trust, Pair_Connect }

Bt_Menu :: struct {
	card:        Card,
	anchor:      i32,
	hits:        [dynamic]Menu_Hit,
	hover:       Menu_Hit,
	arena:       virtual.Arena, // device strings, reset by every state reading
	has_arena:   bool,
	known:       bool, // a state reading arrived
	adapter:     bool,
	powered:     bool,
	devices:     [dynamic]Bt_Device, // paired first (arena)
	querying:    bool,
	scanning:    bool,
	acting:      bool,
	next_query:  f64,
	next_frame:  f64,
	busy:        string, // MAC of the device being worked on (owned)
	busy_op:     Bt_Op,
	error_mac:   string, // owned
	error_text:  string, // owned
}

// ---------------------------------------------------------------------------
// Open / close
// ---------------------------------------------------------------------------
@(private)
bt_toggle :: proc(b: ^Bar, w: ^Widget) {
	m := &b.btm
	if m.card.open {
		bt_close(b)
		return
	}
	close_popups(b)
	if !m.has_arena {
		_ = virtual.arena_init_growing(&m.arena)
		m.has_arena = true
	}
	anchor := widget_screen_rect(b, w)
	m.anchor = anchor.x + anchor.w / 2
	m.hover = {}
	set_owned(&m.error_mac, "")
	if b.tools.bluetoothctl { bt_query(b) }
	bt_draw(b)
	card_map(b, &m.card, true)
}

bt_close :: proc(b: ^Bar) {
	card_hide(b, &b.btm.card)
}

@(private)
bt_destroy :: proc(b: ^Bar) {
	m := &b.btm
	card_destroy(b, &m.card)
	delete(m.hits)
	delete(m.busy)
	delete(m.error_mac)
	delete(m.error_text)
	if m.has_arena { virtual.arena_destroy(&m.arena) }
	m^ = {}
}

@(private)
bt_busy :: proc(b: ^Bar) -> bool {
	m := &b.btm
	return m.card.open && (m.scanning || m.acting)
}

@(private)
bt_tick :: proc(b: ^Bar, now: f64) -> f64 {
	m := &b.btm
	if !m.card.open || !b.tools.bluetoothctl { return -1 }
	if now >= m.next_query { bt_query(b) }
	if bt_busy(b) && now >= m.next_frame {
		m.next_frame = now + 1.0 / 12
		bt_draw(b)
	}
	next := m.next_query
	if bt_busy(b) { next = min(next, m.next_frame) }
	return max(next - now, 0)
}

// ---------------------------------------------------------------------------
// bluetoothctl jobs
// ---------------------------------------------------------------------------
@(private)
BT_STATE_SCRIPT :: `echo @@show; bluetoothctl show 2>&1
P=$(bluetoothctl devices Paired 2>/dev/null)
echo @@paired; echo "$P"
echo "$P" | while read -r _ mac _; do [ -n "$mac" ] && { echo "@@info $mac"; bluetoothctl info "$mac" 2>/dev/null; }; done
echo @@all; bluetoothctl devices 2>/dev/null`

@(private)
bt_query :: proc(b: ^Bar) {
	m := &b.btm
	m.next_query = tx.now() + (m.scanning ? BT_SCAN_REFRESH : BT_REFRESH)
	if m.querying { return }
	m.querying = start_job(b, .Bt_State, {"sh", "-c", BT_STATE_SCRIPT}, true, 10) != nil
}

@(private)
bt_action :: proc(b: ^Bar, argv: []string, mac: string, op: Bt_Op, timeout: f64 = 20) {
	m := &b.btm
	if start_job(b, .Bt_Action, argv, true, timeout, merge_stderr = true, tag = mac, step = int(op)) == nil { return }
	m.acting = true
	m.busy_op = op
	set_owned(&m.busy, mac)
	if m.error_mac == mac { set_owned(&m.error_mac, "") }
}

// bluetoothctl does not always exit non-zero on failure: read its output too.
@(private)
bt_failed :: proc(job: ^Job) -> bool {
	out := string(job.output[:])
	return !job_succeeded(job) || strings.contains(out, "Failed") || strings.contains(out, "org.bluez.Error") ||
	       strings.contains(out, "not available")
}

@(private)
bt_job_done :: proc(b: ^Bar, job: ^Job) {
	m := &b.btm
	output := string(job.output[:])
	#partial switch job.kind {
	case .Bt_State:
		m.querying = false
		bt_parse_state(b, output)
	case .Bt_Scan:
		m.scanning = false
		bt_query(b)
	case .Bt_Action:
		m.acting = false
		set_owned(&m.busy, "")
		op := Bt_Op(job.step)
		if bt_failed(job) {
			fallback := tr(b, "A operação falhou", "The operation failed")
			if op == .Power {
				set_owned(&m.error_mac, "power")
			} else {
				set_owned(&m.error_mac, job.tag)
			}
			set_owned(&m.error_text, bt_error_text(b, output, fallback))
		} else {
			// Pairing continues: trust, then connect.
			#partial switch op {
			case .Pair:  bt_action(b, {"bluetoothctl", "trust", job.tag}, job.tag, .Trust, 10)
			case .Trust: bt_action(b, {"bluetoothctl", "connect", job.tag}, job.tag, .Pair_Connect, 20)
			}
		}
		bt_query(b)
	}
	if m.card.open { bt_draw(b) }
}

@(private)
bt_parse_state :: proc(b: ^Bar, output: string) {
	m := &b.btm
	virtual.arena_free_all(&m.arena)
	alloc := virtual.arena_allocator(&m.arena)
	m.known = true
	show := output_section(output, "show")
	m.adapter = strings.contains(show, "Controller ") && !strings.contains(show, "No default controller")
	m.powered = strings.contains(show, "Powered: yes")
	devices := make([dynamic]Bt_Device, alloc)
	// "Device <MAC> <name>" lines.
	parse :: proc(line: string) -> (mac, name: string, ok: bool) {
		l := strings.trim_space(line)
		if !strings.has_prefix(l, "Device ") { return }
		rest := l[len("Device "):]
		sp := strings.index_byte(rest, ' ')
		if sp < 0 { return rest, rest, len(rest) == 17 }
		return rest[:sp], strings.trim_space(rest[sp + 1:]), sp == 17
	}
	for line in strings.split_lines(output_section(output, "paired"), context.temp_allocator) {
		mac, name, ok := parse(line)
		if !ok { continue }
		d := Bt_Device{mac = strings.clone(mac, alloc), name = strings.clone(name, alloc), icon = .Bluetooth, paired = true, battery = -1}
		info := output_section(output, fmt.tprintf("info %s", mac))
		for il in strings.split_lines(info, context.temp_allocator) {
			t := strings.trim_space(il)
			switch {
			case strings.has_prefix(t, "Connected: "):
				d.connected = strings.has_suffix(t, "yes")
			case strings.has_prefix(t, "Icon: "):
				d.icon = bt_icon(t[len("Icon: "):])
			case strings.has_prefix(t, "Alias: "):
				d.name = strings.clone(t[len("Alias: "):], alloc)
			case strings.has_prefix(t, "Battery Percentage: "):
				// "Battery Percentage: 0x55 (85)"
				if open := strings.index_byte(t, '('); open >= 0 {
					if close := strings.index_byte(t[open:], ')'); close > 0 {
						if v, vok := strconv.parse_int(t[open + 1:open + close], 10); vok { d.battery = v }
					}
				}
			}
		}
		append(&devices, d)
	}
	// Connected devices first, then by name.
	slice.sort_by(devices[:], proc(a, c: Bt_Device) -> bool {
		if a.connected != c.connected { return a.connected }
		return a.name < c.name
	})
	paired_count := len(devices)
	for line in strings.split_lines(output_section(output, "all"), context.temp_allocator) {
		mac, name, ok := parse(line)
		if !ok { continue }
		known := false
		for d in devices[:paired_count] {
			if d.mac == mac { known = true; break }
		}
		// Nameless devices show their address with dashes: not worth listing.
		dashed, _ := strings.replace_all(mac, ":", "-", context.temp_allocator)
		if known || name == dashed || name == mac { continue }
		append(&devices, Bt_Device{mac = strings.clone(mac, alloc), name = strings.clone(name, alloc), icon = .Bluetooth, battery = -1})
	}
	m.devices = devices
}

// bluetoothctl's failure, in words people understand when it is a common one.
@(private)
bt_error_text :: proc(b: ^Bar, output, fallback: string) -> string {
	switch {
	case strings.contains(output, "page-timeout"), strings.contains(output, "Host is down"), strings.contains(output, "ConnectionAttemptFailed"):
		return tr(b, "Fora de alcance ou desligado", "Out of range or switched off")
	case strings.contains(output, "Authentication"):
		return tr(b, "Falha na autenticação", "Authentication failed")
	case strings.contains(output, "not available"):
		return tr(b, "Dispositivo não encontrado", "Device not found")
	case strings.contains(output, "InProgress"):
		return tr(b, "Operação já em andamento", "Already in progress")
	}
	msg := error_line(output, fallback)
	for prefix in ([]string{"Failed to connect: ", "Failed to pair: ", "Failed to disconnect: "}) { msg = strings.trim_prefix(msg, prefix) }
	return msg
}

// BlueZ "Icon" property → glyph.
@(private)
bt_icon :: proc(name: string) -> Icon {
	switch {
	case name == "audio-card":                  return .Speaker
	case strings.has_prefix(name, "audio"):     return .Headphones
	case name == "input-keyboard":              return .Keyboard
	case name == "input-mouse", name == "input-tablet": return .Mouse
	case name == "input-gaming":                return .Gamepad
	case name == "phone":                       return .Phone
	case name == "computer":                    return .Laptop
	case strings.contains(name, "watch"):       return .Watch
	}
	return .Bluetooth
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------
@(private)
bt_event :: proc(b: ^Bar, ev: ^xlib.XEvent) {
	m := &b.btm
	if !m.card.open { return }
	#partial switch ev.type {
	case .ButtonPress:
		x, y := card_local(&m.card, ev.xbutton.x_root, ev.xbutton.y_root)
		if !card_contains(&m.card, x, y) {
			bt_close(b)
			return
		}
		if i32(ev.xbutton.button) != 1 { return }
		if i := menu_hit_at(m.hits[:], x, y); i >= 0 { bt_activate(b, m.hits[i]) }
	case .MotionNotify:
		x, y := card_local(&m.card, ev.xmotion.x_root, ev.xmotion.y_root)
		hover: Menu_Hit
		if i := menu_hit_at(m.hits[:], x, y); i >= 0 { hover = m.hits[i] }
		if hover.action != m.hover.action || hover.index != m.hover.index {
			m.hover = hover
			bt_draw(b)
		}
	case .LeaveNotify:
		if m.hover.action != .None {
			m.hover = {}
			bt_draw(b)
		}
	case .KeyPress:
		if xlib.LookupKeysym(&ev.xkey, 0) == .XK_Escape { bt_close(b) }
	}
}

@(private)
bt_powered :: proc(b: ^Bar) -> bool { return b.btm.powered && !b.bt.blocked }

@(private)
bt_activate :: proc(b: ^Bar, hit: Menu_Hit) {
	m := &b.btm
	if m.acting && hit.action != .Bt_Scan { return }
	#partial switch hit.action {
	case .Bt_Power:
		if bt_powered(b) {
			bt_action(b, {"bluetoothctl", "power", "off"}, "", .Power, 10)
			m.powered = false
		} else if b.bt.blocked && b.tools.rfkill {
			bt_action(b, {"sh", "-c", "rfkill unblock bluetooth && sleep 1 && bluetoothctl power on"}, "", .Power, 12)
			m.powered = true
		} else {
			bt_action(b, {"bluetoothctl", "power", "on"}, "", .Power, 10)
			m.powered = true
		}
		if m.error_mac == "power" { set_owned(&m.error_mac, "") }
	case .Bt_Scan:
		if m.scanning { return }
		timeout := fmt.tprintf("%d", BT_SCAN_SECONDS)
		m.scanning = start_job(b, .Bt_Scan, {"bluetoothctl", "--timeout", timeout, "scan", "on"}, false, BT_SCAN_SECONDS + 5) != nil
		m.next_query = tx.now() + BT_SCAN_REFRESH
	case .Bt_Device:
		if hit.index >= len(m.devices) { return }
		d := m.devices[hit.index]
		if d.connected {
			bt_action(b, {"bluetoothctl", "disconnect", d.mac}, d.mac, .Disconnect)
		} else {
			bt_action(b, {"bluetoothctl", "connect", d.mac}, d.mac, .Connect)
		}
	case .Bt_New:
		if hit.index >= len(m.devices) { return }
		d := m.devices[hit.index]
		bt_action(b, {"bluetoothctl", "pair", d.mac}, d.mac, .Pair, 30)
	}
	if m.card.open { bt_draw(b) }
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------
@(private)
bt_draw :: proc(b: ^Bar) {
	m := &b.btm
	clear(&m.hits)
	W := i32(MENU_WIDTH)
	painter := painter_begin(b, W, menu_max_height(b), false)
	pa := &painter

	usable := b.tools.bluetoothctl && m.known && m.adapter
	sw := paint_menu_header(pa, "Bluetooth", usable, bt_powered(b))
	if usable { append(&m.hits, Menu_Hit{sw, .Bt_Power, 0}) }
	y := i32(MENU_HEADER) + 4
	switch {
	case !b.tools.bluetoothctl:
		paint_menu_message(pa, y, tr(b, "O bluetoothctl (BlueZ) não está instalado.", "bluetoothctl (BlueZ) is not installed."))
		y += MENU_MESSAGE
	case !m.known:
		paint_menu_message(pa, y, tr(b, "Carregando…", "Loading…"))
		y += MENU_MESSAGE
	case !m.adapter:
		paint_menu_message(pa, y, tr(b, "Nenhum adaptador Bluetooth encontrado.", "No Bluetooth adapter found."))
		y += MENU_MESSAGE
	case !bt_powered(b):
		msg := tr(b, "O Bluetooth está desligado.", "Bluetooth is off.")
		if m.error_mac == "power" && m.error_text != "" { msg = m.error_text }
		paint_menu_message(pa, y, msg)
		y += MENU_MESSAGE
	case:
		y = bt_paint_devices(b, pa, y)
	}
	y += 8
	painter_crop(pa, y)
	card_fit(b, &m.card, card_place(b, m.anchor, .Center, W, y), "milk bluetooth")
	painter_present(pa, &m.card)
}

@(private)
bt_paint_devices :: proc(b: ^Bar, pa: ^Card_Painter, y0: i32) -> i32 {
	m := &b.btm
	th := &b.theme
	W := pa.cv.w
	y := y0
	row :: proc(b: ^Bar, pa: ^Card_Painter, y: i32, d: Bt_Device, index: int, action: Menu_Action) {
		m := &b.btm
		th := &b.theme
		sub := ""
		color := th.muted
		busy := m.acting && m.busy == d.mac
		switch {
		case busy:
			switch m.busy_op {
			case .Pair:                  sub = tr(b, "Pareando…", "Pairing…")
			case .Trust:                 sub = tr(b, "Confiando…", "Trusting…")
			case .Connect, .Pair_Connect: sub = tr(b, "Conectando…", "Connecting…")
			case .Disconnect:            sub = tr(b, "Desconectando…", "Disconnecting…")
			case .Power:
			}
		case m.error_mac == d.mac && m.error_text != "":
			sub, color = m.error_text, th.warning
		case d.connected && d.battery >= 0:
			sub = fmt.tprintf("%s · %d%%", tr(b, "Conectado", "Connected"), d.battery)
		case d.connected:
			sub = tr(b, "Conectado", "Connected")
		case !d.paired:
			sub = tr(b, "Clique para parear", "Click to pair")
		}
		hovered := m.hover.action == action && m.hover.index == index
		paint_menu_row(pa, y, d.icon, d.connected ? th.accent : th.foreground, d.name, sub, color, hovered, busy ? 24 : 0)
		if busy { paint_spinner(pa, f32(pa.cv.w - MENU_PAD - 11), f32(y) + f32(MENU_ROW) / 2, 7, th.foreground) }
		append(&m.hits, Menu_Hit{{8, y, pa.cv.w - 16, MENU_ROW}, action, index})
	}

	paint_menu_section(pa, y, tr(b, "Dispositivos pareados", "Paired devices"))
	y += MENU_SECTION
	paired, others := 0, 0
	for d, i in m.devices {
		if !d.paired { continue }
		if paired >= MENU_MAX_ROWS { break }
		paired += 1
		row(b, pa, y, d, i, .Bt_Device)
		y += MENU_ROW
	}
	if paired == 0 {
		paint_menu_message(pa, y, tr(b, "Nenhum dispositivo pareado.", "No paired devices."))
		y += MENU_MESSAGE
	}
	for d in m.devices { if !d.paired { others += 1 } }
	if others > 0 {
		paint_divider(pa, MENU_PAD, y + 2, W - 2 * MENU_PAD)
		y += 4
		paint_menu_section(pa, y, tr(b, "Outros dispositivos", "Other devices"))
		y += MENU_SECTION
		shown := 0
		for d, i in m.devices {
			if d.paired { continue }
			if shown >= MENU_MAX_ROWS - 2 { break }
			shown += 1
			row(b, pa, y, d, i, .Bt_New)
			y += MENU_ROW
		}
	}
	// "Search for devices": a timed scan; a spinner while it runs.
	label := m.scanning ? (tr(b, "Procurando…", "Searching…")) : (tr(b, "Procurar dispositivos", "Search for devices"))
	r := tx.Rect{MENU_PAD, y + 8, W - 2 * MENU_PAD, 34}
	fill := th.surface
	if m.hover.action == .Bt_Scan && !m.scanning { fill = tx.color_mix(th.surface, th.muted, 0.35) }
	tx.canvas_fill_rounded_rect(&pa.cv, r, f32(r.h) / 2, fill)
	tw := tx.text_width(b.c, b.font, label)
	icon_w := i32(24)
	x := r.x + (r.w - tw - icon_w - 6) / 2
	if m.scanning {
		paint_spinner(pa, f32(x) + 12, f32(r.y) + f32(r.h) / 2, 6, th.foreground)
	} else {
		paint_icon(pa, .Refresh, {x, r.y, icon_w, r.h}, th.foreground)
	}
	paint_text(pa, b.font, x + icon_w + 6, r.y, r.h, label, th.foreground)
	append(&m.hits, Menu_Hit{r, .Bt_Scan, 0})
	return y + 8 + r.h
}
