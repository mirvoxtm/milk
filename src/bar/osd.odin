// The volume/brightness pop-up (OSD): a pill near the bottom centre of the
// screen (clear of the bar; "osd.position" can put it in the centre or at the
// top) with the icon, a progress bar and the percentage, in the theme
// colours. The media keys reach it through `media_key` (the window manager
// hands them to the main loop): the bar changes the volume or the brightness
// with its usual helpers and shows the value at once; the pop-up follows the
// real value when the helper reports it, updates in place while the keys are
// pressed and goes away OSD_TIME seconds after the last press.
//
// It is an override-redirect window that never takes input (empty input
// shape: clicks go to whatever is below) and is shown over fullscreen
// windows too, like other desktops do: whoever presses a volume key during a
// video wants to see the level.
package bar

import "core:fmt"
import "core:math"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

@(private) OSD_WIDTH  :: 304
@(private) OSD_HEIGHT :: 52
@(private) OSD_PAD    :: 18
@(private) OSD_ICON   :: 26  // icon box
@(private) OSD_TRACK  :: 6   // progress bar thickness
@(private) OSD_MARGIN :: 64  // from the bar (or the screen edge); clear of the area toast
@(private) OSD_TIME   :: 1.5 // seconds on screen after the last change
@(private) OSD_ENTER  :: 0.16
@(private) OSD_EXIT   :: 0.18
@(private) OSD_RISE   :: 14  // pixels travelled while appearing and leaving
@(private) OSD_FRAME  :: 1.0 / 60

OSD_Kind :: enum { Volume, Brightness }

@(private)
OSD_Phase :: enum { Hidden, Entering, Resting, Leaving }

@(private)
OSD_View :: struct {
	kind:         OSD_Kind,
	value:        int,
	known, muted: bool,
}

OSD_Popup :: struct {
	card:        Card,  // window and pixmap (never grabs: see osd_show)
	kind:        OSD_Kind,
	phase:       OSD_Phase,
	phase_start: f64,
	hide_at:     f64,
	rest_y:      i32,   // resting y; card.y is the current one
	shown:       OSD_View,
}

foreign import xext_osd "system:Xext"
@(default_calling_convention="c", private)
foreign xext_osd {
	@(link_name="XShapeCombineRectangles")
	osd_shape_rectangles :: proc(dpy: ^xlib.Display, dest: xlib.Window, dest_kind: i32, x_off, y_off: i32,
	                             rects: [^]xlib.XRectangle, n: i32, op: i32, ordering: i32) ---
}
@(private) SHAPE_INPUT :: 2

// A media key from the window manager: "volume-up", "volume-down", "mute",
// "brightness-up" or "brightness-down". Changes the value with the bar's own
// helpers and shows the pop-up (osd.enabled). Returns false when the bar
// cannot do it (no volume tool, no backlight): the caller falls back to
// contrib/milk-keys.
media_key :: proc(b: ^Bar, action: string) -> bool {
	if b == nil { return false }
	context.allocator = b.allocator
	switch action {
	case "volume-up", "volume-down", "mute":
		if b.vol.backend == .None { return false }
		switch action {
		case "volume-up":
			if b.vol.known && b.vol.muted { set_mute(b, false) } // raising the volume unmutes it
			change_volume(b, SLIDER_STEP)
		case "volume-down":
			change_volume(b, -SLIDER_STEP)
		case "mute":
			toggle_mute(b)
		}
		if !b.vol.known { request_volume_refresh(b) }
		osd_show(b, .Volume)
	case "brightness-up", "brightness-down":
		if !b.bright.present { refresh_brightness(b) }
		if !b.bright.present { return false }
		change_brightness(b, action == "brightness-up" ? SLIDER_STEP : -SLIDER_STEP)
		osd_show(b, .Brightness)
	case:
		return false
	}
	if b.need_flush {
		tx.flush(b.c)
		b.need_flush = false
	}
	return true
}

// Mute or unmute (the mute key toggles; raising the volume unmutes).
@(private)
set_mute :: proc(b: ^Bar, muted: bool) {
	v := &b.vol
	argv: []string
	switch v.backend {
	case .Wpctl:  argv = {"wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", muted ? "1" : "0"}
	case .Pactl:  argv = {"pactl", "set-sink-mute", "@DEFAULT_SINK@", muted ? "1" : "0"}
	case .Amixer: argv = {"amixer", "-q", "set", "Master", muted ? "mute" : "unmute"}
	case .None:   return
	}
	start_job(b, .Volume_Change, argv, false)
	if v.known && v.muted != muted {
		v.muted = muted
		b.dirty = true
	}
}

