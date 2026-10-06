// milk addition: how the overview (overview.odin) is drawn. Everything is
// done by the X server with Render: window contents are scaled down in
// halving steps (each a bilinear 2×2 average, so text stays legible), cards
// are drawn once into a picture of their own and redrawn only when what they
// show changes, and every frame stacks the background, the cards, their
// labels and the zooming area. Only the masks (rounded corners, rings, soft
// shadows) are computed here, once per size.
package wm

import "base:builtin"
import "core:fmt"
import "core:math"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "../tx"

@(private) OV_SHADOW      :: 6    // blur of a window's shadow in a card
@(private) OV_CARD_SHADOW :: 14   // blur of a card's shadow
@(private) OV_RING_GAP    :: 3    // between a card and its ring
@(private) OV_TINT        :: 0.58 // how much of the theme's background covers the blurred wallpaper

@(private) PICT_OP_IN_REVERSE :: 6

@(private) MASK_FILL   :: 1
@(private) MASK_RING   :: 2
@(private) MASK_SHADOW :: 3

// ---------------------------------------------------------------------------
// Pictures, colours and masks
// ---------------------------------------------------------------------------
@(private)
ov_target :: proc(m: ^Manager, w, h: i32, argb := true) -> (xlib.Pixmap, Picture) {
	ov := &m.overview
	depth := argb ? u32(32) : u32(m.c.depth)
	pm := xlib.CreatePixmap(m.dpy, xlib.Drawable(m.root), u32(max(w, 1)), u32(max(h, 1)), depth)
	pic := XRenderCreatePicture(m.dpy, xlib.Drawable(pm), argb ? ov.fmt_argb : ov.fmt_root, 0, nil)
	return pm, pic
}

@(private)
ov_free_target :: proc(m: ^Manager, pm: ^xlib.Pixmap, pic: ^Picture) {
	if pic^ != 0 { XRenderFreePicture(m.dpy, pic^) }
	if pm^ != 0 { xlib.FreePixmap(m.dpy, pm^) }
	pm^, pic^ = 0, 0
}

@(private)
xr_color :: proc(c: tx.Color, alpha: f32 = 1) -> XRenderColor {
	a := clamp(alpha, 0, 1) * f32(c.a) / 255
	ch :: proc(v: u8, a: f32) -> u16 { return u16(f32(v) * 257 * a) }
	return {ch(c.r, a), ch(c.g, a), ch(c.b, a), u16(a * 65535)}
}

@(private)
ov_fill :: proc(m: ^Manager, dst: Picture, c: tx.Color, alpha: f32, r: tx.Rect) {
	if r.w <= 0 || r.h <= 0 || alpha <= 0 { return }
	col := xr_color(c, alpha)
	XRenderFillRectangle(m.dpy, PICT_OP_OVER, dst, &col, r.x, r.y, u32(r.w), u32(r.h))
}

// A colour through a mask (the mask's size, at `at`).
@(private)
ov_fill_mask :: proc(m: ^Manager, dst: Picture, c: tx.Color, alpha: f32, mask: Picture, at: tx.Rect) {
	if mask == 0 || alpha <= 0 { return }
	col := xr_color(c, alpha)
	src := XRenderCreateSolidFill(m.dpy, &col)
	XRenderComposite(m.dpy, PICT_OP_OVER, src, mask, dst, 0, 0, 0, 0, at.x, at.y, u32(at.w), u32(at.h))
	XRenderFreePicture(m.dpy, src)
}

// `src` over `dst` at an opacity (1 = no mask).
@(private)
ov_blend :: proc(m: ^Manager, src, dst: Picture, sx, sy: i32, at: tx.Rect, alpha: f32) {
	if alpha <= 0 || at.w <= 0 || at.h <= 0 { return }
	mask: Picture
	if alpha < 1 {
		col := XRenderColor{alpha = u16(clamp(alpha, 0, 1) * 65535)}
		mask = XRenderCreateSolidFill(m.dpy, &col)
	}
	XRenderComposite(m.dpy, PICT_OP_OVER, src, mask, dst, sx, sy, 0, 0, at.x, at.y, u32(at.w), u32(at.h))
	if mask != 0 { XRenderFreePicture(m.dpy, mask) }
}

// Signed distance from a pixel centre to a rounded rectangle (negative inside).
@(private)
rounded_distance :: proc(x, y, w, h, r: f32) -> f32 {
	hx, hy := w / 2, h / 2
	qx := abs(x - hx) - (hx - r)
	qy := abs(y - hy) - (hy - r)
	ox, oy := max(qx, 0), max(qy, 0)
	return math.sqrt(ox * ox + oy * oy) + min(max(qx, qy), 0) - r
}

