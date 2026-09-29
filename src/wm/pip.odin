// milk addition: picture-in-picture windows and pointer-driven move/resize.
//
// Picture-in-picture (PiP) windows — the small video windows browsers pop out —
// are recognised by their title ("Picture-in-Picture", "Picture in picture",
// the Portuguese "Imagem na imagem"...), by Firefox's PiP window class
// (instance "Toolkit" of a Firefox-family browser) or by a wm.rules entry with
// "pip": true. They float without a border on every tag, stay above the other
// windows, start at the bottom-right corner of the monitor and can be moved and
// resized with the mouse alone: a press near an edge or corner resizes from
// there, any other press goes to the application, whose own drag-to-move asks
// the window manager to move the window through _NET_WM_MOVERESIZE. Win+Q
// closes them like any other window.
//
// _NET_WM_MOVERESIZE (EWMH) is how client-side-decorated applications (GTK
// headerbars, browser PiP windows) hand a drag over to the window manager: the
// client releases its pointer grab and sends the message to the root; the
// window manager grabs the pointer and moves or resizes the window until the
// button is released.
package wm

import "core:log"
import "core:strings"
import "core:unicode"
import xlib "vendor:x11/xlib"

// _NET_WM_MOVERESIZE directions.
MR_SIZE_TOPLEFT     :: 0
MR_SIZE_TOP         :: 1
MR_SIZE_TOPRIGHT    :: 2
MR_SIZE_RIGHT       :: 3
MR_SIZE_BOTTOMRIGHT :: 4
MR_SIZE_BOTTOM      :: 5
MR_SIZE_BOTTOMLEFT  :: 6
MR_SIZE_LEFT        :: 7
MR_MOVE             :: 8
MR_SIZE_KEYBOARD    :: 9
MR_MOVE_KEYBOARD    :: 10
MR_CANCEL           :: 11

PIP_MARGIN :: 16 // distance from the work area's bottom-right corner
PIP_EDGE   :: 10 // a press this close to an edge resizes (twice as far along a corner)

// Normalised PiP titles (lower case, without spaces and dashes).
@(private)
PIP_TITLES := [?]string{"pictureinpicture", "imagemnaimagem", "imagemsobreimagem"}

// A title that merely contains one of PIP_TITLES counts only when it adds at
// most this many characters ("Picture-in-Picture - YouTube"): a browser's main
// window whose tab is titled "How to use Picture-in-Picture — Mozilla Firefox"
// must not become a PiP window.
@(private)
PIP_TITLE_SLACK :: 16

// Class prefixes of Firefox-family browsers, whose PiP window has the WM_CLASS
// instance "Toolkit".
@(private)
PIP_FIREFOX_CLASSES := [?]string{"firefox", "librewolf", "zen", "floorp", "waterfox", "mullvad", "icecat", "tor"}

