// Package tray: the system tray behind the bar's "tray" widget.
//
// Two protocols feed one list of icons, kept in registration order:
//
// StatusNotifierItem (sni.odin, dbusmenu.odin): milk serves
// org.kde.StatusNotifierWatcher on the session bus (or registers as a host
// with the program that already does) and reads each item's properties with
// asynchronous calls on a private libdbus connection driven by the milk poll
// loop, like the notification server: nothing ever waits for an
// application. The bar draws the items' pictures (icons.odin) and forwards
// their clicks: Activate, SecondaryActivate, Scroll, and the item's
// com.canonical.dbusmenu menu shown with milk's popup menus.
//
// XEmbed (xembed.odin): milk owns the _NET_SYSTEM_TRAY_S<screen> selection
// (unless another tray does) and reparents the icon windows that dock into
// small child windows of the bar, where the applications paint and take
// their clicks themselves.
//
// The owner (the bar) forwards every X event to handle_event, polls poll_fd
// and calls handle_fd when it is readable, calls tick every loop iteration,
// redraws when take_changed says so, places the icons of each frame with
// place_socket / commit, and moves the sockets with attach when its window
// is recreated.
package tray

import "base:runtime"
import "core:log"
import "core:strings"
import xlib "vendor:x11/xlib"
import config "../config"
import desktop "../desktop"
import menu "../menu"
import tx "../tx"

Kind :: enum { SNI, XEmbed }

Status :: enum { Active, Passive, Needs_Attention }

Item :: struct {
	id:               int, // registration order (stable)
	kind:             Kind,
	title:            string, // Title or Id (SNI), the window title (XEmbed); owned
	status:           Status,

	// StatusNotifierItem
	service:          string, // the bus name it registered with (owned)
	path:             string, // its object path (owned)
	owner:            string, // the unique name of its process ("" until known; owned)
	key:              string, // service + path, as RegisteredStatusNotifierItems lists it (owned)
	icon_name:        string,
	attention_name:   string,
	theme_path:       string, // IconThemePath
	menu_path:        string, // com.canonical.dbusmenu object ("" = none)
	item_is_menu:     bool,
	pixmap:           tx.Image, // IconPixmap fitted to the icon size (rgba == nil = none)
	attention_pixmap: tx.Image,
	picture:          tx.Image, // what the bar draws (rgba == nil: a generic glyph)
	ready:            bool,     // the properties arrived once
	fetching:         bool,     // a GetAll is on its way
	refetch:          bool,     // something changed meanwhile: ask again

	// XEmbed
	win:              xlib.Window, // the application's icon window
	socket:           xlib.Window, // milk's window around it (a child of the bar)
	mapped:           bool,        // the icon window is mapped (it asks through _XEMBED_INFO)
	shown:            bool,        // the socket is mapped
	placed:           tx.Rect,     // the socket's rectangle in the bar window
	bg_sum:           u64,         // checksum of the bar pixels behind it at the last repaint
	target:           tx.Rect,     // set by place_socket for the frame being drawn
	target_sum:       u64,
	placed_now:       bool,
}

@(private)
Raw_Pixmap :: struct {
	w, h: i32,
	data: []u8, // ARGB32 in network byte order; points into the D-Bus message
}

Tray :: struct {
	c:            ^tx.Connection,
	cfg:          ^config.Config, // owned by the caller (the bar's)
	allocator:    runtime.Allocator,
	size:         i32, // icon size in pixels
	items:        [dynamic]^Item,
	next_id:      int,
	changed:      bool, // the bar must lay the icons out again
	hover:        int,  // XEmbed item under the pointer (-1 = none)
	bus:          Bus,
	xe:           XEmbed,
	loader:       desktop.Icon_Loader, // icon theme lookups (the desktop icons' loader)
	loader_ready: bool,
	theme_files:  map[string]string, // "IconThemePath\x00name" -> file ("" = none)
	menu:         menu.Menu,
	menu_item:    int, // the item whose menu is open (-1 = none)
	menu_time:    xlib.Time,
	menu_req:     Menu_Request, // the menu asked for last
	activate_req: Menu_Request, // where the last left click happened (Activate errors open the menu there)
	next_request: int,
}

