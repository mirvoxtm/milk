// The clipboard panel: a Material card anchored to the bar's clipboard icon
// (like Windows 11's Win+V flyout) listing the history newest first. Click an
// entry to put it back on the clipboard; pin or delete entries; "Clear all".
// The window is the card itself, rounded with the SHAPE extension (no copy of
// the screen, so nothing goes stale); the list is rendered into its own pixmap
// so text is clipped to it. Opening slides the card out of the bar.
package clip

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import xlib "vendor:x11/xlib"
import tx "../tx"
import config "../config"

@(private) CARD_W      :: 392
@(private) CARD_H      :: 480
@(private) SLIDE       :: 12  // pixels the card travels while opening
@(private) OPEN_ANIM   :: 0.15 // seconds at animation scale 1
@(private) RADIUS      :: 18
@(private) PAD         :: 12  // card edge → list
@(private) HEADER_H    :: 60
@(private) ITEM_GAP    :: 8
@(private) ITEM_RADIUS :: 12
@(private) ITEM_PAD    :: 14
@(private) ROW_H       :: 40  // first row of an entry (text line or picture caption + buttons)
@(private) ICON_BTN    :: 28
@(private) THUMB_MAX_H :: 150
@(private) THUMB_R     :: 8
@(private) SCROLL_STEP :: 64
@(private) BAR_GAP     :: 6   // between the bar and the card
@(private) MAX_LINES   :: 3

// Fonts tried, in order, for characters the text font lacks (CJK, emoji, symbols).
@(private) @(rodata) FALLBACK_FAMILIES := []string{"Noto Sans CJK JP", "Noto Color Emoji", "DejaVu Sans", "Noto Sans Symbols2", "Noto Sans Symbols", "Symbols Nerd Font"}

@(private) GLYPH_CLIPBOARD     :: 0xEA6F
@(private) GLYPH_TRASH         :: 0xEB41
@(private) GLYPH_PIN           :: 0xEC9C
@(private) GLYPH_PIN_FILLED    :: 0xF68E
@(private) GLYPH_PHOTO         :: 0xEB0A

@(private)
Panel_Theme :: struct {
	background, foreground, muted, accent, accent_foreground, surface, warning: tx.Color,
}

@(private)
Hit_Action :: enum u8 { Select, Pin, Delete, Clear }

@(private)
Hit :: struct {
	r:      tx.Rect, // window coordinates
	action: Hit_Action,
	index:  int,
}

@(private)
Box :: struct { y, h: i32 } // an entry in list coordinates

Panel :: struct {
	win:           xlib.Window,
	pixmap:        xlib.Pixmap,
	rect:          tx.Rect, // window on screen, shadow included
	card:          tx.Rect, // window coordinates
	view:          tx.Rect, // list viewport, window coordinates
	open:          bool,
	grabbed:       bool,
	prev_focus:    xlib.Window,
	prev_revert:   xlib.FocusRevert,
	shaped:        bool,  // rounded through the SHAPE extension
	final_y:       i32,   // resting y while the open animation runs
	slide_from:    i32,   // signed offset at the start of the animation
	anim_start:    f64,
	anim_dur:      f64,   // 0 = not animating
	hits:          [dynamic]Hit,
	boxes:         [dynamic]Box,
	content_h:     i32,
	scroll:        i32,
	hover_item:    int,
	hover_hit:     int,
	mx, my:        i32,
	closed_now:    bool, // closed by the click being dispatched
	open_serial:   uint, // first request serial issued while opening
	look_ready:    bool,
	theme:         Panel_Theme,
	font:          ^tx.Font,
	bold:          ^tx.Font,
	small:         ^tx.Font,
	icons:         ^tx.Font,
	icons_small:   ^tx.Font,
	icons_big:     ^tx.Font,
	fallbacks:     [dynamic]^tx.Font,
}

@(private)
Text_Op :: struct {
	font:     ^tx.Font,
	x, base:  i32,
	s:        string,
	color:    tx.Color,
	runs:     bool, // entry text: fall back to other fonts for missing glyphs
}

// A run of text drawn with one font.
@(private)
Seg :: struct {
	font: ^tx.Font,
	s:    string,
}

