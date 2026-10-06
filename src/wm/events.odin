// X event handlers (dwm's handler[] table) plus the EWMH root client messages.
//
// The X connection is shared with the bar and the desktop layer, so events
// on windows that are neither the root nor a managed client are left alone.
package wm

import "core:log"
import xlib "vendor:x11/xlib"
import tx "../tx"

buttonpress :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	ev := &e.xbutton
	c := wintoclient(m, ev.window)
	if c == nil && ev.window != m.root { return false }
	m.ev_ctx = Action_Ctx{x = ev.x_root, y = ev.y_root, time = ev.time, button = u32(ev.button), state = ev.state}
	m.ev_client = c
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
	} else if m.settings.floating && ev.button == .Button1 && cleanmask(m, ev.state) == {} && m.selmon.sel != nil {
		// milk: a click on the empty desktop takes the focus from the windows,
		// as in openbox (the desktop icons then get the keyboard).
		unfocus(m, m.selmon.sel, true)
		m.selmon.sel = nil
	}
	for i in 0 ..< len(m.buttons) {
		b := m.buttons[i]
		if click == b.click && b.func != nil && b.button == u32(ev.button) &&
		   cleanmask(m, b.mask) == cleanmask(m, ev.state) {
			arg := b.arg
			b.func(m, &arg)
			break // one action per click: a user binding replaces the default with the same button
		}
	}
	m.ev_client = nil
	return true
}

clientmessage :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	cme := &e.xclient
	a := &m.atoms
	// milk tray: an application asks milk's system tray (the bar) to dock a
	// window it had mapped as a normal one first: let it go before the tray,
	// which sees this event next, takes it.
	if cme.message_type == tx.atom(m.c, "_NET_SYSTEM_TRAY_OPCODE") && cme.data.l[1] == 0 {
		if c := wintoclient(m, xlib.Window(cme.data.l[2])); c != nil {
			log.debugf("wm: 0x%x asks to dock in the tray; releasing it", c.win)
			unmanage(m, c, false)
			arrange(m, nil)
		}
		return false // the tray handles the request itself
	}
	switch cme.message_type {
	case a.net_current_desktop:
		// milk: switch to a desktop (bar dot clicks, `milk switch N`).
		index := cme.data.l[0]
		if index >= 0 && index < m.settings.tag_count {
			arg := Arg{ui = u32(1) << u32(index)}
			view(m, &arg)
		}
		return true
	case a.net_showing_desktop:
		set_showing_desktop(m, cme.data.l[0] != 0)
		return true
	case a.net_request_frame_extents:
		// Before mapping: the extents the window will get.
		if wintoclient(m, cme.window) == nil {
			ext: [4]uint
			if m.settings.floating {
				b, t := uint(m.settings.border_width), uint(m.settings.title_height)
				ext = {b, b, b + t, b}
				probe := Client{win = cme.window}
				if motif_undecorated(m, &probe) { ext = {} }
			}
			xlib.ChangeProperty(m.dpy, cme.window, a.net_frame_extents, tx.ATOM_CARDINAL, 32, xlib.PropModeReplace, &ext[0], 4)
		}
		return true
	case a.milk_window_menu:
		// The bar's task list: the menu of a window at a point.
		target := wintoclient(m, xlib.Window(uint(cme.data.l[0])))
		if target == nil { target = wintoclient(m, cme.window) }
		if target != nil {
			run_action(m, "window-menu", target, {x = i32(cme.data.l[1]), y = i32(cme.data.l[2]), time = xlib.Time(uint(cme.data.l[3]))})
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
		handle_state_message(m, c, cme.data.l[0], {xlib.Atom(uint(cme.data.l[1])), xlib.Atom(uint(cme.data.l[2]))})
	case a.wm_change_state:
		// ICCCM: a client (or a task list) iconifies the window.
		if cme.data.l[0] == int(xlib.WMHintState.IconicState) { set_minimized(m, c, true) }
	case a.net_active_window:
		if c.minimized || (cme.data.l[0] == 2 && !on_current_tags(c)) {
			// milk: a pager or task list brings the window forward from anywhere.
			activate_client(m, c)
		} else if is_focusable(c) {
			// milk: activate a client that is on screen (dwm only marks it urgent).
			focus(m, c)
			restack(m, c.mon)
		} else if c != m.selmon.sel && !c.isurgent {
			seturgent(m, c, true)
			frame_paint(m, c)
		}
	case a.net_close_window:
		kill_client(m, c)
	case a.net_wm_moveresize:
		// milk: client-side decorations and PiP windows hand their drags over.
		handle_moveresize_message(m, c, cme)
	case a.net_wm_desktop:
		if c.ispip { break } // picture-in-picture windows are on every desktop
		index := uint(cme.data.l[0]) & 0xFFFFFFFF
		if index == 0xFFFFFFFF {
			set_sticky(m, c, true)
			break
		}
		if int(index) < m.settings.tag_count {
			if c.sticky { set_sticky(m, c, false) }
			newtags := u32(1) << u32(index)
			if newtags != c.tags {
				c.tags = newtags
				focus(m, nil)
				arrange(m, c.mon)
			}
		}
	case a.net_moveresize_window:
		// Pagers and scripts (xdotool, wmctrl): gravity bits 8..11 name the fields given.
		flags := uint(cme.data.l[0])
		if !is_free(m, c) { break }
		x, y, w, h := c.x, c.y, c.w, c.h
		if flags & (1 << 8) != 0 { x = i32(cme.data.l[1]) }
		if flags & (1 << 9) != 0 { y = i32(cme.data.l[2]) }
		if flags & (1 << 10) != 0 { w = i32(cme.data.l[3]) }
		if flags & (1 << 11) != 0 { h = i32(cme.data.l[4]) }
		resize(m, c, x, y, w, h, false)
	}
	return true
}

