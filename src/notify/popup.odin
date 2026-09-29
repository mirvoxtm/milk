// Toast popups: one override-redirect window per notification, stacked at
// the top-right (or bottom-right) of the primary monitor's work area, newest
// nearest the corner. Each card slides in from the right edge, the others
// glide to their new places, and it slides back out when it expires (never
// for critical urgency), is dismissed or activated. Hovering a card pauses
// its timer.
//
// Each window is the card itself, rounded with the SHAPE extension and drawn
// opaque with a thin outline: nothing of the screen is copied, so windows
// redrawing around a card never leave stale pixels. Animations only move
// the window (the content is drawn once), clipped at the monitor's right edge.
package notify

import "core:math"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

@(private) POP_W      :: 360 // card width
@(private) POP_GAP    :: 10  // between cards
@(private) POP_MARGIN :: 14  // card to the work-area edge
@(private) POP_PAD    :: 14
@(private) POP_RADIUS :: 14
@(private) POP_HEADER :: 20
@(private) POP_BUTTON :: 32
// Base durations (seconds) at animationScale 1.
@(private) POP_ENTER  :: 0.18
@(private) POP_EXIT   :: 0.15
@(private) POP_MOVE   :: 0.16

@(private)
Popup_Phase :: enum { Entering, Shown, Leaving }

@(private)
Hit_Kind :: enum { None, Close, Action, Body, Clear_All, DND, Dismiss, Dismiss_Group, Card, Cal_Prev, Cal_Next, Panel }

@(private)
Hit :: struct {
	r:     tx.Rect,
	kind:  Hit_Kind,
	id:    u32,
	index: int,
}

Popup :: struct {
	id:          u32,
	snap:        ^Notification, // owned copy of what is displayed
	win:         xlib.Window,
	pixmap:      xlib.Pixmap,
	card_h:      i32,
	shaped_h:    i32, // height the rounded shape was made for
	y:           f64, // card top, screen coordinates
	from_y:      f64,
	to_y:        f64,
	move_start:  f64,
	slide:       f64, // 0 = in place, 1 = fully out to the right
	phase:       Popup_Phase,
	phase_start: f64,
	expire_at:   f64, // 0 = never
	remaining:   f64, // while hovered
	hovered:     bool,
	forgotten:   bool, // the notification is gone: no more clicks
	hits:        [dynamic]Hit,
	hover_hit:   int,
	win_rect:    tx.Rect, // current window geometry
}

@(private)
anim :: proc(n: ^Notifier, base: f64) -> f64 { return config.anim_duration(n.cfg, base) }

// Progress 0..1 of an animation that started at `start` and lasts `d` seconds.
@(private)
progress :: proc(now, start, d: f64) -> f64 {
	if d <= 0.001 { return 1 }
	return clamp((now - start) / d, 0, 1)
}

@(private)
popup_find :: proc(n: ^Notifier, id: u32) -> ^Popup {
	for p in n.popups { if p.id == id && p.phase != .Leaving { return p } }
	return nil
}

// Show (or refresh) the popup of a notification.
@(private)
popup_show :: proc(n: ^Notifier, notif: ^Notification) {
	now := tx.now()
	if len(n.popups) == 0 { popup_place_column(n) }
	p := popup_find(n, notif.id)
	if p != nil {
		notification_free(p.snap)
		p.snap = notification_clone(notif)
		p.card_h = popup_measure(n, p.snap)
		p.expire_at = popup_expiry(n, p.snap, now)
		p.hovered = false
		popups_layout(n, now)
		popup_render(n, p)
		popup_place(n, p)
		return
	}
	p = new(Popup)
	p.id = notif.id
	p.snap = notification_clone(notif)
	p.card_h = popup_measure(n, p.snap)
	p.phase = .Entering
	p.phase_start = now
	p.slide = 1
	p.hover_hit = -1
	enter := anim(n, POP_ENTER)
	p.expire_at = popup_expiry(n, p.snap, now + enter)
	if enter <= 0.001 {
		p.slide = 0
		p.phase = .Shown
	}

	// Make room: the oldest cards leave until the new one fits.
	avail := n.column_rect.h - 2 * POP_MARGIN
	for {
		used := p.card_h
		oldest: ^Popup
		for q in n.popups {
			if q.phase == .Leaving { continue }
			if oldest == nil { oldest = q }
			used += q.card_h + POP_GAP
		}
		if used <= avail || oldest == nil { break }
		popup_leave(n, oldest, now)
	}
	append(&n.popups, p)
	popups_layout(n, now)
	p.y = p.to_y
	p.from_y = p.to_y
	rect := popup_rect(n, p)
	p.win = tx.create_overlay(n.c, rect, {.ButtonPress, .PointerMotion, .EnterWindow, .LeaveWindow},
	                          "_NET_WM_WINDOW_TYPE_NOTIFICATION", "milk notification")
	p.win_rect = rect
	popup_render(n, p)
	popup_place(n, p)
	tx.map_window(n.c, p.win)
	tx.raise_window(n.c, p.win)
}

