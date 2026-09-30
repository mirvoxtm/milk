// EWMH/ICCCM atoms and the root properties published for pagers, the bar and
// the desktop layer. Properties are written only when their value changes:
// ewmh_sync runs after every handled event and compares with a cache, so
// _NET_CURRENT_DESKTOP (which drives the wallpaper switch of the desktop
// layer) changes exactly when the visible tags of the selected monitor do.
package wm

import "core:slice"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "../tx"

WM_NAME :: "milk"

Atoms :: struct {
	utf8_string:              xlib.Atom,
	wm_protocols:             xlib.Atom,
	wm_delete:                xlib.Atom,
	wm_state:                 xlib.Atom,
	wm_take_focus:            xlib.Atom,
	net_supported:            xlib.Atom,
	net_wm_name:              xlib.Atom,
	net_wm_state:             xlib.Atom,
	net_wm_check:             xlib.Atom,
	net_wm_state_fullscreen:  xlib.Atom,
	net_active_window:        xlib.Atom,
	net_wm_window_type:       xlib.Atom,
	net_type_dialog:          xlib.Atom,
	net_type_dock:            xlib.Atom,
	net_type_desktop:         xlib.Atom,
	net_type_notification:    xlib.Atom,
	net_type_tooltip:         xlib.Atom,
	net_type_splash:          xlib.Atom,
	net_type_normal:          xlib.Atom,
	net_client_list:          xlib.Atom,
	net_client_list_stacking: xlib.Atom,
	net_desktop_names:        xlib.Atom,
	net_desktop_viewport:     xlib.Atom,
	net_number_of_desktops:   xlib.Atom,
	net_current_desktop:      xlib.Atom,
	net_wm_desktop:           xlib.Atom,
	net_workarea:             xlib.Atom,
	net_close_window:         xlib.Atom,
	net_wm_moveresize:        xlib.Atom,
	net_wm_state_sticky:      xlib.Atom,
	// Floating mode.
	net_frame_extents:              xlib.Atom,
	net_request_frame_extents:      xlib.Atom,
	net_wm_state_maximized_horz:    xlib.Atom,
	net_wm_state_maximized_vert:    xlib.Atom,
	net_wm_state_hidden:            xlib.Atom,
	net_wm_state_shaded:            xlib.Atom,
	net_wm_state_above:             xlib.Atom,
	net_wm_state_below:             xlib.Atom,
	net_wm_state_demands_attention: xlib.Atom,
	net_showing_desktop:            xlib.Atom,
	net_wm_allowed_actions:         xlib.Atom,
	net_moveresize_window:          xlib.Atom,
	net_wm_icon:                    xlib.Atom,
	wm_change_state:                xlib.Atom,
	motif_wm_hints:                 xlib.Atom,
	milk_window_menu:               xlib.Atom, // the bar's task list asks for a window menu
}

// Last values written, so that properties change only when needed.
Ewmh_Cache :: struct {
	current_desktop:   int,     // -1 = not written yet
	workarea:          tx.Rect,
	workarea_count:    int,     // desktops covered by the last _NET_WORKAREA
	clients:           [dynamic]xlib.Window, // _NET_CLIENT_LIST, in mapping order
	clients_dirty:     bool,
	stacking:          [dynamic]xlib.Window, // _NET_CLIENT_LIST_STACKING, bottom to top
	stacking_dirty:    bool,
	stacking_written:  bool,
}

