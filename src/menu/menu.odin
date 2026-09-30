// Package menu: popup menus shared by the window manager (the root menu, the
// window menu, the window list) and the desktop icons.
//
// A menu is a stack of cards (the menu and its open submenus), each an
// override-redirect window painted on the CPU in milk's look, like the bar's
// popups. While a menu is open it grabs the pointer and the keyboard (all
// pointer events arrive on the first card and are hit-tested against every
// card), so nothing else reacts to the clicks meant for it. It owns no event
// loop: the owner forwards every X event to handle_event and reads the chosen
// entry with take_result. Opening a menu closes any other open menu.
//
// Mouse: a press on an entry chooses it on release; press, drag and release
// chooses the entry under the pointer; a click outside closes the menu.
// Keyboard: arrows, Home/End, Enter/Space, Escape, and the first letter of an
// entry.
package menu

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

// One entry. Separators and headers are never chosen; an entry with `items`
// opens a submenu instead of being chosen.
Item :: struct {
	id:        int,    // reported by take_result
	label:     string,
	accel:     string, // right-aligned hint ("Alt+F4")
	icon:      rune,   // Tabler codepoint (the bar's icon font), 0 = none
	checked:   bool,   // a check mark in the icon column
	disabled:  bool,
	separator: bool,
	header:    bool,   // a muted title row
	items:     []Item, // submenu
}

Style :: struct {
	bg, fg, muted, accent, accent_fg, surface, warning: tx.Color,
	font:           string, // fontconfig pattern
	font_px:        i32,
	icon_font_file: string, // "" = no icons
}

// The bar's colours and font (the suite's theme).
style_from_config :: proc(cfg: ^config.Config) -> Style {
	t := &cfg.bar.theme
	return {
		bg = tx.color_from_hex(t.background), fg = tx.color_from_hex(t.foreground), muted = tx.color_from_hex(t.muted),
		accent = tx.color_from_hex(t.accent), accent_fg = tx.color_from_hex(t.accent_foreground),
		surface = tx.color_from_hex(t.surface), warning = tx.color_from_hex(t.warning),
		font = cfg.bar.font, font_px = i32(max(cfg.bar.font_size - 1, 9)), icon_font_file = cfg.bar.icon_font_file,
	}
}

@(private) PAD       :: 6   // card edge → rows
@(private) ROW_H     :: 32
@(private) SEP_H     :: 11
@(private) HEADER_H  :: 28
@(private) RADIUS    :: 12
@(private) MIN_W     :: 170
@(private) MAX_W     :: 440
@(private) ICON_COL  :: 30
@(private) ARROW_COL :: 22
@(private) EDGE      :: 6   // distance kept from the monitor edges
@(private) CLICK_SLOP :: 4  // a release this close to the opening press is part of the click that opened the menu
@(private) CLICK_TIME :: 250 // ms

@(private)
Level :: struct {
	items:  []Item,     // borrowed from Menu.items (deep copy)
	win:    xlib.Window,
	pixmap: xlib.Pixmap,
	rect:   tx.Rect,    // screen coordinates
	rows:   []tx.Rect,  // per item, card coordinates (zero height = scrolled out)
	hover:  int,        // -1 = none
	first:  int,        // first visible item (scrolling)
	scrollable: bool,
}

Menu :: struct {
	c:          ^tx.Connection,
	style:      Style,
	font:       ^tx.Font,
	icon_font:  ^tx.Font,
	font_key:   string, // "pattern|px|file" the fonts were opened with (owned)
	items:      []Item, // deep copy of what was opened (owned)
	levels:     [dynamic]Level,
	open:       bool,
	grabbed:    bool,
	result:     int,
	has_result: bool,
	pressed:    int,  // level*1000+item pressed with the button held, -1 = none
	open_x, open_y: i32,
	open_time:  xlib.Time,
	armed:      bool, // the button that opened the menu was released (or moved away)
}

@(private)
g_current: ^Menu // the open menu, if any