// When the popup expires (0 = until dismissed).
@(private)
popup_expiry :: proc(n: ^Notifier, notif: ^Notification, from: f64) -> f64 {
	if notif.urgency >= 2 || notif.expire_ms == 0 { return 0 }
	secs := n.cfg.notifications.timeout
	if notif.expire_ms > 0 { secs = f64(notif.expire_ms) / 1000 }
	return from + max(secs, 0.5)
}

// The column the popups use: the right edge of the primary monitor's work area.
@(private)
popup_place_column :: proc(n: ^Notifier) {
	mon := tx.monitor_rect(n.c, "primary")
	area := tx.subtract_bars(n.c, mon, window_ids(n))
	n.column_rect = {area.x + area.w - POP_MARGIN - POP_W, area.y, POP_W + POP_MARGIN, area.h}
	n.clip_right = mon.x + mon.w
}

// Target positions: newest nearest the configured corner.
@(private)
popups_layout :: proc(n: ^Notifier, now: f64) {
	col := n.column_rect
	bottom := n.cfg.notifications.position == "bottom-right"
	cursor := f64(bottom ? col.y + col.h - POP_MARGIN : col.y + POP_MARGIN)
	#reverse for p in n.popups {
		if p.phase == .Leaving { continue }
		target: f64
		if bottom {
			target = cursor - f64(p.card_h)
			cursor = target - POP_GAP
		} else {
			target = cursor
			cursor += f64(p.card_h + POP_GAP)
		}
		if target != p.to_y {
			p.from_y = p.y
			p.to_y = target
			p.move_start = now
			if anim(n, POP_MOVE) <= 0.001 { p.y = target }
		}
	}
}

// Window geometry for the current slide/position, clipped at the monitor edge.
@(private)
popup_rect :: proc(n: ^Notifier, p: ^Popup) -> tx.Rect {
	dx := i32(math.round(p.slide * f64(POP_W + POP_MARGIN)))
	x := n.column_rect.x + dx
	w := clamp(n.clip_right - x, 1, POP_W)
	return {x, i32(math.round(p.y)), w, p.card_h}
}

// Move/resize the window to its current geometry (no redraw needed: the
// background pixmap is anchored at the window's origin).
@(private)
popup_place :: proc(n: ^Notifier, p: ^Popup) {
	rect := popup_rect(n, p)
	if rect != p.win_rect {
		if rect.w == p.win_rect.w && rect.h == p.win_rect.h {
			xlib.MoveWindow(n.c.dpy, p.win, rect.x, rect.y)
		} else {
			tx.move_resize(n.c, p.win, rect)
		}
		p.win_rect = rect
	}
	// The shape is made for the whole card; a narrower window (sliding past
	// the monitor edge) is simply cut on its right side.
	if p.shaped_h != p.card_h {
		tx.shape_rounded(n.c, p.win, POP_W, p.card_h, POP_RADIUS)
		p.shaped_h = p.card_h
	}
}

@(private)
popup_leave :: proc(n: ^Notifier, p: ^Popup, now: f64) {
	if p.phase == .Leaving { return }
	p.phase = .Leaving
	p.phase_start = now
	p.hover_hit = -1
	if anim(n, POP_EXIT) <= 0.001 { p.slide = 1 }
}

// The notification was removed (dismissed, closed, invoked): slide out.
@(private)
popup_forget :: proc(n: ^Notifier, id: u32) {
	now := tx.now()
	for p in n.popups {
		if p.id != id || p.phase == .Leaving { continue }
		p.forgotten = true
		popup_leave(n, p, now)
	}
	popups_layout(n, now)
}

@(private)
popup_free :: proc(n: ^Notifier, p: ^Popup) {
	if p.win != 0 {
		tx.unmap_window(n.c, p.win)
		tx.destroy_window(n.c, p.win)
	}
	tx.pixmap_free(n.c, p.pixmap)
	notification_free(p.snap)
	delete(p.hits)
	free(p)
}

