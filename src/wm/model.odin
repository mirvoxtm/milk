// Data model of the window manager (dwm's Client, Monitor, Arg, Key, Button
// and Layout) and the list helpers that operate on it.
package wm

import xlib "vendor:x11/xlib"

// dwm's layouts[] from config.def.h: tiled (default), floating (no arrange
// function) and monocle.
Layout :: enum u8 {
	Tile,
	Float,
	Monocle,
}

// Symbols of the layouts (dwm shows them in its bar; used here for logging).
LAYOUT_SYMBOLS := [Layout]string {
	.Tile    = "[]=",
	.Float   = "><>",
	.Monocle = "[M]",
}

// EWMH window type classes that change how a client is handled.
Window_Kind :: enum u8 {
	Normal,
	Dock,    // _NET_WM_WINDOW_TYPE_DOCK: sticky, borderless, kept above
	Desktop, // _NET_WM_WINDOW_TYPE_DESKTOP: sticky, borderless, kept at the bottom
	Popup,   // notification/tooltip/splash: kept above the selection
}

// A managed top-level window.
Client :: struct {
	name:                   string, // title (for rules), owned
	mina, maxa:             f32,
	x, y, w, h:             i32,
	oldx, oldy, oldw, oldh: i32,
	basew, baseh:           i32,
	incw, inch:             i32,
	maxw, maxh, minw, minh: i32,
	hintsvalid:             bool,
	bw:                     i32, // current border width
	oldbw:                  i32, // border width before the window was managed (restored by unmanage)
	fsbw:                   i32, // border width before fullscreen (dwm reuses oldbw for this)
	tags:                   u32,
	isfixed:                bool,
	isfloating:             bool,
	isurgent:               bool,
	neverfocus:             bool, // ICCCM input hint is false: never XSetInputFocus
	oldstate:               bool, // floating state before fullscreen
	isfullscreen:           bool,
	nofocus:                bool, // EWMH dock/desktop/notification/tooltip/splash: never selected
	kind:                   Window_Kind,
	ispip:                  bool, // picture-in-picture window (see pip.odin)
	shaped:                 bool,   // rounded corners applied (see anim.odin apply_corners)
	shape_key:              [4]i32, // w, h, bw, radius of the applied shape
	reqw, reqh:             i32,  // the size the client last asked for (map, ConfigureRequest)
	desktop:                i64,  // last _NET_WM_DESKTOP published, -1 = none
	// milk animations: what the X server currently shows (dx..dh) and the
	// geometry the running animation started from. x/y/w/h stay the target, so
	// every dwm computation keeps working on the final layout.
	dx, dy, dw, dh:         i32,
	disp_valid:             bool,
	animating:              bool,
	anim_from:              [4]i32,
	anim_start:             f64,
	next:                   ^Client, // tiling order
	snext:                  ^Client, // focus stack
	mon:                    ^Monitor,
	win:                    xlib.Window,
}

// One RandR monitor.
Monitor :: struct {
	name:           string, // RandR monitor name, owned
	primary:        bool,
	mfact:          f32,
	nmaster:        i32,
	num:            int,
	mx, my, mw, mh: i32, // screen area
	wx, wy, ww, wh: i32, // window area (screen area minus the reserved bar strip)
	seltags:        u32,
	sellt:          u32,
	tagset:         [2]u32,
	clients:        ^Client,
	sel:            ^Client,
	stack:          ^Client,
	next:           ^Monitor,
	lt:             [2]Layout,
}

// dwm's Arg union as a struct: every action reads the one field it needs.
Arg :: struct {
	i:      int,
	ui:     u32,
	f:      f32,
	lt:     Layout,
	has_lt: bool,   // setlayout: false toggles between the two last layouts
	cmd:    string, // spawn: shell command (borrowed from Settings)
}

Action :: #type proc(m: ^Manager, arg: ^Arg)

Key :: struct {
	mod:    xlib.InputMask,
	keysym: xlib.KeySym,
	func:   Action,
	arg:    Arg,
}

// Where a button was pressed (dwm's Clk*; the bar clicks do not exist here).
Click :: enum u8 {
	Client_Win,
	Root_Win,
}

Button :: struct {
	click:  Click,
	mask:   xlib.InputMask,
	button: u32,
	func:   Action,
	arg:    Arg,
}

// ---------------------------------------------------------------------------
// Helpers (dwm's macros and list functions)
// ---------------------------------------------------------------------------

// ISVISIBLE: the client has a tag selected on its monitor.
is_visible :: proc(c: ^Client) -> bool {
	return c.tags & c.mon.tagset[c.mon.seltags] != 0
}

// A visible client that may receive the selection.
is_focusable :: proc(c: ^Client) -> bool {
	return is_visible(c) && !c.nofocus
}

// WIDTH/HEIGHT: outer size including the border.
width :: proc(c: ^Client) -> i32 { return c.w + 2 * c.bw }
height :: proc(c: ^Client) -> i32 { return c.h + 2 * c.bw }

// The monitor's current layout.
cur_layout :: proc(mon: ^Monitor) -> Layout { return mon.lt[mon.sellt] }

// Whether a layout arranges windows (dwm: lt->arrange != NULL).
has_arrange :: proc(l: Layout) -> bool { return l != .Float }

// TAGMASK for the configured number of tags.
tagmask :: proc(m: ^Manager) -> u32 {
	n := m.settings.tag_count
	if n >= 32 { return max(u32) }
	return (u32(1) << u32(n)) - 1
}

// Index of the lowest set tag (0 when there is none).
lowest_tag :: proc(tags: u32) -> int {
	for i in 0 ..< 32 {
		if tags & (u32(1) << u32(i)) != 0 { return i }
	}
	return 0
}

attach :: proc(c: ^Client) {
	c.next = c.mon.clients
	c.mon.clients = c
}

attachstack :: proc(c: ^Client) {
	c.snext = c.mon.stack
	c.mon.stack = c
}

detach :: proc(c: ^Client) {
	tc := &c.mon.clients
	for tc^ != nil && tc^ != c { tc = &tc^.next }
	tc^ = c.next
}

detachstack :: proc(c: ^Client) {
	tc := &c.mon.stack
	for tc^ != nil && tc^ != c { tc = &tc^.snext }
	tc^ = c.snext
	if c == c.mon.sel {
		t := c.mon.stack
		for t != nil && !is_focusable(t) { t = t.snext }
		c.mon.sel = t
	}
}

// The first tiled (visible, non-floating) client starting at `from`.
nexttiled :: proc(from: ^Client) -> ^Client {
	c := from
	for c != nil && (c.isfloating || !is_visible(c)) { c = c.next }
	return c
}

wintoclient :: proc(m: ^Manager, w: xlib.Window) -> ^Client {
	if w == 0 { return nil }
	for mon := m.mons; mon != nil; mon = mon.next {
		for c := mon.clients; c != nil; c = c.next {
			if c.win == w { return c }
		}
	}
	return nil
}