// Start the tray: the session bus (watcher or host) and the XEmbed selection.
create :: proc(c: ^tx.Connection, cfg: ^config.Config, size: i32) -> ^Tray {
	t := new(Tray)
	t.c = c
	t.cfg = cfg
	t.allocator = context.allocator
	t.size = max(size, 8)
	t.items = make([dynamic]^Item)
	t.theme_files = make(map[string]string)
	t.hover = -1
	t.menu_item = -1
	t.menu_req.item = -1
	t.activate_req.item = -1
	bus_open(t)
	xembed_init(t)
	return t
}

// Hand the icons back, leave the bus and free everything.
destroy :: proc(t: ^Tray) {
	if t == nil { return }
	context.allocator = t.allocator
	xembed_stop(t, true)
	drop_sni_items(t)
	bus_close(t)
	menu.destroy(&t.menu)
	for item in t.items { free_item(item) }
	delete(t.items)
	if t.loader_ready { desktop.icons_destroy(&t.loader) }
	for k, v in t.theme_files {
		delete(k)
		delete(v)
	}
	delete(t.theme_files)
	free(t)
}

// A new configuration (reload or new colours): `cfg` replaces the previous
// one; a new icon size reloads every picture.
configure :: proc(t: ^Tray, cfg: ^config.Config, icon_size: i32) {
	if t == nil { return }
	context.allocator = t.allocator
	menu.close(&t.menu) // its style borrowed from the previous configuration
	t.menu_item = -1
	t.cfg = cfg
	size := max(icon_size, 8)
	if size == t.size {
		xembed_properties(t, t.xe.manager) // the colours
		return
	}
	t.size = size
	if t.loader_ready {
		desktop.icons_destroy(&t.loader)
		t.loader_ready = false
	}
	xembed_resize(t)
	for item in t.items {
		if item.kind != .SNI { continue }
		tx.image_destroy(&item.pixmap)
		tx.image_destroy(&item.attention_pixmap)
		request_properties(t, item)
	}
	t.changed = true
}

// Returns true when the event was the tray's (its menu, the tray manager
// window, the sockets and the icon windows).
handle_event :: proc(t: ^Tray, ev: ^xlib.XEvent) -> bool {
	if t == nil || ev == nil { return false }
	context.allocator = t.allocator
	if menu.is_open(&t.menu) && menu.handle_event(&t.menu, ev) {
		if id, ok := menu.take_result(&t.menu); ok { menu_chosen(t, id) }
		if !menu.is_open(&t.menu) {
			t.menu_item = -1 // its slot loses the highlight
			t.changed = true
		}
		return true
	}
	return xembed_event(t, ev)
}

// The session bus socket (-1 = none).
poll_fd :: proc(t: ^Tray) -> i32 {
	if t == nil || t.bus.conn == nil { return -1 }
	return t.bus.fd
}

// poll_fd is readable.
handle_fd :: proc(t: ^Tray) {
	if t == nil { return }
	context.allocator = t.allocator
	bus_pump(t, true)
	tx.flush(t.c)
}

tick :: proc(t: ^Tray, now: f64) {
	if t == nil { return }
	context.allocator = t.allocator
	// Messages may already sit in libdbus' queue (read during a write).
	bus_pump(t, false)
	bus_expire(t, now)
	bus_write(t)
	if t.menu_item >= 0 && !menu.is_open(&t.menu) {
		t.menu_item = -1
		t.changed = true
	}
}

// Seconds until tick must run again (-1 = idle).
next_timeout :: proc(t: ^Tray, now: f64) -> f64 {
	if t == nil { return -1 }
	if t.changed || bus_has_input(t) { return 0 }
	timeout := -1.0
	if d := bus_deadline(t); d >= 0 { timeout = max(d - now, 0) }
	if bus_has_output(t) && (timeout < 0 || timeout > 0.01) { timeout = 0.01 }
	return timeout
}

// True once after the icons changed (appeared, left, new pictures, hover).
take_changed :: proc(t: ^Tray) -> bool {
	if t == nil || !t.changed { return false }
	t.changed = false
	return true
}

