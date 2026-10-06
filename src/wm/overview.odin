// milk addition: the overview (Super+Shift+Tab, the "overview" action). The
// area on screen zooms out into a grid of every area of the monitor, each a
// card with its wallpaper and live thumbnails of its windows where they are
// (or where the tiling layout will put them). A click on a window goes to
// it, a click on a card goes to that area, dragging a window onto another
// card moves it there, the middle button closes it. Keys: the arrows choose
// an area, Tab a window in it, Enter goes there, 1…9 go to an area at once,
// Shift+1…9 send the chosen window to an area, Delete closes it, Escape or
// Super+Shift+Tab come back.
//
// While it is open every top-level window is redirected (Composite,
// automatic: the X server keeps drawing the screen as before), so windows of
// other areas, off screen as dwm hides them, still have their contents; Damage
// keeps the thumbnails live. The overlay covers the monitor except the bar,
// which stays live and clickable through a hole of its shape.
package wm

import "base:builtin"
import "core:log"
import "core:math"
import "core:slice"
import xlib "vendor:x11/xlib"
import menu "../menu"
import tx "../tx"

@(private) OV_DRAG_START   :: 6       // pixels before a press becomes a drag
@(private) OV_FRAME        :: 1.0 / 60
@(private) OV_LIVE_FRAME   :: 1.0 / 24 // live thumbnails refresh at most this often
@(private) OV_MODEL_CHECK  :: 0.15    // how often the window list is compared

// What the wallpaper of an area looks like: main.odin answers with the
// screen-sized pixmap milk keeps for it (desktop.area_wallpaper).
Wallpaper_Probe :: #type proc(data: rawptr, area: int) -> (pm: xlib.Pixmap, w, h: i32, ok: bool)

set_wallpaper_probe :: proc(m: ^Manager, probe: Wallpaper_Probe, data: rawptr) {
	if m == nil { return }
	m.overview.probe = probe
	m.overview.probe_data = data
}

// One window drawn in a card.
@(private)
Ov_Item :: struct {
	win:  xlib.Window, // the client window
	rect: tx.Rect,     // in the card (card coordinates)
	full: tx.Rect,     // where it is (or will be) in the window area, relative to it
}

// One area.
@(private)
Ov_Card :: struct {
	rect:      tx.Rect,             // on the overlay
	items:     [dynamic]Ov_Item,    // bottom first
	minimized: [dynamic]xlib.Window,
	mini_rects: [dynamic]tx.Rect,   // the minimized windows' icons (card coordinates)
	buf_pm:    xlib.Pixmap,         // the card drawn (ARGB, rounded)
	buf:       Picture,
	dirty:     bool,
}

// A window's contents and its thumbnail.
@(private)
Ov_Thumb :: struct {
	win:      xlib.Window, // client window
	top:      xlib.Window, // what is redirected: the frame or the client itself
	src:      Picture,     // the window itself (IncludeInferiors), 0 = no contents
	sw, sh:   i32,
	damage:   Damage,
	dirty:    bool,        // the contents changed since the thumbnail was made
	pm:       xlib.Pixmap, // the thumbnail (ARGB, rounded corners)
	pic:      Picture,
	tw, th:   i32,
	icon:     Picture,     // the window's icon (ARGB), 0 = none
	icon_size: i32,
	icon_tried: bool,
	seen:     bool,
}

@(private)
Ov_Phase :: enum u8 { Closed, Opening, Open, Closing }

// What the overview does when it closes.
@(private)
Ov_Exit :: struct {
	area:   int,         // 0-based area to show, -1 = stay
	client: xlib.Window, // a window to bring forward (its area comes with it)
}

Overview :: struct {
	probe:       Wallpaper_Probe,
	probe_data:  rawptr,
	checked:     bool, // the extensions were looked for
	usable:      bool,
	damage_base: i32,
	fmt_root, fmt_argb, fmt_a8: ^XRenderPictFormat,

	phase:       Ov_Phase,
	mon:         ^Monitor,
	win:         xlib.Window, // the overlay; kept between uses, hidden (ov_conceal)
	size:        tx.Rect,     // the monitor (root coordinates)
	work:        tx.Rect,     // the window area, relative to the monitor
	redirected:  bool,
	kb_grabbed:  bool,
	grab_until:  f64,

	back_pm:     xlib.Pixmap, // what the overlay shows (its background)
	back:        Picture,
	plain:       Picture,     // the area's wallpaper as on screen (monitor size)
	plain_pm:    xlib.Pixmap,
	dim:         Picture,     // the same, blurred and tinted: the overview's background
	dim_pm:      xlib.Pixmap,
	snapshot:    Picture,     // the window area on screen when the overview opened
	snapshot_pm: xlib.Pixmap,
	zoom:        Picture,     // the area being zoomed into (closing), window area size
	zoom_pm:     xlib.Pixmap,
	zoom_tmp:    Picture,     // scratch for the zooming card
	zoom_tmp_pm: xlib.Pixmap,
	walls:       [dynamic]Picture,     // per area: its wallpaper at card size (0 = none)
	wall_pms:    [dynamic]xlib.Pixmap,
	masks:       map[[4]i32]Picture,    // A8 masks by (kind, w, h, radius)
	mask_pms:    [dynamic]xlib.Pixmap,

	cards:       [dynamic]Ov_Card,
	thumbs:      [dynamic]Ov_Thumb,
	cw, ch:      i32,  // card size
	scale:       f32,  // card / window area
	radius:      f32,  // card corners
	label_h:     i32,
	hint_y:      i32,
	label_font:  ^tx.Font,
	hint_font:   ^tx.Font,
	glyph_font:  ^tx.Font,
	signature:   u64,
	checked_at:  f64,

	selected:    int,          // the card the keyboard is on
	pick:        xlib.Window,  // the window Tab chose in it (0 = none)
	hover_card:  int,          // -1 = none
	hover_win:   xlib.Window,
	hover_mini:  bool,         // hover_win is a minimized window's icon
	pointer:     [2]i32,       // last pointer position (overlay coordinates)
	press_win:   xlib.Window,  // button 1 went down on this window (0 = none)
	press_card:  int,
	press_mini:  bool,
	press_at:    [2]i32,
	press_off:   [2]i32,       // pointer offset in the thumbnail
	press_btn:   u32,
	dragging:    bool,
	drop_card:   int,

	anim_start:  f64,
	anim_len:    f64,
	zoom_card:   int,      // the card that zooms (the current area opening, the target closing)
	need_paint:  bool,
	painted_at:  f64,
}

