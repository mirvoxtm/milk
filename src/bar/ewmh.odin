// EWMH state: desktops and their occupancy, the active window (title and
// icon), and keeping the override-redirect bar above managed windows.
package bar

import "core:slice"
import xlib "vendor:x11/xlib"
import tx "../tx"

APP_ICON_SIZE :: 18

// Atoms compared in the event handler, interned once.
Atoms :: struct {
	active_window, current_desktop, number_of_desktops, client_list, desktop_names: xlib.Atom,
	root_pixmap, eroot_pixmap: xlib.Atom,
	wm_check, supported: xlib.Atom,
	net_wm_name, wm_name, net_wm_icon, net_wm_state, net_wm_desktop: xlib.Atom,
	fullscreen: xlib.Atom,
	// The task list (tasks.odin).
	wm_hints, net_wm_window_type, state_hidden, state_skip_taskbar, state_attention: xlib.Atom,
}

Workspaces_State :: struct {
	count:    int,
	current:  int, // 0-based, -1 = unknown
	occupied: [dynamic]bool,
	// WMs without _NET_WM_DESKTOP (dwm): desktop on which each client was last
	// seen on screen. dwm hides clients of other tags by moving them off-screen.
	learned:  map[xlib.Window]int,
}

Active_State :: struct {
	win:      xlib.Window,
	title:    string,
	icon:     tx.Image,
	has_icon: bool,
	watching: bool, // we added PropertyChange to its event mask
}

@(private)
intern_atoms :: proc(b: ^Bar) {
	c := b.c
	b.atoms = Atoms{
		active_window      = tx.atom(c, "_NET_ACTIVE_WINDOW"),
		current_desktop    = tx.atom(c, "_NET_CURRENT_DESKTOP"),
		number_of_desktops = tx.atom(c, "_NET_NUMBER_OF_DESKTOPS"),
		client_list        = tx.atom(c, "_NET_CLIENT_LIST"),
		desktop_names      = tx.atom(c, "_NET_DESKTOP_NAMES"),
		root_pixmap        = tx.atom(c, "_XROOTPMAP_ID"),
		eroot_pixmap       = tx.atom(c, "ESETROOT_PMAP_ID"),
		wm_check           = tx.atom(c, "_NET_SUPPORTING_WM_CHECK"),
		supported          = tx.atom(c, "_NET_SUPPORTED"),
		net_wm_name        = tx.atom(c, "_NET_WM_NAME"),
		wm_name            = tx.ATOM_WM_NAME,
		net_wm_icon        = tx.atom(c, "_NET_WM_ICON"),
		net_wm_state       = tx.atom(c, "_NET_WM_STATE"),
		net_wm_desktop     = tx.atom(c, "_NET_WM_DESKTOP"),
		fullscreen         = tx.atom(c, "_NET_WM_STATE_FULLSCREEN"),
		wm_hints           = tx.atom(c, "WM_HINTS"),
		net_wm_window_type = tx.atom(c, "_NET_WM_WINDOW_TYPE"),
		state_hidden       = tx.atom(c, "_NET_WM_STATE_HIDDEN"),
		state_skip_taskbar = tx.atom(c, "_NET_WM_STATE_SKIP_TASKBAR"),
		state_attention    = tx.atom(c, "_NET_WM_STATE_DEMANDS_ATTENTION"),
	}
}

// Re-read desktops and occupancy. Returns true when anything visible changed.
@(private)
refresh_workspaces :: proc(b: ^Bar) -> bool {
	c := b.c
	ws := &b.ws
	count := 0
	if n, ok := tx.get_cardinal(c, c.root, "_NET_NUMBER_OF_DESKTOPS"); ok { count = int(min(card32(n), 64)) }
	current := -1
	if n, ok := tx.get_cardinal(c, c.root, "_NET_CURRENT_DESKTOP"); ok && int(card32(n)) < max(count, 1) { current = int(card32(n)) }

	occupied := make([]bool, count, context.temp_allocator)
	clients := tx.get_windows(c, c.root, "_NET_CLIENT_LIST")
	if len(clients) == 0 { clients = tx.get_windows(c, c.root, "_NET_CLIENT_LIST_STACKING") }
	screen := tx.screen_rect(c)
	for client in clients {
		if client == b.win { continue }
		if d, ok := tx.get_cardinal(c, client, "_NET_WM_DESKTOP"); ok {
			desk := card32(d) // 0xFFFFFFFF = sticky (all desktops): not an occupant
			if desk != 0xFFFF_FFFF && int(desk) < count { occupied[desk] = true }
			continue
		}
		// No _NET_WM_DESKTOP: learn the desktop from on-screen visibility.
		if current >= 0 && client_on_screen(b, client, screen) { ws.learned[client] = current }
		if d, known := ws.learned[client]; known && d < count { occupied[d] = true }
	}
	// Forget windows that left the client list.
	if len(ws.learned) > 0 {
		stale := make([dynamic]xlib.Window, context.temp_allocator)
		for win in ws.learned {
			if !slice.contains(clients, win) { append(&stale, win) }
		}
		for win in stale { delete_key(&ws.learned, win) }
	}

	changed := count != ws.count || current != ws.current || len(occupied) != len(ws.occupied)
	if !changed {
		for o, i in occupied {
			if o != ws.occupied[i] { changed = true; break }
		}
	}
	if changed {
		ws.count = count
		ws.current = current
		resize(&ws.occupied, count)
		copy(ws.occupied[:], occupied)
	}
	return changed
}

