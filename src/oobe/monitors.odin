// Settings → Tela → Monitores and Escala (package display does the XRandR
// work): the monitors as they are arranged (drag them), the selected one's
// on/off, resolution, refresh rate, rotation and primary. Aplicar shows the
// layout at once and asks whether to keep it: without an answer within
// CONFIRM_SECONDS, or when the window closes, the previous layout comes back.
// Manter saves it as the profile of this set of monitors (displays.profiles),
// which milk applies whenever they are connected again. The Escala tab holds
// the apps' scale (displays.scale), displays.autoApply and the saved profiles.
package oobe

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import xlib "vendor:x11/xlib"
import config "../config"
import display "../display"
import tx "../tx"

@(private) CONFIRM_SECONDS :: 15
@(private) MON_SETTLE      :: 0.3 // RandR events: read the monitors again after this quiet time
@(private) MON_BAND        :: 52  // the arrangement's bottom band: primary, monitors that are off, buttons
@(private) MON_SNAP        :: 14  // window pixels: a dragged monitor sticks to the edges of the others
@(private) SCALES          :: [5]f64{1, 1.25, 1.5, 1.75, 2}

@(private)
Monitors_State :: struct {
	ok:         bool,  // RandR 1.2: the monitors can be changed
	event_base: i32,
	state:      ^display.State,
	key:        string, // heap: the set of monitors connected
	layout:     [dynamic]config.Display_Output, // being edited, one per connected monitor (heap strings)
	applied:    [dynamic]config.Display_Output, // what the screen shows
	previous:   [dynamic]config.Display_Output, // before the last Aplicar (Voltar)
	confirm_until: f64, // > 0: asking whether to keep the layout
	selected:   int,
	picking:    bool,   // the resolution list is open
	scroll:     i32,
	refresh_at: f64,    // 0 = nothing pending
	error:      string, // heap: why the last Aplicar failed ("" = none)
	// The arrangement as last drawn: window = origin + (layout - base) * scale.
	view_scale: f64,
	view_origin: [2]f64,
	view_base:  [2]i32,
	dragging:   int,    // -1, or the monitor being dragged (the view is frozen meanwhile)
	grab:       [2]f64, // the pointer inside the dragged monitor, in layout pixels
	// Escala.
	scale:      f64,
	auto_apply: bool,
	profiles:   map[string][]config.Display_Output, // heap copy of displays.profiles
	profiles_dirty: bool,
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
@(private)
monitors_load :: proc(w: ^Wizard) {
	m := &w.set.mon
	m.dragging = -1
	m.scale = w.cfg.displays.scale
	m.auto_apply = w.cfg.displays.auto_apply
	m.profiles = make(map[string][]config.Display_Output)
	for key, entries in w.cfg.displays.profiles { m.profiles[strings.clone(key)] = display.clone_layout(entries) }
	m.event_base, m.ok = display.watch(w.c)
	if m.ok { monitors_read(w, false) }
}

@(private)
monitors_destroy :: proc(w: ^Wizard) {
	m := &w.set.mon
	display.destroy_state(m.state)
	delete(m.key)
	delete(m.error)
	layout_free(&m.layout)
	layout_free(&m.applied)
	layout_free(&m.previous)
	delete(m.layout)
	delete(m.applied)
	delete(m.previous)
	for key, entries in m.profiles {
		delete(key)
		config.destroy_display_outputs(entries)
	}
	delete(m.profiles)
	m^ = {}
}

// Read the monitors again. keep_edits: the layout being edited stays when
// the same monitors are connected (only what the screen shows is updated).
@(private)
monitors_read :: proc(w: ^Wizard, keep_edits: bool) {
	m := &w.set.mon
	s := display.read_state(w.c)
	if s == nil {
		m.ok = false
		return
	}
	display.destroy_state(m.state)
	m.state = s
	key := display.setup_key(s, context.temp_allocator)
	current := display.layout_from_state(s, context.temp_allocator)
	same_set := key == m.key
	if !same_set {
		delete(m.key)
		m.key = strings.clone(key)
		layout_free(&m.previous)
		m.confirm_until = 0
		m.picking = false
	}
	layout_set(&m.applied, current)
	if !keep_edits || !same_set { layout_set(&m.layout, current) }
	m.selected = clamp(m.selected, 0, max(len(m.layout) - 1, 0))
	if len(m.layout) > 0 && !keep_edits {
		// The primary monitor is selected first.
		for e, i in m.layout { if e.primary { m.selected = i } }
	}
	w.dirty = true
}

@(private="file")
layout_free :: proc(l: ^[dynamic]config.Display_Output) {
	for e in l {
		delete(e.monitor)
		delete(e.output)
		delete(e.rotation)
	}
	clear(l)
}

@(private="file")
layout_set :: proc(dst: ^[dynamic]config.Display_Output, src: []config.Display_Output) {
	copied := display.clone_layout(src, context.temp_allocator) // src may be dst
	layout_free(dst)
	for e in copied {
		append(dst, config.Display_Output{
			monitor = strings.clone(e.monitor), output = strings.clone(e.output), enabled = e.enabled,
			w = e.w, h = e.h, rate = e.rate, x = e.x, y = e.y, rotation = strings.clone(e.rotation), primary = e.primary,
		})
	}
}

@(private="file")
layouts_equal :: proc(a, b: []config.Display_Output) -> bool {
	if len(a) != len(b) { return false }
	for e, i in a {
		f := b[i]
		if e.monitor != f.monitor || e.enabled != f.enabled || e.primary != f.primary { return false }
		if !e.enabled { continue }
		if e.w != f.w || e.h != f.h || e.x != f.x || e.y != f.y || e.rotation != f.rotation || abs(e.rate - f.rate) > 0.05 { return false }
	}
	return true
}

// The layout differs from the screen (Aplicar and Desfazer are offered).
@(private="file")
monitors_dirty :: proc(m: ^Monitors_State) -> bool {
	return !layouts_equal(m.layout[:], m.applied[:])
}

@(private="file")
selected_output :: proc(m: ^Monitors_State) -> (^config.Display_Output, ^display.Output) {
	if m.state == nil || m.selected < 0 || m.selected >= len(m.layout) { return nil, nil }
	e := &m.layout[m.selected]
	return e, display.find_output(m.state, e^)
}

// The name shown for a monitor: the built-in panel, else its model.
@(private="file")
monitor_name :: proc(w: ^Wizard, o: ^display.Output) -> string {
	if o == nil { return "?" }
	if o.internal { return tr(w, "Tela integrada", "Built-in display") }
	return o.label
}

// Monitor events (from the settings window's connection).
@(private)
monitors_event :: proc(w: ^Wizard, ev: ^xlib.XEvent) -> bool {
	m := &w.set.mon
	if !m.ok || !display.is_event(m.event_base, ev) { return false }
	m.refresh_at = tx.now() + MON_SETTLE
	return true
}

@(private)
monitors_tick :: proc(w: ^Wizard, now: f64) {
	m := &w.set.mon
	if m.refresh_at > 0 && now >= m.refresh_at {
		m.refresh_at = 0
		if m.dragging < 0 { monitors_read(w, m.confirm_until > 0 || monitors_dirty(m)) }
	}
	if m.confirm_until > 0 {
		if now >= m.confirm_until {
			monitors_revert(w)
		} else {
			w.dirty = true // the countdown
		}
	}
}

@(private)
monitors_timeout :: proc(w: ^Wizard, now: f64) -> f64 {
	m := &w.set.mon
	t := -1.0
	if m.refresh_at > 0 { t = max(m.refresh_at - now, 0) }
	if m.confirm_until > 0 {
		// Once a second for the countdown.
		left := m.confirm_until - now
		next := max(left - math.floor(left), 0.02)
		if t < 0 || next < t { t = next }
	}
	return t
}

// The window is closing: a layout nobody kept goes back.
@(private)
monitors_finish :: proc(w: ^Wizard) {
	if w.set.mon.confirm_until > 0 { monitors_revert(w) }
}

// ---------------------------------------------------------------------------
// Applying
// ---------------------------------------------------------------------------
@(private="file")
monitors_apply :: proc(w: ^Wizard) {
	m := &w.set.mon
	delete(m.error)
	m.error = ""
	s := display.read_state(w.c)
	if s == nil { return }
	defer display.destroy_state(s)
	layout := display.clone_layout(m.layout[:], context.temp_allocator)
	display.ensure_primary(s, layout)
	before := display.layout_from_state(s, context.temp_allocator)
	ok, why := display.apply(w.c, s, layout)
	if !ok {
		m.error = strings.clone(why)
		w.dirty = true
		return
	}
	layout_set(&m.previous, before)
	m.confirm_until = tx.now() + CONFIRM_SECONDS
	monitors_read(w, false)
}

@(private="file")
monitors_revert :: proc(w: ^Wizard) {
	m := &w.set.mon
	m.confirm_until = 0
	if len(m.previous) == 0 { return }
	s := display.read_state(w.c)
	if s == nil { return }
	defer display.destroy_state(s)
	if ok, why := display.apply(w.c, s, m.previous[:]); !ok {
		delete(m.error)
		m.error = strings.clone(why)
	}
	layout_free(&m.previous)
	monitors_read(w, false)
}

@(private="file")
monitors_keep :: proc(w: ^Wizard) {
	m := &w.set.mon
	m.confirm_until = 0
	layout_free(&m.previous)
	if m.key == "" || len(m.applied) == 0 { return }
	if old, found := m.profiles[m.key]; found {
		config.destroy_display_outputs(old)
		m.profiles[m.key] = display.clone_layout(m.applied[:])
	} else {
		m.profiles[strings.clone(m.key)] = display.clone_layout(m.applied[:])
	}
	m.profiles_dirty = true
	settings_changed(w, .Values)
	show_notice(w, tr(w, "Salvo para estes monitores", "Saved for these monitors"))
}

// displays.profiles as milk.json holds it (written whole by write_edits).
@(private)
profiles_json :: proc(w: ^Wizard) -> json.Object {
	out := make(json.Object, context.temp_allocator)
	for key, entries in w.set.mon.profiles {
		arr := make(json.Array, 0, len(entries), context.temp_allocator)
		for e in entries { append(&arr, json.Value(config.display_output_json(e))) }
		out[key] = arr
	}
	return out
}

// ---------------------------------------------------------------------------
// Editing
// ---------------------------------------------------------------------------

// The sizes the monitor offers, largest first.
@(private="file")
mode_sizes :: proc(o: ^display.Output) -> [][2]i32 {
	sizes := make([dynamic][2]i32, context.temp_allocator)
	outer: for md in o.modes {
		for s in sizes { if s == {md.w, md.h} { continue outer } }
		append(&sizes, [2]i32{md.w, md.h})
	}
	slice.sort_by(sizes[:], proc(a, b: [2]i32) -> bool { return a.x * a.y > b.x * b.y || (a.x * a.y == b.x * b.y && a.x > b.x) })
	return sizes[:]
}

// The refresh rates at a size, fastest first (rates within 0.05 Hz are one).
@(private="file")
size_rates :: proc(o: ^display.Output, w, h: i32) -> []f64 {
	rates := make([dynamic]f64, context.temp_allocator)
	outer: for md in o.modes {
		if md.w != w || md.h != h { continue }
		for r in rates { if abs(r - md.rate) < 0.05 { continue outer } }
		append(&rates, md.rate)
	}
	slice.sort_by(rates[:], proc(a, b: f64) -> bool { return a > b })
	return rates[:]
}

@(private="file")
rate_labels :: proc(rates: []f64) -> []string {
	exact := false
	for r, i in rates {
		for q in rates[i + 1:] { if math.round(r) == math.round(q) { exact = true } }
	}
	labels := make([]string, len(rates), context.temp_allocator)
	for r, i in rates { labels[i] = exact ? fmt.tprintf("%.2f Hz", r) : fmt.tprintf("%d Hz", int(math.round(r))) }
	return labels
}

@(private="file")
closest_rate :: proc(rates: []f64, rate: f64) -> int {
	best := 0
	for r, i in rates { if abs(r - rate) < abs(rates[best] - rate) { best = i } }
	return best
}

// "16:9" for the usual shapes, else the reduced fraction.
@(private="file")
aspect_label :: proc(w, h: i32) -> string {
	SHAPES :: [?]struct{ r: f64, s: string }{{16.0 / 9, "16:9"}, {16.0 / 10, "16:10"}, {4.0 / 3, "4:3"}, {5.0 / 4, "5:4"},
	                                         {3.0 / 2, "3:2"}, {21.0 / 9, "21:9"}, {32.0 / 9, "32:9"}}
	r := f64(w) / f64(max(h, 1))
	for s in SHAPES { if abs(s.r - r) < 0.03 { return s.s } }
	if r > 2.3 && r < 2.45 { return "21:9" }
	a, b := w, h
	for b != 0 { a, b = b, a % b }
	return fmt.tprintf("%d:%d", w / max(a, 1), h / max(a, 1))
}

// The screen rectangle of an entry (rotation applied), in layout pixels.
@(private="file")
entry_rect :: proc(e: config.Display_Output) -> tx.Rect {
	rw, rh := display.rotated(e.w, e.h, display.rotation_from_name(e.rotation))
	return {e.x, e.y, rw, rh}
}

// A monitor turned on goes to the right of the others.
@(private="file")
place_right :: proc(m: ^Monitors_State, index: int) {
	right: i32 = 0
	for e, i in m.layout {
		if i == index || !e.enabled { continue }
		r := entry_rect(e)
		right = max(right, r.x + r.w)
	}
	m.layout[index].x, m.layout[index].y = right, 0
}

@(private)
monitors_toggle :: proc(w: ^Wizard, ctrl: Control) -> bool {
	m := &w.set.mon
	#partial switch ctrl {
	case .Mon_Enabled:
		e, _ := selected_output(m)
		if e == nil || m.confirm_until > 0 { return true }
		if e.enabled {
			on := 0
			for f in m.layout { if f.enabled { on += 1 } }
			if on <= 1 {
				show_notice(w, tr(w, "Pelo menos um monitor fica ligado", "At least one monitor stays on"))
				return true
			}
			e.enabled = false
			if e.primary {
				e.primary = false
				for &f in m.layout { if f.enabled { f.primary = true; break } }
			}
		} else {
			e.enabled = true
			place_right(m, m.selected)
		}
		w.dirty = true
		return true
	case .Dsp_Auto:
		m.auto_apply = !m.auto_apply
		set_edit(w, "displays.autoApply", json.Boolean(m.auto_apply))
		settings_changed(w, .Values)
		return true
	}
	return false
}

