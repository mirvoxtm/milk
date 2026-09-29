// Actions bound to keys and buttons (dwm's focus handling, tags, layouts,
// mouse move/resize, spawn, quit) plus the milk additions (reload,
// fullscreen toggle).
package wm

import xlib "vendor:x11/xlib"

// Give the selection and the input focus to `c`, or to the most recently
// focused visible client of the selected monitor when `c` is nil/hidden.
// milk: picture-in-picture windows are on every tag, so they are only chosen
// that way when nothing else is on screen (a tag switch must not land on them).
focus :: proc(m: ^Manager, client: ^Client) {
	c := client
	if c == nil || !is_focusable(c) {
		c = m.selmon.stack
		for c != nil && (!is_focusable(c) || c.ispip) { c = c.snext }
		if c == nil {
			c = m.selmon.stack
			for c != nil && !is_focusable(c) { c = c.snext }
		}
	}
	if m.selmon.sel != nil && m.selmon.sel != c { unfocus(m, m.selmon.sel, false) }
	if c != nil {
		if c.mon != m.selmon { m.selmon = c.mon }
		if c.isurgent { seturgent(m, c, false) }
		detachstack(c)
		attachstack(c)
		grabbuttons(m, c, true)
		xlib.SetWindowBorder(m.dpy, c.win, m.pixel[.Sel])
		setfocus(m, c)
	} else {
		xlib.SetInputFocus(m.dpy, m.root, .RevertToPointerRoot, xlib.CurrentTime)
		xlib.DeleteProperty(m.dpy, m.root, m.atoms.net_active_window)
	}
	m.selmon.sel = c
}

unfocus :: proc(m: ^Manager, c: ^Client, setfocus_root: bool) {
	if c == nil { return }
	grabbuttons(m, c, false)
	xlib.SetWindowBorder(m.dpy, c.win, m.pixel[.Norm])
	if setfocus_root {
		xlib.SetInputFocus(m.dpy, m.root, .RevertToPointerRoot, xlib.CurrentTime)
		xlib.DeleteProperty(m.dpy, m.root, m.atoms.net_active_window)
	}
}

focusmon :: proc(m: ^Manager, arg: ^Arg) {
	if m.mons.next == nil { return }
	mon := dirtomon(m, arg.i)
	if mon == m.selmon { return }
	unfocus(m, m.selmon.sel, false)
	m.selmon = mon
	focus(m, nil)
}

focusstack :: proc(m: ^Manager, arg: ^Arg) {
	sel := m.selmon.sel
	if sel == nil || (sel.isfullscreen && LOCK_FULLSCREEN) { return }
	c: ^Client
	if arg.i > 0 {
		c = sel.next
		for c != nil && !is_focusable(c) { c = c.next }
		if c == nil {
			c = m.selmon.clients
			for c != nil && !is_focusable(c) { c = c.next }
		}
	} else {
		i := m.selmon.clients
		for ; i != sel; i = i.next {
			if is_focusable(i) { c = i }
		}
		if c == nil {
			for ; i != nil; i = i.next {
				if is_focusable(i) { c = i }
			}
		}
	}
	if c != nil {
		focus(m, c)
		restack(m, m.selmon)
	}
}

incnmaster :: proc(m: ^Manager, arg: ^Arg) {
	m.selmon.nmaster = max(m.selmon.nmaster + i32(arg.i), 0)
	arrange(m, m.selmon)
}

killclient :: proc(m: ^Manager, arg: ^Arg) {
	kill_client(m, m.selmon.sel)
}

// Move the selected client to the top of the tiling order (the master area).
zoom :: proc(m: ^Manager, arg: ^Arg) {
	c := m.selmon.sel
	if !has_arrange(cur_layout(m.selmon)) || c == nil || c.isfloating { return }
	if c == nexttiled(m.selmon.clients) {
		c = nexttiled(c.next)
		if c == nil { return }
	}
	pop(m, c)
}

pop :: proc(m: ^Manager, c: ^Client) {
	detach(c)
	attach(c)
	focus(m, c)
	arrange(m, c.mon)
}

quit :: proc(m: ^Manager, arg: ^Arg) {
	m.quit = true
}

// milk addition (Mod+v, Mod+n): ask the main loop to open a panel
// (arg.cmd = "clipboard" or "notifications").
open_panel :: proc(m: ^Manager, arg: ^Arg) {
	m.panel_request = arg.cmd
}

// milk addition (Mod+Shift+r): ask the main loop to reload milk.json.
reload_config :: proc(m: ^Manager, arg: ^Arg) {
	m.reload = true
}

