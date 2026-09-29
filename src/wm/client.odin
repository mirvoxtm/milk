// Clients: dwm's manage/unmanage, rules, ICCCM hints (size hints, WM_HINTS,
// WM_PROTOCOLS, WM_STATE, WM_TRANSIENT_FOR), window types, fullscreen and the
// resize path (applysizehints/resize/resizeclient/configure).
package wm

import "core:log"
import "core:slice"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "../tx"

// XTextProperty with the C layout (the binding declares `format` as a long).
@(private)
Text_Property :: struct {
	value:    [^]u8,
	encoding: xlib.Atom,
	format:   i32,
	nitems:   uint,
}

foreign import xlib_text "system:X11"
@(default_calling_convention = "c")
foreign xlib_text {
	@(link_name = "XGetTextProperty")
	x_get_text_property :: proc(dpy: ^xlib.Display, w: xlib.Window, prop: ^Text_Property, atom: xlib.Atom) -> i32 ---
	@(link_name = "Xutf8TextPropertyToTextList")
	x_utf8_text_property_to_text_list :: proc(dpy: ^xlib.Display, prop: ^Text_Property, list: ^[^]cstring, count: ^i32) -> i32 ---
	@(link_name = "XFreeStringList")
	x_free_string_list :: proc(list: [^]cstring) ---
}

BROKEN :: "broken"

// Xlib calls that return a Status report failure with 0.
@(private)
status_ok :: proc(s: xlib.Status) -> bool { return s != xlib.Status(0) }

// Start managing a window (dwm's manage). `adopting` is true for windows that
// were already mapped when the window manager started (scan).
manage :: proc(m: ^Manager, w: xlib.Window, wa: ^xlib.XWindowAttributes, adopting: bool) {
	c := new(Client)
	c.win = w
	c.desktop = -1
	// geometry
	c.x = wa.x; c.oldx = wa.x
	c.y = wa.y; c.oldy = wa.y
	c.w = wa.width; c.oldw = wa.width
	c.h = wa.height; c.oldh = wa.height
	c.reqw, c.reqh = wa.width, wa.height
	c.oldbw = wa.border_width

	updatetitle(m, c)
	trans: xlib.Window
	parent: ^Client
	if status_ok(xlib.GetTransientForHint(m.dpy, w, &trans)) { parent = wintoclient(m, trans) } else { trans = 0 }
	if parent != nil {
		c.mon = parent.mon
		c.tags = parent.tags
	} else {
		c.mon = m.selmon
		applyrules(m, c)
		if adopting { restore_desktop(m, c) }
	}

	mon := c.mon
	if c.x + width(c) > mon.wx + mon.ww { c.x = mon.wx + mon.ww - width(c) }
	if c.y + height(c) > mon.wy + mon.wh { c.y = mon.wy + mon.wh - height(c) }
	c.x = max(c.x, mon.wx)
	c.y = max(c.y, mon.wy)
	c.bw = m.settings.border_width

	wc: xlib.XWindowChanges
	wc.border_width = c.bw
	xlib.ConfigureWindow(m.dpy, w, {.CWBorderWidth}, &wc)
	xlib.SetWindowBorder(m.dpy, w, m.pixel[.Norm])
	configure(m, c) // propagates border_width, if size doesn't change
	updatewindowtype(m, c)
	if c.kind == .Dock || c.kind == .Desktop {
		// Screen furniture: on every tag, without a border, where it asked to be.
		c.tags = tagmask(m)
		c.x = wa.x
		c.y = wa.y
		if c.bw != 0 {
			c.bw = 0
			wc.border_width = 0
			xlib.ConfigureWindow(m.dpy, w, {.CWBorderWidth}, &wc)
		}
	}
	updatesizehints(m, c)
	updatewmhints(m, c)
	if c.ispip || detect_pip(m, c) { pip_apply(m, c, true, adopting) }
	xlib.SelectInput(m.dpy, w, {.EnterWindow, .FocusChange, .PropertyChange, .StructureNotify})
	grabbuttons(m, c, false)
	if !c.isfloating {
		c.isfloating = trans != 0 || c.isfixed
		c.oldstate = c.isfloating
	}
	if c.isfloating && !c.isfullscreen && !adopting && !c.ispip && c.kind != .Dock && c.kind != .Desktop {
		place_floating(m, c, parent)
	}
	if c.kind == .Desktop {
		xlib.LowerWindow(m.dpy, c.win)
	} else if c.isfloating {
		xlib.RaiseWindow(m.dpy, c.win)
	}
	attach(c)
	attachstack(c)
	ewmh_client_added(m, c)
	xlib.MoveResizeWindow(m.dpy, c.win, c.x + 2 * m.sw, c.y, u32(c.w), u32(c.h)) // some windows require this
	setclientstate(m, c, .NormalState)
	if !c.nofocus {
		if c.mon == m.selmon { unfocus(m, m.selmon.sel, false) }
		c.mon.sel = c
	}
	arrange(m, c.mon)
	if !adopting && c.kind == .Normal && !c.isfullscreen && is_visible(c) { anim_grow_in(m, c) }
	apply_corners(m, c)
	xlib.MapWindow(m.dpy, c.win)
	focus(m, nil)
	log.debugf("wm: managing 0x%x %q (tags 0x%x%s)", c.win, c.name, c.tags, c.isfloating ? ", floating" : "")
}

