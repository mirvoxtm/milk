// Desktop icons for the active area: its shortcuts ("layer" shortcut mode)
// and, with linux.desktopIcons, the files of the desktop folder.
//
// Neither dwm nor openbox draw desktop icons, so milk does: every icon
// becomes a small override-redirect window (ignored by the window manager)
// kept at the bottom of the stacking order. Its background is a copy of the
// wallpaper pixmap under the cell plus the icon and the label, so the cells
// blend into the wallpaper without a compositor, and the X server repaints
// them by itself (no Expose handling).
//
// Icons sit on a grid, column-major from the top-left corner of the usable
// area, inside the margins. With desktop icons enabled every icon has a
// saved place on that grid (places.odin); otherwise they fill it in order.
// A new list of items is reconciled with the cells on screen: a cell whose
// item did not change is left alone, one whose item moved or changed is
// moved or repainted, so live folder updates never flicker.
package desktop

import "core:fmt"
import "core:hash"
import "core:log"
import "core:math"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import xlib "vendor:x11/xlib"
import tx "../tx"

@(private)
CELL_EVENT_MASK :: xlib.EventMask{.ButtonPress, .ButtonRelease, .Button1Motion, .KeyPress}
@(private)
DOUBLE_CLICK_MS :: 450
@(private)
CELL_FALLBACK_BG :: tx.Color{18, 20, 26, 255}
@(private)
LABEL_COLOR :: tx.Color{255, 255, 255, 255}
// Hidden files and broken links are drawn faded.
@(private)
FADED :: 0.55

Item_Source :: enum u8 {
	Area,   // a shortcut of Common/ or of the area's folder
	Folder, // an entry of the desktop folder (linux.desktopIcons)
}

// One desktop icon. Every string is owned (see item_destroy) except `icon`.
Item :: struct {
	source:   Item_Source,
	name:     string,    // file name: the identity for places, selection and cell reuse
	label:    string,    // what the icon says
	path:     string,
	kind:     File_Kind,
	icon:     string,    // theme icon of a special folder ("folder-documents"), "" = by kind; static
	is_link:  bool,
	hidden:   bool,      // a dot file
	size:     i64,
	mtime:    i64,       // unix seconds
	inode:    u64,
	launcher: bool,      // opening runs `shortcut` (area shortcuts, .desktop/.url files)
	shortcut: Shortcut,
}

item_destroy :: proc(it: ^Item) {
	delete(it.name)
	delete(it.label)
	delete(it.path)
	shortcut_destroy(&it.shortcut)
	it^ = {}
}

items_clear :: proc(items: ^[dynamic]Item) {
	for &it in items { item_destroy(&it) }
	clear(items)
}

@(private)
item_clone :: proc(it: Item) -> Item {
	out := it
	out.name = strings.clone(it.name)
	out.label = strings.clone(it.label)
	out.path = strings.clone(it.path)
	out.shortcut = own_shortcut(it.shortcut, it.shortcut.path, it.shortcut.filename)
	return out
}

// An area shortcut as an item (the shortcut's strings are taken over).
@(private)
item_from_shortcut :: proc(s: Shortcut) -> Item {
	return Item{
		source = .Area, name = strings.clone(s.filename), label = strings.clone(s.name),
		path = strings.clone(s.path), kind = .Generic, launcher = true, shortcut = s,
	}
}

Cell :: struct {
	entry:      int,         // index into Layer.items
	source:     Item_Source, // with `name`: which item the cell shows, across updates
	name:       string,      // owned
	place:      Place,
	rect:       tx.Rect,
	window:     xlib.Window,
	pixmap:     xlib.Pixmap, // current background (freed when replaced)
	background: tx.Canvas,   // wallpaper crop under the cell
	light:      bool,        // that crop is light: dark highlights
	look:       u64,         // what the cell shows (item_look); repainted when it changes
	selected:   bool,
	lines:      [2]string,   // wrapped label (owned)
	nlines:     int,
}

// The icon grid of the current layout.
Grid :: struct {
	x, y:       i32, // top-left corner of cell (0, 0)
	cols, rows: int,
}

