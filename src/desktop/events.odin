// EWMH watcher (the X11 counterpart of windows/src/DesktopEvents.ps1).
//
// The registry-change notification of the Windows version becomes a
// PropertyNotify on the root window: openbox publishes _NET_CURRENT_DESKTOP
// natively and dwm does with the ewmhtags patch. milk never polls it.
package desktop

import "core:slice"
import xlib "vendor:x11/xlib"
import tx "../tx"

// Root-window events the daemon needs: property changes (active desktop,
// wallpaper pixmap, work area), top-level window changes (restacking, bars
// appearing), the root's own geometry (screen size changes) and keys typed
// while the desktop has the focus. Clicks on the empty desktop reach it only
// through milk's window manager, which selects them on the root window.
ROOT_EVENT_MASK :: xlib.EventMask{.PropertyChange, .SubstructureNotify, .StructureNotify, .KeyPress}

// The active desktop, 1-based like the Windows implementation.
current_desktop_index :: proc(c: ^tx.Connection) -> (int, bool) {
	value, ok := tx.get_cardinal(c, c.root, "_NET_CURRENT_DESKTOP")
	if !ok || value >= 0xFFFF { return 0, false }
	return int(value) + 1, true
}

// _NET_NUMBER_OF_DESKTOPS, or 1 when the window manager does not publish it.
desktop_count :: proc(c: ^tx.Connection) -> int {
	value, ok := tx.get_cardinal(c, c.root, "_NET_NUMBER_OF_DESKTOPS")
	if !ok || value == 0 || value >= 0xFFFF { return 1 }
	return int(value)
}

// Process one X event. Returns true when the event concerned one of our own
// windows; root-window notifications are acted upon but reported as false,
// since other components (the bar, the window manager) need them too.
handle_event :: proc(d: ^Daemon, ev: ^xlib.XEvent) -> bool {
	context.allocator = d.allocator
	c := d.c
	#partial switch ev.type {
	case .ButtonPress, .ButtonRelease: d.last_time = ev.xbutton.time
	case .KeyPress:                    d.last_time = ev.xkey.time
	}
	if desktop_menu_event(d, ev) || rename_event(d, ev) || clipboard_event(d, ev) { return true }
	#partial switch ev.type {
	case .PropertyNotify:
		if ev.xproperty.window == c.root { on_root_property(d, &ev.xproperty) }
		return false

	case .ButtonPress, .ButtonRelease:
		be := &ev.xbutton
		if idx := layer_cell_index(d, be.window); idx >= 0 {
			if ev.type == .ButtonPress { layer_on_button(d, idx, be) } else { layer_on_release(d, be) }
			return true
		}
		if be.window != 0 && be.window == d.indicator.window {
			if ev.type == .ButtonPress { indicator_hide(d) }
			return true
		}
		if be.window == c.root {
			// The empty desktop: left button only (the window manager's menus use the others).
			if ev.type == .ButtonPress { layer_on_root_press(d, be) } else { layer_on_release(d, be) }
		}

	case .MotionNotify:
		me := &ev.xmotion
		if layer_cell_index(d, me.window) >= 0 {
			layer_on_motion(d, me.x_root, me.y_root)
			return true
		}
		if me.window == c.root { layer_on_motion(d, me.x_root, me.y_root) }

	case .KeyPress:
		ke := &ev.xkey
		if ke.window == c.root || layer_cell_index(d, ke.window) >= 0 {
			layer_on_key(d, ke)
			return ke.window != c.root
		}

	case .ConfigureNotify:
		ce := &ev.xconfigure
		if ce.window == c.root {
			// The screen was resized (RandR); wait for the burst to settle.
			d.screen_change_at = tx.now() + COALESCE_DELAY
			return false
		}
		if is_own_window(d, ce.window) { return true }
		if ce.event == c.root {
			if ce.above == 0 {
				// Another top-level window reached the bottom of the stack: get back under it.
				layer_relower(d)
			}
			if slice.contains(d.layer.bar_windows[:], ce.window) { schedule_area_check(d) }
		}

	case .MapNotify:
		me := &ev.xmap
		if is_own_window(d, me.window) { return true }
		if me.event == c.root && looks_like_bar(d, me.window, bool(me.override_redirect)) {
			schedule_area_check(d)
		}

	case .UnmapNotify:
		ue := &ev.xunmap
		if is_own_window(d, ue.window) { return true }
		if slice.contains(d.layer.bar_windows[:], ue.window) { schedule_area_check(d) }

	case .DestroyNotify:
		de := &ev.xdestroywindow
		if is_own_window(d, de.window) { return true }
		if slice.contains(d.layer.bar_windows[:], de.window) { schedule_area_check(d) }

	case .Expose:
		// Our windows are painted by the server from their background pixmaps.
		return is_own_window(d, ev.xexpose.window)
	}
	return false
}

@(private)
on_root_property :: proc(d: ^Daemon, pe: ^xlib.XPropertyEvent) {
	switch pe.atom {
	case d.atoms.current_desktop:
		if !d.started { return }
		// Read the current value (not a queued one): a burst of switches
		// collapses into the last state.
		index, ok := current_desktop_index(d.c)
		if !ok { return } // property deleted (window manager restarting): keep the current state
		if d.waiting || index != d.area { switch_area(d, index) }
	case d.atoms.xrootpmap, d.atoms.esetroot:
		if tx.now() - d.wallpaper.last_applied < OWN_WALLPAPER_WINDOW { return } // our own feh call
		d.bg_refresh_at = tx.now() + 0.1
	case d.atoms.workarea:
		schedule_area_check(d)
	case d.atoms.active_window:
		// A window was activated: the desktop lost the "focus", drop the icon selection.
		layer_select(d, -1)
	}
}

@(private)
schedule_area_check :: proc(d: ^Daemon) {
	if len(d.layer.items) == 0 { return }
	if d.area_check_at == 0 { d.area_check_at = tx.now() + COALESCE_DELAY }
}

@(private)
is_own_window :: proc(d: ^Daemon, win: xlib.Window) -> bool {
	if win == 0 { return false }
	switch win {
	case d.indicator.window, d.layer.pointer.band_win, d.rename.window, d.clipboard.window:
		return true
	}
	return layer_cell_index(d, win) >= 0
}

// Could a newly mapped window be a panel? Docks (EWMH type or struts) and
// milk's own bar; transient override-redirect popups such as dmenu are
// ignored so that the icons do not jump while they are open.
@(private)
looks_like_bar :: proc(d: ^Daemon, win: xlib.Window, override_redirect: bool) -> bool {
	c := d.c
	for t in tx.get_atoms(c, win, "_NET_WM_WINDOW_TYPE") {
		if t == d.atoms.type_dock { return true }
	}
	if len(tx.get_cardinals(c, win, "_NET_WM_STRUT_PARTIAL")) >= 4 { return true }
	if len(tx.get_cardinals(c, win, "_NET_WM_STRUT")) >= 4 { return true }
	if override_redirect {
		instance, class := tx.window_class(c, win)
		if class == "Milk" || instance == "milk" || class == "dwm" { return true }
	}
	return false
}
