// Visual feedback for the active area (windows/src/Indicator.ps1), in a
// Material style: a pill-shaped toast with the centred caption "AREA N · Name"
// that slides out from behind the bar (bottom or top of the work area), rests
// for `duration` seconds and slides back. Colours follow the bar theme
// (accent background, accentForeground text).
//
// The toast is a real pill-shaped window (X SHAPE extension) that moves, so
// whatever is behind it stays live: no copy of the screen is ever painted,
// and nothing goes stale while windows below redraw.
package desktop

import "core:fmt"
import "core:math"
import "core:strings"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

@(private) TOAST_PAD_X  :: 22
@(private) TOAST_PAD_Y  :: 11
@(private) TOAST_MARGIN :: 18   // gap to the work-area edge
@(private) TOAST_POP    :: 24   // slide distance for the centred position
@(private) TOAST_ENTER  :: 0.26 // seconds at animationScale 1
@(private) TOAST_EXIT   :: 0.20
@(private) TOAST_FRAME  :: 1.0 / 60.0

@(private)
Toast_Phase :: enum { Hidden, Entering, Resting, Leaving }

Indicator :: struct {
	font:        ^tx.Font,
	window:      xlib.Window,
	pixmap:      xlib.Pixmap,
	visible:     bool,
	deadline:    f64,    // next time indicator_tick must run (frame or hide time)
	index:       int,    // what is displayed
	name:        string, // owned
	text:        string, // owned caption
	phase:       Toast_Phase,
	phase_start: f64,
	rest:        [2]i32, // resting position (screen)
	start:       [2]i32, // position before entering / after leaving (screen)
	pos:         [2]i32, // current position
	w, h:        i32,
}

indicator_init :: proc(d: ^Daemon) {
	indicator_open_font(d)
}

indicator_reconfigure :: proc(d: ^Daemon) {
	indicator_hide(d)
	tx.font_close(d.c, d.indicator.font)
	d.indicator.font = nil
	indicator_open_font(d)
}

indicator_destroy :: proc(d: ^Daemon) {
	ind := &d.indicator
	if ind.window != 0 {
		tx.unmap_window(d.c, ind.window)
		tx.destroy_window(d.c, ind.window)
	}
	tx.pixmap_free(d.c, ind.pixmap)
	tx.font_close(d.c, ind.font)
	delete(ind.name)
	delete(ind.text)
	ind^ = {}
}

@(private)
indicator_open_font :: proc(d: ^Daemon) {
	opts := &d.cfg.linux.indicator
	px := points_to_pixels(opts.font_size)
	ok: bool
	d.indicator.font, ok = tx.font_open(d.c, opts.font, px)
	if !ok { d.indicator.font, _ = tx.font_open(d.c, "sans:bold", px) }
}

// "AREA 2 · Lazer", or "AREA 2" when the area has no name.
indicator_caption :: proc(index: int, name: string, allocator := context.temp_allocator) -> string {
	if strings.trim_space(name) == "" { return fmt.aprintf("AREA %d", index, allocator = allocator) }
	return fmt.aprintf("AREA %d · %s", index, name, allocator = allocator)
}

@(private)
toast_colors :: proc(d: ^Daemon) -> (bg, fg: tx.Color) {
	theme := &d.cfg.bar.theme
	return tx.color_from_hex(theme.accent, tx.rgb(0x31, 0x30, 0x33)), tx.color_from_hex(theme.accent_foreground, tx.rgb(0xF4, 0xEF, 0xF4))
}

// The milk bar's window, so the toast can come out from behind it.
@(private)
find_bar_window :: proc(c: ^tx.Connection) -> xlib.Window {
	for w in tx.root_children(c) {
		if tx.window_title(c, w) == "milk bar" { return w }
	}
	return 0
}

