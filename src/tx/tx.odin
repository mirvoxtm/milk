// Package tx: the thin X11 layer shared by every milk component.
//
// It wraps vendor:x11/xlib with the handful of things milk needs: one
// connection, cached atoms, EWMH property access, RandR monitor geometry,
// unmanaged/dock windows, and a software canvas that is uploaded as a
// server-side pixmap. Text is rendered with Xft (see text.odin).
package tx

import "base:runtime"
import "core:log"
import "core:slice"
import "core:strings"
import "core:time"
import xlib "vendor:x11/xlib"

// Predefined atoms (X11 protocol constants).
ATOM_ATOM     :: xlib.Atom(4)
ATOM_CARDINAL :: xlib.Atom(6)
ATOM_PIXMAP   :: xlib.Atom(20)
ATOM_STRING   :: xlib.Atom(31)
ATOM_WINDOW   :: xlib.Atom(33)
ATOM_WM_NAME  :: xlib.Atom(39)

PROP_MODE_REPLACE :: 0

Rect :: struct { x, y, w, h: i32 }

Connection :: struct {
	dpy:      ^xlib.Display,
	screen:   i32,
	root:     xlib.Window,
	depth:    i32,
	visual:   ^xlib.Visual,
	colormap: xlib.Colormap,
	black:    uint,
	fd:       i32,
	atoms:    map[string]xlib.Atom,
	names:    map[xlib.Atom]string,
}

// Called from the Xlib IO-error handler before the process exits (the server went away).
io_error_cleanup: proc()

@(private)
start_tick := time.tick_now()

// Monotonic seconds since the program started.
now :: proc() -> f64 {
	return time.duration_seconds(time.tick_since(start_tick))
}

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------
connect :: proc(name: cstring = nil) -> (c: ^Connection, ok: bool) {
	dpy := xlib.OpenDisplay(name)
	if dpy == nil {
		return nil, false
	}
	c = new(Connection)
	c.dpy = dpy
	c.screen = xlib.DefaultScreen(dpy)
	c.root = xlib.RootWindow(dpy, c.screen)
	c.depth = xlib.DefaultDepth(dpy, c.screen)
	c.visual = xlib.DefaultVisual(dpy, c.screen)
	c.colormap = xlib.DefaultColormap(dpy, c.screen)
	c.black = xlib.BlackPixel(dpy, c.screen)
	c.fd = xlib.ConnectionNumber(dpy)
	xlib.SetErrorHandler(quiet_error_handler)
	xlib.SetIOErrorHandler(io_error_handler)
	return c, true
}

disconnect :: proc(c: ^Connection) {
	if c == nil { return }
	xlib.CloseDisplay(c.dpy)
	for key, _ in c.atoms { delete(key) }
	delete(c.atoms)
	delete(c.names)
	free(c)
}

flush :: proc(c: ^Connection) { xlib.Flush(c.dpy) }
sync  :: proc(c: ^Connection) { xlib.Sync(c.dpy, false) }

pending :: proc(c: ^Connection) -> i32 { return xlib.Pending(c.dpy) }

next_event :: proc(c: ^Connection, ev: ^xlib.XEvent) { xlib.NextEvent(c.dpy, ev) }

@(private)
quiet_error_handler :: proc "c" (dpy: ^xlib.Display, ev: ^xlib.XErrorEvent) -> i32 {
	// Stale windows/pixmaps (a client vanished between our query and our request)
	// are expected; log and continue instead of aborting like Xlib's default.
	context = runtime.default_context()
	log.debugf("X error %d on request %d (resource 0x%x)", ev.error_code, ev.request_code, ev.resourceid)
	return 0
}

@(private)
io_error_handler :: proc "c" (dpy: ^xlib.Display) -> i32 {
	context = runtime.default_context()
	if io_error_cleanup != nil { io_error_cleanup() }
	runtime.exit(0)
}

