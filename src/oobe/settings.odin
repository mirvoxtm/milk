// The settings app ("Configurações do milk"): the wizard's widgets in a
// normal, managed window with a sidebar of sections. Every change is written
// into milk.json shortly after it is made (the same way the wizard writes it:
// unrelated keys are preserved) and the running milk instance is asked to
// reload with SIGHUP.
package oobe

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

@(private) SIDEBAR_W   :: 236
@(private) SET_ROW_H   :: 56
@(private) NOTICE_TIME :: 2.2

@(private)
Section :: enum { Appearance, Wallpapers, Bar, Windows, Desktop, Effects, Display, Shortcuts, Keyboard, Notifications, Clipboard, Lock, Areas, About }

// What a change touched (decides which keys are written and how soon).
@(private)
Change :: enum { Theme, Keyboard, Wallpapers, Bar_Layout, Values, Text }

@(private)
Control :: enum {
	None,
	Anim_Speed,
	Bar_Height, Bar_Opacity, Bar_Margin, Bar_Radius, Bar_Date, Bar_Clock,
	Wm_Gaps, Wm_Border, Wm_Master, Wm_Animation, Wm_Focus_Follows, Wm_Corners,
	Notif_Enabled, Notif_Dnd, Notif_Timeout, Notif_Position,
	Clip_Enabled, Clip_Persist, Clip_Max,
	Fx_Enabled,
	Area_Name, // + area index
	Th_Name, Th_Hex, // theme editor: name, hex field (+ Theme_Slot)
	Sc_Command, Sc_Site, Sc_Search,
	Scr_Name, Scr_Exec, Scr_Click, Scr_Icon_Name, Scr_Interval, // barscripts.odin
	// windows.odin
	Wm_Mode, Wm_Title_Style, Wm_Title_Side, Wm_Title_Align, Wm_Title_Height, Wm_Placement, Wm_Snap_Layouts,
	Wm_Snap_Distance, Wm_Raise_Focus,
	Di_Enabled, Di_Shortcut_Mode, Di_Size, Di_Single, Di_Thumbs, Di_Hidden, Di_Sort, Di_New_Icons,
	// display.odin
	Nl_Enabled, Nl_Mode, Nl_Transition, Nl_From, Nl_To, Nl_Lat, Nl_Lon, Osd_Position,
	Theme_Apps, // appearance.themeApps (GTK and Qt apps in milk's colours)
	// lock.odin
	Lock_Enabled, Lock_After, Dim_After, Screen_Off_After, Suspend_After, Lock_On_Suspend, Inhibit_Fullscreen,
	// areas.odin
	Area_Number, Area_Bar_Icons,
}

@(private) ANIM_SCALES :: [4]f64{0, 0.5, 1, 1.5}

@(private)
Settings :: struct {
	section:        Section,
	// Values being edited, initialised from milk.json.
	anim_scale:     f64,
	bar_height:     int,
	bar_opacity:    f64,
	bar_margin:     int,
	bar_radius:     int,
	date_format:    [dynamic]u8,
	clock_format:   [dynamic]u8,
	gaps:           int,
	border:         int,
	master:         f64,
	animation_ms:   int,
	corner_radius:  int,
	focus_follows:  bool,
	notif_enabled:  bool,
	notif_dnd:      bool,
	notif_timeout:  int,
	notif_position: int, // 0 top-right, 1 bottom-right
	clip_enabled:   bool,
	clip_persist:   bool,
	clip_max:       int,
	fx_enabled:     bool,                 // compositor.enabled (lactase; see compositor.odin)
	theme_apps:     bool,                 // appearance.themeApps
	// Janelas and Área de trabalho (windows.odin).
	wm_floating:    bool,
	win_tab:        int, // floating mode: 0 general, 1 title bar, 2 behaviour
	look_tab:       int, // Appearance: 0 theme, 1 general
	avatar:         Avatar_State, // the profile picture (avatar.odin)
	title_circles:  bool,
	title_left:     bool,
	title_center:   bool,
	title_height:   int,
	placement:      int, // PLACEMENT_NAMES
	snap_layouts:   bool,
	snap_distance:  int,
	raise_focus:    bool,
	di_enabled:     bool,
	di_thumbs:      bool,
	di_hidden:      bool,
	di_sort:        int, // SORT_NAMES
	di_new_here:    bool, // linux.desktopIcons.newIcons = "current-area"
	di_size:        int,
	di_single:      bool,
	sc_mode:        int, // SHORTCUT_MODE_NAMES
	disp:           Display_Settings, // Tela: night light and the volume/brightness pop-up (display.odin)
	// Bloqueio e inatividade (lock.odin).
	lock_enabled:       bool,
	lock_on_suspend:    bool,
	inhibit_fullscreen: bool,
	dim_after:          int, // seconds, 0 = never
	lock_after:         int,
	screen_off_after:   int,
	suspend_after:      int,
	fx_poll:        f64,
	fx_children:    [dynamic]posix.pid_t, // lactase settings apps not reaped yet
	names:          [dynamic][dynamic]u8,
	areas:          Areas_State, // Áreas: icons and the toast's number (areas.odin)
	sc:             Shortcuts,
	ted:            Theme_Editor,
	lay:            Layout_Editor,
	scr:            Scripts_State, // Barra → Scripts (barscripts.odin)
	bar_tab:        int,  // Barra: 0 style, 1 layouts, 2 widgets, 3 scripts
	themes_dirty:   bool, // write appearance.customThemes on the next save
	text_target:    int, // Text_Field argument of the focused field

	// Saving
	edits:          map[string]json.Value, // "bar.height" -> value (owned)
	wallpapers:     bool, // the wallpaper choice changed
	save_at:        f64,  // 0 = nothing pending
	saved_any:      bool,
	notice:         string,
	notice_until:   f64,
}

// Open the settings window (on `section`, a Section name in lower case:
// "wallpapers", "windows"...; "" = the first) and block until it is closed.
// Returns true when something was saved to milk.json.
run_settings :: proc(c: ^tx.Connection, config_path: string, runtime_root: string, section := "") -> bool {
	if c == nil {
		log.error("Settings: no X connection")
		return false
	}
	cfg, err := config.load(config_path)
	if err != "" {
		log.errorf("Settings: cannot load %s: %s", config_path, err)
		delete(err)
		return false
	}
	defer config.destroy(cfg)

	arena: virtual.Arena
	if aerr := virtual.arena_init_growing(&arena); aerr != nil {
		log.errorf("Settings: out of memory (%v)", aerr)
		return false
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)

	w := new(Wizard)
	defer free(w)
	wizard_setup(w, c, cfg, config_path, runtime_root, .Settings)
	defer wizard_destroy(w)
	settings_load_values(w)
	for sec in Section {
		if section != "" && strings.equal_fold(fmt.tprintf("%v", sec), section) { w.set.section = sec }
	}
	if !settings_open_window(w) { return false }
	wizard_loop(w)
	if w.set.save_at > 0 { settings_save(w) }
	close_window(w)
	thumbs_stop(w)
	return w.set.saved_any
}