// milk addition: a window adopted at startup goes back to the desktop it had
// (_NET_WM_DESKTOP is kept on shutdown, as EWMH asks), so a restart of milk
// does not pile every window onto the current tag.
@(private)
restore_desktop :: proc(m: ^Manager, c: ^Client) {
	desk, ok := tx.get_cardinal(m.c, c.win, "_NET_WM_DESKTOP")
	if !ok { return }
	if desk == 0xFFFFFFFF {
		c.tags = tagmask(m)
	} else if int(desk) < m.settings.tag_count {
		c.tags = u32(1) << u32(desk)
	}
}

// milk addition: a new floating window that did not ask for a position
// (no USPosition/PPosition) is centred on its transient parent, or on the
// window area of its monitor.
@(private)
place_floating :: proc(m: ^Manager, c: ^Client, parent: ^Client) {
	hints: xlib.XSizeHints
	supplied: xlib.SizeHints
	if status_ok(xlib.GetWMNormalHints(m.dpy, c.win, &hints, &supplied)) &&
	   (.USPosition in hints.flags || .PPosition in hints.flags) { return }
	mon := c.mon
	x, y: i32
	if parent != nil && parent.mon == mon {
		x = parent.x + (width(parent) - width(c)) / 2
		y = parent.y + (height(parent) - height(c)) / 2
	} else {
		x = mon.wx + (mon.ww - width(c)) / 2
		y = mon.wy + (mon.wh - height(c)) / 2
	}
	c.x = max(min(x, mon.wx + mon.ww - width(c)), mon.wx)
	c.y = max(min(y, mon.wy + mon.wh - height(c)), mon.wy)
}

// Stop managing a client (dwm's unmanage). `destroyed` = the window is gone.
unmanage :: proc(m: ^Manager, c: ^Client, destroyed: bool) {
	mon := c.mon
	detach(c)
	detachstack(c)
	if !destroyed {
		wc: xlib.XWindowChanges
		wc.border_width = c.oldbw
		xlib.GrabServer(m.dpy) // avoid race conditions
		previous := xlib.SetErrorHandler(xerror_dummy)
		xlib.SelectInput(m.dpy, c.win, {})
		xlib.ConfigureWindow(m.dpy, c.win, {.CWBorderWidth}, &wc) // restore border
		xlib.UngrabButton(m.dpy, xlib.AnyButton, {.AnyModifier}, c.win)
		setclientstate(m, c, .WithdrawnState)
		if !m.shutting_down {
			// EWMH: the WM removes these when a window is withdrawn (not on shutdown).
			xlib.DeleteProperty(m.dpy, c.win, m.atoms.net_wm_desktop)
			xlib.DeleteProperty(m.dpy, c.win, m.atoms.net_wm_state)
		}
		xlib.Sync(m.dpy, false)
		xlib.SetErrorHandler(previous)
		xlib.UngrabServer(m.dpy)
	}
	ewmh_client_removed(m, c)
	log.debugf("wm: released 0x%x %q%s", c.win, c.name, destroyed ? " (destroyed)" : "")
	delete(c.name)
	free(c)
	focus(m, nil)
	arrange(m, mon)
}

