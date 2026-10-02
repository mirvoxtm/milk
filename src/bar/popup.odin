// Popup cards shared by the quick settings, the volume/brightness sliders and
// the Wi-Fi and Bluetooth menus. A card is an override-redirect window with
// rounded corners cut by the SHAPE extension, sized to the card itself and
// painted opaque (theme background and a 1 px outline): nothing around it is
// a copy of the screen, so windows behind it never leave stale pixels.
//
// Rules: one popup at a time; a card grabs the pointer (a click elsewhere
// closes it) and the keyboard (Escape closes it); it opens below a top bar or
// above a bottom one, sliding out from under the bar over a short animation
// (config.anim_duration; 0 = no animation).
package bar

import "core:fmt"
import "core:math"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "../tx"
import config "../config"

@(private) CARD_RADIUS :: 16
@(private) POPUP_GAP   :: 6   // visible bar edge → card edge
@(private) CARD_SLIDE  :: 10  // pixels the card travels while opening
@(private) CARD_ANIM   :: 0.12

@(private)
CARD_EVENT_MASK :: xlib.EventMask{.ButtonPress, .ButtonRelease, .PointerMotion, .LeaveWindow, .KeyPress}

@(private)
Card :: struct {
	win:        xlib.Window,
	pixmap:     xlib.Pixmap,
	rect:       tx.Rect, // final place, screen coordinates
	y:          i32,     // current window y (differs while sliding in)
	shape_w:    i32,     // size the shape was cut for
	shape_h:    i32,
	open:       bool,
	grabbed:    bool,
	keyboard:   bool,
	anim_start: f64,
	anim_len:   f64,     // 0 = not animating
	anim_from:  i32,
}

@(private)
Card_Align :: enum { Center, Right }

// Where a w x h card goes: next to the visible bar, horizontally centred on
// `anchor_x` (or ending near it with .Right), kept 8 px inside the monitor.
@(private)
card_place :: proc(b: ^Bar, anchor_x: i32, align: Card_Align, w, h: i32) -> tx.Rect {
	mon := tx.monitor_rect(b.c, b.cfg.bar.monitor)
	bar := bar_rect(b)
	x := align == .Center ? anchor_x - w / 2 : anchor_x - w + 8
	x = clamp(x, mon.x + 8, max(mon.x + 8, mon.x + mon.w - w - 8))
	y: i32
	if b.cfg.bar.position == "bottom" {
		y = max(mon.y + 4, bar.y - POPUP_GAP - h)
	} else {
		y = bar.y + bar.h + POPUP_GAP
	}
	return {x, y, w, h}
}

// Create or move the window to `rect` and cut its rounded shape. Draw it
// (card_present) before card_map so that it never shows up blank.
@(private)
card_prepare :: proc(b: ^Bar, card: ^Card, rect: tx.Rect, name: string) {
	c := b.c
	card.rect = rect
	if !card.open { card.y = rect.y }
	r := tx.Rect{rect.x, card.y, rect.w, rect.h}
	if card.win == 0 {
		card.win = tx.create_overlay(c, r, CARD_EVENT_MASK, "_NET_WM_WINDOW_TYPE_POPUP_MENU", name)
	} else {
		tx.move_resize(c, card.win, r)
	}
	if card.shape_w != rect.w || card.shape_h != rect.h {
		tx.shape_rounded(c, card.win, rect.w, rect.h, CARD_RADIUS)
		card.shape_w, card.shape_h = rect.w, rect.h
	}
}

// Map, raise and grab. With `animate` the card slides out from under the bar.
@(private)
card_map :: proc(b: ^Bar, card: ^Card, animate: bool) {
	c := b.c
	card.anim_len = animate ? config.anim_duration(b.cfg, CARD_ANIM) : 0
	if card.anim_len > 0.001 {
		card.anim_start = tx.now()
		card.anim_from = card.rect.y + (b.cfg.bar.position == "bottom" ? CARD_SLIDE : -CARD_SLIDE)
		card.y = card.anim_from
	} else {
		card.anim_len = 0
		card.y = card.rect.y
	}
	tx.move_resize(c, card.win, {card.rect.x, card.y, card.rect.w, card.rect.h})
	tx.map_window(c, card.win)
	tx.raise_window(c, card.win)
	// The bar stays on top so that the card emerges from behind it.
	if card.anim_len > 0 && b.overlay && b.win != 0 { tx.raise_window(c, b.win) }
	card.grabbed, card.keyboard = popup_grab(b, card.win)
	card.open = true
	b.need_flush = true
	b.dirty = true // the owner widget keeps its highlight
}