// An A8 mask, made once per size: a rounded rectangle, a ring around one
// (`r2` = its width) or a soft shadow (`r2` = its blur).
@(private)
ov_mask :: proc(m: ^Manager, kind: i32, w, h: i32, r: f32, r2: i32 = 0) -> Picture {
	ov := &m.overview
	if w <= 0 || h <= 0 { return 0 }
	key := [4]i32{kind << 16 | r2, w, h, i32(r * 16)}
	if pic, found := ov.masks[key]; found { return pic }
	data := make([]u8, int(w) * int(h), context.temp_allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			px, py := f32(x) + 0.5, f32(y) + 0.5
			a: f32
			switch kind {
			case MASK_FILL:
				a = clamp(0.5 - rounded_distance(px, py, f32(w), f32(h), r), 0, 1)
			case MASK_RING:
				d := rounded_distance(px, py, f32(w), f32(h), r)
				a = clamp(0.5 - d, 0, 1) * clamp(0.5 + d + f32(r2), 0, 1)
			case MASK_SHADOW:
				// A rounded rectangle inset by the blur, fading out over twice the blur.
				b := f32(max(r2, 1))
				d := rounded_distance(px - b, py - b, f32(w) - 2 * b, f32(h) - 2 * b, r)
				v := clamp(1 - (d + b) / (2 * b), 0, 1)
				a = v * v * (3 - 2 * v)
			}
			data[int(y) * int(w) + int(x)] = u8(a * 255 + 0.5)
		}
	}
	pm := xlib.CreatePixmap(m.dpy, xlib.Drawable(m.root), u32(w), u32(h), 8)
	img := xlib.CreateImage(m.dpy, m.c.visual, 8, .ZPixmap, 0, raw_data(data), u32(w), u32(h), 8, w)
	if img != nil {
		gc := xlib.CreateGC(m.dpy, xlib.Drawable(pm), {}, nil)
		xlib.PutImage(m.dpy, xlib.Drawable(pm), gc, img, 0, 0, 0, 0, u32(w), u32(h))
		xlib.FreeGC(m.dpy, gc)
		img.data = nil
		xlib.DestroyImage(img)
	}
	pic := XRenderCreatePicture(m.dpy, xlib.Drawable(pm), ov.fmt_a8, 0, nil)
	append(&ov.mask_pms, pm)
	ov.masks[key] = pic
	return pic
}

// Make the corners of `dst` (w×h at its origin) transparent.
@(private)
ov_round :: proc(m: ^Manager, dst: Picture, w, h: i32, r: f32) {
	mask := ov_mask(m, MASK_FILL, w, h, r)
	XRenderComposite(m.dpy, PICT_OP_IN_REVERSE, mask, 0, dst, 0, 0, 0, 0, 0, 0, u32(w), u32(h))
}

// The same with a radius that changes every frame: the four quadrants of one disc.
@(private)
ov_round_corners :: proc(m: ^Manager, dst: Picture, w, h: i32, r: i32) {
	k := min(r, w / 2, h / 2)
	if k <= 0 { return }
	disc := ov_mask(m, MASK_FILL, 2 * k, 2 * k, f32(k))
	corners := [4][4]i32{{0, 0, 0, 0}, {w - k, 0, k, 0}, {0, h - k, 0, k}, {w - k, h - k, k, k}}
	for c in corners {
		XRenderComposite(m.dpy, PICT_OP_IN_REVERSE, disc, 0, dst, 0, 0, c[2], c[3], c[0], c[1], u32(k), u32(k))
	}
}

@(private)
ov_set_transform :: proc(m: ^Manager, pic: Picture, fx, fy: f64, ox: f64 = 0, oy: f64 = 0) {
	fixed :: proc(v: f64) -> XFixed { return XFixed(v * 65536) }
	t := XTransform{m = {{fixed(fx), 0, fixed(ox)}, {0, fixed(fy), fixed(oy)}, {0, 0, fixed(1)}}}
	XRenderSetPictureTransform(m.dpy, pic, &t)
	XRenderSetPictureFilter(m.dpy, pic, fx == 1 && fy == 1 ? "nearest" : "bilinear", nil, 0)
}

