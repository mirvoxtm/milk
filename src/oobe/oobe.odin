// Package oobe: milk's first-run setup wizard and its settings app.
//
// On a fresh install (no <runtime>/.setup-done) main runs `run` before the
// window manager starts: a full-screen, mouse-driven card in the milk look
// that lets the user pick the colour theme (light or dark), the keyboard
// layout, the wallpapers (one for every area or one per area) and the bar
// style. The wizard owns its event loop on the caller's X connection; when
// the user finishes, the choices are written into milk.json (and the
// wallpapers copied into the runtime folder), the marker file is created and
// control returns to main, which then starts the desktop as usual.
//
// `run_settings` (settings.odin) shows the same widgets in a normal window
// with a sidebar, for `milk settings`: every change is written to milk.json
// at once and the running instance is asked to reload.
package oobe

import "base:runtime"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

MARKER_NAME :: ".setup-done"

// Next to milk.json: install.sh leaves it so that the wizard opens again after
// a (re)installation, even when the runtime folder says it already ran.
PENDING_NAME :: ".setup-pending"

// Environment override for the Alacritty file whose import is re-pointed at
// the chosen theme (tests use a copy; the default is ~/.config/alacritty/milk.toml).
ALACRITTY_ENV :: "MILK_ALACRITTY_CONFIG"

// Shown on the settings' About page; main may set it to its own version.
app_version := "1.1.0"

@(private) Page :: enum { Welcome, Theme, Keyboard, Wallpaper, Bar, Windows, Summary }

@(private) Mode :: enum { Wizard, Settings }

@(private) State :: enum { Running, Finished, Skipped }

@(private)
Action :: enum {
	None, Next, Back, Skip, Goto_Page,
	Theme, Variant,
	Kb_Search, Kb_Layout, Kb_Variant, Kb_Test,
	Wp_Mode, Wp_Area, Wp_Tile,
	Bar_Choice,
	// Settings app
	Wm_Choice, Di_Choice, // wizard: tiling/floating, desktop icons
	Section, Step, Toggle, Choice, Text_Field, Rerun_Wizard, Open_Config, Fx_Open, Win_Tab,
	Sc_Add, Sc_Edit, Sc_Delete, Sc_Capture, Sc_Kind, Sc_App, Sc_Save, Sc_Cancel, Sc_Builtin, Sc_Action,
	Th_New, Th_Edit, Th_Slot, Th_Variant, Th_Slider, Th_Swatch, Th_Save, Th_Cancel, Th_Delete, Th_Scheme,
	Bar_Tab, Bar_Preset, Lw_Select, Lw_Move, Lw_Remove, Lw_Add,
	Language,
}

@(private) Scroll_Id :: enum { None, Layouts, Variants, Wallpapers, Shortcuts, Apps, Actions, Themes, Zone_Start, Zone_Center, Zone_End, Zone_Avail }

@(private) Field :: enum { None, Search, Test, Text }

// A clickable rectangle of the last frame (window coordinates). `clip` limits
// it to the visible part of a scrolled list.
@(private)
Hit :: struct {
	r:      tx.Rect,
	clip:   tx.Rect,
	action: Action,
	arg:    int,
}

@(private)
Scroll_Area :: struct {
	r:   tx.Rect,
	id:  Scroll_Id,
	max: i32, // largest scroll offset
}

// Text is drawn with Xft after the canvas is uploaded.
@(private)
Text_Item :: struct {
	x, y, h: i32, // vertically centred in [y, y + h)
	s:       string,
	font:    ^tx.Font,
	color:   tx.Color,
	clip:    tx.Rect,
}