// ---------------------------------------------------------------------------
// Look
// ---------------------------------------------------------------------------
@(private)
ensure_look :: proc(cb: ^Clipboard) {
	p := &cb.panel
	if p.look_ready { return }
	c := cb.c
	opts := &cb.cfg.bar
	t := opts.theme
	p.theme = {
		background        = tx.color_from_hex(t.background, tx.rgb(0xF5, 0xEE, 0xE6)),
		foreground        = tx.color_from_hex(t.foreground, tx.rgb(0x3C, 0x3A, 0x38)),
		muted             = tx.color_from_hex(t.muted, tx.rgb(0xA8, 0x9E, 0x94)),
		accent            = tx.color_from_hex(t.accent, tx.rgb(0x4A, 0x3F, 0x35)),
		accent_foreground = tx.color_from_hex(t.accent_foreground, tx.rgb(0xF5, 0xEE, 0xE6)),
		surface           = tx.color_from_hex(t.surface, tx.rgb(0xE9, 0xE0, 0xD6)),
		warning           = tx.color_from_hex(t.warning, tx.rgb(0xB5, 0x47, 0x3A)),
	}
	for &col in ([]^tx.Color{&p.theme.background, &p.theme.surface}) { col.a = 255 }
	size := i32(clamp(opts.font_size, 9, 32))
	open_text :: proc(c: ^tx.Connection, pattern: string, size: i32) -> ^tx.Font {
		if f, ok := tx.font_open(c, pattern, size); ok { return f }
		if f, ok := tx.font_open(c, "sans", size); ok { return f }
		return nil
	}
	p.font = open_text(c, opts.font, size)
	p.bold = open_text(c, strings.concatenate({opts.font, ":bold"}, context.temp_allocator), size + 2)
	p.small = open_text(c, opts.font, size - 2)
	if opts.icon_font_file != "" && os.exists(opts.icon_font_file) {
		p.icons, _ = tx.font_open_file(c, opts.icon_font_file, 20)
		p.icons_small, _ = tx.font_open_file(c, opts.icon_font_file, 17)
		p.icons_big, _ = tx.font_open_file(c, opts.icon_font_file, 46)
	}
	for family in FALLBACK_FAMILIES {
		if f, ok := tx.font_open(c, family, size); ok { append(&p.fallbacks, f) }
	}
	p.look_ready = p.font != nil && p.bold != nil && p.small != nil
}

@(private)
panel_release_look :: proc(cb: ^Clipboard) {
	p := &cb.panel
	for f in ([]^^tx.Font{&p.font, &p.bold, &p.small, &p.icons, &p.icons_small, &p.icons_big}) {
		if f^ != nil { tx.font_close(cb.c, f^) }
		f^ = nil
	}
	for f in p.fallbacks { tx.font_close(cb.c, f) }
	delete(p.fallbacks)
	p.fallbacks = nil
	p.look_ready = false
}

@(private)
panel_destroy :: proc(cb: ^Clipboard) {
	p := &cb.panel
	if p.win != 0 { tx.destroy_window(cb.c, p.win) }
	tx.pixmap_free(cb.c, p.pixmap)
	delete(p.hits)
	delete(p.boxes)
	panel_release_look(cb)
	p^ = {}
}

// ---------------------------------------------------------------------------
// Open / close
// ---------------------------------------------------------------------------
// Open the panel anchored to `anchor` (the bar icon), or centred on the
// primary monitor when `centered` is set (keyboard shortcut).
@(private)
panel_show :: proc(cb: ^Clipboard, anchor: tx.Rect, centered := false) {
	p := &cb.panel
	c := cb.c
	ensure_look(cb)
	if !p.look_ready { return }
	p.open_serial = xlib.NextRequest(c.dpy)

	cx, cy, card_w, card_h: i32
	slide: i32
	if centered {
		mon := tx.monitor_rect(c, "primary")
		card_h = clamp(i32(CARD_H), 220, max(220, mon.h - 32))
		card_w = min(i32(CARD_W), mon.w - 16)
		cx = mon.x + (mon.w - card_w) / 2
		cy = mon.y + (mon.h - card_h) / 2
		slide = SLIDE
	} else {
		acx, acy := anchor.x + anchor.w / 2, anchor.y + anchor.h / 2
		mon := tx.monitor_rect(c, cb.cfg.bar.monitor)
		for m in tx.monitors(c) {
			if tx.rect_contains(m.rect, acx, acy) {
				mon = m.rect
				break
			}
		}
		// Clear the whole bar strip, not just the icon.
		edge := anchor
		for b in tx.bars(c, mon, window_ids(cb)) {
			if tx.rect_contains(b, acx, acy) {
				edge = b
				break
			}
		}
		below := acy < mon.y + mon.h / 2 // top bar: open downwards
		avail := below ? (mon.y + mon.h) - (edge.y + edge.h) - 2 * BAR_GAP : edge.y - mon.y - 2 * BAR_GAP
		card_h = clamp(i32(CARD_H), 220, max(220, avail))
		card_w = min(i32(CARD_W), mon.w - 16)
		cx = clamp(acx - card_w / 2, mon.x + 8, mon.x + mon.w - 8 - card_w)
		cy = below ? edge.y + edge.h + BAR_GAP : edge.y - BAR_GAP - card_h
		slide = below ? -SLIDE : SLIDE // slide out of the bar
	}
	// The window is the card itself, rounded with SHAPE: nothing of the screen
	// is copied, so live windows around the corners never go stale.
	p.rect = {cx, cy, card_w, card_h}
	p.card = {0, 0, card_w, card_h}
	p.view = {PAD, HEADER_H, card_w - 2 * PAD, card_h - HEADER_H - PAD}
	p.final_y = cy
	p.anim_dur = config.anim_duration(cb.cfg, OPEN_ANIM)
	p.slide_from = p.anim_dur > 0.01 ? slide : 0
	if p.slide_from == 0 { p.anim_dur = 0 }
	p.anim_start = tx.now()
	start_rect := tx.Rect{cx, cy + p.slide_from, card_w, card_h}
	if p.win == 0 {
		p.win = tx.create_overlay(c, start_rect, {.ButtonPress, .ButtonRelease, .PointerMotion, .LeaveWindow, .KeyPress},
		                          "_NET_WM_WINDOW_TYPE_POPUP_MENU", "milk clipboard panel")
	} else {
		tx.move_resize(c, p.win, start_rect)
	}
	p.shaped = tx.shape_rounded(c, p.win, card_w, card_h, RADIUS)
	p.scroll = 0
	p.hover_item = -1
	p.hover_hit = -1
	p.mx, p.my = -1, -1
	panel_layout(cb)
	panel_draw(cb)
	tx.map_window(c, p.win)
	tx.raise_window(c, p.win)
	// Clicks outside the card close it, like a menu; Escape needs the keyboard.
	status := xlib.GrabPointer(c.dpy, p.win, true, {.ButtonPress, .ButtonRelease, .PointerMotion},
	                           .GrabModeAsync, .GrabModeAsync, 0, 0, xlib.CurrentTime)
	p.grabbed = status == 0
	xlib.GetInputFocus(c.dpy, &p.prev_focus, &p.prev_revert)
	xlib.SetInputFocus(c.dpy, p.win, .RevertToParent, xlib.CurrentTime)
	p.open = true
	p.closed_now = false
}

