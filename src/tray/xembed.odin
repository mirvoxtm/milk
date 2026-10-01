// The XEmbed system tray (freedesktop System Tray spec 0.3): the legacy
// protocol of Wine, GtkStatusIcon and the applications that fall back to it
// when no StatusNotifierWatcher runs.
//
// milk owns _NET_SYSTEM_TRAY_S<screen> through a small unmapped window
// (announced with the MANAGER client message, with a horizontal orientation,
// the default visual, the icon size and the bar's colours for symbolic
// icons), unless another tray already owns it: then milk leaves it the icons
// and takes over only when that tray's window is destroyed. An icon that
// asks to dock (SYSTEM_TRAY_REQUEST_DOCK) is reparented into a "socket": a
// child window of the bar with a ParentRelative background, so the
// application paints over the bar's own pixels; it is sized to the icon box,
// told XEMBED_EMBEDDED_NOTIFY and mapped as its _XEMBED_INFO asks. Sockets
// are moved to their slots after every bar frame, and the icons are made to
// repaint when the bar pixels behind them changed.
//
// Icons are put in the save set with XFixes' SaveSetRoot/SaveSetUnmap (as
// GtkSocket does): if milk dies they go back to the root unmapped, never as
// stray top-level windows. When the bar window is recreated the sockets are
// parked on the root and moved into the new window (the icons never notice);
// when milk stops or loses the selection the icons are unmapped and handed
// back to the root, which makes GTK wait for the next tray.
package tray

import "core:fmt"
import "core:log"
import xlib "vendor:x11/xlib"
import tx "../tx"

@(private) SYSTEM_TRAY_REQUEST_DOCK :: 0
@(private) XEMBED_EMBEDDED_NOTIFY   :: 0
@(private) XEMBED_MAPPED            :: 1
@(private) XEMBED_VERSION           :: 0
@(private) SOCKET_PAD               :: 0 // around the icon size (GTK draws its icon as large as the window)

foreign import xfixes_tray "system:Xfixes"
@(default_calling_convention="c")
foreign xfixes_tray {
	@(private, link_name="XFixesQueryExtension") xfixes_query_extension :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	@(private, link_name="XFixesChangeSaveSet")  xfixes_change_save_set :: proc(dpy: ^xlib.Display, win: xlib.Window, mode, target, map_: i32) ---
}

@(private) SAVE_SET_INSERT :: 0
@(private) SAVE_SET_DELETE :: 1
@(private) SAVE_SET_ROOT   :: 1
@(private) SAVE_SET_UNMAP  :: 1

@(private)
XEmbed :: struct {
	selection:   xlib.Atom, // _NET_SYSTEM_TRAY_S<screen>
	opcode:      xlib.Atom, // _NET_SYSTEM_TRAY_OPCODE
	xembed:      xlib.Atom,
	xembed_info: xlib.Atom,
	manager:     xlib.Window, // milk's selection owner (0 = not the tray)
	other:       xlib.Window, // another tray's manager window milk waits on
	parent:      xlib.Window, // the bar window the sockets live in (0 = parked on the root)
	xfixes:      bool,
}

@(private)
xembed_init :: proc(t: ^Tray) {
	xe := &t.xe
	c := t.c
	xe.selection = tx.atom(c, fmt.tprintf("_NET_SYSTEM_TRAY_S%d", c.screen))
	xe.opcode = tx.atom(c, "_NET_SYSTEM_TRAY_OPCODE")
	xe.xembed = tx.atom(c, "_XEMBED")
	xe.xembed_info = tx.atom(c, "_XEMBED_INFO")
	event_base, error_base: i32
	xe.xfixes = bool(xfixes_query_extension(c.dpy, &event_base, &error_base))
	xembed_start(t)
}