// WM_CLASS instance and class ("broken" when missing), in the temp allocator.
class_hint :: proc(m: ^Manager, w: xlib.Window) -> (instance, class: string) {
	instance, class = BROKEN, BROKEN
	ch: xlib.XClassHint
	if !status_ok(xlib.GetClassHint(m.dpy, w, &ch)) { return }
	if ch.res_class != nil {
		class = strings.clone(string(ch.res_class), context.temp_allocator)
		xlib.Free(rawptr(ch.res_class))
	}
	if ch.res_name != nil {
		instance = strings.clone(string(ch.res_name), context.temp_allocator)
		xlib.Free(rawptr(ch.res_name))
	}
	return
}

// milk's own windows (WM_CLASS class "Milk") are never managed.
is_milk_window :: proc(m: ^Manager, w: xlib.Window) -> bool {
	_, class := class_hint(m, w)
	return class == "Milk" || class == "Temenos"
}

// dwm's applyrules with the semantics of config.WM_Rule: class and instance
// match exactly, the title is a substring, empty fields match anything. A rule
// with "pip": true marks the client as picture-in-picture (see pip.odin).
applyrules :: proc(m: ^Manager, c: ^Client) {
	c.isfloating = false
	c.tags = 0
	instance, class := class_hint(m, c.win)
	for r in m.settings.rules {
		if (r.title == "" || strings.contains(c.name, r.title)) &&
		   (r.class == "" || r.class == class) &&
		   (r.instance == "" || r.instance == instance) {
			c.isfloating = r.floating
			c.tags |= r.tags
			if r.pip { c.ispip = true }
			for mon := m.mons; mon != nil; mon = mon.next {
				if mon.num == r.monitor {
					c.mon = mon
					break
				}
			}
		}
	}
	mask := tagmask(m)
	c.tags = c.tags & mask != 0 ? c.tags & mask : c.mon.tagset[c.mon.seltags]
}

// Adjust a requested geometry to the client's size hints and keep it
// reachable; true when it differs from the current geometry.
applysizehints :: proc(m: ^Manager, c: ^Client, x, y, w, h: ^i32, interact: bool) -> bool {
	mon := c.mon
	// set minimum possible
	w^ = max(1, w^)
	h^ = max(1, h^)
	if interact {
		if x^ > m.sw { x^ = m.sw - width(c) }
		if y^ > m.sh { y^ = m.sh - height(c) }
		if x^ + w^ + 2 * c.bw < 0 { x^ = 0 }
		if y^ + h^ + 2 * c.bw < 0 { y^ = 0 }
	} else {
		if x^ >= mon.wx + mon.ww { x^ = mon.wx + mon.ww - width(c) }
		if y^ >= mon.wy + mon.wh { y^ = mon.wy + mon.wh - height(c) }
		if x^ + w^ + 2 * c.bw <= mon.wx { x^ = mon.wx }
		if y^ + h^ + 2 * c.bw <= mon.wy { y^ = mon.wy }
	}
	if h^ < MIN_SIZE { h^ = MIN_SIZE }
	if w^ < MIN_SIZE { w^ = MIN_SIZE }
	if m.settings.resize_hints || c.isfloating || !has_arrange(cur_layout(c.mon)) {
		if !c.hintsvalid { updatesizehints(m, c) }
		// see last two sentences in ICCCM 4.1.2.3
		baseismin := c.basew == c.minw && c.baseh == c.minh
		if !baseismin { // temporarily remove base dimensions
			w^ -= c.basew
			h^ -= c.baseh
		}
		// adjust for aspect limits
		if c.mina > 0 && c.maxa > 0 && w^ > 0 && h^ > 0 {
			if c.maxa < f32(w^) / f32(h^) {
				w^ = i32(f64(f32(h^) * c.maxa) + 0.5)
			} else if c.mina < f32(h^) / f32(w^) {
				h^ = i32(f64(f32(w^) * c.mina) + 0.5)
			}
		}
		if baseismin { // increment calculation requires this
			w^ -= c.basew
			h^ -= c.baseh
		}
		// adjust for increment value
		if c.incw != 0 { w^ -= w^ % c.incw }
		if c.inch != 0 { h^ -= h^ % c.inch }
		// restore base dimensions
		w^ = max(w^ + c.basew, c.minw)
		h^ = max(h^ + c.baseh, c.minh)
		if c.maxw != 0 { w^ = min(w^, c.maxw) }
		if c.maxh != 0 { h^ = min(h^, c.maxh) }
	}
	return x^ != c.x || y^ != c.y || w^ != c.w || h^ != c.h
}

