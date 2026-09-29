// Software canvas: everything milk draws (bar, icon cells, indicator) is
// composed on the CPU as 0x00RRGGBB pixels and uploaded as a pixmap. This
// keeps rendering identical with or without a compositor.
package tx

import "core:log"
import "core:math"
import xlib "vendor:x11/xlib"

Color :: struct { r, g, b, a: u8 }

rgb  :: proc(r, g, b: u8) -> Color { return {r, g, b, 255} }
rgba :: proc(r, g, b, a: u8) -> Color { return {r, g, b, a} }

// "#RRGGBB" or "#RRGGBBAA".
color_from_hex :: proc(s: string, fallback := Color{0, 0, 0, 255}) -> Color {
	text := s
	if len(text) > 0 && text[0] == '#' { text = text[1:] }
	if len(text) != 6 && len(text) != 8 { return fallback }
	parse := proc(t: string) -> (u8, bool) {
		v: int
		for ch in t {
			d: int
			switch ch {
			case '0' ..= '9': d = int(ch - '0')
			case 'a' ..= 'f': d = int(ch - 'a') + 10
			case 'A' ..= 'F': d = int(ch - 'A') + 10
			case: return 0, false
			}
			v = v * 16 + d
		}
		return u8(v), true
	}
	r, ok1 := parse(text[0:2])
	g, ok2 := parse(text[2:4])
	b, ok3 := parse(text[4:6])
	if !(ok1 && ok2 && ok3) { return fallback }
	a: u8 = 255
	if len(text) == 8 {
		aa, ok4 := parse(text[6:8])
		if !ok4 { return fallback }
		a = aa
	}
	return {r, g, b, a}
}

color_with_alpha :: proc(c: Color, a: u8) -> Color { return {c.r, c.g, c.b, a} }

// Linear blend between two colours (t = 0 → a, t = 1 → b).
color_mix :: proc(a, b: Color, t: f32) -> Color {
	lerp := proc(x, y: u8, t: f32) -> u8 { return u8(clamp(f32(x) + (f32(y) - f32(x)) * t, 0, 255)) }
	return {lerp(a.r, b.r, t), lerp(a.g, b.g, t), lerp(a.b, b.b, t), lerp(a.a, b.a, t)}
}

Canvas :: struct {
	w, h: i32,
	px:   []u32, // 0x00RRGGBB, row-major, stride == w
}

canvas_make :: proc(w, h: i32, allocator := context.allocator) -> Canvas {
	return {w = max(w, 1), h = max(h, 1), px = make([]u32, int(max(w, 1)) * int(max(h, 1)), allocator)}
}

canvas_destroy :: proc(cv: ^Canvas) {
	delete(cv.px)
	cv.px = nil
}

canvas_clone :: proc(cv: Canvas, allocator := context.allocator) -> Canvas {
	out := canvas_make(cv.w, cv.h, allocator)
	copy(out.px, cv.px)
	return out
}

@(private)
pack :: #force_inline proc(r, g, b: u8) -> u32 { return u32(r) << 16 | u32(g) << 8 | u32(b) }

@(private)
blend_px :: #force_inline proc(dst: u32, c: Color, coverage: f32) -> u32 {
	a := f32(c.a) / 255 * coverage
	if a <= 0 { return dst }
	if a >= 1 { return pack(c.r, c.g, c.b) }
	dr := f32((dst >> 16) & 0xFF)
	dg := f32((dst >> 8) & 0xFF)
	db := f32(dst & 0xFF)
	return pack(u8(dr + (f32(c.r) - dr) * a), u8(dg + (f32(c.g) - dg) * a), u8(db + (f32(c.b) - db) * a))
}

canvas_fill :: proc(cv: ^Canvas, c: Color) {
	if c.a == 255 {
		v := pack(c.r, c.g, c.b)
		for i in 0 ..< len(cv.px) { cv.px[i] = v }
	} else {
		for i in 0 ..< len(cv.px) { cv.px[i] = blend_px(cv.px[i], c, 1) }
	}
}

canvas_fill_rect :: proc(cv: ^Canvas, r: Rect, c: Color) {
	x0 := max(r.x, 0)
	y0 := max(r.y, 0)
	x1 := min(r.x + r.w, cv.w)
	y1 := min(r.y + r.h, cv.h)
	for y in y0 ..< y1 {
		row := int(y) * int(cv.w)
		for x in x0 ..< x1 { cv.px[row + int(x)] = blend_px(cv.px[row + int(x)], c, 1) }
	}
}