// ---------------------------------------------------------------------------
// Atoms
// ---------------------------------------------------------------------------
atom :: proc(c: ^Connection, name: string) -> xlib.Atom {
	if a, found := c.atoms[name]; found { return a }
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	a := xlib.InternAtom(c.dpy, cname, false)
	key := strings.clone(name)
	c.atoms[key] = a
	c.names[a] = key
	return a
}

atom_name :: proc(c: ^Connection, a: xlib.Atom) -> string {
	if n, found := c.names[a]; found { return n }
	cname := xlib.GetAtomName(c.dpy, a)
	if cname == nil { return "" }
	defer xlib.Free(rawptr(cname))
	key := strings.clone(string(cname))
	c.atoms[key] = a
	c.names[a] = key
	return key
}

// ---------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------
Property :: struct {
	type:   xlib.Atom,
	format: i32,
	data:   rawptr,
	count:  uint,
}

get_property :: proc(c: ^Connection, win: xlib.Window, name: string, req_type: xlib.Atom, max_longs := 1 << 20) -> (p: Property, ok: bool) {
	act_type: xlib.Atom
	act_format: i32
	nitems, after: uint
	data: rawptr
	status := xlib.GetWindowProperty(c.dpy, win, atom(c, name), 0, max_longs, false, req_type,
	                                 &act_type, &act_format, &nitems, &after, &data)
	if status != 0 { return }
	if data == nil { return }
	if nitems == 0 {
		xlib.Free(data)
		return
	}
	return Property{act_type, act_format, data, nitems}, true
}

property_free :: proc(p: Property) {
	if p.data != nil { xlib.Free(p.data) }
}

// CARDINAL/WINDOW/PIXMAP properties of format 32 arrive as C longs.
@(private)
property_longs :: proc(c: ^Connection, win: xlib.Window, name: string, req_type: xlib.Atom, allocator := context.temp_allocator) -> []uint {
	p, ok := get_property(c, win, name, req_type)
	if !ok { return nil }
	defer property_free(p)
	if p.format != 32 { return nil }
	// Xlib stores format-32 values in C longs and sign-extends them on 64-bit,
	// so 0xFFFFFFFF ("all desktops") would read as all ones: mask to 32 bits.
	src := ([^]uint)(p.data)[:p.count]
	out := make([]uint, len(src), allocator)
	for v, i in src { out[i] = v & 0xFFFFFFFF }
	return out
}

get_cardinals :: proc(c: ^Connection, win: xlib.Window, name: string, allocator := context.temp_allocator) -> []uint {
	return property_longs(c, win, name, ATOM_CARDINAL, allocator)
}

get_cardinal :: proc(c: ^Connection, win: xlib.Window, name: string) -> (value: uint, ok: bool) {
	values := get_cardinals(c, win, name)
	if len(values) == 0 { return 0, false }
	return values[0], true
}

get_windows :: proc(c: ^Connection, win: xlib.Window, name: string, allocator := context.temp_allocator) -> []xlib.Window {
	longs := property_longs(c, win, name, ATOM_WINDOW, allocator)
	return transmute([]xlib.Window)longs
}

get_window :: proc(c: ^Connection, win: xlib.Window, name: string) -> (xlib.Window, bool) {
	wins := get_windows(c, win, name)
	if len(wins) == 0 { return 0, false }
	return wins[0], true
}

get_atoms :: proc(c: ^Connection, win: xlib.Window, name: string, allocator := context.temp_allocator) -> []xlib.Atom {
	longs := property_longs(c, win, name, ATOM_ATOM, allocator)
	return transmute([]xlib.Atom)longs
}

get_pixmap_id :: proc(c: ^Connection, win: xlib.Window, name: string) -> (xlib.Pixmap, bool) {
	longs := property_longs(c, win, name, ATOM_PIXMAP)
	if len(longs) == 0 || longs[0] == 0 { return 0, false }
	return xlib.Pixmap(longs[0]), true
}