resize :: proc(m: ^Manager, c: ^Client, x, y, w, h: i32, interact: bool) {
	nx, ny, nw, nh := x, y, w, h
	// Mouse moves/resizes follow the pointer directly; everything else animates.
	if applysizehints(m, c, &nx, &ny, &nw, &nh, interact) { resizeclient_ex(m, c, nx, ny, nw, nh, !interact) }
}

resizeclient :: proc(m: ^Manager, c: ^Client, x, y, w, h: i32) {
	resizeclient_ex(m, c, x, y, w, h, true)
}

resizeclient_ex :: proc(m: ^Manager, c: ^Client, x, y, w, h: i32, animate: bool) {
	c.oldx = c.x; c.x = x
	c.oldy = c.y; c.y = y
	c.oldw = c.w; c.w = w
	c.oldh = c.h; c.h = h
	if animate && anim_begin(m, c) {
		// The border changes at once (fullscreen); the geometry follows the animation.
		wc: xlib.XWindowChanges
		wc.border_width = c.bw
		xlib.ConfigureWindow(m.dpy, c.win, {.CWBorderWidth}, &wc)
		configure(m, c)
		return
	}
	anim_snap(m, c)
	configure(m, c)
	xlib.Sync(m.dpy, false)
}

// Synthetic ConfigureNotify with the geometry we gave the client (ICCCM 4.1.5).
configure :: proc(m: ^Manager, c: ^Client) {
	ev: xlib.XEvent
	ev.xconfigure = xlib.XConfigureEvent{
		type              = .ConfigureNotify,
		display           = m.dpy,
		event             = c.win,
		window            = c.win,
		x                 = c.x,
		y                 = c.y,
		width             = c.w,
		height            = c.h,
		border_width      = c.bw,
		above             = 0,
		override_redirect = false,
	}
	xlib.SendEvent(m.dpy, c.win, false, {.StructureNotify}, &ev)
}

updatesizehints :: proc(m: ^Manager, c: ^Client) {
	size: xlib.XSizeHints
	msize: xlib.SizeHints
	if !status_ok(xlib.GetWMNormalHints(m.dpy, c.win, &size, &msize)) {
		// size is uninitialized, ensure that size.flags aren't used
		size.flags = {.PSize}
	}
	if .PBaseSize in size.flags {
		c.basew = size.base_width
		c.baseh = size.base_height
	} else if .PMinSize in size.flags {
		c.basew = size.min_width
		c.baseh = size.min_height
	} else {
		c.basew = 0
		c.baseh = 0
	}
	if .PResizeInc in size.flags {
		c.incw = size.width_inc
		c.inch = size.height_inc
	} else {
		c.incw = 0
		c.inch = 0
	}
	if .PMaxSize in size.flags {
		c.maxw = size.max_width
		c.maxh = size.max_height
	} else {
		c.maxw = 0
		c.maxh = 0
	}
	if .PMinSize in size.flags {
		c.minw = size.min_width
		c.minh = size.min_height
	} else if .PBaseSize in size.flags {
		c.minw = size.base_width
		c.minh = size.base_height
	} else {
		c.minw = 0
		c.minh = 0
	}
	if .PAspect in size.flags && size.min_aspect.x != 0 && size.max_aspect.y != 0 {
		c.mina = f32(size.min_aspect.y) / f32(size.min_aspect.x)
		c.maxa = f32(size.max_aspect.x) / f32(size.max_aspect.y)
	} else {
		c.maxa = 0
		c.mina = 0
	}
	c.isfixed = c.maxw != 0 && c.maxh != 0 && c.maxw == c.minw && c.maxh == c.minh
	c.hintsvalid = true
}

