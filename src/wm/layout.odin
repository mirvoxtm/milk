// Layouts and stacking: dwm's arrange, tile (with an optional uniform gap),
// monocle, showhide and restack.
package wm

import "base:runtime"
import xlib "vendor:x11/xlib"

// Show/hide the clients and re-apply the layout of one monitor (or all).
arrange :: proc(m: ^Manager, mon: ^Monitor) {
	if mon != nil {
		showhide(m, mon.stack)
	} else {
		for it := m.mons; it != nil; it = it.next { showhide(m, it.stack) }
	}
	if mon != nil {
		arrangemon(m, mon)
		restack(m, mon)
	} else {
		for it := m.mons; it != nil; it = it.next { arrangemon(m, it) }
	}
}

arrangemon :: proc(m: ^Manager, mon: ^Monitor) {
	switch cur_layout(mon) {
	case .Tile:    tile(m, mon)
	case .Monocle: monocle(m, mon)
	case .Float:
	}
}

// Master/stack tiling. With gaps == 0 this is exactly dwm's tile(); otherwise
// every tiled window is separated from its neighbours and from the edges of
// the window area by `gaps` pixels.
tile :: proc(m: ^Manager, mon: ^Monitor) {
	n: i32 = 0
	for c := nexttiled(mon.clients); c != nil; c = nexttiled(c.next) { n += 1 }
	if n == 0 { return }
	g := m.settings.gaps

	mw: i32
	if n > mon.nmaster {
		mw = mon.nmaster > 0 ? i32(f32(mon.ww - 3 * g) * mon.mfact) : 0
	} else {
		mw = mon.ww - 2 * g
	}
	stack_x := mon.wx + g + (mw > 0 ? mw + g : 0)
	stack_w := mon.ww - 2 * g - (mw > 0 ? mw + g : 0)

	i: i32 = 0
	my, ty := g, g
	for c := nexttiled(mon.clients); c != nil; c = nexttiled(c.next) {
		if i < mon.nmaster {
			rest := min(n, mon.nmaster) - i
			h := (mon.wh - my - rest * g) / rest
			resize(m, c, mon.wx + g, mon.wy + my, mw - ext_w(c), h - ext_h(c), false)
			if my + height(c) + g < mon.wh { my += height(c) + g }
		} else {
			rest := n - i
			h := (mon.wh - ty - rest * g) / rest
			resize(m, c, stack_x, mon.wy + ty, stack_w - ext_w(c), h - ext_h(c), false)
			if ty + height(c) + g < mon.wh { ty += height(c) + g }
		}
		i += 1
	}
}

// Every tiled client fills the window area (minus the gap).
monocle :: proc(m: ^Manager, mon: ^Monitor) {
	g := m.settings.gaps
	for c := nexttiled(mon.clients); c != nil; c = nexttiled(c.next) {
		resize(m, c, mon.wx + g, mon.wy + g, mon.ww - 2 * g - ext_w(c), mon.wh - 2 * g - ext_h(c), false)
	}
}

// Move visible clients on screen (top down) and hidden ones off screen
// (bottom up), along the focus stack.
showhide :: proc(m: ^Manager, c: ^Client) {
	if c == nil { return }
	if is_visible(c) {
		if !c.animating {
			frame_move(m, c, c.x, c.y)
			anim_sync_display(m, c)
		}
		if (!has_arrange(cur_layout(c.mon)) || c.isfloating) && !c.isfullscreen &&
		   c.kind != .Dock && c.kind != .Desktop { // docks and desktops keep their own geometry
			resize(m, c, c.x, c.y, c.w, c.h, false)
		}
		showhide(m, c.snext)
	} else {
		showhide(m, c.snext)
		if c.animating { anim_snap(m, c) }
		frame_move(m, c, width(c) * -2, c.y)
		c.disp_valid = false
	}
}

// Raise the selected floating client and stack the tiled ones in focus order.
// dwm stacks tiled clients right below its bar window; milk has no such
// window in the WM, so the (unmapped) _NET_SUPPORTING_WM_CHECK window plays
// that role: it is created on top of the stack, floating clients are raised
// above it and tiled clients are kept below it. milk: in the floating mode,
// "always on top" windows stay above the others and "always below" ones under
// them (most recently focused first within a layer).
restack :: proc(m: ^Manager, mon: ^Monitor) {
	if mon == nil || mon.sel == nil { return }
	sel := mon.sel
	if (sel.isfloating || !has_arrange(cur_layout(mon))) && sel.layer != .Below {
		xlib.RaiseWindow(m.dpy, top_window(sel))
		// Its dialogs stay above it.
		for c := mon.clients; c != nil; c = c.next {
			if c.transient_for == sel.win && is_visible(c) { xlib.RaiseWindow(m.dpy, top_window(c)) }
		}
	}
	if m.settings.floating {
		// Raised least recent first: the most recent ends up on top of its layer.
		above := make([dynamic]^Client, context.temp_allocator)
		for c := mon.stack; c != nil; c = c.snext {
			if c.layer == .Above && is_visible(c) { append(&above, c) }
		}
		#reverse for c in above { xlib.RaiseWindow(m.dpy, top_window(c)) }
		for c := mon.stack; c != nil; c = c.snext {
			if c.layer == .Below && is_visible(c) { xlib.LowerWindow(m.dpy, top_window(c)) }
		}
		for c := mon.clients; c != nil; c = c.next {
			if c.kind == .Desktop { xlib.LowerWindow(m.dpy, c.win) }
		}
		if sel.isfullscreen { xlib.RaiseWindow(m.dpy, top_window(sel)) }
	}
	// milk: docks and popups (splash, notification, tooltip) never take the
	// selection, and picture-in-picture windows float over everything, so keep
	// them above the selection, unless the selection is fullscreen.
	if !sel.isfullscreen {
		for c := mon.stack; c != nil; c = c.snext {
			if (c.kind == .Dock || c.kind == .Popup || c.ispip) && is_visible(c) { xlib.RaiseWindow(m.dpy, c.win) }
		}
	}
	if has_arrange(cur_layout(mon)) {
		wc: xlib.XWindowChanges
		wc.stack_mode = .Below
		wc.sibling = m.wmcheckwin
		for c := mon.stack; c != nil; c = c.snext {
			if !c.isfloating && is_visible(c) {
				xlib.ConfigureWindow(m.dpy, top_window(c), {.CWSibling, .CWStackMode}, &wc)
				wc.sibling = top_window(c)
			}
		}
	}
	grips_restack(m)
	overview_raise(m) // milk: the overview stays above the windows it shows
	xlib.Sync(m.dpy, false)
	discard_enter_events(m)
	m.ewmh.stacking_dirty = true
}

// Drop the EnterNotify events caused by restacking (dwm: XCheckMaskEvent with
// EnterWindowMask). Only the crossings dwm itself would act on (root and
// managed clients) are removed: the connection is shared with the bar and the
// desktop layer, whose windows keep their events.
discard_enter_events :: proc(m: ^Manager) {
	ev: xlib.XEvent
	for xlib.CheckIfEvent(m.dpy, &ev, enter_predicate, m) {}
}

@(private)
enter_predicate :: proc "c" (_: ^xlib.Display, ev: ^xlib.XEvent, arg: rawptr) -> b32 {
	context = runtime.default_context()
	if ev.type != .EnterNotify { return false }
	m := (^Manager)(arg)
	w := ev.xcrossing.window
	return b32(w == m.root || wintoclient(m, w) != nil)
}
