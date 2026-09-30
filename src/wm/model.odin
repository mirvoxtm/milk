// Data model of the window manager (dwm's Client, Monitor, Arg, Key, Button
// and Layout) and the list helpers that operate on it.
package wm

import xlib "vendor:x11/xlib"
import tx "../tx"

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

// Where a floating window was snapped with the mouse or the keyboard.
Snap :: enum u8 { None, Left, Right, Top, Bottom, Top_Left, Top_Right, Bottom_Left, Bottom_Right }

// Stacking layer of a window in the floating mode (_NET_WM_STATE_ABOVE/BELOW).
Layer :: enum u8 { Normal, Above, Below }

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
	// Floating mode (frame.odin, floating.odin). A framed client is reparented
	// into `frame`; x/y then give the frame's corner and w/h the client's size,
	// so width()/height() (the outer size) keep dwm's arithmetic valid.
	frame:                  xlib.Window, // 0 = not reparented
	title_win:              xlib.Window, // child of the frame: the painted title bar
	title_pixmap:           xlib.Pixmap,
	title_w:                i32,         // width the title bar was painted for
	grip:                   xlib.Window, // InputOnly sibling below the frame: the invisible resize margin
	grip_dir:               int,         // resize direction whose cursor the grip shows, -1 = none
	ext:                    [4]i32,      // frame extents: left, right, top, bottom
	nodecor:                bool,        // no title bar (_MOTIF_WM_HINTS, a rule or the user)
	focused:                bool,        // the title bar is painted as the active one
	icon:                   tx.Image,    // _NET_WM_ICON at the title bar's size
	has_icon:               bool,
	title_hits:             [8]Title_Hit,
	nhits:                  int,
	hover:                  int,  // title element under the pointer, -1 = none
	pressed:                int,  // title button held down, -1 = none
	minimized:              bool,
	max_horz, max_vert:     bool, // maximized horizontally / vertically
	snapped:                Snap,
	saved:                  [4]i32, // geometry before maximize/snap (x, y, w, h)
	has_saved:              bool,
	shaded:                 bool,
	layer:                  Layer,
	sticky:                 bool,
	sticky_tags:            u32,  // tags before "on every area"
	transient_for:          xlib.Window, // WM_TRANSIENT_FOR (dialogs stay above it)
	float_geom:             [4]i32,      // x, y, w, h in the floating mode before the last switch to tiling
	has_float_geom:         bool,
}

// A clickable element of a title bar (title bar coordinates).
Title_Hit :: struct {
	r:      tx.Rect,
	letter: u8, // 'N', 'L', 'I', 'M', 'C', 'S', 'D', 'A'
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

// ISVISIBLE: the client has a tag selected on its monitor and is not minimized.
is_visible :: proc(c: ^Client) -> bool {
	return c.tags & c.mon.tagset[c.mon.seltags] != 0 && !c.minimized
}

// On the selected tags of its monitor, minimized or not (the window switcher).
on_current_tags :: proc(c: ^Client) -> bool {
	return c.tags & c.mon.tagset[c.mon.seltags] != 0
}

// A visible client that may receive the selection.
is_focusable :: proc(c: ^Client) -> bool {
	return is_visible(c) && !c.nofocus
}

// WIDTH/HEIGHT: outer size including the border (and the frame of a framed client).
width :: proc(c: ^Client) -> i32 { return c.w + ext_w(c) }
height :: proc(c: ^Client) -> i32 { return c.h + ext_h(c) }

// What surrounds the client window horizontally / vertically.
ext_w :: proc(c: ^Client) -> i32 { return 2 * c.bw + c.ext[0] + c.ext[1] }
ext_h :: proc(c: ^Client) -> i32 { return 2 * c.bw + c.ext[2] + c.ext[3] }

// The window the X server stacks and moves: the frame, or the client itself.
top_window :: proc(c: ^Client) -> xlib.Window { return c.frame != 0 ? c.frame : c.win }

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

// The client of a client window or of its frame.
wintoclient :: proc(m: ^Manager, w: xlib.Window) -> ^Client {
	if w == 0 { return nil }
	for mon := m.mons; mon != nil; mon = mon.next {
		for c := mon.clients; c != nil; c = c.next {
			if c.win == w || (c.frame != 0 && c.frame == w) { return c }
		}
	}
	return nil
}

// Parts of a framed window that receive events (frame.odin).
Frame_Part :: enum u8 { None, Frame, Title, Grip }

// The client owning a frame, title bar or resize margin window.
frame_part :: proc(m: ^Manager, w: xlib.Window) -> (^Client, Frame_Part) {
	if w == 0 { return nil, .None }
	for mon := m.mons; mon != nil; mon = mon.next {
		for c := mon.clients; c != nil; c = c.next {
			if c.frame == 0 { continue }
			switch w {
			case c.frame:     return c, .Frame
			case c.title_win: return c, .Title
			case c.grip:      return c, .Grip
			}
		}
	}
	return nil, .None
}