// Open `items` (copied) with the top-left corner near (x, y), screen
// coordinates; kept inside the monitor under that point. `time` is the X
// timestamp of the event that opened it (0 = keyboard): the release of the
// same click does not choose anything.
open :: proc(m: ^Menu, c: ^tx.Connection, style: Style, items: []Item, x, y: i32, time: xlib.Time = 0) -> bool {
	if g_current != nil && g_current != m { close(g_current) }
	close(m)
	if len(items) == 0 { return false }
	m.c = c
	m.style = style
	open_fonts(m)
	if m.font == nil { return false }
	m.items = clone_items(items)
	m.levels = make([dynamic]Level)
	m.result = -1
	m.has_result = false
	m.pressed = -1
	m.open_x, m.open_y = x, y
	m.open_time = time
	m.armed = time == 0
	push_level(m, m.items, {x, y, 0, 0}, false)
	m.open = true
	g_current = m
	if !grab(m) {
		close(m)
		return false
	}
	// Keyboard-opened menus start on their first entry.
	if time == 0 { select_next(m, &m.levels[0], 1) }
	return true
}

is_open :: proc(m: ^Menu) -> bool { return m != nil && m.open }

// The id of the chosen entry, once (after handle_event returned true).
take_result :: proc(m: ^Menu) -> (id: int, ok: bool) {
	if m == nil || !m.has_result { return -1, false }
	m.has_result = false
	return m.result, true
}

// Close every card and drop the grabs (no result).
close :: proc(m: ^Menu) {
	if m == nil { return }
	for len(m.levels) > 0 { pop_level(m) }
	delete(m.levels)
	m.levels = nil
	if m.grabbed && m.c != nil {
		xlib.UngrabPointer(m.c.dpy, xlib.CurrentTime)
		xlib.UngrabKeyboard(m.c.dpy, xlib.CurrentTime)
		tx.flush(m.c)
	}
	m.grabbed = false
	destroy_items(m.items)
	m.items = nil
	m.open = false
	if g_current == m { g_current = nil }
}

// Close the menu and free its fonts.
destroy :: proc(m: ^Menu) {
	if m == nil { return }
	close(m)
	if m.c != nil {
		tx.font_close(m.c, m.font)
		tx.font_close(m.c, m.icon_font)
	}
	m.font, m.icon_font = nil, nil
	delete(m.font_key)
	m.font_key = ""
}

// Handle one event; true when it was for the menu (a result may be ready).
handle_event :: proc(m: ^Menu, ev: ^xlib.XEvent) -> bool {
	if m == nil || !m.open { return false }
	#partial switch ev.type {
	case .MotionNotify:
		if !own_window(m, ev.xmotion.window) { return false }
		on_motion(m, ev.xmotion.x_root, ev.xmotion.y_root)
		return true
	case .ButtonPress:
		if !own_window(m, ev.xbutton.window) { return false }
		on_press(m, &ev.xbutton)
		return true
	case .ButtonRelease:
		if !own_window(m, ev.xbutton.window) { return false }
		on_release(m, &ev.xbutton)
		return true
	case .KeyPress:
		if !own_window(m, ev.xkey.window) { return false }
		on_key(m, &ev.xkey)
		return true
	case .KeyRelease:
		return own_window(m, ev.xkey.window)
	case .Expose:
		return own_window(m, ev.xexpose.window)
	}
	return false
}

// ---------------------------------------------------------------------------
// Items
// ---------------------------------------------------------------------------
@(private)
clone_items :: proc(items: []Item) -> []Item {
	out := make([]Item, len(items))
	for it, i in items {
		out[i] = it
		out[i].label = strings.clone(it.label)
		out[i].accel = strings.clone(it.accel)
		out[i].items = clone_items(it.items) if len(it.items) > 0 else nil
	}
	return out
}

@(private)
destroy_items :: proc(items: []Item) {
	for it in items {
		delete(it.label)
		delete(it.accel)
		destroy_items(it.items)
	}
	delete(items)
}

@(private)
selectable :: proc(it: ^Item) -> bool { return !it.separator && !it.header && !it.disabled }

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------
@(private)
open_fonts :: proc(m: ^Menu) {
	key := strings.concatenate({m.style.font, "|", tx_itoa(int(m.style.font_px)), "|", m.style.icon_font_file}, context.temp_allocator)
	if m.font != nil && key == m.font_key { return }
	tx.font_close(m.c, m.font)
	tx.font_close(m.c, m.icon_font)
	m.font, m.icon_font = nil, nil
	ok: bool
	m.font, ok = tx.font_open(m.c, m.style.font, m.style.font_px)
	if !ok { m.font, _ = tx.font_open(m.c, "sans", m.style.font_px) }
	if m.style.icon_font_file != "" {
		m.icon_font, _ = tx.font_open_file(m.c, m.style.icon_font_file, m.style.font_px + 3)
	}
	delete(m.font_key)
	m.font_key = strings.clone(key)
}

