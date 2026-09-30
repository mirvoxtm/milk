// milk addition: the window states of the floating mode, openbox style —
// minimize (iconify), maximize (both ways or one axis), snap layouts
// (halves, quarters), shade, always on top / below, on every area, no
// decorations — each published as _NET_WM_STATE and settable by clients,
// pagers (the bar's task list) and the user; plus where new windows appear
// (wm.placement) and "show desktop". Minimize and "on every area" also work
// in the tiling mode.
package wm

import xlib "vendor:x11/xlib"
import tx "../tx"

// The monitor's window area minus the gaps: where maximized and snapped windows go.
work_rect :: proc(m: ^Manager, mon: ^Monitor) -> tx.Rect {
	g := m.settings.gaps
	return {mon.wx + g, mon.wy + g, max(mon.ww - 2 * g, MIN_SIZE), max(mon.wh - 2 * g, MIN_SIZE)}
}

// The outer rectangle of a snap layout.
snap_rect :: proc(m: ^Manager, mon: ^Monitor, snap: Snap) -> tx.Rect {
	r := work_rect(m, mon)
	g := m.settings.gaps
	hw := (r.w - g) / 2
	hh := (r.h - g) / 2
	switch snap {
	case .None, .Top:     return r
	case .Left:           return {r.x, r.y, hw, r.h}
	case .Right:          return {r.x + r.w - hw, r.y, hw, r.h}
	case .Bottom:         return {r.x, r.y + r.h - hh, r.w, hh}
	case .Top_Left:       return {r.x, r.y, hw, hh}
	case .Top_Right:      return {r.x + r.w - hw, r.y, hw, hh}
	case .Bottom_Left:    return {r.x, r.y + r.h - hh, hw, hh}
	case .Bottom_Right:   return {r.x + r.w - hw, r.y + r.h - hh, hw, hh}
	}
	return r
}

// Whether a client can be moved and resized freely (not tiled, not fullscreen).
@(private)
is_free :: proc(m: ^Manager, c: ^Client) -> bool {
	return !c.isfullscreen && (c.isfloating || !has_arrange(cur_layout(c.mon))) && c.kind == .Normal
}

// Give the client the outer rectangle `r` (no size hints: maximized and
// snapped windows fill their place exactly).
@(private)
set_outer :: proc(m: ^Manager, c: ^Client, r: tx.Rect) {
	resizeclient(m, c, r.x, r.y, max(r.w - ext_w(c), MIN_SIZE), max(r.h - ext_h(c), MIN_SIZE))
}

// Remember the geometry to restore later, moved onto the monitor if it hangs
// over an edge (a window dragged to the edge to snap it).
@(private)
save_geometry :: proc(m: ^Manager, c: ^Client) {
	if c.has_saved { return }
	area := work_rect(m, c.mon)
	x := clamp(c.x, area.x, max(area.x, area.x + area.w - width(c)))
	y := clamp(c.y, area.y, max(area.y, area.y + area.h - height(c)))
	c.saved = {x, y, c.w, c.h}
	c.has_saved = true
}

// Back to the geometry before maximize/snap.
@(private)
restore_geometry :: proc(m: ^Manager, c: ^Client) {
	if !c.has_saved { return }
	c.has_saved = false
	resizeclient(m, c, c.saved[0], c.saved[1], c.saved[2], c.saved[3])
}