@(private)
settings_load_values :: proc(w: ^Wizard) {
	s := &w.set
	cfg := w.cfg
	s.anim_scale = cfg.appearance.animation_scale
	s.bar_height = cfg.bar.height
	s.bar_opacity = cfg.bar.opacity
	s.bar_margin = cfg.bar.margin
	s.bar_radius = cfg.bar.radius
	append(&s.date_format, ..transmute([]u8)cfg.bar.date_format)
	append(&s.clock_format, ..transmute([]u8)cfg.bar.clock_format)
	s.gaps = cfg.wm.gaps
	s.border = cfg.wm.border_width
	s.master = cfg.wm.master_factor
	s.animation_ms = cfg.wm.animation
	s.corner_radius = cfg.wm.corner_radius
	s.focus_follows = cfg.wm.focus_follows_mouse
	s.notif_enabled = cfg.notifications.enabled
	s.notif_dnd = cfg.notifications.do_not_disturb
	s.notif_timeout = int(math.round(cfg.notifications.timeout))
	s.notif_position = cfg.notifications.position == "bottom-right" ? 1 : 0
	s.clip_enabled = cfg.clipboard.enabled
	s.clip_persist = cfg.clipboard.persist
	s.clip_max = cfg.clipboard.max_items
	s.fx_enabled = cfg.compositor.enabled
	s.theme_apps = cfg.appearance.theme_apps
	windows_load_values(w)
	display_load_values(w)
	lock_load_values(w)
	for n in w.areas {
		name: [dynamic]u8
		if ws, ok := cfg.workspaces[n]; ok { append(&name, ..transmute([]u8)ws.name) }
		append(&s.names, name)
	}
	areas_load_values(w)
}

@(private)
settings_destroy :: proc(w: ^Wizard) {
	s := &w.set
	delete(s.date_format)
	delete(s.clock_format)
	delete(s.fx_children)
	for n in s.names { delete(n) }
	delete(s.names)
	areas_destroy(w)
	clear_edits(w)
	delete(s.edits)
	shortcuts_destroy(w)
	display_destroy(w)
	ted_destroy(w)
	lay_destroy(w)
	scripts_destroy(w)
	s^ = {}
}

@(private)
settings_open_window :: proc(w: ^Wizard) -> bool {
	c := w.c
	mon := w.monitor
	ww := min(i32(980), mon.w - 40)
	wh := min(i32(660), mon.h - 60)
	w.screen = {mon.x + (mon.w - ww) / 2, mon.y + (mon.h - wh) / 2, ww, wh}
	w.card = {0, 0, ww, wh}

	attrs: xlib.XSetWindowAttributes
	bg := w.theme.bg
	attrs.background_pixel = uint(bg.r) << 16 | uint(bg.g) << 8 | uint(bg.b)
	// KeyRelease: the shortcut capture takes Super on its own when it is released.
	attrs.event_mask = {.ButtonPress, .PointerMotion, .LeaveWindow, .KeyPress, .KeyRelease, .Exposure, .StructureNotify}
	w.win = xlib.CreateWindow(c.dpy, c.root, w.screen.x, w.screen.y, u32(ww), u32(wh), 0, c.depth, .InputOutput, c.visual,
	                          {.CWBackPixel, .CWEventMask}, &attrs)
	if w.win == 0 { return false }
	w.input = tx.input_open(c, w.win)
	hint := xlib.XClassHint{res_name = "milk-settings", res_class = "Milk-settings"}
	xlib.SetClassHint(c.dpy, w.win, &hint)
	title := tr(w, "Configurações do milk", "milk settings")
	xlib.StoreName(c.dpy, w.win, "milk settings") // legacy WM_NAME is Latin-1; _NET_WM_NAME carries the real title
	tx.set_utf8_string(c, w.win, "_NET_WM_NAME", title)
	tx.set_atom_list(c, w.win, "_NET_WM_WINDOW_TYPE", {tx.atom(c, "_NET_WM_WINDOW_TYPE_DIALOG")})
	tx.set_cardinals(c, w.win, "_NET_WM_PID", {uint(posix.getpid())})
	protocols := [1]xlib.Atom{tx.atom(c, "WM_DELETE_WINDOW")}
	xlib.SetWMProtocols(c.dpy, w.win, &protocols[0], 1)
	if sh := xlib.AllocSizeHints(); sh != nil {
		sh.flags = {.PMinSize, .PPosition, .PSize}
		sh.x, sh.y, sh.width, sh.height = w.screen.x, w.screen.y, ww, wh
		sh.min_width, sh.min_height = min(ww, 820), min(wh, 560)
		xlib.SetWMNormalHints(c.dpy, w.win, sh)
		xlib.Free(sh)
	}
	if wmh := xlib.AllocWMHints(); wmh != nil {
		wmh.flags = {.InputHint}
		wmh.input = true
		xlib.SetWMHints(c.dpy, w.win, wmh)
		xlib.Free(wmh)
	}
	w.cursor = xlib.CreateFontCursor(c.dpy, .XC_left_ptr)
	xlib.DefineCursor(c.dpy, w.win, w.cursor)
	// Map at once (plain theme colour), then open the fonts and draw.
	tx.map_window(c, w.win)
	tx.flush(c)
	if !open_fonts(w) {
		log.error("Settings: no usable font")
		return false
	}
	keyboard_init(w)
	w.base_dirty = true
	w.dirty = true
	w.anim_start = tx.now()
	return true
}

@(private)
settings_resized :: proc(w: ^Wizard, width, height: i32) {
	if width == w.screen.w && height == w.screen.h { return }
	w.screen.w, w.screen.h = width, height
	w.card = {0, 0, width, height}
	w.base_dirty = true
	w.dirty = true
}

@(private)
settings_content_rect :: proc(w: ^Wizard) -> tx.Rect {
	return {SIDEBAR_W + 36, 112, w.screen.w - SIDEBAR_W - 72, w.screen.h - 112 - 28}
}

@(private)
sidebar_color :: proc(th: ^Theme) -> tx.Color {
	return th.dark ? mix(th.bg, tx.rgb(0, 0, 0), 0.18) : mix(th.bg, th.surface, 0.75)
}

