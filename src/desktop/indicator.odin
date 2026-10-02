// Visual feedback for the active area (windows/src/Indicator.ps1), in a
// Material style: a pill-shaped toast with the centred caption "AREA N · Name"
// (just the name with linux.indicator.showNumber off), after the area's icon
// when it has one (workspaces.N.icon, a glyph of the bar's Tabler font), that
// slides out from behind the bar (bottom or top of the work area), rests
// for `duration` seconds and slides back. Colours follow the bar theme
// (accent background, accentForeground text).
//
// The toast is a real pill-shaped window (X SHAPE extension) that moves, so
// whatever is behind it stays live: no copy of the screen is ever painted,
// and nothing goes stale while windows below redraw.
package desktop

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
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
@(private) TOAST_ICON_GAP :: 10 // between the icon and the caption

@(private)
Toast_Phase :: enum { Hidden, Entering, Resting, Leaving }

Indicator :: struct {
	font:        ^tx.Font,
	icon_font:   ^tx.Font, // the bar's Tabler font (nil: no icons)
	glyph:       string,   // owned: the area's icon as text, "" = none
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
	tx.font_close(d.c, d.indicator.icon_font)
	d.indicator.font = nil
	d.indicator.icon_font = nil
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
	tx.font_close(d.c, ind.icon_font)
	delete(ind.name)
	delete(ind.text)
	delete(ind.glyph)
	ind^ = {}
}

@(private)
indicator_open_font :: proc(d: ^Daemon) {
	opts := &d.cfg.linux.indicator
	px := points_to_pixels(opts.font_size)
	ok: bool
	d.indicator.font, ok = tx.font_open(d.c, opts.font, px)
	if !ok { d.indicator.font, _ = tx.font_open(d.c, "sans:bold", px) }
	if file := d.cfg.bar.icon_font_file; file != "" && os.exists(file) {
		d.indicator.icon_font, _ = tx.font_open_file(d.c, file, max(8, i32(f32(px) * 1.3 + 0.5)))
	}
}

// "ÁREA 2 · Lazer", or "ÁREA 2" when the area has no name ("AREA 2" in
// English); just "Lazer" without the number.
indicator_caption :: proc(index: int, name: string, lang: config.Language, show_number := true, allocator := context.temp_allocator) -> string {
	word := config.tr(lang, "ÁREA", "AREA")
	if strings.trim_space(name) == "" { return fmt.aprintf("%s %d", word, index, allocator = allocator) }
	if !show_number { return strings.clone(strings.trim_space(name), allocator) }
	return fmt.aprintf("%s %d · %s", word, index, name, allocator = allocator)
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
	ind.text = indicator_caption(index, name, d.cfg.bar.language, d.cfg.linux.indicator.show_number, context.allocator)
	delete(ind.glyph)
	ind.glyph = ""
	if r, has := config.workspace_icon(d.cfg, index); has && tx.font_has_glyph(c, ind.icon_font, r) {
		buf, n := utf8.encode_rune(r)
		ind.glyph = strings.clone(string(buf[:n]))
	}

	font := ind.font
	w := tx.text_width(c, font, ind.text) + 2 * TOAST_PAD_X
	if ind.glyph != "" { w += i32(tx.text_extents(c, ind.icon_font, ind.glyph).width) + TOAST_ICON_GAP }
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

	// Paint the pill once: an opaque pill-shaped window never needs a repaint
	// (only new colours do, indicator_recolor).
	pm := toast_pixmap(d)

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

@(private)
toast_pixmap :: proc(d: ^Daemon) -> xlib.Pixmap {
	ind := &d.indicator
	bg, fg := toast_colors(d)
	cv := tx.canvas_make(ind.w, ind.h)
	defer tx.canvas_destroy(&cv)
	tx.canvas_fill(&cv, bg)
	pm := tx.canvas_to_pixmap(d.c, cv)
	ts := tx.text_surface_make(d.c, xlib.Drawable(pm))
	text_w := tx.text_width(d.c, ind.font, ind.text)
	x := (ind.w - text_w) / 2
	if ind.glyph != "" {
		// The icon's ink, centred on the pill's height, then the caption.
		ext := tx.text_extents(d.c, ind.icon_font, ind.glyph)
		x = (ind.w - (i32(ext.width) + TOAST_ICON_GAP + text_w)) / 2
		tx.draw_text(&ts, ind.icon_font, x + i32(ext.x), (ind.h - i32(ext.height)) / 2 + i32(ext.y), ind.glyph, fg)
		x += i32(ext.width) + TOAST_ICON_GAP
	}
	tx.draw_text_centered_v(&ts, ind.font, x, 0, ind.h, ind.text, fg)
	tx.text_surface_destroy(&ts)
	return pm
}

// New colours while the toast is up (the wallpaper theme's palette arrives a
// moment after the area switch that showed it): paint it again in place.
indicator_recolor :: proc(d: ^Daemon) {
	ind := &d.indicator
	if !ind.visible || ind.window == 0 || ind.font == nil || ind.w <= 0 { return }
	pm := toast_pixmap(d)
	tx.set_background(d.c, ind.window, pm)
	tx.pixmap_free(d.c, ind.pixmap)
	ind.pixmap = pm
	tx.flush(d.c)
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