// NUL-separated string list (UTF8_STRING first, then STRING).
get_utf8_strings :: proc(c: ^Connection, win: xlib.Window, name: string, allocator := context.temp_allocator) -> []string {
	p, ok := get_property(c, win, name, atom(c, "UTF8_STRING"))
	if !ok { p, ok = get_property(c, win, name, ATOM_STRING) }
	if !ok { return nil }
	defer property_free(p)
	if p.format != 8 { return nil }
	raw := string(([^]u8)(p.data)[:p.count])
	parts := make([dynamic]string, allocator)
	for part in strings.split(raw, "\x00", context.temp_allocator) {
		if len(part) > 0 { append(&parts, strings.clone(part, allocator)) }
	}
	return parts[:]
}

get_utf8_string :: proc(c: ^Connection, win: xlib.Window, name: string, allocator := context.temp_allocator) -> string {
	parts := get_utf8_strings(c, win, name, allocator)
	if len(parts) == 0 { return "" }
	return parts[0]
}

// A window's title: _NET_WM_NAME, falling back to WM_NAME.
window_title :: proc(c: ^Connection, win: xlib.Window, allocator := context.temp_allocator) -> string {
	title := get_utf8_string(c, win, "_NET_WM_NAME", allocator)
	if title == "" { title = get_utf8_string(c, win, "WM_NAME", allocator) }
	return title
}

window_class :: proc(c: ^Connection, win: xlib.Window, allocator := context.temp_allocator) -> (instance, class: string) {
	parts := get_utf8_strings(c, win, "WM_CLASS", allocator)
	if len(parts) > 0 { instance = parts[0] }
	if len(parts) > 1 { class = parts[1] }
	return
}

// Name of the running window manager (via _NET_SUPPORTING_WM_CHECK).
wm_name :: proc(c: ^Connection, allocator := context.temp_allocator) -> string {
	check, ok := get_window(c, c.root, "_NET_SUPPORTING_WM_CHECK")
	if !ok { return "" }
	return get_utf8_string(c, check, "_NET_WM_NAME", allocator)
}

set_atom_list :: proc(c: ^Connection, win: xlib.Window, name: string, atoms: []xlib.Atom) {
	xlib.ChangeProperty(c.dpy, win, atom(c, name), ATOM_ATOM, 32, PROP_MODE_REPLACE, raw_data(atoms), i32(len(atoms)))
}

set_cardinals :: proc(c: ^Connection, win: xlib.Window, name: string, values: []uint) {
	xlib.ChangeProperty(c.dpy, win, atom(c, name), ATOM_CARDINAL, 32, PROP_MODE_REPLACE, raw_data(values), i32(len(values)))
}

set_utf8_string :: proc(c: ^Connection, win: xlib.Window, name: string, value: string) {
	xlib.ChangeProperty(c.dpy, win, atom(c, name), atom(c, "UTF8_STRING"), 8, PROP_MODE_REPLACE, raw_data(value), i32(len(value)))
}

