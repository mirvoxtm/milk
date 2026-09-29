// Drawing helpers shared by the popups and the panel: a frame canvas plus a
// list of text runs drawn with Xft after the canvas is uploaded (optionally
// clipped), layers that map window coordinates onto an offscreen canvas
// (the scrolling list), soft shadows, Tabler glyphs, relative times.
package notify

import "core:fmt"
import "core:sys/posix"
import "core:time"
import xlib "vendor:x11/xlib"
import tx "../tx"

foreign import xft "system:Xft"

@(default_calling_convention="c")
foreign xft {
	XftDrawSetClipRectangles :: proc(draw: ^tx.XftDraw, x_origin, y_origin: i32, rects: [^]xlib.XRectangle, n: i32) -> b32 ---
	XftDrawSetClip           :: proc(draw: ^tx.XftDraw, region: rawptr) -> b32 ---
}

// Tabler codepoints (noctalia-tabler.ttf / tabler.json).
@(private) GLYPH_BELL          :: rune(0xEA35)
@(private) GLYPH_BELL_OFF      :: rune(0xECE9)
@(private) GLYPH_BELL_Z        :: rune(0xEFF1)
@(private) GLYPH_X             :: rune(0xEB55)
@(private) GLYPH_CHEVRON_UP    :: rune(0xEA62)
@(private) GLYPH_CHEVRON_DOWN  :: rune(0xEA5F)
@(private) GLYPH_CLEAR_ALL     :: rune(0xEE41)

@(private)
Text_Op :: struct {
	font:  ^tx.Font,
	x, y:  i32, // baseline, window coordinates
	s:     string,
	color: tx.Color,
	clip:  tx.Rect, // w == 0: none
}

@(private)
Painter :: struct {
	cv:    tx.Canvas,
	texts: [dynamic]Text_Op,
}

// Where shapes go: the frame itself or an offscreen canvas placed at (ox, oy).
@(private)
Layer :: struct {
	p:      ^Painter,
	cv:     ^tx.Canvas,
	ox, oy: i32,
	clip:   tx.Rect,
}

@(private)
painter_make :: proc(w, h: i32) -> Painter {
	return {cv = tx.canvas_make(w, h, context.temp_allocator), texts = make([dynamic]Text_Op, context.temp_allocator)}
}

@(private)
frame_layer :: proc(p: ^Painter) -> Layer {
	return {p = p, cv = &p.cv}
}

// Upload the frame, draw the text runs and make it the window's background.
@(private)
painter_finish :: proc(c: ^tx.Connection, p: ^Painter, win: xlib.Window, pixmap: ^xlib.Pixmap) {
	pm := tx.canvas_to_pixmap(c, p.cv)
	ts := tx.text_surface_make(c, xlib.Drawable(pm))
	current := tx.Rect{}
	for t in p.texts {
		if t.clip != current {
			if t.clip.w > 0 {
				r := xlib.XRectangle{i16(t.clip.x), i16(t.clip.y), u16(max(t.clip.w, 0)), u16(max(t.clip.h, 0))}
				XftDrawSetClipRectangles(ts.draw, 0, 0, &r, 1)
			} else {
				XftDrawSetClip(ts.draw, nil)
			}
			current = t.clip
		}
		tx.draw_text(&ts, t.font, t.x, t.y, t.s, t.color)
	}
	tx.text_surface_destroy(&ts)
	tx.set_background(c, win, pm)
	tx.pixmap_free(c, pixmap^)
	pixmap^ = pm
}

@(private)
layer_rect :: proc(l: Layer, r: tx.Rect, radius: f32, color: tx.Color) {
	tx.canvas_fill_rounded_rect(l.cv, {r.x - l.ox, r.y - l.oy, r.w, r.h}, radius, color)
}

