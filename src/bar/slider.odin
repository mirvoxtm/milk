// Volume and brightness popups: a small card anchored to the widget with the
// icon (a mute toggle for the volume), a horizontal slider and the
// percentage. Clicking or dragging on the track sets the value live, the
// wheel changes it by 5 %, and so do the arrow keys while the card holds the
// keyboard. Escape, a click outside, a second click on the widget or another
// popup closes it.
package bar

import "core:fmt"
import "core:math"
import xlib "vendor:x11/xlib"
import tx "../tx"

@(private) SLIDER_WIDTH  :: 300
@(private) SLIDER_HEIGHT :: 60
@(private) SLIDER_PAD    :: 12
@(private) SLIDER_BUTTON :: 36 // icon button diameter
@(private) SLIDER_TRACK  :: 6  // track thickness
@(private) SLIDER_THUMB  :: 9  // thumb radius
@(private) SLIDER_STEP   :: 5  // percent per wheel notch / arrow key

Slider_Kind :: enum { Volume, Brightness }

@(private)
Slider_Part :: enum { None, Button, Track }

Slider_Popup :: struct {
	card:       Card,
	kind:       Slider_Kind,
	dragging:   bool,
	drag_value: int,
	hover:      Slider_Part,
	// Layout of the last frame (card coordinates).
	button:     tx.Rect,
	track:      tx.Rect,
	// What the last frame showed: redraw only when it changes.
	shown:      Slider_View,
}

@(private)
Slider_View :: struct {
	value:        int,
	known, muted: bool,
	hover:        Slider_Part,
	dragging:     bool,
}

// ---------------------------------------------------------------------------
// Open / close
// ---------------------------------------------------------------------------
@(private)
slider_available :: proc(b: ^Bar, kind: Slider_Kind) -> bool {
	switch kind {
	case .Volume:     return b.vol.backend != .None
	case .Brightness: return b.bright.present
	}
	return false
}

// Left click on the volume or brightness widget.
@(private)
slider_toggle :: proc(b: ^Bar, kind: Slider_Kind, w: ^Widget) {
	if b.slider.card.open && b.slider.kind == kind {
		slider_close(b)
		return
	}
	close_popups(b)
	if !slider_available(b, kind) {
		// No way to change it here: fall back to the configured command.
		if cmd := command_for(b, WIDGET_IDS[w.kind]); cmd != "" { run_detached(b, cmd) }
		return
	}
	p := &b.slider
	p.kind = kind
	p.dragging = false
	p.hover = .None
	anchor := widget_screen_rect(b, w)
	card_prepare(b, &p.card, card_place(b, anchor.x + anchor.w / 2, .Center, SLIDER_WIDTH, SLIDER_HEIGHT), "milk slider")
	slider_draw(b)
	card_map(b, &p.card, true)
}

slider_close :: proc(b: ^Bar) {
	p := &b.slider
	if !p.card.open { return }
	if p.dragging {
		p.dragging = false
		slider_released(b)
	}
	card_hide(b, &p.card)
}

@(private)
slider_destroy :: proc(b: ^Bar) {
	card_destroy(b, &b.slider.card)
	b.slider = {}
}

// Every loop iteration: follow outside changes (keys, polls, the wheel on the widget).
@(private)
slider_tick :: proc(b: ^Bar) {
	p := &b.slider
	if !p.card.open { return }
	if !slider_available(b, p.kind) {
		slider_close(b)
		return
	}
	if slider_view(b) != p.shown { slider_draw(b) }
}

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------
@(private)
slider_view :: proc(b: ^Bar) -> Slider_View {
	p := &b.slider
	v := Slider_View{hover = p.hover, dragging = p.dragging}
	switch p.kind {
	case .Volume:     v.value, v.known, v.muted = b.vol.percent, b.vol.known, b.vol.muted
	case .Brightness: v.value, v.known = b.bright.percent, b.bright.present
	}
	if p.dragging { v.value, v.known = p.drag_value, true }
	return v
}

@(private)
slider_set :: proc(b: ^Bar, percent: int) {
	switch b.slider.kind {
	case .Volume:     set_volume_percent(b, percent)
	case .Brightness: set_brightness_percent(b, percent)
	}
}

@(private)
slider_step :: proc(b: ^Bar, delta: int) {
	switch b.slider.kind {
	case .Volume:     change_volume(b, delta)
	case .Brightness: change_brightness(b, delta)
	}
}

// The value under a card x on the track.
@(private)
slider_value_at :: proc(b: ^Bar, x: i32) -> int {
	t := b.slider.track
	if t.w <= 0 { return 0 }
	return clamp(int(math.round(f32(x - t.x) * 100 / f32(t.w))), 0, 100)
}

@(private)
slider_drag_to :: proc(b: ^Bar, x: i32) {
	p := &b.slider
	value := slider_value_at(b, x)
	if value == p.drag_value { return }
	p.drag_value = value
	slider_set(b, value)
}

