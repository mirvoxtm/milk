// The notification centre, Windows 11 style: two cards that slide in from
// the right edge of the work area and fill its height. The upper card holds
// the history grouped by application (newest first) with "clear all" and
// do-not-disturb; the lower card is a month calendar with today highlighted.
// Clicking outside (pointer grab, as the quick-settings card) or Escape
// closes it; the wheel scrolls the list. Opening it marks everything read.
//
// Each card is its own window, rounded with the SHAPE extension and drawn
// opaque with a thin outline (no copy of the screen, so nothing goes stale);
// the slide moves the windows, clipped at the monitor's right edge.
// Coordinates of hits and of the list viewport are relative to the
// notification card's window (the calendar's are offset by its position).
package notify

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

@(private) PANEL_W       :: 380
@(private) PANEL_MARGIN  :: 12 // cards to the work-area edges
@(private) PANEL_GAP     :: 12 // between the two cards
@(private) PANEL_RADIUS  :: 16
@(private) PANEL_HEADER  :: 54
@(private) PANEL_PAD     :: 16
// Base durations (seconds) at animationScale 1.
@(private) PANEL_OPEN_T  :: 0.20
@(private) PANEL_CLOSE_T :: 0.16
@(private) GROUP_HEADER  :: 34
@(private) CARD_PAD      :: 12
@(private) CARD_GAP      :: 8
@(private) GROUP_GAP     :: 14
@(private) SCROLL_STEP   :: 56

@(private)
Panel_Phase :: enum { Hidden, Opening, Open, Closing }

Panel :: struct {
	win:          xlib.Window, // notification card; holds the grabs
	cal_win:      xlib.Window, // calendar card
	pixmap:       xlib.Pixmap,
	cal_pixmap:   xlib.Pixmap,
	card:         tx.Rect, // resting geometry, screen coordinates
	cal:          tx.Rect, // resting geometry; h == 0: no calendar
	cell_h:       i32,
	clip_right:   i32,     // monitor edge: sliding windows are cut there
	card_cur:     tx.Rect, // current window geometries
	cal_cur:      tx.Rect,
	card_shape:   [2]i32,  // size the rounded shapes were made for
	cal_shape:    [2]i32,
	open:         bool,
	phase:        Panel_Phase,
	phase_start:  f64,
	slide:        f64, // 0 = in place, 1 = out to the right
	scroll:       i32,
	content_h:    i32,
	view:         tx.Rect, // list viewport
	hits:         [dynamic]Hit,
	hover:        int,
	grab_pointer: bool,
	grab_keys:    bool,
	next_refresh: f64,
	month_offset: int, // calendar: months from the current one
	batch:        bool, // several removals in a row: redraw once at the end
}