// A text property converted to UTF-8 (COMPOUND_TEXT, STRING and UTF8_STRING).
// `found` is true when the property exists, even if it could not be converted.
gettextprop :: proc(m: ^Manager, w: xlib.Window, atom: xlib.Atom, allocator := context.allocator) -> (text: string, found: bool) {
	name: Text_Property
	if x_get_text_property(m.dpy, w, &name, atom) == 0 { return "", false }
	defer if name.value != nil { xlib.Free(name.value) }
	if name.nitems == 0 { return "", false }
	list: [^]cstring
	n: i32
	if x_utf8_text_property_to_text_list(m.dpy, &name, &list, &n) >= 0 && list != nil {
		if n > 0 && list[0] != nil { text = strings.clone(string(list[0]), allocator) }
		x_free_string_list(list)
	}
	return text, true
}

updatetitle :: proc(m: ^Manager, c: ^Client) {
	delete(c.name)
	c.name = ""
	title, found := gettextprop(m, c.win, m.atoms.net_wm_name)
	if !found || title == "" {
		delete(title)
		title, _ = gettextprop(m, c.win, tx.ATOM_WM_NAME)
	}
	if title == "" { // hack to mark broken clients
		delete(title)
		title = strings.clone(BROKEN)
	}
	c.name = title
}

// _NET_WM_STATE (fullscreen) and _NET_WM_WINDOW_TYPE: dialogs float; docks,
// desktops, notifications, tooltips and splash screens float and never get
// the selection (see Window_Kind for their stacking).
updatewindowtype :: proc(m: ^Manager, c: ^Client) {
	a := &m.atoms
	states := tx.get_atoms(m.c, c.win, "_NET_WM_STATE")
	if slice.contains(states, a.net_wm_state_fullscreen) { setfullscreen(m, c, true) }
	for t in tx.get_atoms(m.c, c.win, "_NET_WM_WINDOW_TYPE") {
		if t == a.net_type_dialog {
			c.isfloating = true
			break
		}
		kind := Window_Kind.Normal
		switch t {
		case a.net_type_dock:    kind = .Dock
		case a.net_type_desktop: kind = .Desktop
		case a.net_type_notification, a.net_type_tooltip, a.net_type_splash: kind = .Popup
		}
		if kind != .Normal {
			c.isfloating = true
			c.nofocus = true
			c.kind = kind
			break
		}
		if t == a.net_type_normal { break }
	}
}

updatewmhints :: proc(m: ^Manager, c: ^Client) {
	wmh := xlib.GetWMHints(m.dpy, c.win)
	if wmh == nil { return }
	defer xlib.Free(wmh)
	if c == m.selmon.sel && .XUrgencyHint in wmh.flags {
		wmh.flags -= {.XUrgencyHint}
		xlib.SetWMHints(m.dpy, c.win, wmh)
	} else {
		c.isurgent = .XUrgencyHint in wmh.flags
	}
	if .InputHint in wmh.flags {
		c.neverfocus = !bool(wmh.input)
	} else {
		c.neverfocus = false
	}
}

seturgent :: proc(m: ^Manager, c: ^Client, urg: bool) {
	c.isurgent = urg
	wmh := xlib.GetWMHints(m.dpy, c.win)
	if wmh == nil { return }
	defer xlib.Free(wmh)
	if urg { wmh.flags += {.XUrgencyHint} } else { wmh.flags -= {.XUrgencyHint} }
	xlib.SetWMHints(m.dpy, c.win, wmh)
}

setclientstate :: proc(m: ^Manager, c: ^Client, state: xlib.WMHintState) {
	data := [2]uint{uint(state), 0}
	xlib.ChangeProperty(m.dpy, c.win, m.atoms.wm_state, m.atoms.wm_state, 32, xlib.PropModeReplace, &data[0], 2)
}

