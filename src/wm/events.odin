// X event handlers (dwm's handler[] table) plus the EWMH root client messages.
//
// The X connection is shared with the bar and the desktop layer, so events
// on windows that are neither the root nor a managed client are left alone.
package wm

import xlib "vendor:x11/xlib"
import tx "../tx"

buttonpress :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	ev := &e.xbutton
	c := wintoclient(m, ev.window)
	if c == nil && ev.window != m.root { return false }
	click := Click.Root_Win
	// focus monitor if necessary
	if mon := wintomon(m, ev.window); mon != nil && mon != m.selmon {
		unfocus(m, m.selmon.sel, true)
		m.selmon = mon
		focus(m, nil)
	}
	if c != nil {
		focus(m, c)
		restack(m, m.selmon)
		// milk: a plain Button1 press near the edge of a picture-in-picture
		// window resizes it; anywhere else it is replayed to the application
		// (its controls, and its own drag-to-move via _NET_WM_MOVERESIZE).
		if c.ispip && ev.button == .Button1 && cleanmask(m, ev.state) == {} {
			if dir := pip_edge(c, ev.x, ev.y); dir >= 0 {
				xlib.AllowEvents(m.dpy, .AsyncBoth, xlib.CurrentTime)
				moveresize(m, c, dir, ev.x_root, ev.y_root, 1)
				return true
			}
		}
		xlib.AllowEvents(m.dpy, .ReplayPointer, xlib.CurrentTime)
		click = .Client_Win
	}
	for i in 0 ..< len(m.buttons) {
		b := m.buttons[i]
		if click == b.click && b.func != nil && b.button == u32(ev.button) &&
		   cleanmask(m, b.mask) == cleanmask(m, ev.state) {
			arg := b.arg
			b.func(m, &arg)
		}
	}
	return true
}

clientmessage :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	cme := &e.xclient
	a := &m.atoms
	if cme.message_type == a.net_current_desktop {
		// milk: switch to a desktop (bar dot clicks, `milk switch N`).
		index := cme.data.l[0]
		if index >= 0 && index < m.settings.tag_count {
			arg := Arg{ui = u32(1) << u32(index)}
			view(m, &arg)
		}
		return true
	}
	c := wintoclient(m, cme.window)
	if c == nil { return false }
	switch cme.message_type {
	case a.net_wm_state:
		fs := int(a.net_wm_state_fullscreen)
		if cme.data.l[1] == fs || cme.data.l[2] == fs {
			setfullscreen(m, c, cme.data.l[0] == 1 || // _NET_WM_STATE_ADD
			                    (cme.data.l[0] == 2 && !c.isfullscreen)) // _NET_WM_STATE_TOGGLE
		}
	case a.net_active_window:
		if is_focusable(c) {
			// milk: activate a client that is on screen (dwm only marks it urgent).
			focus(m, c)
			restack(m, c.mon)
		} else if c != m.selmon.sel && !c.isurgent {
			seturgent(m, c, true)
		}
	case a.net_close_window:
		kill_client(m, c)
	case a.net_wm_moveresize:
		// milk: client-side decorations and PiP windows hand their drags over.
		handle_moveresize_message(m, c, cme)
	case a.net_wm_desktop:
		if c.ispip { break } // picture-in-picture windows are on every desktop
		index := uint(cme.data.l[0]) & 0xFFFFFFFF
		newtags: u32
		if index == 0xFFFFFFFF {
			newtags = tagmask(m)
		} else if int(index) < m.settings.tag_count {
			newtags = u32(1) << u32(index)
		}
		if newtags != 0 && newtags != c.tags {
			c.tags = newtags
			focus(m, nil)
			arrange(m, c.mon)
		}
	}
	return true
}

configurerequest :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	ev := &e.xconfigurerequest
	mask := transmute(xlib.WindowChangesMask)i32(ev.value_mask & 0x7F)
	if c := wintoclient(m, ev.window); c != nil {
		if .CWWidth in mask { c.reqw = ev.width }
		if .CWHeight in mask { c.reqh = ev.height }
		if .CWBorderWidth in mask {
			c.bw = ev.border_width
		} else if c.isfloating || !has_arrange(cur_layout(m.selmon)) {
			mon := c.mon
			if .CWX in mask {
				c.oldx = c.x
				c.x = mon.mx + ev.x
			}
			if .CWY in mask {
				c.oldy = c.y
				c.y = mon.my + ev.y
			}
			if .CWWidth in mask {
				c.oldw = c.w
				c.w = ev.width
			}
			if .CWHeight in mask {
				c.oldh = c.h
				c.h = ev.height
			}
			if c.x + c.w > mon.mx + mon.mw && c.isfloating {
				c.x = mon.mx + (mon.mw / 2 - width(c) / 2) // center in x direction
			}
			if c.y + c.h > mon.my + mon.mh && c.isfloating {
				c.y = mon.my + (mon.mh / 2 - height(c) / 2) // center in y direction
			}
			if (.CWX in mask || .CWY in mask) && !(.CWWidth in mask || .CWHeight in mask) {
				configure(m, c)
			}
			if is_visible(c) {
				xlib.MoveResizeWindow(m.dpy, c.win, c.x, c.y, u32(max(c.w, 1)), u32(max(c.h, 1)))
				anim_sync_display(m, c)
			}
		} else {
			configure(m, c)
		}
	} else {
		wc: xlib.XWindowChanges
		wc.x = ev.x
		wc.y = ev.y
		wc.width = ev.width
		wc.height = ev.height
		wc.border_width = ev.border_width
		wc.sibling = ev.above
		wc.stack_mode = ev.detail
		xlib.ConfigureWindow(m.dpy, ev.window, mask, &wc)
	}
	xlib.Sync(m.dpy, false)
	return true
}