@(private)
monitors_choice :: proc(w: ^Wizard, ctrl: Control, opt: int) -> bool {
	m := &w.set.mon
	#partial switch ctrl {
	case .Mon_Rate:
		e, o := selected_output(m)
		if e == nil || o == nil || m.confirm_until > 0 { return true }
		rates := size_rates(o, e.w, e.h)
		if opt >= 0 && opt < len(rates) { e.rate = rates[opt] }
	case .Mon_Rotation:
		e, _ := selected_output(m)
		if e == nil || m.confirm_until > 0 { return true }
		names := display.ROTATION_NAMES
		delete(e.rotation)
		e.rotation = strings.clone(names[display.Rotation(clamp(opt, 0, 3))])
	case .Dsp_Scale:
		scales := SCALES
		m.scale = scales[clamp(opt, 0, len(scales) - 1)]
		set_edit(w, "displays.scale", json.Float(m.scale))
		settings_changed(w, .Values)
	case:
		return false
	}
	w.dirty = true
	return true
}

// The rate as a stepper (more rates than a segmented control holds).
@(private)
monitors_step :: proc(w: ^Wizard, ctrl: Control, dir: int) -> bool {
	m := &w.set.mon
	if ctrl != .Mon_Rate { return false }
	e, o := selected_output(m)
	if e == nil || o == nil || m.confirm_until > 0 { return true }
	rates := size_rates(o, e.w, e.h)
	if len(rates) == 0 { return true }
	i := closest_rate(rates, e.rate)
	e.rate = rates[clamp(i - dir, 0, len(rates) - 1)] // fastest first: + goes up
	w.dirty = true
	return true
}