// Scale the region (sx, sy, sw, sh) of `src` to `dst` at (dx, dy, dw, dh):
// halving first while it is more than twice too large (a 2×2 average each
// time), then one bilinear step.
@(private)
ov_scale :: proc(m: ^Manager, src: Picture, sx, sy, sw, sh: i32, dst: Picture, dx, dy, dw, dh: i32, op: i32 = PICT_OP_SRC) {
	if sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0 { return }
	cur, cx, cy, cw, ch := src, f64(sx), f64(sy), sw, sh
	tmp_pm: xlib.Pixmap
	tmp: Picture
	for cw >= 2 * dw + 2 || ch >= 2 * dh + 2 {
		nw := cw >= 2 * dw + 2 ? (cw + 1) / 2 : cw
		nh := ch >= 2 * dh + 2 ? (ch + 1) / 2 : ch
		next_pm, next := ov_target(m, nw, nh)
		ov_set_transform(m, cur, f64(cw) / f64(nw), f64(ch) / f64(nh), cx, cy)
		XRenderComposite(m.dpy, PICT_OP_SRC, cur, 0, next, 0, 0, 0, 0, 0, 0, u32(nw), u32(nh))
		ov_set_transform(m, cur, 1, 1)
		if tmp != 0 { ov_free_target(m, &tmp_pm, &tmp) }
		tmp_pm, tmp = next_pm, next
		cur, cx, cy, cw, ch = next, 0, 0, nw, nh
		// Bilinear sampling at the edges reads the pixels beside them.
		pa := XRenderPictureAttributes{repeat = REPEAT_PAD}
		XRenderChangePicture(m.dpy, cur, CP_REPEAT, &pa)
	}
	ov_set_transform(m, cur, f64(cw) / f64(dw), f64(ch) / f64(dh), cx, cy)
	XRenderComposite(m.dpy, op, cur, 0, dst, 0, 0, 0, 0, dx, dy, u32(dw), u32(dh))
	ov_set_transform(m, cur, 1, 1)
	if tmp != 0 { ov_free_target(m, &tmp_pm, &tmp) }
}

// ---------------------------------------------------------------------------
// Opening: the screen as it is, the background, the wallpapers
// ---------------------------------------------------------------------------
// The window area as the screen shows it now (before the overlay exists).
@(private)
ov_take_snapshot :: proc(m: ^Manager) {
	ov := &m.overview
	pa := XRenderPictureAttributes{subwindow_mode = INCLUDE_INFERIORS}
	root := XRenderCreatePicture(m.dpy, xlib.Drawable(m.root), ov.fmt_root, CP_SUBWINDOW_MODE, &pa)
	w := ov.work
	ov.snapshot_pm, ov.snapshot = ov_target(m, w.w, w.h, false)
	XRenderComposite(m.dpy, PICT_OP_SRC, root, 0, ov.snapshot, ov.size.x + w.x, ov.size.y + w.y, 0, 0, 0, 0, u32(w.w), u32(w.h))
	XRenderFreePicture(m.dpy, root)
}

// The picture of area `index` (0-based): the pixmap milk keeps for it, or the
// root background for the area on screen. Returns a picture to free.
@(private)
ov_wallpaper :: proc(m: ^Manager, index: int) -> (pic: Picture, w, h: i32, pm: xlib.Pixmap) {
	ov := &m.overview
	ok: bool
	if ov.probe != nil { pm, w, h, ok = ov.probe(ov.probe_data, index + 1) }
	if !ok && ov.mon != nil && index == lowest_tag(ov.mon.tagset[ov.mon.seltags]) {
		pm, ok = tx.root_pixmap(m.c)
		if ok { w, h, ok = tx.drawable_size(m.c, xlib.Drawable(pm)) }
	}
	if !ok || w < ov.size.x + ov.size.w || h < ov.size.y + ov.size.h { return 0, 0, 0, 0 }
	pic = XRenderCreatePicture(m.dpy, xlib.Drawable(pm), ov.fmt_root, 0, nil)
	return pic, w, h, pm
}