@(private)
settings_build_base :: proc(w: ^Wizard) {
	th := &w.theme
	cv := &w.base
	tx.canvas_fill(cv, th.bg)
	tx.canvas_fill_rect(cv, {0, 0, SIDEBAR_W, cv.h}, sidebar_color(th))
	tx.canvas_fill_rect(cv, {SIDEBAR_W, 0, 1, cv.h}, mix(th.bg, th.muted, 0.25))
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------
@(private)
section_info :: proc(w: ^Wizard, s: Section) -> (icon: Icon, title, desc: string) {
	switch s {
	case .Appearance:
		return .Palette, tr(w, "Aparência", "Appearance"), tr(w, "Tema de cores, foto de perfil e animações.", "Colour theme, profile picture and animations.")
	case .Wallpapers:
		return .Photo, tr(w, "Papéis de parede", "Wallpapers"), tr(w, "Uma imagem para todas as áreas ou uma para cada área.", "One image for every area or one per area.")
	case .Bar:
		return .Layout_Top, tr(w, "Barra", "Bar"), tr(w, "Posição, estilo, tamanho, widgets e formatos de data e hora.", "Position, style, size, widgets and date/time formats.")
	case .Effects:
		return .Sparkles, tr(w, "Efeitos", "Effects"), tr(w, "Sombras, animações e transparência com o lactase, o compositor do milk.", "Shadows, animations and transparency with lactase, milk's compositor.")
	case .Display:
		return .Sun, tr(w, "Tela", "Display"), tr(w, "Luz noturna e o aviso de volume e brilho.", "Night light and the volume and brightness pop-up.")
	case .Windows:
		return .App_Window, tr(w, "Janelas", "Windows"), tr(w, "Lado a lado ou flutuantes, bordas, barra de título e animações.", "Tiling or floating, borders, title bars and animations.")
	case .Desktop:
		return .Desktop, tr(w, "Área de trabalho", "Desktop"), tr(w, "Ícones de arquivos e atalhos sobre o papel de parede.", "File and shortcut icons over the wallpaper.")
	case .Shortcuts:
		return .Command, tr(w, "Atalhos", "Shortcuts"), tr(w, "Combinações de teclas para aplicativos, comandos, sites e ações das janelas.", "Key combinations for applications, commands, sites and window actions.")
	case .Keyboard:
		return .Keyboard, tr(w, "Idioma e teclado", "Language and keyboard"), tr(w, "Idioma do milk, layout e variante do teclado, aplicados na hora.", "milk's language and the keyboard layout and variant, applied at once.")
	case .Notifications:
		return .Bell, tr(w, "Notificações", "Notifications"), tr(w, "Avisos que aparecem no canto da tela.", "Pop-ups shown in a corner of the screen.")
	case .Clipboard:
		return .Clipboard, tr(w, "Área de transferência", "Clipboard"), tr(w, "Histórico de textos e imagens copiados.", "History of copied text and images.")
	case .Lock:
		return .Lock, tr(w, "Bloqueio e inatividade", "Lock & idle"), tr(w, "Tela de bloqueio e o que acontece quando o computador fica sem uso.", "The lock screen and what happens when the computer is not in use.")
	case .Areas:
		return .Layout_Grid, tr(w, "Áreas", "Areas"), tr(w, "Nomes e ícones das áreas, mostrados no aviso de área e na barra.", "Area names and icons, shown by the area toast and on the bar.")
	case .About:
		return .Info, tr(w, "Sobre", "About"), tr(w, "Versão, arquivos e assistente inicial.", "Version, files and the setup wizard.")
	}
	return .None, "", ""
}

@(private)
draw_settings :: proc(w: ^Wizard, cv: ^tx.Canvas) {
	th := &w.theme
	s := &w.set

	// The section first: scrolled content may run over the header band,
	// which is then repainted from the base.
	c := settings_content_rect(w)
	switch s.section {
	case .Appearance:
		if s.ted.open {
			draw_theme_editor(w, cv, c)
			break
		}
		if s.avatar.picking {
			draw_avatar_picker(w, cv, c)
			break
		}
		// Two tabs, so the theme cards keep their size in a small window.
		segmented(w, cv, {c.x, c.y, min(i32(360), c.w), 40}, {tr(w, "Tema", "Theme"), tr(w, "Geral", "General")},
		          {.Palette, .Sparkles}, s.look_tab, .Look_Tab)
		body := tx.Rect{c.x, c.y + 56, c.w, c.h - 56}
		if s.look_tab == 0 {
			draw_theme_page(w, cv, body)
			break
		}
		row := tx.Rect{body.x, body.y, body.w, SET_ROW_H + 8}
		draw_avatar_row(w, cv, row)
		row.y += row.h
		row.h = SET_ROW_H
		fill_rounded(cv, {row.x, row.y - 1, row.w, 1}, 0, mix(th.bg, th.muted, 0.25))
		row_label(w, row, tr(w, "Velocidade das animações", "Animation speed"), tr(w, "Janelas, barra, painéis e avisos", "Windows, bar, panels and toasts"))
		labels := []string{tr(w, "Desligadas", "Off"), tr(w, "Rápidas", "Fast"), tr(w, "Normais", "Normal"), tr(w, "Lentas", "Slow")}
		sw := min(i32(440), row.w / 2 + 40)
		choice_control(w, cv, {row.x + row.w - sw, row.y + 8, sw, 40}, labels, anim_index(s.anim_scale), .Anim_Speed)
		row.y += SET_ROW_H
		fill_rounded(cv, {row.x, row.y - 1, row.w, 1}, 0, mix(th.bg, th.muted, 0.25))
		row_label(w, row, tr(w, "Colorir apps GTK e Qt", "Colour GTK and Qt apps"),
		          tr(w, "Os outros aplicativos também usam as cores do tema", "Other apps use the theme's colours too"))
		toggle(w, cv, row, s.theme_apps, .Theme_Apps)
	case .Wallpapers:
		draw_wallpaper_page(w, cv, c)
	case .Bar:
		body := draw_bar_tabs(w, cv, c)
		switch s.bar_tab {
		case 1: draw_layout_presets(w, cv, body)
		case 2: draw_widget_editor(w, cv, body)
		case 3: draw_scripts_tab(w, cv, body)
		case:
			top_h := min(i32(176), body.h / 2 - 20)
			draw_bar_page(w, cv, {body.x, body.y, body.w, top_h})
			ry := body.y + top_h + 12
			rows_bar(w, cv, body, &ry)
		}
	case .Windows:
		draw_windows_section(w, cv, c)
	case .Desktop:
		ry := c.y
		rows_desktop(w, cv, c, &ry)
	case .Effects:
		draw_effects_page(w, cv, c)
	case .Display:
		draw_display_section(w, cv, c)
	case .Shortcuts:
		draw_shortcuts(w, cv, c)
	case .Keyboard:
		row := tx.Rect{c.x, c.y, c.w, SET_ROW_H}
		row_label(w, row, tr(w, "Idioma", "Language"), tr(w, "Menus, painéis, datas e este app", "Menus, panels, dates and this app"))
		lw := min(i32(520), row.w - 220)
		draw_language_control(w, cv, {row.x + row.w - lw, row.y + 8, lw, 40})
		fill_rounded(cv, {c.x, row.y + row.h + 8, c.w, 1}, 0, mix(th.bg, th.muted, 0.25))
		top := row.h + 24
		draw_keyboard_page(w, cv, {c.x, c.y + top, c.w, c.h - top})
	case .Notifications:
		ry := c.y
		rows_notifications(w, cv, c, &ry)
	case .Clipboard:
		ry := c.y
		rows_clipboard(w, cv, c, &ry)
	case .Lock:
		ry := c.y
		rows_lock(w, cv, c, &ry)
	case .Areas:
		draw_areas_section(w, cv, c)
	case .About:
		draw_about(w, cv, c)
	}
	for y in 0 ..< cv.h {
		if y >= c.y && y < c.y + c.h { continue }
		row := int(y) * int(cv.w)
		copy(cv.px[row + SIDEBAR_W + 1:row + int(cv.w)], w.base.px[row + SIDEBAR_W + 1:row + int(cv.w)])
	}


	// Sidebar: the entries shrink a little when they would reach the version line.
	step := clamp((w.screen.h - 80 - 52) / i32(len(Section)), 30, 44)
	x: i32 = 22
	if w.f_icon_small != nil {
		tx.canvas_fill_circle(cv, f32(x + 15), 39, 15, th.accent)
		icon(w, w.f_icon_small, {x, 24, 30, 30}, .Milk, th.accent_fg)
		x += 40
	}
	text(w, w.f_h2, x, 24, 30, tr(w, "Configurações", "Settings"), th.fg)
	y: i32 = 80
	for sec in Section {
		ic, title, _ := section_info(w, sec)
		r := tx.Rect{12, y, SIDEBAR_W - 24, step - 4}
		sel := sec == s.section
		hot := hovered(w, .Section, int(sec))
		if sel {
			fill_rounded(cv, r, 12, th.accent)
		} else if hot {
			fill_rounded(cv, r, 12, th.hover)
		}
		fg := sel ? th.accent_fg : th.fg
		icon(w, w.f_icon_small, {r.x + 12, r.y, 22, r.h}, ic, sel ? th.accent_fg : mix(th.fg, th.muted, 0.35))
		text(w, w.f_body, r.x + 46, r.y, r.h, ellipsize(w, w.f_body, title, r.w - 54), fg)
		add_hit(w, r, .Section, int(sec))
		y += step
	}
	text(w, w.f_small, 24, w.screen.h - 40, 20, fmt.tprintf("milk %s", app_version), th.muted)

	// Header.
	_, title, desc := section_info(w, s.section)
	cx := i32(SIDEBAR_W + 36)
	text(w, w.f_title, cx, 26, 42, title, th.fg)
	text(w, w.f_small, cx, 68, 22, ellipsize(w, w.f_small, desc, w.screen.w - cx - 36), mix(th.fg, th.muted, 0.55))
	if s.notice != "" && tx.now() < s.notice_until {
		nw := text_width(w, w.f_small, s.notice) + 44
		r := tx.Rect{w.screen.w - 36 - nw, 32, nw, 30}
		fill_rounded(cv, r, 15, mix(th.accent, th.bg, 0.82))
		icon(w, w.f_icon_small, {r.x + 10, r.y, 18, r.h}, .Check, th.accent)
		text(w, w.f_small, r.x + 32, r.y, r.h, s.notice, th.fg)
	}

}

@(private)
anim_index :: proc(scale: f64) -> int {
	if scale <= 0 { return 0 }
	if scale <= 0.75 { return 1 }
	if scale <= 1.25 { return 2 }
	return 3
}

// Label and description on the left of a settings row.
@(private)
row_label :: proc(w: ^Wizard, row: tx.Rect, label, desc: string) {
	th := &w.theme
	if desc == "" {
		text(w, w.f_body, row.x, row.y, row.h, label, th.fg)
		return
	}
	text(w, w.f_body, row.x, row.y + 8, 22, label, th.fg)
	text(w, w.f_small, row.x, row.y + 29, 18, desc, mix(th.fg, th.muted, 0.55))
}

// Start a row at *y: draws the label and a divider; returns the row rectangle.
@(private)
next_row :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect, y: ^i32, label, desc: string, dimmed := false) -> tx.Rect {
	th := &w.theme
	row := tx.Rect{c.x, y^, c.w, SET_ROW_H}
	if dimmed {
		text(w, w.f_body, row.x, row.y + (desc == "" ? 0 : 8), desc == "" ? row.h : 22, label, th.muted)
		if desc != "" { text(w, w.f_small, row.x, row.y + 29, 18, desc, th.muted) }
	} else {
		row_label(w, row, label, desc)
	}
	y^ += SET_ROW_H
	tx.canvas_fill_rect(cv, {c.x, y^ - 1, c.w, 1}, mix(th.bg, th.muted, 0.18))
	return row
}

