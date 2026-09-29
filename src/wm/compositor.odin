// milk addition: rounded corners with and without a compositor.
//
// Without a compositor milk cuts the corners of its windows with SHAPE
// (anim.odin, apply_corners), which leaves them jagged. lactase, milk's
// compositor, draws anti-aliased corners itself and says so with
// _LACTASE_CORNERS on the window that owns the compositor selection; while
// it does, the windows stay rectangular for it to round. When it stops (or
// crashes) the selection owner goes away and the shapes come back.
package wm

import "core:fmt"
import "core:log"
import xlib "vendor:x11/xlib"
import tx "../tx"

foreign import xfixes_cm "system:Xfixes"

@(private="file") SELECTION_ANY_MASK :: uint(1 << 0 | 1 << 1 | 1 << 2) // owner set, window destroyed, client closed
@(private="file") XFIXES_SELECTION_NOTIFY :: 0

@(private="file")
XFixes_Selection_Event :: struct {
	type:                i32,
	serial:              uint,
	send_event:          b32,
	display:             ^xlib.Display,
	window:              xlib.Window,
	subtype:             i32,
	owner:               xlib.Window,
	selection:           xlib.Atom,
	timestamp:           xlib.Time,
	selection_timestamp: xlib.Time,
}

@(default_calling_convention="c")
foreign xfixes_cm {
	@(link_name="XFixesQueryExtension")       xfixes_query  :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	@(link_name="XFixesSelectSelectionInput") xfixes_select :: proc(dpy: ^xlib.Display, win: xlib.Window, selection: xlib.Atom, event_mask: uint) ---
}

// Follow the compositor selection (called once the window manager runs).
compositor_watch :: proc(m: ^Manager) {
	error_base: i32
	if !xfixes_query(m.dpy, &m.cm.event_base, &error_base) { return }
	m.cm.watching = true
	m.cm.selection = tx.atom(m.c, fmt.tprintf("_NET_WM_CM_S%d", m.c.screen))
	m.cm.corners_atom = tx.atom(m.c, "_LACTASE_CORNERS")
	xfixes_select(m.dpy, m.root, m.cm.selection, SELECTION_ANY_MASK)
	compositor_check(m)
}

// Selection changes and _LACTASE_CORNERS updates; true when the event was one.
compositor_event :: proc(m: ^Manager, ev: ^xlib.XEvent) -> bool {
	if !m.cm.watching { return false }
	if i32(ev.type) == m.cm.event_base + XFIXES_SELECTION_NOTIFY {
		se := (^XFixes_Selection_Event)(ev)
		if se.selection != m.cm.selection { return false }
		compositor_check(m)
		return true
	}
	if ev.type == .PropertyNotify && m.cm.owner != 0 && ev.xproperty.window == m.cm.owner && ev.xproperty.atom == m.cm.corners_atom {
		compositor_check(m)
		return true
	}
	return false
}

// Does the compositor round the corners? Re-shape every window when that changed.
compositor_check :: proc(m: ^Manager) {
	owner := xlib.GetSelectionOwner(m.dpy, m.cm.selection)
	rounds := false
	if owner != 0 {
		_, class := tx.window_class(m.c, owner)
		if class == "Lactase" {
			if owner != m.cm.owner { xlib.SelectInput(m.dpy, owner, {.PropertyChange}) }
			radius, ok := tx.get_cardinal(m.c, owner, "_LACTASE_CORNERS")
			rounds = ok && radius > 0
		}
	}
	m.cm.owner = owner
	if rounds == m.cm.rounds_corners { return }
	m.cm.rounds_corners = rounds
	log.infof("wm: %s", rounds ? "lactase rounds the window corners" : "rounding window corners with SHAPE")
	if m.started && !m.shutting_down { corners_refresh_all(m) }
}