// Become the tray, unless another program is.
@(private)
xembed_start :: proc(t: ^Tray) {
	xe := &t.xe
	c := t.c
	if xe.manager != 0 { return }
	owner := xlib.GetSelectionOwner(c.dpy, xe.selection)
	if owner != 0 {
		log.infof("Tray: another system tray owns the XEmbed tray (window 0x%x); its icons stay there", owner)
		xe.other = owner
		xlib.SelectInput(c.dpy, owner, {.StructureNotify})
		return
	}
	win := tx.create_overlay(c, {-1, -1, 1, 1}, {.PropertyChange, .StructureNotify}, "_NET_WM_WINDOW_TYPE_UTILITY", "milk tray")
	xembed_properties(t, win)
	time := server_time(t, win)
	xlib.SetSelectionOwner(c.dpy, xe.selection, win, time)
	if xlib.GetSelectionOwner(c.dpy, xe.selection) != win {
		log.warn("Tray: could not become the XEmbed system tray")
		xlib.DestroyWindow(c.dpy, win)
		return
	}
	xe.manager = win
	xe.other = 0
	// ICCCM MANAGER announcement: applications waiting for a tray dock now.
	ev: xlib.XEvent
	ev.xclient.type = .ClientMessage
	ev.xclient.window = c.root
	ev.xclient.message_type = tx.atom(c, "MANAGER")
	ev.xclient.format = 32
	ev.xclient.data.l = {int(time), int(xe.selection), int(win), 0, 0}
	xlib.SendEvent(c.dpy, c.root, false, {.StructureNotify}, &ev)
	tx.flush(c)
	log.info("Tray: serving the XEmbed system tray")
}

// Orientation, visual, icon size, padding and colours, read by the icons.
@(private)
xembed_properties :: proc(t: ^Tray, win: xlib.Window) {
	if win == 0 { return }
	c := t.c
	tx.set_cardinals(c, win, "_NET_SYSTEM_TRAY_ORIENTATION", {0}) // horizontal
	visual := [1]uint{uint(xlib.VisualIDFromVisual(c.visual))}
	xlib.ChangeProperty(c.dpy, win, tx.atom(c, "_NET_SYSTEM_TRAY_VISUAL"), tx.atom(c, "VISUALID"), 32, xlib.PropModeReplace, &visual[0], 1)
	tx.set_cardinals(c, win, "_NET_SYSTEM_TRAY_ICON_SIZE", {uint(t.size)})
	tx.set_cardinals(c, win, "_NET_SYSTEM_TRAY_PADDING", {0})
	if t.cfg != nil {
		th := &t.cfg.bar.theme
		fg := tx.color_from_hex(th.foreground, tx.rgb(0x3C, 0x3A, 0x38))
		warn := tx.color_from_hex(th.warning, tx.rgb(0xB5, 0x47, 0x3A))
		ok := tx.color_from_hex(th.accent, tx.rgb(0x4A, 0x3F, 0x35))
		w16 :: proc(v: u8) -> uint { return uint(v) * 257 }
		colors := []uint{w16(fg.r), w16(fg.g), w16(fg.b), w16(warn.r), w16(warn.g), w16(warn.b),
		                 w16(warn.r), w16(warn.g), w16(warn.b), w16(ok.r), w16(ok.g), w16(ok.b)}
		tx.set_cardinals(c, win, "_NET_SYSTEM_TRAY_COLORS", colors)
	}
}

// The server time, from the PropertyNotify of a zero-length append (ICCCM).
@(private)
server_time :: proc(t: ^Tray, win: xlib.Window) -> xlib.Time {
	c := t.c
	xlib.ChangeProperty(c.dpy, win, tx.atom(c, "_MILK_TRAY_TIME"), tx.ATOM_CARDINAL, 32, xlib.PropModeAppend, nil, 0)
	ev: xlib.XEvent
	xlib.WindowEvent(c.dpy, win, {.PropertyChange}, &ev)
	return ev.xproperty.time
}

// Stop being the tray: every icon goes back to the root, unmapped.
@(private)
xembed_stop :: proc(t: ^Tray, release: bool) {
	xe := &t.xe
	c := t.c
	for i := len(t.items) - 1; i >= 0; i -= 1 {
		item := t.items[i]
		if item.kind == .XEmbed { xembed_undock(t, item, true) }
	}
	if xe.manager != 0 {
		if release { xlib.SetSelectionOwner(c.dpy, xe.selection, 0, xlib.CurrentTime) }
		xlib.DestroyWindow(c.dpy, xe.manager)
		xe.manager = 0
	}
	if xe.other != 0 {
		xlib.SelectInput(c.dpy, xe.other, {})
		xe.other = 0
	}
	tx.flush(c)
}