// Remove every popup at once (the panel opens, reload).
@(private)
popups_hide_all :: proc(n: ^Notifier) {
	popups := n.popups
	n.popups = {}
	for p in popups {
		id, forgotten := p.id, p.forgotten
		popup_free(n, p)
		if !forgotten { notification_popup_gone(n, id) }
	}
	delete(popups)
}

@(private)
popups_tick :: proc(n: ^Notifier, now: f64) {
	if len(n.popups) == 0 { return }
	i := 0
	relayout := false
	for i < len(n.popups) {
		p := n.popups[i]
		switch p.phase {
		case .Entering:
			t := progress(now, p.phase_start, anim(n, POP_ENTER))
			p.slide = 1 - ease_out(t)
			if t >= 1 {
				p.slide = 0
				p.phase = .Shown
			}
		case .Shown:
			if p.expire_at > 0 && !p.hovered && now >= p.expire_at {
				popup_leave(n, p, now)
				relayout = true
			}
		case .Leaving:
			t := progress(now, p.phase_start, anim(n, POP_EXIT))
			p.slide = ease_in(t)
			if t >= 1 {
				ordered_remove(&n.popups, i)
				id, forgotten := p.id, p.forgotten
				popup_free(n, p)
				if !forgotten { notification_popup_gone(n, id) }
				continue
			}
		}
		if p.y != p.to_y {
			t := progress(now, p.move_start, anim(n, POP_MOVE))
			p.y = t >= 1 ? p.to_y : p.from_y + (p.to_y - p.from_y) * ease_out(t)
		}
		popup_place(n, p)
		i += 1
	}
	if relayout { popups_layout(n, now) }
}

@(private)
popups_timeout :: proc(n: ^Notifier, now: f64) -> f64 {
	best := -1.0
	for p in n.popups {
		if p.phase != .Shown || p.y != p.to_y { return FRAME }
		if p.expire_at > 0 && !p.hovered {
			d := max(p.expire_at - now, 0)
			if best < 0 || d < best { best = d }
		}
	}
	return best
}

@(private)
popup_event :: proc(n: ^Notifier, p: ^Popup, ev: ^xlib.XEvent) {
	now := tx.now()
	#partial switch ev.type {
	case .EnterNotify:
		if p.phase == .Leaving { return }
		p.hovered = true
		if p.expire_at > 0 { p.remaining = p.expire_at - now }
	case .LeaveNotify:
		if !p.hovered { return }
		p.hovered = false
		if p.expire_at > 0 { p.expire_at = now + max(p.remaining, 1.5) }
		if p.hover_hit != -1 {
			p.hover_hit = -1
			popup_render(n, p)
		}
	case .MotionNotify:
		if p.phase == .Leaving { return }
		hover := -1
		for h, i in p.hits {
			if h.kind != .Body && tx.rect_contains(h.r, ev.xmotion.x, ev.xmotion.y) { hover = i }
		}
		if hover != p.hover_hit {
			p.hover_hit = hover
			popup_render(n, p)
		}
	case .ButtonPress:
		if p.phase == .Leaving || p.forgotten { return }
		x, y := ev.xbutton.x, ev.xbutton.y
		button := ev.xbutton.button
		if button == .Button3 {
			// Right click: hide the popup, keep the notification.
			popup_leave(n, p, now)
			popups_layout(n, now)
			return
		}
		if button != .Button1 { return }
		kind := Hit_Kind.None
		index := -1
		for h in p.hits {
			if tx.rect_contains(h.r, x, y) && (kind == .None || h.kind != .Body) {
				kind = h.kind
				index = h.index
			}
		}
		id := p.id
		switch kind {
		case .Close:
			notification_remove(n, id, .Dismissed)
		case .Action:
			actions := visible_actions(p.snap)
			if index >= 0 && index < len(actions) { notification_invoke(n, id, actions[index].key) }
		case .Body:
			notification_invoke(n, id, p.snap.has_default ? "default" : "")
		case .None, .Clear_All, .DND, .Dismiss, .Dismiss_Group, .Card, .Cal_Prev, .Cal_Next, .Panel:
		}
	}
	tx.flush(n.c)
}

// ---------------------------------------------------------------------------
// Layout and drawing
// ---------------------------------------------------------------------------
@(private)
popup_text_x :: proc(notif: ^Notification) -> i32 {
	return notif.image.rgba != nil ? POP_PAD + BIG_ICON + 12 : POP_PAD
}