@(private)
monitors_action :: proc(w: ^Wizard, action: Action, arg: int) {
	m := &w.set.mon
	d := &w.set.disp
	#partial switch action {
	case .Disp_Tab:
		d.tab = clamp(arg, 0, 2)
		m.picking = false
	case .Mon_Select:
		if arg < 0 || arg >= len(m.layout) { break }
		m.selected = arg
		if m.confirm_until > 0 || !m.layout[arg].enabled { break }
		// Start dragging it (monitors_drag moves it while the button is held).
		m.dragging = arg
		e := m.layout[arg]
		lx := (f64(w.pointer.x) - m.view_origin.x) / max(m.view_scale, 0.0001) + f64(m.view_base.x)
		ly := (f64(w.pointer.y) - m.view_origin.y) / max(m.view_scale, 0.0001) + f64(m.view_base.y)
		m.grab = {lx - f64(e.x), ly - f64(e.y)}
	case .Mon_Mode:
		if m.confirm_until > 0 { break }
		if e, o := selected_output(m); e != nil && o != nil && e.enabled {
			m.picking = true
			m.scroll = 0
		}
	case .Mon_Mode_Back:
		m.picking = false
	case .Mon_Mode_Pick:
		e, o := selected_output(m)
		m.picking = false
		if e == nil || o == nil { break }
		sizes := mode_sizes(o)
		if arg < 0 || arg >= len(sizes) { break }
		before := entry_rect(e^)
		e.w, e.h = sizes[arg].x, sizes[arg].y
		rates := size_rates(o, e.w, e.h)
		if len(rates) > 0 { e.rate = rates[closest_rate(rates, e.rate)] }
		// The monitors right of it or below it follow its new size.
		monitors_close_gaps(m, m.selected, before)
	case .Mon_Primary:
		if m.confirm_until > 0 { break }
		if e, _ := selected_output(m); e != nil && e.enabled {
			for &f in m.layout { f.primary = false }
			e.primary = true
		}
	case .Mon_Apply:
		monitors_apply(w)
	case .Mon_Undo:
		layout_set(&m.layout, m.applied[:])
		delete(m.error)
		m.error = ""
	case .Mon_Keep:
		monitors_keep(w)
	case .Mon_Revert:
		monitors_revert(w)
	case .Mon_Profile_Delete:
		keys := profile_keys(m)
		if arg < 0 || arg >= len(keys) { break }
		key := keys[arg]
		if key in m.profiles {
			k, entries := delete_key(&m.profiles, key)
			config.destroy_display_outputs(entries)
			delete(k)
		}
		m.profiles_dirty = true
		settings_changed(w, .Values)
	}
	w.dirty = true
}