// Is the overview on screen (opening, open or closing)?
overview_active :: proc(m: ^Manager) -> bool {
	return m != nil && m.overview.phase != .Closed
}

// The "overview" action: open it, or close it where it was opened.
overview_toggle :: proc(m: ^Manager) {
	ov := &m.overview
	switch ov.phase {
	case .Closed:            overview_open(m)
	case .Opening, .Open:    overview_close(m, {area = -1})
	case .Closing:
	}
}

@(private)
overview_check :: proc(m: ^Manager) -> bool {
	ov := &m.overview
	if ov.checked { return ov.usable }
	ov.checked = true
	ev, er: i32
	if !XCompositeQueryExtension(m.dpy, &ev, &er) { log.warn("overview: the X server has no Composite extension"); return false }
	if !XDamageQueryExtension(m.dpy, &ov.damage_base, &er) { log.warn("overview: the X server has no Damage extension"); return false }
	if !XRenderQueryExtension(m.dpy, &ev, &er) { log.warn("overview: the X server has no Render extension"); return false }
	ov.fmt_root = XRenderFindVisualFormat(m.dpy, m.c.visual)
	ov.fmt_argb = XRenderFindStandardFormat(m.dpy, PICT_STANDARD_ARGB32)
	ov.fmt_a8 = XRenderFindStandardFormat(m.dpy, PICT_STANDARD_A8)
	if ov.fmt_root == nil || ov.fmt_argb == nil || ov.fmt_a8 == nil { log.warn("overview: no Render formats"); return false }
	ov.usable = true
	return true
}

@(private)
overview_open :: proc(m: ^Manager) {
	ov := &m.overview
	if !overview_check(m) { return }
	switcher_finish(m, false)
	menu.close(&m.menu)
	clear(&m.menu_entries)
	mon := m.selmon
	if mon == nil || mon.mw <= 0 || mon.mh <= 0 { return }
	ov.mon = mon
	ov.size = {mon.mx, mon.my, mon.mw, mon.mh}
	ov.work = {mon.wx - mon.mx, mon.wy - mon.my, mon.ww, mon.wh}
	now := tx.now()

	// What is on screen now, before anything changes: the first frame.
	ov_take_snapshot(m)
	XCompositeRedirectSubwindows(m.dpy, m.root, COMPOSITE_REDIRECT_AUTOMATIC)
	ov.redirected = true

	ov_overlay(m)
	ov_fonts(m)
	ov_layout(m)
	ov_backgrounds(m)
	ov.selected = max(lowest_tag(mon.tagset[mon.seltags]), 0)
	ov.pick = 0
	ov.hover_card, ov.hover_win, ov.press_win, ov.dragging, ov.drop_card = -1, 0, 0, false, -1
	ov_rebuild(m)

	ov.kb_grabbed = false
	ov.grab_until = now + 1.5 // the launcher may still hold the keyboard for a moment
	ov_grab(m)
	ov.zoom_card = ov.selected
	ov.phase = .Opening
	ov.anim_start = now
	ov.anim_len = m.settings.overview_anim
	if ov.anim_len <= 0 { ov.phase = .Open }
	ov_paint(m, now)
	ov_reveal(m) // with the first frame, the screen itself, already in it
	if x, y, ok := getrootptr(m); ok { ov_hover(m, x - ov.size.x, y - ov.size.y) }
	m.panel_request = "overview" // main.odin closes the bar's popups and the panels
	xlib.Flush(m.dpy)
	log.debug("overview: open")
}

// Leave the overview: do what `exit` says, then zoom into that area.
@(private)
overview_close :: proc(m: ^Manager, exit: Ov_Exit) {
	ov := &m.overview
	if ov.phase == .Closed || ov.phase == .Closing { return }
	ov_end_drag(m, false)
	mon := ov.mon
	cur := lowest_tag(mon.tagset[mon.seltags])
	target := exit.area >= 0 ? exit.area : cur
	if exit.client != 0 {
		if c := wintoclient(m, exit.client); c != nil && c.mon == mon { target = lowest_tag(c.tags) }
	}
	target = clamp(target, 0, len(ov.cards) - 1)
	// The area as it will look, drawn now from the windows as they are, and
	// its wallpaper around it (beside a floating bar) as the zoom ends.
	ov_compose_full(m, target)
	if target != cur {
		if pic, _, _, _ := ov_wallpaper(m, target); pic != 0 {
			XRenderComposite(m.dpy, PICT_OP_SRC, pic, 0, ov.plain, ov.size.x, ov.size.y, 0, 0, 0, 0, u32(ov.size.w), u32(ov.size.h))
			XRenderFreePicture(m.dpy, pic)
		}
	}
	if exit.client != 0 {
		if c := wintoclient(m, exit.client); c != nil { activate_client(m, c) }
	} else if exit.area >= 0 && exit.area != cur {
		a := Arg{ui = u32(1) << u32(exit.area)}
		view(m, &a)
	}
	ov_ungrab(m)
	ov.zoom_card = target
	now := tx.now()
	start := now
	// Closing while it still opens: zoom back from where it is.
	if ov.phase == .Opening && ov.anim_len > 0 {
		t := clamp((now - ov.anim_start) / ov.anim_len, 0, 1)
		start = now - (1 - t) * ov.anim_len
	}
	ov.phase = .Closing
	ov.anim_start = start
	ov.anim_len = m.settings.overview_anim
	if ov.anim_len <= 0 {
		overview_finish(m)
		return
	}
	ov.need_paint = true
}