// Lower case, without whitespace, dashes and underscores.
@(private)
normalize_title :: proc(title: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in strings.to_lower(title, context.temp_allocator) {
		if unicode.is_space(r) || r == '-' || r == '_' || (r >= 0x2010 && r <= 0x2015) { continue }
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}

is_pip_title :: proc(title: string) -> bool {
	t := normalize_title(title)
	for k in PIP_TITLES {
		if t == k { return true }
		if len(t) <= len(k) + PIP_TITLE_SLACK && strings.contains(t, k) { return true }
	}
	return false
}

// Whether a client is a picture-in-picture window (title or Firefox class; the
// rules set Client.ispip themselves in applyrules).
detect_pip :: proc(m: ^Manager, c: ^Client) -> bool {
	if c.kind != .Normal { return false }
	if is_pip_title(c.name) { return true }
	instance, class := class_hint(m, c.win)
	if strings.to_lower(instance, context.temp_allocator) == "toolkit" {
		lc := strings.to_lower(class, context.temp_allocator)
		for prefix in PIP_FIREFOX_CLASSES {
			if strings.has_prefix(lc, prefix) { return true }
		}
	}
	return false
}

// Turn a client into a PiP window. `managing` = called from manage (which
// configures, maps and arranges the window afterwards); otherwise the change
// is applied at once (the title changed after mapping). `adopting` keeps the
// position of a window that was on screen before the window manager started.
pip_apply :: proc(m: ^Manager, c: ^Client, managing, adopting: bool) {
	c.ispip = true
	c.nofocus = false // Win+Q must be able to close it
	c.tags = tagmask(m)
	if c.isfullscreen {
		c.fsbw = 0
		c.oldstate = true
	} else {
		if !c.isfloating && c.reqw > 0 && c.reqh > 0 {
			// It was tiled: give it back the size it asked for.
			c.w, c.h = c.reqw, c.reqh
		}
		c.isfloating = true
		c.oldstate = true
		c.bw = 0
	}
	write_state_atom(m, c, m.atoms.net_wm_state_sticky, true)

	if !c.isfullscreen {
		// Keep the size it asked for; start at the bottom-right corner unless
		// the user placed it (USPosition).
		hints: xlib.XSizeHints
		supplied: xlib.SizeHints
		user_pos := status_ok(xlib.GetWMNormalHints(m.dpy, c.win, &hints, &supplied)) && .USPosition in hints.flags
		if !adopting && !user_pos {
			mon := c.mon
			c.x = max(mon.wx + mon.ww - width(c) - PIP_MARGIN, mon.wx)
			c.y = max(mon.wy + mon.wh - height(c) - PIP_MARGIN, mon.wy)
		}
		wc: xlib.XWindowChanges
		wc.border_width = 0
		xlib.ConfigureWindow(m.dpy, c.win, {.CWBorderWidth}, &wc)
	}
	log.infof("wm: picture-in-picture window 0x%x %q", c.win, c.name)
	if managing { return }
	if !c.isfullscreen { resizeclient(m, c, c.x, c.y, c.w, c.h) }
	grabbuttons(m, c, c == c.mon.sel)
	xlib.RaiseWindow(m.dpy, c.win)
	arrange(m, c.mon)
}

// The _NET_WM_MOVERESIZE direction for a press at (x, y) relative to a PiP
// window, or -1 when the press is not near an edge.
pip_edge :: proc(c: ^Client, x, y: i32) -> int {
	w, h := width(c), height(c)
	l1, l2 := x < PIP_EDGE, x < 2 * PIP_EDGE
	r1, r2 := x >= w - PIP_EDGE, x >= w - 2 * PIP_EDGE
	t1, t2 := y < PIP_EDGE, y < 2 * PIP_EDGE
	b1, b2 := y >= h - PIP_EDGE, y >= h - 2 * PIP_EDGE
	switch {
	case (t1 && l2) || (t2 && l1): return MR_SIZE_TOPLEFT
	case (t1 && r2) || (t2 && r1): return MR_SIZE_TOPRIGHT
	case (b1 && r2) || (b2 && r1): return MR_SIZE_BOTTOMRIGHT
	case (b1 && l2) || (b2 && l1): return MR_SIZE_BOTTOMLEFT
	case t1: return MR_SIZE_TOP
	case r1: return MR_SIZE_RIGHT
	case b1: return MR_SIZE_BOTTOM
	case l1: return MR_SIZE_LEFT
	}
	return -1
}

// Resize cursors for the eight _NET_WM_MOVERESIZE directions.
create_dir_cursors :: proc(m: ^Manager) {
	shapes := [8]xlib.CursorShape{
		.XC_top_left_corner, .XC_top_side, .XC_top_right_corner, .XC_right_side,
		.XC_bottom_right_corner, .XC_bottom_side, .XC_bottom_left_corner, .XC_left_side,
	}
	for shape, i in shapes { m.dir_cursor[i] = xlib.CreateFontCursor(m.dpy, shape) }
}

// A _NET_WM_MOVERESIZE request from a client.
handle_moveresize_message :: proc(m: ^Manager, c: ^Client, cme: ^xlib.XClientMessageEvent) {
	dir := cme.data.l[2]
	switch dir {
	case MR_SIZE_TOPLEFT ..= MR_MOVE:
		moveresize(m, c, dir, i32(cme.data.l[0]), i32(cme.data.l[1]), u32(cme.data.l[3]))
	case MR_SIZE_KEYBOARD, MR_MOVE_KEYBOARD:
		log.debugf("wm: keyboard move/resize requested by 0x%x (not supported)", c.win)
	case MR_CANCEL:
		// Nothing is running: a drag in progress handles the cancel itself.
	}
}

// Whether `button` (1..5, 0 = any) is set in a pointer/modifier state.
@(private)
button_in_state :: proc(bits: u32, button: u32) -> bool {
	if button >= 1 && button <= 5 { return bits & (u32(1) << (7 + button)) != 0 }
	return bits & (u32(0x1F) << 8) != 0
}

@(private)
pointer_button_down :: proc(m: ^Manager, button: u32) -> bool {
	dummy: xlib.Window
	x, y, wx, wy: i32
	mask: xlib.KeyMask
	if !bool(xlib.QueryPointer(m.dpy, m.root, &dummy, &dummy, &x, &y, &wx, &wy, &mask)) { return false }
	return button_in_state(transmute(u32)mask, button)
}

// Events the move/resize loop consumes: pointer events, requests of other
// clients (so they are not blocked), and _NET_WM_MOVERESIZE (cancel).
@(private)
moveresize_predicate :: proc "c" (_: ^xlib.Display, ev: ^xlib.XEvent, arg: rawptr) -> b32 {
	m := (^Manager)(arg)
	#partial switch ev.type {
	case .ButtonPress, .ButtonRelease, .MotionNotify, .ConfigureRequest, .MapRequest:
		return true
	case .ClientMessage:
		return b32(ev.xclient.message_type == m.atoms.net_wm_moveresize)
	}
	return false
}