@(private)
panel_show :: proc(n: ^Notifier) {
	pn := &n.panel
	c := n.c
	if pn.open && pn.phase != .Closing { return }
	popups_hide_all(n)
	for notif in n.history { notif.read = true }
	now := tx.now()

	if pn.phase != .Closing {
		mon := tx.monitor_rect(c, "primary")
		area := tx.subtract_bars(c, mon, window_ids(n))
		inner_h := area.h - 2 * PANEL_MARGIN
		pn.cell_h = inner_h >= 820 ? 36 : 30
		cal_h := calendar_height(n, pn.cell_h)
		show_cal := inner_h - cal_h - PANEL_GAP >= 240
		notif_h := show_cal ? inner_h - cal_h - PANEL_GAP : inner_h
		x := area.x + area.w - PANEL_MARGIN - PANEL_W
		pn.card = {x, area.y + PANEL_MARGIN, PANEL_W, notif_h}
		pn.cal = show_cal ? tx.Rect{x, pn.card.y + notif_h + PANEL_GAP, PANEL_W, cal_h} : tx.Rect{}
		pn.clip_right = mon.x + mon.w
		pn.scroll = 0
		pn.month_offset = 0
		pn.slide = anim(n, PANEL_OPEN_T) > 0.001 ? 1 : 0
		pn.phase_start = now
		if pn.win == 0 {
			pn.win = tx.create_overlay(c, pn.card, {.ButtonPress, .PointerMotion, .KeyPress, .LeaveWindow},
			                           "_NET_WM_WINDOW_TYPE_POPUP_MENU", "milk notifications")
			pn.card_cur = pn.card
		}
		if pn.cal_win == 0 {
			pn.cal_win = tx.create_overlay(c, pn.card, {.ButtonPress, .PointerMotion, .LeaveWindow},
			                               "_NET_WM_WINDOW_TYPE_POPUP_MENU", "milk calendar")
			pn.cal_cur = pn.card
		}
	} else {
		// Re-opened while closing: continue from the current position.
		pn.phase_start = now - (1 - pn.slide) * anim(n, PANEL_OPEN_T)
	}
	pn.phase = .Opening
	pn.open = true
	pn.hover = -1
	pn.next_refresh = now + 30
	panel_render(n)
	panel_place(n)
	tx.map_window(c, pn.win)
	tx.raise_window(c, pn.win)
	if pn.cal.h > 0 {
		tx.map_window(c, pn.cal_win)
		tx.raise_window(c, pn.cal_win)
	} else {
		tx.unmap_window(c, pn.cal_win)
	}
	status := xlib.GrabPointer(c.dpy, pn.win, false, {.ButtonPress, .ButtonRelease, .PointerMotion},
	                           .GrabModeAsync, .GrabModeAsync, 0, 0, xlib.CurrentTime)
	pn.grab_pointer = status == 0
	pn.grab_keys = xlib.GrabKeyboard(c.dpy, pn.win, false, .GrabModeAsync, .GrabModeAsync, xlib.CurrentTime) == 0
	if !pn.grab_pointer { log.debug("Notifications: the panel could not grab the pointer") }
	tx.flush(c)
}

// Geometry of a card for the current slide, cut at the monitor edge.
@(private)
panel_slid :: proc(pn: ^Panel, r: tx.Rect) -> tx.Rect {
	dx := i32(math.round(pn.slide * f64(PANEL_W + PANEL_MARGIN)))
	x := r.x + dx
	return {x, r.y, clamp(pn.clip_right - x, 1, r.w), r.h}
}

// Move the card windows (their content is drawn once; only the position
// changes while sliding) and keep their rounded shapes up to date.
@(private)
panel_place :: proc(n: ^Notifier) {
	pn := &n.panel
	c := n.c
	place :: proc(c: ^tx.Connection, win: xlib.Window, want: tx.Rect, cur: ^tx.Rect, full: tx.Rect, shaped: ^[2]i32) {
		if want != cur^ {
			if want.w == cur.w && want.h == cur.h {
				xlib.MoveWindow(c.dpy, win, want.x, want.y)
			} else {
				tx.move_resize(c, win, want)
			}
			cur^ = want
		}
		if shaped^ != {full.w, full.h} {
			tx.shape_rounded(c, win, full.w, full.h, PANEL_RADIUS)
			shaped^ = {full.w, full.h}
		}
	}
	place(c, pn.win, panel_slid(pn, pn.card), &pn.card_cur, pn.card, &pn.card_shape)
	if pn.cal.h > 0 { place(c, pn.cal_win, panel_slid(pn, pn.cal), &pn.cal_cur, pn.cal, &pn.cal_shape) }
}

@(private)
panel_ungrab :: proc(n: ^Notifier) {
	pn := &n.panel
	if pn.grab_pointer { xlib.UngrabPointer(n.c.dpy, xlib.CurrentTime) }
	if pn.grab_keys { xlib.UngrabKeyboard(n.c.dpy, xlib.CurrentTime) }
	pn.grab_pointer = false
	pn.grab_keys = false
}

@(private)
panel_start_close :: proc(n: ^Notifier) {
	pn := &n.panel
	if !pn.open || pn.phase == .Closing { return }
	panel_ungrab(n)
	pn.phase_start = tx.now() - pn.slide * anim(n, PANEL_CLOSE_T)
	pn.phase = .Closing
	pn.hover = -1
	if anim(n, PANEL_CLOSE_T) <= 0.001 { panel_hide_now(n) }
	tx.flush(n.c)
}