@(private)
card_hide :: proc(b: ^Bar, card: ^Card) {
	if !card.open { return }
	popup_ungrab(b, card.grabbed, card.keyboard)
	card.grabbed, card.keyboard = false, false
	if card.win != 0 { tx.unmap_window(b.c, card.win) }
	card.open = false
	card.anim_len = 0
	b.need_flush = true
	b.dirty = true
}

@(private)
card_destroy :: proc(b: ^Bar, card: ^Card) {
	if card.win != 0 { tx.destroy_window(b.c, card.win) }
	tx.pixmap_free(b.c, card.pixmap)
	card^ = {}
}

// A new height (menus grow as their lists load): re-place, reshape, move.
@(private)
card_resize :: proc(b: ^Bar, card: ^Card, rect: tx.Rect) {
	if rect == card.rect { return }
	settled := card.anim_len == 0
	card.rect = rect
	if settled { card.y = rect.y }
	tx.move_resize(b.c, card.win, {rect.x, card.y, rect.w, rect.h})
	if card.shape_w != rect.w || card.shape_h != rect.h {
		tx.shape_rounded(b.c, card.win, rect.w, rect.h, CARD_RADIUS)
		card.shape_w, card.shape_h = rect.w, rect.h
	}
	b.need_flush = true
}

// Advance the opening slide; returns true while it runs.
@(private)
card_animate :: proc(b: ^Bar, card: ^Card, now: f64) -> bool {
	if !card.open || card.anim_len <= 0 { return false }
	t := clamp((now - card.anim_start) / card.anim_len, 0, 1)
	e := 1 - math.pow(1 - t, 3) // ease-out cubic
	y := card.anim_from + i32(math.round(f64(card.rect.y - card.anim_from) * e))
	if y != card.y {
		card.y = y
		tx.move_resize(b.c, card.win, {card.rect.x, card.y, card.rect.w, card.rect.h})
		b.need_flush = true
	}
	if t >= 1 {
		card.anim_len = 0
		return false
	}
	return true
}

// Screen → card coordinates (follows the slide).
@(private)
card_local :: proc(card: ^Card, x_root, y_root: i32) -> (x, y: i32) {
	return x_root - card.rect.x, y_root - card.y
}

@(private)
card_contains :: proc(card: ^Card, x, y: i32) -> bool {
	return tx.rect_contains({0, 0, card.rect.w, card.rect.h}, x, y)
}

// ---------------------------------------------------------------------------
// Drawing helpers
// ---------------------------------------------------------------------------

// Text queued while shapes are painted on the canvas, drawn with Xft once the
// canvas is a pixmap.
@(private)
Card_Text :: struct {
	font:     ^tx.Font,
	x:        i32,
	baseline: i32,
	s:        string,
	color:    tx.Color,
}

@(private)
Card_Painter :: struct {
	b:     ^Bar,
	cv:    tx.Canvas,
	texts: [dynamic]Card_Text,
}

// An opaque card canvas: theme background and a faint 1 px outline (the
// window shape cuts the corners).
@(private)
painter_begin :: proc(b: ^Bar, w, h: i32, outline := true) -> Card_Painter {
	p := Card_Painter{b = b, cv = tx.canvas_make(w, h, context.temp_allocator)}
	p.texts = make([dynamic]Card_Text, context.temp_allocator)
	tx.canvas_fill(&p.cv, b.theme.background)
	if outline { painter_outline(&p) }
	return p
}