// wm.mode changed on reload: frame or unframe every window (each keeps its
// place on screen) and switch the monitors' layouts.
switch_mode :: proc(m: ^Manager) {
	s := &m.settings
	for mon := m.mons; mon != nil; mon = mon.next {
		mon.lt = s.floating ? {.Float, .Tile} : {.Tile, .Float}
		mon.sellt = 0
	}
	for mon := m.mons; mon != nil; mon = mon.next {
		for c := mon.clients; c != nil; c = c.next {
			if c.animating { anim_snap(m, c) }
			if s.floating {
				if !wants_frame(m, c) || c.frame != 0 { continue }
				ow, oh := width(c), height(c)
				c.nodecor = motif_undecorated(m, c)
				frame_attach(m, c)
				if c.has_float_geom {
					// Back where it floated before.
					c.x, c.y, c.w, c.h = c.float_geom[0], c.float_geom[1], c.float_geom[2], c.float_geom[3]
				} else {
					// It keeps its tiled place, unless that is much smaller than it asked for.
					area := work_rect(m, c.mon)
					c.w = max(ow - ext_w(c), MIN_SIZE)
					c.h = max(oh - ext_h(c), MIN_SIZE)
					want_w := min(max(c.reqw, 240), area.w - ext_w(c))
					want_h := min(max(c.reqh, 160), area.h - ext_h(c))
					if c.w < want_w / 2 || c.h < want_h / 2 {
						c.w, c.h = want_w, want_h
						place_new(m, c, nil)
					}
				}
				if is_visible(c) { anim_snap(m, c) }
				if c.focused || c == mon.sel { frame_set_active(m, c, c == mon.sel) }
				xlib.MapWindow(m.dpy, c.frame)
				write_allowed_actions(m, c)
			} else if c.frame != 0 {
				// Remembered for a return to the floating mode (maximized/snapped: the size behind it).
				c.float_geom = c.has_saved ? c.saved : {c.x, c.y, c.w, c.h}
				c.has_float_geom = true
				if c.shaded { set_shaded(m, c, false) }
				c.max_horz, c.max_vert, c.snapped, c.has_saved = false, false, .None, false
				write_state_atom(m, c, m.atoms.net_wm_state_maximized_horz, false)
				write_state_atom(m, c, m.atoms.net_wm_state_maximized_vert, false)
				if c.layer != .Normal { set_layer(m, c, .Normal) }
				frame_detach(m, c, false, true)
				if !c.isfullscreen {
					c.bw = s.border_width
					wc: xlib.XWindowChanges
					wc.border_width = c.bw
					xlib.ConfigureWindow(m.dpy, c.win, {.CWBorderWidth}, &wc)
					c.x -= c.bw
					c.y -= c.bw
				}
				c.disp_valid = false
			}
		}
	}
	m.cascade_x, m.cascade_y = 0, 0
	arrange(m, nil)
}

// ---------------------------------------------------------------------------
// Minimize
// ---------------------------------------------------------------------------
set_minimized :: proc(m: ^Manager, c: ^Client, on: bool) {
	if c.minimized == on || c.kind != .Normal { return }
	c.minimized = on
	write_state_atom(m, c, m.atoms.net_wm_state_hidden, on)
	setclientstate(m, c, on ? .IconicState : .NormalState)
	if on {
		if c == c.mon.sel { c.mon.sel = nil }
		focus(m, nil)
		arrange(m, c.mon)
	} else {
		if m.showing_desktop { m.showing_desktop = false }
		arrange(m, c.mon)
		focus(m, c)
		restack(m, c.mon)
	}
	m.ewmh.stacking_dirty = true
}

// Hide every window of the current area (again: bring them back).
toggle_show_desktop :: proc(m: ^Manager) {
	set_showing_desktop(m, !m.showing_desktop)
}

set_showing_desktop :: proc(m: ^Manager, on: bool) {
	if on == m.showing_desktop { return }
	if on {
		clear(&m.desktop_hidden)
		for c := m.selmon.stack; c != nil; c = c.snext {
			if is_visible(c) && c.kind == .Normal && !c.ispip { append(&m.desktop_hidden, c.win) }
		}
		for w in m.desktop_hidden {
			if c := wintoclient(m, w); c != nil { set_minimized(m, c, true) }
		}
		m.showing_desktop = true
	} else {
		m.showing_desktop = false
		// Most recently focused last, so that it ends up on top with the focus.
		#reverse for w in m.desktop_hidden {
			if c := wintoclient(m, w); c != nil && c.minimized { set_minimized(m, c, false) }
		}
		clear(&m.desktop_hidden)
	}
	tx.set_cardinals(m.c, m.root, "_NET_SHOWING_DESKTOP", {m.showing_desktop ? 1 : 0})
}

// ---------------------------------------------------------------------------
// Maximize and snap
// ---------------------------------------------------------------------------
toggle_maximize :: proc(m: ^Manager, c: ^Client) {
	if c.max_horz && c.max_vert { set_maximized(m, c, false, false) } else { set_maximized(m, c, true, true) }
}