@(private)
Wizard :: struct {
	c:            ^tx.Connection,
	cfg:          ^config.Config,
	allocator:    runtime.Allocator,
	config_path:  string,
	runtime_root: string,
	lang:         config.Language, // the language of the labels
	locale_index: int,             // the bar.locale choice: an index into config.LANGUAGE_CODES
	state:        State,
	mode:         Mode,

	win:        xlib.Window,
	cursor:     xlib.Cursor,
	pixmap:     xlib.Pixmap,
	screen:     tx.Rect, // the window, screen coordinates
	monitor:    tx.Rect, // the primary monitor (aspect ratio of the previews)
	card:       tx.Rect, // window coordinates
	base:       tx.Canvas, // backdrop + card, rebuilt when the theme or backdrop image changes
	base_image: int,     // candidate the backdrop was built from (-1 = none)
	base_dirty: bool,
	dirty:      bool,
	started:    bool,    // the first real frame is up and the slow work has begun
	anim_start: f64,
	anim_start_run: f64, // when run/run_settings was entered
	last_frame: f64,

	f_title, f_h2, f_body, f_small, f_tiny: ^tx.Font,
	f_icon, f_icon_small, f_icon_big:        ^tx.Font,

	theme:   Theme,
	page:    Page,
	hits:    [dynamic]Hit,
	scrolls: [dynamic]Scroll_Area,
	texts:   [dynamic]Text_Item, // current frame only (temp allocator)
	hover:   Hit,
	pointer: [2]i32,
	focus:   Field,

	// Choices
	theme_index:  int,          // THEME_PRESETS index, len(THEME_PRESETS) + index into customs, or WALLPAPER_INDEX
	pal:          Palette_View, // the wallpaper theme (wallpaper_theme.odin)
	dark:         bool,
	customs:      [dynamic]User_Theme, // appearance.customThemes
	scroll_themes: i32,
	bar_top:      bool,
	bar_floating: bool,
	wm_floating:  bool, // wm.mode
	desktop_icons: bool, // linux.desktopIcons.enabled
	areas:        [dynamic]int, // workspace numbers from milk.json, sorted
	wp_per_area:  bool,
	wp_tab:       int,          // index into areas
	wp_single:    int,          // candidate index, -1 = no wallpaper
	wp_choice:    [dynamic]int, // per area: candidate index, -1 = no wallpaper
	scroll_wp:    i32,

	kb:     Keyboard,
	thumbs: Thumbs,
	input:    tx.Input, // input context: dead keys and compose in text fields
	input_on: bool,     // the input context has the focus
	set:    Settings, // settings app state
}

// True on a fresh install (the wizard has never been completed or skipped)
// and after install.sh ran.
needed :: proc(runtime_root, config_path: string) -> bool {
	path, _ := filepath.join({runtime_root, MARKER_NAME}, context.temp_allocator)
	return !os.exists(path) || os.exists(pending_path(config_path))
}

@(private)
pending_path :: proc(config_path: string) -> string {
	path, _ := filepath.join({filepath.dir(config_path), PENDING_NAME}, context.temp_allocator)
	return path
}

// Show the wizard and block until the user finishes or skips it. Returns true
// when the choices were written (milk.json, wallpapers, terminal theme,
// marker); false when the user skipped (the marker is still created) or on an
// error (logged; nothing is marked, so the wizard returns next time).
run :: proc(c: ^tx.Connection, config_path: string, runtime_root: string) -> bool {
	if c == nil {
		log.error("Setup: no X connection")
		return false
	}
	cfg, err := config.load(config_path)
	if err != "" {
		log.errorf("Setup: cannot load %s: %s", config_path, err)
		delete(err)
		return false
	}
	defer config.destroy(cfg)

	// A private scratch arena for each frame, so that the caller's temp
	// allocations survive our loop.
	arena: virtual.Arena
	if aerr := virtual.arena_init_growing(&arena); aerr != nil {
		log.errorf("Setup: out of memory (%v)", aerr)
		return false
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)

	w := new(Wizard)
	defer free(w)
	wizard_setup(w, c, cfg, config_path, runtime_root, .Wizard)
	defer wizard_destroy(w)

	if !wizard_init(w) { return false }
	log.info("Setup: first-run wizard shown")
	wizard_loop(w)
	close_window(w)
	thumbs_stop(w)

	switch w.state {
	case .Running, .Skipped:
		keyboard_restore(w)
		write_marker(w)
		log.info("Setup: skipped; keeping the current configuration")
		return false
	case .Finished:
		ok := apply_choices(w)
		if ok {
			write_marker(w)
			log.info("Setup: choices saved")
		}
		return ok
	}
	return false
}