@(private)
ov_backgrounds :: proc(m: ^Manager) {
	ov := &m.overview
	size, work := ov.size, ov.work
	col := &m.settings.colors
	ov.back_pm, ov.back = ov_target(m, size.w, size.h, false)
	ov.plain_pm, ov.plain = ov_target(m, size.w, size.h, false)
	ov.dim_pm, ov.dim = ov_target(m, size.w, size.h, false)
	ov.zoom_tmp_pm, ov.zoom_tmp = ov_target(m, work.w, work.h)
	cur := lowest_tag(ov.mon.tagset[ov.mon.seltags])
	if pic, _, _, _ := ov_wallpaper(m, cur); pic != 0 {
		XRenderComposite(m.dpy, PICT_OP_SRC, pic, 0, ov.plain, size.x, size.y, 0, 0, 0, 0, u32(size.w), u32(size.h))
		// Blurred: down to a thirty-second, back up in two smooth steps.
		sw, sh := max(size.w / 32, 4), max(size.h / 32, 4)
		mw, mh := max(size.w / 4, 8), max(size.h / 4, 8)
		small_pm, small := ov_target(m, sw, sh)
		mid_pm, mid := ov_target(m, mw, mh)
		ov_scale(m, ov.plain, 0, 0, size.w, size.h, small, 0, 0, sw, sh)
		pa := XRenderPictureAttributes{repeat = REPEAT_PAD}
		XRenderChangePicture(m.dpy, small, CP_REPEAT, &pa)
		XRenderChangePicture(m.dpy, mid, CP_REPEAT, &pa)
		ov_scale(m, small, 0, 0, sw, sh, mid, 0, 0, mw, mh)
		ov_scale(m, mid, 0, 0, mw, mh, ov.dim, 0, 0, size.w, size.h)
		ov_free_target(m, &small_pm, &small)
		ov_free_target(m, &mid_pm, &mid)
		XRenderFreePicture(m.dpy, pic)
	} else {
		ov_fill(m, ov.plain, col.surface, 1, {0, 0, size.w, size.h})
		ov_fill(m, ov.dim, col.surface, 1, {0, 0, size.w, size.h})
	}
	ov_fill(m, ov.dim, col.bg, OV_TINT, {0, 0, size.w, size.h})
	// Every area's wallpaper at card size (areas sharing a picture share it).
	n := len(ov.cards)
	builtin.resize(&ov.walls, n)
	builtin.resize(&ov.wall_pms, n)
	done := make(map[xlib.Pixmap]int, context.temp_allocator)
	for i in 0 ..< n {
		ov.walls[i], ov.wall_pms[i] = 0, 0
		pic, _, _, pm := ov_wallpaper(m, i)
		if pic == 0 { continue }
		if j, found := done[pm]; found {
			XRenderFreePicture(m.dpy, pic)
			ov.walls[i] = ov.walls[j] // shared: freed once (ov_release)
			continue
		}
		ov.wall_pms[i], ov.walls[i] = ov_target(m, ov.cw, ov.ch, false)
		ov_scale(m, pic, size.x + work.x, size.y + work.y, work.w, work.h, ov.walls[i], 0, 0, ov.cw, ov.ch)
		XRenderFreePicture(m.dpy, pic)
		done[pm] = i
	}
	for &card in ov.cards {
		card.buf_pm, card.buf = ov_target(m, ov.cw, ov.ch)
		card.dirty = true
	}
	tx.set_background(m.c, ov.win, ov.back_pm)
}

// Everything made for one opening.
@(private)
ov_release :: proc(m: ^Manager) {
	ov := &m.overview
	for &t in ov.thumbs { ov_thumb_free(m, &t) }
	clear(&ov.thumbs)
	for &card in ov.cards {
		ov_free_target(m, &card.buf_pm, &card.buf)
		delete(card.items)
		delete(card.minimized)
		delete(card.mini_rects)
		card = {}
	}
	clear(&ov.cards)
	for i in 0 ..< len(ov.walls) {
		if ov.wall_pms[i] != 0 { ov_free_target(m, &ov.wall_pms[i], &ov.walls[i]) }
	}
	clear(&ov.walls)
	clear(&ov.wall_pms)
	for _, pic in ov.masks { XRenderFreePicture(m.dpy, pic) }
	clear(&ov.masks)
	for pm in ov.mask_pms { xlib.FreePixmap(m.dpy, pm) }
	clear(&ov.mask_pms)
	ov_free_target(m, &ov.back_pm, &ov.back)
	ov_free_target(m, &ov.plain_pm, &ov.plain)
	ov_free_target(m, &ov.dim_pm, &ov.dim)
	ov_free_target(m, &ov.snapshot_pm, &ov.snapshot)
	ov_free_target(m, &ov.zoom_pm, &ov.zoom)
	ov_free_target(m, &ov.zoom_tmp_pm, &ov.zoom_tmp)
}

// ---------------------------------------------------------------------------
// Window thumbnails
// ---------------------------------------------------------------------------
@(private)
ov_thumb_for :: proc(m: ^Manager, c: ^Client) -> ^Ov_Thumb {
	ov := &m.overview
	top := top_window(c)
	for &t in ov.thumbs {
		if t.win != c.win { continue }
		if t.top == top {
			// The contents may have a new size.
			if t.src != 0 {
				root: xlib.Window
				x, y: i32
				w, h, bw, depth: u32
				if xlib.GetGeometry(m.dpy, xlib.Drawable(top), &root, &x, &y, &w, &h, &bw, &depth) != xlib.Status(0) &&
				   (i32(w) != t.sw || i32(h) != t.sh) {
					t.sw, t.sh = i32(w), i32(h)
					t.dirty = true
				}
			}
			return &t
		}
		ov_thumb_free(m, &t) // framed or unframed since: start again
		t = ov_thumb_make(m, c)
		return &t
	}
	append(&ov.thumbs, ov_thumb_make(m, c))
	return &ov.thumbs[len(ov.thumbs) - 1]
}

@(private)
ov_thumb_make :: proc(m: ^Manager, c: ^Client) -> Ov_Thumb {
	ov := &m.overview
	t := Ov_Thumb{win = c.win, top = top_window(c), dirty = true}
	attrs: xlib.XWindowAttributes
	if xlib.GetWindowAttributes(m.dpy, t.top, &attrs) == 0 || attrs.class == .InputOnly || attrs.map_state == .IsUnmapped { return t }
	format := XRenderFindVisualFormat(m.dpy, attrs.visual)
	if format == nil { return t }
	pa := XRenderPictureAttributes{subwindow_mode = INCLUDE_INFERIORS, repeat = REPEAT_PAD}
	t.src = XRenderCreatePicture(m.dpy, xlib.Drawable(t.top), format, CP_SUBWINDOW_MODE | CP_REPEAT, &pa)
	t.sw, t.sh = attrs.width, attrs.height
	t.damage = XDamageCreate(m.dpy, xlib.Drawable(t.top), DAMAGE_REPORT_NON_EMPTY)
	_ = ov
	return t
}