// Hand an icon back (alive: its window still exists) and forget it.
@(private)
xembed_undock :: proc(t: ^Tray, item: ^Item, alive: bool) {
	c := t.c
	if alive && item.win != 0 {
		xlib.SelectInput(c.dpy, item.win, {})
		xlib.UnmapWindow(c.dpy, item.win)
		xlib.ReparentWindow(c.dpy, item.win, c.root, 0, 0)
		save_set(t, item.win, false)
	}
	if item.socket != 0 { xlib.DestroyWindow(c.dpy, item.socket) }
	item.socket = 0
	item.win = 0
	remove_item(t, item)
}

@(private)
save_set :: proc(t: ^Tray, win: xlib.Window, add: bool) {
	if t.xe.xfixes {
		xfixes_change_save_set(t.c.dpy, win, add ? SAVE_SET_INSERT : SAVE_SET_DELETE, SAVE_SET_ROOT, SAVE_SET_UNMAP)
	} else if add {
		xlib.AddToSaveSet(t.c.dpy, win)
	} else {
		xlib.RemoveFromSaveSet(t.c.dpy, win)
	}
}

@(private)
socket_size :: proc(t: ^Tray) -> i32 { return t.size + 2 * SOCKET_PAD }

@(private)
xembed_find :: proc(t: ^Tray, win: xlib.Window) -> ^Item {
	if win == 0 { return nil }
	for item in t.items {
		if item.kind == .XEmbed && item.win == win { return item }
	}
	return nil
}

@(private)
socket_find :: proc(t: ^Tray, win: xlib.Window) -> ^Item {
	if win == 0 { return nil }
	for item in t.items {
		if item.kind == .XEmbed && item.socket == win { return item }
	}
	return nil
}

// _XEMBED_INFO: (version, flags); absent = version 0, mapped.
@(private)
read_xembed_info :: proc(t: ^Tray, win: xlib.Window) -> (version: uint, flags: uint, ok: bool) {
	p, found := tx.get_property(t.c, win, "_XEMBED_INFO", t.xe.xembed_info, 2)
	if !found { return 0, XEMBED_MAPPED, false }
	defer tx.property_free(p)
	if p.format != 32 || p.count < 2 { return 0, XEMBED_MAPPED, false }
	longs := ([^]uint)(p.data)[:2]
	return longs[0] & 0xFFFFFFFF, longs[1] & 0xFFFFFFFF, true
}

@(private)
send_xembed :: proc(t: ^Tray, win: xlib.Window, time: xlib.Time, message, detail, data1, data2: int) {
	ev: xlib.XEvent
	ev.xclient.type = .ClientMessage
	ev.xclient.window = win
	ev.xclient.message_type = t.xe.xembed
	ev.xclient.format = 32
	ev.xclient.data.l = {int(time), message, detail, data1, data2}
	xlib.SendEvent(t.c.dpy, win, false, {}, &ev)
}

@(private)
create_socket :: proc(t: ^Tray) -> xlib.Window {
	c := t.c
	size := socket_size(t)
	attrs: xlib.XSetWindowAttributes
	attrs.background_pixmap = xlib.Pixmap(xlib.ParentRelative)
	attrs.override_redirect = true
	attrs.event_mask = {.EnterWindow, .LeaveWindow}
	parent := t.xe.parent != 0 ? t.xe.parent : c.root
	return xlib.CreateWindow(c.dpy, parent, -size, -size, u32(size), u32(size), 0, c.depth, .InputOutput, c.visual,
	                         {.CWBackPixmap, .CWOverrideRedirect, .CWEventMask}, &attrs)
}