@(private)
stepper :: proc(w: ^Wizard, cv: ^tx.Canvas, row: tx.Rect, value: string, ctrl: Control) {
	th := &w.theme
	bw: i32 = 34
	value_w: i32 = 92
	plus := tx.Rect{row.x + row.w - bw, row.y + (row.h - bw) / 2, bw, bw}
	minus := tx.Rect{plus.x - value_w - bw, plus.y, bw, bw}
	for b, i in ([2]tx.Rect{minus, plus}) {
		arg := int(ctrl) * 10 + i
		fill_rounded(cv, b, f32(bw) / 2, hovered(w, .Step, arg) ? th.hover : th.surface)
		text_centered(w, w.f_h2, b, i == 0 ? "−" : "+", th.fg)
		add_hit(w, b, .Step, arg)
	}
	text_centered(w, w.f_body, {minus.x + bw, row.y, value_w, row.h}, value, th.fg)
}

@(private)
toggle :: proc(w: ^Wizard, cv: ^tx.Canvas, row: tx.Rect, on: bool, ctrl: Control) {
	th := &w.theme
	track := tx.Rect{row.x + row.w - 50, row.y + (row.h - 28) / 2, 50, 28}
	hot := hovered(w, .Toggle, int(ctrl))
	fill := on ? th.accent : (hot ? th.hover : mix(th.surface, th.muted, 0.2))
	fill_rounded(cv, track, 14, fill)
	if !on { tx.canvas_stroke_rounded_rect(cv, track, 14, 1.5, th.muted) }
	knob: f32 = on ? 10 : 7
	kx := on ? f32(track.x + track.w - 14) : f32(track.x + 14)
	tx.canvas_fill_circle(cv, kx, f32(track.y) + 14, knob, on ? th.accent_fg : th.muted)
	add_hit(w, {track.x - 6, track.y - 6, track.w + 12, track.h + 12}, .Toggle, int(ctrl))
}

// Segmented control whose options report (control, option) through .Choice.
@(private)
choice_control :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect, labels: []string, selected: int, ctrl: Control) {
	th := &w.theme
	fill_rounded(cv, r, f32(r.h) / 2, th.field)
	tx.canvas_stroke_rounded_rect(cv, r, f32(r.h) / 2, 1, th.outline)
	n := i32(len(labels))
	seg_w := (r.w - 8) / n
	for label, i in labels {
		seg := tx.Rect{r.x + 4 + i32(i) * seg_w, r.y + 4, seg_w, r.h - 8}
		arg := int(ctrl) * 100 + i
		if i == selected {
			fill_rounded(cv, seg, f32(seg.h) / 2, th.accent)
		} else if hovered(w, .Choice, arg) {
			fill_rounded(cv, seg, f32(seg.h) / 2, th.hover)
		}
		text_centered(w, w.f_body, seg, ellipsize(w, w.f_body, label, seg.w - 12), i == selected ? th.accent_fg : th.fg)
		add_hit(w, seg, .Choice, arg)
	}
}

@(private)
text_control :: proc(w: ^Wizard, cv: ^tx.Canvas, row: tx.Rect, width: i32, buf: []u8, placeholder: string, target: int) {
	r := tx.Rect{row.x + row.w - width, row.y + (row.h - 40) / 2, width, 40}
	focused := w.focus == .Text && w.set.text_target == target
	draw_field(w, cv, r, .None, string(buf), placeholder, focused, .Text_Field, target)
}

