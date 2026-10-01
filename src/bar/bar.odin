// Package bar: the milk status bar.
//
// A strip along the top (or bottom) of a monitor that reproduces the user's
// Noctalia bar on Xorg: launcher, active window, workspace dots, media, quick
// setting icons, date, clock and session button. Every frame is composed on a
// CPU canvas (a grab of the wallpaper under the bar blended with the theme
// background), uploaded as the window's background pixmap, and text/glyphs
// are drawn on that pixmap with Xft. State comes from EWMH properties, sysfs
// and small helper processes that never block the shared event loop.
//
// Integration: select ROOT_EVENT_MASK on the root window, offer every event
// to `handle_event` (root events are shared: it returns false for them even
// when it used them), poll `poll_fds` next to the X fd and call `handle_fd`
// for the ready ones, then call `tick` every loop iteration and sleep at most
// `next_timeout`.
//
// Popups: the gear opens the quick-settings card, volume and brightness open
// a slider card; one popup at a time. Other panels (notifications, clipboard)
// hook in through `set_click_handler`, `set_badge`, `bar_rect` and
// `close_popups`.
package bar

import "base:runtime"
import "core:log"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import xlib "vendor:x11/xlib"
import tx "../tx"
import config "../config"
import tray "../tray"

ROOT_EVENT_MASK :: xlib.EventMask{.PropertyChange, .SubstructureNotify}

@(private)
WINDOW_EVENT_MASK :: xlib.EventMask{.ButtonPress, .PointerMotion, .LeaveWindow, .Exposure}

POLL_INTERVAL :: 2.0 // seconds between network/bluetooth/volume/brightness/battery polls

Theme :: struct {
	background, foreground, muted, accent, accent_foreground, surface, warning: tx.Color,
	dot_empty: tx.Color,
}

Warning :: enum { Brightness }