Layer :: struct {
	area_items:  [dynamic]Item, // shortcuts of the active area (owned)
	items:       [dynamic]Item, // what is shown: area shortcuts, then folder files (owned copies)
	cells:       [dynamic]Cell, // the items that fit on screen
	grid:        Grid,
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
	pointer:        Pointer, // clicks, drags and the rubber band (selection.odin)
	cursor:         int,     // keyboard anchor (cell index), -1 = none
	pending_select: string,  // a folder file to select once it shows up (owned)
	pending_rename: bool,    // ...and to rename (a folder just created)
}

@(private)
Bar_Info :: struct {
	win:  xlib.Window,
	rect: tx.Rect,
}

layer_init :: proc(d: ^Daemon) {
	l := &d.layer
	l.area_items = make([dynamic]Item)
	l.items = make([dynamic]Item)
	l.cells = make([dynamic]Cell)
	l.bar_windows = make([dynamic]xlib.Window)
	l.cursor = -1
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
	delete(d.layer.area_items)
	delete(d.layer.items)
	delete(d.layer.cells)
	delete(d.layer.bar_windows)
	delete(d.layer.pending_select)
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

// Show `shortcuts` (ownership taken; empty outside the "layer" mode) as the
// area's icons, next to the desktop folder's files. `refresh` re-copies the
// wallpaper behind the cells that stay (it changed with the area).
layer_set_area :: proc(d: ^Daemon, shortcuts: ^[dynamic]Shortcut, refresh: bool) {
	l := &d.layer
	items_clear(&l.area_items)
	for s in shortcuts { append(&l.area_items, item_from_shortcut(s)) }
	delete(shortcuts^)
	shortcuts^ = nil
	layer_refresh(d, refresh)
}

// Rebuild the list of shown items (area shortcuts, then the folder's files)
// and bring the cells in line.
layer_refresh :: proc(d: ^Daemon, refresh: bool) {
	l := &d.layer
	items_clear(&l.items)
	for it in l.area_items { append(&l.items, item_clone(it)) }
	if d.files.enabled {
		for it in d.files.items { append(&l.items, item_clone(it)) }
	}
	if len(l.items) == 0 && len(l.cells) == 0 { return }
	layer_sync(d, refresh)
}

// Destroy every cell and forget the items (the folder's own list stays).
layer_clear :: proc(d: ^Daemon) {
	l := &d.layer
	pointer_cancel(d)
	rename_cancel(d)
	for &cell in l.cells { cell_destroy(d, &cell) }
	clear(&l.cells)
	items_clear(&l.items)
	items_clear(&l.area_items)
	l.last_click_window = 0
	l.cursor = -1
	l.area = {}
}

// Lay the current items out again (work area or screen size changed).
layer_relayout :: proc(d: ^Daemon) {
	if len(d.layer.items) == 0 && len(d.layer.cells) == 0 { return }
	layer_sync(d, true)
}

// Re-check the usable area; relayout when a bar appeared, moved or vanished.
layer_check_area :: proc(d: ^Daemon) {
	if len(d.layer.items) == 0 { return }
	area := usable_area(d)
	if area != d.layer.area {
		log.debugf("Desktop area changed from %v to %v; laying the icons out again", d.layer.area, area)
		layer_sync(d, false)
	}
}

// Is an icon being dragged, a band drawn or a name edited? The cells must
// then stay as they are (rescans wait).
layer_busy :: proc(d: ^Daemon) -> bool {
	return d.layer.pointer.mode != .Idle || d.rename.active
}

@(private)
cell_key :: proc(source: Item_Source, name: string) -> string {
	return fmt.tprintf("%d/%s", int(source), name)
}

// Place the items on the grid and bring the cells in line: cells of items
// that are still shown are kept (moved or repainted only when needed), new
// ones are created under the old ones before those go, so nothing blinks.
// `refresh` re-copies every background (the wallpaper changed).
@(private)
layer_sync :: proc(d: ^Daemon, refresh: bool) {
	l := &d.layer
	c := d.c
	pointer_cancel(d)
	area := usable_area(d)
	l.grid = make_grid(d, area)
	places := place_items(d, l.items[:], l.grid)
	shown := 0
	for p in places { if p.x >= 0 { shown += 1 } }
	if shown < len(l.items) && !l.warned_overflow {
		log.warnf("Only %d of %d icons fit on the desktop", shown, len(l.items))
		l.warned_overflow = true
	}
	cursor_key := ""
	if l.cursor >= 0 && l.cursor < len(l.cells) { cursor_key = cell_key(l.cells[l.cursor].source, l.cells[l.cursor].name) }
	l.cursor = -1

	source, has_pixmap := wallpaper_drawable(d)
	old := l.cells
	l.cells = make([dynamic]Cell, 0, shown)
	if !has_pixmap {
		// Without a wallpaper pixmap the screen itself is copied: remove the old cells first.
		for &cell in old { cell_destroy(d, &cell) }
		clear(&old)
		tx.sync(c)
	}
	by_key := make(map[string]int, len(old), context.temp_allocator)
	for cell, i in old { by_key[cell_key(cell.source, cell.name)] = i }
	pending := -1
	for p, i in places {
		if p.x < 0 { continue }
		it := &l.items[i]
		rect := grid_rect(l, p)
		look := item_look(d, it)
		key := cell_key(it.source, it.name)
		if key == cursor_key { l.cursor = len(l.cells) }
		if it.source == .Folder && l.pending_select != "" && it.name == l.pending_select { pending = len(l.cells) }
		if j, found := by_key[key]; found && old[j].window != 0 {
			cell := old[j]
			old[j] = {}
			cell.entry = i
			cell.place = p
			moved := cell.rect != rect
			if moved || refresh {
				tx.canvas_destroy(&cell.background)
				cell.background = grab_background(d, source, rect)
				cell.light = canvas_is_light(cell.background)
			}
			if look != cell.look { cell_set_label(d, &cell, it.label) }
			if moved || refresh || look != cell.look {
				cell.rect = rect
				cell.look = look
				cell_paint(d, &cell)
				if moved { tx.move_resize(c, cell.window, rect) }
			}
			append(&l.cells, cell)
			continue
		}
		cell := Cell{entry = i, source = it.source, name = strings.clone(it.name), place = p, rect = rect, look = look}
		cell_set_label(d, &cell, it.label)
		cell.background = grab_background(d, source, rect)
		cell.light = canvas_is_light(cell.background)
		cell.window = tx.create_overlay(c, rect, CELL_EVENT_MASK, "_NET_WM_WINDOW_TYPE_DESKTOP", fmt.tprintf("milk: %s", it.label))
		// Lowered before it is mapped: it never shows up above other windows.
		tx.lower_window(c, cell.window)
		append(&l.cells, cell)
		cell_paint(d, &l.cells[len(l.cells) - 1])
		tx.map_window(c, cell.window)
	}
	// The new cells sit under the old ones; removing these reveals them without a gap.
	for &cell in old {
		if cell.window != 0 { cell_destroy(d, &cell) }
	}
	delete(old)
	l.area = area
	if l.pending_select != "" {
		if pending >= 0 {
			layer_select(d, pending)
			l.cursor = pending
			if l.pending_rename { rename_start(d, pending) }
		}
		delete(l.pending_select)
		l.pending_select = ""
		l.pending_rename = false
	}
	tx.flush(c)
	log.debugf("Desktop layer: %d icons in %v", len(l.cells), area)
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
		cell.light = canvas_is_light(cell.background)
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
	band_restack(d)
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

// The grid of cells that fits in the area, inside the margins.
@(private)
make_grid :: proc(d: ^Daemon, area: tx.Rect) -> Grid {
	l := &d.layer
	m := d.cfg.linux.shortcuts.margins // top, right, bottom, left
	avail_w := area.w - i32(m[3]) - i32(m[1])
	avail_h := area.h - i32(m[0]) - i32(m[2])
	return {
		x = area.x + i32(m[3]), y = area.y + i32(m[0]),
		cols = max(1, int(avail_w / l.cell_w)), rows = max(1, int(avail_h / l.cell_h)),
	}
}

@(private)
grid_rect :: proc(l: ^Layer, p: Place) -> tx.Rect {
	return {l.grid.x + i32(p.x) * l.cell_w, l.grid.y + i32(p.y) * l.cell_h, l.cell_w, l.cell_h}
}

// The grid cell under a screen point (it may lie outside the grid).
@(private)
grid_cell_at :: proc(l: ^Layer, x, y: i32) -> Place {
	col := math.floor(f64(x - l.grid.x) / f64(l.cell_w))
	row := math.floor(f64(y - l.grid.y) / f64(l.cell_h))
	return {int(col), int(row)}
}

@(private)
grid_contains :: proc(g: Grid, p: Place) -> bool {
	return p.x >= 0 && p.y >= 0 && p.x < g.cols && p.y < g.rows
}

// The cell of every item ({-1, -1} = does not fit). With desktop icons,
// saved places come first (in list order; a taken or out-of-grid place
// falls back to the free cells); the others take the free cells column by
// column and keep them. Without them, the items simply fill the grid in order.
@(private)
place_items :: proc(d: ^Daemon, items: []Item, g: Grid) -> []Place {
	out := make([]Place, len(items), context.temp_allocator)
	taken := make([]bool, g.cols * g.rows, context.temp_allocator)
	for &p in out { p = {-1, -1} }
	saved := d.files.enabled
	if saved {
		for &it, i in items {
			p, has := place_of(d, &it)
			if !has || !grid_contains(g, p) || taken[p.x * g.rows + p.y] { continue }
			out[i] = p
			taken[p.x * g.rows + p.y] = true
		}
	}
	next := 0
	for &it, i in items {
		if out[i].x >= 0 { continue }
		for next < len(taken) && taken[next] { next += 1 }
		if next >= len(taken) { break }
		out[i] = {next / g.rows, next % g.rows}
		taken[next] = true
		if saved {
			if _, has := place_of(d, &it); !has { place_store(d, &it, out[i]) }
		}
	}
	return out
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

// Is the canvas light on average (a pale wallpaper)?
@(private)
canvas_is_light :: proc(cv: tx.Canvas) -> bool {
	total, n: u64
	for i := 0; i < len(cv.px); i += 7 {
		p := cv.px[i]
		total += u64((p >> 16) & 0xFF) * 299 + u64((p >> 8) & 0xFF) * 587 + u64(p & 0xFF) * 114
		n += 1
	}
	return n > 0 && total / n > 165 * 1000
}

// Selection wash and outline: white on dark wallpapers, dark on light ones.
@(private)
highlight_colors :: proc(light: bool) -> (fill, stroke: tx.Color) {
	if light { return tx.rgba(0, 0, 0, 34), tx.rgba(0, 0, 0, 96) }
	return tx.rgba(255, 255, 255, 56), tx.rgba(255, 255, 255, 120)
}

// Wrap the label into the cell's lines (owned).
@(private)
cell_set_label :: proc(d: ^Daemon, cell: ^Cell, label: string) {
	for i in 0 ..< cell.nlines { delete(cell.lines[i]) }
	lines, n := wrap_label(d, label, d.layer.cell_w - 8)
	for j in 0 ..< n { cell.lines[j] = strings.clone(lines[j]) }
	cell.nlines = n
}

// Everything the cell shows, hashed: a cell is repainted when it changes.
@(private)
item_look :: proc(d: ^Daemon, it: ^Item) -> u64 {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s\x00%v\x00%s\x00%s\x00%v%v%v", it.label, it.kind, it.shortcut.icon, it.icon, it.is_link, it.hidden, it.launcher)
	if thumb_ready(d, it) { fmt.sbprintf(&b, "\x00%s", thumb_key(it)) }
	return hash.fnv64a(b.buf[:])
}

// The theme icon of an item (valid until the next lookup), nil when the
// letter glyph must be drawn.
@(private)
item_icon :: proc(d: ^Daemon, it: ^Item) -> ^tx.Image {
	if it.launcher { return icon_for(&d.icons, &it.shortcut) }
	if it.icon != "" {
		if img := icon_cached(&d.icons, it.icon); img != nil { return img }
	}
	for name in kind_icon_names(it.kind) {
		if img := icon_cached(&d.icons, name); img != nil { return img }
	}
	return nil
}

@(private)
cell_paint :: proc(d: ^Daemon, cell: ^Cell) {
	l := &d.layer
	c := d.c
	it := &l.items[cell.entry]
	w, h := cell.rect.w, cell.rect.h
	cv := tx.canvas_clone(cell.background)
	defer tx.canvas_destroy(&cv)
	if r, inside := band_overlap(d, cell.rect); inside {
		tx.canvas_fill_rect(&cv, r, band_colors(d).fill)
	}
	if cell.selected {
		fill, stroke := highlight_colors(cell.light)
		tx.canvas_fill_rounded_rect(&cv, {2, 2, w - 4, h - 4}, 8, fill)
		tx.canvas_stroke_rounded_rect(&cv, {2, 2, w - 4, h - 4}, 8, 1, stroke)
	}
	icon_x := (w - l.icon_size) / 2
	icon_y := l.pad
	opacity: f32 = it.hidden || it.kind == .Broken ? FADED : 1
	glyph := false
	if thumb := thumb_for(d, it); thumb != nil {
		draw_thumbnail(&cv, thumb^, {icon_x, icon_y, l.icon_size, l.icon_size}, opacity)
	} else if icon := item_icon(d, it); icon != nil {
		tx.canvas_blit_image(&cv, icon^, icon_x, icon_y, opacity)
	} else {
		glyph = true
		square := tx.Rect{icon_x + 1, icon_y + 1, l.icon_size - 2, l.icon_size - 2}
		radius := f32(max(4, l.icon_size / 5))
		tx.canvas_fill_rounded_rect(&cv, square, radius, glyph_color(it.label))
		tx.canvas_stroke_rounded_rect(&cv, square, radius, 1, tx.rgba(255, 255, 255, 90))
	}
	if it.is_link { draw_link_emblem(&cv, icon_x, icon_y + l.icon_size, l.icon_size) }
	pm := tx.canvas_to_pixmap(c, cv)

	ts := tx.text_surface_make(c, xlib.Drawable(pm))
	if glyph && l.glyph_font != nil {
		letter := first_letter_upper(it.label)
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

// A preview centred in the icon box, with a hairline frame and a soft shadow
// so pictures with white edges keep their outline on any wallpaper.
@(private)
draw_thumbnail :: proc(cv: ^tx.Canvas, img: tx.Image, box: tx.Rect, opacity: f32) {
	x := box.x + (box.w - img.w) / 2
	y := box.y + (box.h - img.h) / 2
	tx.canvas_fill_rounded_rect(cv, {x - 1, y, img.w + 3, img.h + 3}, 2, tx.rgba(0, 0, 0, u8(60 * opacity)))
	tx.canvas_blit_image(cv, img, x, y, opacity)
	canvas_frame(cv, {x, y, img.w, img.h}, tx.rgba(255, 255, 255, u8(110 * opacity)))
}

// A one-pixel square outline inside `r`.
@(private)
canvas_frame :: proc(cv: ^tx.Canvas, r: tx.Rect, color: tx.Color) {
	if r.w <= 0 || r.h <= 0 { return }
	tx.canvas_fill_rect(cv, {r.x, r.y, r.w, 1}, color)
	if r.h > 1 { tx.canvas_fill_rect(cv, {r.x, r.y + r.h - 1, r.w, 1}, color) }
	if r.h > 2 {
		tx.canvas_fill_rect(cv, {r.x, r.y + 1, 1, r.h - 2}, color)
		if r.w > 1 { tx.canvas_fill_rect(cv, {r.x + r.w - 1, r.y + 1, 1, r.h - 2}, color) }
	}
}

// The small arrow badge of symbolic links, at the icon's bottom-left corner.
@(private)
draw_link_emblem :: proc(cv: ^tx.Canvas, x, bottom, icon_size: i32) {
	r := f32(max(5, icon_size / 7))
	cx, cy := f32(x) + r + 1, f32(bottom) - r - 1
	tx.canvas_fill_circle(cv, cx, cy, r + 1, tx.rgba(255, 255, 255, 230))
	tx.canvas_fill_circle(cv, cx, cy, r, tx.rgba(40, 40, 44, 235))
	a := r * 0.45
	white := tx.rgba(255, 255, 255, 255)
	tx.canvas_stroke_line(cv, cx - a, cy + a, cx + a, cy - a, 1.5, white)
	tx.canvas_stroke_line(cv, cx + a, cy - a, cx - a * 0.2, cy - a, 1.5, white)
	tx.canvas_stroke_line(cv, cx + a, cy - a, cx + a, cy + a * 0.2, 1.5, white)
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
	delete(cell.name)
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