setlayout :: proc(m: ^Manager, arg: ^Arg) {
	mon := m.selmon
	if arg == nil || !arg.has_lt || arg.lt != mon.lt[mon.sellt] { mon.sellt ~= 1 }
	if arg != nil && arg.has_lt { mon.lt[mon.sellt] = arg.lt }
	if mon.sel != nil { arrange(m, mon) }
}

// arg.f < 1.0 is added to mfact; arg.f > 1.0 sets mfact to arg.f - 1.0.
setmfact :: proc(m: ^Manager, arg: ^Arg) {
	if arg == nil || !has_arrange(cur_layout(m.selmon)) { return }
	f := arg.f < 1.0 ? arg.f + m.selmon.mfact : arg.f - 1.0
	if f < 0.05 || f > 0.95 { return }
	m.selmon.mfact = f
	arrange(m, m.selmon)
}

spawn :: proc(m: ^Manager, arg: ^Arg) {
	spawn_command(m, arg.cmd)
}

tag :: proc(m: ^Manager, arg: ^Arg) {
	sel := m.selmon.sel
	mask := tagmask(m)
	if sel != nil && !sel.ispip && arg.ui & mask != 0 { // PiP windows stay on every tag
		sel.tags = arg.ui & mask
		focus(m, nil)
		arrange(m, m.selmon)
	}
}

tagmon :: proc(m: ^Manager, arg: ^Arg) {
	if m.selmon.sel == nil || m.mons.next == nil { return }
	sendmon(m, m.selmon.sel, dirtomon(m, arg.i))
}

// Move a client to another monitor, on that monitor's current tags.
sendmon :: proc(m: ^Manager, c: ^Client, mon: ^Monitor) {
	if c.mon == mon { return }
	unfocus(m, c, true)
	detach(c)
	detachstack(c)
	c.mon = mon
	c.tags = c.ispip ? tagmask(m) : mon.tagset[mon.seltags] // assign tags of target monitor
	attach(c)
	attachstack(c)
	focus(m, nil)
	arrange(m, nil)
}

togglefloating :: proc(m: ^Manager, arg: ^Arg) {
	sel := m.selmon.sel
	if sel == nil { return }
	if sel.isfullscreen { return } // no support for fullscreen windows
	if sel.ispip { return }        // picture-in-picture windows always float
	sel.isfloating = !sel.isfloating || sel.isfixed
	if sel.isfloating { resize(m, sel, sel.x, sel.y, sel.w, sel.h, false) }
	arrange(m, m.selmon)
}

// milk addition (Mod+Shift+f): toggle fullscreen on the selected client.
togglefullscreen :: proc(m: ^Manager, arg: ^Arg) {
	if sel := m.selmon.sel; sel != nil { setfullscreen(m, sel, !sel.isfullscreen) }
}

toggletag :: proc(m: ^Manager, arg: ^Arg) {
	sel := m.selmon.sel
	if sel == nil || sel.ispip { return } // PiP windows stay on every tag
	newtags := sel.tags ~ (arg.ui & tagmask(m))
	if newtags != 0 {
		sel.tags = newtags
		focus(m, nil)
		arrange(m, m.selmon)
	}
}

toggleview :: proc(m: ^Manager, arg: ^Arg) {
	mon := m.selmon
	newtagset := mon.tagset[mon.seltags] ~ (arg.ui & tagmask(m))
	if newtagset != 0 {
		mon.tagset[mon.seltags] = newtagset
		focus(m, nil)
		arrange(m, mon)
	}
}

// View the given tags; arg.ui == 0 (Mod+Tab) returns to the previous tagset.
view :: proc(m: ^Manager, arg: ^Arg) {
	mon := m.selmon
	mask := tagmask(m)
	if arg.ui & mask == mon.tagset[mon.seltags] { return }
	mon.seltags ~= 1 // toggle sel tagset
	if arg.ui & mask != 0 { mon.tagset[mon.seltags] = arg.ui & mask }
	focus(m, nil)
	arrange(m, mon)
}