// Advance the open animation (ease-out slide).
@(private)
panel_tick :: proc(cb: ^Clipboard, now: f64) {
	p := &cb.panel
	if !p.open || p.anim_dur <= 0 { return }
	t := clamp((now - p.anim_start) / p.anim_dur, 0, 1)
	e := 1 - (1 - t) * (1 - t) * (1 - t)
	y := p.final_y + i32(math.round(f64(p.slide_from) * (1 - e)))
	xlib.MoveWindow(cb.c.dpy, p.win, p.rect.x, y)
	if t >= 1 { p.anim_dur = 0 }
	tx.flush(cb.c)
}

@(private)
panel_animating :: proc(cb: ^Clipboard) -> bool { return cb.panel.open && cb.panel.anim_dur > 0 }

@(private)
panel_hide :: proc(cb: ^Clipboard) {
	p := &cb.panel
	if !p.open { return }
	c := cb.c
	if p.grabbed { xlib.UngrabPointer(c.dpy, xlib.CurrentTime) }
	p.grabbed = false
	if p.win != 0 { tx.unmap_window(c, p.win) }
	if p.prev_focus > 1 && p.prev_focus != p.win {
		xlib.SetInputFocus(c.dpy, p.prev_focus, p.prev_revert, xlib.CurrentTime)
	} else {
		xlib.SetInputFocus(c.dpy, xlib.Window(1), .RevertToPointerRoot, xlib.CurrentTime) // PointerRoot
	}
	p.open = false
	p.anim_dur = 0
}

// The history changed (new copy, deletion) while the panel may be open.
@(private)
panel_changed :: proc(cb: ^Clipboard) {
	if !cb.panel.open { return }
	panel_layout(cb)
	panel_draw(cb)
	panel_hover(cb, cb.panel.mx, cb.panel.my, true)
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------
@(private)
panel_event :: proc(cb: ^Clipboard, ev: ^xlib.XEvent) {
	p := &cb.panel
	if !p.open { return }
	#partial switch ev.type {
	case .ButtonPress:
		x, y := ev.xbutton.x, ev.xbutton.y
		if !tx.rect_contains(p.card, x, y) {
			panel_hide(cb)
			p.closed_now = true
			return
		}
		switch i32(ev.xbutton.button) {
		case 4: panel_scroll(cb, -SCROLL_STEP)
		case 5: panel_scroll(cb, SCROLL_STEP)
		case 1:
			for hit in p.hits {
				if tx.rect_contains(hit.r, x, y) {
					panel_action(cb, hit.action, hit.index, ev.xbutton.time)
					return
				}
			}
		}
	case .MotionNotify:
		panel_hover(cb, ev.xmotion.x, ev.xmotion.y, false)
	case .LeaveNotify:
		panel_hover(cb, -1, -1, false)
	case .KeyPress:
		sym := xlib.LookupKeysym(&ev.xkey, 0)
		#partial switch sym {
		case .XK_Escape:
			panel_hide(cb)
		case .XK_Down, .XK_Up:
			if len(cb.items) == 0 { return }
			step := sym == .XK_Down ? 1 : -1
			next := p.hover_item < 0 ? 0 : clamp(p.hover_item + step, 0, len(cb.items) - 1)
			panel_reveal(cb, next)
			p.hover_item = next
			p.hover_hit = -1
			p.mx, p.my = -1, -1
			panel_draw(cb)
		case .XK_Return, .XK_KP_Enter:
			if p.hover_item >= 0 && p.hover_item < len(cb.items) { panel_action(cb, .Select, p.hover_item, ev.xkey.time) }
		case .XK_Delete:
			if p.hover_item >= 0 && p.hover_item < len(cb.items) { panel_action(cb, .Delete, p.hover_item, ev.xkey.time) }
		}
	}
}