// Anti-aliased rounded rectangle (radius clamped to half the shorter side).
canvas_fill_rounded_rect :: proc(cv: ^Canvas, r: Rect, radius: f32, c: Color) {
	if r.w <= 0 || r.h <= 0 { return }
	rad := clamp(radius, 0, f32(min(r.w, r.h)) / 2)
	if rad < 0.5 {
		canvas_fill_rect(cv, r, c)
		return
	}
	x0 := max(r.x, 0)
	y0 := max(r.y, 0)
	x1 := min(r.x + r.w, cv.w)
	y1 := min(r.y + r.h, cv.h)
	left := f32(r.x) + rad
	right := f32(r.x + r.w) - rad
	top := f32(r.y) + rad
	bottom := f32(r.y + r.h) - rad
	for y in y0 ..< y1 {
		row := int(y) * int(cv.w)
		py := f32(y) + 0.5
		cy := clamp(py, top, bottom)
		dy := py - cy
		for x in x0 ..< x1 {
			px := f32(x) + 0.5
			cx := clamp(px, left, right)
			dx := px - cx
			d := math.sqrt(dx * dx + dy * dy)
			coverage := clamp(rad - d + 0.5, 0, 1)
			if coverage > 0 { cv.px[row + int(x)] = blend_px(cv.px[row + int(x)], c, coverage) }
		}
	}
}

canvas_fill_circle :: proc(cv: ^Canvas, cx, cy, radius: f32, c: Color) {
	r := Rect{i32(math.floor(cx - radius)), i32(math.floor(cy - radius)), i32(math.ceil(radius * 2)) + 1, i32(math.ceil(radius * 2)) + 1}
	x0 := max(r.x, 0)
	y0 := max(r.y, 0)
	x1 := min(r.x + r.w, cv.w)
	y1 := min(r.y + r.h, cv.h)
	for y in y0 ..< y1 {
		row := int(y) * int(cv.w)
		py := f32(y) + 0.5
		for x in x0 ..< x1 {
			px := f32(x) + 0.5
			d := math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy))
			coverage := clamp(radius - d + 0.5, 0, 1)
			if coverage > 0 { cv.px[row + int(x)] = blend_px(cv.px[row + int(x)], c, coverage) }
		}
	}
}

// Rounded outline of `width` pixels.
canvas_stroke_rounded_rect :: proc(cv: ^Canvas, r: Rect, radius: f32, width: f32, c: Color) {
	if r.w <= 0 || r.h <= 0 { return }
	rad := clamp(radius, 0, f32(min(r.w, r.h)) / 2)
	x0 := max(r.x, 0)
	y0 := max(r.y, 0)
	x1 := min(r.x + r.w, cv.w)
	y1 := min(r.y + r.h, cv.h)
	left := f32(r.x) + rad
	right := f32(r.x + r.w) - rad
	top := f32(r.y) + rad
	bottom := f32(r.y + r.h) - rad
	for y in y0 ..< y1 {
		row := int(y) * int(cv.w)
		py := f32(y) + 0.5
		cy := clamp(py, top, bottom)
		for x in x0 ..< x1 {
			px := f32(x) + 0.5
			cx := clamp(px, left, right)
			dx := px - cx
			dy := py - cy
			d := math.sqrt(dx * dx + dy * dy)
			// distance to the rounded edge, positive inside
			inside := rad - d
			if inside < 0 && rad == 0 { inside = 0 }
			// approximate: outer coverage minus inner coverage
			outer := clamp(inside + 0.5, 0, 1)
			inner := clamp(inside - width + 0.5, 0, 1)
			coverage := outer - inner
			if coverage > 0 { cv.px[row + int(x)] = blend_px(cv.px[row + int(x)], c, coverage) }
		}
	}
}

// RGBA (straight alpha, 8 bits per channel, row-major) image.
Image :: struct {
	w, h: i32,
	rgba: []u8,
}

image_make :: proc(w, h: i32, allocator := context.allocator) -> Image {
	return {w = max(w, 1), h = max(h, 1), rgba = make([]u8, int(max(w, 1)) * int(max(h, 1)) * 4, allocator)}
}

image_destroy :: proc(img: ^Image) {
	delete(img.rgba)
	img.rgba = nil
}

// Box-filtered resize (good enough for icons; downsampling stays smooth).
image_resize :: proc(src: Image, w, h: i32, allocator := context.allocator) -> Image {
	dst := image_make(w, h, allocator)
	if src.w <= 0 || src.h <= 0 { return dst }
	for y in 0 ..< int(h) {
		sy0 := int(f32(y) * f32(src.h) / f32(h))
		sy1 := max(sy0 + 1, int(f32(y + 1) * f32(src.h) / f32(h)))
		sy1 = min(sy1, int(src.h))
		for x in 0 ..< int(w) {
			sx0 := int(f32(x) * f32(src.w) / f32(w))
			sx1 := max(sx0 + 1, int(f32(x + 1) * f32(src.w) / f32(w)))
			sx1 = min(sx1, int(src.w))
			r, g, b, a, n: f32
			for sy in sy0 ..< sy1 {
				for sx in sx0 ..< sx1 {
					i := (sy * int(src.w) + sx) * 4
					pa := f32(src.rgba[i + 3])
					r += f32(src.rgba[i]) * pa
					g += f32(src.rgba[i + 1]) * pa
					b += f32(src.rgba[i + 2]) * pa
					a += pa
					n += 1
				}
			}
			o := (y * int(w) + x) * 4
			if a > 0 {
				dst.rgba[o] = u8(r / a)
				dst.rgba[o + 1] = u8(g / a)
				dst.rgba[o + 2] = u8(b / a)
				dst.rgba[o + 3] = u8(a / n)
			}
		}
	}
	return dst
}