// Drag the selected client with the pointer (Mod+Button1).
movemouse :: proc(m: ^Manager, arg: ^Arg) {
	c := m.selmon.sel
	if c == nil { return }
	if c.isfullscreen { return } // no support moving fullscreen windows by mouse
	restack(m, m.selmon)
	ocx, ocy := c.x, c.y
	if xlib.GrabPointer(m.dpy, m.root, false, MOUSEMASK, .GrabModeAsync, .GrabModeAsync,
	                    0, m.cursor[.Move], xlib.CurrentTime) != GRAB_SUCCESS { return }
	x, y, ok := getrootptr(m)
	if !ok {
		xlib.UngrabPointer(m.dpy, xlib.CurrentTime)
		return
	}
	lasttime: xlib.Time
	ev: xlib.XEvent
	for {
		xlib.MaskEvent(m.dpy, MOUSEMASK + {.SubstructureRedirect}, &ev)
		#partial switch ev.type {
		case .ConfigureRequest:
			configurerequest(m, &ev)
		case .MapRequest:
			maprequest(m, &ev)
		case .MotionNotify:
			if ev.xmotion.window != m.root { continue }
			if ev.xmotion.time - lasttime <= 1000 / 60 { continue }
			lasttime = ev.xmotion.time

			sm := m.selmon
			nx := ocx + (ev.xmotion.x - x)
			ny := ocy + (ev.xmotion.y - y)
			if abs(sm.wx - nx) < SNAP {
				nx = sm.wx
			} else if abs((sm.wx + sm.ww) - (nx + width(c))) < SNAP {
				nx = sm.wx + sm.ww - width(c)
			}
			if abs(sm.wy - ny) < SNAP {
				ny = sm.wy
			} else if abs((sm.wy + sm.wh) - (ny + height(c))) < SNAP {
				ny = sm.wy + sm.wh - height(c)
			}
			if !c.isfloating && has_arrange(cur_layout(sm)) && (abs(nx - c.x) > SNAP || abs(ny - c.y) > SNAP) {
				togglefloating(m, nil)
			}
			if !has_arrange(cur_layout(sm)) || c.isfloating { resize(m, c, nx, ny, c.w, c.h, true) }
		}
		if ev.type == .ButtonRelease { break }
	}
	xlib.UngrabPointer(m.dpy, xlib.CurrentTime)
	if mon := recttomon(m, c.x, c.y, c.w, c.h); mon != m.selmon {
		sendmon(m, c, mon)
		m.selmon = mon
		focus(m, nil)
	}
	m.ewmh.stacking_dirty = true
}

// Resize the selected client from its bottom-right corner (Mod+Button3).
resizemouse :: proc(m: ^Manager, arg: ^Arg) {
	c := m.selmon.sel
	if c == nil { return }
	if c.isfullscreen { return } // no support resizing fullscreen windows by mouse
	restack(m, m.selmon)
	ocx, ocy := c.x, c.y
	if xlib.GrabPointer(m.dpy, m.root, false, MOUSEMASK, .GrabModeAsync, .GrabModeAsync,
	                    0, m.cursor[.Resize], xlib.CurrentTime) != GRAB_SUCCESS { return }
	xlib.WarpPointer(m.dpy, 0, c.win, 0, 0, 0, 0, c.w + c.bw - 1, c.h + c.bw - 1)
	lasttime: xlib.Time
	ev: xlib.XEvent
	for {
		xlib.MaskEvent(m.dpy, MOUSEMASK + {.SubstructureRedirect}, &ev)
		#partial switch ev.type {
		case .ConfigureRequest:
			configurerequest(m, &ev)
		case .MapRequest:
			maprequest(m, &ev)
		case .MotionNotify:
			if ev.xmotion.window != m.root { continue }
			if ev.xmotion.time - lasttime <= 1000 / 60 { continue }
			lasttime = ev.xmotion.time

			sm := m.selmon
			nw := max(ev.xmotion.x - ocx - 2 * c.bw + 1, 1)
			nh := max(ev.xmotion.y - ocy - 2 * c.bw + 1, 1)
			if c.mon.wx + nw >= sm.wx && c.mon.wx + nw <= sm.wx + sm.ww &&
			   c.mon.wy + nh >= sm.wy && c.mon.wy + nh <= sm.wy + sm.wh {
				if !c.isfloating && has_arrange(cur_layout(sm)) && (abs(nw - c.w) > SNAP || abs(nh - c.h) > SNAP) {
					togglefloating(m, nil)
				}
			}
			if !has_arrange(cur_layout(sm)) || c.isfloating { resize(m, c, c.x, c.y, nw, nh, true) }
		}
		if ev.type == .ButtonRelease { break }
	}
	xlib.WarpPointer(m.dpy, 0, c.win, 0, 0, 0, 0, c.w + c.bw - 1, c.h + c.bw - 1)
	xlib.UngrabPointer(m.dpy, xlib.CurrentTime)
	discard_enter_events(m)
	if mon := recttomon(m, c.x, c.y, c.w, c.h); mon != m.selmon {
		sendmon(m, c, mon)
		m.selmon = mon
		focus(m, nil)
	}
	m.ewmh.stacking_dirty = true
}

GRAB_SUCCESS :: 0