// SYSTEM_TRAY_REQUEST_DOCK.
@(private)
xembed_dock :: proc(t: ^Tray, win: xlib.Window, time: xlib.Time) {
	c := t.c
	if win == 0 || xembed_find(t, win) != nil { return }
	attrs: xlib.XWindowAttributes
	if xlib.GetWindowAttributes(c.dpy, win, &attrs) == 0 { return } // already gone
	version, flags, _ := read_xembed_info(t, win)
	size := socket_size(t)
	sock := create_socket(t)
	item := new(Item)
	item.kind = .XEmbed
	item.id = t.next_id
	t.next_id += 1
	item.win = win
	item.socket = sock
	item.status = .Active
	title := tx.window_title(c, win)
	if title == "" { _, title = tx.window_class(c, win) }
	item.title = clone_line(title)
	append(&t.items, item)
	// Watch it first, then take it: nothing slips in between.
	xlib.SelectInput(c.dpy, win, {.StructureNotify, .PropertyChange})
	save_set(t, win, true)
	xlib.ReparentWindow(c.dpy, win, sock, 0, 0)
	wc := xlib.XWindowChanges{x = 0, y = 0, width = size, height = size, border_width = 0}
	xlib.ConfigureWindow(c.dpy, win, {.CWX, .CWY, .CWWidth, .CWHeight, .CWBorderWidth}, &wc)
	send_xembed(t, win, time, XEMBED_EMBEDDED_NOTIFY, 0, int(sock), int(min(version, XEMBED_VERSION)))
	if flags & XEMBED_MAPPED != 0 { xlib.MapWindow(c.dpy, win) }
	tx.flush(c)
	log.infof("Tray: docked the XEmbed icon of %q (0x%x)", item.title, win)
	t.changed = true
}

// _XEMBED_INFO changed: map or unmap as the application asks.
@(private)
apply_xembed_info :: proc(t: ^Tray, item: ^Item) {
	_, flags, _ := read_xembed_info(t, item.win)
	want := flags & XEMBED_MAPPED != 0
	if want && !item.mapped {
		xlib.MapWindow(t.c.dpy, item.win)
	} else if !want && item.mapped {
		xlib.UnmapWindow(t.c.dpy, item.win)
	}
}

// Events of the manager window, the sockets and the icon windows.
@(private)
xembed_event :: proc(t: ^Tray, ev: ^xlib.XEvent) -> bool {
	xe := &t.xe
	c := t.c
	#partial switch ev.type {
	case .ClientMessage:
		cm := &ev.xclient
		if xe.manager == 0 || cm.window != xe.manager || cm.message_type != xe.opcode { return false }
		// Balloon messages (BEGIN/CANCEL_MESSAGE) are not shown.
		if cm.data.l[1] == SYSTEM_TRAY_REQUEST_DOCK {
			xembed_dock(t, xlib.Window(uint(cm.data.l[2])), xlib.Time(uint(cm.data.l[0])))
		}
		return true
	case .SelectionClear:
		sc := &ev.xselectionclear
		if xe.manager == 0 || sc.window != xe.manager || sc.selection != xe.selection { return false }
		log.info("Tray: another program took the XEmbed system tray over")
		xembed_stop(t, false)
		xembed_start(t) // waits for that one now
		return true
	case .DestroyNotify:
		w := ev.xdestroywindow.window
		if item := xembed_find(t, w); item != nil {
			log.debugf("Tray: the XEmbed icon of %q went away", item.title)
			xembed_undock(t, item, false)
			return true
		}
		if xe.other != 0 && w == xe.other {
			xe.other = 0
			xembed_start(t)
			return true
		}
		return socket_find(t, w) != nil || (xe.manager != 0 && w == xe.manager)
	case .UnmapNotify:
		if item := xembed_find(t, ev.xunmap.window); item != nil {
			if item.mapped {
				item.mapped = false
				t.changed = true
			}
			return true
		}
	case .MapNotify:
		if item := xembed_find(t, ev.xmap.window); item != nil {
			if !item.mapped {
				item.mapped = true
				item.bg_sum = 0 // repaint once placed
				t.changed = true
			}
			return true
		}
	case .ReparentNotify:
		if item := xembed_find(t, ev.xreparent.window); item != nil {
			// Only the copy reported on the icon itself (our StructureNotify):
			// milk shares one connection, and the window manager's copies (its
			// frame's or the root's) may describe an older move, e.g. the
			// release of an icon it had managed until it asked to dock.
			if ev.xreparent.event == item.win && ev.xreparent.parent != item.socket {
				// The application took its window back.
				log.debugf("Tray: the XEmbed icon of %q left the tray", item.title)
				xlib.SelectInput(c.dpy, item.win, {})
				save_set(t, item.win, false)
				xembed_undock(t, item, false)
			}
			return true
		}
	case .ConfigureNotify:
		if item := xembed_find(t, ev.xconfigure.window); item != nil {
			size := socket_size(t)
			cf := &ev.xconfigure
			if cf.x != 0 || cf.y != 0 || cf.width != size || cf.height != size {
				xlib.MoveResizeWindow(c.dpy, item.win, 0, 0, u32(size), u32(size))
			}
			return true
		}
	case .PropertyNotify:
		if item := xembed_find(t, ev.xproperty.window); item != nil {
			if ev.xproperty.atom == xe.xembed_info { apply_xembed_info(t, item) }
			return true
		}
	case .EnterNotify, .LeaveNotify:
		cr := &ev.xcrossing
		if item := socket_find(t, cr.window); item != nil {
			if cr.detail != .NotifyInferior {
				hover := ev.type == .EnterNotify ? item.id : -1
				if t.hover != hover {
					t.hover = hover
					t.changed = true
				}
			}
			return true
		}
	case .Expose:
		return socket_find(t, ev.xexpose.window) != nil
	}
	return false
}