configurerequest :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	ev := &e.xconfigurerequest
	mask := transmute(xlib.WindowChangesMask)i32(ev.value_mask & 0x7F)
	if c := wintoclient(m, ev.window); c != nil {
		if .CWWidth in mask { c.reqw = ev.width }
		if .CWHeight in mask { c.reqh = ev.height }
		if c.frame != 0 && (c.max_horz || c.max_vert || c.snapped != .None || c.isfullscreen) {
			// milk: a maximized, snapped or fullscreen window keeps its place.
			configure(m, c)
		} else if .CWBorderWidth in mask && c.frame == 0 {
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
			if (.CWX in mask || .CWY in mask) && !(.CWWidth in mask || .CWHeight in mask) || c.frame != 0 {
				configure(m, c)
			}
			if is_visible(c) { anim_snap(m, c) }
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
	overview_finish(m) // its monitor may be gone
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

// Focus follows the mouse (wm.focusFollowsMouse); wm.raiseOnFocus raises too.
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
	if c != nil && m.settings.raise_on_focus { restack(m, c.mon) }
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
	m.ev_ctx = Action_Ctx{x = ev.x_root, y = ev.y_root, time = ev.time, state = ev.state}
	// milk: Super on its own runs its binding when it is released (keyrelease).
	// Its grab holds the keyboard while Super is down, so the keys pressed
	// with it come here too and cancel the tap.
	if tap := tap_sym(keysym); tap != NO_KEY {
		if m.tap_key != tap { // a repeat keeps the time of the first press
			m.tap_key = state == {} && tap_binding(m, tap) != nil ? tap : NO_KEY
			m.tap_time = ev.time
		}
		return m.tap_key != NO_KEY
	}
	m.tap_key = NO_KEY
	for i in 0 ..< len(m.keys) {
		k := m.keys[i]
		if keysym == k.keysym && cleanmask(m, k.mod) == state && k.func != nil {
			arg := k.arg
			k.func(m, &arg)
			return true // one action per key: a user binding replaces the default with the same keys
		}
	}
	return false
}

// Super released after a press with nothing else in between: run its binding.
keyrelease :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	ev := &e.xkey
	tap := tap_sym(xlib.KeycodeToKeysym(m.dpy, xlib.KeyCode(ev.keycode), 0))
	if tap == NO_KEY || tap != m.tap_key { return false }
	// An auto-repeat is a release followed by a press with the same time.
	if xlib.Pending(m.dpy) > 0 {
		next: xlib.XEvent
		xlib.PeekEvent(m.dpy, &next)
		if next.type == .KeyPress && next.xkey.keycode == ev.keycode && next.xkey.time == ev.time { return true }
	}
	m.tap_key = NO_KEY
	if ev.time < m.tap_time || ev.time - m.tap_time > TAP_MAX_MS { return true } // held, not tapped
	if k := tap_binding(m, tap); k != nil {
		m.ev_ctx = Action_Ctx{x = ev.x_root, y = ev.y_root, time = ev.time, state = ev.state}
		arg := k.arg
		k.func(m, &arg)
	}
	return true
}