// WM_STATE of a window (-1 when absent).
getstate :: proc(m: ^Manager, w: xlib.Window) -> int {
	real: xlib.Atom
	format: i32
	n, extra: uint
	p: rawptr
	if xlib.GetWindowProperty(m.dpy, w, m.atoms.wm_state, 0, 2, false, m.atoms.wm_state,
	                          &real, &format, &n, &extra, &p) != 0 { return -1 }
	defer if p != nil { xlib.Free(p) }
	if n == 0 || p == nil || format != 32 { return -1 }
	return int(([^]uint)(p)[0] & 0xFFFFFFFF)
}

// Send a WM_PROTOCOLS message when the client supports `proto`.
sendevent :: proc(m: ^Manager, c: ^Client, proto: xlib.Atom) -> bool {
	protocols: [^]xlib.Atom
	n: i32
	exists := false
	if status_ok(xlib.GetWMProtocols(m.dpy, c.win, &protocols, &n)) {
		for i in 0 ..< int(n) {
			if protocols[i] == proto { exists = true }
		}
		xlib.Free(protocols)
	}
	if exists {
		ev: xlib.XEvent
		ev.xclient.type = .ClientMessage
		ev.xclient.window = c.win
		ev.xclient.message_type = m.atoms.wm_protocols
		ev.xclient.format = 32
		ev.xclient.data.l[0] = int(proto)
		ev.xclient.data.l[1] = xlib.CurrentTime
		xlib.SendEvent(m.dpy, c.win, false, {}, &ev)
	}
	return exists
}

setfocus :: proc(m: ^Manager, c: ^Client) {
	if !c.neverfocus {
		xlib.SetInputFocus(m.dpy, c.win, .RevertToPointerRoot, xlib.CurrentTime)
		win := c.win
		xlib.ChangeProperty(m.dpy, m.root, m.atoms.net_active_window, tx.ATOM_WINDOW, 32, xlib.PropModeReplace, &win, 1)
	}
	sendevent(m, c, m.atoms.wm_take_focus)
}

// Add or remove one _NET_WM_STATE atom, keeping the other states the client
// set (dwm replaces the whole list, dropping e.g. _NET_WM_STATE_MODAL).
@(private)
write_state_atom :: proc(m: ^Manager, c: ^Client, state: xlib.Atom, on: bool) {
	states := make([dynamic]xlib.Atom, context.temp_allocator)
	for s in tx.get_atoms(m.c, c.win, "_NET_WM_STATE") {
		if s != state { append(&states, s) }
	}
	if on { append(&states, state) }
	xlib.ChangeProperty(m.dpy, c.win, m.atoms.net_wm_state, tx.ATOM_ATOM, 32, xlib.PropModeReplace,
	                    raw_data(states), i32(len(states)))
}

setfullscreen :: proc(m: ^Manager, c: ^Client, fullscreen: bool) {
	if fullscreen && !c.isfullscreen {
		write_state_atom(m, c, m.atoms.net_wm_state_fullscreen, true)
		c.isfullscreen = true
		c.oldstate = c.isfloating
		c.fsbw = c.bw
		c.bw = 0
		c.isfloating = true
		resizeclient(m, c, c.mon.mx, c.mon.my, c.mon.mw, c.mon.mh)
		xlib.RaiseWindow(m.dpy, c.win)
		m.ewmh.stacking_dirty = true
	} else if !fullscreen && c.isfullscreen {
		write_state_atom(m, c, m.atoms.net_wm_state_fullscreen, false)
		c.isfullscreen = false
		c.isfloating = c.oldstate
		c.bw = c.fsbw
		c.x = c.oldx
		c.y = c.oldy
		c.w = c.oldw
		c.h = c.oldh
		resizeclient(m, c, c.x, c.y, c.w, c.h)
		arrange(m, c.mon)
	}
}

// Close a client politely (WM_DELETE_WINDOW) or kill its connection.
kill_client :: proc(m: ^Manager, c: ^Client) {
	if c == nil { return }
	if !sendevent(m, c, m.atoms.wm_delete) {
		xlib.GrabServer(m.dpy)
		previous := xlib.SetErrorHandler(xerror_dummy)
		xlib.SetCloseDownMode(m.dpy, .DestroyAll)
		xlib.KillClient(m.dpy, xlib.XID(c.win))
		xlib.Sync(m.dpy, false)
		xlib.SetErrorHandler(previous)
		xlib.UngrabServer(m.dpy)
	}
}