@(private)
painter_outline :: proc(p: ^Card_Painter) {
	tx.canvas_stroke_rounded_rect(&p.cv, {0, 0, p.cv.w, p.cv.h}, CARD_RADIUS, 1, tx.color_with_alpha(p.b.theme.muted, 90))
}

// Menus paint on a tall canvas, then keep the rows they used (the stride is
// the width, so the first h rows are a prefix) and add the outline.
@(private)
painter_crop :: proc(p: ^Card_Painter, h: i32) {
	p.cv.h = clamp(h, 1, p.cv.h)
	p.cv.px = p.cv.px[:int(p.cv.w) * int(p.cv.h)]
	painter_outline(p)
}

// Place a card that is not open yet, or move/reshape an open one.
@(private)
card_fit :: proc(b: ^Bar, card: ^Card, rect: tx.Rect, name: string) {
	if card.open {
		card_resize(b, card, rect)
	} else {
		card_prepare(b, card, rect, name)
	}
}

// Upload the canvas as the window background and draw the queued text.
@(private)
painter_present :: proc(p: ^Card_Painter, card: ^Card) {
	b := p.b
	c := b.c
	pm := tx.canvas_to_pixmap(c, p.cv)
	ts := tx.text_surface_make(c, xlib.Drawable(pm))
	for t in p.texts { tx.draw_text(&ts, t.font, t.x, t.baseline, t.s, t.color) }
	tx.text_surface_destroy(&ts)
	tx.set_background(c, card.win, pm)
	tx.pixmap_free(c, card.pixmap)
	card.pixmap = pm
	b.need_flush = true
}

// Text vertically centred in a box of height `box_h` at `box_y`.
@(private)
paint_text :: proc(p: ^Card_Painter, font: ^tx.Font, x, box_y, box_h: i32, s: string, color: tx.Color) {
	if font == nil || s == "" { return }
	append(&p.texts, Card_Text{font, x, box_y + (box_h - font.height) / 2 + font.ascent, s, color})
}

// Text ellipsised to `max_w` pixels; returns its width.
@(private)
paint_text_fit :: proc(p: ^Card_Painter, font: ^tx.Font, x, box_y, box_h, max_w: i32, s: string, color: tx.Color) -> i32 {
	if font == nil || s == "" || max_w <= 0 { return 0 }
	text := tx.text_ellipsize(p.b.c, font, s, max_w)
	paint_text(p, font, x, box_y, box_h, text, color)
	return tx.text_width(p.b.c, font, text)
}

// An icon glyph centred on its ink in `box`.
@(private)
paint_icon :: proc(p: ^Card_Painter, icon: Icon, box: tx.Rect, color: tx.Color) {
	g := &p.b.icons.glyphs[icon]
	if !g.ok { return }
	x := box.x + (box.w - g.advance) / 2 + g.dx
	baseline := box.y + (box.h - g.ink_h) / 2 + g.ink_y
	append(&p.texts, Card_Text{g.font, x, baseline, g.text, color})
}

// A pill button; `primary` fills it with the accent colour.
@(private)
paint_button :: proc(p: ^Card_Painter, r: tx.Rect, label: string, primary, hovered: bool) {
	th := &p.b.theme
	fill := primary ? th.accent : th.surface
	if hovered { fill = primary ? tx.color_mix(th.accent, th.background, 0.18) : tx.color_mix(th.surface, th.muted, 0.35) }
	tx.canvas_fill_rounded_rect(&p.cv, r, f32(r.h) / 2, fill)
	tw := tx.text_width(p.b.c, p.b.font, label)
	paint_text(p, p.b.font, r.x + (r.w - tw) / 2, r.y, r.h, label, primary ? th.accent_foreground : th.foreground)
}