@(private)
item_height :: proc(it: ^Item) -> i32 {
	if it.separator { return SEP_H }
	if it.header { return HEADER_H }
	return ROW_H
}

@(private)
has_icons :: proc(items: []Item) -> bool {
	for &it in items {
		if (it.icon != 0 || it.checked) && !it.separator && !it.header { return true }
	}
	return false
}

// Create the card for `items` next to `anchor` (a point for the first card,
// the parent row for a submenu).
@(private)
push_level :: proc(m: ^Menu, items: []Item, anchor: tx.Rect, submenu: bool) {
	c := m.c
	icons := has_icons(items)
	label_w: i32 = 0
	accel_w: i32 = 0
	arrows := false
	total_h: i32 = 2 * PAD
	for &it in items {
		total_h += item_height(&it)
		if it.separator { continue }
		label_w = max(label_w, tx.text_width(c, m.font, it.label))
		if it.accel != "" { accel_w = max(accel_w, tx.text_width(c, m.font, it.accel)) }
		if len(it.items) > 0 { arrows = true }
	}
	w := 2 * PAD + 14 + label_w + 14
	if icons { w += ICON_COL }
	if accel_w > 0 { w += accel_w + 24 }
	if arrows { w += ARROW_COL }
	w = clamp(w, MIN_W, MAX_W)

	mon := monitor_at(c, anchor.x, anchor.y)
	h := total_h
	scrollable := false
	if h > mon.h - 2 * EDGE {
		h = mon.h - 2 * EDGE
		scrollable = true
	}
	x, y: i32
	if !submenu {
		x = anchor.x
		y = anchor.y
		if x + w > mon.x + mon.w - EDGE { x = max(mon.x + EDGE, anchor.x - w) }
		if y + h > mon.y + mon.h - EDGE { y = max(mon.y + EDGE, anchor.y - h) }
	} else {
		x = anchor.x + anchor.w - 4
		if x + w > mon.x + mon.w - EDGE { x = max(mon.x + EDGE, anchor.x - w + 4) }
		y = anchor.y - PAD
		if y + h > mon.y + mon.h - EDGE { y = max(mon.y + EDGE, mon.y + mon.h - EDGE - h) }
	}
	x = clamp(x, mon.x + EDGE, max(mon.x + EDGE, mon.x + mon.w - EDGE - w))

	lv := Level{items = items, rect = {x, y, w, h}, hover = -1, scrollable = scrollable}
	lv.rows = make([]tx.Rect, len(items))
	lv.win = tx.create_overlay(c, lv.rect, {.ButtonPress, .ButtonRelease, .PointerMotion, .KeyPress, .KeyRelease},
	                           "_NET_WM_WINDOW_TYPE_POPUP_MENU", "milk menu")
	tx.shape_rounded(c, lv.win, w, h, RADIUS)
	append(&m.levels, lv)
	paint(m, len(m.levels) - 1)
	tx.map_window(c, lv.win)
	tx.raise_window(c, lv.win)
	tx.flush(c)
}

@(private)
pop_level :: proc(m: ^Menu) {
	n := len(m.levels)
	if n == 0 { return }
	lv := &m.levels[n - 1]
	if lv.win != 0 {
		tx.unmap_window(m.c, lv.win)
		tx.destroy_window(m.c, lv.win)
	}
	tx.pixmap_free(m.c, lv.pixmap)
	delete(lv.rows)
	pop(&m.levels)
}

// Keep only the first `n` cards.
@(private)
truncate_levels :: proc(m: ^Menu, n: int) {
	for len(m.levels) > n { pop_level(m) }
}

@(private)
monitor_at :: proc(c: ^tx.Connection, x, y: i32) -> tx.Rect {
	for mon in tx.monitors(c) {
		if tx.rect_contains(mon.rect, x, y) { return mon.rect }
	}
	return tx.screen_rect(c)
}