@(private)
panel_action :: proc(cb: ^Clipboard, action: Hit_Action, index: int, time: xlib.Time) {
	p := &cb.panel
	switch action {
	case .Select:
		if index < 0 || index >= len(cb.items) { return }
		if become_owner(cb, cb.items[index], time) { move_to_top(cb, index) }
		panel_hide(cb)
	case .Pin:
		if index < 0 || index >= len(cb.items) { return }
		cb.items[index].pinned = !cb.items[index].pinned
		schedule_save(cb)
		panel_draw(cb)
	case .Delete:
		remove_item(cb, index)
		p.hover_item = -1
		panel_layout(cb)
		panel_draw(cb)
		panel_hover(cb, p.mx, p.my, true)
	case .Clear:
		clear_unpinned(cb)
		p.scroll = 0
		p.hover_item = -1
		panel_layout(cb)
		panel_draw(cb)
		panel_hover(cb, p.mx, p.my, true)
	}
}

@(private)
panel_scroll :: proc(cb: ^Clipboard, delta: i32) {
	p := &cb.panel
	old := p.scroll
	p.scroll = clamp(p.scroll + delta, 0, max(0, p.content_h - p.view.h))
	if p.scroll == old { return }
	panel_draw(cb)
	panel_hover(cb, p.mx, p.my, true)
}

// Scroll so that entry `index` is fully visible.
@(private)
panel_reveal :: proc(cb: ^Clipboard, index: int) {
	p := &cb.panel
	if index < 0 || index >= len(p.boxes) { return }
	b := p.boxes[index]
	if b.y < p.scroll { p.scroll = b.y }
	if b.y + b.h > p.scroll + p.view.h { p.scroll = b.y + b.h - p.view.h }
	p.scroll = clamp(p.scroll, 0, max(0, p.content_h - p.view.h))
}