// Take the overview down at once (reloads, monitor changes, the lock screen).
overview_finish :: proc(m: ^Manager) {
	ov := &m.overview
	if ov.phase == .Closed { return }
	ov_ungrab(m)
	ov.phase = .Closed
	ov_conceal(m)
	ov_release(m)
	if ov.redirected {
		XCompositeUnredirectSubwindows(m.dpy, m.root, COMPOSITE_REDIRECT_AUTOMATIC)
		ov.redirected = false
	}
	ov.mon = nil
	xlib.Flush(m.dpy)
	log.debug("overview: closed")
}

// Free everything (milk stops).
overview_destroy :: proc(m: ^Manager) {
	ov := &m.overview
	overview_finish(m)
	if ov.win != 0 { xlib.DestroyWindow(m.dpy, ov.win) }
	ov.win = 0
	overview_fonts_reset(m)
	delete(ov.cards)
	delete(ov.thumbs)
	delete(ov.walls)
	delete(ov.wall_pms)
	delete(ov.masks)
	delete(ov.mask_pms)
}

// Keep the overlay above the windows the window manager raises.
overview_raise :: proc(m: ^Manager) {
	ov := &m.overview
	if ov.phase != .Closed && ov.win != 0 { xlib.RaiseWindow(m.dpy, ov.win) }
}

// The overlay: the whole monitor (a compositor gives a full-screen window no
// corners or shadow), kept mapped between uses and only reshaped: a
// compositor animates windows that are mapped or come back from off screen,
// not a change of shape. Hidden, it is one pixel at the bottom of the stack
// showing the root's own background, and takes no input.
@(private)
ov_overlay :: proc(m: ^Manager) {
	ov := &m.overview
	overview_prepare(m)
	xlib.MoveResizeWindow(m.dpy, ov.win, ov.size.x, ov.size.y, u32(ov.size.w), u32(ov.size.h))
}

// Make the hidden overlay (wm start): a compositor's animation of its first
// mapping happens now, unseen, and not when the overview first opens.
overview_prepare :: proc(m: ^Manager) {
	ov := &m.overview
	if ov.win != 0 { return }
	mask := xlib.EventMask{.ButtonPress, .ButtonRelease, .PointerMotion, .LeaveWindow, .KeyPress, .KeyRelease}
	ov.win = tx.create_overlay(m.c, {0, 0, 1, 1}, mask, "_NET_WM_WINDOW_TYPE_NORMAL", "milk overview")
	ov_conceal(m)
	xlib.MapWindow(m.dpy, ov.win)
	xlib.LowerWindow(m.dpy, ov.win)
}

@(private)
ov_conceal :: proc(m: ^Manager) {
	ov := &m.overview
	if ov.win == 0 { return }
	if tx.shape_supported(m.c) {
		dot := xlib.XRectangle{0, 0, 1, 1}
		tx.XShapeCombineRectangles(m.dpy, ov.win, SHAPE_BOUNDING, 0, 0, &dot, 1, SHAPE_SET, 0)
		tx.XShapeCombineRectangles(m.dpy, ov.win, SHAPE_INPUT, 0, 0, nil, 0, SHAPE_SET, 0)
	}
	xlib.SetWindowBackgroundPixmap(m.dpy, ov.win, xlib.Pixmap(xlib.ParentRelative))
	xlib.ClearWindow(m.dpy, ov.win)
	xlib.LowerWindow(m.dpy, ov.win)
	xlib.ResizeWindow(m.dpy, ov.win, 1, 1)
}

// Shown: the whole monitor but the bars, which stay live and clickable.
@(private)
ov_reveal :: proc(m: ^Manager) {
	ov := &m.overview
	xlib.RaiseWindow(m.dpy, ov.win)
	if !tx.shape_supported(m.c) {
		xlib.Flush(m.dpy)
		return
	}
	full := xlib.XRectangle{0, 0, u16(ov.size.w), u16(ov.size.h)}
	tx.XShapeCombineRectangles(m.dpy, ov.win, SHAPE_BOUNDING, 0, 0, &full, 1, SHAPE_SET, 0)
	for w in tx.root_children(m.c) {
		if w == ov.win || !ov_is_bar(m, w) { continue }
		attrs: xlib.XWindowAttributes
		if xlib.GetWindowAttributes(m.dpy, w, &attrs) == 0 || attrs.map_state != .IsViewable { continue }
		bx, by := attrs.x - ov.size.x, attrs.y - ov.size.y
		if bx >= ov.size.w || by >= ov.size.h || bx + attrs.width <= 0 || by + attrs.height <= 0 { continue }
		n, ordering: i32
		rects := XShapeGetRectangles(m.dpy, w, SHAPE_BOUNDING, &n, &ordering)
		if rects != nil && n > 0 {
			// The shape is relative to the inside of the border.
			bw := attrs.border_width
			tx.XShapeCombineRectangles(m.dpy, ov.win, SHAPE_BOUNDING, bx + bw, by + bw, rects, n, SHAPE_SUBTRACT, 0)
		} else {
			hole := xlib.XRectangle{i16(bx), i16(by), u16(attrs.width + 2 * attrs.border_width), u16(attrs.height + 2 * attrs.border_width)}
			tx.XShapeCombineRectangles(m.dpy, ov.win, SHAPE_BOUNDING, 0, 0, &hole, 1, SHAPE_SUBTRACT, 0)
		}
		if rects != nil { xlib.Free(rects) }
	}
	tx.XShapeCombineMask(m.dpy, ov.win, SHAPE_INPUT, 0, 0, 0, SHAPE_SET) // input follows the shape
	xlib.Flush(m.dpy)
}