@(private)
grab :: proc(m: ^Menu) -> bool {
	c := m.c
	win := m.levels[0].win
	mask := xlib.EventMask{.ButtonPress, .ButtonRelease, .PointerMotion}
	for attempt in 0 ..< 20 {
		if xlib.GrabPointer(c.dpy, win, false, mask, .GrabModeAsync, .GrabModeAsync, 0, 0, xlib.CurrentTime) == 0 {
			m.grabbed = true
			break
		}
		if attempt < 19 { sleep_ms(10) }
	}
	if !m.grabbed { return false }
	for attempt in 0 ..< 20 {
		if xlib.GrabKeyboard(c.dpy, win, false, .GrabModeAsync, .GrabModeAsync, xlib.CurrentTime) == 0 { break }
		if attempt < 19 { sleep_ms(10) }
	}
	return true
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------
@(private)
paint :: proc(m: ^Menu, index: int) {
	c := m.c
	st := &m.style
	lv := &m.levels[index]
	w, h := lv.rect.w, lv.rect.h
	cv := tx.canvas_make(w, h, context.temp_allocator)
	tx.canvas_fill(&cv, st.bg)
	tx.canvas_stroke_rounded_rect(&cv, {0, 0, w, h}, RADIUS, 1, tx.color_mix(st.bg, st.muted, 0.45))
	icons := has_icons(lv.items)
	for &r in lv.rows { r = {} }
	y := i32(PAD)
	limit := h - PAD
	if lv.scrollable && lv.first > 0 { y += 10 } // room for the "more above" hint
	Pending_Text :: struct { font: ^tx.Font, x, y, h: i32, s: string, color: tx.Color }
	texts := make([dynamic]Pending_Text, context.temp_allocator)
	for i := lv.first; i < len(lv.items); i += 1 {
		it := &lv.items[i]
		ih := item_height(it)
		if y + ih > limit - (lv.scrollable ? 10 : 0) && i > lv.first { break }
		row := tx.Rect{PAD, y, w - 2 * PAD, ih}
		lv.rows[i] = row
		y += ih
		if it.separator {
			tx.canvas_fill_rect(&cv, {row.x + 8, row.y + ih / 2, row.w - 16, 1}, tx.color_mix(st.bg, st.muted, 0.35))
			continue
		}
		if it.header {
			append(&texts, Pending_Text{m.font, row.x + 10, row.y, row.h, tx.text_ellipsize(c, m.font, it.label, row.w - 20), st.muted})
			continue
		}
		hot := i == lv.hover && !it.disabled
		if hot { tx.canvas_fill_rounded_rect(&cv, row, 8, st.accent) }
		fg := hot ? st.accent_fg : (it.disabled ? tx.color_mix(st.fg, st.bg, 0.55) : st.fg)
		sub := hot ? st.accent_fg : st.muted
		x := row.x + 10
		if icons {
			if it.checked && it.icon == 0 {
				cx, cy := f32(x + 9), f32(row.y + ih / 2)
				tx.canvas_stroke_line(&cv, cx - 5, cy, cx - 1.5, cy + 4, 2, fg)
				tx.canvas_stroke_line(&cv, cx - 1.5, cy + 4, cx + 5.5, cy - 4, 2, fg)
			} else if it.icon != 0 && m.icon_font != nil {
				buf, n := utf8.encode_rune(it.icon)
				glyph := strings.clone(string(buf[:n]), context.temp_allocator)
				gw := tx.text_width(c, m.icon_font, glyph)
				append(&texts, Pending_Text{m.icon_font, x + (20 - gw) / 2, row.y, row.h, glyph, it.checked ? (hot ? st.accent_fg : st.accent) : fg})
			}
			x += ICON_COL
		}
		right := row.x + row.w - 10
		if len(it.items) > 0 {
			ax, ay := f32(right - 5), f32(row.y + ih / 2)
			tx.canvas_stroke_line(&cv, ax - 3, ay - 5, ax + 2, ay, 1.6, sub)
			tx.canvas_stroke_line(&cv, ax + 2, ay, ax - 3, ay + 5, 1.6, sub)
			right -= ARROW_COL
		}
		if it.accel != "" {
			aw := tx.text_width(c, m.font, it.accel)
			append(&texts, Pending_Text{m.font, right - aw, row.y, row.h, it.accel, sub})
			right -= aw + 16
		}
		append(&texts, Pending_Text{m.font, x, row.y, row.h, tx.text_ellipsize(c, m.font, it.label, right - x), fg})
	}
	if lv.scrollable {
		mid := f32(w) / 2
		if lv.first > 0 {
			tx.canvas_stroke_line(&cv, mid - 5, 13, mid, 8, 1.6, st.muted)
			tx.canvas_stroke_line(&cv, mid, 8, mid + 5, 13, 1.6, st.muted)
		}
		last_visible := -1
		for r, i in lv.rows { if r.h > 0 { last_visible = i } }
		if last_visible < len(lv.items) - 1 {
			tx.canvas_stroke_line(&cv, mid - 5, f32(h) - 13, mid, f32(h) - 8, 1.6, st.muted)
			tx.canvas_stroke_line(&cv, mid, f32(h) - 8, mid + 5, f32(h) - 13, 1.6, st.muted)
		}
	}
	pm := tx.canvas_to_pixmap(c, cv)
	ts := tx.text_surface_make(c, xlib.Drawable(pm))
	for t in texts { tx.draw_text_centered_v(&ts, t.font, t.x, t.y, t.h, t.s, t.color) }
	tx.text_surface_destroy(&ts)
	tx.set_background(c, lv.win, pm)
	tx.pixmap_free(c, lv.pixmap)
	lv.pixmap = pm
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------
@(private)
own_window :: proc(m: ^Menu, win: xlib.Window) -> bool {
	for &lv in m.levels {
		if lv.win == win { return true }
	}
	return false
}

// The card and item under a screen point (-1 when none).
@(private)
hit :: proc(m: ^Menu, x, y: i32) -> (level, item: int) {
	for i := len(m.levels) - 1; i >= 0; i -= 1 {
		lv := &m.levels[i]
		if !tx.rect_contains(lv.rect, x, y) { continue }
		lx, ly := x - lv.rect.x, y - lv.rect.y
		for r, j in lv.rows {
			if r.h > 0 && tx.rect_contains(r, lx, ly) { return i, j }
		}
		return i, -1
	}
	return -1, -1
}

@(private)
set_hover :: proc(m: ^Menu, level, item: int) {
	lv := &m.levels[level]
	if lv.hover == item { return }
	lv.hover = item
	paint(m, level)
}

@(private)
on_motion :: proc(m: ^Menu, x, y: i32) {
	if !m.armed && (abs(x - m.open_x) > CLICK_SLOP || abs(y - m.open_y) > CLICK_SLOP) { m.armed = true }
	level, item := hit(m, x, y)
	if level < 0 { return }
	lv := &m.levels[level]
	if item >= 0 && !selectable(&lv.items[item]) { item = -1 }
	if item == lv.hover && item >= 0 { return }
	if item < 0 {
		// Between entries or on a separator: keep an open submenu's parent lit.
		if level == len(m.levels) - 1 { set_hover(m, level, -1) }
		return
	}
	truncate_levels(m, level + 1)
	set_hover(m, level, item)
	it := &m.levels[level].items[item]
	if len(it.items) > 0 { open_submenu(m, level, item) }
	tx.flush(m.c)
}

@(private)
open_submenu :: proc(m: ^Menu, level, item: int) {
	lv := &m.levels[level]
	row := lv.rows[item]
	anchor := tx.Rect{lv.rect.x + row.x, lv.rect.y + row.y, row.w, row.h}
	push_level(m, lv.items[item].items, anchor, true)
}

@(private)
on_press :: proc(m: ^Menu, be: ^xlib.XButtonEvent) {
	level, item := hit(m, be.x_root, be.y_root)
	if level < 0 {
		close(m)
		return
	}
	if be.button == .Button4 || be.button == .Button5 {
		scroll(m, level, be.button == .Button4 ? -1 : 1)
		return
	}
	m.armed = true
	m.pressed = item >= 0 ? level * 1000 + item : -1
}

@(private)
on_release :: proc(m: ^Menu, be: ^xlib.XButtonEvent) {
	if be.button == .Button4 || be.button == .Button5 { return }
	level, item := hit(m, be.x_root, be.y_root)
	quick := !m.armed && u32(be.time) - u32(m.open_time) < CLICK_TIME
	m.armed = true
	if quick || level < 0 || item < 0 { return }
	activate(m, level, item)
}

@(private)
activate :: proc(m: ^Menu, level, item: int) {
	it := &m.levels[level].items[item]
	if !selectable(it) { return }
	if len(it.items) > 0 {
		if len(m.levels) == level + 1 { open_submenu(m, level, item) }
		return
	}
	id := it.id
	close(m)
	m.result = id
	m.has_result = true
}

@(private)
scroll :: proc(m: ^Menu, level, dir: int) {
	lv := &m.levels[level]
	if !lv.scrollable { return }
	last_visible := -1
	for r, i in lv.rows { if r.h > 0 { last_visible = i } }
	if dir > 0 && last_visible >= len(lv.items) - 1 { return }
	lv.first = clamp(lv.first + dir, 0, len(lv.items) - 1)
	truncate_levels(m, level + 1)
	paint(m, level)
	tx.flush(m.c)
}

// Move the keyboard selection of a card by `dir`, skipping what cannot be chosen.
@(private)
select_next :: proc(m: ^Menu, level: ^Level, dir: int) {
	lv := level
	n := len(lv.items)
	if n == 0 { return }
	i := lv.hover
	for _ in 0 ..< n {
		i += dir
		if i < 0 { i = n - 1 }
		if i >= n { i = 0 }
		if selectable(&lv.items[i]) { break }
	}
	if !selectable(&lv.items[i]) { return }
	index := level_index(m, lv)
	truncate_levels(m, index + 1)
	lv = &m.levels[index]
	lv.hover = i
	ensure_visible(m, index, i)
	paint(m, index)
	tx.flush(m.c)
}

@(private)
level_index :: proc(m: ^Menu, lv: ^Level) -> int {
	for &l, i in m.levels {
		if &l == lv { return i }
	}
	return 0
}

@(private)
ensure_visible :: proc(m: ^Menu, level, item: int) {
	lv := &m.levels[level]
	if !lv.scrollable { return }
	if item < lv.first {
		lv.first = item
		return
	}
	for _ in 0 ..< len(lv.items) {
		paint(m, level)
		if lv.rows[item].h > 0 { return }
		lv.first += 1
	}
}

@(private)
on_key :: proc(m: ^Menu, ke: ^xlib.XKeyEvent) {
	if len(m.levels) == 0 { return }
	sym := xlib.LookupKeysym(ke, 0)
	top := len(m.levels) - 1
	lv := &m.levels[top]
	#partial switch sym {
	case .XK_Escape:
		if top == 0 { close(m) } else { truncate_levels(m, top) }
	case .XK_Left:
		if top > 0 { truncate_levels(m, top) }
	case .XK_Down, .XK_Tab:
		select_next(m, lv, 1)
	case .XK_Up, .XK_ISO_Left_Tab:
		select_next(m, lv, -1)
	case .XK_Home:
		lv.hover = -1
		select_next(m, lv, 1)
	case .XK_End:
		lv.hover = len(lv.items)
		select_next(m, lv, -1)
	case .XK_Right:
		if lv.hover >= 0 && len(lv.items[lv.hover].items) > 0 {
			open_submenu(m, top, lv.hover)
			select_next(m, &m.levels[top + 1], 1)
		}
	case .XK_Return, .XK_KP_Enter, .XK_space:
		if lv.hover >= 0 {
			if len(lv.items[lv.hover].items) > 0 {
				open_submenu(m, top, lv.hover)
				select_next(m, &m.levels[top + 1], 1)
			} else {
				activate(m, top, lv.hover)
			}
		}
	case:
		// First letter: the next entry whose label starts with it.
		buf: [8]u8
		n := xlib.LookupString(ke, &buf[0], len(buf), nil, nil)
		if n <= 0 { return }
		r, _ := utf8.decode_rune(buf[:n])
		want := unicode.to_lower(r)
		count := len(lv.items)
		for step in 1 ..= count {
			i := (max(lv.hover, -1) + step) %% count
			it := &lv.items[i]
			if !selectable(it) { continue }
			first, _ := utf8.decode_rune_in_string(it.label)
			if unicode.to_lower(first) == want {
				lv.hover = i - 1
				select_next(m, lv, 1)
				return
			}
		}
	}
	if m.open { tx.flush(m.c) }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
foreign import libc_menu "system:c"
@(default_calling_convention = "c")
foreign libc_menu {
	@(link_name = "usleep") c_usleep :: proc(usec: u32) -> i32 ---
}

@(private)
sleep_ms :: proc(ms: int) { c_usleep(u32(ms * 1000)) }

@(private)
tx_itoa :: proc(v: int) -> string {
	buf: [24]u8
	i := len(buf)
	n := v < 0 ? -v : v
	for {
		i -= 1
		buf[i] = u8('0' + n % 10)
		n /= 10
		if n == 0 { break }
	}
	if v < 0 {
		i -= 1
		buf[i] = '-'
	}
	return strings.clone(string(buf[i:]), context.temp_allocator)
}