Bar :: struct {
	c:               ^tx.Connection,
	cfg:             ^config.Config, // owned by the caller
	allocator:       runtime.Allocator,
	atoms:           Atoms,
	tools:           Tools,
	warned:          bit_set[Warning],
	unsupported:     map[string]struct{}, // widget ids already warned about

	// Window
	win:             xlib.Window,
	rect:            tx.Rect, // the window (screen coordinates)
	body:            tx.Rect, // the visible bar inside it (window coordinates); inset when floating
	overlay:         bool, // override-redirect (dwm) instead of a managed dock
	mapped:          bool,
	started:         bool,
	pixmap:          xlib.Pixmap, // current background
	base:            tx.Canvas,   // wallpaper grab blended with the theme background
	frame:           tx.Canvas,   // scratch canvas for every render
	need_flush:      bool,

	// Look
	theme:           Theme,
	font:            ^tx.Font,
	text_baseline:   i32,
	icons:           Icon_Set,
	launcher:        tx.Image,
	has_launcher:    bool,     // a configured launcher image; otherwise milk's logo
	logo_font:       ^tx.Font, // the Tabler font at the logo's glyph size (nil: "m" in the text font)
	logo_text:       string,   // the logo glyph (points into icons.glyphs or a literal)
	widgets:         [dynamic]Widget,
	settings:        Settings_Popup,
	slider:          Slider_Popup,
	wifi:            Wifi_Menu,
	btm:             Bt_Menu,
	small_font:      ^tx.Font, // second lines in the menus
	popup_wait:      f64,      // seconds until the popups need a tick (-1 = none)
	click_handler:   Click_Handler,
	click_data:      rawptr,
	badges:          [Widget_Kind]int,
	config_path:     string, // milk.json, edited by the settings popup (owned)
	reload_flag:     bool,   // the popup changed milk.json
	hover:           int, // widget under the pointer, -1 = none
	dirty:           bool,

	// State
	ws:              Workspaces_State,
	active:          Active_State,
	tasks:           Tasks_State,
	tray:            Tray_State, // milk tray: the system tray (tray.odin)
	media:           Media_State,
	net:             Network_State,
	bt:              Bluetooth_State,
	bat:             Battery_State,
	bright:          Brightness_State,
	vol:             Volume_State,
	date_text:       string,
	clock_text:      string,

	// Timers
	next_poll:       f64,
	next_clock:      f64,
	occupancy_dirty: bool,
	wm_dirty:        bool, // the window manager (re)started: re-check overlay vs dock

	// Processes
	jobs:            [dynamic]^Job,
	children:        [dynamic]posix.pid_t,
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// Left-click hook for widgets the bar does not handle itself (notifications,
// clipboard, launcher, ...). `anchor` is the widget's rectangle in screen
// coordinates (x/w: the widget, y/h: the visible bar). Return true when the
// click was handled: the bar then skips its own action (the configured
// command). Volume, brightness, settings and the workspace dots never reach it.
Click_Handler :: #type proc(data: rawptr, id: string, anchor: tx.Rect) -> bool

set_click_handler :: proc(b: ^Bar, handler: Click_Handler, data: rawptr) {
	if b == nil { return }
	b.click_handler = handler
	b.click_data = data
	b.dirty = true // hover highlights depend on it
}

// Unread marker on a widget (e.g. "notifications"): a small accent dot on its
// icon while count > 0. Redraws only when the dot appears or disappears.
set_badge :: proc(b: ^Bar, id: string, count: int) {
	if b == nil { return }
	kind, ok := widget_kind(id)
	if !ok { return }
	old := b.badges[kind]
	b.badges[kind] = max(count, 0)
	if (old > 0) != (count > 0) { b.dirty = true }
}

// The visible bar in screen coordinates (the rounded strip when floating).
bar_rect :: proc(b: ^Bar) -> tx.Rect {
	if b == nil { return {} }
	rect, body := b.rect, b.body
	if b.win == 0 { rect, body = compute_geometry(b) }
	return {rect.x + body.x, rect.y + body.y, body.w, body.h}
}

// Close every bar popup: quick settings, sliders, Wi-Fi and Bluetooth menus.
close_popups :: proc(b: ^Bar) {
	if b == nil { return }
	context.allocator = b.allocator
	settings_close(b)
	slider_close(b)
	wifi_close(b)
	bt_close(b)
	if b.need_flush {
		tx.flush(b.c)
		b.need_flush = false
	}
}

// Prepare the bar (fonts, icons, launcher image); no X window yet.
create :: proc(c: ^tx.Connection, cfg: ^config.Config) -> (^Bar, bool) {
	if c == nil || cfg == nil { return nil, false }
	b := new(Bar)
	b.c = c
	b.cfg = cfg
	b.allocator = context.allocator
	b.hover = -1
	b.ws.current = -1
	b.tasks.hover = -1
	b.tasks.pointer_x = -1
	intern_atoms(b)
	detect_tools(b)
	if !apply_config(b) {
		destroy(b)
		return nil, false
	}
	return b, true
}

// Unmap and destroy the window, stop helpers and free everything.
destroy :: proc(b: ^Bar) {
	if b == nil { return }
	context.allocator = b.allocator
	settings_close(b)
	settings_destroy(b)
	slider_close(b)
	slider_destroy(b)
	wifi_close(b)
	wifi_destroy(b)
	bt_close(b)
	bt_destroy(b)
	delete(b.config_path)
	kill_jobs(b)
	b.media.stream = nil
	reap_children(b)
	delete(b.jobs)
	delete(b.children)
	unwatch_active(b)
	clear_active(b)
	tasks_destroy(b)
	tray_destroy(b) // milk tray: hands the XEmbed icons back before the bar window goes
	hide_window(b)
	release_look(b)
	delete(b.widgets)
	tx.canvas_destroy(&b.base)
	tx.canvas_destroy(&b.frame)
	delete(b.ws.occupied)
	delete(b.ws.learned)
	delete(b.media.text)
	delete(b.media.player)
	delete(b.bright.device)
	delete(b.date_text)
	delete(b.clock_text)
	for id in b.unsupported { delete(id) }
	delete(b.unsupported)
	free(b)
}

// Read the initial state, create and map the window and draw the first frame.
start :: proc(b: ^Bar) {
	if b == nil || b.started { return }
	context.allocator = b.allocator
	b.started = true
	now := tx.now()
	refresh_active(b)
	refresh_workspaces(b)
	tasks_update(b)
	b.net = read_network()
	b.bt = read_bluetooth()
	b.bat = read_battery()
	refresh_brightness(b)
	request_volume_refresh(b)
	update_time_texts(b)
	b.next_poll = now + POLL_INTERVAL
	b.next_clock = next_clock_deadline(b, now)
	start_media(b, now)
	if b.cfg.bar.enabled { show_window(b) }
}

// Returns true when the event belonged to the bar alone (its window or the
// watched active window). Root-window events are used but never claimed.
handle_event :: proc(b: ^Bar, ev: ^xlib.XEvent) -> bool {
	if b == nil || !b.started || ev == nil { return false }
	context.allocator = b.allocator
	// milk tray: its menu, the tray manager window, the sockets and the icons.
	if b.tray.t != nil && tray.handle_event(b.tray.t, ev) {
		if b.need_flush {
			tx.flush(b.c)
			b.need_flush = false
		}
		return true
	}
	win := ev.xany.window
	claimed := false
	// A click anywhere else (the desktop, icon cells, other windows) closes the
	// open popup; clicks on the bar are handled below (a widget toggles its own).
	if ev.type == .ButtonPress && popup_open(b) && win != b.win && !is_popup_window(b, win) {
		close_popups(b)
	}
	// Titles, states and areas of the listed windows (shared with the window
	// manager, so never claimed).
	if ev.type == .PropertyNotify && win != b.c.root { tasks_property(b, win, ev.xproperty.atom) }
	// While the slider is dragged the pointer may cross the bar window (same
	// client, so the grab reports it there): keep following it.
	if b.slider.dragging && win != b.slider.card.win && (ev.type == .MotionNotify || ev.type == .ButtonRelease) {
		slider_event(b, ev)
	}
	switch {
	case b.win != 0 && win == b.win:
		handle_bar_event(b, ev)
		claimed = true
	case b.settings.card.win != 0 && win == b.settings.card.win:
		settings_event(b, ev)
		claimed = true
	case b.slider.card.win != 0 && win == b.slider.card.win:
		slider_event(b, ev)
		claimed = true
	case b.wifi.card.win != 0 && win == b.wifi.card.win:
		wifi_event(b, ev)
		claimed = true
	case b.btm.card.win != 0 && win == b.btm.card.win:
		bt_event(b, ev)
		claimed = true
	case win == b.c.root:
		handle_root_event(b, ev)
	case b.active.win != 0 && win == b.active.win && ev.type == .PropertyNotify:
		handle_active_property(b, ev.xproperty.atom)
		claimed = true
	}
	if b.need_flush {
		tx.flush(b.c)
		b.need_flush = false
	}
	return claimed
}

tick :: proc(b: ^Bar, now: f64) {
	if b == nil || !b.started { return }
	context.allocator = b.allocator
	reap_children(b)
	service_jobs(b, now)
	media_tick(b, now)
	if b.tray.t != nil { // milk tray
		tray.tick(b.tray.t, now)
		if tray.take_changed(b.tray.t) { b.dirty = true }
	}
	if now >= b.next_poll {
		poll_sources(b)
		b.next_poll = now + POLL_INTERVAL
	}
	if now >= b.next_clock {
		update_time_texts(b)
		b.next_clock = next_clock_deadline(b, now)
	}
	if b.occupancy_dirty {
		b.occupancy_dirty = false
		if refresh_workspaces(b) { b.dirty = true }
		b.tasks.recheck = true // the current area (or a learned one) may have changed
	}
	if (b.tasks.stale || b.tasks.recheck) && tasks_update(b) { b.dirty = true }
	if b.wm_dirty {
		b.wm_dirty = false
		if b.win != 0 && use_overlay(b) != b.overlay {
			log.info("Bar: the window manager changed; recreating the bar window")
			hide_window(b)
			show_window(b)
		}
	}
	if b.dirty {
		if b.mapped { render(b) } else { b.dirty = false }
	}
	slider_tick(b)
	b.popup_wait = popups_tick(b, now)
	if b.need_flush {
		tx.flush(b.c)
		b.need_flush = false
	}
}

// Seconds until `tick` has work to do (0 = now).
next_timeout :: proc(b: ^Bar, now: f64) -> f64 {
	if b == nil || !b.started { return -1 }
	if (b.dirty && b.mapped) || b.occupancy_dirty || b.wm_dirty || b.tasks.stale || b.tasks.recheck { return 0 }
	deadline := min(b.next_poll, b.next_clock)
	if d := media_deadline(b); d >= 0 { deadline = min(deadline, d) }
	if b.popup_wait >= 0 { deadline = min(deadline, now + b.popup_wait) }
	for job in b.jobs {
		if job.file == nil {
			deadline = min(deadline, now + 0.05) // output done, waiting for the exit
		} else if job.timeout > 0 {
			deadline = min(deadline, job.started + job.timeout)
		}
	}
	if len(b.children) > 0 { deadline = min(deadline, now + 1) }
	if tt := tray.next_timeout(b.tray.t, now); tt >= 0 { deadline = min(deadline, now + tt) } // milk tray
	return max(deadline - now, 0)
}

// Pipes of running helpers (poll them for input/HUP next to the X fd).
poll_fds :: proc(b: ^Bar, allocator := context.temp_allocator) -> []i32 {
	if b == nil { return nil }
	fds := make([dynamic]i32, 0, len(b.jobs) + 1, allocator)
	for job in b.jobs {
		if job.file != nil { append(&fds, job.fd) }
	}
	if fd := tray.poll_fd(b.tray.t); fd >= 0 { append(&fds, fd) } // milk tray: the session bus
	return fds[:]
}

// One of `poll_fds` is readable (or hung up).
handle_fd :: proc(b: ^Bar, fd: i32) {
	if b == nil { return }
	context.allocator = b.allocator
	if b.tray.t != nil && fd == tray.poll_fd(b.tray.t) { // milk tray
		tray.handle_fd(b.tray.t)
		if tray.take_changed(b.tray.t) { b.dirty = true }
		return
	}
	job := find_job(b, fd)
	if job == nil { return }
	read_job(b, job)
	if job.file == nil { service_jobs(b, tx.now()) }
}

// Apply a new configuration (the caller owns `cfg`; the old one must not be used any more).
reload :: proc(b: ^Bar, cfg: ^config.Config) {
	if b == nil || cfg == nil { return }
	context.allocator = b.allocator
	b.cfg = cfg
	detect_tools(b)
	if !apply_config(b) { log.error("Bar: could not apply the new configuration") }
	if !b.started { return }
	now := tx.now()
	stop_media(b)
	start_media(b, now)
	update_time_texts(b)
	b.next_clock = next_clock_deadline(b, now)
	request_volume_refresh(b)
	if !cfg.bar.enabled {
		hide_window(b)
		return
	}
	slider_close(b) // its anchor widget may have moved or gone
	if b.win == 0 || use_overlay(b) != b.overlay {
		hide_window(b)
		show_window(b)
		settings_after_reload(b)
		menus_after_reload(b)
		return
	}
	if r, body := compute_geometry(b); r != b.rect || body != b.body {
		b.rect, b.body = r, body
		tx.move_resize(b.c, b.win, r)
		apply_strut(b)
	}
	update_base(b)
	b.dirty = true
	settings_after_reload(b)
	menus_after_reload(b)
}

// New colours only (the wallpaper theme follows the area on screen): the look
// is rebuilt, the media watcher, the tools found and the geometry stay.
retheme :: proc(b: ^Bar, cfg: ^config.Config) {
	if b == nil || cfg == nil { return }
	context.allocator = b.allocator
	b.cfg = cfg
	if !apply_config(b) { log.error("Bar: could not apply the new colours") }
	if !b.started || b.win == 0 { return }
	slider_close(b)
	update_base(b)
	b.dirty = true
	settings_after_reload(b)
	menus_after_reload(b)
}

window_ids :: proc(b: ^Bar, allocator := context.temp_allocator) -> []xlib.Window {
	if b == nil || b.win == 0 { return nil }
	ids := make([]xlib.Window, 1, allocator)
	ids[0] = b.win
	return ids
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
@(private)
make_theme :: proc(t: config.Bar_Theme) -> Theme {
	th := Theme{
		background        = tx.color_from_hex(t.background, tx.rgb(0xF5, 0xEE, 0xE6)),
		foreground        = tx.color_from_hex(t.foreground, tx.rgb(0x3C, 0x3A, 0x38)),
		muted             = tx.color_from_hex(t.muted, tx.rgb(0xA8, 0x9E, 0x94)),
		accent            = tx.color_from_hex(t.accent, tx.rgb(0x4A, 0x3F, 0x35)),
		accent_foreground = tx.color_from_hex(t.accent_foreground, tx.rgb(0xF5, 0xEE, 0xE6)),
		surface           = tx.color_from_hex(t.surface, tx.rgb(0xE9, 0xE0, 0xD6)),
		warning           = tx.color_from_hex(t.warning, tx.rgb(0xB5, 0x47, 0x3A)),
	}
	th.dot_empty = tx.color_mix(th.muted, th.background, 0.45)
	th.dot_empty.a = 255
	return th
}

// Fonts, icons, launcher image and widget list from the configuration.
@(private)
apply_config :: proc(b: ^Bar) -> bool {
	opts := &b.cfg.bar
	release_look(b)
	b.theme = make_theme(opts.theme)
	font, ok := tx.font_open(b.c, opts.font, i32(opts.font_size))
	if !ok { font, ok = tx.font_open(b.c, "sans", i32(opts.font_size)) }
	if !ok {
		log.error("Bar: no usable text font")
		return false
	}
	b.font = font
	small, sok := tx.font_open(b.c, opts.font, i32(max(9, opts.font_size - 3)))
	b.small_font = sok ? small : nil
	// Centre capitals and digits vertically.
	ext := tx.text_extents(b.c, font, "H")
	b.text_baseline = (i32(opts.height) - i32(ext.height)) / 2 + i32(ext.y)
	resolve_icons(b)
	load_launcher(b)
	build_widgets(b)
	tasks_configure(b)
	tray_configure(b) // milk tray
	b.vol.backend = pick_volume_backend(b)
	b.hover = -1
	b.dirty = true
	return true
}

@(private)
release_look :: proc(b: ^Bar) {
	destroy_icons(b)
	if b.has_launcher { tx.image_destroy(&b.launcher) }
	b.has_launcher = false
	if b.logo_font != nil { tx.font_close(b.c, b.logo_font) }
	b.logo_font = nil
	b.logo_text = ""
	if b.font != nil { tx.font_close(b.c, b.font) }
	b.font = nil
	if b.small_font != nil { tx.font_close(b.c, b.small_font) }
	b.small_font = nil
	clear(&b.widgets)
}

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------
@(private)
is_floating :: proc(b: ^Bar) -> bool { return b.cfg.bar.style == "floating" }

// The window (screen coordinates) and the visible bar inside it (window
// coordinates). "full": one edge-to-edge strip. "floating": the window spans
// the whole reserved strip (margin + height, full monitor width) so that the
// margins can show the wallpaper, the rounded corners and a soft shadow
// without a compositor; the bar body is inset by `margin` from the edges.
@(private)
compute_geometry :: proc(b: ^Bar) -> (rect, body: tx.Rect) {
	mon := tx.monitor_rect(b.c, b.cfg.bar.monitor)
	h := min(i32(b.cfg.bar.height), mon.h)
	bottom := b.cfg.bar.position == "bottom"
	if is_floating(b) {
		m := clamp(i32(b.cfg.bar.margin), 0, max(0, min(mon.h - h, mon.w / 4)))
		strip := h + m
		rect = {mon.x, bottom ? mon.y + mon.h - strip : mon.y, mon.w, strip}
		body = {m, bottom ? 0 : m, mon.w - 2 * m, h}
		return
	}
	rect = {mon.x, bottom ? mon.y + mon.h - h : mon.y, mon.w, h}
	body = {0, 0, mon.w, h}
	return
}

// "auto": override-redirect on dwm, on any WM that does not honour struts (a
// managed dock would be tiled like a normal client there) and while no EWMH
// WM runs yet (dwm started after milk would otherwise adopt the dock).
@(private)
use_overlay :: proc(b: ^Bar) -> bool {
	switch b.cfg.bar.override_redirect {
	case "always": return true
	case "never":  return false
	}
	if strings.has_prefix(strings.to_lower(tx.wm_name(b.c), context.temp_allocator), "dwm") { return true }
	supported := tx.get_atoms(b.c, b.c.root, "_NET_SUPPORTED")
	if len(supported) == 0 { return true }
	return !slice.contains(supported, tx.atom(b.c, "_NET_WM_STRUT_PARTIAL")) &&
	       !slice.contains(supported, tx.atom(b.c, "_NET_WM_STRUT"))
}

// Reserve the bar's edge (honoured by docks; informative for the overlay).
@(private)
apply_strut :: proc(b: ^Bar) {
	if b.win == 0 { return }
	screen := tx.screen_rect(b.c)
	x0, x1 := b.rect.x, b.rect.x + b.rect.w - 1
	if b.cfg.bar.position == "bottom" {
		tx.set_strut(b.c, b.win, 0, screen.h - b.rect.y, x0, x1)
	} else {
		tx.set_strut(b.c, b.win, b.rect.y + b.rect.h, 0, x0, x1)
	}
}

@(private)
show_window :: proc(b: ^Bar) {
	if b.win != 0 { return }
	b.rect, b.body = compute_geometry(b)
	b.overlay = use_overlay(b)
	if b.overlay {
		b.win = tx.create_overlay(b.c, b.rect, WINDOW_EVENT_MASK, "_NET_WM_WINDOW_TYPE_DOCK", "milk bar")
	} else {
		b.win = tx.create_dock(b.c, b.rect, WINDOW_EVENT_MASK, "milk bar")
	}
	apply_strut(b)
	update_base(b)
	b.mapped = true
	if b.tray.t != nil { tray.attach(b.tray.t, b.win) } // milk tray: the sockets move in
	render(b) // background first: no black flash on map
	tx.map_window(b.c, b.win)
	if b.overlay { tx.raise_window(b.c, b.win) }
	tx.flush(b.c)
	log.infof("Bar: %dx%d at %d,%d (%s)", b.rect.w, b.rect.h, b.rect.x, b.rect.y, b.overlay ? "override-redirect" : "dock")
}

@(private)
hide_window :: proc(b: ^Bar) {
	if b.win == 0 { return }
	if b.tray.t != nil { tray.attach(b.tray.t, 0) } // milk tray: park the sockets (and their icons) first
	tx.unmap_window(b.c, b.win)
	tx.destroy_window(b.c, b.win)
	tx.pixmap_free(b.c, b.pixmap)
	b.pixmap = 0
	b.win = 0
	b.mapped = false
	b.hover = -1
	tx.flush(b.c)
}

// The wallpaper under the bar blended with the theme background (solid when
// there is no root pixmap). Floating: the wallpaper stays visible around a
// rounded, shadowed body.
@(private)
update_base :: proc(b: ^Bar) {
	tx.canvas_destroy(&b.base)
	bg := b.theme.background
	alpha := u8(clamp(b.cfg.bar.opacity, 0, 1) * 255 + 0.5)
	grabbed := false
	if pm, ok := tx.root_pixmap(b.c); ok {
		if cv, gok := tx.canvas_grab(b.c, xlib.Drawable(pm), b.rect); gok {
			b.base = cv
			grabbed = true
		}
	}
	if !grabbed {
		b.base = tx.canvas_make(b.rect.w, b.rect.h)
		tx.canvas_fill(&b.base, tx.color_with_alpha(bg, 255))
		alpha = 255
	}
	if is_floating(b) {
		radius := f32(clamp(i32(b.cfg.bar.radius), 0, b.body.h / 2))
		if grabbed { draw_shadow(&b.base, b.body, radius, 1, 4, 22) }
		tx.canvas_fill_rounded_rect(&b.base, b.body, radius, tx.color_with_alpha(bg, alpha))
		tx.canvas_stroke_rounded_rect(&b.base, b.body, radius, 1, tx.color_with_alpha(b.theme.muted, 50))
	} else if grabbed {
		tx.canvas_fill(&b.base, tx.color_with_alpha(bg, alpha))
	}
	b.dirty = true
}

// Open menus follow a reloaded configuration (theme, fonts, bar position).
@(private)
menus_after_reload :: proc(b: ^Bar) {
	if b.wifi.card.open {
		wifi_draw(b)
		tx.raise_window(b.c, b.wifi.card.win)
	}
	if b.btm.card.open {
		bt_draw(b)
		tx.raise_window(b.c, b.btm.card.win)
	}
}

// The widget whose popup is open keeps its highlight.
@(private)
popup_owner :: proc(b: ^Bar, kind: Widget_Kind) -> bool {
	#partial switch kind {
	case .Settings:   return b.settings.card.open
	case .Volume:     return b.slider.card.open && b.slider.kind == .Volume
	case .Brightness: return b.slider.card.open && b.slider.kind == .Brightness
	case .Network:    return b.wifi.card.open
	case .Bluetooth:  return b.btm.card.open
	}
	return false
}

// Soft drop shadow under a rounded rectangle: `layers` expanding translucent
// rings, darkest (alpha `strength`) next to the shape, shifted down by `dy`.
@(private)
draw_shadow :: proc(cv: ^tx.Canvas, r: tx.Rect, radius: f32, dy: i32, layers: int, strength: int) {
	for i in 1 ..= layers {
		s := i32(i)
		alpha := u8(strength * (layers + 1 - i) / layers)
		tx.canvas_fill_rounded_rect(cv, {r.x - s + 1, r.y - s + 1 + dy, r.w + 2 * s - 2, r.h + 2 * s - 2}, radius + f32(s), tx.rgba(0, 0, 0, alpha))
	}
}

@(private)
render :: proc(b: ^Bar) {
	b.dirty = false
	if b.win == 0 || b.font == nil { return }
	if b.base.w != b.rect.w || b.base.h != b.rect.h || len(b.base.px) == 0 { update_base(b); b.dirty = false }
	layout(b)
	if b.frame.w != b.base.w || b.frame.h != b.base.h || len(b.frame.px) != len(b.base.px) {
		tx.canvas_destroy(&b.frame)
		b.frame = tx.canvas_make(b.base.w, b.base.h)
	}
	copy(b.frame.px, b.base.px)
	for &w, i in b.widgets {
		if !w.visible || w.kind == .Spacer { continue }
		draw_widget_shapes(b, &b.frame, &w, i == b.hover || popup_owner(b, w.kind))
	}
	pm := tx.canvas_to_pixmap(b.c, b.frame)
	ts := tx.text_surface_make(b.c, xlib.Drawable(pm))
	for &w in b.widgets {
		if !w.visible || w.kind == .Spacer { continue }
		draw_widget_text(b, &ts, &w)
	}
	tx.text_surface_destroy(&ts)
	for &w in b.widgets {
		if w.visible && b.badges[w.kind] > 0 { draw_badge(b, pm, &w) }
	}
	tx.set_background(b.c, b.win, pm)
	tx.pixmap_free(b.c, b.pixmap)
	b.pixmap = pm
	tray.commit(b.tray.t) // milk tray: XEmbed icons over their slots, on the new background
	tx.flush(b.c)
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------
@(private)
handle_bar_event :: proc(b: ^Bar, ev: ^xlib.XEvent) {
	#partial switch ev.type {
	case .ButtonPress:
		on_button(b, &ev.xbutton)
	case .MotionNotify:
		set_hover(b, hit_widget(b, ev.xmotion.x))
		tasks_pointer(b, ev.xmotion.x)
		tray_pointer(b, ev.xmotion.x)
	case .LeaveNotify:
		set_hover(b, -1)
		tasks_pointer(b, -1)
		tray_pointer(b, -1)
	}
}

@(private)
handle_root_event :: proc(b: ^Bar, ev: ^xlib.XEvent) {
	a := &b.atoms
	#partial switch ev.type {
	case .PropertyNotify:
		switch ev.xproperty.atom {
		case a.active_window:
			if refresh_active(b) { b.dirty = true }
			keep_above(b, 0)
		case a.client_list:
			b.occupancy_dirty = true
			b.tasks.stale = b.tasks.enabled
		case a.current_desktop, a.number_of_desktops, a.desktop_names:
			b.occupancy_dirty = true
		case a.root_pixmap, a.eroot_pixmap:
			if b.win != 0 { update_base(b) }
		case a.wm_check, a.supported:
			b.wm_dirty = true
		}
	case .MapNotify:
		if ev.xmap.window != b.win {
			b.occupancy_dirty = true
			if !ev.xmap.override_redirect { keep_above(b, ev.xmap.window) }
		}
	case .UnmapNotify:
		if ev.xunmap.window != b.win { b.occupancy_dirty = true }
	case .DestroyNotify:
		if ev.xdestroywindow.window == b.active.win { b.active.watching = false }
		tasks_window_destroyed(b, ev.xdestroywindow.window)
		b.occupancy_dirty = true
	case .ConfigureNotify:
		cfg := &ev.xconfigure
		if cfg.window == b.c.root {
			screen_changed(b)
		} else if cfg.window != b.win {
			b.occupancy_dirty = true // dwm hides other tags' clients by moving them
			if cfg.above == b.win && b.win != 0 && !cfg.override_redirect { keep_above(b, cfg.window) }
		}
	}
}