// Format-32 property items arrive in C longs, sign-extended on 64-bit Xlib
// (0xFFFFFFFF reads as ~0): keep the 32 bits the client actually wrote.
@(private)
card32 :: #force_inline proc(v: uint) -> u32 {
	return u32(v & 0xFFFF_FFFF)
}

@(private)
client_on_screen :: proc(b: ^Bar, win: xlib.Window, screen: tx.Rect) -> bool {
	attrs: xlib.XWindowAttributes
	if xlib.GetWindowAttributes(b.c.dpy, win, &attrs) == 0 { return false }
	if attrs.map_state != .IsViewable { return false }
	_, inside := tx.rect_intersect(tx.Rect{attrs.x, attrs.y, attrs.width, attrs.height}, screen)
	return inside
}

// Follow _NET_ACTIVE_WINDOW. Returns true when the active window changed.
@(private)
refresh_active :: proc(b: ^Bar) -> bool {
	win, ok := tx.get_window(b.c, b.c.root, "_NET_ACTIVE_WINDOW")
	if !ok || win == b.win { win = 0 }
	if win == b.active.win { return false }
	unwatch_active(b)
	clear_active(b)
	b.active.win = win
	if win != 0 {
		watch_active(b)
		load_active_title(b)
		load_active_icon(b)
	}
	return true
}

@(private)
clear_active :: proc(b: ^Bar) {
	delete(b.active.title)
	b.active.title = ""
	if b.active.has_icon { tx.image_destroy(&b.active.icon) }
	b.active.has_icon = false
	b.active.win = 0
}

// Add PropertyChange to the window's event mask for this connection without
// dropping bits selected by other components sharing the connection.
@(private)
watch_active :: proc(b: ^Bar) {
	attrs: xlib.XWindowAttributes
	if xlib.GetWindowAttributes(b.c.dpy, b.active.win, &attrs) == 0 { return }
	if .PropertyChange not_in attrs.your_event_mask {
		xlib.SelectInput(b.c.dpy, b.active.win, attrs.your_event_mask + {.PropertyChange})
		b.active.watching = true
	}
}

// While the window is still listed, the task list takes the mask over.
@(private)
unwatch_active :: proc(b: ^Bar) {
	if b.active.watching && b.active.win != 0 && !tasks_adopt_watch(b, b.active.win) {
		attrs: xlib.XWindowAttributes
		if xlib.GetWindowAttributes(b.c.dpy, b.active.win, &attrs) != 0 {
			xlib.SelectInput(b.c.dpy, b.active.win, attrs.your_event_mask - {.PropertyChange})
		}
	}
	b.active.watching = false
}

@(private)
load_active_title :: proc(b: ^Bar) -> bool {
	title := tx.window_title(b.c, b.active.win)
	if title == b.active.title { return false }
	delete(b.active.title)
	b.active.title = sanitize_line(title)
	return true
}

// _NET_WM_ICON: pick the smallest image at least APP_ICON_SIZE wide (else the
// largest) and scale it to APP_ICON_SIZE.
@(private)
load_active_icon :: proc(b: ^Bar) {
	if b.active.has_icon { tx.image_destroy(&b.active.icon) }
	b.active.has_icon = false
	data := tx.get_cardinals(b.c, b.active.win, "_NET_WM_ICON")
	best_at, best_w, best_h := -1, 0, 0
	for i := 0; i + 2 <= len(data); {
		w, h := int(card32(data[i])), int(card32(data[i + 1]))
		if w <= 0 || h <= 0 || w > 1024 || h > 1024 || i + 2 + w * h > len(data) { break }
		size, best := min(w, h), min(best_w, best_h)
		better := best_at < 0 ||
		          (size >= APP_ICON_SIZE && (best < APP_ICON_SIZE || size < best)) ||
		          (size < APP_ICON_SIZE && best < APP_ICON_SIZE && size > best)
		if better { best_at, best_w, best_h = i + 2, w, h }
		i += 2 + w * h
	}
	if best_at < 0 { return }
	src := tx.image_from_argb(data[best_at:best_at + best_w * best_h], i32(best_w), i32(best_h), context.temp_allocator)
	b.active.icon = fit_image(src, APP_ICON_SIZE)
	b.active.has_icon = true
}

@(private)
has_state :: proc(b: ^Bar, win: xlib.Window, state: xlib.Atom) -> bool {
	if win == 0 { return false }
	return slice.contains(tx.get_atoms(b.c, win, "_NET_WM_STATE"), state)
}

// A fullscreen window that overlaps the bar: the bar must stay below it.
@(private)
covers_bar :: proc(b: ^Bar, win: xlib.Window) -> bool {
	if win == 0 || win == b.win || !has_state(b, win, b.atoms.fullscreen) { return false }
	attrs: xlib.XWindowAttributes
	if xlib.GetWindowAttributes(b.c.dpy, win, &attrs) == 0 || attrs.map_state != .IsViewable { return false }
	_, overlap := tx.rect_intersect(tx.Rect{attrs.x, attrs.y, attrs.width, attrs.height}, b.rect)
	return overlap
}

// Overlay mode: raise the bar above managed windows, except fullscreen ones.
@(private)
keep_above :: proc(b: ^Bar, trigger: xlib.Window) {
	if !b.overlay || b.win == 0 || !b.mapped { return }
	if covers_bar(b, trigger) || covers_bar(b, b.active.win) { return }
	tx.raise_window(b.c, b.win)
	b.need_flush = true
}