@(private)
layer_stroke :: proc(l: Layer, r: tx.Rect, radius: f32, width: f32, color: tx.Color) {
	tx.canvas_stroke_rounded_rect(l.cv, {r.x - l.ox, r.y - l.oy, r.w, r.h}, radius, width, color)
}

@(private)
layer_circle :: proc(l: Layer, cx, cy, radius: f32, color: tx.Color) {
	tx.canvas_fill_circle(l.cv, cx - f32(l.ox), cy - f32(l.oy), radius, color)
}

@(private)
layer_image :: proc(l: Layer, img: tx.Image, x, y: i32) {
	if img.rgba == nil { return }
	tx.canvas_blit_image(l.cv, img, x - l.ox, y - l.oy)
}

@(private)
layer_text :: proc(l: Layer, f: ^tx.Font, x, baseline: i32, s: string, color: tx.Color) {
	if f == nil || s == "" { return }
	append(&l.p.texts, Text_Op{font = f, x = x, y = baseline, s = s, color = color, clip = l.clip})
}

// Text vertically centred in [box_y, box_y + box_h).
@(private)
layer_text_v :: proc(l: Layer, f: ^tx.Font, x, box_y, box_h: i32, s: string, color: tx.Color) {
	if f == nil { return }
	layer_text(l, f, x, box_y + (box_h - f.height) / 2 + f.ascent, s, color)
}

// A glyph whose ink box is centred on (cx, cy).
@(private)
layer_glyph :: proc(c: ^tx.Connection, l: Layer, f: ^tx.Font, glyph: rune, cx, cy: i32, color: tx.Color) {
	if f == nil { return }
	s := rune_string(glyph)
	ext := tx.text_extents(c, f, s)
	x := cx - i32(ext.width) / 2 + i32(ext.x)
	y := cy - i32(ext.height) / 2 + i32(ext.y)
	layer_text(l, f, x, y, s, color)
}

@(private)
rune_string :: proc(r: rune) -> string {
	return fmt.tprintf("%r", r)
}

// Copy an offscreen canvas into the frame at (x, y).
@(private)
canvas_paste :: proc(dst: ^tx.Canvas, src: tx.Canvas, x, y: i32) {
	for sy in 0 ..< src.h {
		dy := y + sy
		if dy < 0 || dy >= dst.h { continue }
		for sx in 0 ..< src.w {
			dx := x + sx
			if dx < 0 || dx >= dst.w { continue }
			dst.px[int(dy) * int(dst.w) + int(dx)] = src.px[int(sy) * int(src.w) + int(sx)]
		}
	}
}

@(private)
ease_out :: proc(t: f64) -> f64 {
	x := clamp(t, 0, 1)
	return 1 - (1 - x) * (1 - x) * (1 - x)
}

@(private)
ease_in :: proc(t: f64) -> f64 {
	x := clamp(t, 0, 1)
	return x * x * x
}

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------
@(private)
now_unix :: proc() -> i64 { return time.to_unix_seconds(time.now()) }

@(private)
local_tm :: proc(unix: i64) -> posix.tm {
	t := posix.time_t(unix)
	tm: posix.tm
	posix.localtime_r(&t, &tm)
	return tm
}

// "agora", "5 min", "10:42", "28/09" (or the English equivalents).
@(private)
format_age :: proc(n: ^Notifier, unix: i64) -> string {
	pt := portuguese(n)
	now := now_unix()
	age := now - unix
	if age < 60 { return pt ? "agora" : "now" }
	if age < 3600 { return fmt.tprintf("%d min", age / 60) }
	then := local_tm(unix)
	today := local_tm(now)
	if then.tm_year == today.tm_year && then.tm_yday == today.tm_yday {
		return fmt.tprintf("%02d:%02d", then.tm_hour, then.tm_min)
	}
	return pt ? fmt.tprintf("%02d/%02d", then.tm_mday, then.tm_mon + 1) : fmt.tprintf("%02d/%02d", then.tm_mon + 1, then.tm_mday)
}