// After a monitor changed size, the ones that touched its right or bottom edge
// keep touching it.
@(private="file")
monitors_close_gaps :: proc(m: ^Monitors_State, index: int, old: tx.Rect) {
	if index < 0 || index >= len(m.layout) { return }
	now := entry_rect(m.layout[index])
	for &e, i in m.layout {
		if i == index || !e.enabled { continue }
		if e.x == old.x + old.w { e.x = now.x + now.w }
		if e.y == old.y + old.h { e.y = now.y + now.h }
	}
}

// Pointer motion while a monitor is dragged (the first button held).
@(private)
monitors_drag :: proc(w: ^Wizard, x, y: i32, held: bool) {
	m := &w.set.mon
	if m.dragging < 0 { return }
	if !held || m.dragging >= len(m.layout) {
		if m.dragging < len(m.layout) { attach(m, m.dragging) }
		m.dragging = -1
		display.normalize(m.layout[:])
		w.dirty = true
		return
	}
	sc := max(m.view_scale, 0.0001)
	lx := (f64(x) - m.view_origin.x) / sc + f64(m.view_base.x) - m.grab.x
	ly := (f64(y) - m.view_origin.y) / sc + f64(m.view_base.y) - m.grab.y
	nx, ny := snap(m, m.dragging, i32(math.round(lx)), i32(math.round(ly)), f64(MON_SNAP) / sc)
	e := &m.layout[m.dragging]
	if e.x != nx || e.y != ny {
		e.x, e.y = nx, ny
		w.dirty = true
	}
}