// Show (or re-show) the toast for area `index`.
indicator_show :: proc(d: ^Daemon, index: int, name: string) {
	ind := &d.indicator
	c := d.c
	if ind.font == nil { return }
	indicator_hide(d)
	if name != ind.name {
		delete(ind.name)
		ind.name = strings.clone(name)
	}
	ind.index = index
	delete(ind.text)
	ind.text = indicator_caption(index, name, context.allocator)

	font := ind.font
	w := tx.text_width(c, font, ind.text) + 2 * TOAST_PAD_X
	h := font.ascent + font.descent + 2 * TOAST_PAD_Y
	ind.w, ind.h = w, h

	// Work area of the primary monitor: the monitor minus bars and docks.
	mon := tx.monitor_rect(c, "primary")
	area := tx.subtract_bars(c, mon, window_ids(d))
	x := area.x + (area.w - w) / 2
	switch d.cfg.linux.indicator.position {
	case "top":
		ind.rest = {x, area.y + TOAST_MARGIN}
		ind.start = {x, area.y - h} // hidden behind a top bar
	case "center":
		y := area.y + (area.h - h) / 2
		ind.rest = {x, y}
		ind.start = {x, y + TOAST_POP}
	case: // bottom
		ind.rest = {x, area.y + area.h - TOAST_MARGIN - h}
		ind.start = {x, area.y + area.h} // hidden behind a bottom bar
	}

	// Paint the pill once: an opaque pill-shaped window never needs a repaint.
	bg, fg := toast_colors(d)
	cv := tx.canvas_make(w, h)
	defer tx.canvas_destroy(&cv)
	tx.canvas_fill(&cv, bg)
	pm := tx.canvas_to_pixmap(c, cv)
	ts := tx.text_surface_make(c, xlib.Drawable(pm))
	tx.draw_text_centered_v(&ts, font, (w - tx.text_width(c, font, ind.text)) / 2, 0, h, ind.text, fg)
	tx.text_surface_destroy(&ts)

	animated := config.anim_duration(d.cfg, TOAST_ENTER) > 0
	first := animated ? ind.start : ind.rest
	rect := tx.Rect{first.x, first.y, w, h}
	if ind.window == 0 {
		ind.window = tx.create_overlay(c, rect, {.ButtonPress}, "_NET_WM_WINDOW_TYPE_NOTIFICATION", "milk indicator")
	} else {
		tx.move_resize(c, ind.window, rect)
	}
	tx.shape_rounded(c, ind.window, w, h, f32(h) / 2)
	tx.set_background(c, ind.window, pm)
	tx.pixmap_free(c, ind.pixmap)
	ind.pixmap = pm
	ind.pos = first

	tx.map_window(c, ind.window)
	tx.raise_window(c, ind.window)
	// Slide out from behind the bar: keep the toast just below it.
	if bar := find_bar_window(c); bar != 0 {
		wc: xlib.XWindowChanges
		wc.sibling = bar
		wc.stack_mode = .Below
		xlib.ConfigureWindow(c.dpy, ind.window, {.CWSibling, .CWStackMode}, &wc)
	}
	ind.visible = true
	now := tx.now()
	if animated {
		ind.phase = .Entering
		ind.phase_start = now
		ind.deadline = now + TOAST_FRAME
	} else {
		ind.phase = .Resting
		ind.deadline = now + d.cfg.linux.indicator.duration
	}
	tx.flush(c)
}

// The wallpaper changed under the toast: nothing to repaint (it is opaque).
indicator_refresh :: proc(d: ^Daemon) {}

// Hide at once (area switch, click, reload).
indicator_hide :: proc(d: ^Daemon) {
	ind := &d.indicator
	if ind.visible && ind.window != 0 { tx.unmap_window(d.c, ind.window) }
	ind.visible = false
	ind.phase = .Hidden
}

indicator_tick :: proc(d: ^Daemon, now: f64) {
	ind := &d.indicator
	if !ind.visible || now < ind.deadline { return }
	switch ind.phase {
	case .Hidden:
		return
	case .Entering:
		t := (now - ind.phase_start) / config.anim_duration(d.cfg, TOAST_ENTER)
		if t >= 1 {
			toast_move(d, ind.rest)
			ind.phase = .Resting
			ind.deadline = now + d.cfg.linux.indicator.duration
		} else {
			toast_move(d, toast_lerp(ind.start, ind.rest, 1 - math.pow(1 - t, 3))) // decelerate
			ind.deadline = now + TOAST_FRAME
		}
	case .Resting:
		if config.anim_duration(d.cfg, TOAST_EXIT) <= 0 {
			indicator_hide(d)
		} else {
			ind.phase = .Leaving
			ind.phase_start = now
			ind.deadline = now + TOAST_FRAME
		}
	case .Leaving:
		t := (now - ind.phase_start) / config.anim_duration(d.cfg, TOAST_EXIT)
		if t >= 1 {
			indicator_hide(d)
		} else {
			toast_move(d, toast_lerp(ind.rest, ind.start, t * t * t)) // accelerate
			ind.deadline = now + TOAST_FRAME
		}
	}
	tx.flush(d.c)
}

@(private)
toast_move :: proc(d: ^Daemon, p: [2]i32) {
	ind := &d.indicator
	if p == ind.pos { return }
	xlib.MoveWindow(d.c.dpy, ind.window, p.x, p.y)
	ind.pos = p
}

@(private)
toast_lerp :: proc(a, b: [2]i32, e: f64) -> [2]i32 {
	return {a.x + i32(math.round(f64(b.x - a.x) * e)), a.y + i32(math.round(f64(b.y - a.y) * e))}
}