// How long Super may be held for a tap, milliseconds.
TAP_MAX_MS :: 1000
NO_KEY     :: xlib.KeySym(0)

// The key a modifier stands for when it is bound on its own (both Super keys
// are "super"); 0 for the others.
tap_sym :: proc(sym: xlib.KeySym) -> xlib.KeySym {
	#partial switch sym {
	case .XK_Super_L, .XK_Super_R: return .XK_Super_L
	}
	return NO_KEY
}

// The binding of a modifier on its own.
tap_binding :: proc(m: ^Manager, tap: xlib.KeySym) -> ^Key {
	for &k in m.keys {
		if k.keysym == tap && k.mod == {} && k.func != nil { return &k }
	}
	return nil
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
	if is_tray_icon(m, ev.window) { return true } // milk tray: the bar's system tray maps it
	if is_milk_window(m, ev.window) {
		// milk's own managed-style windows (e.g. the bar in dock mode) are
		// mapped as they are, never managed.
		xlib.MapWindow(m.dpy, ev.window)
		return true
	}
	manage(m, ev.window, &wa, false)
	return true
}

// milk tray: an XEmbed tray icon is never managed. An application asks to
// dock before mapping its icon, so by the time its map request is handled the
// tray has reparented the window into the bar: it is no longer a child of
// the root. (_XEMBED_INFO alone says nothing: Qt puts it on every top-level
// window.) An icon mapped before its dock request is released when the
// request comes (clientmessage).
is_tray_icon :: proc(m: ^Manager, w: xlib.Window) -> bool {
	root, parent: xlib.Window
	children: [^]xlib.Window
	n: u32
	if xlib.QueryTree(m.dpy, w, &root, &parent, &children, &n) == xlib.Status(0) { return false }
	if children != nil { xlib.Free(children) }
	return parent != m.root
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
	if ev.window == m.root && ev.state == .PropertyNewValue && ev.atom == tx.atom(m.c, MILK_ACTION) {
		run_requested_actions(m, ev.time)
		return true
	}
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
		frame_paint(m, c)
	}
	if ev.atom == tx.ATOM_WM_NAME || ev.atom == m.atoms.net_wm_name {
		updatetitle(m, c)
		// Browsers may title their PiP window only after mapping it.
		if !c.ispip && detect_pip(m, c) { pip_apply(m, c, false, false) }
		frame_paint(m, c)
	}
	if ev.atom == m.atoms.net_wm_window_type { updatewindowtype(m, c) }
	if c.frame != 0 {
		switch ev.atom {
		case m.atoms.net_wm_icon:
			load_icon(m, c)
			frame_paint(m, c)
		case m.atoms.motif_wm_hints:
			// Browsers switch between their own title bar and the system's.
			nodecor := motif_undecorated(m, c)
			if nodecor != c.nodecor {
				c.nodecor = nodecor
				frame_refresh(m, c)
				apply_corners(m, c)
			}
		}
	}
	return true
}

unmapnotify :: proc(m: ^Manager, e: ^xlib.XEvent) -> bool {
	ev := &e.xunmap
	c := wintoclient(m, ev.window)
	if c == nil || ev.window != c.win { return false }
	if ev.send_event {
		setclientstate(m, c, .WithdrawnState)
	} else if ev.event == ev.window {
		// Each unmap is reported to the client window and to its parent (the
		// root or the frame); acting on the client's own report handles it once.
		unmanage(m, c, false)
	}
	return true
}