// Maximize along the given axes (false, false = restore). Windows of a fixed
// size (min == max) keep it.
set_maximized :: proc(m: ^Manager, c: ^Client, horz, vert: bool) {
	if !is_free(m, c) || (c.isfixed && (horz || vert)) { return }
	if !horz && !vert {
		if !c.max_horz && !c.max_vert && c.snapped == .None { return }
		c.max_horz, c.max_vert, c.snapped = false, false, .None
		restore_geometry(m, c)
	} else {
		save_geometry(m, c)
		if c.snapped != .None { // un-snap first: the other axis comes back from the saved geometry
			c.snapped = .None
		}
		area := work_rect(m, c.mon)
		r := tx.Rect{c.saved[0], c.saved[1], c.saved[2] + ext_w(c), c.saved[3] + ext_h(c)}
		if horz { r.x, r.w = area.x, area.w }
		if vert { r.y, r.h = area.y, area.h }
		c.max_horz, c.max_vert = horz, vert
		if c.shaded { set_shaded(m, c, false) }
		set_outer(m, c, r)
	}
	write_state_atom(m, c, m.atoms.net_wm_state_maximized_horz, c.max_horz)
	write_state_atom(m, c, m.atoms.net_wm_state_maximized_vert, c.max_vert)
	grip_update(m, c)
	frame_paint(m, c)
	restack(m, c.mon)
}

// Snap to a half or a quarter of the monitor (Top = maximize, None = restore).
set_snapped :: proc(m: ^Manager, c: ^Client, snap: Snap) {
	if !is_free(m, c) || (c.isfixed && snap != .None) { return }
	if snap == .Top {
		set_maximized(m, c, true, true)
		return
	}
	if snap == .None {
		set_maximized(m, c, false, false)
		return
	}
	save_geometry(m, c)
	c.max_horz, c.max_vert = false, false
	write_state_atom(m, c, m.atoms.net_wm_state_maximized_horz, false)
	write_state_atom(m, c, m.atoms.net_wm_state_maximized_vert, false)
	c.snapped = snap
	if c.shaded { set_shaded(m, c, false) }
	set_outer(m, c, snap_rect(m, c.mon, snap))
	grip_update(m, c)
	frame_paint(m, c)
	restack(m, c.mon)
}

// A keyboard snap: Left then Right from the right half restores, as on other desktops.
snap_toward :: proc(m: ^Manager, c: ^Client, snap: Snap) {
	opposite := Snap.None
	#partial switch snap {
	case .Left:   opposite = .Right
	case .Right:  opposite = .Left
	case .Top:    opposite = .Bottom
	case .Bottom: opposite = .Top
	}
	if c.snapped == opposite && opposite != .None {
		set_snapped(m, c, .None)
	} else {
		set_snapped(m, c, snap)
	}
}

// Centre on the monitor's window area.
center_client :: proc(m: ^Manager, c: ^Client) {
	if !is_free(m, c) { return }
	area := work_rect(m, c.mon)
	resize(m, c, area.x + (area.w - width(c)) / 2, area.y + (area.h - height(c)) / 2, c.w, c.h, false)
}

// ---------------------------------------------------------------------------
// Shade, layers, every area, decorations
// ---------------------------------------------------------------------------
set_shaded :: proc(m: ^Manager, c: ^Client, on: bool) {
	if on == c.shaded || (on && !has_title(c)) { return }
	c.shaded = on
	write_state_atom(m, c, m.atoms.net_wm_state_shaded, on)
	if is_visible(c) {
		anim_snap(m, c)
		configure(m, c)
	}
	apply_corners(m, c)
	grip_update(m, c)
	frame_paint(m, c)
}

set_layer :: proc(m: ^Manager, c: ^Client, layer: Layer) {
	if c.layer == layer { return }
	c.layer = layer
	write_state_atom(m, c, m.atoms.net_wm_state_above, layer == .Above)
	write_state_atom(m, c, m.atoms.net_wm_state_below, layer == .Below)
	frame_paint(m, c)
	restack(m, c.mon)
}