// Material switch (44 x 24) whose right edge is `right`, centred in a row.
@(private)
paint_switch :: proc(p: ^Card_Painter, right, row_y, row_h: i32, on: bool) -> tx.Rect {
	th := &p.b.theme
	track := tx.Rect{right - 44, row_y + (row_h - 24) / 2, 44, 24}
	fill := on ? th.accent : tx.color_mix(th.surface, th.muted, 0.25)
	tx.canvas_fill_rounded_rect(&p.cv, track, 12, fill)
	if !on { tx.canvas_stroke_rounded_rect(&p.cv, track, 12, 1.5, th.muted) }
	knob_r: f32 = on ? 8 : 6
	kx := on ? f32(track.x + track.w - 12) : f32(track.x + 12)
	tx.canvas_fill_circle(&p.cv, kx, f32(track.y) + 12, knob_r, on ? th.accent_foreground : th.muted)
	return track
}

// Busy indicator: eight dots around a circle, the brightest one turning.
@(private)
paint_spinner :: proc(p: ^Card_Painter, cx, cy: f32, radius: f32, color: tx.Color) {
	N :: 8
	head := int(tx.now() * 12) % N
	for i in 0 ..< N {
		angle := f32(i) * 2 * math.PI / N - math.PI / 2
		age := (head - i + N) % N
		alpha := u8(max(40, 255 - age * 30))
		tx.canvas_fill_circle(&p.cv, cx + radius * math.cos(angle), cy + radius * math.sin(angle), 1.8, tx.color_with_alpha(color, alpha))
	}
}

@(private)
paint_divider :: proc(p: ^Card_Painter, x, y, w: i32) {
	tx.canvas_fill_rect(&p.cv, {x, y, w, 1}, tx.color_with_alpha(p.b.theme.muted, 60))
}

// ---------------------------------------------------------------------------
// Popup input
// ---------------------------------------------------------------------------

// Menu-like input: clicks on other clients' windows are reported to the popup
// (which closes it), and the keyboard goes to it for Escape and the arrows.
@(private)
popup_grab :: proc(b: ^Bar, win: xlib.Window) -> (pointer, keyboard: bool) {
	ps := xlib.GrabPointer(b.c.dpy, win, true, {.ButtonPress, .ButtonRelease, .PointerMotion},
	                       .GrabModeAsync, .GrabModeAsync, 0, 0, xlib.CurrentTime)
	ks := xlib.GrabKeyboard(b.c.dpy, win, false, .GrabModeAsync, .GrabModeAsync, xlib.CurrentTime)
	return ps == 0, ks == 0
}

@(private)
popup_ungrab :: proc(b: ^Bar, pointer, keyboard: bool) {
	if pointer { xlib.UngrabPointer(b.c.dpy, xlib.CurrentTime) }
	if keyboard { xlib.UngrabKeyboard(b.c.dpy, xlib.CurrentTime) }
}

@(private)
popup_open :: proc(b: ^Bar) -> bool {
	return b.settings.card.open || b.slider.card.open || b.wifi.card.open || b.btm.card.open
}

@(private)
is_popup_window :: proc(b: ^Bar, win: xlib.Window) -> bool {
	if win == 0 { return false }
	return win == b.settings.card.win || win == b.slider.card.win || win == b.wifi.card.win || win == b.btm.card.win
}

// Advance the card animations and the menus (refreshes, spinners); returns
// the seconds until the next deadline (-1 = nothing to do).
@(private)
popups_tick :: proc(b: ^Bar, now: f64) -> f64 {
	earliest :: proc(a, c: f64) -> f64 {
		if a < 0 { return c }
		if c < 0 { return a }
		return min(a, c)
	}
	next := -1.0
	for card in ([]^Card{&b.settings.card, &b.slider.card, &b.wifi.card, &b.btm.card}) {
		if card_animate(b, card, now) { next = 1.0 / 60 }
	}
	next = earliest(next, wifi_tick(b, now))
	next = earliest(next, bt_tick(b, now))
	next = earliest(next, audio_tick(b, now)) // the volume card's device list (audio.odin)
	next = earliest(next, osd_tick(b, now)) // the volume/brightness pop-up (osd.odin)
	return next
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

// Quote a string for `sh -c`.
@(private)
shell_quote :: proc(s: string) -> string {
	escaped, _ := strings.replace_all(s, "'", `'\''`, context.temp_allocator)
	return fmt.tprintf("'%s'", escaped)
}