ewmh_init :: proc(m: ^Manager) {
	c := m.c
	m.atoms = Atoms{
		utf8_string              = tx.atom(c, "UTF8_STRING"),
		wm_protocols             = tx.atom(c, "WM_PROTOCOLS"),
		wm_delete                = tx.atom(c, "WM_DELETE_WINDOW"),
		wm_state                 = tx.atom(c, "WM_STATE"),
		wm_take_focus            = tx.atom(c, "WM_TAKE_FOCUS"),
		net_supported            = tx.atom(c, "_NET_SUPPORTED"),
		net_wm_name              = tx.atom(c, "_NET_WM_NAME"),
		net_wm_state             = tx.atom(c, "_NET_WM_STATE"),
		net_wm_check             = tx.atom(c, "_NET_SUPPORTING_WM_CHECK"),
		net_wm_state_fullscreen  = tx.atom(c, "_NET_WM_STATE_FULLSCREEN"),
		net_active_window        = tx.atom(c, "_NET_ACTIVE_WINDOW"),
		net_wm_window_type       = tx.atom(c, "_NET_WM_WINDOW_TYPE"),
		net_type_dialog          = tx.atom(c, "_NET_WM_WINDOW_TYPE_DIALOG"),
		net_type_dock            = tx.atom(c, "_NET_WM_WINDOW_TYPE_DOCK"),
		net_type_desktop         = tx.atom(c, "_NET_WM_WINDOW_TYPE_DESKTOP"),
		net_type_notification    = tx.atom(c, "_NET_WM_WINDOW_TYPE_NOTIFICATION"),
		net_type_tooltip         = tx.atom(c, "_NET_WM_WINDOW_TYPE_TOOLTIP"),
		net_type_splash          = tx.atom(c, "_NET_WM_WINDOW_TYPE_SPLASH"),
		net_type_normal          = tx.atom(c, "_NET_WM_WINDOW_TYPE_NORMAL"),
		net_client_list          = tx.atom(c, "_NET_CLIENT_LIST"),
		net_client_list_stacking = tx.atom(c, "_NET_CLIENT_LIST_STACKING"),
		net_desktop_names        = tx.atom(c, "_NET_DESKTOP_NAMES"),
		net_desktop_viewport     = tx.atom(c, "_NET_DESKTOP_VIEWPORT"),
		net_number_of_desktops   = tx.atom(c, "_NET_NUMBER_OF_DESKTOPS"),
		net_current_desktop      = tx.atom(c, "_NET_CURRENT_DESKTOP"),
		net_wm_desktop           = tx.atom(c, "_NET_WM_DESKTOP"),
		net_workarea             = tx.atom(c, "_NET_WORKAREA"),
		net_close_window         = tx.atom(c, "_NET_CLOSE_WINDOW"),
		net_wm_moveresize        = tx.atom(c, "_NET_WM_MOVERESIZE"),
		net_wm_state_sticky      = tx.atom(c, "_NET_WM_STATE_STICKY"),
		net_frame_extents              = tx.atom(c, "_NET_FRAME_EXTENTS"),
		net_request_frame_extents      = tx.atom(c, "_NET_REQUEST_FRAME_EXTENTS"),
		net_wm_state_maximized_horz    = tx.atom(c, "_NET_WM_STATE_MAXIMIZED_HORZ"),
		net_wm_state_maximized_vert    = tx.atom(c, "_NET_WM_STATE_MAXIMIZED_VERT"),
		net_wm_state_hidden            = tx.atom(c, "_NET_WM_STATE_HIDDEN"),
		net_wm_state_shaded            = tx.atom(c, "_NET_WM_STATE_SHADED"),
		net_wm_state_above             = tx.atom(c, "_NET_WM_STATE_ABOVE"),
		net_wm_state_below             = tx.atom(c, "_NET_WM_STATE_BELOW"),
		net_wm_state_demands_attention = tx.atom(c, "_NET_WM_STATE_DEMANDS_ATTENTION"),
		net_showing_desktop            = tx.atom(c, "_NET_SHOWING_DESKTOP"),
		net_wm_allowed_actions         = tx.atom(c, "_NET_WM_ALLOWED_ACTIONS"),
		net_moveresize_window          = tx.atom(c, "_NET_MOVERESIZE_WINDOW"),
		net_wm_icon                    = tx.atom(c, "_NET_WM_ICON"),
		wm_change_state                = tx.atom(c, "WM_CHANGE_STATE"),
		motif_wm_hints                 = tx.atom(c, "_MOTIF_WM_HINTS"),
		milk_window_menu               = tx.atom(c, "_MILK_WINDOW_MENU"),
	}
	m.ewmh.current_desktop = -1
	m.ewmh.clients = make([dynamic]xlib.Window)
	m.ewmh.stacking = make([dynamic]xlib.Window)
}

