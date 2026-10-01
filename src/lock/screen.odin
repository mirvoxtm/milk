// Drawing the lock screen: on every monitor the clock and the date in the
// upper part, then the user (an accent circle with the Tabler user icon or
// the initial) and the password field with its messages. Shapes are drawn on
// the panel's CPU canvas over its piece of the blurred wallpaper, text with
// Xft on the uploaded pixmap, which is copied into the window.
package lock

import "core:math"
import "core:unicode"
import "core:unicode/utf8"
import xlib "vendor:x11/xlib"
import tx "../tx"

@(private) ICON_USER :: rune(0xEB4D)

@(private)
caret_visible :: proc(l: ^Locker, now: f64) -> bool {
	if l.state == .Checking { return false }
	return math.mod(now - l.caret_epoch, 2 * CARET_PERIOD) < CARET_PERIOD
}

@(private)
render :: proc(l: ^Locker) {
	l.dirty = false
	now := tx.now()
	l.drawn_caret = caret_visible(l, now)
	l.last_frame = now
	if l.gc == nil {
		// No GraphicsExpose/NoExpose events for every copy.
		values: xlib.XGCValues
		values.graphics_exposures = false
		l.gc = xlib.CreateGC(l.c.dpy, xlib.Drawable(l.win), {.GCGraphicsExposures}, &values)
	}
	for &p in l.panels { render_panel(l, &p, now) }
}