// The icons to show, in registration order: SNI items that are not Passive,
// mapped XEmbed icons.
visible :: proc(t: ^Tray, allocator := context.temp_allocator) -> []^Item {
	out := make([dynamic]^Item, allocator)
	if t == nil { return out[:] }
	for item in t.items {
		switch item.kind {
		case .SNI:
			if item.ready && item.status != .Passive { append(&out, item) }
		case .XEmbed:
			if item.mapped && item.socket != 0 { append(&out, item) }
		}
	}
	return out[:]
}

// The XEmbed icon under the pointer (-1 = none; SNI hover is the bar's).
hovered :: proc(t: ^Tray) -> int { return t != nil ? t.hover : -1 }

// The item whose menu is open (-1 = none): its slot stays lit.
menu_owner :: proc(t: ^Tray) -> int { return t != nil ? t.menu_item : -1 }

// A click on an SNI icon. (px, py): the pointer; (mx, my): the corner where
// its menu opens (the bar's inner edge); both in screen coordinates.
click :: proc(t: ^Tray, id: int, button: int, px, py, mx, my: i32, time: xlib.Time) {
	if t == nil { return }
	context.allocator = t.allocator
	item := find_item(t, id)
	if item == nil || item.kind != .SNI { return }
	req := Menu_Request{item = id, x = mx, y = my, px = px, py = py, time = time}
	switch button {
	case 1:
		if item.item_is_menu && item.menu_path != "" {
			open_item_menu(t, item, req)
		} else {
			t.activate_req = req
			item_call_xy(t, item, "Activate", px, py, Call.Activate)
		}
	case 2:
		item_call_xy(t, item, "SecondaryActivate", px, py, nil)
	case 3:
		open_item_menu(t, item, req)
	case 4:
		item_scroll(t, item, 120)
	case 5:
		item_scroll(t, item, -120)
	}
	bus_write(t)
}

// Where an XEmbed icon goes in the frame being drawn (bar window
// coordinates) and a checksum of the bar pixels behind it.
place_socket :: proc(t: ^Tray, item: ^Item, r: tx.Rect, sum: u64) {
	if t == nil || item == nil || item.kind != .XEmbed { return }
	item.target = r
	item.target_sum = sum
	item.placed_now = true
}

// Size of an XEmbed icon's window (centred in its slot like the pictures).
socket_extent :: proc(t: ^Tray) -> i32 { return socket_size(t) }

// The frame is on screen (its background set): move, show or hide the sockets.
commit :: proc(t: ^Tray) {
	if t == nil { return }
	context.allocator = t.allocator
	xembed_commit(t)
}

// The bar window the sockets live in (0: the bar has no window right now).
attach :: proc(t: ^Tray, parent: xlib.Window) {
	if t == nil { return }
	context.allocator = t.allocator
	xembed_attach(t, parent)
}

// ---------------------------------------------------------------------------
// The item list
// ---------------------------------------------------------------------------
@(private)
find_item :: proc(t: ^Tray, id: int) -> ^Item {
	if id < 0 { return nil }
	for item in t.items {
		if item.id == id { return item }
	}
	return nil
}

// Take an item off the list and free it (an XEmbed icon's windows must be
// dealt with first: xembed_undock).
@(private)
remove_item :: proc(t: ^Tray, item: ^Item) {
	for it, i in t.items {
		if it != item { continue }
		ordered_remove(&t.items, i)
		break
	}
	if item.kind == .SNI {
		log.debugf("Tray: item %s left", item.key)
		emit_watcher_signal(t, "StatusNotifierItemUnregistered", item.key, true)
	}
	drop_pending(t, item.id)
	if t.menu_item == item.id {
		menu.close(&t.menu)
		t.menu_item = -1
	}
	if t.hover == item.id { t.hover = -1 }
	free_item(item)
	t.changed = true
}

@(private)
free_item :: proc(item: ^Item) {
	delete(item.title)
	delete(item.service)
	delete(item.path)
	delete(item.owner)
	delete(item.key)
	delete(item.icon_name)
	delete(item.attention_name)
	delete(item.theme_path)
	delete(item.menu_path)
	tx.image_destroy(&item.pixmap)
	tx.image_destroy(&item.attention_pixmap)
	tx.image_destroy(&item.picture)
	free(item)
}

// One line, cloned.
@(private)
clone_line :: proc(s: string) -> string {
	line, _ := strings.replace_all(strings.trim_space(s), "\n", " ", context.temp_allocator)
	return strings.clone(line)
}