// ---------------------------------------------------------------------------
// Setup and teardown
// ---------------------------------------------------------------------------
@(private)
wizard_setup :: proc(w: ^Wizard, c: ^tx.Connection, cfg: ^config.Config, config_path, runtime_root: string, mode: Mode) {
	w.anim_start_run = tx.now()
	w.c = c
	w.cfg = cfg
	w.mode = mode
	w.allocator = context.allocator
	w.config_path = strings.clone(config_path)
	w.runtime_root = strings.clone(runtime_root)
	w.lang = cfg.bar.language
	w.locale_index = locale_choice(cfg.bar.locale)
	w.base_image = -2
	w.wp_single = -1

	// Choices start from the current configuration.
	for p, i in config.THEME_PRESETS { if p.name == cfg.appearance.theme { w.theme_index = i } }
	if cfg.appearance.theme == config.WALLPAPER_THEME { w.theme_index = WALLPAPER_INDEX }
	w.dark = cfg.appearance.variant == "dark"
	palette_view_init(w)
	themes_load(w)
	for t, i in w.customs {
		if t.name == cfg.appearance.theme {
			w.theme_index = len(config.THEME_PRESETS) + i
			w.dark = t.dark
		}
	}
	w.bar_top = cfg.bar.position != "bottom"
	w.bar_floating = cfg.bar.style == "floating"
	w.wm_floating = cfg.wm.mode == "floating"
	w.desktop_icons = cfg.linux.desktop_icons.enabled
	// Every area the window manager has (one per tag, 9 by default), plus any
	// other area milk.json configures.
	for n in 1 ..= max(cfg.wm.tag_count, 1) { append(&w.areas, n) }
	for n, _ in cfg.workspaces {
		known := false
		for a in w.areas { if a == n { known = true; break } }
		if !known { append(&w.areas, n) }
	}
	sort_ints(w.areas[:])
	resize(&w.wp_choice, len(w.areas))
	for &v in w.wp_choice { v = -1 }
	w.theme = current_theme(w)
	w.monitor = tx.monitor_rect(c, "primary")
}

@(private)
wizard_init :: proc(w: ^Wizard) -> bool {
	c := w.c
	// The window covers the primary monitor. It is mapped at once with a
	// splash (logo and spinner, no text: fonts are not open yet); the pages
	// replace it as soon as they are drawn.
	w.screen = w.monitor
	sw, sh := w.screen.w, w.screen.h
	margin := clamp(min(sw, sh) / 22, 14, 56)
	cw := min(sw - 2 * margin, 1180)
	ch := min(sh - 2 * margin, 800)
	w.card = {(sw - cw) / 2, (sh - ch) / 2, cw, ch}

	mask := xlib.EventMask{.ButtonPress, .PointerMotion, .LeaveWindow, .KeyPress, .Exposure, .StructureNotify}
	w.win = tx.create_overlay(c, w.screen, mask, "_NET_WM_WINDOW_TYPE_SPLASH", "milk setup")
	w.input = tx.input_open(c, w.win)
	w.cursor = xlib.CreateFontCursor(c.dpy, .XC_left_ptr)
	xlib.DefineCursor(c.dpy, w.win, w.cursor)
	show_splash(w)
	tx.map_window(c, w.win)
	tx.raise_window(c, w.win)
	tx.flush(c)
	log.debugf("Setup: splash mapped %.0f ms after start", (tx.now() - w.anim_start_run) * 1000)

	if !open_fonts(w) {
		log.error("Setup: no usable font")
		return false
	}
	keyboard_init(w)
	w.base_dirty = true
	w.dirty = true
	w.anim_start = tx.now()
	return true
}