// Stick a dragged monitor to the edges of the others: side by side, or
// aligned with their top, bottom, left or right edge.
@(private="file")
snap :: proc(m: ^Monitors_State, index: int, x, y: i32, threshold: f64) -> (i32, i32) {
	r := entry_rect(m.layout[index])
	best_x, best_y := x, y
	dx_best, dy_best := threshold + 1, threshold + 1
	for e, i in m.layout {
		if i == index || !e.enabled { continue }
		o := entry_rect(e)
		for cx in ([4]i32{o.x + o.w, o.x - r.w, o.x, o.x + o.w - r.w}) {
			if d := f64(abs(cx - x)); d < dx_best { dx_best, best_x = d, cx }
		}
		for cy in ([4]i32{o.y, o.y + o.h - r.h, o.y + o.h, o.y - r.h}) {
			if d := f64(abs(cy - y)); d < dy_best { dy_best, best_y = d, cy }
		}
	}
	return best_x if dx_best <= threshold else x, best_y if dy_best <= threshold else y
}

// A monitor dropped away from the others moves to the closest place where it
// touches one edge to edge without covering any: no dead space between monitors.
@(private="file")
attach :: proc(m: ^Monitors_State, index: int) {
	r := entry_rect(m.layout[index])
	others := make([dynamic]tx.Rect, 0, len(m.layout), context.temp_allocator)
	for e, i in m.layout { if i != index && e.enabled { append(&others, entry_rect(e)) } }
	if len(others) == 0 { return }
	overlaps :: proc(a: tx.Rect, list: []tx.Rect) -> bool {
		for b in list { if a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h { return true } }
		return false
	}
	touches :: proc(a: tx.Rect, list: []tx.Rect) -> bool {
		for b in list {
			side := (a.x == b.x + b.w || a.x + a.w == b.x) && a.y < b.y + b.h && b.y < a.y + a.h
			flat := (a.y == b.y + b.h || a.y + a.h == b.y) && a.x < b.x + b.w && b.x < a.x + a.w
			if side || flat { return true }
		}
		return false
	}
	if touches(r, others[:]) && !overlaps(r, others[:]) { return }
	best := r
	best_d := max(f64)
	for o in others {
		// Left, right, above, below o, as close to where it was dropped as that allows.
		cy := clamp(r.y, o.y - r.h + 1, o.y + o.h - 1)
		cx := clamp(r.x, o.x - r.w + 1, o.x + o.w - 1)
		for cand in ([4]tx.Rect{{o.x - r.w, cy, r.w, r.h}, {o.x + o.w, cy, r.w, r.h}, {cx, o.y - r.h, r.w, r.h}, {cx, o.y + o.h, r.w, r.h}}) {
			if overlaps(cand, others[:]) { continue }
			dx, dy := f64(cand.x - r.x), f64(cand.y - r.y)
			if d := dx * dx + dy * dy; d < best_d { best, best_d = cand, d }
		}
	}
	if best_d < max(f64) { m.layout[index].x, m.layout[index].y = best.x, best.y }
}