// Track the pointer; redraw when the hovered entry or button changes.
@(private)
panel_hover :: proc(cb: ^Clipboard, x, y: i32, force: bool) {
	p := &cb.panel
	p.mx, p.my = x, y
	item := -1
	if tx.rect_contains(p.view, x, y) {
		ly := y - p.view.y + p.scroll
		for b, i in p.boxes {
			if ly >= b.y && ly < b.y + b.h {
				item = i
				break
			}
		}
	}
	hit := -1
	for h, i in p.hits {
		if h.action != .Select && tx.rect_contains(h.r, x, y) {
			hit = i
			break
		}
	}
	if !force && item == p.hover_item && hit == p.hover_hit { return }
	changed := item != p.hover_item || hit != p.hover_hit
	p.hover_item = item
	p.hover_hit = hit
	if changed || force { panel_draw(cb) }
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------
@(private)
thumb_max_w :: proc(cb: ^Clipboard) -> i32 { return cb.panel.view.w - 2 * ITEM_PAD }

@(private)
thumb_size :: proc(w, h, max_w: i32) -> (i32, i32) {
	if w <= 0 || h <= 0 { return max_w, 90 }
	scale := min(f32(max_w) / f32(w), f32(THUMB_MAX_H) / f32(h), 1)
	return max(1, i32(math.round(f32(w) * scale))), max(1, i32(math.round(f32(h) * scale)))
}

@(private)
text_width_for_preview :: proc(cb: ^Clipboard) -> i32 {
	return cb.panel.view.w - 2 * ITEM_PAD - 2 * ICON_BTN - 10
}

@(private)
panel_layout :: proc(cb: ^Clipboard) {
	p := &cb.panel
	clear(&p.boxes)
	y: i32 = 0
	line_h := p.font.height + 2
	for it in cb.items {
		h: i32
		switch it.kind {
		case .Text:
			if it.preview == nil { it.preview = wrap_preview(cb, string(it.data), text_width_for_preview(cb)) }
			n := i32(max(len(it.preview), 1))
			h = ROW_H + (n - 1) * line_h
		case .Image:
			_, th := thumb_size(it.w, it.h, thumb_max_w(cb))
			h = ROW_H - 4 + th + ITEM_PAD
		}
		append(&p.boxes, Box{y, h})
		y += h + ITEM_GAP
	}
	p.content_h = max(0, y - ITEM_GAP)
	p.scroll = clamp(p.scroll, 0, max(0, p.content_h - p.view.h))
}

// Up to MAX_LINES word-wrapped lines, the last one ellipsised when text remains.
@(private)
wrap_preview :: proc(cb: ^Clipboard, text: string, max_w: i32) -> []string {
	src := text
	cut := false
	if len(src) > 8192 {
		src = src[:8192]
		for len(src) > 0 && !utf8.valid_string(src) { src = src[:len(src) - 1] }
		cut = true
	}
	logical := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(src, context.temp_allocator) {
		s := strings.trim_right_space(line)
		if len(strings.trim_space(s)) == 0 { continue }
		if strings.contains_rune(s, '\t') { s, _ = strings.replace_all(s, "\t", "    ", context.temp_allocator) }
		if len(s) > 1024 {
			s = s[:1024]
			for len(s) > 0 && !utf8.valid_string(s) { s = s[:len(s) - 1] }
		}
		append(&logical, s)
		if len(logical) > MAX_LINES * 2 {
			cut = true
			break
		}
	}
	out := make([dynamic]string, 0, MAX_LINES)
	outer: for li := 0; li < len(logical); li += 1 {
		s := logical[li]
		if len(out) > 0 { s = strings.trim_left_space(s) }
		for len(s) > 0 {
			if len(out) == MAX_LINES - 1 {
				more := li < len(logical) - 1 || cut
				if !more && runs_width(cb, s) <= max_w {
					append(&out, strings.clone(s))
				} else if more && runs_width(cb, s) + runs_width(cb, " …") <= max_w {
					append(&out, strings.concatenate({s, " …"}))
				} else {
					append(&out, strings.clone(ellipsize(cb, s, max_w)))
				}
				break outer
			}
			n := fit_prefix(cb, s, max_w)
			if n < len(s) {
				if sp := strings.last_index_byte(s[:n], ' '); sp > 0 { n = sp }
			}
			if n == 0 {
				_, size := utf8.decode_rune_in_string(s)
				n = size
			}
			append(&out, strings.clone(strings.trim_right_space(s[:n])))
			s = strings.trim_left_space(s[n:])
		}
	}
	if len(out) == 0 { append(&out, strings.clone(" ")) }
	return out[:]
}

// Longest prefix (in bytes, on a rune boundary) of `s` that fits in `max_w`.
@(private)
fit_prefix :: proc(cb: ^Clipboard, s: string, max_w: i32) -> int {
	if runs_width(cb, s) <= max_w { return len(s) }
	offs := make([dynamic]int, context.temp_allocator)
	for _, i in s { append(&offs, i) }
	append(&offs, len(s))
	lo, hi := 0, len(offs) - 1
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		if runs_width(cb, s[:offs[mid]]) <= max_w { lo = mid } else { hi = mid }
	}
	return offs[lo]
}

// Split `s` into runs of the text font and the fallback fonts that have the missing glyphs.
@(private)
segments :: proc(cb: ^Clipboard, s: string) -> []Seg {
	p := &cb.panel
	out := make([dynamic]Seg, context.temp_allocator)
	start := 0
	cur: ^tx.Font
	for r, i in s {
		f := p.font
		if r >= 0x80 && !tx.font_has_glyph(cb.c, p.font, r) {
			for fb in p.fallbacks {
				if tx.font_has_glyph(cb.c, fb, r) {
					f = fb
					break
				}
			}
		}
		if cur == nil {
			cur = f
		} else if f != cur {
			append(&out, Seg{cur, s[start:i]})
			start = i
			cur = f
		}
	}
	if cur != nil && start < len(s) { append(&out, Seg{cur, s[start:]}) }
	return out[:]
}

@(private)
runs_width :: proc(cb: ^Clipboard, s: string) -> i32 {
	w: i32
	for seg in segments(cb, s) { w += tx.text_width(cb.c, seg.font, seg.s) }
	return w
}

@(private)
ellipsize :: proc(cb: ^Clipboard, s: string, max_w: i32) -> string {
	if runs_width(cb, s) <= max_w { return s }
	n := fit_prefix(cb, s, max_w - runs_width(cb, "…"))
	return strings.concatenate({strings.trim_right_space(s[:n]), "…"}, context.temp_allocator)
}

@(private)
make_thumb :: proc(cb: ^Clipboard, it: ^Item, img: tx.Image) {
	if it.w <= 0 || it.h <= 0 { it.w, it.h = img.w, img.h }
	max_w := cb.panel.view.w > 0 ? thumb_max_w(cb) : CARD_W - 2 * PAD - 2 * ITEM_PAD
	tw, th := thumb_size(img.w, img.h, max_w)
	tx.image_destroy(&it.thumb)
	it.thumb = tx.image_resize(img, tw, th)
	it.thumb_state = .Ready
}