set_sticky :: proc(m: ^Manager, c: ^Client, on: bool) {
	if c.sticky == on || c.ispip || c.kind != .Normal { return }
	c.sticky = on
	if on {
		c.sticky_tags = c.tags
		c.tags = tagmask(m)
	} else {
		c.tags = c.mon.tagset[c.mon.seltags]
	}
	write_state_atom(m, c, m.atoms.net_wm_state_sticky, on)
	frame_paint(m, c)
	focus(m, nil)
	arrange(m, c.mon)
}

set_decorated :: proc(m: ^Manager, c: ^Client, on: bool) {
	if c.frame == 0 || c.nodecor == !on { return }
	c.nodecor = !on
	frame_refresh(m, c)
	grip_update(m, c)
	apply_corners(m, c)
}

// ---------------------------------------------------------------------------
// Placement of new windows
// ---------------------------------------------------------------------------

// Choose where a new window goes (wm.placement); transients centre on their parent.
place_new :: proc(m: ^Manager, c: ^Client, parent: ^Client) {
	mon := c.mon
	area := work_rect(m, mon)
	// Larger than the monitor: shrink it (size hints allowing).
	if width(c) > area.w { c.w = max(area.w - ext_w(c), MIN_SIZE) }
	if height(c) > area.h { c.h = max(area.h - ext_h(c), MIN_SIZE) }
	ow, oh := width(c), height(c)
	x, y: i32
	if parent != nil && parent.mon == mon && !parent.minimized {
		x = parent.x + (width(parent) - ow) / 2
		y = parent.y + (height(parent) - oh) / 2
	} else {
		switch m.settings.placement {
		case .Center:
			x, y = area.x + (area.w - ow) / 2, area.y + (area.h - oh) / 2
		case .Mouse:
			px, py, _ := getrootptr(m)
			x, y = px - ow / 2, py - oh / 2
		case .Cascade:
			step := m.settings.title_height
			if m.cascade_x < area.x || m.cascade_y < area.y || m.cascade_x + ow > area.x + area.w || m.cascade_y + oh > area.y + area.h {
				m.cascade_x, m.cascade_y = area.x, area.y
			}
			x, y = m.cascade_x, m.cascade_y
			m.cascade_x += step
			m.cascade_y += step
		case .Smart:
			x, y = smart_place(m, c, area, ow, oh)
		}
	}
	c.x = clamp(x, area.x, max(area.x, area.x + area.w - ow))
	c.y = clamp(y, area.y, max(area.y, area.y + area.h - oh))
}

// Openbox's smart placement, preferring the centre: among the positions
// touching the area's edges or other windows' edges (and the centre), the one
// overlapping the other windows least, closest to the centre.
@(private)
smart_place :: proc(m: ^Manager, c: ^Client, area: tx.Rect, ow, oh: i32) -> (i32, i32) {
	g := m.settings.gaps
	others := make([dynamic]tx.Rect, context.temp_allocator)
	for o := c.mon.clients; o != nil; o = o.next {
		if o == c || !is_visible(o) || o.kind != .Normal || o.isfullscreen { continue }
		append(&others, tx.Rect{o.x, o.y, width(o), height(o)})
	}
	cx, cy := area.x + (area.w - ow) / 2, area.y + (area.h - oh) / 2
	xs := make([dynamic]i32, context.temp_allocator)
	ys := make([dynamic]i32, context.temp_allocator)
	append(&xs, cx, area.x, area.x + area.w - ow)
	append(&ys, cy, area.y, area.y + area.h - oh)
	for r in others {
		append(&xs, r.x + r.w + g, r.x - ow - g)
		append(&ys, r.y + r.h + g, r.y - oh - g)
	}
	best_x, best_y := cx, cy
	best_overlap := max(i64)
	best_dist := max(i64)
	for x in xs {
		if x < area.x || x + ow > area.x + area.w { continue }
		for y in ys {
			if y < area.y || y + oh > area.y + area.h { continue }
			overlap: i64
			for r in others {
				if ir, hit := tx.rect_intersect({x, y, ow, oh}, r); hit { overlap += i64(ir.w) * i64(ir.h) }
			}
			dx, dy := i64(x - cx), i64(y - cy)
			dist := dx * dx + dy * dy
			if overlap < best_overlap || (overlap == best_overlap && dist < best_dist) {
				best_x, best_y, best_overlap, best_dist = x, y, overlap, dist
			}
		}
	}
	return best_x, best_y
}