// Move the sockets into `parent` (the bar window; 0 = park them on the root
// while the bar has no window).
@(private)
xembed_attach :: proc(t: ^Tray, parent: xlib.Window) {
	if t.xe.parent == parent { return }
	t.xe.parent = parent
	c := t.c
	size := socket_size(t)
	for item in t.items {
		if item.kind != .XEmbed || item.socket == 0 { continue }
		xlib.UnmapWindow(c.dpy, item.socket)
		xlib.ReparentWindow(c.dpy, item.socket, parent != 0 ? parent : c.root, -size, -size)
		item.placed = {}
		item.shown = false
	}
	t.hover = -1
	t.changed = true
	tx.flush(c)
}

// The icon size changed: resize the sockets and the icons.
@(private)
xembed_resize :: proc(t: ^Tray) {
	c := t.c
	size := socket_size(t)
	xembed_properties(t, t.xe.manager)
	for item in t.items {
		if item.kind != .XEmbed { continue }
		xlib.ResizeWindow(c.dpy, item.socket, u32(size), u32(size))
		xlib.MoveResizeWindow(c.dpy, item.win, 0, 0, u32(size), u32(size))
		item.placed = {}
	}
}

// After a bar frame: move the sockets placed by it, hide the others, and
// make icons repaint when the bar pixels behind them changed.
@(private)
xembed_commit :: proc(t: ^Tray) {
	c := t.c
	for item in t.items {
		if item.kind != .XEmbed || item.socket == 0 { continue }
		if !item.placed_now {
			if item.shown {
				xlib.UnmapWindow(c.dpy, item.socket)
				item.shown = false
			}
			item.placed = {}
			continue
		}
		item.placed_now = false
		moved := item.placed != item.target
		if moved {
			r := item.target
			xlib.MoveResizeWindow(c.dpy, item.socket, r.x, r.y, u32(max(r.w, 1)), u32(max(r.h, 1)))
			item.placed = r
		}
		if !item.shown {
			xlib.MapWindow(c.dpy, item.socket)
			item.shown = true
		} else if moved || item.target_sum != item.bg_sum {
			// ParentRelative backgrounds do not follow the bar's new pixmap by themselves.
			xlib.ClearArea(c.dpy, item.socket, 0, 0, 0, 0, false)
			xlib.ClearArea(c.dpy, item.win, 0, 0, 0, 0, true)
		}
		item.bg_sum = item.target_sum
	}
}
