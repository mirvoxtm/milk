// Selecting, moving and opening desktop icons with the mouse and the keyboard.
//
// Without desktop icons (linux.desktopIcons) the layer keeps its plain
// behaviour: a click selects a shortcut, a double click (or a single one,
// with singleClick) launches it. With them:
//
// * A press on an icon selects it (Ctrl adds or removes it); a second press
//   within the double-click time opens it, or the release with singleClick.
// * Dragging an icon moves the whole selection: the cells jump from grid
//   cell to grid cell under the pointer, never onto another icon or off the
//   grid (they stay at the last valid spot), and the places are saved on
//   release.
// * A left drag on the empty desktop draws a rubber band that selects every
//   icon it touches (Ctrl adds to the selection); a click there clears it.
//   The band is a window just above the icons whose shape leaves them out,
//   while the icons paint the band's tint themselves, so it looks
//   translucent without a compositor.
// * Keys reach the desktop when the root window has the input focus (the
//   window manager leaves it there when no client is focused) and the
//   pointer is over the desktop: Enter opens, Delete moves to the trash, F2
//   renames, Escape clears, Ctrl+A selects all, the arrows move the
//   selection to the nearest icon in that direction.
//
// Motion events only record the pointer; pointer_tick does the work once
// per loop iteration, so a burst of motion costs one update.
package desktop

import "core:slice"
import xlib "vendor:x11/xlib"
import tx "../tx"

// Pixels the pointer must travel before a press on an icon becomes a drag.
@(private)
DRAG_THRESHOLD :: 5

// X SHAPE operations for the band window (see tx/shape.odin).
@(private) SHAPE_BOUNDING :: 0
@(private) SHAPE_SET      :: 0
@(private) SHAPE_UNION    :: 1
@(private) SHAPE_SUBTRACT :: 3
@(private) SHAPE_UNSORTED :: 0

Pointer_Mode :: enum u8 {
	Idle,
	Pressed,  // button 1 held on an icon, not dragged yet
	Dragging, // moving the selection
	Band,     // rubber band on the empty desktop
}

Pointer :: struct {
	mode:       Pointer_Mode,
	press:      [2]i32, // root coordinates of the press
	pos:        [2]i32, // latest pointer position
	moved:      bool,   // `pos` changed since pointer_tick
	cell:       int,    // the icon pressed
	ctrl:       bool,
	toggle_off: bool,   // Ctrl-press on a selected icon: deselect it on release unless dragged
	collapse:   bool,   // plain press on a selected icon: select only it on release unless dragged
	// Dragging
	moving:     [dynamic]int,   // the cells being moved
	origin:     [dynamic]Place, // their places when the drag started
	offset:     [2]int,         // grid offset applied so far
	// Band
	band:       tx.Rect,        // screen coordinates; w = 0 until it has a size
	base:       [dynamic]bool,  // selection before the band (kept with Ctrl)
	band_win:   xlib.Window,
	band_pm:    xlib.Pixmap,
	band_shown: bool,           // band_win is mapped
	wallpaper:  tx.Canvas,      // the usable area's wallpaper, for the band's own pixels
	light:      bool,           // that wallpaper is light: dark band
	grabbed:    bool,           // we hold the pointer grab of the band
}

@(private)
Band_Colors :: struct { fill, stroke: tx.Color }

pointer_destroy :: proc(d: ^Daemon) {
	p := &d.layer.pointer
	pointer_cancel(d)
	if p.band_win != 0 { tx.destroy_window(d.c, p.band_win) }
	tx.pixmap_free(d.c, p.band_pm)
	delete(p.moving)
	delete(p.origin)
	delete(p.base)
	p^ = {}
}

// Abandon a press, drag or band: the cells are about to be rebuilt, and
// icons dragged but not dropped go back to their saved places.
pointer_cancel :: proc(d: ^Daemon) {
	p := &d.layer.pointer
	if p.mode == .Band { band_end(d) }
	p.mode = .Idle
	p.moved = false
	clear(&p.moving)
	clear(&p.origin)
}

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------

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
	if index >= 0 { d.layer.cursor = index }
	if changed { tx.flush(d.c) }
}