@(private)
panel_hide_now :: proc(n: ^Notifier) {
	pn := &n.panel
	panel_ungrab(n)
	if pn.open {
		if pn.win != 0 { tx.unmap_window(n.c, pn.win) }
		if pn.cal_win != 0 { tx.unmap_window(n.c, pn.cal_win) }
	}
	pn.open = false
	pn.phase = .Hidden
}

@(private)
panel_destroy :: proc(n: ^Notifier) {
	pn := &n.panel
	panel_hide_now(n)
	if pn.win != 0 { tx.destroy_window(n.c, pn.win) }
	if pn.cal_win != 0 { tx.destroy_window(n.c, pn.cal_win) }
	tx.pixmap_free(n.c, pn.pixmap)
	tx.pixmap_free(n.c, pn.cal_pixmap)
	delete(pn.hits)
	pn^ = {}
}

// The content changed while open.
@(private)
panel_refresh :: proc(n: ^Notifier) {
	if !n.panel.open || n.panel.batch { return }
	for notif in n.history { notif.read = true }
	panel_render(n)
}

@(private)
panel_tick :: proc(n: ^Notifier, now: f64) {
	pn := &n.panel
	if !pn.open { return }
	switch pn.phase {
	case .Hidden:
	case .Opening:
		t := progress(now, pn.phase_start, anim(n, PANEL_OPEN_T))
		pn.slide = 1 - ease_out(t)
		if t >= 1 {
			pn.slide = 0
			pn.phase = .Open
		}
		panel_place(n)
	case .Closing:
		t := progress(now, pn.phase_start, anim(n, PANEL_CLOSE_T))
		pn.slide = ease_in(t)
		if t >= 1 {
			panel_hide_now(n)
			return
		}
		panel_place(n)
	case .Open:
		if now >= pn.next_refresh {
			// Relative times ("5 min") and the calendar's today move on.
			pn.next_refresh = now + 30
			panel_render(n)
		}
	}
}

@(private)
panel_timeout :: proc(n: ^Notifier, now: f64) -> f64 {
	pn := &n.panel
	if !pn.open { return -1 }
	if pn.phase == .Opening || pn.phase == .Closing { return FRAME }
	return max(pn.next_refresh - now, 0)
}

// Events of the calendar window (only without a pointer grab) use the
// notification card's coordinates.
@(private)
panel_event_calendar :: proc(n: ^Notifier, ev: ^xlib.XEvent) {
	e := ev^
	dy := n.panel.cal.y - n.panel.card.y
	#partial switch e.type {
	case .ButtonPress, .ButtonRelease: e.xbutton.y += dy
	case .MotionNotify:                e.xmotion.y += dy
	}
	panel_event(n, &e)
}

