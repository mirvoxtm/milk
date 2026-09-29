// Desktop icons for the active area ("layer" shortcut mode).
//
// Neither dwm nor openbox draw desktop icons, so milk does: every shortcut
// becomes a small override-redirect window (ignored by the window manager)
// kept at the bottom of the stacking order. Its background is a copy of the
// wallpaper pixmap under the cell plus the icon and the label, so the cells
// blend into the wallpaper without a compositor, and the X server repaints
// them by itself (no Expose handling).
package desktop

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import xlib "vendor:x11/xlib"
import tx "../tx"

@(private)
CELL_EVENT_MASK :: xlib.EventMask{.ButtonPress, .ButtonRelease}
@(private)
DOUBLE_CLICK_MS :: 450
@(private)
CELL_FALLBACK_BG :: tx.Color{18, 20, 26, 255}
@(private)
LABEL_COLOR :: tx.Color{255, 255, 255, 255}

Cell :: struct {
	entry:      int, // index into Layer.entries
	rect:       tx.Rect,
	window:     xlib.Window,
	pixmap:     xlib.Pixmap, // current background (freed when replaced)
	background: tx.Canvas,   // wallpaper crop under the cell
	selected:   bool,
	lines:      [2]string,   // wrapped label (owned)
	nlines:     int,
}

Layer :: struct {
	entries:     [dynamic]Shortcut, // shortcuts of the active area (owned)
	cells:       [dynamic]Cell,     // the ones that fit on screen
	font:        ^tx.Font,
	glyph_font:  ^tx.Font,
	line_h:      i32,
	pad:         i32,
	icon_size:   i32,
	cell_w:      i32,
	cell_h:      i32,
	area:        tx.Rect, // usable area of the current layout
	bar_windows: [dynamic]xlib.Window, // panels subtracted from the area (watched)
	last_click_window: xlib.Window,
	last_click_time:   xlib.Time,
	relower_window_start: f64,
	relower_count:        int,
	relower_paused_until: f64,
	warned_overflow:      bool,
}

@(private)
Bar_Info :: struct {
	win:  xlib.Window,
	rect: tx.Rect,
}

layer_init :: proc(d: ^Daemon) {
	l := &d.layer
	l.entries = make([dynamic]Shortcut)
	l.cells = make([dynamic]Cell)
	l.bar_windows = make([dynamic]xlib.Window)
	layer_open_fonts(d)
}

// Fonts and metrics follow the configuration (called again on reload).
layer_reconfigure :: proc(d: ^Daemon) {
	layer_clear(d)
	layer_close_fonts(d)
	layer_open_fonts(d)
	d.layer.warned_overflow = false
}

layer_destroy :: proc(d: ^Daemon) {
	layer_clear(d)
	layer_close_fonts(d)
	delete(d.layer.entries)
	delete(d.layer.cells)
	delete(d.layer.bar_windows)
}

@(private)
layer_open_fonts :: proc(d: ^Daemon) {
	l := &d.layer
	opts := &d.cfg.linux.shortcuts
	px := points_to_pixels(opts.font_size)
	ok: bool
	l.font, ok = tx.font_open(d.c, opts.font, px)
	if !ok { l.font, _ = tx.font_open(d.c, "sans", px) }
	l.icon_size = i32(opts.icon_size)
	l.glyph_font, _ = tx.font_open(d.c, "sans:bold", max(8, l.icon_size / 2))
	l.pad = 6
	l.cell_w = max(80, l.icon_size * 2)
	text_h: i32 = px + 4
	if l.font != nil { text_h = l.font.ascent + l.font.descent }
	l.line_h = text_h + 1
	l.cell_h = l.pad + l.icon_size + 4 + 2 * l.line_h + l.pad
}

@(private)
layer_close_fonts :: proc(d: ^Daemon) {
	tx.font_close(d.c, d.layer.font)
	tx.font_close(d.c, d.layer.glyph_font)
	d.layer.font = nil
	d.layer.glyph_font = nil
}

// Show `entries` (ownership taken) as the icons of the active area.
layer_show :: proc(d: ^Daemon, entries: ^[dynamic]Shortcut) {
	old := d.layer.entries
	d.layer.entries = entries^
	entries^ = nil
	layer_build(d)
	for &s in old { shortcut_destroy(&s) }
	delete(old)
}