// Root size changes: re-read the monitors and re-arrange.
configurenotify :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	ev := &e.xconfigure
	if ev.window != m.root { return false }
	dirty := m.sw != ev.width || m.sh != ev.height
	m.sw = ev.width
	m.sh = ev.height
	if updategeom(m) || dirty {
		for mon := m.mons; mon != nil; mon = mon.next {
			for c := mon.clients; c != nil; c = c.next {
				if c.isfullscreen { resizeclient(m, c, mon.mx, mon.my, mon.mw, mon.mh) }
			}
		}
		focus(m, nil)
		arrange(m, nil)
	}
	return false // the desktop layer handles this event too
}

destroynotify :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	ev := &e.xdestroywindow
	c := wintoclient(m, ev.window)
	if c == nil { return false }
	unmanage(m, c, true)
	return true
}

// Focus follows the mouse (wm.focusFollowsMouse).
enternotify :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	if !m.settings.focus_follows_mouse { return false }
	ev := &e.xcrossing
	if (ev.mode != .NotifyNormal || ev.detail == .NotifyInferior) && ev.window != m.root { return false }
	c := wintoclient(m, ev.window)
	if c == nil && ev.window != m.root { return false }
	mon := c != nil ? c.mon : wintomon(m, ev.window)
	if mon != m.selmon {
		unfocus(m, m.selmon.sel, true)
		m.selmon = mon
	} else if c == nil || c == m.selmon.sel {
		return false
	}
	focus(m, c)
	return true
}

// There are some broken focus acquiring clients needing extra handling.
focusin :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	ev := &e.xfocus
	if wintoclient(m, ev.window) == nil { return false }
	if m.selmon.sel != nil && ev.window != m.selmon.sel.win { setfocus(m, m.selmon.sel) }
	return true
}

keypress :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	ev := &e.xkey
	keysym := xlib.KeycodeToKeysym(m.dpy, xlib.KeyCode(ev.keycode), 0)
	state := cleanmask(m, ev.state)
	matched := false
	for i in 0 ..< len(m.keys) {
		k := m.keys[i]
		if keysym == k.keysym && cleanmask(m, k.mod) == state && k.func != nil {
			arg := k.arg
			k.func(m, &arg)
			matched = true
		}
	}
	return matched
}

mappingnotify :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	ev := &e.xmapping
	xlib.RefreshKeyboardMapping(ev)
	if ev.request == .MappingKeyboard { grabkeys(m) }
	return false
}

maprequest :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	ev := &e.xmaprequest
	wa: xlib.XWindowAttributes
	if xlib.GetWindowAttributes(m.dpy, ev.window, &wa) == 0 || wa.override_redirect { return false }
	if wintoclient(m, ev.window) != nil { return true }
	if is_milk_window(m, ev.window) {
		// milk's own managed-style windows (e.g. the bar in dock mode) are
		// mapped as they are, never managed.
		xlib.MapWindow(m.dpy, ev.window)
		return true
	}
	manage(m, ev.window, &wa, false)
	return true
}

// Moving the pointer over the root window onto another monitor selects it.
motionnotify :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	ev := &e.xmotion
	if ev.window != m.root { return false }
	mon := recttomon(m, ev.x_root, ev.y_root, 1, 1)
	if mon != m.motion_mon && m.motion_mon != nil && m.settings.focus_follows_mouse {
		unfocus(m, m.selmon.sel, true)
		m.selmon = mon
		focus(m, nil)
	}
	m.motion_mon = mon
	return false
}

propertynotify :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	ev := &e.xproperty
	if ev.window == m.root || ev.state == .PropertyDelete { return false }
	c := wintoclient(m, ev.window)
	if c == nil { return false }
	switch ev.atom {
	case xlib.XA_WM_TRANSIENT_FOR:
		trans: xlib.Window
		if !c.isfloating && status_ok(xlib.GetTransientForHint(m.dpy, c.win, &trans)) {
			c.isfloating = wintoclient(m, trans) != nil
			if c.isfloating { arrange(m, c.mon) }
		}
	case xlib.XA_WM_NORMAL_HINTS:
		c.hintsvalid = false
		// milk: GTK dialogs map first and declare a fixed size (min == max)
		// afterwards; float them as dwm floats windows that are fixed at map time.
		if !c.isfloating && !c.isfullscreen {
			updatesizehints(m, c)
			if c.isfixed {
				c.isfloating = true
				c.w = c.maxw
				c.h = c.maxh
				place_floating(m, c, nil)
				resizeclient(m, c, c.x, c.y, c.w, c.h)
				xlib.RaiseWindow(m.dpy, c.win)
				arrange(m, c.mon)
			}
		}
	case xlib.XA_WM_HINTS:
		updatewmhints(m, c)
	}
	if ev.atom == tx.ATOM_WM_NAME || ev.atom == m.atoms.net_wm_name {
		updatetitle(m, c)
		// Browsers may title their PiP window only after mapping it.
		if !c.ispip && detect_pip(m, c) { pip_apply(m, c, false, false) }
	}
	if ev.atom == m.atoms.net_wm_window_type { updatewindowtype(m, c) }
	return true
}

unmapnotify :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	ev := &e.xunmap
	c := wintoclient(m, ev.window)
	if c == nil { return false }
	if ev.send_event {
		setclientstate(m, c, .WithdrawnState)
	} else {
		unmanage(m, c, false)
	}
	return true
}
