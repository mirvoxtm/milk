// Window shapes (X SHAPE extension): rounded cards and panels without a
// compositor. A shaped window only exists inside its shape, so the corners
// show whatever is really behind them (live windows included) instead of a
// copy of the screen taken when the card opened — no stale artefacts.
package tx

import "core:math"
import xlib "vendor:x11/xlib"

foreign import xext "system:Xext"

@(private) SHAPE_BOUNDING :: 0
@(private) SHAPE_SET      :: 0
@(private) SHAPE_UNSORTED :: 0

@(default_calling_convention="c")
foreign xext {
	XShapeQueryExtension    :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	XShapeCombineRectangles :: proc(dpy: ^xlib.Display, dest: xlib.Window, dest_kind: i32, x_off, y_off: i32,
	                                rects: [^]xlib.XRectangle, n: i32, op: i32, ordering: i32) ---
	XShapeCombineMask       :: proc(dpy: ^xlib.Display, dest: xlib.Window, dest_kind: i32, x_off, y_off: i32,
	                                src: xlib.Pixmap, op: i32) ---
}

@(private) g_shape_checked: bool
@(private) g_shape_ok: bool

// True when the server supports window shapes.
shape_supported :: proc(c: ^Connection) -> bool {
	if !g_shape_checked {
		ev, er: i32
		g_shape_ok = bool(XShapeQueryExtension(c.dpy, &ev, &er))
		g_shape_checked = true
	}
	return g_shape_ok
}

// Give `win` (w x h) rounded corners of `radius` pixels. Call again after a
// resize. Returns false (and leaves the window rectangular) without SHAPE.
shape_rounded :: proc(c: ^Connection, win: xlib.Window, w, h: i32, radius: f32) -> bool {
	return shape_rounded_box(c, win, 0, 0, w, h, radius)
}

// Rounded shape of the box (x, y, w, h) in window coordinates; a negative
// origin covers the window border (x = y = -border_width).
shape_rounded_box :: proc(c: ^Connection, win: xlib.Window, x, y, w, h: i32, radius: f32) -> bool {
	if !shape_supported(c) || w <= 0 || h <= 0 { return false }
	r := i32(math.round(clamp(radius, 0, f32(min(w, h)) / 2)))
	rects := make([dynamic]xlib.XRectangle, context.temp_allocator)
	for row in 0 ..< r {
		// Horizontal inset of this row of the corner arc (a pixel is kept
		// when its centre lies inside the circle).
		dy := f32(r) - (f32(row) + 0.5)
		inset := i32(math.ceil(f32(r) - math.sqrt(max(f32(r * r) - dy * dy, 0)) - 0.5))
		inset = clamp(inset, 0, r)
		width := w - 2 * inset
		if width <= 0 { continue }
		append(&rects, xlib.XRectangle{i16(inset), i16(row), u16(width), 1})
		append(&rects, xlib.XRectangle{i16(inset), i16(h - 1 - row), u16(width), 1})
	}
	if h - 2 * r > 0 { append(&rects, xlib.XRectangle{0, i16(r), u16(w), u16(h - 2 * r)}) }
	XShapeCombineRectangles(c.dpy, win, SHAPE_BOUNDING, x, y, raw_data(rects), i32(len(rects)), SHAPE_SET, SHAPE_UNSORTED)
	return true
}

// Remove any shape (back to a plain rectangle).
shape_reset :: proc(c: ^Connection, win: xlib.Window) {
	if !shape_supported(c) { return }
	XShapeCombineMask(c.dpy, win, SHAPE_BOUNDING, 0, 0, 0, SHAPE_SET)
}