@(private)
rows_bar :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect, y: ^i32) {
	s := &w.set
	row := next_row(w, cv, c, y, tr(w, "Altura", "Height"), "")
	stepper(w, cv, row, fmt.tprintf("%d px", s.bar_height), .Bar_Height)
	row = next_row(w, cv, c, y, tr(w, "Opacidade", "Opacity"), "")
	stepper(w, cv, row, fmt.tprintf("%d%%", int(math.round(s.bar_opacity * 100))), .Bar_Opacity)
	floating := w.bar_floating
	row = next_row(w, cv, c, y, tr(w, "Margem (flutuante)", "Margin (floating)"), "", !floating)
	stepper(w, cv, row, fmt.tprintf("%d px", s.bar_margin), .Bar_Margin)
	row = next_row(w, cv, c, y, tr(w, "Cantos (flutuante)", "Corners (floating)"), "", !floating)
	stepper(w, cv, row, fmt.tprintf("%d px", s.bar_radius), .Bar_Radius)
	half := (c.w - 24) / 2
	if y^ + SET_ROW_H <= c.y + c.h + 8 {
		left := tx.Rect{c.x, y^, half, SET_ROW_H}
		right := tx.Rect{c.x + half + 24, y^, half, SET_ROW_H}
		text(w, w.f_body, left.x, left.y, left.h, tr(w, "Data", "Date"), w.theme.fg)
		text_control(w, cv, left, half - 70, s.date_format[:], "%a %d %b", int(Control.Bar_Date) * 100)
		text(w, w.f_body, right.x, right.y, right.h, tr(w, "Relógio", "Clock"), w.theme.fg)
		text_control(w, cv, right, half - 90, s.clock_format[:], "%H:%M", int(Control.Bar_Clock) * 100)
		y^ += SET_ROW_H
	}
}

@(private)
rows_windows :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect, y: ^i32) {
	s := &w.set
	row := next_row(w, cv, c, y, tr(w, "Espaçamento", "Gaps"), tr(w, "Entre as janelas e as bordas da tela", "Between windows and the screen edges"))
	stepper(w, cv, row, fmt.tprintf("%d px", s.gaps), .Wm_Gaps)
	row = next_row(w, cv, c, y, tr(w, "Borda das janelas", "Window borders"), tr(w, "Cor da janela em foco: destaque do tema", "Focused window: the theme accent"))
	stepper(w, cv, row, fmt.tprintf("%d px", s.border), .Wm_Border)
	row = next_row(w, cv, c, y, tr(w, "Cantos arredondados", "Rounded corners"), tr(w, "Raio dos cantos das janelas", "Radius of the window corners"))
	stepper(w, cv, row, s.corner_radius == 0 ? tr(w, "Desligado", "Off") : fmt.tprintf("%d px", s.corner_radius), .Wm_Corners)
	{
		// A mini window with that radius (half scale), left of the stepper.
		th := &w.theme
		win := tx.Rect{row.x + row.w - 160 - 24 - 56, row.y + (row.h - 36) / 2, 56, 36}
		rad := f32(s.corner_radius) / 2
		bw := f32(max(s.border, 1))
		fill_rounded(cv, win, rad, th.focus)
		fill_rounded(cv, {win.x + i32(bw), win.y + i32(bw), win.w - 2 * i32(bw), win.h - 2 * i32(bw)}, max(rad - bw, 0), th.bg)
		fill_rounded(cv, {win.x + 8, win.y + 9, 22, 4}, 2, mix(th.fg, th.bg, 0.4))
		fill_rounded(cv, {win.x + 8, win.y + 17, 32, 4}, 2, mix(th.muted, th.bg, 0.3))
	}
	row = next_row(w, cv, c, y, tr(w, "Área mestre", "Master area"), tr(w, "Largura da janela principal", "Width of the main window"))
	stepper(w, cv, row, fmt.tprintf("%d%%", int(math.round(s.master * 100))), .Wm_Master)
	row = next_row(w, cv, c, y, tr(w, "Foco segue o mouse", "Focus follows mouse"), tr(w, "Focar a janela sob o ponteiro", "Focus the window under the pointer"))
	toggle(w, cv, row, s.focus_follows, .Wm_Focus_Follows)
	row = next_row(w, cv, c, y, tr(w, "Animação das janelas", "Window animation"), tr(w, "Duração ao abrir, mover e redimensionar", "Duration when opening, moving and resizing"))
	stepper(w, cv, row, s.animation_ms == 0 ? tr(w, "Desligada", "Off") : fmt.tprintf("%d ms", s.animation_ms), .Wm_Animation)
}

@(private)
rows_notifications :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect, y: ^i32) {
	s := &w.set
	row := next_row(w, cv, c, y, tr(w, "Notificações", "Notifications"), tr(w, "Receber avisos dos aplicativos", "Receive pop-ups from applications"))
	toggle(w, cv, row, s.notif_enabled, .Notif_Enabled)
	row = next_row(w, cv, c, y, tr(w, "Não perturbe", "Do not disturb"), tr(w, "Guardar no histórico sem mostrar", "Keep them in the history without showing them"), !s.notif_enabled)
	toggle(w, cv, row, s.notif_dnd, .Notif_Dnd)
	row = next_row(w, cv, c, y, tr(w, "Tempo na tela", "Time on screen"), tr(w, "Quando o aplicativo não define", "When the application does not say"), !s.notif_enabled)
	stepper(w, cv, row, fmt.tprintf("%d s", s.notif_timeout), .Notif_Timeout)
	row = next_row(w, cv, c, y, tr(w, "Posição", "Position"), "", !s.notif_enabled)
	choice_control(w, cv, {row.x + row.w - 340, row.y + 8, 340, 40}, {tr(w, "Superior direito", "Top right"), tr(w, "Inferior direito", "Bottom right")},
	               s.notif_position, .Notif_Position)
}

@(private)
rows_clipboard :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect, y: ^i32) {
	s := &w.set
	row := next_row(w, cv, c, y, tr(w, "Histórico", "History"), tr(w, "Guardar o que for copiado", "Keep what is copied"))
	toggle(w, cv, row, s.clip_enabled, .Clip_Enabled)
	row = next_row(w, cv, c, y, tr(w, "Itens guardados", "Items kept"), "", !s.clip_enabled)
	stepper(w, cv, row, fmt.tprintf("%d", s.clip_max), .Clip_Max)
	row = next_row(w, cv, c, y, tr(w, "Manter após reiniciar", "Keep after restarting"), tr(w, "Salvar o histórico na pasta do milk", "Save the history in milk's folder"), !s.clip_enabled)
	toggle(w, cv, row, s.clip_persist, .Clip_Persist)
}

@(private)
draw_about :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	th := &w.theme
	y := c.y + 8
	tx.canvas_fill_circle(cv, f32(c.x + 36), f32(y + 36), 36, th.accent)
	icon(w, w.f_icon_big, {c.x, y, 72, 72}, .Milk, th.accent_fg)
	text(w, w.f_title, c.x + 92, y + 4, 40, "milk", th.fg)
	text(w, w.f_body, c.x + 92, y + 42, 24, fmt.tprintf(tr(w, "Versão %s", "Version %s"), app_version), mix(th.fg, th.muted, 0.5))
	y += 104
	text(w, w.f_tiny, c.x, y, 18, tr(w, "CONFIGURAÇÃO", "CONFIGURATION"), th.muted)
	text(w, w.f_small, c.x, y + 18, 22, ellipsize(w, w.f_small, w.config_path, c.w), th.fg)
	y += 50
	text(w, w.f_tiny, c.x, y, 18, tr(w, "DADOS", "DATA"), th.muted)
	text(w, w.f_small, c.x, y + 18, 22, ellipsize(w, w.f_small, w.runtime_root, c.w), th.fg)
	y += 64
	rerun := tr(w, "Executar assistente inicial novamente", "Run the setup wizard again")
	bw := button_width(w, rerun, .Sparkles)
	button(w, cv, {c.x, y, bw, BUTTON_H}, rerun, .Tonal, .Rerun_Wizard, 0, .Sparkles)
	edit := tr(w, "Abrir milk.json", "Open milk.json")
	ew := button_width(w, edit)
	button(w, cv, {c.x + bw + 12, y, ew, BUTTON_H}, edit, .Text, .Open_Config)
	y += BUTTON_H + 12
	text(w, w.f_small, c.x, y, 22, tr(w, "O assistente aparece no próximo início do milk.", "The wizard appears the next time milk starts."), th.muted)
	y += 46
	update := tr(w, "Atualizar o milk…", "Update milk…")
	uw := button_width(w, update, .Arrow_Down)
	button(w, cv, {c.x, y, uw, BUTTON_H}, update, .Tonal, .Update_Milk, 0, .Arrow_Down)
	y += BUTTON_H + 12
	text(w, w.f_small, c.x, y, 22, ellipsize(w, w.f_small, tr(w, "Baixa e compila o milk, o Spoil, o lactase e o snippy e reinicia o milk sem fechar suas janelas.",
	                                                           "Downloads and builds milk, Spoil, lactase and snippy, then restarts milk without closing your windows."), c.w), th.muted)
}