@(private)
handle_active_property :: proc(b: ^Bar, atom: xlib.Atom) {
	a := &b.atoms
	switch atom {
	case a.net_wm_name, a.wm_name:
		if load_active_title(b) { b.dirty = true }
	case a.net_wm_icon:
		load_active_icon(b)
		b.dirty = true
	case a.net_wm_state:
		keep_above(b, 0) // leaving fullscreen: come back on top
	case a.net_wm_desktop:
		b.occupancy_dirty = true
	}
}

// Root geometry changed (RandR): follow the monitor.
@(private)
screen_changed :: proc(b: ^Bar) {
	if b.win == 0 { return }
	r, body := compute_geometry(b)
	if r == b.rect && body == b.body { return }
	close_popups(b)
	b.rect, b.body = r, body
	tx.move_resize(b.c, b.win, r)
	apply_strut(b)
	update_base(b)
	b.need_flush = true
}

// Periodic sources (every POLL_INTERVAL): redraw only when a visible value changes.
@(private)
poll_sources :: proc(b: ^Bar) {
	net := read_network()
	if network_icon(net) != network_icon(b.net) { b.dirty = true }
	b.net = net
	bt := read_bluetooth()
	if bluetooth_icon(bt) != bluetooth_icon(b.bt) { b.dirty = true }
	b.bt = bt
	bat := read_battery()
	if bat != b.bat { b.dirty = true }
	b.bat = bat
	if !b.bright.setting { refresh_brightness(b) }
	request_volume_refresh(b)
	update_time_texts(b) // catches clock jumps and resume from suspend
	b.occupancy_dirty = true
}