@(private)
close_window :: proc(w: ^Wizard) {
	c := w.c
	tx.input_close(&w.input)
	w.input_on = false
	if w.win != 0 {
		tx.unmap_window(c, w.win)
		tx.destroy_window(c, w.win)
		w.win = 0
		if w.mode == .Wizard {
			xlib.SetInputFocus(c.dpy, xlib.Window(1), .RevertToPointerRoot, xlib.CurrentTime) // PointerRoot
		}
	}
	if w.cursor != 0 {
		xlib.FreeCursor(c.dpy, w.cursor)
		w.cursor = 0
	}
	tx.pixmap_free(c, w.pixmap)
	w.pixmap = 0
	tx.sync(c)
}

@(private)
wizard_destroy :: proc(w: ^Wizard) {
	close_window(w)
	thumbs_destroy(w)
	keyboard_destroy(w)
	settings_destroy(w)
	themes_destroy(w)
	palette_view_destroy(w)
	close_fonts(w)
	tx.canvas_destroy(&w.base)
	delete(w.hits)
	delete(w.scrolls)
	delete(w.areas)
	delete(w.wp_choice)
	delete(w.config_path)
	delete(w.runtime_root)
}

@(private)
sort_ints :: proc(a: []int) {
	for i in 1 ..< len(a) {
		for j := i; j > 0 && a[j] < a[j - 1]; j -= 1 { a[j], a[j - 1] = a[j - 1], a[j] }
	}
}

// The wallpaper list is built after the first frame is on screen.
@(private)
start_background_work :: proc(w: ^Wizard) {
	if w.started { return }
	w.started = true
	log.debugf("Setup: first frame %.0f ms after start", (tx.now() - w.anim_start_run) * 1000)
	thumbs_start(w)
	wallpaper_preselect(w)
	w.dirty = true
}

// ---------------------------------------------------------------------------
// Event loop
// ---------------------------------------------------------------------------
@(private) FRAME :: 1.0 / 30.0

// Loading placeholders animate while thumbnails are on the way.
@(private)
animating :: proc(w: ^Wizard) -> bool {
	if config.anim_duration(w.cfg, 1) <= 0 { return false }
	if !w.started || w.thumbs.pending > 0 { return shows_thumbnails(w) }
	return false
}

@(private)
wizard_loop :: proc(w: ^Wizard) {
	c := w.c
	for w.state == .Running {
		for tx.pending(c) > 0 && w.state == .Running {
			ev: xlib.XEvent
			tx.next_event(c, &ev)
			if tx.input_filter(&ev) { continue } // a dead key waiting for its letter
			handle_event(w, &ev)
			sync_input_focus(w)
		}
		if w.state != .Running { break }
		now := tx.now()
		if thumbs_poll(w) { w.dirty = true }
		if w.mode == .Settings { settings_tick(w, now) }
		if animating(w) && now - w.last_frame >= FRAME { w.dirty = true }
		if w.dirty || w.base_dirty {
			render(w)
			w.last_frame = now
		}
		if !w.started { start_background_work(w) }
		free_all(context.temp_allocator)
		if tx.pending(c) > 0 { continue }

		timeout := -1.0
		if thumbs_busy(w) { timeout = 0.06 }
		if animating(w) { timeout = max(FRAME - (tx.now() - w.last_frame), 0.005) }
		if w.mode == .Settings {
			if st := settings_timeout(w, tx.now()); st >= 0 && (timeout < 0 || st < timeout) { timeout = st }
		}
		ms: i32 = timeout < 0 ? -1 : i32(timeout * 1000) + 1
		pfd := posix.pollfd{fd = posix.FD(c.fd), events = {.IN}}
		posix.poll(&pfd, 1, ms)
	}
}