// Where the pop-up rests: centred on the bar's monitor, OSD_MARGIN away from
// the bar (or the edge) at the bottom or the top, or in the middle.
@(private)
osd_rect :: proc(b: ^Bar) -> tx.Rect {
	mon := tx.monitor_rect(b.c, b.cfg.bar.monitor)
	area := mon
	if b.win != 0 && b.mapped {
		bar := bar_rect(b)
		if b.cfg.bar.position == "bottom" {
			area.h = max(bar.y - area.y, OSD_HEIGHT)
		} else {
			cut := clamp(bar.y + bar.h - area.y, 0, area.h - OSD_HEIGHT)
			area.y += cut
			area.h -= cut
		}
	}
	w, h := i32(OSD_WIDTH), i32(OSD_HEIGHT)
	x := area.x + (area.w - w) / 2
	y: i32
	switch b.cfg.osd.position {
	case "top":    y = area.y + OSD_MARGIN
	case "center": y = area.y + (area.h - h) / 2
	case:          y = area.y + area.h - OSD_MARGIN - h
	}
	return {x, clamp(y, mon.y, mon.y + mon.h - h), w, h}
}

// Show the pop-up for `kind` (or update it in place) and restart its timer.
@(private)
osd_show :: proc(b: ^Bar, kind: OSD_Kind) {
	if !b.cfg.osd.enabled || b.font == nil { return }
	o := &b.osd
	c := b.c
	now := tx.now()
	o.kind = kind
	o.hide_at = now + OSD_TIME
	rect := osd_rect(b)
	o.rest_y = rect.y
	if o.card.win == 0 {
		o.card.win = tx.create_overlay(c, rect, {}, "_NET_WM_WINDOW_TYPE_NOTIFICATION", "milk osd")
		// No input region: clicks fall through to the window below.
		osd_shape_rectangles(c.dpy, o.card.win, SHAPE_INPUT, 0, 0, nil, 0, 0, 0)
	}
	if o.card.shape_w != rect.w || o.card.shape_h != rect.h {
		tx.shape_rounded(c, o.card.win, rect.w, rect.h, f32(rect.h) / 2)
		o.card.shape_w, o.card.shape_h = rect.w, rect.h
	}
	o.card.rect = rect
	osd_draw(b)
	switch o.phase {
	case .Hidden:
		enter := config.anim_duration(b.cfg, OSD_ENTER)
		if enter > 0.001 {
			o.phase = .Entering
			o.phase_start = now
			o.card.y = rect.y + osd_offset(b)
		} else {
			o.phase = .Resting
			o.card.y = rect.y
		}
		tx.move_resize(c, o.card.win, {rect.x, o.card.y, rect.w, rect.h})
		tx.map_window(c, o.card.win)
	case .Leaving:
		o.phase = .Resting // a new press while it was going: back up at once
		o.card.y = rect.y
		tx.move_resize(c, o.card.win, rect)
	case .Entering, .Resting:
		if o.phase == .Resting && o.card.y != rect.y {
			o.card.y = rect.y
			tx.move_resize(c, o.card.win, rect)
		}
	}
	tx.raise_window(c, o.card.win) // above fullscreen windows and the bar's popups
	o.card.open = true
	b.need_flush = true
}

// Pixels below (bottom, centre) or above (top) the resting place where the
// pop-up starts and ends its movement: it comes out of the screen edge side.
@(private)
osd_offset :: proc(b: ^Bar) -> i32 {
	return b.cfg.osd.position == "top" ? -OSD_RISE : OSD_RISE
}

@(private)
osd_close :: proc(b: ^Bar) {
	o := &b.osd
	if o.phase == .Hidden { return }
	if o.card.win != 0 { tx.unmap_window(b.c, o.card.win) }
	o.phase = .Hidden
	o.card.open = false
	b.need_flush = true
}

@(private)
osd_destroy :: proc(b: ^Bar) {
	osd_close(b)
	card_destroy(b, &b.osd.card)
	b.osd = {}
}