// Destroy every cell and forget the entries.
layer_clear :: proc(d: ^Daemon) {
	l := &d.layer
	for &cell in l.cells { cell_destroy(d, &cell) }
	clear(&l.cells)
	for &s in l.entries { shortcut_destroy(&s) }
	clear(&l.entries)
	l.last_click_window = 0
	l.area = {}
}

// Lay the current entries out again (work area or screen size changed).
layer_relayout :: proc(d: ^Daemon) {
	if len(d.layer.entries) == 0 && len(d.layer.cells) == 0 { return }
	layer_build(d)
}

// Re-check the usable area; relayout when a bar appeared, moved or vanished.
layer_check_area :: proc(d: ^Daemon) {
	if d.cfg.linux.shortcuts.mode != "layer" || len(d.layer.entries) == 0 { return }
	area := usable_area(d)
	if area != d.layer.area {
		log.debugf("Desktop area changed from %v to %v; laying the icons out again", d.layer.area, area)
		layer_build(d)
	}
}

// (Re)create the cell windows for the current entries.
@(private)
layer_build :: proc(d: ^Daemon) {
	l := &d.layer
	c := d.c
	area := usable_area(d)
	rects := layout(d, len(l.entries), area)
	if len(rects) < len(l.entries) {
		if !l.warned_overflow {
			log.warnf("Only %d of %d shortcuts fit on the desktop", len(rects), len(l.entries))
			l.warned_overflow = true
		}
	}
	source, has_pixmap := wallpaper_drawable(d)
	old := l.cells
	l.cells = make([dynamic]Cell, 0, len(rects))
	if !has_pixmap {
		// Without a wallpaper pixmap the screen itself is copied: remove the old cells first.
		for &cell in old { cell_destroy(d, &cell) }
		clear(&old)
		tx.sync(c)
	}
	for rect, i in rects {
		s := &l.entries[i]
		cell := Cell{entry = i, rect = rect}
		lines, n := wrap_label(d, s.name, l.cell_w - 8)
		for j in 0 ..< n { cell.lines[j] = strings.clone(lines[j]) }
		cell.nlines = n
		cell.background = grab_background(d, source, rect)
		cell.window = tx.create_overlay(c, rect, CELL_EVENT_MASK, "_NET_WM_WINDOW_TYPE_DESKTOP", fmt.tprintf("milk: %s", s.name))
		// Lowered before it is mapped: it never shows up above other windows.
		tx.lower_window(c, cell.window)
		append(&l.cells, cell)
		cell_paint(d, &l.cells[len(l.cells) - 1])
		tx.map_window(c, cell.window)
	}
	// The new cells sit under the old ones; removing these reveals them without a gap.
	for &cell in old { cell_destroy(d, &cell) }
	delete(old)
	l.area = area
	l.last_click_window = 0
	tx.flush(c)
	log.debugf("Desktop layer: %d shortcuts in %v", len(l.cells), area)
}

// Re-copy the wallpaper behind every cell (the root pixmap was replaced).
layer_refresh_backgrounds :: proc(d: ^Daemon) {
	l := &d.layer
	if len(l.cells) == 0 { return }
	source, has_pixmap := wallpaper_drawable(d)
	if !has_pixmap {
		// Copying the screen would copy the cells themselves: take them away meanwhile.
		for &cell in l.cells { tx.unmap_window(d.c, cell.window) }
		tx.sync(d.c)
	}
	for &cell in l.cells {
		tx.canvas_destroy(&cell.background)
		cell.background = grab_background(d, source, cell.rect)
		cell_paint(d, &cell)
		if !has_pixmap { tx.map_window(d.c, cell.window) }
	}
	tx.flush(d.c)
}

// Put every cell back at the bottom of the stack. A program that keeps
// lowering its own windows would fight us forever; back off if that happens.
layer_relower :: proc(d: ^Daemon) {
	l := &d.layer
	if len(l.cells) == 0 { return }
	now := tx.now()
	if now < l.relower_paused_until { return }
	if now - l.relower_window_start > 2.0 {
		l.relower_window_start = now
		l.relower_count = 0
	}
	l.relower_count += 1
	if l.relower_count > 40 {
		l.relower_paused_until = now + 10
		log.warn("Another program keeps lowering its windows below the desktop icons; not re-lowering for 10 s")
		return
	}
	for &cell in l.cells { tx.lower_window(d.c, cell.window) }
	tx.flush(d.c)
}