@(private)
handle_event :: proc(w: ^Wizard, ev: ^xlib.XEvent) {
	#partial switch ev.type {
	case .MapNotify:
		if ev.xmap.window == w.win && w.mode == .Wizard {
			xlib.SetInputFocus(w.c.dpy, w.win, .RevertToParent, xlib.CurrentTime)
		}
	case .MappingNotify:
		xlib.RefreshKeyboardMapping(&ev.xmapping)
	case .ButtonPress:
		if ev.xbutton.window != w.win { return }
		on_button(w, ev.xbutton.x, ev.xbutton.y, i32(ev.xbutton.button))
	case .MotionNotify:
		if ev.xmotion.window != w.win { return }
		if w.mode == .Settings { theme_drag(w, ev.xmotion.x, .Button1Mask in ev.xmotion.state) }
		on_motion(w, ev.xmotion.x, ev.xmotion.y)
	case .LeaveNotify:
		if w.hover.action != .None {
			w.hover = {}
			w.dirty = true
		}
	case .KeyPress:
		on_key(w, &ev.xkey)
	case .ConfigureNotify:
		if ev.xconfigure.window == w.win && w.mode == .Settings { settings_resized(w, ev.xconfigure.width, ev.xconfigure.height) }
	case .ClientMessage:
		if ev.xclient.window == w.win && w.mode == .Settings {
			if xlib.Atom(ev.xclient.data.l[0]) == tx.atom(w.c, "WM_DELETE_WINDOW") { w.state = .Finished }
		}
	}
}

@(private)
hit_at :: proc(w: ^Wizard, x, y: i32) -> Hit {
	#reverse for h in w.hits {
		if !tx.rect_contains(h.r, x, y) { continue }
		if h.clip.w > 0 && !tx.rect_contains(h.clip, x, y) { continue }
		return h
	}
	return {}
}

@(private)
on_motion :: proc(w: ^Wizard, x, y: i32) {
	w.pointer = {x, y}
	h := hit_at(w, x, y)
	if h.action != w.hover.action || h.arg != w.hover.arg {
		w.hover = h
		w.dirty = true
	}
}

@(private)
on_button :: proc(w: ^Wizard, x, y: i32, button: i32) {
	w.pointer = {x, y}
	if button == 4 || button == 5 {
		scroll_at(w, x, y, button == 4 ? -1 : 1)
		return
	}
	if button != 1 { return }
	h := hit_at(w, x, y)
	if w.mode == .Settings && w.set.sc.ed.capturing && h.action != .Sc_Capture { capture_stop(w) }
	if h.action != .Kb_Search && h.action != .Kb_Test && h.action != .Text_Field && w.focus != .None {
		w.focus = .None
		w.dirty = true
	}
	do_action(w, h.action, h.arg)
}

@(private)
scroll_at :: proc(w: ^Wizard, x, y: i32, dir: i32) {
	for s in w.scrolls {
		if !tx.rect_contains(s.r, x, y) { continue }
		step: i32 = (s.id == .Wallpapers || s.id == .Shortcuts) ? 90 : 3 * ROW_H
		target := scroll_ptr(w, s.id)
		if target == nil { return }
		target^ = clamp(target^ + dir * step, 0, max(s.max, 0))
		w.dirty = true
		on_motion(w, x, y)
		return
	}
}

@(private)
scroll_ptr :: proc(w: ^Wizard, id: Scroll_Id) -> ^i32 {
	switch id {
	case .None:       return nil
	case .Layouts:    return &w.kb.scroll_layouts
	case .Variants:   return &w.kb.scroll_variants
	case .Wallpapers: return &w.scroll_wp
	case .Shortcuts:  return &w.set.sc.scroll
	case .Apps:       return &w.set.sc.ed.scroll_apps
	case .Actions:    return &w.set.sc.ed.scroll_actions
	case .Themes:     return &w.scroll_themes
	case .Zone_Start: return &w.set.lay.scroll[0]
	case .Zone_Center: return &w.set.lay.scroll[1]
	case .Zone_End:   return &w.set.lay.scroll[2]
	case .Zone_Avail: return &w.set.lay.scroll[3]
	}
	return nil
}