// ---------------------------------------------------------------------------
// _NET_WM_STATE requests and the allowed actions
// ---------------------------------------------------------------------------

// A _NET_WM_STATE client message (action 0 remove, 1 add, 2 toggle) for the
// states the floating mode handles; fullscreen is handled by the caller.
handle_state_message :: proc(m: ^Manager, c: ^Client, action: int, props: [2]xlib.Atom) {
	a := &m.atoms
	want :: proc(action: int, current: bool) -> bool {
		switch action {
		case 0: return false
		case 1: return true
		}
		return !current
	}
	has :: proc(props: [2]xlib.Atom, atom: xlib.Atom) -> bool { return props[0] == atom || props[1] == atom }
	if has(props, a.net_wm_state_maximized_horz) || has(props, a.net_wm_state_maximized_vert) {
		h, v := c.max_horz, c.max_vert
		if has(props, a.net_wm_state_maximized_horz) { h = want(action, c.max_horz) }
		if has(props, a.net_wm_state_maximized_vert) { v = want(action, c.max_vert) }
		set_maximized(m, c, h, v)
	}
	if has(props, a.net_wm_state_hidden) { set_minimized(m, c, want(action, c.minimized)) }
	if has(props, a.net_wm_state_shaded) { set_shaded(m, c, want(action, c.shaded)) }
	if has(props, a.net_wm_state_above) { set_layer(m, c, want(action, c.layer == .Above) ? .Above : .Normal) }
	if has(props, a.net_wm_state_below) { set_layer(m, c, want(action, c.layer == .Below) ? .Below : .Normal) }
	if has(props, a.net_wm_state_sticky) { set_sticky(m, c, want(action, c.sticky)) }
	if has(props, a.net_wm_state_demands_attention) {
		on := want(action, c.isurgent)
		if c != m.selmon.sel || !on { seturgent(m, c, on) }
		frame_paint(m, c)
	}
}

// _NET_WM_ALLOWED_ACTIONS for pagers and task lists.
write_allowed_actions :: proc(m: ^Manager, c: ^Client) {
	names := [?]string{"_NET_WM_ACTION_MOVE", "_NET_WM_ACTION_RESIZE", "_NET_WM_ACTION_MINIMIZE", "_NET_WM_ACTION_MAXIMIZE_HORZ",
	                   "_NET_WM_ACTION_MAXIMIZE_VERT", "_NET_WM_ACTION_FULLSCREEN", "_NET_WM_ACTION_CHANGE_DESKTOP",
	                   "_NET_WM_ACTION_CLOSE", "_NET_WM_ACTION_ABOVE", "_NET_WM_ACTION_BELOW", "_NET_WM_ACTION_STICK",
	                   "_NET_WM_ACTION_SHADE"}
	atoms := make([dynamic]xlib.Atom, context.temp_allocator)
	for n in names {
		if n == "_NET_WM_ACTION_SHADE" && !has_title(c) { continue }
		if c.isfixed && (n == "_NET_WM_ACTION_RESIZE" || n == "_NET_WM_ACTION_MAXIMIZE_HORZ" || n == "_NET_WM_ACTION_MAXIMIZE_VERT") { continue }
		append(&atoms, tx.atom(m.c, n))
	}
	tx.set_atom_list(m.c, c.win, "_NET_WM_ALLOWED_ACTIONS", atoms[:])
}

// Clients a window list shows for a monitor: the current tags first (focus
// order), minimized ones included.
switchable_clients :: proc(m: ^Manager, mon: ^Monitor, allocator := context.temp_allocator) -> []^Client {
	out := make([dynamic]^Client, allocator)
	for c := mon.stack; c != nil; c = c.snext {
		if on_current_tags(c) && c.kind == .Normal && !c.nofocus && !c.ispip { append(&out, c) }
	}
	return out[:]
}