@(private)
render_panel :: proc(l: ^Locker, p: ^Panel, now: f64) {
	c := l.c
	st := &l.style
	cv := &p.cv
	s := p.scale
	W := p.rect.w

	// The wallpaper under the panel.
	ox := p.rect.x - l.screen.x
	for y in 0 ..< p.rect.h {
		sy := p.rect.y - l.screen.y + y
		if sy < 0 || sy >= l.bg.h { continue }
		src := int(sy) * int(l.bg.w) + int(ox)
		dst := int(y) * int(W)
		n := int(min(W, l.bg.w - ox))
		if n > 0 { copy(cv.px[dst:dst + n], l.bg.px[src:src + n]) }
	}

	// Layout (panel coordinates).
	clock_h := p.f_clock != nil ? p.f_clock.height : i32(120 * s)
	date_y := clock_h + i32(2 * s)
	av_r := 42 * s
	av_cy := f32(p.mon.y + i32(f32(p.mon.h) * 0.53) - p.rect.y)
	name_y := i32(av_cy + av_r) + i32(14 * s)
	name_h := p.f_name != nil ? p.f_name.height : i32(26 * s)
	fw := min(i32(380 * s), W - 40)
	fh := i32(54 * s)
	shake: i32 = 0
	if t := now - l.shake_start; t >= 0 && t < SHAKE_TIME {
		decay := 1 - t / SHAKE_TIME
		shake = i32(math.sin(t * 2 * math.PI * 7) * f64(12 * s) * decay)
	}
	field := tx.Rect{(W - fw) / 2 + shake, name_y + name_h + i32(16 * s), fw, fh}
	msg_y := field.y + field.h + i32(14 * s)
	small_h := p.f_small != nil ? p.f_small.height : i32(18 * s)
	body_h := p.f_body != nil ? p.f_body.height : i32(22 * s)
	caps_y := msg_y + body_h + i32(10 * s)

	// Shapes: the profile picture, or an accent circle with the user icon.
	if l.face.w > 0 {
		d := i32(2 * av_r)
		if p.face.w != d {
			if p.face.w > 0 { delete(p.face.rgba) }
			p.face = tx.image_circle(l.face, d)
		}
		tx.canvas_fill_circle(cv, f32(W) / 2, av_cy, av_r + 3 * s, tx.color_with_alpha(st.bg, 200))
		tx.canvas_blit_image(cv, p.face, W / 2 - d / 2, i32(av_cy) - d / 2)
	} else {
		tx.canvas_fill_circle(cv, f32(W) / 2, av_cy, av_r, st.accent)
	}
	tx.canvas_fill_rounded_rect(cv, field, f32(fh) / 2, tx.color_with_alpha(st.bg, 238))
	switch l.state {
	case .Wrong:
		tx.canvas_stroke_rounded_rect(cv, field, f32(fh) / 2, 2 * s, st.warning)
	case .Checking:
		pulse := 0.5 + 0.5 * math.sin(now * 2 * math.PI * 1.4)
		tx.canvas_stroke_rounded_rect(cv, field, f32(fh) / 2, 2 * s, tx.color_with_alpha(st.accent, u8(110 + 145 * pulse)))
	case .Typing:
		tx.canvas_stroke_rounded_rect(cv, field, f32(fh) / 2, max(1, s), tx.color_mix(st.bg, st.muted, 0.45))
	}
	pad := i32(24 * s)
	count := l.state == .Checking ? l.shown_len : utf8.rune_count(string(l.password[:l.pw_len]))
	spacing := 17 * s
	fit := max(1, int(f32(field.w - 2 * pad) / spacing))
	shown := min(count, fit)
	dot_color := l.state == .Checking ? st.muted : st.fg
	cy := f32(field.y) + f32(fh) / 2
	for i in 0 ..< shown {
		cx := f32(field.x + pad) + spacing * (f32(i) + 0.5)
		tx.canvas_fill_circle(cv, cx, cy, 5 * s, dot_color)
	}
	if l.drawn_caret {
		x := f32(field.x + pad) + spacing * f32(shown) + (shown > 0 ? 2 * s : 0)
		tx.canvas_fill_rect(cv, {i32(x), i32(cy - 12 * s), max(2, i32(2 * s)), i32(24 * s)}, st.accent)
	}
	warn := tx.color_mix(st.warning, tx.rgb(255, 255, 255), 0.6)
	caps_text := tr(l, "Caps Lock está ativado", "Caps Lock is on")
	caps_w: i32 = 0
	if l.caps && p.f_small != nil {
		caps_w = tx.text_width(c, p.f_small, caps_text) + i32(28 * s)
		pill := tx.Rect{(W - caps_w) / 2, caps_y - i32(4 * s), caps_w, small_h + i32(8 * s)}
		tx.canvas_fill_rounded_rect(cv, pill, f32(pill.h) / 2, tx.color_with_alpha(st.warning, 200))
	}
	tx.canvas_upload(c, cv^, xlib.Drawable(p.pixmap), 0, 0)

	// Text.
	ts := &p.ts
	center :: proc(c: ^tx.Connection, ts: ^tx.Text_Surface, f: ^tx.Font, W, top: i32, text: string, color: tx.Color) {
		if f == nil || text == "" { return }
		w := tx.text_width(c, f, text)
		tx.draw_text(ts, f, (W - w) / 2, top + f.ascent, text, color)
	}
	center(c, ts, p.f_clock, W, 0, l.clock_text, st.text)
	center(c, ts, p.f_date, W, date_y, l.date_text, st.text_dim)
	if l.face.w > 0 {
		// The picture says who it is.
	} else if p.f_icon != nil && tx.font_has_glyph(c, p.f_icon, ICON_USER) {
		buf, n := utf8.encode_rune(ICON_USER)
		glyph := string(buf[:n])
		ext := tx.text_extents(c, p.f_icon, glyph)
		gx := W / 2 - i32(ext.width) / 2 + i32(ext.x)
		gy := i32(av_cy) - i32(ext.height) / 2 + i32(ext.y)
		tx.draw_text(ts, p.f_icon, gx, gy, glyph, st.accent_fg)
	} else if p.f_name != nil && l.display_name != "" {
		r, _ := utf8.decode_rune(l.display_name)
		initial := utf8.runes_to_string({unicode.to_upper(r)}, context.temp_allocator)
		ext := tx.text_extents(c, p.f_name, initial)
		tx.draw_text(ts, p.f_name, W / 2 - i32(ext.width) / 2 + i32(ext.x), i32(av_cy) - i32(ext.height) / 2 + i32(ext.y), initial, st.accent_fg)
	}
	center(c, ts, p.f_name, W, name_y, l.display_name, st.text)
	if count == 0 && l.state == .Typing && p.f_body != nil {
		label := tr(l, "Senha", "Password")
		tx.draw_text(ts, p.f_body, field.x + pad + (l.drawn_caret ? i32(8 * s) : 0) + i32(2 * s),
		             field.y + (fh - p.f_body.height) / 2 + p.f_body.ascent, label, st.muted)
	}
	message := ""
	color := st.text_dim
	switch l.state {
	case .Checking:
		message = tr(l, "Verificando…", "Checking…")
	case .Wrong:
		message = tr(l, "Senha incorreta", "Wrong password")
		color = warn
	case .Typing:
		if count == 0 { message = tr(l, "Digite a senha para desbloquear", "Type your password to unlock") }
	}
	center(c, ts, p.f_body, W, msg_y, message, color)
	if l.caps && p.f_small != nil {
		center(c, ts, p.f_small, W, caps_y, caps_text, tx.rgb(255, 255, 255))
	}
	when TEST_BUILD {
		// Never mistaken for a real lock screen.
		center(c, ts, p.f_small, W, p.rect.h - small_h, "TEST BUILD: PAM is off", warn)
	}
	xlib.CopyArea(c.dpy, xlib.Drawable(p.pixmap), xlib.Drawable(l.win), l.gc, 0, 0, u32(p.rect.w), u32(p.rect.h),
	              p.rect.x - l.screen.x, p.rect.y - l.screen.y)
}
