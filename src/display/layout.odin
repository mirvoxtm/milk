// Layouts: one config.Display_Output per connected monitor (what milk.json's
// profiles hold), made from the current state, chosen automatically for a
// set of monitors without a profile, matched back to the outputs, compared.
package display

import "core:strings"
import config "../config"

// The connected output an entry is for: its monitor identity, else the output
// it was saved on (a monitor without an EDID, or one moved to another port of
// the same machine is not found by identity).
find_output :: proc(s: ^State, e: config.Display_Output) -> ^Output {
	for &o in s.outputs { if o.connected && o.monitor == e.monitor { return &o } }
	if e.output != "" {
		for &o in s.outputs { if o.connected && o.name == e.output { return &o } }
	}
	return nil
}

// The output's mode of size w × h with the rate closest to `rate` (0: the
// preferred one at that size, else the fastest); ok = false when it has no
// mode of that size.
pick_mode :: proc(o: ^Output, w, h: i32, rate: f64) -> (best: Mode, ok: bool) {
	for m in o.modes {
		if m.w != w || m.h != h { continue }
		if !ok { best, ok = m, true; continue }
		if rate > 0 {
			if abs(m.rate - rate) < abs(best.rate - rate) { best = m }
		} else if (m.preferred && !best.preferred) || (m.preferred == best.preferred && m.rate > best.rate + 0.01) {
			best = m
		}
	}
	return
}

// The output's preferred mode (its first), else its largest.
preferred_mode :: proc(o: ^Output) -> (Mode, bool) {
	for m in o.modes { if m.preferred { return m, true } }
	best: Mode
	found := false
	for m in o.modes {
		if !found || m.w * m.h > best.w * best.h || (m.w * m.h == best.w * best.h && m.rate > best.rate) { best, found = m, true }
	}
	return best, found
}

// The current layout of the connected monitors (strings in `allocator`).
layout_from_state :: proc(s: ^State, allocator := context.allocator) -> []config.Display_Output {
	out := make([dynamic]config.Display_Output, 0, len(s.outputs), allocator)
	for &o in s.outputs {
		if !o.connected { continue }
		e := config.Display_Output{
			monitor = strings.clone(o.monitor, allocator), output = strings.clone(o.name, allocator),
			enabled = o.crtc != 0, primary = o.primary,
		}
		names := ROTATION_NAMES
		if o.crtc != 0 {
			e.w, e.h = rotated(o.w, o.h, o.rotation) // back to the mode's own size
			e.rate = o.rate
			e.x, e.y = o.x, o.y
			e.rotation = strings.clone(names[o.rotation], allocator)
		} else {
			if m, ok := preferred_mode(&o); ok { e.w, e.h, e.rate = m.w, m.h, m.rate }
			e.rotation = strings.clone("normal", allocator)
		}
		append(&out, e)
	}
	return out[:]
}

// For a set of monitors without a profile: the monitors on now stay as they
// are, the ones connected but off come on at their preferred mode to the right
// of the others, top-aligned. With none on (the only one on was unplugged)
// every connected monitor comes on, left to right, the built-in panel first.
auto_layout :: proc(s: ^State, allocator := context.allocator) -> []config.Display_Output {
	layout := layout_from_state(s, allocator)
	any_on := false
	right: i32 = 0
	for &e in layout {
		if !e.enabled { continue }
		any_on = true
		w, _ := rotated(e.w, e.h, rotation_from_name(e.rotation))
		right = max(right, e.x + w)
	}
	if !any_on {
		// Built-in panel first.
		order := make([dynamic]int, 0, len(layout), context.temp_allocator)
		for e, i in layout { if o := find_output(s, e); o != nil && o.internal { append(&order, i) } }
		for e, i in layout { if o := find_output(s, e); o == nil || !o.internal { append(&order, i) } }
		for i in order {
			e := &layout[i]
			if e.w <= 0 { continue }
			e.enabled = true
			e.x, e.y = right, 0
			right += e.w
		}
	} else {
		for &e in layout {
			if e.enabled || e.w <= 0 { continue }
			e.enabled = true
			e.x, e.y = right, 0
			right += e.w
		}
	}
	ensure_primary(s, layout)
	normalize(layout)
	return layout
}

// Exactly one enabled monitor is primary: the one marked, else the built-in panel, else the first.
ensure_primary :: proc(s: ^State, layout: []config.Display_Output) {
	chosen := -1
	for e, i in layout { if e.enabled && e.primary && chosen < 0 { chosen = i } }
	if chosen < 0 {
		for e, i in layout {
			if !e.enabled { continue }
			if o := find_output(s, e); o != nil && o.internal { chosen = i; break }
		}
	}
	if chosen < 0 { for e, i in layout { if e.enabled { chosen = i; break } } }
	for &e, i in layout { e.primary = i == chosen }
}

// Move the layout so the enabled monitors start at 0, 0.
normalize :: proc(layout: []config.Display_Output) {
	min_x, min_y := max(i32), max(i32)
	for e in layout {
		if !e.enabled { continue }
		min_x, min_y = min(min_x, e.x), min(min_y, e.y)
	}
	if min_x == max(i32) { return }
	for &e in layout {
		if !e.enabled { continue }
		e.x -= min_x
		e.y -= min_y
	}
}

// The screen size a layout needs (the bounding box of the enabled monitors).
layout_size :: proc(layout: []config.Display_Output) -> (w, h: i32) {
	for e in layout {
		if !e.enabled { continue }
		rw, rh := rotated(e.w, e.h, rotation_from_name(e.rotation))
		w, h = max(w, e.x + rw), max(h, e.y + rh)
	}
	return
}

// Whether the screen already shows `layout`: the same monitors on, at the
// same positions, modes (rates within 0.5 Hz), rotations and primary.
same_layout :: proc(s: ^State, layout: []config.Display_Output) -> bool {
	seen := make(map[^Output]bool, context.temp_allocator)
	for e in layout {
		o := find_output(s, e)
		if o == nil { continue }
		seen[o] = true
		if !e.enabled {
			if o.crtc != 0 { return false }
			continue
		}
		if o.crtc == 0 { return false }
		w, h := rotated(o.w, o.h, o.rotation)
		if w != e.w || h != e.h || o.x != e.x || o.y != e.y { return false }
		if o.rotation != rotation_from_name(e.rotation) || o.primary != e.primary { return false }
		if e.rate > 0 && abs(o.rate - e.rate) > 0.5 { return false }
	}
	// A connected monitor the layout does not mention is turned off by it.
	for &o in s.outputs { if o.connected && o.crtc != 0 && !seen[&o] { return false } }
	return true
}

// Whether a profile still fits the monitors connected: every entry finds its
// output and its mode.
layout_fits :: proc(s: ^State, layout: []config.Display_Output) -> bool {
	on := 0
	for e in layout {
		o := find_output(s, e)
		if o == nil { return false }
		if !e.enabled { continue }
		if _, ok := pick_mode(o, e.w, e.h, e.rate); !ok { return false }
		on += 1
	}
	return on > 0
}

clone_layout :: proc(layout: []config.Display_Output, allocator := context.allocator) -> []config.Display_Output {
	out := make([]config.Display_Output, len(layout), allocator)
	for e, i in layout {
		out[i] = e
		out[i].monitor = strings.clone(e.monitor, allocator)
		out[i].output = strings.clone(e.output, allocator)
		out[i].rotation = strings.clone(e.rotation, allocator)
	}
	return out
}