// Fixed-aspect clients (min aspect == max aspect, as video windows set): derive
// the other dimension from the dragged one, so that an edge resizes the window
// proportionally instead of being blocked by the aspect limit. Returns which
// dimension was derived.
@(private)
keep_aspect :: proc(c: ^Client, w, h: ^i32, horizontal, vertical: bool, ow, oh: i32) -> (derived_w, derived_h: bool) {
	if c.mina <= 0 || c.maxa <= 0 || abs(c.mina * c.maxa - 1) > 0.01 { return }
	ratio := c.maxa // width / height
	from_width := horizontal
	if horizontal && vertical {
		// A corner follows the axis that changed most.
		from_width = abs(f32(w^) / f32(max(ow, 1)) - 1) >= abs(f32(h^) / f32(max(oh, 1)) - 1)
	}
	if from_width {
		h^ = i32(f32(w^) / ratio + 0.5)
		return false, !vertical
	}
	w^ = i32(f32(h^) * ratio + 0.5)
	return !horizontal, false
}

// Move (MR_MOVE) or resize from an edge/corner (MR_SIZE_*) a client with the
// pointer, from the root position (px, py) where the drag started, until
// `button` (0 = any) is released or the client cancels. The edge or corner
// opposite to the dragged one stays in place; size hints are honoured; a tiled
// window that is moved or resized becomes floating, as with dwm's Mod+drag.
moveresize :: proc(m: ^Manager, c: ^Client, dir: int, px, py: i32, button: u32) {
	if c.isfullscreen || c.kind == .Dock || c.kind == .Desktop { return }
	if dir < MR_SIZE_TOPLEFT || dir > MR_MOVE { return }
	if c != m.selmon.sel { focus(m, c) }
	restack(m, c.mon)
	cursor := dir == MR_MOVE ? m.cursor[.Move] : m.dir_cursor[dir]
	if xlib.GrabPointer(m.dpy, m.root, false, MOUSEMASK, .GrabModeAsync, .GrabModeAsync,
	                    0, cursor, xlib.CurrentTime) != GRAB_SUCCESS {
		log.debugf("wm: move/resize of 0x%x: the pointer is grabbed by someone else", c.win)
		return
	}
	// A quick click may be over before the request arrives: nothing to drag.
	if !pointer_button_down(m, button) {
		xlib.UngrabPointer(m.dpy, xlib.CurrentTime)
		return
	}
	ocx, ocy, ocw, och := c.x, c.y, c.w, c.h
	left := dir == MR_SIZE_TOPLEFT || dir == MR_SIZE_BOTTOMLEFT || dir == MR_SIZE_LEFT
	right := dir == MR_SIZE_TOPRIGHT || dir == MR_SIZE_RIGHT || dir == MR_SIZE_BOTTOMRIGHT
	top := dir == MR_SIZE_TOPLEFT || dir == MR_SIZE_TOP || dir == MR_SIZE_TOPRIGHT
	bottom := dir == MR_SIZE_BOTTOMRIGHT || dir == MR_SIZE_BOTTOM || dir == MR_SIZE_BOTTOMLEFT
	// togglefloating acts on the selection: only the selected client may leave the tiling.
	can_float := c == m.selmon.sel
	lasttime: xlib.Time
	ev: xlib.XEvent
	loop: for {
		xlib.IfEvent(m.dpy, &ev, moveresize_predicate, m)
		#partial switch ev.type {
		case .ConfigureRequest:
			configurerequest(m, &ev)
		case .MapRequest:
			maprequest(m, &ev)
		case .ClientMessage:
			if ev.xclient.data.l[2] == MR_CANCEL { break loop }
		case .ButtonRelease:
			if button == 0 || u32(ev.xbutton.button) == button { break loop }
		case .MotionNotify:
			if ev.xmotion.window != m.root { continue }
			// The button went up without a release reaching us.
			if !button_in_state(u32(transmute(i32)ev.xmotion.state), button) { break loop }
			if ev.xmotion.time - lasttime <= 1000 / 60 { continue }
			lasttime = ev.xmotion.time
			dx := ev.xmotion.x_root - px
			dy := ev.xmotion.y_root - py
			sm := m.selmon
			arranged := has_arrange(cur_layout(sm))
			if dir == MR_MOVE {
				nx, ny := ocx + dx, ocy + dy
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
				if !c.isfloating && arranged && can_float && (abs(nx - c.x) > SNAP || abs(ny - c.y) > SNAP) {
					togglefloating(m, nil)
				}
				if !arranged || c.isfloating { resize(m, c, nx, ny, c.w, c.h, true) }
			} else {
				nx, ny, nw, nh := ocx, ocy, ocw, och
				if left {
					nx = ocx + dx
					nw = ocw - dx
				}
				if right { nw = ocw + dx }
				if top {
					ny = ocy + dy
					nh = och - dy
				}
				if bottom { nh = och + dy }
				derived_w, derived_h := keep_aspect(c, &nw, &nh, left || right, top || bottom, ocw, och)
				// A dimension that follows the aspect ratio grows away from the
				// nearer screen edge (a PiP in the bottom-right corner grows up/left).
				anchor_right, anchor_bottom := left, top
				mon := c.mon
				if derived_w { anchor_right = ocx + ocw / 2 > mon.mx + mon.mw / 2 }
				if derived_h { anchor_bottom = ocy + och / 2 > mon.my + mon.mh / 2 }
				if !c.isfloating && arranged && can_float && (abs(nw - c.w) > SNAP || abs(nh - c.h) > SNAP) {
					togglefloating(m, nil)
				}
				if !arranged || c.isfloating {
					applysizehints(m, c, &nx, &ny, &nw, &nh, true)
					// Keep the opposite edge where it was.
					if anchor_right { nx = ocx + ocw - nw }
					if anchor_bottom { ny = ocy + och - nh }
					if nx != c.x || ny != c.y || nw != c.w || nh != c.h { resizeclient_ex(m, c, nx, ny, nw, nh, false) }
				}
			}
		}
	}
	xlib.UngrabPointer(m.dpy, xlib.CurrentTime)
	discard_enter_events(m)
	if mon := recttomon(m, c.x, c.y, c.w, c.h); mon != m.selmon {
		sendmon(m, c, mon)
		m.selmon = mon
		focus(m, nil)
	}
	m.ewmh.stacking_dirty = true
}