// A dock window (milk's bar, or another panel) that the overview leaves visible.
@(private)
ov_is_bar :: proc(m: ^Manager, w: xlib.Window) -> bool {
	if c := wintoclient(m, w); c != nil { return c.kind == .Dock }
	dock := tx.atom(m.c, "_NET_WM_WINDOW_TYPE_DOCK")
	for a in tx.get_atoms(m.c, w, "_NET_WM_WINDOW_TYPE") { if a == dock { return true } }
	return false
}

@(private)
ov_fonts :: proc(m: ^Manager) {
	ov := &m.overview
	st := &m.settings.menu_style
	if ov.label_font == nil {
		ov.label_font, _ = tx.font_open(m.c, st.font, st.font_px + 1)
		if ov.label_font == nil { ov.label_font, _ = tx.font_open(m.c, "sans", st.font_px + 1) }
	}
	if ov.hint_font == nil {
		ov.hint_font, _ = tx.font_open(m.c, st.font, max(st.font_px - 1, 9))
		if ov.hint_font == nil { ov.hint_font, _ = tx.font_open(m.c, "sans", max(st.font_px - 1, 9)) }
	}
	if ov.glyph_font == nil && m.settings.icon_font_file != "" {
		ov.glyph_font, _ = tx.font_open_file(m.c, m.settings.icon_font_file, st.font_px + 3)
	}
}

// New settings while it is open: everything is drawn again with them (the
// fonts change on the next opening).
overview_restyle :: proc(m: ^Manager) {
	ov := &m.overview
	if ov.phase == .Closed {
		overview_fonts_reset(m)
		return
	}
	for &card in ov.cards { card.dirty = true }
	ov.need_paint = true
}

// The fonts follow the settings (a reload).
overview_fonts_reset :: proc(m: ^Manager) {
	ov := &m.overview
	tx.font_close(m.c, ov.label_font)
	tx.font_close(m.c, ov.hint_font)
	tx.font_close(m.c, ov.glyph_font)
	ov.label_font, ov.hint_font, ov.glyph_font = nil, nil, nil
}

@(private)
ov_grab :: proc(m: ^Manager) {
	ov := &m.overview
	if ov.kb_grabbed || ov.win == 0 { return }
	if xlib.GrabKeyboard(m.dpy, ov.win, true, .GrabModeAsync, .GrabModeAsync, xlib.CurrentTime) == GRAB_SUCCESS {
		ov.kb_grabbed = true
	}
}