@(private)
ov_thumb_free :: proc(m: ^Manager, t: ^Ov_Thumb) {
	if t.damage != 0 { XDamageDestroy(m.dpy, t.damage) }
	if t.src != 0 { XRenderFreePicture(m.dpy, t.src) }
	ov_free_target(m, &t.pm, &t.pic)
	if t.icon != 0 { XRenderFreePicture(m.dpy, t.icon) }
	t^ = {}
}

// The thumbnail at w×h, made again when the contents changed.
@(private)
ov_thumb_render :: proc(m: ^Manager, t: ^Ov_Thumb, w, h: i32) -> Picture {
	ov := &m.overview
	if t.src == 0 || w <= 0 || h <= 0 { return 0 }
	if t.pic != 0 && t.tw == w && t.th == h && !t.dirty { return t.pic }
	if t.tw != w || t.th != h { ov_free_target(m, &t.pm, &t.pic) }
	if t.pic == 0 { t.pm, t.pic = ov_target(m, w, h) }
	t.tw, t.th = w, h
	ov_scale(m, t.src, 0, 0, t.sw, t.sh, t.pic, 0, 0, w, h)
	c := wintoclient(m, t.win)
	if c == nil || !c.isfullscreen {
		ov_round(m, t.pic, w, h, clamp(f32(m.settings.corner_radius) * ov.scale + 1, 2, 10))
	}
	t.dirty = false
	return t.pic
}

// The window's icon (premultiplied ARGB) at `size`; 0 when it has none.
@(private)
ov_thumb_icon :: proc(m: ^Manager, t: ^Ov_Thumb, size: i32) -> Picture {
	if t.icon != 0 && t.icon_size == size { return t.icon }
	if t.icon_tried && t.icon_size == size { return 0 }
	if t.icon != 0 { XRenderFreePicture(m.dpy, t.icon) }
	t.icon, t.icon_size, t.icon_tried = 0, size, true
	img, ok := tx.window_icon(m.c, t.win, size, context.temp_allocator)
	if !ok || img.w <= 0 { return 0 }
	t.icon = ov_image_picture(m, img)
	return t.icon
}

// An RGBA image (straight alpha) as an ARGB picture.
@(private)
ov_image_picture :: proc(m: ^Manager, img: tx.Image) -> Picture {
	px := make([]u32, int(img.w) * int(img.h), context.temp_allocator)
	for i in 0 ..< len(px) {
		r, g, b, a := u32(img.rgba[i * 4]), u32(img.rgba[i * 4 + 1]), u32(img.rgba[i * 4 + 2]), u32(img.rgba[i * 4 + 3])
		px[i] = a << 24 | (r * a / 255) << 16 | (g * a / 255) << 8 | b * a / 255
	}
	pm, pic := ov_target(m, img.w, img.h)
	ximg := xlib.CreateImage(m.dpy, m.c.visual, 32, .ZPixmap, 0, raw_data(px), u32(img.w), u32(img.h), 32, img.w * 4)
	if ximg != nil {
		gc := xlib.CreateGC(m.dpy, xlib.Drawable(pm), {}, nil)
		xlib.PutImage(m.dpy, xlib.Drawable(pm), gc, ximg, 0, 0, 0, 0, u32(img.w), u32(img.h))
		xlib.FreeGC(m.dpy, gc)
		ximg.data = nil
		xlib.DestroyImage(ximg)
	}
	xlib.FreePixmap(m.dpy, pm) // the picture keeps it
	return pic
}