@(private="file")
profile_keys :: proc(m: ^Monitors_State) -> []string {
	keys := make([dynamic]string, 0, len(m.profiles), context.temp_allocator)
	for k in m.profiles { append(&keys, k) }
	slice.sort(keys[:])
	return keys[:]
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------
@(private)
draw_monitors_tab :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	m := &w.set.mon
	th := &w.theme
	if !m.ok || m.state == nil || len(m.layout) == 0 {
		text(w, w.f_body, c.x, c.y + 8, 24, tr(w, "Este servidor X não permite mudar os monitores (RandR 1.2).",
		                                       "This X server does not let the monitors be changed (RandR 1.2)."), th.muted)
		return
	}
	if m.picking {
		draw_mode_picker(w, cv, c)
		return
	}
	rows_h := i32(4 * SET_ROW_H)
	box := tx.Rect{c.x, c.y, c.w, max(c.h - rows_h - 12, 150)}
	draw_arrangement(w, cv, box)

	e, o := selected_output(m)
	if e == nil { return }
	busy := m.confirm_until > 0
	y := box.y + box.h + 8
	name := monitor_name(w, o)
	output := o != nil ? o.name : e.output
	row := next_row(w, cv, c, &y, tr(w, "Usar este monitor", "Use this monitor"), name == output ? name : fmt.tprintf("%s · %s", name, output), busy)
	toggle(w, cv, row, e.enabled, .Mon_Enabled)
	off := !e.enabled || busy || o == nil

	// Resolution: a pill that opens the list.
	pref := ""
	if o != nil {
		if pm, ok := display.preferred_mode(o); ok { pref = fmt.tprintf(tr(w, "Recomendada: %d × %d", "Recommended: %d × %d"), pm.w, pm.h) }
	}
	row = next_row(w, cv, c, &y, tr(w, "Resolução", "Resolution"), pref, off)
	{
		label := fmt.tprintf("%d × %d", e.w, e.h)
		bw := text_width(w, w.f_body, label) + 60
		r := tx.Rect{row.x + row.w - bw, row.y + 8, bw, 40}
		fill_rounded(cv, r, 20, !off && hovered(w, .Mon_Mode) ? th.hover : th.surface)
		text(w, w.f_body, r.x + 18, r.y, r.h, label, off ? th.muted : th.fg)
		icon(w, w.f_icon_small, {r.x + r.w - 34, r.y, 20, r.h}, .Chevron_Right, off ? th.muted : th.fg)
		if !off { add_hit(w, r, .Mon_Mode) }
	}

	row = next_row(w, cv, c, &y, tr(w, "Taxa de atualização", "Refresh rate"), "", off)
	if o != nil {
		rates := size_rates(o, e.w, e.h)
		if len(rates) > 4 {
			stepper(w, cv, row, rate_labels(rates)[closest_rate(rates, e.rate)], .Mon_Rate)
		} else if len(rates) > 0 {
			rw := min(i32(110) * i32(len(rates)), row.w - 260)
			choice_control(w, cv, {row.x + row.w - rw, row.y + 8, rw, 40}, rate_labels(rates), closest_rate(rates, e.rate), .Mon_Rate)
		}
	}

	row = next_row(w, cv, c, &y, tr(w, "Rotação", "Rotation"), "", off)
	rot_w := min(i32(460), row.w - 220)
	choice_control(w, cv, {row.x + row.w - rot_w, row.y + 8, rot_w, 40},
	               {tr(w, "Normal", "Normal"), tr(w, "Esquerda", "Left"), tr(w, "Invertida", "Upside down"), tr(w, "Direita", "Right")},
	               int(display.rotation_from_name(e.rotation)), .Mon_Rotation)
}