// `milk update` in the configured terminal, which stays open on the result.
@(private)
run_update_in_terminal :: proc(w: ^Wizard) {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil { return }
	exe = strings.trim_suffix(exe, " (deleted)")
	script := fmt.tprintf("'%s' update; printf '\n%s'; read _", exe, tr(w, "Pressione Enter para fechar.", "Press Enter to close."))
	terminal := strings.fields(w.cfg.wm.terminal, context.temp_allocator)
	if len(terminal) == 0 { terminal = {"xterm"} }
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, ..terminal)
	// gnome-terminal and its kin take the command after "--"; the others after -e.
	switch strings.to_lower(terminal[0], context.temp_allocator) {
	case "gnome-terminal", "kgx", "ptyxis", "tilix": append(&argv, "--")
	case "wezterm": append(&argv, "start", "--")
	case: append(&argv, "-e")
	}
	append(&argv, "sh", "-c", script)
	if _, perr := os.process_start(os.Process_Desc{command = argv[:]}); perr != nil {
		log.warnf("Settings: cannot open %s for milk update: %v", terminal[0], perr)
		show_notice(w, tr(w, "Não foi possível abrir o terminal", "Could not open the terminal"))
	}
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------
@(private)
settings_action :: proc(w: ^Wizard, action: Action, arg: int) {
	s := &w.set
	#partial switch action {
	case .Section:
		sec := Section(clamp(arg, 0, len(Section) - 1))
		if sec != s.section {
			capture_stop(w)
			s.avatar.picking = false
			s.areas.picking = -1
			s.section = sec
			w.focus = .None
			w.hover = {}
			if sec == .Keyboard { keyboard_reveal(w) }
		}
	case .Step:
		ctrl := Control(arg / 10)
		dir := arg % 10 == 1 ? 1 : -1
		step_control(w, ctrl, dir)
	case .Toggle:
		toggle_control(w, Control(arg))
	case .Choice:
		ctrl := Control(arg / 100)
		opt := arg % 100
		#partial switch ctrl {
		case .Anim_Speed:
			scales := ANIM_SCALES
			s.anim_scale = scales[clamp(opt, 0, 3)]
			set_edit(w, "appearance.animationScale", json.Float(s.anim_scale))
		case .Notif_Position:
			s.notif_position = opt
			set_edit(w, "notifications.position", json.String(opt == 1 ? "bottom-right" : "top-right"))
		case:
			if !windows_choice(w, ctrl, opt) && !display_choice(w, ctrl, opt) { return }
		}
		settings_changed(w, .Values)
	case .Win_Tab:
		s.win_tab = clamp(arg, 0, 2)
	case .Look_Tab:
		s.look_tab = clamp(arg, 0, 1)
	case .Avatar_Pick:
		s.avatar.picking = true
		s.avatar.scroll = 0
	case .Avatar_Back:
		s.avatar.picking = false
	case .Avatar_Tile:
		avatar_choose(w, arg)
	case .Avatar_Remove:
		avatar_remove(w)
	case .Text_Field:
		w.focus = .Text
		s.text_target = arg
		if Control(arg / 100) == .Th_Hex { ted_select_slot(w, Theme_Slot(clamp(arg % 100, 0, len(Theme_Slot) - 1))) }
	case .Rerun_Wizard:
		path := join_path({w.runtime_root, MARKER_NAME})
		if os.exists(path) { _ = os.remove(path) }
		show_notice(w, tr(w, "O assistente abrirá no próximo início", "The wizard will open next time"))
	case .Update_Milk:
		run_update_in_terminal(w)
	case .Fx_Open:
		open_lactase_settings(w)
	case .Lock_Now:
		lock_now(w) // lock.odin
	case .Open_Config:
		desc := os.Process_Desc{command = {"xdg-open", w.config_path}}
		if p, err := os.process_start(desc); err == nil {
			_ = p
		} else {
			log.warnf("Settings: cannot run xdg-open: %v", err)
		}
	}
	w.dirty = true
}

@(private)
step_control :: proc(w: ^Wizard, ctrl: Control, dir: int) {
	s := &w.set
	#partial switch ctrl {
	case .Bar_Height:
		s.bar_height = clamp(s.bar_height + 2 * dir, 24, 80)
		set_edit(w, "bar.height", json.Integer(s.bar_height))
	case .Bar_Opacity:
		s.bar_opacity = clamp(math.round((s.bar_opacity + 0.05 * f64(dir)) * 100) / 100, 0.3, 1)
		set_edit(w, "bar.opacity", json.Float(s.bar_opacity))
	case .Scr_Interval:
		scr_step_interval(w, dir) // saved with the script
		w.dirty = true
		return
	case .Bar_Margin:
		s.bar_margin = clamp(s.bar_margin + 2 * dir, 0, 60)
		set_edit(w, "bar.margin", json.Integer(s.bar_margin))
	case .Bar_Radius:
		s.bar_radius = clamp(s.bar_radius + 2 * dir, 0, 40)
		set_edit(w, "bar.radius", json.Integer(s.bar_radius))
	case .Wm_Gaps:
		s.gaps = clamp(s.gaps + 2 * dir, 0, 60)
		set_edit(w, "wm.gaps", json.Integer(s.gaps))
	case .Wm_Border:
		s.border = clamp(s.border + dir, 0, 10)
		set_edit(w, "wm.borderWidth", json.Integer(s.border))
	case .Wm_Master:
		s.master = clamp(math.round((s.master + 0.05 * f64(dir)) * 100) / 100, 0.2, 0.8)
		set_edit(w, "wm.masterFactor", json.Float(s.master))
	case .Wm_Animation:
		s.animation_ms = clamp(s.animation_ms + 30 * dir, 0, 600)
		set_edit(w, "wm.animation", json.Integer(s.animation_ms))
	case .Wm_Corners:
		s.corner_radius = clamp((s.corner_radius / 2) * 2 + 2 * dir, 0, 24)
		set_edit(w, "wm.cornerRadius", json.Integer(s.corner_radius))
	case .Notif_Timeout:
		s.notif_timeout = clamp(s.notif_timeout + dir, 1, 60)
		set_edit(w, "notifications.timeout", json.Integer(s.notif_timeout))
	case .Clip_Max:
		s.clip_max = clamp(s.clip_max + 10 * dir, 10, 500)
		set_edit(w, "clipboard.maxItems", json.Integer(s.clip_max))
	case:
		if !windows_step(w, ctrl, dir) && !display_step(w, ctrl, dir) && !lock_step(w, ctrl, dir) { return }
	}
	settings_changed(w, .Values)
}