@(private)
set_page :: proc(w: ^Wizard, p: Page) {
	if p == w.page { return }
	w.page = p
	w.focus = .None
	if p == .Keyboard { keyboard_reveal(w) }
	w.hover = {}
	w.dirty = true
}

// The keyboard lists are on screen (wizard page or settings section).
@(private)
on_keyboard_page :: proc(w: ^Wizard) -> bool {
	if w.mode == .Settings { return w.set.section == .Keyboard }
	return w.page == .Keyboard
}

@(private)
shows_thumbnails :: proc(w: ^Wizard) -> bool {
	if w.mode == .Settings { return w.set.section == .Wallpapers }
	return w.page == .Wallpaper || w.page == .Bar || w.page == .Windows || w.page == .Summary
}

@(private)
do_action :: proc(w: ^Wizard, action: Action, arg: int) {
	switch action {
	case .None:
	case .Next:
		if w.mode == .Settings { return }
		if w.page == .Summary {
			w.state = .Finished
		} else {
			set_page(w, Page(int(w.page) + 1))
		}
	case .Back:
		if w.mode == .Settings { return }
		if w.page != .Welcome { set_page(w, Page(int(w.page) - 1)) }
	case .Skip:
		w.state = .Skipped
	case .Goto_Page:
		set_page(w, Page(clamp(arg % 100, 0, len(Page) - 1)))
	case .Theme:
		w.theme_index = arg
		if t := selected_custom(w); t != nil { w.dark = t.dark } // the variant control shows the custom theme's
		update_theme(w)
		settings_changed(w, .Theme)
	case .Variant:
		w.dark = arg == 1
		if theme_is_custom(w) {
			w.dirty = true // a custom theme keeps its colours: only the preset cards change
		} else {
			update_theme(w)
			settings_changed(w, .Theme)
		}
	case .Language:
		language_pick(w, arg)
	case .Kb_Search:
		w.focus = .Search
		w.dirty = true
	case .Kb_Test:
		w.focus = .Test
		w.dirty = true
	case .Kb_Layout:
		keyboard_select_layout(w, arg)
		settings_changed(w, .Keyboard)
	case .Kb_Variant:
		keyboard_select_variant(w, arg)
		settings_changed(w, .Keyboard)
	case .Wp_Mode:
		wallpaper_set_mode(w, arg == 1)
		settings_changed(w, .Wallpapers)
	case .Wp_Area:
		w.wp_tab = clamp(arg, 0, len(w.areas) - 1)
		w.base_dirty = true
		w.dirty = true
	case .Wp_Tile:
		wallpaper_pick(w, arg)
		settings_changed(w, .Wallpapers)
	case .Bar_Choice:
		w.bar_top = arg < 2
		w.bar_floating = arg % 2 == 1
		w.dirty = true
		settings_changed(w, .Bar_Layout)
	case .Wm_Choice:
		w.wm_floating = arg == 1
		w.dirty = true
	case .Di_Choice:
		w.desktop_icons = !w.desktop_icons
		w.dirty = true
	case .Section, .Step, .Toggle, .Choice, .Text_Field, .Rerun_Wizard, .Open_Config, .Fx_Open, .Win_Tab:
		settings_action(w, action, arg)
	case .Sc_Add, .Sc_Edit, .Sc_Delete, .Sc_Capture, .Sc_Kind, .Sc_App, .Sc_Save, .Sc_Cancel, .Sc_Builtin, .Sc_Action:
		shortcuts_action(w, action, arg)
	case .Th_New, .Th_Edit, .Th_Slot, .Th_Variant, .Th_Slider, .Th_Swatch, .Th_Save, .Th_Cancel, .Th_Delete:
		themes_action(w, action, arg)
	case .Th_Scheme:
		w.pal.scheme = clamp(arg, 0, len(config.MATUGEN_SCHEMES) - 1)
		w.dirty = true
		settings_changed(w, .Theme)
	case .Bar_Tab, .Bar_Preset, .Lw_Select, .Lw_Move, .Lw_Remove, .Lw_Add:
		layout_action(w, action, arg)
	}
}