@(private)
panel_event :: proc(n: ^Notifier, ev: ^xlib.XEvent) {
	pn := &n.panel
	if pn.phase == .Closing { return }
	#partial switch ev.type {
	case .KeyPress:
		if xlib.LookupKeysym(&ev.xkey, 0) == .XK_Escape { panel_start_close(n) }
	case .LeaveNotify:
		if pn.hover != -1 && !pn.grab_pointer {
			pn.hover = -1
			panel_render(n)
		}
	case .MotionNotify:
		hover := -1
		for h, i in pn.hits {
			if h.kind != .Panel && h.kind != .None && tx.rect_contains(h.r, ev.xmotion.x, ev.xmotion.y) { hover = i }
		}
		if hover != pn.hover {
			pn.hover = hover
			panel_render(n)
		}
	case .ButtonPress:
		x, y := ev.xbutton.x, ev.xbutton.y
		hit := -1
		for h, i in pn.hits {
			if h.kind != .None && tx.rect_contains(h.r, x, y) { hit = i }
		}
		if hit < 0 {
			panel_start_close(n)
			return
		}
		#partial switch ev.xbutton.button {
		case .Button4, .Button5:
			if !tx.rect_contains(pn.view, x, y) { return }
			step: i32 = ev.xbutton.button == .Button4 ? -SCROLL_STEP : SCROLL_STEP
			panel_scroll(n, step)
			return
		case .Button1:
		case:
			return
		}
		h := pn.hits[hit]
		log.debugf("Notifications: panel click %v", h.kind)
		switch h.kind {
		case .Clear_All:
			ids := make([dynamic]u32, context.temp_allocator)
			for notif in n.history { if !notif.transient { append(&ids, notif.id) } }
			pn.batch = true
			for id in ids { notification_remove(n, id, .Dismissed) }
			pn.batch = false
			pn.scroll = 0
		case .DND:
			n.dnd = !n.dnd
		case .Dismiss:
			notification_remove(n, h.id, .Dismissed)
		case .Dismiss_Group:
			ids := make([dynamic]u32, context.temp_allocator)
			key := group_key_of(n, h.id)
			for notif in n.history {
				if !notif.transient && group_key(n, notif) == key { append(&ids, notif.id) }
			}
			pn.batch = true
			for id in ids { notification_remove(n, id, .Dismissed) }
			pn.batch = false
		case .Card:
			notif, _ := find_notification(n, h.id)
			if notif != nil && notif.has_default {
				notification_invoke(n, h.id, "default")
				panel_start_close(n)
			}
		case .Cal_Prev:
			pn.month_offset -= 1
		case .Cal_Next:
			pn.month_offset += 1
		case .None, .Close, .Action, .Body, .Panel:
		}
		if !pn.open || pn.phase == .Closing { return }
		// Redraw, then re-evaluate the hover under the pointer (the layout changed).
		pn.hover = -1
		panel_render(n)
		for hh, i in pn.hits {
			if hh.kind != .Panel && hh.kind != .None && tx.rect_contains(hh.r, x, y) { pn.hover = i }
		}
		if pn.hover != -1 { panel_render(n) }
	}
	tx.flush(n.c)
}

@(private)
panel_scroll :: proc(n: ^Notifier, delta: i32) {
	pn := &n.panel
	limit := max(pn.content_h - pn.view.h, 0)
	next := clamp(pn.scroll + delta, 0, limit)
	if next == pn.scroll { return }
	pn.scroll = next
	pn.hover = -1
	panel_render(n)
}

@(private)
group_key :: proc(n: ^Notifier, notif: ^Notification) -> string {
	return display_app_name(n, notif)
}