@(private)
toggle_control :: proc(w: ^Wizard, ctrl: Control) {
	s := &w.set
	#partial switch ctrl {
	case .Wm_Focus_Follows:
		s.focus_follows = !s.focus_follows
		set_edit(w, "wm.focusFollowsMouse", json.Boolean(s.focus_follows))
	case .Notif_Enabled:
		s.notif_enabled = !s.notif_enabled
		set_edit(w, "notifications.enabled", json.Boolean(s.notif_enabled))
	case .Notif_Dnd:
		s.notif_dnd = !s.notif_dnd
		set_edit(w, "notifications.doNotDisturb", json.Boolean(s.notif_dnd))
	case .Clip_Enabled:
		s.clip_enabled = !s.clip_enabled
		set_edit(w, "clipboard.enabled", json.Boolean(s.clip_enabled))
	case .Clip_Persist:
		s.clip_persist = !s.clip_persist
		set_edit(w, "clipboard.persist", json.Boolean(s.clip_persist))
	case .Fx_Enabled:
		s.fx_enabled = !s.fx_enabled
		set_edit(w, "compositor.enabled", json.Boolean(s.fx_enabled))
	case .Theme_Apps:
		s.theme_apps = !s.theme_apps
		set_edit(w, "appearance.themeApps", json.Boolean(s.theme_apps))
	case:
		if !windows_toggle(w, ctrl) && !display_toggle(w, ctrl) && !lock_toggle(w, ctrl) && !areas_toggle(w, ctrl) { return }
	}
	settings_changed(w, .Values)
}

// Text fields: the date/clock formats and the area names.
@(private)
settings_text_buffer :: proc(w: ^Wizard) -> ^[dynamic]u8 {
	s := &w.set
	ctrl := Control(s.text_target / 100)
	#partial switch ctrl {
	case .Bar_Date:  return &s.date_format
	case .Bar_Clock: return &s.clock_format
	case .Area_Name:
		i := s.text_target % 100
		if i >= 0 && i < len(s.names) { return &s.names[i] }
	case .Sc_Command: return &s.sc.ed.command
	case .Sc_Site:    return &s.sc.ed.site
	case .Sc_Search:  return &s.sc.ed.search
	case .Th_Name:    return &s.ted.name
	case .Th_Hex:
		i := s.text_target % 100
		if i >= 0 && i < len(Theme_Slot) { return &s.ted.hex[Theme_Slot(i)] }
	case .Nl_From, .Nl_To, .Nl_Lat, .Nl_Lon:
		return display_text_buffer(w, ctrl)
	case .Scr_Name:      return &s.scr.ed.name
	case .Scr_Exec:      return &s.scr.ed.exec
	case .Scr_Click:     return &s.scr.ed.click
	case .Scr_Icon_Name: return &s.scr.ed.icon
	}
	return nil
}

@(private)
settings_text_insert :: proc(w: ^Wizard, text: string) {
	buf := settings_text_buffer(w)
	ctrl := Control(w.set.text_target / 100)
	limit := ctrl >= .Sc_Command ? 240 : 48
	if ctrl == .Th_Name { limit = config.CUSTOM_THEME_NAME_MAX }
	if ctrl == .Th_Hex { limit = 7 }
	#partial switch ctrl {
	case .Scr_Name:             limit = config.SCRIPT_NAME_MAX
	case .Scr_Exec, .Scr_Click: limit = 4000
	case .Scr_Icon_Name:        limit = 64
	}
	if buf == nil || len(buf) + len(text) > limit { return }
	append(buf, ..transmute([]u8)text)
	settings_text_edited(w)
}

@(private)
settings_text_edited :: proc(w: ^Wizard) {
	s := &w.set
	if w.mode != .Settings { return }
	buf := settings_text_buffer(w)
	if buf == nil { return }
	value := strings.trim_space(string(buf[:]))
	ctrl := Control(s.text_target / 100)
	#partial switch ctrl {
	case .Bar_Date:
		if value == "" { return } // an empty format is invalid: keep the saved one
		set_edit(w, "bar.dateFormat", json.String(value))
	case .Bar_Clock:
		if value == "" { return }
		set_edit(w, "bar.clockFormat", json.String(value))
	case .Area_Name:
		i := s.text_target % 100
		if i < 0 || i >= len(w.areas) { return }
		set_edit(w, fmt.tprintf("workspaces.%d.name", w.areas[i]), json.String(value))
	case .Sc_Search:
		s.sc.ed.scroll_apps = 0
		return
	case .Th_Name:
		s.ted.error = ""
		return // saved with the theme
	case .Th_Hex:
		ted_hex_edited(w, Theme_Slot(clamp(s.text_target % 100, 0, len(Theme_Slot) - 1)))
		return
	case .Nl_From, .Nl_To, .Nl_Lat, .Nl_Lon:
		if !display_text_edited(w, ctrl) { return } // saved once valid
	case .Scr_Name, .Scr_Exec, .Scr_Click, .Scr_Icon_Name:
		s.scr.ed.error = ""
		return // saved with the script
	case:
		return // editor fields are saved with the shortcut
	}
	settings_changed(w, .Text)
}

// ---------------------------------------------------------------------------
// Saving
// ---------------------------------------------------------------------------
@(private)
clone_value :: proc(v: json.Value) -> json.Value {
	if s, ok := v.(json.String); ok { return json.String(strings.clone(s)) }
	return v
}

@(private)
free_value :: proc(v: json.Value) {
	if s, ok := v.(json.String); ok { delete(s) }
}

// Queue milk.json key `path` (dotted) = value.
@(private)
set_edit :: proc(w: ^Wizard, path: string, value: json.Value) {
	s := &w.set
	if old, found := s.edits[path]; found {
		free_value(old)
		s.edits[path] = clone_value(value)
		return
	}
	s.edits[strings.clone(path)] = clone_value(value)
}

@(private)
clear_edits :: proc(w: ^Wizard) {
	s := &w.set
	for k, v in s.edits {
		delete(k)
		free_value(v)
	}
	clear(&s.edits)
}