// The monitors to scale in a box, each with its name and resolution; the
// bottom band holds the primary pill, the monitors that are off and the
// Aplicar / Manter buttons.
@(private="file")
draw_arrangement :: proc(w: ^Wizard, cv: ^tx.Canvas, box: tx.Rect) {
	m := &w.set.mon
	th := &w.theme
	fill_rounded(cv, box, 18, th.field)
	tx.canvas_stroke_rounded_rect(cv, box, 18, 1, th.outline)
	area := tx.Rect{box.x + 24, box.y + 18, box.w - 48, box.h - 18 - MON_BAND}

	// The mapping is frozen while a monitor is dragged (else the view jumps).
	if m.dragging < 0 {
		min_x, min_y, max_x, max_y := max(i32), max(i32), min(i32), min(i32)
		for e in m.layout {
			if !e.enabled { continue }
			r := entry_rect(e)
			min_x, min_y = min(min_x, r.x), min(min_y, r.y)
			max_x, max_y = max(max_x, r.x + r.w), max(max_y, r.y + r.h)
		}
		if min_x == max(i32) { min_x, min_y, max_x, max_y = 0, 0, 1920, 1080 }
		bw, bh := f64(max_x - min_x), f64(max_y - min_y)
		sc := min(f64(area.w) / bw, f64(area.h) / bh) * 0.92
		m.view_scale = sc
		m.view_base = {min_x, min_y}
		m.view_origin = {f64(area.x) + (f64(area.w) - bw * sc) / 2, f64(area.y) + (f64(area.h) - bh * sc) / 2}
	}
	number := 0
	for e, i in m.layout {
		if !e.enabled { continue }
		number += 1
		r := entry_rect(e)
		wr := tx.Rect{
			i32(m.view_origin.x + f64(r.x - m.view_base.x) * m.view_scale) + 2, i32(m.view_origin.y + f64(r.y - m.view_base.y) * m.view_scale) + 2,
			max(i32(f64(r.w) * m.view_scale) - 4, 8), max(i32(f64(r.h) * m.view_scale) - 4, 8),
		}
		sel := i == m.selected
		hot := hovered(w, .Mon_Select, i) || m.dragging == i
		bg := sel ? th.accent : (hot ? th.hover : th.surface)
		fg := sel ? th.accent_fg : th.fg
		fill_rounded(cv, wr, 10, bg)
		if !sel { tx.canvas_stroke_rounded_rect(cv, wr, 10, 1.5, mix(th.outline, th.fg, 0.2)) }
		o := display.find_output(m.state, e)
		inner := wr.w - 20
		if wr.h >= 44 && inner > 30 {
			text(w, w.f_body, wr.x + 10, wr.y + 6, 22, ellipsize(w, w.f_body, fmt.tprintf("%d  %s", number, monitor_name(w, o)), inner - (e.primary ? 22 : 0)), fg)
			if wr.h >= 64 { text(w, w.f_small, wr.x + 10, wr.y + wr.h - 26, 20, ellipsize(w, w.f_small, fmt.tprintf("%d × %d", e.w, e.h), inner), sel ? fg : th.muted) }
			if e.primary { icon(w, w.f_icon_small, {wr.x + wr.w - 28, wr.y + 6, 20, 22}, .Star, fg) }
		} else {
			text_centered(w, w.f_body, wr, fmt.tprintf("%d", number), fg)
		}
		add_hit(w, wr, .Mon_Select, i)
	}

	// The bottom band.
	band := tx.Rect{box.x + 14, box.y + box.h - MON_BAND + 4, box.w - 28, MON_BAND - 12}
	x := band.x
	if m.confirm_until > 0 {
		left := int(math.ceil(m.confirm_until - tx.now()))
		msg := fmt.tprintf(tr(w, "Manter esta configuração? Volta à anterior em %d s", "Keep this layout? Going back in %d s"), max(left, 0))
		keep := tr(w, "Manter", "Keep")
		back := tr(w, "Voltar", "Revert")
		kw := button_width(w, keep)
		bw := button_width(w, back)
		kr := tx.Rect{band.x + band.w - kw, band.y, kw, band.h}
		br := tx.Rect{kr.x - 10 - bw, band.y, bw, band.h}
		button(w, cv, kr, keep, .Filled, .Mon_Keep)
		button(w, cv, br, back, .Tonal, .Mon_Revert)
		text(w, w.f_body, band.x + 6, band.y, band.h, ellipsize(w, w.f_body, msg, br.x - band.x - 16), th.fg)
		return
	}
	e, _ := selected_output(m)
	if e != nil && e.enabled {
		label := tr(w, "Principal", "Primary")
		pw := text_width(w, w.f_body, label) + 56
		pr := tx.Rect{x, band.y + (band.h - 36) / 2, pw, 36}
		if e.primary {
			fill_rounded(cv, pr, 18, mix(th.accent, th.field, 0.75))
		} else {
			fill_rounded(cv, pr, 18, hovered(w, .Mon_Primary) ? th.hover : th.surface)
			add_hit(w, pr, .Mon_Primary)
		}
		icon(w, w.f_icon_small, {pr.x + 12, pr.y, 20, pr.h}, .Star, e.primary ? th.accent : th.muted)
		text(w, w.f_body, pr.x + 38, pr.y, pr.h, label, th.fg)
		x += pw + 10
	}
	// Monitors connected but off: chips that select them.
	for f, i in m.layout {
		if f.enabled { continue }
		o := display.find_output(m.state, f)
		label := fmt.tprintf(tr(w, "%s (desligado)", "%s (off)"), monitor_name(w, o))
		cw := min(text_width(w, w.f_small, label) + 28, 220)
		r := tx.Rect{x, band.y + (band.h - 32) / 2, cw, 32}
		if r.x + r.w > band.x + band.w - 240 { break }
		fill_rounded(cv, r, 16, i == m.selected ? mix(th.accent, th.field, 0.7) : (hovered(w, .Mon_Select, i) ? th.hover : th.surface))
		text_centered(w, w.f_small, r, ellipsize(w, w.f_small, label, cw - 16), th.fg)
		add_hit(w, r, .Mon_Select, i)
		x += cw + 8
	}
	if monitors_dirty(m) {
		apply := tr(w, "Aplicar", "Apply")
		undo := tr(w, "Desfazer", "Undo")
		aw := button_width(w, apply)
		uw := button_width(w, undo)
		ar := tx.Rect{band.x + band.w - aw, band.y, aw, band.h}
		ur := tx.Rect{ar.x - 8 - uw, band.y, uw, band.h}
		button(w, cv, ar, apply, .Filled, .Mon_Apply)
		button(w, cv, ur, undo, .Text, .Mon_Undo)
	} else if m.error != "" {
		msg := fmt.tprintf(tr(w, "Não foi possível aplicar: %s", "Could not apply: %s"), m.error)
		text(w, w.f_small, x + 6, band.y, band.h, ellipsize(w, w.f_small, msg, band.x + band.w - x - 6), th.warning)
	} else {
		hint := tr(w, "Arraste os monitores para organizá-los", "Drag the monitors to arrange them")
		hw := text_width(w, w.f_small, hint)
		if band.x + band.w - hw > x + 12 { text(w, w.f_small, band.x + band.w - hw - 6, band.y, band.h, hint, th.muted) }
	}
	if m.error != "" && monitors_dirty(m) {
		text(w, w.f_small, box.x + 24, box.y + 2, 16, ellipsize(w, w.f_small, m.error, box.w - 48), th.warning)
	}
}