ewmh_free :: proc(m: ^Manager) {
	delete(m.ewmh.clients)
	delete(m.ewmh.stacking)
}

// The supporting window, _NET_SUPPORTED and the desktop properties.
ewmh_setup :: proc(m: ^Manager) {
	a := &m.atoms
	m.wmcheckwin = xlib.CreateSimpleWindow(m.dpy, m.root, 0, 0, 1, 1, 0, 0, 0)
	check := m.wmcheckwin
	xlib.ChangeProperty(m.dpy, check, a.net_wm_check, tx.ATOM_WINDOW, 32, xlib.PropModeReplace, &check, 1)
	tx.set_utf8_string(m.c, check, "_NET_WM_NAME", WM_NAME)
	xlib.ChangeProperty(m.dpy, m.root, a.net_wm_check, tx.ATOM_WINDOW, 32, xlib.PropModeReplace, &check, 1)
	tx.set_utf8_string(m.c, m.root, "_NET_WM_NAME", WM_NAME)

	// Deliberately no _NET_WM_STRUT(_PARTIAL): milk's bar then runs as an
	// override-redirect window whose strip is reserved through set_reserved.
	supported := [?]xlib.Atom{
		a.net_supported, a.net_wm_check, a.net_wm_name, a.net_wm_state, a.net_wm_state_fullscreen,
		a.net_active_window, a.net_wm_window_type, a.net_type_dialog, a.net_type_dock, a.net_type_desktop,
		a.net_type_notification, a.net_type_tooltip, a.net_type_splash, a.net_type_normal,
		a.net_client_list, a.net_client_list_stacking, a.net_desktop_names, a.net_desktop_viewport,
		a.net_number_of_desktops, a.net_current_desktop, a.net_wm_desktop, a.net_workarea,
		a.net_close_window, a.net_wm_moveresize, a.net_wm_state_sticky,
		a.net_wm_state_hidden, a.net_wm_state_demands_attention, a.net_showing_desktop, a.net_moveresize_window,
		a.net_wm_state_maximized_horz, a.net_wm_state_maximized_vert, a.net_wm_state_shaded, a.net_wm_state_above,
		a.net_wm_state_below, a.net_frame_extents, a.net_request_frame_extents, a.net_wm_allowed_actions,
	}
	tx.set_atom_list(m.c, m.root, "_NET_SUPPORTED", supported[:])
	tx.set_cardinals(m.c, m.root, "_NET_SHOWING_DESKTOP", {0})
	ewmh_write_desktops(m)
	xlib.DeleteProperty(m.dpy, m.root, a.net_client_list)
	xlib.DeleteProperty(m.dpy, m.root, a.net_client_list_stacking)
	m.ewmh.current_desktop = -1
	m.ewmh.workarea_count = 0
	m.ewmh.clients_dirty = true
	m.ewmh.stacking_dirty = true
	m.ewmh.stacking_written = false
}

// _NET_NUMBER_OF_DESKTOPS, _NET_DESKTOP_NAMES and _NET_DESKTOP_VIEWPORT.
ewmh_write_desktops :: proc(m: ^Manager) {
	n := m.settings.tag_count
	tx.set_cardinals(m.c, m.root, "_NET_NUMBER_OF_DESKTOPS", {uint(n)})
	b := strings.builder_make(context.temp_allocator)
	for name in m.settings.desktop_names {
		strings.write_string(&b, name)
		strings.write_byte(&b, 0)
	}
	names := strings.to_string(b)
	xlib.ChangeProperty(m.dpy, m.root, m.atoms.net_desktop_names, m.atoms.utf8_string, 8, xlib.PropModeReplace,
	                    raw_data(names), i32(len(names)))
	viewport := make([]uint, 2 * n, context.temp_allocator) // one (0, 0) pair per desktop
	tx.set_cardinals(m.c, m.root, "_NET_DESKTOP_VIEWPORT", viewport)
	m.ewmh.workarea_count = 0 // force a rewrite with the new length
}