// Something changed in the settings app: queue the keys and save soon.
@(private)
settings_changed :: proc(w: ^Wizard, change: Change) {
	if w.mode != .Settings { return }
	s := &w.set
	delay := 0.25
	switch change {
	case .Theme:
		name, colors, dark := chosen_theme(w)
		set_edit(w, "appearance.theme", json.String(name))
		set_edit(w, "appearance.variant", json.String(dark ? "dark" : "light"))
		set_edit(w, "appearance.matugenScheme", json.String(config.MATUGEN_SCHEMES[w.pal.scheme]))
		set_edit(w, "bar.theme.background", json.String(colors.bar.background))
		set_edit(w, "bar.theme.foreground", json.String(colors.bar.foreground))
		set_edit(w, "bar.theme.muted", json.String(colors.bar.muted))
		set_edit(w, "bar.theme.accent", json.String(colors.bar.accent))
		set_edit(w, "bar.theme.accentForeground", json.String(colors.bar.accent_foreground))
		set_edit(w, "bar.theme.surface", json.String(colors.bar.surface))
		set_edit(w, "bar.theme.warning", json.String(colors.bar.warning))
		set_edit(w, "wm.borderColor", json.String(colors.border_color))
		set_edit(w, "wm.focusColor", json.String(colors.focus_color))
	case .Keyboard:
		set_edit(w, "keyboard.layout", json.String(w.kb.layout))
		set_edit(w, "keyboard.variant", w.kb.variant == "" ? json.Value(json.Null(nil)) : json.Value(json.String(w.kb.variant)))
		delay = 0.4
	case .Wallpapers:
		s.wallpapers = true
		delay = 0.5
	case .Bar_Layout:
		set_edit(w, "bar.position", json.String(w.bar_top ? "top" : "bottom"))
		set_edit(w, "bar.style", json.String(w.bar_floating ? "floating" : "full"))
	case .Values:
		delay = 0.35
	case .Text:
		delay = 0.9
	}
	s.save_at = tx.now() + delay
	w.dirty = true
}

@(private)
settings_tick :: proc(w: ^Wizard, now: f64) {
	s := &w.set
	if s.sc.icons_pending {
		s.sc.icons_pending = false
		w.dirty = true
	}
	if s.save_at > 0 && now >= s.save_at { settings_save(w) }
	if s.notice != "" && now >= s.notice_until {
		s.notice = ""
		w.dirty = true
	}
	effects_tick(w, now)
	palette_view_tick(w, now)
	scr_tick(w, now)
}

@(private)
settings_timeout :: proc(w: ^Wizard, now: f64) -> f64 {
	s := &w.set
	t := -1.0
	if s.sc.icons_pending { return 0 }
	if s.save_at > 0 { t = max(s.save_at - now, 0) }
	if s.notice != "" {
		n := max(s.notice_until - now, 0)
		if t < 0 || n < t { t = n }
	}
	if ft := effects_timeout(w, now); ft >= 0 && (t < 0 || ft < t) { t = ft }
	if pt := palette_view_timeout(w, now); pt >= 0 && (t < 0 || pt < t) { t = pt }
	if st := scr_timeout(w); st >= 0 && (t < 0 || st < t) { t = st }
	return t
}

@(private)
show_notice :: proc(w: ^Wizard, text: string) {
	w.set.notice = text // literals only
	w.set.notice_until = tx.now() + NOTICE_TIME
	w.dirty = true
}

@(private)
settings_save :: proc(w: ^Wizard) {
	s := &w.set
	s.save_at = 0
	if s.wallpapers {
		s.wallpapers = false
		if names, ok := copy_wallpapers(w); ok {
			for n, i in w.areas {
				path := fmt.tprintf("workspaces.%d.wallpaper", n)
				set_edit(w, path, names[i] == "" ? json.Value(json.Null(nil)) : json.Value(json.String(names[i])))
			}
		}
	}
	if len(s.edits) == 0 && !s.sc.dirty && !s.themes_dirty && !s.lay.dirty && !s.scr.dirty { return }
	theme_changed := "appearance.theme" in s.edits || "appearance.variant" in s.edits
	themes_changed := s.themes_dirty
	if !write_edits(w) {
		show_notice(w, tr(w, "Não foi possível salvar", "Could not save"))
		return
	}
	clear_edits(w)
	s.sc.dirty = false
	s.themes_dirty = false
	s.lay.dirty = false
	s.scr.dirty = false
	s.saved_any = true
	if theme_changed { update_alacritty(w) }
	if themes_changed { remove_stale_alacritty(w) }
	if signal_reload(w) {
		show_notice(w, tr(w, "Salvo e aplicado", "Saved and applied"))
	} else {
		show_notice(w, tr(w, "Salvo", "Saved"))
	}
}

// Apply the queued edits to milk.json (parse, set, write back sorted, atomically).
@(private)
write_edits :: proc(w: ^Wizard) -> bool {
	path := w.config_path
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		log.errorf("Settings: cannot read %s: %v", path, rerr)
		return false
	}
	value, perr := json.parse(data, .JSON5, true, context.temp_allocator)
	root, is_obj := value.(json.Object)
	if perr != .None || !is_obj {
		log.errorf("Settings: cannot parse %s (%v); not changing it", path, perr)
		return false
	}
	ensure_workspaces(&root, w.areas[:])
	for key, v in w.set.edits {
		json_set(&root, strings.split(key, ".", context.temp_allocator), v)
	}
	if w.set.sc.dirty {
		// wm.bindings, wm.keys and wm.defaultKeys are rewritten whole: removed shortcuts must disappear.
		bindings := make(json.Object, context.temp_allocator)
		keys := make(json.Object, context.temp_allocator)
		for r in w.set.sc.rows {
			if r.action { keys[r.spec] = json.String(r.command) } else { bindings[r.spec] = json.String(r.command) }
		}
		json_set(&root, {"wm", "bindings"}, bindings)
		json_set(&root, {"wm", "keys"}, keys)
		defaults := make(json.Object, context.temp_allocator)
		for id, specs in w.set.sc.overrides { defaults[id] = json.String(specs) }
		json_set(&root, {"wm", "defaultKeys"}, defaults)
	}
	if w.set.themes_dirty {
		// Rewritten whole too: renamed and deleted themes must disappear.
		json_set(&root, {"appearance", "customThemes"}, themes_json(w))
	}
	if w.set.scr.dirty {
		// Rewritten whole: renamed and deleted scripts must disappear (bar.start/center/end follow below).
		json_set(&root, {"bar", "scripts"}, scripts_json(w))
	}
	if w.set.lay.dirty {
		json_set(&root, {"bar", "start"}, lay_json(w, 0))
		json_set(&root, {"bar", "center"}, lay_json(w, 1))
		json_set(&root, {"bar", "end"}, lay_json(w, 2))
	}
	return write_json(root, path)
}

// Set root[path...] = value, creating objects on the way (maps are written
// back into their parents, as inserting may move them).
@(private)
json_set :: proc(obj: ^json.Object, path: []string, value: json.Value) {
	if len(path) == 0 { return }
	if len(path) == 1 {
		obj^[path[0]] = value
		return
	}
	child := json_child(obj^, path[0])
	json_set(&child, path[1:], value)
	obj^[path[0]] = child
}

// Ask the running milk to re-read milk.json (SIGHUP to the pid in the runtime folder).
@(private)
signal_reload :: proc(w: ^Wizard) -> bool {
	for name in ([]string{"milk.pid", "Temenos.pid"}) {
		data, err := os.read_entire_file(join_path({w.runtime_root, name}), context.temp_allocator)
		if err != nil { continue }
		pid, ok := strconv.parse_int(strings.trim_space(string(data)), 10)
		if !ok || pid <= 0 { continue }
		cmdline, cerr := os.read_entire_file(fmt.tprintf("/proc/%d/cmdline", pid), context.temp_allocator)
		if cerr != nil { continue }
		if !strings.contains(string(cmdline), "milk") && !strings.contains(string(cmdline), "temenos") { continue }
		if posix.kill(posix.pid_t(pid), .SIGHUP) == .OK {
			log.infof("Settings: asked milk (pid %d) to reload", pid)
			return true
		}
	}
	return false
}