// Keysyms used for navigation.
@(private) KS_RETURN    :: 0xff0d
@(private) KS_KP_ENTER  :: 0xff8d
@(private) KS_ESCAPE    :: 0xff1b
@(private) KS_BACKSPACE :: 0xff08
@(private) KS_TAB       :: 0xff09
@(private) KS_LEFT      :: 0xff51
@(private) KS_UP        :: 0xff52
@(private) KS_RIGHT     :: 0xff53
@(private) KS_DOWN      :: 0xff54

// The input context follows the text fields (not the shortcut capture,
// which needs raw keys).
@(private)
sync_input_focus :: proc(w: ^Wizard) {
	want := w.focus != .None && !(w.mode == .Settings && w.set.sc.ed.capturing)
	if want != w.input_on {
		tx.input_focus(&w.input, want)
		w.input_on = want
	}
}

@(private)
on_key :: proc(w: ^Wizard, ev: ^xlib.XKeyEvent) {
	if w.mode == .Settings && w.set.sc.ed.capturing {
		capture_key(w, ev) // raw keysyms, never composed text
		return
	}
	raw, keysym := tx.input_lookup(&w.input, ev)
	ks := uint(keysym)
	typed := printable(raw)

	if w.focus != .None {
		switch ks {
		case KS_ESCAPE:
			w.focus = .None
			w.dirty = true
		case KS_BACKSPACE:
			field_backspace(w)
		case KS_RETURN, KS_KP_ENTER:
			if w.focus == .Search {
				if len(w.kb.filtered) > 0 {
					keyboard_select_layout(w, w.kb.filtered[0])
					settings_changed(w, .Keyboard)
				}
			} else if w.focus == .Test && w.mode == .Wizard {
				do_action(w, .Next, 0)
			}
			w.focus = .None
			w.dirty = true
		case KS_UP, KS_DOWN:
			if w.focus == .Search {
				keyboard_step(w, ks == KS_DOWN ? 1 : -1)
				settings_changed(w, .Keyboard)
			}
		case:
			if ev.state & {.ControlMask, .Mod1Mask} != {} { return }
			if typed != "" { field_insert(w, typed) }
		}
		return
	}
	if w.mode == .Settings {
		if on_keyboard_page(w) && (ks == KS_UP || ks == KS_DOWN) {
			keyboard_step(w, ks == KS_DOWN ? 1 : -1)
			settings_changed(w, .Keyboard)
		}
		return
	}
	switch ks {
	case KS_RETURN, KS_KP_ENTER, KS_RIGHT:
		do_action(w, .Next, 0)
	case KS_ESCAPE, KS_LEFT:
		do_action(w, .Back, 0)
	case KS_UP, KS_DOWN:
		if w.page == .Keyboard { keyboard_step(w, ks == KS_DOWN ? 1 : -1) }
	case:
		// Typing on the keyboard page goes to the search field.
		if w.page == .Keyboard && ev.state & {.ControlMask, .Mod1Mask} == {} {
			if typed != "" && typed != " " {
				w.focus = .Search
				field_insert(w, typed)
			}
		}
	}
}

// Composed text without control characters (Enter, Backspace and Tab also
// produce bytes).
@(private)
printable :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in text {
		if r < 0x20 || r == 0x7f { continue }
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}