@(private)
ov_ungrab :: proc(m: ^Manager) {
	ov := &m.overview
	if !ov.kb_grabbed { return }
	xlib.UngrabKeyboard(m.dpy, xlib.CurrentTime)
	ov.kb_grabbed = false
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------
// The grid of cards in the window area: as large as the cards can be, a
// label under each and a line of hints at the bottom.
@(private)
ov_layout :: proc(m: ^Manager) {
	ov := &m.overview
	n := max(m.settings.tag_count, 1)
	work := ov.work
	aspect := f32(work.w) / f32(max(work.h, 1))
	ov.label_h = (ov.label_font != nil ? ov.label_font.height : 16) + 14
	hint_h := (ov.hint_font != nil ? ov.hint_font.height : 14) + 24
	gap := clamp(work.w / 48, 14, 40)
	mx := max(work.w / 22, 24)
	top := max(work.h / 18, 24)
	avail_w := work.w - 2 * mx
	avail_h := work.h - top - hint_h
	best_cols, best_w := 1, i32(0)
	for cols in 1 ..= n {
		rows := (n + cols - 1) / cols
		w := (avail_w - i32(cols - 1) * gap) / i32(cols)
		h := (avail_h - i32(rows) * ov.label_h - i32(rows - 1) * gap) / i32(rows)
		w = min(w, i32(f32(h) * aspect))
		if w > best_w { best_cols, best_w = cols, w }
	}
	cols := best_cols
	rows := (n + cols - 1) / cols
	ov.cw = max(best_w, 32)
	ov.ch = max(i32(f32(ov.cw) / aspect), 18)
	ov.scale = f32(ov.cw) / f32(max(work.w, 1))
	ov.radius = clamp(f32(ov.cw) / 28, 6, 16)
	grid_h := i32(rows) * (ov.ch + ov.label_h) + i32(rows - 1) * gap
	y0 := work.y + top + max((avail_h - grid_h) / 2, 0)
	ov.hint_y = work.y + work.h - hint_h
	builtin.resize(&ov.cards, n)
	for i in 0 ..< n {
		row, col := i / cols, i % cols
		in_row := min(cols, n - row * cols) // the last row is centred
		row_w := i32(in_row) * ov.cw + i32(in_row - 1) * gap
		x0 := work.x + (work.w - row_w) / 2
		ov.cards[i].rect = {x0 + i32(col) * (ov.cw + gap), y0 + i32(row) * (ov.ch + ov.label_h + gap), ov.cw, ov.ch}
	}
}

// Every window of every area, where it will be shown; thumbnails for the new
// ones. Cheap enough to run whenever something changes.
@(private)
ov_rebuild :: proc(m: ^Manager) {
	ov := &m.overview
	mon := ov.mon
	for &t in ov.thumbs { t.seen = false }
	stacking := tx.root_children(m.c)
	Stacked :: struct { c: ^Client, level: int }
	for &card, i in ov.cards {
		clear(&card.items)
		clear(&card.minimized)
		clear(&card.mini_rects)
		card.dirty = true
		bit := u32(1) << u32(i)
		stacked := make([dynamic]Stacked, context.temp_allocator)
		for c := mon.clients; c != nil; c = c.next {
			if c.tags & bit == 0 || !ov_shows(c) { continue }
			if c.minimized {
				append(&card.minimized, c.win)
				continue
			}
			level := -1
			top := top_window(c)
			for w, k in stacking { if w == top { level = k; break } }
			append(&stacked, Stacked{c, level})
		}
		// Bottom first, as the X server stacks them.
		slice.stable_sort_by(stacked[:], proc(a, b: Stacked) -> bool { return a.level < b.level })
		shown := make([]^Client, len(stacked), context.temp_allocator)
		for s, k in stacked { shown[k] = s.c }
		geoms := ov_area_geometry(m, mon, bit, shown)
		for c, k in shown {
			full := geoms[k]
			r := tx.Rect{
				i32(math.round(f32(full.x) * ov.scale)), i32(math.round(f32(full.y) * ov.scale)),
				max(i32(math.round(f32(full.w) * ov.scale)), 2), max(i32(math.round(f32(full.h) * ov.scale)), 2),
			}
			append(&card.items, Ov_Item{win = c.win, rect = r, full = full})
			ov_thumb_for(m, c).seen = true
		}
		// Minimized windows: their icons along the bottom of the card.
		size := ov_mini_size(ov)
		for w, k in card.minimized {
			x := ov.cw - 8 - i32(len(card.minimized) - k) * (size + 6) + 6
			append(&card.mini_rects, tx.Rect{x, ov.ch - size - 8, size, size})
			if c := wintoclient(m, w); c != nil { ov_thumb_for(m, c).seen = true }
		}
	}
	// Windows that went away (or left the monitor).
	for i := len(ov.thumbs) - 1; i >= 0; i -= 1 {
		if ov.thumbs[i].seen { continue }
		ov_thumb_free(m, &ov.thumbs[i])
		unordered_remove(&ov.thumbs, i)
	}
	if ov.pick != 0 && ov_card_of(ov, ov.pick, ov.selected) < 0 { ov.pick = 0 }
	ov.signature = ov_signature(m)
	ov.need_paint = true
}

// Which windows a card shows: application windows (no panels, popups or
// picture-in-picture windows, which are on every area anyway).
@(private)
ov_shows :: proc(c: ^Client) -> bool {
	return c.kind == .Normal && !c.ispip && !c.nofocus
}

@(private)
ov_mini_size :: proc(ov: ^Overview) -> i32 {
	return clamp(ov.ch / 7, 14, 32)
}

// Where the windows of area `bit` are (the visible ones) or will be once the
// area is shown: the tiling layout computed for it, floating windows where
// they were. Rectangles relative to the monitor's window area. Tiled windows
// of an area off screen are given that place and size already (still off
// screen, see ov_place_hidden).
@(private)
ov_area_geometry :: proc(m: ^Manager, mon: ^Monitor, bit: u32, clients: []^Client) -> []tx.Rect {
	out := make([]tx.Rect, len(clients), context.temp_allocator)
	visible := mon.tagset[mon.seltags] & bit != 0
	lt := cur_layout(mon)
	tiled := make([dynamic]int, context.temp_allocator)
	for c, i in clients {
		switch {
		case c.isfullscreen:
			out[i] = {mon.mx, mon.my, mon.mw, mon.mh}
		case visible || c.isfloating || !has_arrange(lt):
			out[i] = {c.x, c.y, width(c), height(c)}
		case:
			out[i] = {c.x, c.y, width(c), height(c)}
			append(&tiled, i)
		}
	}
	if len(tiled) > 0 {
		// tile() and monocle() in the order of mon.clients.
		ordered := make([dynamic]int, context.temp_allocator)
		for c := mon.clients; c != nil; c = c.next {
			for i in tiled { if clients[i] == c { append(&ordered, i) } }
		}
		g := m.settings.gaps
		n := i32(len(ordered))
		if lt == .Monocle {
			for i in ordered { out[i] = {mon.wx + g, mon.wy + g, mon.ww - 2 * g, mon.wh - 2 * g} }
		} else {
			mw: i32
			if n > mon.nmaster {
				mw = mon.nmaster > 0 ? i32(f32(mon.ww - 3 * g) * mon.mfact) : 0
			} else {
				mw = mon.ww - 2 * g
			}
			stack_x := mon.wx + g + (mw > 0 ? mw + g : 0)
			stack_w := mon.ww - 2 * g - (mw > 0 ? mw + g : 0)
			my, ty := g, g
			for i, k in ordered {
				k := i32(k)
				if k < mon.nmaster {
					rest := min(n, mon.nmaster) - k
					h := (mon.wh - my - rest * g) / rest
					out[i] = {mon.wx + g, mon.wy + my, mw, h}
					my += h + g
				} else {
					rest := n - k
					h := (mon.wh - ty - rest * g) / rest
					out[i] = {stack_x, mon.wy + ty, stack_w, h}
					ty += h + g
				}
			}
		}
		for i in ordered { out[i] = ov_place_hidden(m, clients[i], out[i]) }
	}
	for &r in out { r.x -= mon.wx; r.y -= mon.wy }
	return out
}

// A tiled window of an area off screen takes the place the layout gives it
// there (size hints applied, as tile() does), staying off screen: the
// application draws itself at that size, so its thumbnail is right, and
// showing the area moves nothing. Returns its outer rectangle.
@(private)
ov_place_hidden :: proc(m: ^Manager, c: ^Client, r: tx.Rect) -> tx.Rect {
	x, y, w, h := r.x, r.y, r.w - ext_w(c), r.h - ext_h(c)
	if c.animating || is_visible(c) || !applysizehints(m, c, &x, &y, &w, &h, false) {
		return {c.x, c.y, width(c), height(c)}
	}
	c.x, c.y, c.w, c.h = x, y, w, h
	hidden_x := width(c) * -2
	if c.frame != 0 {
		frame_apply(m, c, hidden_x, c.y)
	} else {
		xlib.MoveResizeWindow(m.dpy, c.win, hidden_x, c.y, u32(max(c.w, 1)), u32(max(c.h, 1)))
	}
	c.disp_valid = false
	apply_corners(m, c)
	configure(m, c)
	return {c.x, c.y, width(c), height(c)}
}

// A summary of what the cards show: when it changes, they are rebuilt.
@(private)
ov_signature :: proc(m: ^Manager) -> u64 {
	ov := &m.overview
	mon := ov.mon
	h: u64 = 1469598103934665603
	mix :: proc(h: ^u64, v: u64) { h^ = (h^ ~ v) * 1099511628211 }
	mix(&h, u64(mon.tagset[mon.seltags]))
	mix(&h, u64(cur_layout(mon)))
	for c := mon.clients; c != nil; c = c.next {
		mix(&h, u64(c.win))
		mix(&h, u64(c.tags))
		mix(&h, u64(c.minimized) | u64(c.isfloating) << 1 | u64(c.isfullscreen) << 2)
		mix(&h, u64(u32(c.x)) | u64(u32(c.y)) << 32)
		mix(&h, u64(u32(c.w)) | u64(u32(c.h)) << 32)
	}
	for w in tx.root_children(m.c) { mix(&h, u64(w)) }
	return h
}

// The card (0-based area) showing `win`, preferring `prefer`; -1 = none.
@(private)
ov_card_of :: proc(ov: ^Overview, win: xlib.Window, prefer := -1) -> int {
	found := -1
	for &card, i in ov.cards {
		for it in card.items {
			if it.win != win { continue }
			if i == prefer { return i }
			if found < 0 { found = i }
		}
	}
	return found
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------
// Events for the overview; true when used up.
overview_event :: proc(m: ^Manager, ev: ^xlib.XEvent) -> bool {
	ov := &m.overview
	if !ov.checked || !ov.usable { return false }
	if i32(ev.type) == ov.damage_base + DAMAGE_NOTIFY {
		de := (^XDamageNotifyEvent)(ev)
		XDamageSubtract(m.dpy, de.damage, 0, 0)
		for &t in ov.thumbs {
			if t.damage == de.damage {
				t.dirty = true
				break
			}
		}
		return true
	}
	if ov.phase == .Closed { return false }
	#partial switch ev.type {
	case .KeyPress:
		ov_key(m, &ev.xkey)
		return true
	case .KeyRelease:
		return true
	case .ButtonPress:
		if ev.xbutton.window != ov.win { return false }
		ov_press(m, &ev.xbutton)
		return true
	case .ButtonRelease:
		if ev.xbutton.window != ov.win { return false }
		ov_release_button(m, &ev.xbutton)
		return true
	case .MotionNotify:
		if ev.xmotion.window != ov.win { return false }
		mo := &ev.xmotion
		for xlib.CheckTypedWindowEvent(m.dpy, ov.win, .MotionNotify, ev) {} // the latest position only
		ov_motion(m, mo.x, mo.y)
		return true
	case .LeaveNotify:
		if ev.xcrossing.window != ov.win { return false }
		if !ov.dragging { ov_hover(m, -1, -1) }
		return true
	case .EnterNotify:
		return ev.xcrossing.window == ov.win
	}
	return false
}

@(private)
ov_key :: proc(m: ^Manager, ke: ^xlib.XKeyEvent) {
	ov := &m.overview
	if ov.phase != .Open && ov.phase != .Opening { return }
	sym := xlib.LookupKeysym(ke, 0)
	shift := .ShiftMask in ke.state
	n := len(ov.cards)
	cols := ov_cols(ov)
	// The overview's own shortcut (Super+Shift+Tab, or the user's) closes it.
	state := cleanmask(m, ke.state)
	for list in ([][]Key_Action{m.settings.default_keys, m.settings.key_actions}) {
		for k in list {
			if k.action == "overview" && k.keysym == sym && cleanmask(m, k.mod) == state {
				overview_close(m, {area = -1})
				return
			}
		}
	}
	#partial switch sym {
	case .XK_Escape:
		overview_close(m, {area = -1})
	case .XK_Tab, .XK_ISO_Left_Tab:
		// Super+Shift+Tab again closes; Tab alone walks the windows of the card.
		if m.settings.modkey <= ke.state {
			overview_close(m, {area = -1})
			return
		}
		ov_step_pick(m, shift || sym == .XK_ISO_Left_Tab ? -1 : 1)
	case .XK_Left, .XK_h:
		if shift { ov_send_pick(m, ov.selected - 1); return }
		ov_select(m, (ov.selected - 1 + n) % n)
	case .XK_Right, .XK_l:
		if shift { ov_send_pick(m, ov.selected + 1); return }
		ov_select(m, (ov.selected + 1) % n)
	case .XK_Up, .XK_k:
		if shift { ov_send_pick(m, ov.selected - cols); return }
		if ov.selected - cols >= 0 { ov_select(m, ov.selected - cols) }
	case .XK_Down, .XK_j:
		if shift { ov_send_pick(m, ov.selected + cols); return }
		if ov.selected + cols < n { ov_select(m, ov.selected + cols) }
	case .XK_Return, .XK_KP_Enter, .XK_space:
		overview_close(m, {area = ov.selected, client = ov.pick})
	case .XK_Delete, .XK_BackSpace:
		if c := wintoclient(m, ov.pick); c != nil { kill_client(m, c) }
	case .XK_1 ..= .XK_9, .XK_KP_1 ..= .XK_KP_9:
		k := int(uint(sym) - uint(xlib.KeySym.XK_1))
		if sym >= .XK_KP_1 { k = int(uint(sym) - uint(xlib.KeySym.XK_KP_1)) }
		if k >= n { return }
		if shift { ov_send_pick(m, k); return }
		overview_close(m, {area = k})
	}
}