// The drag ended: the widget shows the value that was sent until the next reading.
@(private)
slider_released :: proc(b: ^Bar) {
	if b.slider.kind == .Volume && !b.vol.setting { request_volume_refresh(b) }
	b.dirty = true
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------
@(private)
slider_part_at :: proc(b: ^Bar, x, y: i32) -> Slider_Part {
	p := &b.slider
	if tx.rect_contains(p.button, x, y) { return .Button }
	// The whole height of the card around the track is clickable.
	hit := tx.Rect{p.track.x - SLIDER_THUMB - 4, 0, p.track.w + 2 * SLIDER_THUMB + 8, p.card.rect.h}
	if tx.rect_contains(hit, x, y) { return .Track }
	return .None
}

@(private)
slider_event :: proc(b: ^Bar, ev: ^xlib.XEvent) {
	p := &b.slider
	if !p.card.open { return }
	#partial switch ev.type {
	case .ButtonPress:
		x, y := card_local(&p.card, ev.xbutton.x_root, ev.xbutton.y_root)
		if !card_contains(&p.card, x, y) {
			slider_close(b)
			return
		}
		switch i32(ev.xbutton.button) {
		case 1:
			switch slider_part_at(b, x, y) {
			case .Button:
				if p.kind == .Volume { toggle_mute(b) }
			case .Track:
				p.dragging = true
				p.drag_value = -1
				slider_drag_to(b, x)
			case .None:
			}
		case 4: slider_step(b, SLIDER_STEP)
		case 5: slider_step(b, -SLIDER_STEP)
		}
	case .MotionNotify:
		x, y := card_local(&p.card, ev.xmotion.x_root, ev.xmotion.y_root)
		if p.dragging {
			slider_drag_to(b, x)
		} else {
			p.hover = slider_part_at(b, x, y)
		}
	case .ButtonRelease:
		if p.dragging && i32(ev.xbutton.button) == 1 {
			p.dragging = false
			x, y := card_local(&p.card, ev.xbutton.x_root, ev.xbutton.y_root)
			p.hover = slider_part_at(b, x, y)
			slider_released(b)
		}
	case .LeaveNotify:
		if !p.dragging { p.hover = .None }
	case .KeyPress:
		#partial switch xlib.LookupKeysym(&ev.xkey, 0) {
		case .XK_Escape:          slider_close(b); return
		case .XK_Right, .XK_Up:   slider_step(b, SLIDER_STEP)
		case .XK_Left, .XK_Down:  slider_step(b, -SLIDER_STEP)
		}
	}
	if p.card.open && slider_view(b) != p.shown { slider_draw(b) }
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------
@(private)
slider_draw :: proc(b: ^Bar) {
	p := &b.slider
	c := b.c
	th := &b.theme
	view := slider_view(b)
	p.shown = view
	w, h := p.card.rect.w, p.card.rect.h
	pt := painter_begin(b, w, h)

	// Icon button (the mute toggle for the volume).
	bs := i32(SLIDER_BUTTON)
	p.button = {SLIDER_PAD, (h - bs) / 2, bs, bs}
	button_fill := th.surface
	if p.kind == .Volume && view.hover == .Button { button_fill = tx.color_mix(th.surface, th.muted, 0.35) }
	tx.canvas_fill_circle(&pt.cv, f32(p.button.x) + f32(bs) / 2, f32(p.button.y) + f32(bs) / 2, f32(bs) / 2, button_fill)
	icon: Icon = .Sun
	if p.kind == .Volume { icon = volume_icon(b.vol) }
	paint_icon(&pt, icon, p.button, view.muted ? th.muted : th.foreground)

	// Percentage on the right, in a column wide enough for "100%".
	label := view.known ? fmt.tprintf("%d%%", view.value) : "–"
	column := tx.text_width(c, b.font, "100%")
	label_right := w - SLIDER_PAD - 4
	paint_text(&pt, b.font, label_right - tx.text_width(c, b.font, label), 0, h, label, view.muted ? th.muted : th.foreground)

	// Track: rounded groove, the filled part in the accent colour, a round thumb.
	x0 := p.button.x + bs + 16
	x1 := label_right - column - 16
	p.track = {x0, (h - SLIDER_TRACK) / 2, max(x1 - x0, 10), SLIDER_TRACK}
	fill := view.muted ? th.muted : th.accent
	tx.canvas_fill_rounded_rect(&pt.cv, p.track, f32(SLIDER_TRACK) / 2, tx.color_mix(th.surface, th.muted, 0.35))
	value := view.known ? clamp(view.value, 0, 100) : 0
	thumb_x := f32(p.track.x) + f32(p.track.w) * f32(value) / 100
	thumb_y := f32(p.track.y) + f32(SLIDER_TRACK) / 2
	filled := tx.Rect{p.track.x, p.track.y, i32(thumb_x + 0.5) - p.track.x, SLIDER_TRACK}
	if filled.w > 0 { tx.canvas_fill_rounded_rect(&pt.cv, filled, f32(SLIDER_TRACK) / 2, fill) }
	if view.dragging || view.hover == .Track {
		tx.canvas_fill_circle(&pt.cv, thumb_x, thumb_y, SLIDER_THUMB + 7, tx.color_with_alpha(fill, 40))
	}
	tx.canvas_fill_circle(&pt.cv, thumb_x, thumb_y + 1, SLIDER_THUMB + 1, tx.rgba(0, 0, 0, 45))
	tx.canvas_fill_circle(&pt.cv, thumb_x, thumb_y, SLIDER_THUMB, fill)
	tx.canvas_fill_circle(&pt.cv, thumb_x, thumb_y, 3, tx.color_with_alpha(th.background, 200))

	painter_present(&pt, &p.card)
}