// Index of the cell owning `win`, or -1.
layer_cell_index :: proc(d: ^Daemon, win: xlib.Window) -> int {
	if win == 0 { return -1 }
	for &cell, i in d.layer.cells {
		if cell.window == win { return i }
	}
	return -1
}

// Selection on the first click, launch on the second one (or on the first
// click with singleClick).
layer_on_button :: proc(d: ^Daemon, index: int, be: ^xlib.XButtonEvent) {
	l := &d.layer
	if be.button != .Button1 || index < 0 || index >= len(l.cells) { return }
	cell := &l.cells[index]
	entry := cell.entry
	if d.cfg.linux.shortcuts.single_click {
		layer_select(d, -1)
		launch(d, &l.entries[entry])
		return
	}
	elapsed := u32(be.time) - u32(l.last_click_time) // X time wraps around
	if l.last_click_window == cell.window && elapsed < DOUBLE_CLICK_MS {
		l.last_click_window = 0
		layer_select(d, -1)
		launch(d, &l.entries[entry])
		return
	}
	l.last_click_window = cell.window
	l.last_click_time = be.time
	layer_select(d, index)
}

// Highlight cell `index` only (-1 clears the selection).
layer_select :: proc(d: ^Daemon, index: int) {
	changed := false
	for &cell, i in d.layer.cells {
		wanted := i == index
		if cell.selected == wanted { continue }
		cell.selected = wanted
		cell_paint(d, &cell)
		changed = true
	}
	if changed { tx.flush(d.c) }
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

// The shortcut monitor minus panels: _NET_WORKAREA when published, then any
// dock/override-redirect strip along its edges (our own windows excluded).
@(private)
usable_area :: proc(d: ^Daemon) -> tx.Rect {
	c := d.c
	mon := tx.monitor_rect(c, d.cfg.linux.shortcuts.monitor)
	area := mon
	if wa, ok := tx.workarea(c, max(d.area - 1, 0)); ok {
		if r, inside := tx.rect_intersect(area, wa); inside { area = r }
	}
	clear(&d.layer.bar_windows)
	for b in find_bars(d, mon, window_ids(d)) {
		append(&d.layer.bar_windows, b.win)
		area = subtract_bar(area, b.rect)
	}
	if area.w <= 0 || area.h <= 0 { return mon }
	return area
}

// Panels along the monitor's edges (tx.bars with the window ids kept, so
// that their disappearance can be noticed).
@(private)
find_bars :: proc(d: ^Daemon, monitor: tx.Rect, exclude: []xlib.Window) -> []Bar_Info {
	c := d.c
	found := make([dynamic]Bar_Info, context.temp_allocator)
	screen := tx.screen_rect(c)
	for child in tx.root_children(c) {
		if slice.contains(exclude, child) { continue }
		attrs: xlib.XWindowAttributes
		if xlib.GetWindowAttributes(c.dpy, child, &attrs) == 0 { continue }
		if attrs.map_state != .IsViewable { continue }
		strut := tx.get_cardinals(c, child, "_NET_WM_STRUT_PARTIAL")
		if len(strut) < 4 { strut = tx.get_cardinals(c, child, "_NET_WM_STRUT") }
		if len(strut) >= 4 {
			left, right, top, bottom := i32(strut[0]), i32(strut[1]), i32(strut[2]), i32(strut[3])
			if top > 0 { append(&found, Bar_Info{child, {0, 0, screen.w, top}}) }
			if bottom > 0 { append(&found, Bar_Info{child, {0, screen.h - bottom, screen.w, bottom}}) }
			if left > 0 { append(&found, Bar_Info{child, {0, 0, left, screen.h}}) }
			if right > 0 { append(&found, Bar_Info{child, {screen.w - right, 0, right, screen.h}}) }
			continue
		}
		if !attrs.override_redirect { continue }
		at_top := abs(attrs.y - monitor.y) <= 2
		at_bottom := abs((attrs.y + attrs.height) - (monitor.y + monitor.h)) <= 2
		if attrs.width >= monitor.w * 6 / 10 && attrs.height <= 64 && (at_top || at_bottom) {
			append(&found, Bar_Info{child, {attrs.x, attrs.y, attrs.width, attrs.height}})
		}
	}
	return found[:]
}

// Remove a panel strip from the area (clamped, so the order of the panels
// does not matter).
@(private)
subtract_bar :: proc(r: tx.Rect, b: tx.Rect) -> tx.Rect {
	out := r
	if _, overlaps := tx.rect_intersect(r, b); !overlaps { return out }
	if b.y <= r.y + 2 && b.h < r.h / 2 {
		shift := max(0, (b.y + b.h) - r.y)
		out.y += shift
		out.h -= shift
	} else if b.y + b.h >= r.y + r.h - 2 && b.h < r.h / 2 {
		out.h -= max(0, (r.y + r.h) - b.y)
	} else if b.x <= r.x + 2 && b.w < r.w / 2 {
		shift := max(0, (b.x + b.w) - r.x)
		out.x += shift
		out.w -= shift
	} else if b.x + b.w >= r.x + r.w - 2 && b.w < r.w / 2 {
		out.w -= max(0, (r.x + r.w) - b.x)
	}
	return out
}

// Column-major grid from the top-left corner of the area, inside the margins.
@(private)
layout :: proc(d: ^Daemon, count: int, area: tx.Rect) -> []tx.Rect {
	l := &d.layer
	m := d.cfg.linux.shortcuts.margins // top, right, bottom, left
	x0 := area.x + i32(m[3])
	y0 := area.y + i32(m[0])
	avail_w := area.w - i32(m[3]) - i32(m[1])
	avail_h := area.h - i32(m[0]) - i32(m[2])
	rows := max(1, int(avail_h / l.cell_h))
	cols := max(1, int(avail_w / l.cell_w))
	rects := make([dynamic]tx.Rect, 0, count, context.temp_allocator)
	for i in 0 ..< count {
		col, row := i / rows, i % rows
		if col >= cols { break }
		append(&rects, tx.Rect{x0 + i32(col) * l.cell_w, y0 + i32(row) * l.cell_h, l.cell_w, l.cell_h})
	}
	return rects[:]
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

// Where the wallpaper can be copied from: feh's root pixmap, else the screen.
@(private)
wallpaper_drawable :: proc(d: ^Daemon) -> (xlib.Drawable, bool) {
	if pm, ok := tx.root_pixmap(d.c); ok { return xlib.Drawable(pm), true }
	return xlib.Drawable(d.c.root), false
}

@(private)
grab_background :: proc(d: ^Daemon, source: xlib.Drawable, rect: tx.Rect) -> tx.Canvas {
	cv, ok := tx.canvas_grab(d.c, source, rect, d.allocator)
	if !ok {
		cv = tx.canvas_make(rect.w, rect.h, d.allocator)
		tx.canvas_fill(&cv, CELL_FALLBACK_BG)
	}
	return cv
}

@(private)
cell_paint :: proc(d: ^Daemon, cell: ^Cell) {
	l := &d.layer
	c := d.c
	s := &l.entries[cell.entry]
	w, h := cell.rect.w, cell.rect.h
	cv := tx.canvas_clone(cell.background)
	defer tx.canvas_destroy(&cv)
	if cell.selected {
		tx.canvas_fill_rounded_rect(&cv, {2, 2, w - 4, h - 4}, 8, tx.rgba(255, 255, 255, 56))
		tx.canvas_stroke_rounded_rect(&cv, {2, 2, w - 4, h - 4}, 8, 1, tx.rgba(255, 255, 255, 120))
	}
	icon_x := (w - l.icon_size) / 2
	icon_y := l.pad
	icon := icon_for(&d.icons, s) // valid until the next lookup: used right away
	if icon != nil {
		tx.canvas_blit_image(&cv, icon^, icon_x, icon_y)
	} else {
		square := tx.Rect{icon_x + 1, icon_y + 1, l.icon_size - 2, l.icon_size - 2}
		radius := f32(max(4, l.icon_size / 5))
		tx.canvas_fill_rounded_rect(&cv, square, radius, glyph_color(s.name))
		tx.canvas_stroke_rounded_rect(&cv, square, radius, 1, tx.rgba(255, 255, 255, 90))
	}
	pm := tx.canvas_to_pixmap(c, cv)

	ts := tx.text_surface_make(c, xlib.Drawable(pm))
	if icon == nil && l.glyph_font != nil {
		letter := first_letter_upper(s.name)
		ext := tx.text_extents(c, l.glyph_font, letter)
		gx := icon_x + (l.icon_size - i32(ext.width)) / 2 + i32(ext.x)
		gy := icon_y + (l.icon_size - i32(ext.height)) / 2 + i32(ext.y)
		tx.draw_text(&ts, l.glyph_font, gx, gy, letter, LABEL_COLOR)
	}
	if l.font != nil {
		y := l.pad + l.icon_size + 4
		for i in 0 ..< cell.nlines {
			line := cell.lines[i]
			x := (w - tx.text_width(c, l.font, line)) / 2
			draw_outlined(&ts, l.font, x, y + l.font.ascent, line)
			y += l.line_h
		}
	}
	tx.text_surface_destroy(&ts)

	tx.set_background(c, cell.window, pm)
	tx.pixmap_free(c, cell.pixmap)
	cell.pixmap = pm
}

// White text with a dark halo (Xft cannot stroke: dark copies around it).
@(private)
draw_outlined :: proc(ts: ^tx.Text_Surface, font: ^tx.Font, x, baseline: i32, text: string) {
	near := tx.rgba(0, 0, 0, 120)
	far := tx.rgba(0, 0, 0, 55)
	for off in ([][2]i32{{-2, 0}, {2, 0}, {0, -2}, {0, 2}}) {
		tx.draw_text(ts, font, x + off[0], baseline + off[1], text, far)
	}
	for off in ([][2]i32{{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}) {
		tx.draw_text(ts, font, x + off[0], baseline + off[1], text, near)
	}
	tx.draw_text(ts, font, x, baseline, text, LABEL_COLOR)
}

@(private)
cell_destroy :: proc(d: ^Daemon, cell: ^Cell) {
	if cell.window != 0 {
		tx.unmap_window(d.c, cell.window)
		tx.destroy_window(d.c, cell.window)
	}
	tx.pixmap_free(d.c, cell.pixmap)
	tx.canvas_destroy(&cell.background)
	for i in 0 ..< cell.nlines { delete(cell.lines[i]) }
	cell^ = {}
}

// Wrap a label into at most two lines of `max_w` pixels; the second line
// gets an ellipsis when text is left over. Strings live in the temp allocator.
@(private)
wrap_label :: proc(d: ^Daemon, text: string, max_w: i32) -> (lines: [2]string, count: int) {
	c := d.c
	font := d.layer.font
	if font == nil { return }
	width :: proc(c: ^tx.Connection, f: ^tx.Font, s: string) -> i32 { return tx.text_width(c, f, s) }
	out := make([dynamic]string, context.temp_allocator)
	current := ""
	for word in strings.fields(text, context.temp_allocator) {
		candidate := word if current == "" else strings.concatenate({current, " ", word}, context.temp_allocator)
		if width(c, font, candidate) <= max_w {
			current = candidate
			continue
		}
		if current != "" { append(&out, current) }
		current = word
		// A single word wider than the cell is broken between characters.
		for width(c, font, current) > max_w && utf8.rune_count_in_string(current) > 1 {
			cut := 0
			for _, i in current {
				if i > 0 && width(c, font, current[:i]) > max_w { break }
				cut = i
			}
			if cut == 0 { _, cut = utf8.decode_rune_in_string(current) }
			append(&out, current[:cut])
			current = current[cut:]
		}
	}
	if current != "" { append(&out, current) }
	if len(out) > 2 {
		last := out[1]
		for last != "" && width(c, font, strings.concatenate({last, "…"}, context.temp_allocator)) > max_w {
			_, size := utf8.decode_last_rune_in_string(last)
			last = last[:len(last) - size]
		}
		out[1] = strings.concatenate({strings.trim_right_space(last), "…"}, context.temp_allocator)
	}
	count = min(len(out), 2)
	for i in 0 ..< count { lines[i] = out[i] }
	return
}

@(private)
first_letter_upper :: proc(name: string) -> string {
	trimmed := strings.trim_space(name)
	r, _ := utf8.decode_rune_in_string(trimmed)
	if trimmed == "" || r == utf8.RUNE_ERROR { return "?" }
	bytes, n := utf8.encode_rune(unicode.to_upper(r))
	return strings.clone(string(bytes[:n]), context.temp_allocator)
}