@(private)
popup_measure :: proc(n: ^Notifier, notif: ^Notification) -> i32 {
	f := &n.fonts
	text_w := POP_W - POP_PAD - popup_text_x(notif)
	h: i32 = POP_PAD + POP_HEADER + 10
	text_h: i32 = 0
	if notif.summary != "" && f.title != nil { text_h += f.title.height }
	lines := wrap_text(n.c, f.body, notif.body, text_w, 3)
	if len(lines) > 0 && f.body != nil {
		if text_h > 0 { text_h += 2 }
		text_h += i32(len(lines)) * f.body.height
	}
	if notif.image.rgba != nil { text_h = max(text_h, BIG_ICON) }
	h += text_h
	if len(visible_actions(notif)) > 0 { h += 12 + POP_BUTTON }
	h += POP_PAD
	return h
}

// Draw the card (window coordinates: the card is the whole window).
@(private)
popup_render :: proc(n: ^Notifier, p: ^Popup) {
	c := n.c
	th := &n.theme
	f := &n.fonts
	notif := p.snap
	pt := painter_make(POP_W, p.card_h)
	l := frame_layer(&pt)
	clear(&p.hits)

	card := tx.Rect{0, 0, POP_W, p.card_h}
	tx.canvas_fill(&pt.cv, th.background)
	layer_stroke(l, card, POP_RADIUS, 1, th.outline)
	append(&p.hits, Hit{r = card, kind = .Body})
	if notif.urgency >= 2 {
		layer_rect(l, {card.x + 5, card.y + 18, 4, card.h - 36}, 2, th.warning)
	}

	// Header: app icon, app name, close button.
	hx := card.x + POP_PAD
	hy := card.y + POP_PAD
	if notif.icon.rgba != nil {
		layer_image(l, notif.icon, hx, hy + (POP_HEADER - SMALL_ICON) / 2)
	} else {
		layer_glyph(c, l, f.icons, GLYPH_BELL, hx + SMALL_ICON / 2, hy + POP_HEADER / 2, th.secondary)
	}
	close_r := tx.Rect{card.x + card.w - POP_PAD - 26 + 6, hy - 3, 26, 26}
	name_w := close_r.x - (hx + SMALL_ICON + 8) - 8
	name := tx.text_ellipsize(c, f.small, display_app_name(n, notif), name_w)
	layer_text_v(l, f.small, hx + SMALL_ICON + 8, hy, POP_HEADER, name, th.secondary)
	close_hover := p.hover_hit >= 0 && p.hover_hit < len(p.hits) && p.hits[p.hover_hit].kind == .Close
	if close_hover { layer_circle(l, f32(close_r.x) + 13, f32(close_r.y) + 13, 13, th.hover) }
	if f.icons != nil {
		layer_glyph(c, l, f.icons, GLYPH_X, close_r.x + 13, close_r.y + 13, close_hover ? th.foreground : th.secondary)
	} else {
		layer_text_v(l, f.body, close_r.x + 8, close_r.y, close_r.h, "×", th.secondary)
	}
	append(&p.hits, Hit{r = close_r, kind = .Close})

	// Content: picture, summary, body.
	cy := hy + POP_HEADER + 10
	if notif.image.rgba != nil { layer_image(l, notif.image, card.x + POP_PAD, cy) }
	tx0 := card.x + popup_text_x(notif)
	text_w := card.x + card.w - POP_PAD - tx0
	ty := cy
	if notif.summary != "" && f.title != nil {
		layer_text(l, f.title, tx0, ty + f.title.ascent, tx.text_ellipsize(c, f.title, notif.summary, text_w), th.foreground)
		ty += f.title.height + 2
	}
	if f.body != nil {
		for line in wrap_text(c, f.body, notif.body, text_w, 3) {
			layer_text(l, f.body, tx0, ty + f.body.ascent, line, th.secondary)
			ty += f.body.height
		}
	}

	// Action buttons, equal widths across the card.
	actions := visible_actions(notif)
	if len(actions) > 0 {
		by := card.y + card.h - POP_PAD - POP_BUTTON
		k := i32(len(actions))
		gap: i32 = 8
		bw := (card.w - 2 * POP_PAD - (k - 1) * gap) / k
		for a, i in actions {
			r := tx.Rect{card.x + POP_PAD + i32(i) * (bw + gap), by, bw, POP_BUTTON}
			hovered := p.hover_hit == len(p.hits)
			layer_rect(l, r, 10, hovered ? th.hover : th.surface)
			label := tx.text_ellipsize(c, f.body, a.label, bw - 16)
			lw := tx.text_width(c, f.body, label)
			layer_text_v(l, f.body, r.x + (r.w - lw) / 2, r.y, r.h, label, th.foreground)
			append(&p.hits, Hit{r = r, kind = .Action, index = i})
		}
	}
	painter_finish(c, &pt, p.win, &p.pixmap)
}