@(private)
ensure_thumb :: proc(cb: ^Clipboard, it: ^Item) {
	tw, th := thumb_size(it.w, it.h, thumb_max_w(cb))
	if it.thumb_state == .Ready && (it.thumb.w != tw || it.thumb.h != th) { it.thumb_state = .None }
	if it.thumb_state != .None { return }
	img, ok := decode_image(it.mime, it.data)
	if !ok {
		it.thumb_state = .Failed
		return
	}
	make_thumb(cb, it, img)
	tx.image_destroy(&img)
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------
@(private)
glyph :: proc(r: rune) -> string { return utf8.runes_to_string({r}, context.temp_allocator) }

// A glyph (or short text) centred on its ink box inside `box`.
@(private)
glyph_op :: proc(cb: ^Clipboard, f: ^tx.Font, box: tx.Rect, s: string, color: tx.Color) -> Text_Op {
	ext := tx.text_extents(cb.c, f, s)
	x := box.x + (box.w - i32(ext.width)) / 2 + i32(ext.x)
	base := box.y + (box.h - i32(ext.height)) / 2 + i32(ext.y)
	return {f, x, base, s, color, false}
}

// Text vertically centred in a row.
@(private)
text_op :: proc(f: ^tx.Font, x, row_y, row_h: i32, s: string, color: tx.Color) -> Text_Op {
	return {f, x, row_y + (row_h - f.height) / 2 + f.ascent, s, color, false}
}

@(private)
human_size :: proc(n: int, pt: bool) -> string {
	switch {
	case n < 1024:        return fmt.tprintf("%d B", n)
	case n < 1024 * 1024: return fmt.tprintf("%d KB", (n + 512) / 1024)
	}
	s := fmt.tprintf("%.1f MB", f64(n) / (1024 * 1024))
	if pt { s, _ = strings.replace_all(s, ".", ",", context.temp_allocator) }
	return s
}

@(private)
image_caption :: proc(it: ^Item, pt: bool) -> string {
	kind := it.mime == "image/png" ? "PNG" : it.mime == "image/jpeg" ? "JPEG" : "BMP"
	if it.w > 0 && it.h > 0 {
		return fmt.tprintf("%d × %d  ·  %s  ·  %s", it.w, it.h, kind, human_size(len(it.data), pt))
	}
	return fmt.tprintf("%s  ·  %s", kind, human_size(len(it.data), pt))
}

// Paint `color` over the corners of `r` outside a rounded rectangle of `radius`.
@(private)
round_corners :: proc(cv: ^tx.Canvas, r: tx.Rect, radius: f32, color: tx.Color) {
	rad := i32(math.ceil(radius))
	corners := [4][2]i32{{r.x, r.y}, {r.x + r.w - rad, r.y}, {r.x, r.y + r.h - rad}, {r.x + r.w - rad, r.y + r.h - rad}}
	centres := [4][2]f32{
		{f32(r.x) + radius, f32(r.y) + radius}, {f32(r.x + r.w) - radius, f32(r.y) + radius},
		{f32(r.x) + radius, f32(r.y + r.h) - radius}, {f32(r.x + r.w) - radius, f32(r.y + r.h) - radius},
	}
	for k in 0 ..< 4 {
		for y in corners[k][1] ..< corners[k][1] + rad {
			if y < 0 || y >= cv.h { continue }
			for x in corners[k][0] ..< corners[k][0] + rad {
				if x < 0 || x >= cv.w { continue }
				dx := f32(x) + 0.5 - centres[k][0]
				dy := f32(y) + 0.5 - centres[k][1]
				// only the part of the corner square beyond the circle's centre lines
				if (k == 0 || k == 2) && dx > 0 { continue }
				if (k == 1 || k == 3) && dx < 0 { continue }
				if (k == 0 || k == 1) && dy > 0 { continue }
				if (k == 2 || k == 3) && dy < 0 { continue }
				outside := clamp(math.sqrt(dx * dx + dy * dy) - radius + 0.5, 0, 1)
				if outside <= 0 { continue }
				i := int(y) * int(cv.w) + int(x)
				dst := cv.px[i]
				a := outside * f32(color.a) / 255
				mix :: proc(d: u32, s: u8, a: f32) -> u32 { return u32(f32(d) + (f32(s) - f32(d)) * a) }
				cv.px[i] = mix((dst >> 16) & 0xFF, color.r, a) << 16 | mix((dst >> 8) & 0xFF, color.g, a) << 8 | mix(dst & 0xFF, color.b, a)
			}
		}
	}
}

@(private)
panel_draw :: proc(cb: ^Clipboard) {
	p := &cb.panel
	c := cb.c
	th := &p.theme
	pt := portuguese(cb)
	clear(&p.hits)

	cv := tx.canvas_make(p.rect.w, p.rect.h)
	defer tx.canvas_destroy(&cv)
	card := p.card
	// Opaque card; the window's SHAPE cuts the corners. A 1 px outline
	// separates it from what is behind (no shadow: that would need a copy of
	// the screen, which goes stale).
	tx.canvas_fill(&cv, th.background)
	outline := tx.color_with_alpha(th.muted, 110)
	if p.shaped {
		// The shape is binary: keep the outline one pixel inside the cut.
		tx.canvas_stroke_rounded_rect(&cv, card, RADIUS - 0.5, 1.2, outline)
	} else {
		tx.canvas_stroke_rounded_rect(&cv, card, 0, 1, outline)
	}

	head := make([dynamic]Text_Op, context.temp_allocator)
	list := make([dynamic]Text_Op, context.temp_allocator)

	// Header: icon, title, "Clear all".
	hx := card.x + PAD + 6
	head_row := tx.Rect{card.x, card.y + 6, card.w, HEADER_H - 12}
	if p.icons != nil && tx.font_has_glyph(c, p.icons, GLYPH_CLIPBOARD) {
		append(&head, glyph_op(cb, p.icons, {hx, head_row.y, 22, head_row.h}, glyph(GLYPH_CLIPBOARD), th.accent))
		hx += 32
	}
	title := pt ? "Área de transferência" : "Clipboard"
	append(&head, text_op(p.bold, hx, head_row.y, head_row.h, title, th.foreground))

	has_unpinned := false
	for it in cb.items { if !it.pinned { has_unpinned = true } }
	if len(cb.items) > 0 {
		label := pt ? "Limpar tudo" : "Clear all"
		bw := tx.text_width(c, p.font, label) + 28
		br := tx.Rect{card.x + card.w - PAD - bw, head_row.y + (head_row.h - 30) / 2, bw, 30}
		hovered := p.mx >= 0 && tx.rect_contains(br, p.mx, p.my) && has_unpinned
		fill := hovered ? tx.color_mix(th.surface, th.muted, 0.35) : th.surface
		tx.canvas_fill_rounded_rect(&cv, br, 15, fill)
		append(&head, text_op(p.font, br.x + 14, br.y, br.h, label, has_unpinned ? th.foreground : th.muted))
		if has_unpinned { append(&p.hits, Hit{r = br, action = .Clear, index = -1}) }
	}

	// The list, in its own canvas (list coordinates).
	view := p.view
	lv := tx.canvas_make(view.w, view.h)
	defer tx.canvas_destroy(&lv)
	tx.canvas_fill(&lv, th.background)
	line_h := p.font.height + 2

	if len(cb.items) == 0 {
		cy := view.h / 2 - 20
		if p.icons_big != nil && tx.font_has_glyph(c, p.icons_big, GLYPH_CLIPBOARD) {
			tx.canvas_fill_circle(&lv, f32(view.w) / 2, f32(cy - 34), 38, th.surface)
			append(&list, glyph_op(cb, p.icons_big, {0, cy - 72, view.w, 76}, glyph(GLYPH_CLIPBOARD), th.muted))
		}
		t1 := pt ? "Nada copiado ainda" : "Nothing copied yet"
		t2 := pt ? "Textos e imagens que você copiar" : "Text and pictures you copy"
		t3 := pt ? "aparecem aqui." : "show up here."
		w1 := tx.text_width(c, p.bold, t1)
		append(&list, text_op(p.bold, (view.w - w1) / 2, cy + 16, 26, t1, th.foreground))
		w2 := tx.text_width(c, p.font, t2)
		append(&list, text_op(p.font, (view.w - w2) / 2, cy + 44, line_h, t2, th.muted))
		w3 := tx.text_width(c, p.font, t3)
		append(&list, text_op(p.font, (view.w - w3) / 2, cy + 44 + line_h, line_h, t3, th.muted))
	}

	for it, i in cb.items {
		if i >= len(p.boxes) { break }
		b := p.boxes[i]
		top := b.y - p.scroll
		if top + b.h <= 0 || top >= view.h { continue }
		r := tx.Rect{0, top, view.w, b.h}
		hovered := i == p.hover_item
		fill := hovered ? tx.color_mix(th.surface, th.muted, 0.22) : th.surface
		fill.a = 255
		tx.canvas_fill_rounded_rect(&lv, r, ITEM_RADIUS, fill)
		if it.pinned { tx.canvas_stroke_rounded_rect(&lv, r, ITEM_RADIUS, 1.5, tx.color_with_alpha(th.accent, 150)) }

		// Buttons (delete, pin) on the first row, right-aligned.
		del_r := tx.Rect{r.x + r.w - 8 - ICON_BTN, r.y + (ROW_H - ICON_BTN) / 2, ICON_BTN, ICON_BTN}
		pin_r := tx.Rect{del_r.x - ICON_BTN - 2, del_r.y, ICON_BTN, ICON_BTN}
		buttons := [2]struct { r: tx.Rect, action: Hit_Action, g: rune, fallback: string }{
			{pin_r, .Pin, it.pinned ? GLYPH_PIN_FILLED : GLYPH_PIN, "•"},
			{del_r, .Delete, GLYPH_TRASH, "×"},
		}
		for bt in buttons {
			wr := tx.Rect{bt.r.x + view.x, bt.r.y + view.y, bt.r.w, bt.r.h}
			clipped, visible := tx.rect_intersect(wr, view)
			bhover := visible && p.mx >= 0 && tx.rect_contains(clipped, p.mx, p.my)
			if bhover {
				tx.canvas_fill_circle(&lv, f32(bt.r.x) + f32(bt.r.w) / 2, f32(bt.r.y) + f32(bt.r.h) / 2, f32(ICON_BTN) / 2,
				                      tx.color_mix(fill, th.muted, 0.35))
			}
			color := hovered ? th.foreground : th.muted
			if bt.action == .Pin && it.pinned { color = th.accent }
			if bt.action == .Delete && bhover { color = th.warning }
			g := glyph(bt.g)
			if p.icons_small != nil && tx.font_has_glyph(c, p.icons_small, bt.g) {
				append(&list, glyph_op(cb, p.icons_small, bt.r, g, color))
			} else {
				append(&list, glyph_op(cb, p.bold, bt.r, bt.fallback, color))
			}
			if visible { append(&p.hits, Hit{r = clipped, action = bt.action, index = i}) }
		}

		switch it.kind {
		case .Text:
			tx0 := r.x + ITEM_PAD
			first := r.y + (ROW_H - line_h) / 2
			for line, li in it.preview {
				op := text_op(p.font, tx0, first + i32(li) * line_h, line_h, line, th.foreground)
				op.runs = true
				append(&list, op)
			}
		case .Image:
			cx := r.x + ITEM_PAD
			if p.icons_small != nil && tx.font_has_glyph(c, p.icons_small, GLYPH_PHOTO) {
				append(&list, glyph_op(cb, p.icons_small, {cx - 2, r.y, 22, ROW_H}, glyph(GLYPH_PHOTO), th.muted))
				cx += 26
			}
			append(&list, text_op(p.small, cx, r.y, ROW_H, image_caption(it, pt), th.muted))
			ensure_thumb(cb, it)
			tw, tht := thumb_size(it.w, it.h, thumb_max_w(cb))
			tr := tx.Rect{r.x + ITEM_PAD, r.y + ROW_H - 4, tw, tht}
			if it.thumb_state == .Ready {
				tx.canvas_blit_image(&lv, it.thumb, tr.x, tr.y)
				round_corners(&lv, tr, THUMB_R, fill)
				tx.canvas_stroke_rounded_rect(&lv, tr, THUMB_R, 1, tx.color_with_alpha(th.muted, 60))
			} else {
				tx.canvas_fill_rounded_rect(&lv, tr, THUMB_R, tx.color_mix(fill, th.muted, 0.2))
				if p.icons != nil { append(&list, glyph_op(cb, p.icons, tr, glyph(GLYPH_PHOTO), th.muted)) }
			}
		}

		wr := tx.Rect{r.x + view.x, r.y + view.y, r.w, r.h}
		if clipped, visible := tx.rect_intersect(wr, view); visible {
			append(&p.hits, Hit{r = clipped, action = .Select, index = i})
		}
	}

	// Scrollbar in the card's right padding.
	if p.content_h > view.h {
		track := tx.Rect{card.x + card.w - PAD / 2 - 3, view.y + 4, 4, view.h - 8}
		thumb_h := max(28, track.h * view.h / p.content_h)
		range_ := max(1, p.content_h - view.h)
		ty := track.y + (track.h - thumb_h) * p.scroll / range_
		tx.canvas_fill_rounded_rect(&cv, {track.x, ty, track.w, thumb_h}, 2, tx.color_with_alpha(th.muted, 140))
	}

	pm := tx.canvas_to_pixmap(c, cv)
	lpm := tx.canvas_to_pixmap(c, lv)
	ts := tx.text_surface_make(c, xlib.Drawable(lpm))
	for t in list {
		if !t.runs {
			tx.draw_text(&ts, t.font, t.x, t.base, t.s, t.color)
			continue
		}
		x := t.x
		for seg in segments(cb, t.s) {
			tx.draw_text(&ts, seg.font, x, t.base, seg.s, t.color)
			x += tx.text_width(c, seg.font, seg.s)
		}
	}
	tx.text_surface_destroy(&ts)
	gc := xlib.CreateGC(c.dpy, xlib.Drawable(pm), {}, nil)
	xlib.CopyArea(c.dpy, xlib.Drawable(lpm), xlib.Drawable(pm), gc, 0, 0, u32(view.w), u32(view.h), view.x, view.y)
	xlib.FreeGC(c.dpy, gc)
	tx.pixmap_free(c, lpm)
	ts = tx.text_surface_make(c, xlib.Drawable(pm))
	for t in head { tx.draw_text(&ts, t.font, t.x, t.base, t.s, t.color) }
	tx.text_surface_destroy(&ts)
	tx.set_background(c, p.win, pm)
	tx.pixmap_free(c, p.pixmap)
	p.pixmap = pm
}