// Remove the properties that describe a running window manager.
ewmh_teardown :: proc(m: ^Manager) {
	a := &m.atoms
	if m.wmcheckwin != 0 {
		xlib.DestroyWindow(m.dpy, m.wmcheckwin)
		m.wmcheckwin = 0
	}
	for prop in ([]xlib.Atom{a.net_wm_check, a.net_supported, a.net_wm_name, a.net_client_list,
	                         a.net_client_list_stacking, a.net_workarea, a.net_showing_desktop}) {
		xlib.DeleteProperty(m.dpy, m.root, prop)
	}
	clear(&m.ewmh.clients)
	clear(&m.ewmh.stacking)
}

ewmh_client_added :: proc(m: ^Manager, c: ^Client) {
	append(&m.ewmh.clients, c.win)
	m.ewmh.clients_dirty = true
	m.ewmh.stacking_dirty = true
}

ewmh_client_removed :: proc(m: ^Manager, c: ^Client) {
	if i, found := slice.linear_search(m.ewmh.clients[:], c.win); found { ordered_remove(&m.ewmh.clients, i) }
	m.ewmh.clients_dirty = true
	m.ewmh.stacking_dirty = true
}

// _NET_WM_DESKTOP of a client: its lowest tag, 0xFFFFFFFF when it has them all.
client_desktop :: proc(m: ^Manager, c: ^Client) -> i64 {
	if c.ispip { return 0xFFFFFFFF } // on every desktop, whatever the tag count
	mask := tagmask(m)
	if m.settings.tag_count > 1 && c.tags & mask == mask { return 0xFFFFFFFF }
	return i64(lowest_tag(c.tags))
}

// Publish whatever changed since the last call.
ewmh_sync :: proc(m: ^Manager) {
	if !m.started || m.shutting_down || m.selmon == nil { return }
	a := &m.atoms
	mon := m.selmon

	current := lowest_tag(mon.tagset[mon.seltags])
	if current != m.ewmh.current_desktop {
		m.ewmh.current_desktop = current
		tx.set_cardinals(m.c, m.root, "_NET_CURRENT_DESKTOP", {uint(current)})
	}

	area := tx.Rect{mon.wx, mon.wy, mon.ww, mon.wh}
	if area != m.ewmh.workarea || m.ewmh.workarea_count != m.settings.tag_count {
		m.ewmh.workarea = area
		m.ewmh.workarea_count = m.settings.tag_count
		values := make([]uint, 4 * m.settings.tag_count, context.temp_allocator)
		for i in 0 ..< m.settings.tag_count {
			values[4 * i + 0] = uint(u32(area.x))
			values[4 * i + 1] = uint(u32(area.y))
			values[4 * i + 2] = uint(u32(area.w))
			values[4 * i + 3] = uint(u32(area.h))
		}
		tx.set_cardinals(m.c, m.root, "_NET_WORKAREA", values)
	}

	for it := m.mons; it != nil; it = it.next {
		for c := it.clients; c != nil; c = c.next {
			d := client_desktop(m, c)
			if d != c.desktop {
				c.desktop = d
				tx.set_cardinals(m.c, c.win, "_NET_WM_DESKTOP", {uint(d)})
			}
		}
	}

	if m.ewmh.clients_dirty {
		m.ewmh.clients_dirty = false
		list := m.ewmh.clients[:]
		xlib.ChangeProperty(m.dpy, m.root, a.net_client_list, tx.ATOM_WINDOW, 32, xlib.PropModeReplace,
		                    raw_data(list), i32(len(list)))
	}

	if m.ewmh.stacking_dirty {
		m.ewmh.stacking_dirty = false
		order := make([dynamic]xlib.Window, context.temp_allocator)
		for w in tx.root_children(m.c) {
			// Frames stand for their clients.
			if c := wintoclient(m, w); c != nil { append(&order, c.win) }
		}
		if !m.ewmh.stacking_written || !slice.equal(order[:], m.ewmh.stacking[:]) {
			m.ewmh.stacking_written = true
			clear(&m.ewmh.stacking)
			append(&m.ewmh.stacking, ..order[:])
			list := m.ewmh.stacking[:]
			xlib.ChangeProperty(m.dpy, m.root, a.net_client_list_stacking, tx.ATOM_WINDOW, 32, xlib.PropModeReplace,
			                    raw_data(list), i32(len(list)))
		}
	}
}