@(private)
ov_icon_size :: proc(ov: ^Overview) -> i32 {
	return clamp(ov.ch / 6, 16, 48)
}

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------
@(private)
ov_compose_card :: proc(m: ^Manager, i: int) {
	ov := &m.overview
	card := &ov.cards[i]
	col := &m.settings.colors
	buf := card.buf
	if buf == 0 { return }
	cw, ch := ov.cw, ov.ch
	if ov.walls[i] != 0 {
		XRenderComposite(m.dpy, PICT_OP_SRC, ov.walls[i], 0, buf, 0, 0, 0, 0, 0, 0, u32(cw), u32(ch))
	} else {
		c := XRenderColor{}
		XRenderFillRectangle(m.dpy, PICT_OP_SRC, buf, &c, 0, 0, u32(cw), u32(ch))
		ov_fill(m, buf, col.surface, 1, {0, 0, cw, ch})
	}
	isize := ov_icon_size(ov)
	for it in card.items {
		if ov.dragging && it.win == ov.press_win { continue } // lifted out of its card
		t := ov_find_thumb(ov, it.win)
		r := it.rect
		s := i32(OV_SHADOW)
		ov_fill_mask(m, buf, {0, 0, 0, 255}, 0.32, ov_mask(m, MASK_SHADOW, r.w + 2 * s, r.h + 2 * s, 4, s), {r.x - s, r.y - s + 2, r.w + 2 * s, r.h + 2 * s})
		pic: Picture
		if t != nil { pic = ov_thumb_render(m, t, r.w, r.h) }
		if pic != 0 {
			XRenderComposite(m.dpy, PICT_OP_OVER, pic, 0, buf, 0, 0, 0, 0, r.x, r.y, u32(r.w), u32(r.h))
		} else {
			// No contents (yet): the window's colour and its icon.
			ov_fill_mask(m, buf, col.bg, 0.95, ov_mask(m, MASK_FILL, r.w, r.h, 6), r)
		}
		highlighted := it.win == ov.hover_win && !ov.hover_mini && !ov.dragging || (i == ov.selected && it.win == ov.pick)
		if highlighted {
			w := i32(2)
			ov_fill_mask(m, buf, col.accent, 1, ov_mask(m, MASK_RING, r.w + 2 * w, r.h + 2 * w, 6, w), {r.x - w, r.y - w, r.w + 2 * w, r.h + 2 * w})
		}
		// The icon at the bottom, or in the middle of a small (or empty) thumbnail.
		if t != nil {
			sz := min(isize, r.w - 8, r.h - 8)
			if pic == 0 { sz = min(isize * 3 / 2, r.w - 8, r.h - 8) }
			if sz >= 12 {
				if icon := ov_thumb_icon(m, t, sz); icon != 0 {
					y := r.y + r.h - sz - max(r.h / 12, 4)
					if pic == 0 || r.h < 3 * sz { y = r.y + (r.h - sz) / 2 }
					XRenderComposite(m.dpy, PICT_OP_OVER, icon, 0, buf, 0, 0, 0, 0, r.x + (r.w - sz) / 2, y, u32(sz), u32(sz))
				}
			}
		}
	}
	// Minimized windows: their icons on small plates.
	for w, k in card.minimized {
		r := card.mini_rects[k]
		hovered := ov.hover_win == w && ov.hover_mini
		ov_fill_mask(m, buf, col.bg, hovered ? 0.98 : 0.82, ov_mask(m, MASK_FILL, r.w + 6, r.h + 6, 6), {r.x - 3, r.y - 3, r.w + 6, r.h + 6})
		icon: Picture
		if t := ov_find_thumb(ov, w); t != nil { icon = ov_thumb_icon(m, t, r.w) }
		if icon != 0 {
			ov_blend(m, icon, buf, 0, 0, r, hovered ? 1 : 0.7)
		} else {
			// No icon: the outline of a window.
			g := tx.Rect{r.x + r.w / 6, r.y + r.h / 5, r.w - r.w / 3, r.h - 2 * (r.h / 5)}
			a: f32 = hovered ? 0.9 : 0.6
			ov_fill_mask(m, buf, col.fg, a, ov_mask(m, MASK_RING, g.w, g.h, 3, 2), g)
			ov_fill(m, buf, col.fg, a, {g.x + 2, g.y + g.h / 3, g.w - 4, 2})
		}
	}
	if ov.dragging && i == ov.drop_card && i != ov.press_card { ov_fill(m, buf, col.accent, 0.18, {0, 0, cw, ch}) }
	ov_round(m, buf, cw, ch, ov.radius)
	card.dirty = false
}

@(private)
ov_find_thumb :: proc(ov: ^Overview, win: xlib.Window) -> ^Ov_Thumb {
	for &t in ov.thumbs { if t.win == win { return &t } }
	return nil
}