// Animate, follow the value, hide when the time is up; returns the seconds
// until the next call is needed (-1 = none).
@(private)
osd_tick :: proc(b: ^Bar, now: f64) -> f64 {
	o := &b.osd
	if o.phase == .Hidden { return -1 }
	if !b.cfg.osd.enabled {
		osd_close(b)
		return -1
	}
	if osd_view(b) != o.shown { osd_draw(b) }
	from := o.rest_y + osd_offset(b)
	switch o.phase {
	case .Hidden:
		return -1
	case .Entering:
		t := (now - o.phase_start) / max(config.anim_duration(b.cfg, OSD_ENTER), 0.001)
		if t >= 1 {
			o.phase = .Resting
			osd_move(b, o.rest_y)
		} else {
			osd_move(b, from + i32(math.round(f64(o.rest_y - from) * (1 - math.pow(1 - t, 3)))))
			return OSD_FRAME
		}
	case .Resting:
		if now >= o.hide_at {
			if config.anim_duration(b.cfg, OSD_EXIT) <= 0.001 {
				osd_close(b)
				return -1
			}
			o.phase = .Leaving
			o.phase_start = now
			return OSD_FRAME
		}
	case .Leaving:
		t := (now - o.phase_start) / max(config.anim_duration(b.cfg, OSD_EXIT), 0.001)
		if t >= 1 {
			osd_close(b)
			return -1
		}
		osd_move(b, o.rest_y + i32(math.round(f64(from - o.rest_y) * t * t)))
		return OSD_FRAME
	}
	return max(o.hide_at - now, 0)
}

@(private)
osd_move :: proc(b: ^Bar, y: i32) {
	o := &b.osd
	if y == o.card.y { return }
	o.card.y = y
	xlib.MoveWindow(b.c.dpy, o.card.win, o.card.rect.x, y)
	b.need_flush = true
}

@(private)
osd_view :: proc(b: ^Bar) -> OSD_View {
	o := &b.osd
	v := OSD_View{kind = o.kind}
	switch o.kind {
	case .Volume:     v.value, v.known, v.muted = b.vol.percent, b.vol.known, b.vol.muted
	case .Brightness: v.value, v.known = b.bright.percent, b.bright.present
	}
	return v
}

// The pill: icon, progress bar and percentage (muted: greyed, empty bar).
@(private)
osd_draw :: proc(b: ^Bar) {
	o := &b.osd
	th := &b.theme
	view := osd_view(b)
	o.shown = view
	w, h := o.card.rect.w, o.card.rect.h
	pt := painter_begin(b, w, h, false)
	tx.canvas_stroke_rounded_rect(&pt.cv, {0, 0, w, h}, f32(h) / 2, 1, tx.color_with_alpha(th.muted, 90))

	icon: Icon = .Sun
	if view.kind == .Volume { icon = volume_icon(b.vol) }
	fg := view.muted ? th.muted : th.foreground
	paint_icon(&pt, icon, {OSD_PAD, 0, OSD_ICON, h}, fg)

	label := view.known ? fmt.tprintf("%d%%", clamp(view.value, 0, 999)) : "–"
	column := tx.text_width(b.c, b.font, "100%")
	right := w - OSD_PAD - 2
	paint_text(&pt, b.font, right - tx.text_width(b.c, b.font, label), 0, h, label, fg)

	x0 := i32(OSD_PAD + OSD_ICON + 14)
	x1 := right - column - 14
	track := tx.Rect{x0, (h - OSD_TRACK) / 2, max(x1 - x0, 10), OSD_TRACK}
	tx.canvas_fill_rounded_rect(&pt.cv, track, f32(OSD_TRACK) / 2, tx.color_mix(th.surface, th.muted, 0.35))
	value := view.known ? clamp(view.value, 0, 100) : 0
	fill_w := i32(math.round(f32(track.w) * f32(value) / 100))
	if fill_w > 0 && !view.muted {
		tx.canvas_fill_rounded_rect(&pt.cv, {track.x, track.y, max(fill_w, OSD_TRACK), OSD_TRACK}, f32(OSD_TRACK) / 2, th.accent)
	} else if fill_w > 0 {
		tx.canvas_fill_rounded_rect(&pt.cv, {track.x, track.y, max(fill_w, OSD_TRACK), OSD_TRACK}, f32(OSD_TRACK) / 2, tx.color_with_alpha(th.muted, 160))
	}
	painter_present(&pt, &o.card)
}