// Composite an RGBA image onto the canvas at (x, y); `opacity` scales its alpha.
canvas_blit_image :: proc(cv: ^Canvas, img: Image, x, y: i32, opacity: f32 = 1) {
	for iy in 0 ..< img.h {
		cy := y + iy
		if cy < 0 || cy >= cv.h { continue }
		row := int(cy) * int(cv.w)
		for ix in 0 ..< img.w {
			cx := x + ix
			if cx < 0 || cx >= cv.w { continue }
			i := (int(iy) * int(img.w) + int(ix)) * 4
			c := Color{img.rgba[i], img.rgba[i + 1], img.rgba[i + 2], img.rgba[i + 3]}
			cv.px[row + int(cx)] = blend_px(cv.px[row + int(cx)], c, opacity)
		}
	}
}

// _NET_WM_ICON data (ARGB, non-premultiplied, one u32 per pixel) → Image.
image_from_argb :: proc(argb: []uint, w, h: i32, allocator := context.allocator) -> Image {
	img := image_make(w, h, allocator)
	for i in 0 ..< int(w) * int(h) {
		if i >= len(argb) { break }
		v := u32(argb[i])
		img.rgba[i * 4] = u8(v >> 16)
		img.rgba[i * 4 + 1] = u8(v >> 8)
		img.rgba[i * 4 + 2] = u8(v)
		img.rgba[i * 4 + 3] = u8(v >> 24)
	}
	return img
}

// Copy a region of a drawable (root window or the wallpaper pixmap) into a canvas.
canvas_grab :: proc(c: ^Connection, d: xlib.Drawable, r: Rect, allocator := context.allocator) -> (Canvas, bool) {
	if r.w <= 0 || r.h <= 0 { return {}, false }
	if c.depth != 24 && c.depth != 32 {
		log.warnf("Unsupported root depth %d for grabbing", c.depth)
		return {}, false
	}
	// XGetImage fails (BadMatch) when the rectangle leaves the drawable.
	dw, dh, ok := drawable_size(c, d)
	if !ok { return {}, false }
	region, inside := rect_intersect(r, Rect{0, 0, dw, dh})
	if !inside { return {}, false }
	ximg := xlib.GetImage(c.dpy, d, region.x, region.y, u32(region.w), u32(region.h), ~uint(0), .ZPixmap)
	if ximg == nil { return {}, false }
	defer xlib.DestroyImage(ximg)
	if ximg.bits_per_pixel != 32 {
		log.warnf("Unsupported image format (%d bpp)", ximg.bits_per_pixel)
		return {}, false
	}
	cv := canvas_make(r.w, r.h, allocator)
	canvas_fill(&cv, rgb(18, 20, 26))
	stride := int(ximg.bytes_per_line) / 4
	src := ([^]u32)(ximg.data)
	for y in 0 ..< region.h {
		dst_row := int(y + region.y - r.y) * int(cv.w)
		src_row := int(y) * stride
		for x in 0 ..< region.w {
			cv.px[dst_row + int(x + region.x - r.x)] = src[src_row + int(x)] & 0x00FFFFFF
		}
	}
	return cv, true
}

// Upload a canvas into a new server-side pixmap.
canvas_to_pixmap :: proc(c: ^Connection, cv: Canvas) -> xlib.Pixmap {
	pm := xlib.CreatePixmap(c.dpy, xlib.Drawable(c.root), u32(cv.w), u32(cv.h), u32(c.depth))
	canvas_upload(c, cv, xlib.Drawable(pm), 0, 0)
	return pm
}

// Copy a canvas onto an existing drawable at (x, y).
canvas_upload :: proc(c: ^Connection, cv: Canvas, dst: xlib.Drawable, x, y: i32) {
	if c.depth != 24 && c.depth != 32 { return }
	ximg := xlib.CreateImage(c.dpy, c.visual, u32(c.depth), .ZPixmap, 0, raw_data(cv.px), u32(cv.w), u32(cv.h), 32, cv.w * 4)
	if ximg == nil { return }
	gc := xlib.CreateGC(c.dpy, dst, {}, nil)
	xlib.PutImage(c.dpy, dst, gc, ximg, 0, 0, x, y, u32(cv.w), u32(cv.h))
	xlib.FreeGC(c.dpy, gc)
	ximg.data = nil // the pixels belong to the canvas
	xlib.DestroyImage(ximg)
}