// Area `index` at the size of the window area, for the zoom when the overview
// closes: its wallpaper and its windows where they go.
@(private)
ov_compose_full :: proc(m: ^Manager, index: int) {
	ov := &m.overview
	work, size := ov.work, ov.size
	if ov.zoom == 0 { ov.zoom_pm, ov.zoom = ov_target(m, work.w, work.h, false) }
	ov_rebuild(m) // the windows as they are now
	pic, _, _, _ := ov_wallpaper(m, index)
	if pic != 0 {
		XRenderComposite(m.dpy, PICT_OP_SRC, pic, 0, ov.zoom, size.x + work.x, size.y + work.y, 0, 0, 0, 0, u32(work.w), u32(work.h))
		XRenderFreePicture(m.dpy, pic)
	} else {
		ov_fill(m, ov.zoom, m.settings.colors.surface, 1, {0, 0, work.w, work.h})
	}
	if index < 0 || index >= len(ov.cards) { return }
	for it in ov.cards[index].items {
		t := ov_find_thumb(ov, it.win)
		if t == nil || t.src == 0 { continue }
		r := it.full
		if r.w <= 0 || r.h <= 0 { continue }
		ov_scale(m, t.src, 0, 0, t.sw, t.sh, ov.zoom, r.x, r.y, r.w, r.h, PICT_OP_OVER)
	}
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------
@(private)
lerp_rect :: proc(a, b: tx.Rect, t: f32) -> tx.Rect {
	l :: proc(x, y: i32, t: f32) -> i32 { return i32(math.round(f32(x) + (f32(y) - f32(x)) * t)) }
	return {l(a.x, b.x, t), l(a.y, b.y, t), l(a.w, b.w, t), l(a.h, b.h, t)}
}

@(private)
ov_paint :: proc(m: ^Manager, now: f64) {
	ov := &m.overview
	if ov.back == 0 || ov.win == 0 { return }
	col := &m.settings.colors
	size := ov.size
	t := ov_progress(ov, now)
	full := tx.Rect{0, 0, size.w, size.h}
	// Background: the screen's wallpaper giving way to the blurred one.
	if t < 1 {
		XRenderComposite(m.dpy, PICT_OP_SRC, ov.plain, 0, ov.back, 0, 0, 0, 0, 0, 0, u32(size.w), u32(size.h))
		ov_blend(m, ov.dim, ov.back, 0, 0, full, t)
	} else {
		XRenderComposite(m.dpy, PICT_OP_SRC, ov.dim, 0, ov.back, 0, 0, 0, 0, 0, 0, u32(size.w), u32(size.h))
	}
	animating := ov.phase == .Opening || ov.phase == .Closing
	cur := lowest_tag(ov.mon.tagset[ov.mon.seltags])
	for &card, i in ov.cards {
		if animating && i == ov.zoom_card { continue }
		if card.dirty { ov_compose_card(m, i) }
		r := card.rect
		s := i32(OV_CARD_SHADOW)
		ov_fill_mask(m, ov.back, {0, 0, 0, 255}, 0.30 * t, ov_mask(m, MASK_SHADOW, r.w + 2 * s, r.h + 2 * s, ov.radius, s), {r.x - s, r.y - s + 4, r.w + 2 * s, r.h + 2 * s})
		ov_blend(m, card.buf, ov.back, 0, 0, r, t)
	}
	// Rings: the area on screen, the one the keyboard is on, the one under the pointer.
	for card, i in ov.cards {
		if animating && i == ov.zoom_card { continue }
		ring: tx.Color
		alpha: f32
		width := i32(2)
		switch {
		case ov.dragging && i == ov.drop_card:     ring, alpha, width = col.accent, 1, 3
		case i == cur:                             ring, alpha, width = col.accent, 1, 3
		case i == ov.selected:                     ring, alpha = col.fg, 0.55
		case i == ov.hover_card && !ov.dragging:   ring, alpha = col.fg, 0.3
		}
		r := card.rect
		// A faint edge, for cards as plain as the background around them.
		ov_fill_mask(m, ov.back, col.fg, 0.10 * t, ov_mask(m, MASK_RING, r.w, r.h, ov.radius, 1), r)
		if alpha <= 0 { continue }
		o := OV_RING_GAP + width
		ov_fill_mask(m, ov.back, ring, alpha * t, ov_mask(m, MASK_RING, r.w + 2 * o, r.h + 2 * o, ov.radius + f32(o), width),
		             {r.x - o, r.y - o, r.w + 2 * o, r.h + 2 * o})
	}
	ts := tx.text_surface_make(m.c, xlib.Drawable(ov.back_pm))
	defer tx.text_surface_destroy(&ts)
	ov_paint_labels(m, &ts, t, cur)
	// The area zooming out of (or into) the screen.
	if animating && ov.zoom_card >= 0 && ov.zoom_card < len(ov.cards) {
		src := ov.phase == .Opening ? ov.snapshot : ov.zoom
		if src != 0 {
			r := lerp_rect(ov.work, ov.cards[ov.zoom_card].rect, t)
			if r.w > 0 && r.h > 0 {
				ov_scale(m, src, 0, 0, ov.work.w, ov.work.h, ov.zoom_tmp, 0, 0, r.w, r.h)
				ov_round_corners(m, ov.zoom_tmp, r.w, r.h, i32(ov.radius * t + 0.5))
				XRenderComposite(m.dpy, PICT_OP_OVER, ov.zoom_tmp, 0, ov.back, 0, 0, 0, 0, r.x, r.y, u32(r.w), u32(r.h))
			}
		}
	}
	// The window being dragged follows the pointer.
	if ov.dragging {
		if th := ov_find_thumb(ov, ov.press_win); th != nil && th.pic != 0 {
			r := tx.Rect{ov.pointer.x - ov.press_off.x, ov.pointer.y - ov.press_off.y, th.tw, th.th}
			s := i32(OV_SHADOW + 4)
			ov_fill_mask(m, ov.back, {0, 0, 0, 255}, 0.4, ov_mask(m, MASK_SHADOW, r.w + 2 * s, r.h + 2 * s, 6, s), {r.x - s, r.y - s + 4, r.w + 2 * s, r.h + 2 * s})
			ov_blend(m, th.pic, ov.back, 0, 0, r, 0.92)
		}
	}
	ov_paint_title(m, &ts)
	xlib.ClearArea(m.dpy, ov.win, 0, 0, 0, 0, false)
	xlib.Flush(m.dpy)
	ov.need_paint = false
	ov.painted_at = now
}

// Labels under the cards and the hints.
@(private)
ov_paint_labels :: proc(m: ^Manager, ts: ^tx.Text_Surface, t: f32, cur: int) {
	ov := &m.overview
	col := &m.settings.colors
	if ov.label_font == nil { return }
	a := u8(clamp(t, 0, 1) * 255)
	for card, i in ov.cards {
		label := ov_area_label(m, i)
		fg := i == cur ? col.accent : col.fg
		glyph := ""
		if i < len(m.settings.area_icons) && m.settings.area_icons[i] != 0 && ov.glyph_font != nil && tx.font_has_glyph(m.c, ov.glyph_font, m.settings.area_icons[i]) {
			glyph = fmt.tprintf("%r", m.settings.area_icons[i])
		}
		lw := tx.text_width(m.c, ov.label_font, label)
		gw := glyph != "" ? tx.text_width(m.c, ov.glyph_font, glyph) + 8 : 0
		x := card.rect.x + (card.rect.w - lw - gw) / 2
		y := card.rect.y + card.rect.h + 4
		if glyph != "" {
			tx.draw_text_centered_v(ts, ov.glyph_font, x, y, ov.label_h - 4, glyph, tx.color_with_alpha(fg, a))
			x += gw
		}
		tx.draw_text_centered_v(ts, ov.label_font, x, y, ov.label_h - 4, label, tx.color_with_alpha(fg, a))
	}
	if ov.hint_font != nil {
		hint := tr(m, "Clique para ir · arraste uma janela para outra área · botão do meio fecha · Esc volta",
		             "Click to go there · drag a window to another area · middle click closes · Esc goes back")
		hint = tx.text_ellipsize(m.c, ov.hint_font, hint, ov.work.w - 40)
		hw := tx.text_width(m.c, ov.hint_font, hint)
		tx.draw_text_centered_v(ts, ov.hint_font, ov.work.x + (ov.work.w - hw) / 2, ov.hint_y, ov.hint_font.height + 24, hint,
		                        tx.color_with_alpha(col.fg, u8(f32(a) * 0.62)))
	}
}

// The title of the window under the pointer, on a plate above it.
@(private)
ov_paint_title :: proc(m: ^Manager, ts: ^tx.Text_Surface) {
	ov := &m.overview
	col := &m.settings.colors
	if ov.phase == .Open && !ov.dragging && ov.hover_win != 0 && ov.hover_card >= 0 && ov.hint_font != nil {
		c := wintoclient(m, ov.hover_win)
		if c == nil { return }
		card := &ov.cards[ov.hover_card]
		r: tx.Rect
		found := false
		if ov.hover_mini {
			for w, k in card.minimized { if w == ov.hover_win { r, found = card.mini_rects[k], true } }
		} else {
			for it in card.items { if it.win == ov.hover_win { r, found = it.rect, true } }
		}
		if !found { return }
		title := tx.text_ellipsize(m.c, ov.hint_font, c.name, max(ov.cw * 3 / 2, 160))
		if title == "" { return }
		pad := i32(10)
		w := tx.text_width(m.c, ov.hint_font, title) + 2 * pad
		h := ov.hint_font.height + 10
		x := clamp(card.rect.x + r.x + (r.w - w) / 2, 4, ov.size.w - w - 4)
		y := card.rect.y + r.y - h - 6
		if y < 4 { y = card.rect.y + r.y + r.h + 6 }
		plate := tx.Rect{x, y, w, h}
		ov_fill_mask(m, ov.back, col.bg, 0.96, ov_mask(m, MASK_FILL, w, h, f32(h) / 2), plate)
		tx.draw_text_centered_v(ts, ov.hint_font, x + pad, y, h, title, col.fg)
	}
}

// "1", or "1  Name" when the area has a name.
@(private)
ov_area_label :: proc(m: ^Manager, i: int) -> string {
	number := fmt.tprintf("%d", i + 1)
	if i >= len(m.settings.desktop_names) { return number }
	name := strings.trim_space(m.settings.desktop_names[i])
	if name == "" || name == number { return number }
	return fmt.tprintf("%s   %s", number, name)
}