@(private)
ov_cols :: proc(ov: ^Overview) -> int {
	if len(ov.cards) == 0 { return 1 }
	y := ov.cards[0].rect.y
	n := 0
	for card in ov.cards { if card.rect.y == y { n += 1 } }
	return max(n, 1)
}

@(private)
ov_select :: proc(m: ^Manager, i: int) {
	ov := &m.overview
	if i < 0 || i >= len(ov.cards) || i == ov.selected { return }
	ov.cards[ov.selected].dirty = true
	ov.selected = i
	ov.pick = 0
	ov.cards[i].dirty = true
	ov.need_paint = true
}

// Tab: the next window of the chosen card (topmost first).
@(private)
ov_step_pick :: proc(m: ^Manager, dir: int) {
	ov := &m.overview
	card := &ov.cards[ov.selected]
	n := len(card.items)
	if n == 0 { return }
	cur := -1
	for it, i in card.items { if it.win == ov.pick { cur = n - 1 - i } } // index from the top
	next := cur < 0 ? (dir > 0 ? 0 : n - 1) : (cur + dir + n) % n
	ov.pick = card.items[n - 1 - next].win
	card.dirty = true
	ov.need_paint = true
}

// Shift+arrow / Shift+digit: the chosen window (or the focused one) to another area.
@(private)
ov_send_pick :: proc(m: ^Manager, area: int) {
	ov := &m.overview
	if area < 0 || area >= len(ov.cards) { return }
	win := ov.pick
	if win == 0 {
		card := &ov.cards[ov.selected]
		if sel := ov.mon.sel; sel != nil && ov_card_of(ov, sel.win, ov.selected) == ov.selected { win = sel.win }
		if win == 0 && len(card.items) > 0 { win = card.items[len(card.items) - 1].win }
	}
	c := wintoclient(m, win)
	if c == nil || !can_drop_overview(c) { return }
	drop_on_area(m, c, area + 1, drag_start(c))
	ov.cards[ov.selected].dirty = true
	ov.selected = area
	ov.pick = c.win
	ov_rebuild(m)
}