@(private)
cell_set_selected :: proc(d: ^Daemon, index: int, on: bool) {
	cell := &d.layer.cells[index]
	if cell.selected == on { return }
	cell.selected = on
	cell_paint(d, cell)
}

// The selected cells (temp allocator).
selected_cells :: proc(d: ^Daemon) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for &cell, i in d.layer.cells {
		if cell.selected { append(&out, i) }
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Mouse
// ---------------------------------------------------------------------------

// Button press on a cell.
layer_on_button :: proc(d: ^Daemon, index: int, be: ^xlib.XButtonEvent) {
	l := &d.layer
	if index < 0 || index >= len(l.cells) { return }
	extended := d.files.enabled
	if be.button == .Button3 && extended && l.pointer.mode == .Idle {
		desktop_context_menu(d, index, be)
		return
	}
	if be.button != .Button1 || l.pointer.mode != .Idle { return }
	cell := &l.cells[index]
	ctrl := extended && .ControlMask in be.state
	single := d.cfg.linux.shortcuts.single_click
	if !extended && single {
		layer_select(d, -1)
		open_item(d, &l.items[cell.entry])
		return
	}
	elapsed := u32(be.time) - u32(l.last_click_time) // X time wraps around
	if !single && !ctrl && l.last_click_window == cell.window && elapsed < DOUBLE_CLICK_MS {
		l.last_click_window = 0
		layer_select(d, -1)
		open_item(d, &l.items[cell.entry])
		return
	}
	l.last_click_window = cell.window
	l.last_click_time = be.time
	if !extended {
		layer_select(d, index)
		return
	}
	p := &l.pointer
	p.mode = .Pressed
	p.press = {be.x_root, be.y_root}
	p.pos = p.press
	p.moved = false
	p.cell = index
	p.ctrl = ctrl
	p.toggle_off = false
	p.collapse = false
	if ctrl {
		if cell.selected { p.toggle_off = true } else { cell_set_selected(d, index, true) }
	} else if cell.selected {
		p.collapse = true
	} else {
		layer_select(d, index)
	}
	l.cursor = index
	tx.flush(d.c)
}

// Button 1 press on the empty desktop (the root window): clear the
// selection (unless Ctrl) and start a rubber band.
layer_on_root_press :: proc(d: ^Daemon, be: ^xlib.XButtonEvent) {
	l := &d.layer
	if !d.files.enabled || be.button != .Button1 || be.subwindow != 0 || l.pointer.mode != .Idle { return }
	ctrl := .ControlMask in be.state
	if !ctrl { layer_select(d, -1) }
	if len(l.cells) == 0 { return }
	c := d.c
	// Take the implicit grab of the press over: the release and the motion
	// come to us wherever the pointer goes.
	mask := xlib.EventMask{.ButtonRelease, .PointerMotion}
	if xlib.GrabPointer(c.dpy, c.root, false, mask, .GrabModeAsync, .GrabModeAsync, 0, 0, be.time) != 0 { return }
	p := &l.pointer
	p.mode = .Band
	p.grabbed = true
	p.press = {be.x_root, be.y_root}
	p.pos = p.press
	p.moved = false
	p.ctrl = ctrl
	p.band = {}
	clear(&p.base)
	for cell in l.cells { append(&p.base, cell.selected) }
	source, _ := wallpaper_drawable(d)
	p.wallpaper = grab_background(d, source, l.area)
	p.light = canvas_is_light(p.wallpaper)
}

// Pointer motion over a cell (while pressed) or the root (while banding).
layer_on_motion :: proc(d: ^Daemon, x, y: i32) {
	p := &d.layer.pointer
	if p.mode == .Idle { return }
	p.pos = {x, y}
	p.moved = true
}

// Button 1 release: finish the click, the drag or the band.
layer_on_release :: proc(d: ^Daemon, be: ^xlib.XButtonEvent) {
	l := &d.layer
	p := &l.pointer
	if be.button != .Button1 { return }
	p.pos = {be.x_root, be.y_root}
	switch p.mode {
	case .Idle:
	case .Pressed:
		p.mode = .Idle
		if p.cell < 0 || p.cell >= len(l.cells) { return }
		if p.toggle_off {
			cell_set_selected(d, p.cell, false)
		} else if p.collapse {
			layer_select(d, p.cell)
		}
		if d.cfg.linux.shortcuts.single_click && !p.ctrl {
			layer_select(d, -1)
			open_item(d, &l.items[l.cells[p.cell].entry])
		}
	case .Dragging:
		drag_update(d)
		for i in p.moving {
			cell := &l.cells[i]
			place_store(d, &l.items[cell.entry], cell.place)
		}
		p.mode = .Idle
		clear(&p.moving)
		clear(&p.origin)
	case .Band:
		band_update(d)
		band_end(d)
	}
	tx.flush(d.c)
}

// Coalesced motion: start a drag, move the dragged icons, resize the band.
pointer_tick :: proc(d: ^Daemon) {
	p := &d.layer.pointer
	if !p.moved { return }
	p.moved = false
	switch p.mode {
	case .Idle:
	case .Pressed:
		if abs(p.pos.x - p.press.x) <= DRAG_THRESHOLD && abs(p.pos.y - p.press.y) <= DRAG_THRESHOLD { return }
		drag_begin(d)
		drag_update(d)
	case .Dragging:
		drag_update(d)
	case .Band:
		band_update(d)
	}
	tx.flush(d.c)
}

@(private)
drag_begin :: proc(d: ^Daemon) {
	l := &d.layer
	p := &l.pointer
	p.mode = .Dragging
	p.toggle_off = false
	p.collapse = false
	p.offset = {}
	cell_set_selected(d, p.cell, true)
	clear(&p.moving)
	clear(&p.origin)
	for &cell, i in l.cells {
		if !cell.selected { continue }
		append(&p.moving, i)
		append(&p.origin, cell.place)
	}
}

// Move the dragged cells by the grid offset under the pointer, when every
// one of them lands on a free cell of the grid.
@(private)
drag_update :: proc(d: ^Daemon) {
	l := &d.layer
	p := &l.pointer
	if p.mode != .Dragging { return }
	at := grid_cell_at(l, p.pos.x, p.pos.y)
	start := grid_cell_at(l, p.press.x, p.press.y)
	offset := [2]int{at.x - start.x, at.y - start.y}
	if offset == p.offset { return }
	g := l.grid
	taken := make([]bool, g.cols * g.rows, context.temp_allocator)
	for &cell, i in l.cells {
		if slice.contains(p.moving[:], i) || !grid_contains(g, cell.place) { continue }
		taken[cell.place.x * g.rows + cell.place.y] = true
	}
	for o in p.origin {
		q := o + offset
		if !grid_contains(g, q) || taken[q.x * g.rows + q.y] { return }
	}
	p.offset = offset
	source, has_pixmap := wallpaper_drawable(d)
	if !has_pixmap {
		// The screen is the only copy of the wallpaper: take the moving cells off it first.
		for i in p.moving { tx.unmap_window(d.c, l.cells[i].window) }
		tx.sync(d.c)
	}
	for i, k in p.moving {
		cell := &l.cells[i]
		cell.place = p.origin[k] + offset
		cell.rect = grid_rect(l, cell.place)
		tx.canvas_destroy(&cell.background)
		cell.background = grab_background(d, source, cell.rect)
		cell.light = canvas_is_light(cell.background)
		cell_paint(d, cell)
		tx.move_resize(d.c, cell.window, cell.rect)
		if !has_pixmap { tx.map_window(d.c, cell.window) }
	}
}

// ---------------------------------------------------------------------------
// Rubber band
// ---------------------------------------------------------------------------

// Tint and outline of the band: dark on light wallpapers, white on dark ones.
@(private)
band_colors :: proc(d: ^Daemon) -> Band_Colors {
	if d.layer.pointer.light { return {tx.rgba(0, 0, 0, 30), tx.rgba(0, 0, 0, 150)} }
	return {tx.rgba(255, 255, 255, 44), tx.rgba(255, 255, 255, 190)}
}

// The part of the band over `rect`, in `rect`'s coordinates.
@(private)
band_overlap :: proc(d: ^Daemon, rect: tx.Rect) -> (tx.Rect, bool) {
	p := &d.layer.pointer
	if p.mode != .Band || p.band.w <= 0 { return {}, false }
	r, inside := tx.rect_intersect(p.band, rect)
	if !inside { return {}, false }
	return {r.x - rect.x, r.y - rect.y, r.w, r.h}, true
}

// Keep the band window just above the icons (and below everything else).
band_restack :: proc(d: ^Daemon) {
	l := &d.layer
	p := &l.pointer
	if p.band_win == 0 || p.mode != .Band { return }
	top := xlib.Window(0)
	for w in tx.root_children(d.c) {
		if layer_cell_index(d, w) >= 0 { top = w }
	}
	if top == 0 { return }
	wc: xlib.XWindowChanges
	wc.sibling = top
	wc.stack_mode = .Above
	xlib.ConfigureWindow(d.c.dpy, p.band_win, {.CWSibling, .CWStackMode}, &wc)
}

// Follow the pointer: new band rectangle, selection of the icons it
// touches, and the band window's pixels and shape.
@(private)
band_update :: proc(d: ^Daemon) {
	l := &d.layer
	p := &l.pointer
	if p.mode != .Band { return }
	x0, x1 := min(p.press.x, p.pos.x), max(p.press.x, p.pos.x)
	y0, y1 := min(p.press.y, p.pos.y), max(p.press.y, p.pos.y)
	band, inside := tx.rect_intersect({x0, y0, x1 - x0 + 1, y1 - y0 + 1}, l.area)
	if !inside || band.w < 3 || band.h < 3 { band = {} }
	previous := p.band
	if band == previous { return }
	p.band = band
	for &cell, i in l.cells {
		was, _ := tx.rect_intersect(previous, cell.rect)
		now, touched := tx.rect_intersect(band, cell.rect)
		wanted := touched || (p.ctrl && i < len(p.base) && p.base[i])
		if wanted == cell.selected && was == now { continue }
		cell.selected = wanted
		cell_paint(d, &cell)
	}
	band_paint(d)
}

@(private)
band_paint :: proc(d: ^Daemon) {
	l := &d.layer
	p := &l.pointer
	c := d.c
	if p.band.w <= 0 || !tx.shape_supported(c) {
		if p.band_shown { tx.unmap_window(c, p.band_win) }
		p.band_shown = false
		return
	}
	r := p.band
	colors := band_colors(d)
	cv := tx.canvas_make(r.w, r.h, context.temp_allocator)
	area := l.area
	for y in 0 ..< r.h {
		sy := r.y + y - area.y
		if sy < 0 || sy >= p.wallpaper.h { continue }
		sx := r.x - area.x
		copy(cv.px[int(y) * int(r.w):][:r.w], p.wallpaper.px[int(sy) * int(p.wallpaper.w) + int(sx):][:r.w])
	}
	tx.canvas_fill(&cv, colors.fill)
	canvas_frame(&cv, {0, 0, r.w, r.h}, colors.stroke)
	pm := tx.canvas_to_pixmap(c, cv)
	if p.band_win == 0 {
		p.band_win = tx.create_overlay(c, r, {}, "_NET_WM_WINDOW_TYPE_DESKTOP", "milk: selection")
	} else {
		tx.move_resize(c, p.band_win, r)
	}
	tx.set_background(c, p.band_win, pm)
	tx.pixmap_free(c, p.band_pm)
	p.band_pm = pm

	// Shape: the band minus the icons (they paint the tint themselves), plus
	// the outline, which stays on top of them.
	full := xlib.XRectangle{0, 0, u16(r.w), u16(r.h)}
	tx.XShapeCombineRectangles(c.dpy, p.band_win, SHAPE_BOUNDING, 0, 0, &full, 1, SHAPE_SET, SHAPE_UNSORTED)
	holes := make([dynamic]xlib.XRectangle, context.temp_allocator)
	for &cell in l.cells {
		if o, ok := tx.rect_intersect(cell.rect, r); ok {
			append(&holes, xlib.XRectangle{i16(o.x - r.x), i16(o.y - r.y), u16(o.w), u16(o.h)})
		}
	}
	if len(holes) > 0 {
		tx.XShapeCombineRectangles(c.dpy, p.band_win, SHAPE_BOUNDING, 0, 0, raw_data(holes), i32(len(holes)), SHAPE_SUBTRACT, SHAPE_UNSORTED)
		outline := [4]xlib.XRectangle{
			{0, 0, u16(r.w), 1}, {0, i16(r.h - 1), u16(r.w), 1},
			{0, 0, 1, u16(r.h)}, {i16(r.w - 1), 0, 1, u16(r.h)},
		}
		tx.XShapeCombineRectangles(c.dpy, p.band_win, SHAPE_BOUNDING, 0, 0, &outline[0], 4, SHAPE_UNION, SHAPE_UNSORTED)
	}
	if !p.band_shown {
		// Stacked before it is mapped: it never shows up above other windows.
		band_restack(d)
		tx.map_window(c, p.band_win)
		p.band_shown = true
	}
}

// Drop the band: release the grab, hide the window, untint the icons.
@(private)
band_end :: proc(d: ^Daemon) {
	l := &d.layer
	p := &l.pointer
	if p.grabbed {
		xlib.UngrabPointer(d.c.dpy, xlib.CurrentTime)
		p.grabbed = false
	}
	if p.band_shown { tx.unmap_window(d.c, p.band_win) }
	p.band_shown = false
	band := p.band
	p.band = {}
	p.mode = .Idle
	for &cell in l.cells {
		if _, touched := tx.rect_intersect(band, cell.rect); touched { cell_paint(d, &cell) }
	}
	for &cell, i in l.cells {
		if cell.selected {
			l.cursor = i
			break
		}
	}
	tx.canvas_destroy(&p.wallpaper)
	clear(&p.base)
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

// A key pressed while the desktop has the focus (see the header).
layer_on_key :: proc(d: ^Daemon, ke: ^xlib.XKeyEvent) {
	l := &d.layer
	if !d.files.enabled || l.pointer.mode != .Idle { return }
	if ke.state & {.Mod1Mask, .Mod4Mask} != {} { return } // the window manager's
	ctrl := .ControlMask in ke.state
	#partial switch xlib.LookupKeysym(ke, 0) {
	case .XK_Escape:
		layer_select(d, -1)
	case .XK_Return, .XK_KP_Enter:
		open_selection(d)
	case .XK_Delete, .XK_KP_Delete:
		trash_selection(d)
	case .XK_F2:
		if sel := selected_cells(d); len(sel) == 1 { rename_start(d, sel[0]) }
	case .XK_a:
		if ctrl {
			for _, i in l.cells { cell_set_selected(d, i, true) }
		}
	case .XK_Left:  move_cursor(d, {-1, 0})
	case .XK_Right: move_cursor(d, {1, 0})
	case .XK_Up:    move_cursor(d, {0, -1})
	case .XK_Down:  move_cursor(d, {0, 1})
	}
	tx.flush(d.c)
}

// Select the nearest icon from the keyboard anchor in direction `dir`:
// the same row (or column) first, then the closest one.
@(private)
move_cursor :: proc(d: ^Daemon, dir: [2]int) {
	l := &d.layer
	if len(l.cells) == 0 { return }
	from := l.cursor
	if from < 0 || from >= len(l.cells) || !l.cells[from].selected {
		sel := selected_cells(d)
		from = len(sel) > 0 ? sel[0] : -1
	}
	if from < 0 {
		// Nothing selected yet: start at the top-left icon.
		best := 0
		for &cell, i in l.cells {
			b := l.cells[best].place
			if cell.place.x < b.x || (cell.place.x == b.x && cell.place.y < b.y) { best = i }
		}
		layer_select(d, best)
		return
	}
	cur := l.cells[from].place
	best, best_score := -1, max(int)
	for &cell, i in l.cells {
		delta := cell.place - cur
		along := delta.x * dir.x + delta.y * dir.y   // distance in the direction
		across := abs(delta.x * dir.y) + abs(delta.y * dir.x)
		if along <= 0 { continue }
		score := across * 10_000 + along
		if score < best_score { best, best_score = i, score }
	}
	if best >= 0 { layer_select(d, best) }
}
