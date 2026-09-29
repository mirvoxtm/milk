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
// appearing) and the root's own geometry (screen size changes).
ROOT_EVENT_MASK :: xlib.EventMask{.PropertyChange, .SubstructureNotify, .StructureNotify}

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
// since other components (the bar) need them too.
handle_event :: proc(d: ^Daemon, ev: ^xlib.XEvent) -> bool {
	context.allocator = d.allocator
	c := d.c
	#partial switch ev.type {
	case .PropertyNotify:
		if ev.xproperty.window == c.root { on_root_property(d, &ev.xproperty) }
		return false

	case .ButtonPress, .ButtonRelease:
		win := ev.xbutton.window
		if idx := layer_cell_index(d, win); idx >= 0 {
			if ev.type == .ButtonPress { layer_on_button(d, idx, &ev.xbutton) }
			return true
		}
		if win != 0 && win == d.indicator.window {
			if ev.type == .ButtonPress { indicator_hide(d) }
			return true
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
	if d.cfg.linux.shortcuts.mode != "layer" { return }
	if d.area_check_at == 0 { d.area_check_at = tx.now() + COALESCE_DELAY }
}

@(private)
is_own_window :: proc(d: ^Daemon, win: xlib.Window) -> bool {
	if win == 0 { return false }
	if win == d.indicator.window { return true }
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