@(private)
can_drop_overview :: proc(c: ^Client) -> bool {
	return !c.ispip && c.kind != .Dock && c.kind != .Desktop
}

// What is under an overlay point: a card, a window in it (or a minimized
// window's icon).
@(private)
ov_hit :: proc(ov: ^Overview, x, y: i32) -> (card: int, win: xlib.Window, mini: bool) {
	for &c, i in ov.cards {
		r := c.rect
		if !tx.rect_contains(r, x, y) { continue }
		lx, ly := x - r.x, y - r.y
		for mr, k in c.mini_rects {
			if tx.rect_contains(mr, lx, ly) { return i, c.minimized[k], true }
		}
		#reverse for it in c.items {
			if it.win == ov.press_win && ov.dragging { continue }
			if tx.rect_contains(it.rect, lx, ly) { return i, it.win, false }
		}
		return i, 0, false
	}
	return -1, 0, false
}

@(private)
ov_hover :: proc(m: ^Manager, x, y: i32) {
	ov := &m.overview
	ov.pointer = {x, y}
	card, win, mini := ov_hit(ov, x, y)
	if card == ov.hover_card && win == ov.hover_win && mini == ov.hover_mini { return }
	if ov.hover_card >= 0 && ov.hover_card < len(ov.cards) { ov.cards[ov.hover_card].dirty = true }
	if card >= 0 { ov.cards[card].dirty = true }
	ov.hover_card, ov.hover_win, ov.hover_mini = card, win, mini
	ov.need_paint = true
}

@(private)
ov_press :: proc(m: ^Manager, be: ^xlib.XButtonEvent) {
	ov := &m.overview
	if ov.phase != .Open && ov.phase != .Opening { return }
	card, win, mini := ov_hit(ov, be.x, be.y)
	ov.press_btn = u32(be.button)
	ov.press_card, ov.press_win, ov.press_mini = card, win, mini
	ov.press_at = {be.x, be.y}
	if win != 0 && !mini {
		for it in ov.cards[card].items {
			if it.win == win { ov.press_off = {be.x - ov.cards[card].rect.x - it.rect.x, be.y - ov.cards[card].rect.y - it.rect.y} }
		}
	}
}