// The resolutions of the selected monitor (a click picks one and goes back).
@(private="file")
draw_mode_picker :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	m := &w.set.mon
	th := &w.theme
	e, o := selected_output(m)
	if e == nil || o == nil {
		m.picking = false
		return
	}
	back := tr(w, "Voltar", "Back")
	bw := button_width(w, back, .Arrow_Left)
	button(w, cv, {c.x, c.y, bw, 40}, back, .Tonal, .Mon_Mode_Back, 0, .Arrow_Left)
	text(w, w.f_h2, c.x + bw + 18, c.y, 40, ellipsize(w, w.f_h2, fmt.tprintf(tr(w, "Resolução de %s", "Resolution of %s"), monitor_name(w, o)), c.w - bw - 18), th.fg)
	lr := tx.Rect{c.x, c.y + 56, c.w, c.h - 56}
	sizes := mode_sizes(o)
	pref, has_pref := display.preferred_mode(o)
	content_h := i32(len(sizes)) * ROW_H + 8
	sub := list_begin(w, lr, content_h, &m.scroll, .Monitors)
	for s, i in sizes {
		y := 4 + i32(i) * ROW_H - m.scroll
		if y + ROW_H < 0 { continue }
		if y > lr.h { break }
		detail := aspect_label(s.x, s.y)
		if has_pref && pref.w == s.x && pref.h == s.y { detail = fmt.tprintf(tr(w, "%s · recomendada", "%s · recommended"), detail) }
		list_row(w, &sub, lr, y, fmt.tprintf("%d × %d", s.x, s.y), detail, s.x == e.w && s.y == e.h, .Mon_Mode_Pick, i)
	}
	list_end(w, cv, &sub, lr, content_h, m.scroll)
}

// Escala e conexão: the apps' scale, autoApply and the saved profiles.
@(private)
draw_scale_tab :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	m := &w.set.mon
	th := &w.theme
	y := c.y
	row := next_row(w, cv, c, &y, tr(w, "Escala dos aplicativos", "Applications' scale"),
	                tr(w, "Para os abertos depois; os GTK mudam na hora", "For the ones opened next; GTK apps change at once"))
	scales := SCALES
	sel := 0
	for s, i in scales { if abs(s - m.scale) < abs(scales[sel] - m.scale) { sel = i } }
	sw := min(i32(470), row.w - 300)
	choice_control(w, cv, {row.x + row.w - sw, row.y + 8, sw, 40}, {"100%", "125%", "150%", "175%", "200%"}, sel, .Dsp_Scale)
	row = next_row(w, cv, c, &y, tr(w, "Ajustar ao conectar monitores", "Adjust when monitors are connected"),
	               tr(w, "A configuração salva de cada conjunto, ou estender a tela", "The layout saved for each set, or extend the screen"))
	toggle(w, cv, row, m.auto_apply, .Dsp_Auto)

	y += 18
	text(w, w.f_tiny, c.x, y, 18, tr(w, "CONFIGURAÇÕES SALVAS", "SAVED LAYOUTS"), th.muted)
	y += 24
	keys := profile_keys(m)
	if len(keys) == 0 {
		text(w, w.f_small, c.x, y, 22, ellipsize(w, w.f_small, tr(w, "Nenhuma ainda: aplique e mantenha uma configuração na aba Monitores.",
		                                                         "None yet: apply and keep a layout in the Monitors tab."), c.w), th.muted)
		return
	}
	for key, i in keys {
		if y + SET_ROW_H > c.y + c.h + 8 { break }
		entries := m.profiles[key]
		names := make([dynamic]string, 0, len(entries), context.temp_allocator)
		for e in entries {
			o := m.state != nil ? display.find_output(m.state, e) : nil
			append(&names, o != nil ? monitor_name(w, o) : e.output != "" ? e.output : e.monitor)
		}
		on := 0
		for e in entries { if e.enabled { on += 1 } }
		desc := key == m.key ? tr(w, "Os monitores conectados agora", "The monitors connected now") :
		                       fmt.tprintf(tr(w, "%d ligado(s)", "%d on"), on)
		label := strings.join(names[:], " + ", context.temp_allocator)
		r := next_row(w, cv, c, &y, ellipsize(w, w.f_body, label, c.w - 80), desc)
		del := tx.Rect{r.x + r.w - 40, r.y + 8, 40, 40}
		fill_rounded(cv, del, 20, hovered(w, .Mon_Profile_Delete, i) ? th.hover : th.surface)
		icon(w, w.f_icon_small, del, .Trash, th.fg)
		add_hit(w, del, .Mon_Profile_Delete, i)
	}
}