@(private)
group_key_of :: proc(n: ^Notifier, id: u32) -> string {
	notif, _ := find_notification(n, id)
	if notif == nil { return "" }
	return strings.clone(group_key(n, notif), context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------
@(private)
Group :: struct {
	key:    string,
	items:  [dynamic]^Notification, // newest first
}

@(private)
panel_groups :: proc(n: ^Notifier) -> []Group {
	groups := make([dynamic]Group, context.temp_allocator)
	#reverse for notif in n.history {
		if notif.transient { continue }
		key := group_key(n, notif)
		found := false
		for &g in groups {
			if g.key == key {
				append(&g.items, notif)
				found = true
				break
			}
		}
		if !found {
			g := Group{key = key, items = make([dynamic]^Notification, context.temp_allocator)}
			append(&g.items, notif)
			append(&groups, g)
		}
	}
	return groups[:]
}

@(private)
card_text_x :: proc(notif: ^Notification) -> i32 {
	return notif.image.rgba != nil ? CARD_PAD + BIG_ICON + 12 : CARD_PAD
}

@(private)
card_height :: proc(n: ^Notifier, notif: ^Notification, w: i32) -> i32 {
	f := &n.fonts
	text_w := w - CARD_PAD - card_text_x(notif)
	h: i32 = 0
	if f.title != nil { h += f.title.height }
	lines := wrap_text(n.c, f.body, notif.body, text_w, 3)
	if len(lines) > 0 && f.body != nil { h += 2 + i32(len(lines)) * f.body.height }
	if notif.image.rgba != nil { h = max(h, BIG_ICON) }
	return h + 2 * CARD_PAD
}

@(private)
calendar_height :: proc(n: ^Notifier, cell_h: i32) -> i32 {
	f := &n.fonts
	title_h: i32 = f.title != nil ? f.title.height : 18
	return PANEL_PAD + title_h + 14 + 1 + 12 + 30 + 26 + 6 * cell_h + PANEL_PAD - 4
}

@(private)
panel_render :: proc(n: ^Notifier) {
	pn := &n.panel
	c := n.c
	th := &n.theme
	f := &n.fonts
	clear(&pn.hits)

	// The notification card (window coordinates: the card is the window).
	card := tx.Rect{0, 0, PANEL_W, pn.card.h}
	p := painter_make(card.w, card.h)
	l := frame_layer(&p)
	tx.canvas_fill(&p.cv, th.background)
	layer_stroke(l, card, PANEL_RADIUS, 1, th.outline)
	append(&pn.hits, Hit{r = card, kind = .Panel})

	// While another daemon owns the bus name (or there is no bus), say so
	// under the title: the panel still shows milk's own history.
	notice := ""
	switch n.bus_state {
	case .Serving:
	case .Waiting:
		who := n.owner_label != "" ? n.owner_label : tr(n, "desconhecido", "unknown")
		notice = fmt.tprintf(tr(n, "Outro serviço de notificações está ativo (%s)", "Another notification service is running (%s)"), who)
	case .Unavailable:
		notice = tr(n, "Serviço de notificações indisponível (sem D-Bus)", "Notification service unavailable (no D-Bus)")
	}
	top_h: i32 = notice != "" ? PANEL_HEADER - 8 : PANEL_HEADER // title row
	header_h := notice != "" ? top_h + 20 : top_h
	if notice != "" {
		line := tx.text_ellipsize(c, f.small, notice, card.w - 2 * PANEL_PAD)
		layer_text_v(l, f.small, card.x + PANEL_PAD + 2, card.y + top_h - 6, 20, line, th.muted)
	}

	// Header: title, do-not-disturb, clear all.
	hy := card.y
	layer_text_v(l, f.header, card.x + PANEL_PAD + 2, hy, top_h, tr(n, "Notificações", "Notifications"), th.foreground)
	clear_label := tr(n, "Limpar tudo", "Clear all")
	clear_w := tx.text_width(c, f.small, clear_label) + 24
	clear_r := tx.Rect{card.x + card.w - PANEL_PAD - clear_w + 4, hy + (top_h - 30) / 2, clear_w, 30}
	has_items := false
	for notif in n.history { if !notif.transient { has_items = true; break } }
	if has_items {
		hovered := pn.hover == len(pn.hits)
		layer_rect(l, clear_r, 15, hovered ? th.hover : th.surface)
		layer_text_v(l, f.small, clear_r.x + 12, clear_r.y, clear_r.h, clear_label, th.foreground)
		append(&pn.hits, Hit{r = clear_r, kind = .Clear_All})
	}
	dnd_r := tx.Rect{(has_items ? clear_r.x : card.x + card.w - PANEL_PAD + 4) - 8 - 30, clear_r.y, 30, 30}
	{
		hovered := pn.hover == len(pn.hits)
		fill := n.dnd ? th.accent : (hovered ? th.hover : th.surface)
		layer_circle(l, f32(dnd_r.x) + 15, f32(dnd_r.y) + 15, 15, fill)
		glyph := n.dnd ? GLYPH_BELL_Z : GLYPH_BELL
		if f.icons != nil {
			layer_glyph(c, l, f.icons, glyph, dnd_r.x + 15, dnd_r.y + 15, n.dnd ? th.accent_foreground : th.foreground)
		} else {
			layer_text_v(l, f.small, dnd_r.x + 6, dnd_r.y, dnd_r.h, "DND", n.dnd ? th.accent_foreground : th.foreground)
		}
		append(&pn.hits, Hit{r = dnd_r, kind = .DND})
	}
	// A hairline under the header once the list scrolls beneath it.
	if pn.scroll > 0 {
		tx.canvas_fill_rect(&p.cv, {card.x, card.y + header_h - 1, card.w, 1}, tx.color_with_alpha(th.muted, 60))
	}

	// The list, drawn on its own canvas so that it clips at the viewport.
	view := tx.Rect{card.x + 8, card.y + header_h, card.w - 16, card.h - header_h - 12}
	pn.view = view
	groups := panel_groups(n)
	if len(groups) == 0 {
		pn.content_h = 0
		pn.scroll = 0
		mid := view.y + view.h / 2 - 20
		if f.big != nil {
			layer_glyph(c, l, f.big, GLYPH_BELL_OFF, view.x + view.w / 2, mid - 10, th.muted)
		}
		empty := tr(n, "Sem notificações novas", "No new notifications")
		ew := tx.text_width(c, f.body, empty)
		layer_text_v(l, f.body, view.x + (view.w - ew) / 2, mid + 26, 24, empty, th.secondary)
		if n.dnd {
			note := tr(n, "Não perturbe está ativado", "Do not disturb is on")
			nw := tx.text_width(c, f.small, note)
			layer_text_v(l, f.small, view.x + (view.w - nw) / 2, mid + 50, 20, note, th.muted)
		}
	} else {
		panel_draw_list(n, &p, groups, view)
	}
	painter_finish(c, &p, pn.win, &pn.pixmap)

	// The calendar card, in its own window below.
	if pn.cal.h > 0 {
		dy := pn.cal.y - pn.card.y
		cal := tx.Rect{0, 0, PANEL_W, pn.cal.h}
		cp := painter_make(cal.w, cal.h)
		cl := frame_layer(&cp)
		tx.canvas_fill(&cp.cv, th.background)
		layer_stroke(cl, cal, PANEL_RADIUS, 1, th.outline)
		append(&pn.hits, Hit{r = {0, dy, cal.w, cal.h}, kind = .Panel})
		panel_draw_calendar(n, cl, cal, pn.cell_h, dy)
		painter_finish(c, &cp, pn.cal_win, &pn.cal_pixmap)
	}
}

@(private)
panel_draw_list :: proc(n: ^Notifier, p: ^Painter, groups: []Group, view: tx.Rect) {
	pn := &n.panel
	c := n.c
	th := &n.theme
	f := &n.fonts

	// Measure first so the scroll range is known.
	total: i32 = 0
	for g, gi in groups {
		if gi > 0 { total += GROUP_GAP }
		total += GROUP_HEADER
		for notif, i in g.items {
			if i > 0 { total += CARD_GAP }
			total += card_height(n, notif, view.w)
		}
	}
	total += 4
	pn.content_h = total
	pn.scroll = clamp(pn.scroll, 0, max(total - view.h, 0))

	list := tx.canvas_make(view.w, view.h, context.temp_allocator)
	tx.canvas_fill(&list, th.background)
	l := Layer{p = p, cv = &list, ox = view.x, oy = view.y, clip = view}

	y := view.y - pn.scroll
	for g, gi in groups {
		if gi > 0 { y += GROUP_GAP }
		// Group header: icon, app name, dismiss-all.
		first := g.items[0]
		gx := view.x + 6
		if first.icon.rgba != nil {
			layer_image(l, first.icon, gx, y + (GROUP_HEADER - SMALL_ICON) / 2)
		} else if f.icons != nil {
			layer_glyph(c, l, f.icons, GLYPH_BELL, gx + SMALL_ICON / 2, y + GROUP_HEADER / 2, th.secondary)
		}
		gx_r := tx.Rect{view.x + view.w - 30, y + (GROUP_HEADER - 26) / 2, 26, 26}
		name := tx.text_ellipsize(c, f.small, g.key, gx_r.x - (gx + SMALL_ICON + 8) - 6)
		layer_text_v(l, f.small, gx + SMALL_ICON + 8, y, GROUP_HEADER, name, th.secondary)
		if clip_r, cok := tx.rect_intersect(gx_r, view); cok {
			hovered := pn.hover == len(pn.hits)
			if hovered { layer_circle(l, f32(gx_r.x) + 13, f32(gx_r.y) + 13, 13, th.hover) }
			if f.icons != nil { layer_glyph(c, l, f.icons, GLYPH_X, gx_r.x + 13, gx_r.y + 13, hovered ? th.foreground : th.muted) }
			append(&pn.hits, Hit{r = clip_r, kind = .Dismiss_Group, id = first.id})
		}
		y += GROUP_HEADER

		for notif, i in g.items {
			if i > 0 { y += CARD_GAP }
			h := card_height(n, notif, view.w)
			r := tx.Rect{view.x, y, view.w, h}
			y += h
			visible, ok := tx.rect_intersect(r, view)
			if !ok { continue }
			card_index := len(pn.hits)
			append(&pn.hits, Hit{r = visible, kind = .Card, id = notif.id})
			// Hover: the card, or its dismiss button (appended right after).
			card_hover := pn.hover == card_index || pn.hover == card_index + 1
			fill := th.surface
			if card_hover { fill = tx.color_mix(th.surface, th.muted, notif.has_default ? 0.16 : 0.08) }
			layer_rect(l, r, 12, fill)
			if notif.urgency >= 2 { layer_rect(l, {r.x + 4, r.y + 12, 3, r.h - 24}, 1.5, th.warning) }

			if notif.image.rgba != nil { layer_image(l, notif.image, r.x + CARD_PAD, r.y + CARD_PAD) }
			tx0 := r.x + card_text_x(notif)
			right := r.x + r.w - CARD_PAD
			ty := r.y + CARD_PAD
			// Time, or the dismiss button while hovered.
			x_r := tx.Rect{right - 24 + 4, ty - 3, 24, 24}
			age := format_age(n, notif.unix_time)
			age_w := tx.text_width(c, f.small, age)
			if card_hover {
				xh := pn.hover == card_index + 1
				if xh { layer_circle(l, f32(x_r.x) + 12, f32(x_r.y) + 12, 12, th.hover) }
				if f.icons != nil { layer_glyph(c, l, f.icons, GLYPH_X, x_r.x + 12, x_r.y + 12, xh ? th.foreground : th.secondary) }
			} else {
				layer_text_v(l, f.small, right - age_w, ty, f.title != nil ? f.title.height : 18, age, th.muted)
			}
			if dismiss_r, dok := tx.rect_intersect(x_r, view); dok {
				append(&pn.hits, Hit{r = dismiss_r, kind = .Dismiss, id = notif.id})
			} else {
				append(&pn.hits, Hit{r = {}, kind = .None})
			}
			title_w := right - max(age_w, 24) - 8 - tx0
			if f.title != nil {
				summary := notif.summary != "" ? notif.summary : display_app_name(n, notif)
				layer_text(l, f.title, tx0, ty + f.title.ascent, tx.text_ellipsize(c, f.title, summary, title_w), th.foreground)
				ty += f.title.height + 2
			}
			if f.body != nil {
				for line in wrap_text(c, f.body, notif.body, right - tx0, 3) {
					layer_text(l, f.body, tx0, ty + f.body.ascent, line, th.secondary)
					ty += f.body.height
				}
			}
		}
	}
	canvas_paste(&p.cv, list, view.x, view.y)

	// Scroll indicator.
	if pn.content_h > view.h {
		track_h := view.h - 8
		thumb_h := max(track_h * view.h / pn.content_h, 24)
		thumb_y := view.y + 4 + (track_h - thumb_h) * pn.scroll / max(pn.content_h - view.h, 1)
		tx.canvas_fill_rounded_rect(&p.cv, {view.x + view.w + 2, thumb_y, 4, thumb_h}, 2, tx.color_with_alpha(th.muted, 150))
	}
}

// ---------------------------------------------------------------------------
// Calendar
// ---------------------------------------------------------------------------

@(private)
days_in_month :: proc(year, month: int) -> int { // month 1..12
	switch month {
	case 4, 6, 9, 11: return 30
	case 2:
		leap := (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
		return leap ? 29 : 28
	}
	return 31
}

// 0 = Sunday (Sakamoto's method).
@(private)
weekday :: proc(year, month, day: int) -> int {
	t := [12]int{0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4}
	y := year
	if month < 3 { y -= 1 }
	return (y + y / 4 - y / 100 + y / 400 + t[month - 1] + day) % 7
}

@(private)
panel_draw_calendar :: proc(n: ^Notifier, l: Layer, cal: tx.Rect, cell_h: i32, hit_dy: i32) {
	pn := &n.panel
	c := n.c
	th := &n.theme
	f := &n.fonts
	lang := n.cfg.bar.language
	today := local_tm(now_unix())
	t_year, t_month, t_day := int(today.tm_year) + 1900, int(today.tm_mon) + 1, int(today.tm_mday)

	x0 := cal.x + PANEL_PAD
	y := cal.y + PANEL_PAD - 2
	title_h: i32 = f.title != nil ? f.title.height : 18
	wday := int(today.tm_wday)
	full := lang == .English ? fmt.tprintf("%s, %s %d", config.WEEKDAYS_FULL[lang][wday], config.MONTHS_FULL[lang][t_month - 1], t_day) \
	                         : fmt.tprintf("%s, %d de %s", config.WEEKDAYS_FULL[lang][wday], t_day, config.MONTHS_FULL[lang][t_month - 1])
	layer_text_v(l, f.title, x0 + 2, y, title_h, full, th.foreground)
	y += title_h + 14
	tx.canvas_fill_rect(l.cv, {cal.x - l.ox, y - l.oy, cal.w, 1}, tx.color_with_alpha(th.muted, 60))
	y += 1 + 12

	// Month shown (current + offset).
	m := t_month - 1 + pn.month_offset
	year := t_year + int(math.floor(f64(m) / 12))
	month := ((m % 12) + 12) % 12 + 1
	label := lang == .English ? fmt.tprintf("%s %d", config.MONTHS_FULL[lang][month - 1], year) : fmt.tprintf("%s de %d", config.MONTHS_FULL[lang][month - 1], year)
	layer_text_v(l, f.body, x0 + 2, y, 30, label, th.foreground)
	up := tx.Rect{cal.x + cal.w - PANEL_PAD - 64, y, 30, 30}
	down := tx.Rect{cal.x + cal.w - PANEL_PAD - 30, y, 30, 30}
	for r, i in ([2]tx.Rect{up, down}) {
		hovered := pn.hover == len(pn.hits)
		if hovered { layer_circle(l, f32(r.x) + 15, f32(r.y) + 15, 15, th.hover) }
		glyph := i == 0 ? GLYPH_CHEVRON_UP : GLYPH_CHEVRON_DOWN
		if f.icons != nil {
			layer_glyph(c, l, f.icons, glyph, r.x + 15, r.y + 15, th.foreground)
		} else {
			layer_text_v(l, f.body, r.x + 10, r.y, r.h, i == 0 ? "^" : "v", th.foreground)
		}
		append(&pn.hits, Hit{r = {r.x, r.y + hit_dy, r.w, r.h}, kind = i == 0 ? .Cal_Prev : .Cal_Next})
	}
	y += 30

	grid_w := cal.w - 2 * PANEL_PAD
	cell_w := grid_w / 7
	gx := cal.x + (cal.w - cell_w * 7) / 2
	initials := config.WEEKDAY_INITIALS[lang]
	for i in 0 ..< 7 {
		s := initials[i]
		w := tx.text_width(c, f.small, s)
		layer_text_v(l, f.small, gx + i32(i) * cell_w + (cell_w - w) / 2, y, 26, s, th.muted)
	}
	y += 26

	first := weekday(year, month, 1)
	count := days_in_month(year, month)
	prev_month := month == 1 ? 12 : month - 1
	prev_year := month == 1 ? year - 1 : year
	prev_count := days_in_month(prev_year, prev_month)
	for cell in 0 ..< 42 {
		row, col := i32(cell / 7), i32(cell % 7)
		day := cell - first + 1
		in_month := day >= 1 && day <= count
		shown := day
		if day < 1 { shown = prev_count + day }
		if day > count { shown = day - count }
		cx := gx + col * cell_w + cell_w / 2
		cy := y + row * cell_h + cell_h / 2
		s := fmt.tprintf("%d", shown)
		color := in_month ? th.foreground : th.muted
		if in_month && year == t_year && month == t_month && day == t_day {
			radius := f32(min(cell_w, cell_h)) / 2 - 1
			layer_circle(l, f32(cx), f32(cy), radius, th.accent)
			color = th.accent_foreground
		}
		w := tx.text_width(c, f.body, s)
		layer_text_v(l, f.body, cx - w / 2, cy - cell_h / 2, cell_h, s, color)
	}
}
