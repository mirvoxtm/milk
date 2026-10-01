// milk addition: a window moved with the mouse (title bar drag, Alt+drag
// and client move requests in the floating mode, Mod+drag in the tiling
// mode) and released on one of the bar's area dots goes to that area, like
// the "send" action: the view stays where it is, the window gets back the
// place and size it had before the drag (or its tile) and loses "on every
// area". The window manager holds the pointer grab while it moves a window,
// so the bar never sees the pointer: main.odin hands it a probe
// (set_drop_probe) that asks the bar which dot is under the pointer and
// highlights it.
package wm

import xlib "vendor:x11/xlib"

// `ending` false: the pointer is at root (x, y) during a move; highlight the
// dot under it and return its area (1-based; 0 = none). `ending` true: the
// move is over (released at x, y, or abandoned with x = y = -1); clear the
// highlight and return the area under (x, y).
Drop_Probe :: #type proc(data: rawptr, x, y: i32, ending: bool) -> int

set_drop_probe :: proc(m: ^Manager, probe: Drop_Probe, data: rawptr) {
	if m == nil { return }
	m.drop_probe = probe
	m.drop_data = data
}

// A window as it was when a move started.
@(private)
Drag_Start :: struct {
	x, y, w, h:         i32,
	floating:           bool,
	max_horz, max_vert: bool,
	snapped:            Snap,
	has_saved:          bool,
	saved:              [4]i32,
}

@(private)
drag_start :: proc(c: ^Client) -> Drag_Start {
	return {c.x, c.y, c.w, c.h, c.isfloating, c.max_horz, c.max_vert, c.snapped, c.has_saved, c.saved}
}

// Can `c` be dropped on an area? Not docks and desktops (they are never
// moved) nor picture-in-picture windows (on every area by design).
@(private)
can_drop :: proc(m: ^Manager, c: ^Client) -> bool {
	return m.drop_probe != nil && !c.ispip && c.kind != .Dock && c.kind != .Desktop
}

@(private)
drop_hover :: proc(m: ^Manager, x, y: i32) -> int {
	if m.drop_probe == nil { return 0 }
	return m.drop_probe(m.drop_data, x, y, false)
}

@(private)
drop_end :: proc(m: ^Manager, x, y: i32) -> int {
	if m.drop_probe == nil { return 0 }
	return m.drop_probe(m.drop_data, x, y, true)
}

// `c` was released on area n's dot: send it there as it was before the move.
@(private)
drop_on_area :: proc(m: ^Manager, c: ^Client, n: int, s: Drag_Start) {
	if n < 1 || n > m.settings.tag_count { return }
	if c.sticky { set_sticky(m, c, false) } // like the "send" action
	// Tiled again, or its floating place and size (maximized or snapped included).
	c.isfloating = s.floating
	c.max_horz, c.max_vert, c.snapped = s.max_horz, s.max_vert, s.snapped
	c.has_saved, c.saved = s.has_saved, s.saved
	write_state_atom(m, c, m.atoms.net_wm_state_maximized_horz, c.max_horz)
	write_state_atom(m, c, m.atoms.net_wm_state_maximized_vert, c.max_vert)
	c.tags = u32(1) << u32(n - 1)
	focus(m, nil)
	arrange(m, c.mon) // hidden (off screen) unless area n is on screen
	floats := c.isfloating || !has_arrange(cur_layout(c.mon))
	if is_visible(c) {
		if floats { resizeclient_ex(m, c, s.x, s.y, s.w, s.h, false) }
	} else {
		// The old geometry is applied off screen: the window shows up there
		// on area n without flashing back into place here first.
		c.x, c.y, c.w, c.h = s.x, s.y, s.w, s.h
		hidden_x := width(c) * -2
		if c.frame != 0 {
			frame_apply(m, c, hidden_x, c.y)
		} else {
			xlib.MoveResizeWindow(m.dpy, c.win, hidden_x, c.y, u32(max(c.w, 1)), u32(max(c.h, 1)))
		}
		c.disp_valid = false
		apply_corners(m, c)
		configure(m, c)
	}
	grip_update(m, c)
	frame_paint(m, c)
	m.ewmh.stacking_dirty = true
}