@(private)
ov_motion :: proc(m: ^Manager, x, y: i32) {
	ov := &m.overview
	ov.pointer = {x, y}
	if ov.press_win != 0 && ov.press_btn == 1 && !ov.press_mini && !ov.dragging {
		if abs(x - ov.press_at.x) >= OV_DRAG_START || abs(y - ov.press_at.y) >= OV_DRAG_START {
			if c := wintoclient(m, ov.press_win); c != nil && can_drop_overview(c) {
				ov.dragging = true
				ov.cards[ov.press_card].dirty = true
			}
		}
	}
	if ov.dragging {
		card, _, _ := ov_hit(ov, x, y)
		if card != ov.drop_card {
			if ov.drop_card >= 0 { ov.cards[ov.drop_card].dirty = true }
			if card >= 0 { ov.cards[card].dirty = true }
			ov.drop_card = card
		}
		ov.need_paint = true
		return
	}
	ov_hover(m, x, y)
}

@(private)
ov_release_button :: proc(m: ^Manager, be: ^xlib.XButtonEvent) {
	ov := &m.overview
	if u32(be.button) != ov.press_btn { return }
	defer { ov.press_win, ov.press_card, ov.press_btn = 0, -1, 0 }
	if ov.phase != .Open && ov.phase != .Opening { return }
	if ov.dragging {
		ov_end_drag(m, true)
		return
	}
	card, win, mini := ov_hit(ov, be.x, be.y)
	if card != ov.press_card || win != ov.press_win { return } // released elsewhere
	#partial switch be.button {
	case .Button1:
		switch {
		case card < 0:  overview_close(m, {area = -1})
		case win != 0:  overview_close(m, {area = card, client = win})
		case:           overview_close(m, {area = card})
		}
	case .Button2:
		if win != 0 && !mini {
			if c := wintoclient(m, win); c != nil { kill_client(m, c) }
		}
	case .Button3:
		if card < 0 { overview_close(m, {area = -1}) }
	}
}

// A drag ends: `drop` puts the window on the card under the pointer.
@(private)
ov_end_drag :: proc(m: ^Manager, drop: bool) {
	ov := &m.overview
	if !ov.dragging { return }
	ov.dragging = false
	target := ov.drop_card
	ov.drop_card = -1
	for &card in ov.cards { card.dirty = true }
	ov.need_paint = true
	if !drop || target < 0 || target == ov.press_card { return }
	c := wintoclient(m, ov.press_win)
	if c == nil { return }
	drop_on_area(m, c, target + 1, drag_start(c))
	ov.selected = target
	ov.pick = c.win
	ov_rebuild(m)
}

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------
overview_tick :: proc(m: ^Manager, now: f64) {
	ov := &m.overview
	if ov.phase == .Closed { return }
	if !ov.kb_grabbed && now < ov.grab_until && ov.phase != .Closing { ov_grab(m) }
	if ov.phase == .Open && now - ov.checked_at >= OV_MODEL_CHECK {
		ov.checked_at = now
		if ov_signature(m) != ov.signature { ov_rebuild(m) }
	}
	switch ov.phase {
	case .Opening, .Closing:
		if now - ov.anim_start >= ov.anim_len {
			if ov.phase == .Closing {
				overview_finish(m)
				return
			}
			ov.phase = .Open
			for &card in ov.cards { card.dirty = true }
		}
		ov_mark_live(ov)
		ov_paint(m, now)
	case .Open:
		if now - ov.painted_at >= OV_LIVE_FRAME && ov_mark_live(ov) { ov.need_paint = true }
		if ov.need_paint { ov_paint(m, now) }
	case .Closed:
	}
}

// The cards whose windows drew something since the last frame are drawn
// again (their thumbnails with them). Windows no card shows (minimized ones)
// are not waited for. True when a card changed.
@(private)
ov_mark_live :: proc(ov: ^Overview) -> bool {
	changed := false
	for &t in ov.thumbs {
		if !t.dirty { continue }
		shown := false
		for &card in ov.cards {
			for it in card.items {
				if it.win != t.win { continue }
				card.dirty = true
				shown = true
			}
		}
		if shown { changed = true } else { t.dirty = false }
	}
	return changed
}

overview_timeout :: proc(m: ^Manager, now: f64) -> f64 {
	ov := &m.overview
	switch ov.phase {
	case .Opening, .Closing:
		return OV_FRAME
	case .Open:
		if ov.need_paint { return 0 }
		for t in ov.thumbs {
			if t.dirty { return max(OV_LIVE_FRAME - (now - ov.painted_at), 0) }
		}
		next := OV_MODEL_CHECK - (now - ov.checked_at)
		if !ov.kb_grabbed && now < ov.grab_until { next = min(next, 0.05) }
		return max(next, 0)
	case .Closed:
	}
	return -1
}

// The animation's progress: 0 = the area fills the screen, 1 = the grid.
@(private)
ov_progress :: proc(ov: ^Overview, now: f64) -> f32 {
	if ov.anim_len <= 0 { return ov.phase == .Closing ? 0 : 1 }
	t := clamp((now - ov.anim_start) / ov.anim_len, 0, 1)
	#partial switch ov.phase {
	case .Opening: return ease_out(f32(t))
	case .Closing: return 1 - ease_out(f32(t))
	}
	return 1
}

@(private)
ease_out :: proc(t: f32) -> f32 {
	u := 1 - t
	return 1 - u * u * u
}