// The wallpaper pixmap published by feh (or any other root setter).
root_pixmap :: proc(c: ^Connection) -> (xlib.Pixmap, bool) {
	for name in ([]string{"_XROOTPMAP_ID", "ESETROOT_PMAP_ID"}) {
		pm, ok := get_pixmap_id(c, c.root, name)
		if !ok { continue }
		root: xlib.Window
		x, y: i32
		w, h, border, depth: u32
		if xlib.GetGeometry(c.dpy, xlib.Drawable(pm), &root, &x, &y, &w, &h, &border, &depth) == xlib.Status(0) { continue }
		if i32(depth) != c.depth || w == 0 || h == 0 { continue }
		return pm, true
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------
rect_intersect :: proc(a, b: Rect) -> (Rect, bool) {
	x := max(a.x, b.x)
	y := max(a.y, b.y)
	right := min(a.x + a.w, b.x + b.w)
	bottom := min(a.y + a.h, b.y + b.h)
	if right <= x || bottom <= y { return {}, false }
	return {x, y, right - x, bottom - y}, true
}

rect_contains :: proc(r: Rect, x, y: i32) -> bool {
	return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h
}

screen_rect :: proc(c: ^Connection) -> Rect {
	root: xlib.Window
	x, y: i32
	w, h, border, depth: u32
	xlib.GetGeometry(c.dpy, xlib.Drawable(c.root), &root, &x, &y, &w, &h, &border, &depth)
	return {0, 0, i32(w), i32(h)}
}

drawable_size :: proc(c: ^Connection, d: xlib.Drawable) -> (w, h: i32, ok: bool) {
	root: xlib.Window
	x, y: i32
	bw, bh, border, depth: u32
	if xlib.GetGeometry(c.dpy, d, &root, &x, &y, &bw, &bh, &border, &depth) == xlib.Status(0) { return }
	return i32(bw), i32(bh), true
}

Monitor :: struct {
	name:    string,
	primary: bool,
	rect:    Rect,
}

foreign import xrandr_extra "system:Xrandr"
@(default_calling_convention="c")
foreign xrandr_extra {
	XRRFreeMonitors :: proc(monitors: [^]xlib.XRRMonitorInfo) ---
}

// Active RandR monitors (name, primary flag, geometry). Falls back to the whole screen.
monitors :: proc(c: ^Connection, allocator := context.temp_allocator) -> []Monitor {
	count: i32
	infos := xlib.XRRGetMonitors(c.dpy, c.root, true, &count)
	result := make([dynamic]Monitor, allocator)
	if infos != nil {
		defer XRRFreeMonitors(infos)
		for i in 0 ..< int(count) {
			mi := infos[i]
			if mi.width <= 0 || mi.height <= 0 { continue }
			append(&result, Monitor{
				name = strings.clone(atom_name(c, mi.name), allocator),
				primary = bool(mi.primary),
				rect = {mi.x, mi.y, mi.width, mi.height},
			})
		}
	}
	if len(result) == 0 {
		append(&result, Monitor{name = "screen", primary = true, rect = screen_rect(c)})
	}
	return result[:]
}

// The monitor called `preference` ("primary" or a RandR output name).
monitor_rect :: proc(c: ^Connection, preference := "primary") -> Rect {
	mons := monitors(c)
	if preference != "primary" {
		for m in mons { if m.name == preference { return m.rect } }
		log.debugf("Monitor %q not found; using the primary monitor", preference)
	}
	for m in mons { if m.primary { return m.rect } }
	best := mons[0]
	for m in mons[1:] {
		if m.rect.y < best.rect.y || (m.rect.y == best.rect.y && m.rect.x < best.rect.x) { best = m }
	}
	return best.rect
}

// _NET_WORKAREA for a 0-based desktop index, when the WM publishes it.
workarea :: proc(c: ^Connection, desktop_index: int = 0) -> (Rect, bool) {
	values := get_cardinals(c, c.root, "_NET_WORKAREA")
	if len(values) < 4 { return {}, false }
	offset := desktop_index * 4
	if offset + 4 > len(values) { offset = 0 }
	r := Rect{i32(values[offset]), i32(values[offset + 1]), i32(values[offset + 2]), i32(values[offset + 3])}
	if r.w <= 0 || r.h <= 0 { return {}, false }
	return r, true
}

// Panels occupying screen edges: struts published by docks, plus full-width
// override-redirect strips such as dwm's own bar.
bars :: proc(c: ^Connection, monitor: Rect, exclude: []xlib.Window = nil, allocator := context.temp_allocator) -> []Rect {
	root, parent: xlib.Window
	children: [^]xlib.Window
	nchildren: u32
	found := make([dynamic]Rect, allocator)
	if xlib.QueryTree(c.dpy, c.root, &root, &parent, &children, &nchildren) == xlib.Status(0) { return found[:] }
	defer if children != nil { xlib.Free(children) }
	screen := screen_rect(c)
	for i in 0 ..< int(nchildren) {
		child := children[i]
		if slice.contains(exclude, child) { continue }
		attrs: xlib.XWindowAttributes
		if xlib.GetWindowAttributes(c.dpy, child, &attrs) == 0 { continue }
		if attrs.map_state != .IsViewable { continue }
		strut := get_cardinals(c, child, "_NET_WM_STRUT_PARTIAL")
		if len(strut) < 4 { strut = get_cardinals(c, child, "_NET_WM_STRUT") }
		if len(strut) >= 4 {
			left, right, top, bottom := i32(strut[0]), i32(strut[1]), i32(strut[2]), i32(strut[3])
			if top > 0 { append(&found, Rect{0, 0, screen.w, top}) }
			if bottom > 0 { append(&found, Rect{0, screen.h - bottom, screen.w, bottom}) }
			if left > 0 { append(&found, Rect{0, 0, left, screen.h}) }
			if right > 0 { append(&found, Rect{screen.w - right, 0, right, screen.h}) }
			continue
		}
		if !attrs.override_redirect { continue }
		at_top := abs(attrs.y - monitor.y) <= 2
		at_bottom := abs((attrs.y + attrs.height) - (monitor.y + monitor.h)) <= 2
		if attrs.width >= monitor.w * 6 / 10 && attrs.height <= 64 && (at_top || at_bottom) {
			append(&found, Rect{attrs.x, attrs.y, attrs.width, attrs.height})
		}
	}
	return found[:]
}

// The monitor rectangle minus any panels along its edges.
subtract_bars :: proc(c: ^Connection, monitor: Rect, exclude: []xlib.Window = nil) -> Rect {
	r := monitor
	for b in bars(c, monitor, exclude) {
		if b.x + b.w <= r.x || b.x >= r.x + r.w || b.y + b.h <= r.y || b.y >= r.y + r.h { continue }
		if b.y <= r.y + 2 && b.h < r.h / 2 {
			shift := max(0, (b.y + b.h) - r.y)
			r.y += shift
			r.h -= shift
		} else if b.y + b.h >= r.y + r.h - 2 && b.h < r.h / 2 {
			r.h -= max(0, (r.y + r.h) - b.y)
		} else if b.x <= r.x + 2 && b.w < r.w / 2 {
			shift := max(0, (b.x + b.w) - r.x)
			r.x += shift
			r.w -= shift
		} else if b.x + b.w >= r.x + r.w - 2 && b.w < r.w / 2 {
			r.w -= max(0, (r.x + r.w) - b.x)
		}
	}
	if r.w <= 0 || r.h <= 0 { return monitor }
	return r
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------
// An unmanaged (override-redirect) window: dwm and openbox leave it alone.
create_overlay :: proc(c: ^Connection, r: Rect, mask: xlib.EventMask, window_type: string, name: string) -> xlib.Window {
	attrs: xlib.XSetWindowAttributes
	attrs.override_redirect = true
	attrs.background_pixel = c.black
	attrs.event_mask = mask
	win := xlib.CreateWindow(c.dpy, c.root, r.x, r.y, u32(max(r.w, 1)), u32(max(r.h, 1)), 0, c.depth, .InputOutput, c.visual,
	                         {.CWOverrideRedirect, .CWBackPixel, .CWEventMask}, &attrs)
	decorate_window(c, win, window_type, name)
	return win
}

// A managed dock window (for the bar): the WM keeps it on every desktop and
// honours its struts.
create_dock :: proc(c: ^Connection, r: Rect, mask: xlib.EventMask, name: string) -> xlib.Window {
	attrs: xlib.XSetWindowAttributes
	attrs.background_pixel = c.black
	attrs.event_mask = mask
	win := xlib.CreateWindow(c.dpy, c.root, r.x, r.y, u32(max(r.w, 1)), u32(max(r.h, 1)), 0, c.depth, .InputOutput, c.visual,
	                         {.CWBackPixel, .CWEventMask}, &attrs)
	decorate_window(c, win, "_NET_WM_WINDOW_TYPE_DOCK", name)
	set_atom_list(c, win, "_NET_WM_STATE", {atom(c, "_NET_WM_STATE_STICKY"), atom(c, "_NET_WM_STATE_SKIP_TASKBAR"),
	                                        atom(c, "_NET_WM_STATE_SKIP_PAGER"), atom(c, "_NET_WM_STATE_ABOVE")})
	set_cardinals(c, win, "_NET_WM_DESKTOP", {0xFFFFFFFF})
	pid := uint(runtime_pid())
	set_cardinals(c, win, "_NET_WM_PID", {pid})
	return win
}

@(private)
decorate_window :: proc(c: ^Connection, win: xlib.Window, window_type: string, name: string) {
	hint := xlib.XClassHint{res_name = "milk", res_class = "Milk"}
	xlib.SetClassHint(c.dpy, win, &hint)
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	xlib.StoreName(c.dpy, win, cname)
	set_utf8_string(c, win, "_NET_WM_NAME", name)
	set_atom_list(c, win, "_NET_WM_WINDOW_TYPE", {atom(c, window_type)})
}

// _NET_WM_STRUT_PARTIAL for a top or bottom bar spanning [start, end] on the x axis.
set_strut :: proc(c: ^Connection, win: xlib.Window, top, bottom: i32, start_x, end_x: i32) {
	partial := [12]uint{0, 0, uint(top), uint(bottom), 0, 0, 0, 0,
	                    top > 0 ? uint(start_x) : 0, top > 0 ? uint(end_x) : 0,
	                    bottom > 0 ? uint(start_x) : 0, bottom > 0 ? uint(end_x) : 0}
	set_cardinals(c, win, "_NET_WM_STRUT_PARTIAL", partial[:])
	set_cardinals(c, win, "_NET_WM_STRUT", partial[:4])
}

set_background :: proc(c: ^Connection, win: xlib.Window, pm: xlib.Pixmap) {
	xlib.SetWindowBackgroundPixmap(c.dpy, win, pm)
	xlib.ClearArea(c.dpy, win, 0, 0, 0, 0, false)
}

map_window     :: proc(c: ^Connection, win: xlib.Window) { xlib.MapWindow(c.dpy, win) }
unmap_window   :: proc(c: ^Connection, win: xlib.Window) { xlib.UnmapWindow(c.dpy, win) }
destroy_window :: proc(c: ^Connection, win: xlib.Window) { xlib.DestroyWindow(c.dpy, win) }
lower_window   :: proc(c: ^Connection, win: xlib.Window) { xlib.LowerWindow(c.dpy, win) }
raise_window   :: proc(c: ^Connection, win: xlib.Window) { xlib.RaiseWindow(c.dpy, win) }

move_resize :: proc(c: ^Connection, win: xlib.Window, r: Rect) {
	xlib.MoveResizeWindow(c.dpy, win, r.x, r.y, u32(max(r.w, 1)), u32(max(r.h, 1)))
}

pixmap_free :: proc(c: ^Connection, pm: xlib.Pixmap) {
	if pm != 0 { xlib.FreePixmap(c.dpy, pm) }
}

// EWMH client message to the root window (e.g. _NET_CURRENT_DESKTOP to switch desktops).
send_client_message :: proc(c: ^Connection, name: string, data: [5]int) {
	ev: xlib.XEvent
	ev.xclient.type = .ClientMessage
	ev.xclient.window = c.root
	ev.xclient.message_type = atom(c, name)
	ev.xclient.format = 32
	ev.xclient.data.l = data
	xlib.SendEvent(c.dpy, c.root, false, {.SubstructureRedirect, .SubstructureNotify}, &ev)
	flush(c)
}

// Children of the root window, top-level, in stacking order (bottom first).
root_children :: proc(c: ^Connection, allocator := context.temp_allocator) -> []xlib.Window {
	root, parent: xlib.Window
	children: [^]xlib.Window
	nchildren: u32
	if xlib.QueryTree(c.dpy, c.root, &root, &parent, &children, &nchildren) == xlib.Status(0) || children == nil { return nil }
	defer xlib.Free(children)
	return slice.clone(children[:nchildren], allocator)
}

@(private)
runtime_pid :: proc() -> int {
	return int(_getpid())
}

foreign import libc_extra "system:c"
@(default_calling_convention="c")
foreign libc_extra {
	@(link_name="getpid") _getpid :: proc() -> i32 ---
}
