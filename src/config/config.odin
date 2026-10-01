// Package config: milk.json loader.
//
// Mirrors windows/src/Config.ps1 (same file, same validation rules) and adds
// two optional sections used only on Linux: "linux" (wallpaper mode, indicator,
// shortcut rendering) and "bar" (the status bar).
package config

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

WALLPAPER_MODES     :: []string{"fill", "scale", "center", "max", "tile"}
SHORTCUT_MODES      :: []string{"layer", "folder", "none"}
INDICATOR_POSITIONS :: []string{"center", "top", "bottom"}
BAR_POSITIONS       :: []string{"top", "bottom"}
OVERRIDE_MODES      :: []string{"auto", "always", "never"}
// Globals (not constants): a constant slice would be re-materialised on the
// stack of whoever uses it, and default_bar() hands these out to the loader.
@(rodata) DEFAULT_BAR_START  := []string{"launcher", "active_window"}
@(rodata) DEFAULT_BAR_CENTER := []string{"workspaces", "media"}
@(rodata) DEFAULT_BAR_END    := []string{"clipboard", "network", "bluetooth", "volume", "brightness", "battery", "date", "clock", "notifications", "settings", "session"}
BAR_WIDGETS         :: []string{"launcher", "active_window", "workspaces", "media", "spacer", "notifications", "clipboard",
                                 "recorder", "network", "bluetooth", "volume", "brightness", "battery", "date", "clock", "settings", "session",
                                 "tasks"}
DESKTOP_ICON_SORTS  :: []string{"name", "type", "modified"}

Workspace :: struct {
	index:     int,
	name:      string,
	folder:    string,
	wallpaper: string, // "" when null / not configured
}

Paths :: struct {
	common:          string,
	wallpapers:      string,
	wallpaper_cache: string,
}

Indicator_Options :: struct {
	enabled:   bool,
	duration:  f64,    // seconds
	font:      string, // fontconfig pattern
	font_size: f64,    // points (96 DPI)
	position:  string, // center | top | bottom
}

Shortcut_Options :: struct {
	mode:         string, // layer | folder | none
	icon_size:    int,
	single_click: bool,
	font:         string,
	font_size:    f64,
	icon_theme:   string, // "" = detect
	margins:      [4]int, // top, right, bottom, left
	monitor:      string, // "primary" or a RandR output name
}

// Files of a folder (the XDG Desktop folder by default) as desktop icons,
// next to the area shortcuts; drawn with the look of linux.shortcuts.
Desktop_Icon_Options :: struct {
	enabled:     bool,
	folder:      string, // "" = the XDG Desktop folder (XDG_DESKTOP_DIR)
	show_hidden: bool,   // dot files
	sort:        string, // name | type | modified: order of icons that have no saved place
	thumbnails:  bool,   // previews of images instead of their type icon
}

Linux_Options :: struct {
	wallpaper_mode: string,
	indicator:      Indicator_Options,
	shortcuts:      Shortcut_Options,
	desktop_icons:  Desktop_Icon_Options,
}

Bar_Theme :: struct {
	background:        string, // hex colours
	foreground:        string,
	muted:             string,
	accent:            string,
	accent_foreground: string,
	surface:           string,
	warning:           string,
}

Bar_Options :: struct {
	enabled:               bool,
	height:                int,
	position:              string,   // top | bottom
	monitor:               string,   // "primary" or output name
	override_redirect:     string,   // auto | always | never  (auto: yes on dwm, no elsewhere)
	opacity:               f64,      // 0..1, blended over the wallpaper
	font:                  string,
	font_size:             int,      // pixels
	icon_font_file:        string,   // Tabler icon font (Noctalia's), "" = disabled
	icon_font:             string,   // fallback fontconfig pattern for icons (Nerd Font)
	icon_size:             int,      // pixels
	theme:                 Bar_Theme,
	start:                 []string, // widget ids, left group
	center:                []string,
	end:                   []string,
	commands:              map[string]string, // widget id -> shell command on click
	launcher_icon:         string,   // image path (svg/png) or "" for a glyph
	date_format:           string,   // strftime subset: %a %d %b %m %Y %H %M
	clock_format:          string,
	locale:                string,   // "auto" (the system language) | "pt-BR" | "en" | "es"
	language:              Language, // resolved from locale when the file is read
	media_idle_text:       string,
	title_max_width:       int,
	show_empty_workspaces: bool,
	spacing:               int,      // gap between widgets
	spacer_width:          int,      // width of an explicit "spacer" widget
	style:                 string,   // full (edge to edge) | floating (margins, rounded corners)
	margin:                int,      // floating: gap to the screen edges, pixels
	radius:                int,      // floating: corner radius, pixels
}

BAR_STYLES :: []string{"full", "floating"}
THEME_VARIANTS :: []string{"light", "dark"}

// Colour theme of the whole suite (bar, panels, toast, borders, terminal).
Appearance_Options :: struct {
	theme:           string,         // a THEME_PRESETS name, one of custom_themes or WALLPAPER_THEME (palette.odin)
	variant:         string,         // light | dark
	animation_scale: f64,            // multiplies every UI/window animation duration: 0 = off, 0.5 = twice as fast, 1 = normal
	custom_themes:   []Custom_Theme, // appearance.customThemes, sorted by name
	matugen_scheme:  string,         // the "wallpaper" theme's matugen scheme (MATUGEN_SCHEMES)
}

// A theme made by the user in the settings app:
//     "customThemes": { "Meu tema": { "variant": "dark", "background": "#1E1E2E", ... } }
// with the colour keys of bar.theme plus borderColor and focusColor (#RRGGBB);
// missing colours come from the milk preset of the same variant.
Custom_Theme :: struct {
	name:   string,
	dark:   bool,
	colors: Theme_Colors, // owned strings
}

CUSTOM_THEME_NAME_MAX :: 40 // bytes

// Duration of an animation of `seconds` at the configured speed (0 = no animation).
anim_duration :: proc(cfg: ^Config, seconds: f64) -> f64 {
	if cfg == nil { return seconds }
	return seconds * clamp(cfg.appearance.animation_scale, 0, 3)
}

// Notification daemon (org.freedesktop.Notifications) and its side panel.
Notification_Options :: struct {
	enabled:         bool,
	timeout:         f64,    // seconds a popup stays when the sender does not say (expire_timeout -1)
	max_history:     int,    // notifications kept in the panel
	do_not_disturb:  bool,   // no popups; history still collected
	position:        string, // popups: top-right | bottom-right
}

// Clipboard history (text and images) and its panel.
Clipboard_Options :: struct {
	enabled:         bool,
	max_items:       int,
	max_image_bytes: int,  // larger images are not kept
	persist:         bool, // keep the history in <runtime>/Clipboard across restarts
}

NOTIFICATION_POSITIONS :: []string{"top-right", "bottom-right"}

// lactase, milk's compositor (shadows, fades, transparency, blur, smooth
// corners). Its own settings live in lactase.json; milk only starts it.
Compositor_Options :: struct {
	enabled: bool, // run lactase with milk when it is installed (next to milk or on $PATH)
}

// Keyboard (applied with setxkbmap when milk starts; "" keeps the X server's setting).
Keyboard_Options :: struct {
	layout:  string, // xkb layouts, comma separated: "br", "us,br"
	variant: string, // xkb variants: "abnt2", "intl", ...
	model:   string, // "pc105"
	options: string, // xkb options: "grp:alt_shift_toggle,caps:escape"
}

// A theme preset: every colour milk draws with.
Theme_Colors :: struct {
	bar:          Bar_Theme, // hex strings, the same fields as bar.theme
	border_color: string,    // wm.borderColor
	focus_color:  string,    // wm.focusColor
}

Theme_Preset :: struct {
	name:  string, // id used in appearance.theme
	title: string, // shown by the setup wizard
	light: Theme_Colors,
	dark:  Theme_Colors,
}

// Built-in themes, each with a light and a dark variant. "milk" is the
// Noctalia-like cream/espresso look.
@(rodata) THEME_PRESETS := []Theme_Preset{
	{name = "milk", title = "Milk",
	 light = {bar = {background = "#F5EEE6", foreground = "#3C3A38", muted = "#A89E94", accent = "#4A3F35",
	                 accent_foreground = "#F5EEE6", surface = "#E9E0D6", warning = "#B5473A"},
	          border_color = "#D8CEC3", focus_color = "#4A3F35"},
	 dark  = {bar = {background = "#211D1A", foreground = "#EDE3D8", muted = "#8C8279", accent = "#D9C3A5",
	                 accent_foreground = "#211D1A", surface = "#2E2925", warning = "#E07A6A"},
	          border_color = "#3A342F", focus_color = "#D9C3A5"}},
	{name = "matcha", title = "Matcha",
	 light = {bar = {background = "#EEF2E6", foreground = "#2F3A2B", muted = "#8F9A86", accent = "#4E6B3A",
	                 accent_foreground = "#EEF2E6", surface = "#DDE5D1", warning = "#B5473A"},
	          border_color = "#CBD5BE", focus_color = "#4E6B3A"},
	 dark  = {bar = {background = "#1B211A", foreground = "#E1E9D8", muted = "#7F8B76", accent = "#A7C58A",
	                 accent_foreground = "#1B211A", surface = "#263025", warning = "#E07A6A"},
	          border_color = "#303A2E", focus_color = "#A7C58A"}},
	{name = "blueberry", title = "Blueberry",
	 light = {bar = {background = "#ECEEF6", foreground = "#2B3040", muted = "#8A90A6", accent = "#3F4F86",
	                 accent_foreground = "#ECEEF6", surface = "#DCE0EE", warning = "#B5473A"},
	          border_color = "#C9CEE0", focus_color = "#3F4F86"},
	 dark  = {bar = {background = "#191B24", foreground = "#E0E4F2", muted = "#7D839C", accent = "#9FB0F0",
	                 accent_foreground = "#191B24", surface = "#242735", warning = "#E07A6A"},
	          border_color = "#2F3345", focus_color = "#9FB0F0"}},
}

// The preset colours for a theme name and variant (falls back to milk light).
theme_preset :: proc(name, variant: string) -> Theme_Colors {
	for p in THEME_PRESETS {
		if p.name == name { return variant == "dark" ? p.dark : p.light }
	}
	return THEME_PRESETS[0].light
}

// The user's theme called `name`, if there is one.
custom_theme :: proc(cfg: ^Config, name: string) -> (^Custom_Theme, bool) {
	if cfg == nil { return nil, false }
	for &t in cfg.appearance.custom_themes {
		if t.name == name { return &t, true }
	}
	return nil, false
}

// Colours of the configured theme (appearance.theme/variant), preset or custom.
current_theme_colors :: proc(cfg: ^Config) -> (colors: Theme_Colors, dark: bool) {
	if t, ok := custom_theme(cfg, cfg.appearance.theme); ok { return t.colors, t.dark }
	dark = cfg.appearance.variant == "dark"
	return theme_preset(cfg.appearance.theme, cfg.appearance.variant), dark
}

// "#RRGGBB".
is_hex_color :: proc(s: string) -> bool {
	if len(s) != 7 || s[0] != '#' { return false }
	for ch in s[1:] {
		switch ch {
		case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
		case: return false
		}
	}
	return true
}

// A usable custom theme name: 1..CUSTOM_THEME_NAME_MAX bytes, no surrounding
// spaces or control characters, and not the name of a built-in theme.
valid_custom_theme_name :: proc(name: string) -> bool {
	if name == "" || len(name) > CUSTOM_THEME_NAME_MAX || strings.trim_space(name) != name { return false }
	for r in name { if r < 0x20 || r == 0x7f { return false } }
	for p in THEME_PRESETS {
		if strings.equal_fold(p.name, name) || strings.equal_fold(p.title, name) { return false }
	}
	if strings.equal_fold(name, WALLPAPER_THEME) { return false }
	return true
}

WM_MOD_KEYS :: []string{"super", "alt"}
WM_MODES :: []string{"tiling", "floating"}
WM_PLACEMENTS :: []string{"smart", "center", "mouse", "cascade"}
TITLE_ALIGNS :: []string{"left", "center", "right"}
TITLE_BUTTON_STYLES :: []string{"icons", "circles"}
RULE_LAYERS :: []string{"above", "normal", "below"}

// A dwm-style rule: windows whose WM_CLASS / title match get these tags, floating state and monitor.
// The optional fields (openbox's <applications>) place and dress the window when it appears.
WM_Rule :: struct {
	class:       string, // WM_CLASS class, exact match ("" = any)
	instance:    string, // WM_CLASS instance, exact match ("" = any)
	title:       string, // substring of the window title ("" = any)
	tags:        uint,   // tag bitmask; 0 = the current tags
	floating:    bool,
	monitor:     int,    // -1 = the current monitor
	pip:         bool,   // treat as a picture-in-picture window (see wm)
	x, y:        Maybe(int),  // position in the monitor's window area (negative: from the right/bottom edge)
	center:      bool,        // "x"/"y": "center"
	width:       Maybe(int),
	height:      Maybe(int),
	maximized:   bool,
	minimized:   bool,
	fullscreen:  bool,
	sticky:      bool,        // on every area
	decorations: Maybe(bool), // title bar in floating mode (false = none)
	layer:       string,      // "" | above | normal | below
	focus:       Maybe(bool), // give it the focus when it appears
}

// Title bars of the floating mode (openbox's theme and titleLayout).
Title_Bar_Options :: struct {
	height:         int,
	layout:         string, // letters: N icon, L title, I minimize, M maximize, C close, S shade, D all areas, A always on top
	align:          string, // left | center | right
	font:           string, // "" = bar.font
	font_size:      int,    // pixels; 0 = bar.fontSize - 1
	button_style:   string, // icons | circles
	active_color:   string, // "" = from the theme; else #RRGGBB
	inactive_color: string,
	active_text:    string,
	inactive_text:  string,
}

// An entry of the root menu (wm.menu): a built-in action, a command, a
// separator or a submenu.
Menu_Item :: struct {
	label:     string,
	action:    string, // a WM action ("" when command, items or separator)
	command:   string, // shell command
	separator: bool,
	items:     []Menu_Item, // submenu
}

// Built-in window manager actions for wm.keys, wm.mouse and wm.menu, written
// "name" or "name argument". ACTIONS_WITH_ARGUMENT need one; "exec" takes the
// rest of the text as a shell command; "settings" takes an optional section.
WM_ACTIONS :: []string{
	"none", "close", "kill", "minimize", "maximize", "maximize-horizontal", "maximize-vertical", "restore",
	"fullscreen", "shade", "unshade", "above", "below", "sticky", "decorations", "center", "raise", "lower",
	"snap-left", "snap-right", "snap-top", "snap-bottom", "snap-top-left", "snap-top-right", "snap-bottom-left",
	"snap-bottom-right", "move", "resize", "window-menu", "root-menu", "window-list", "area-list",
	"switch-windows", "switch-windows-reverse", "show-desktop", "focus-next", "focus-prev", "toggle-floating",
	"view-next", "view-prev", "view-last", "send-next", "send-prev", "terminal", "launcher", "files",
	"screenshot", "clipboard", "notifications", "reload", "quit",
	"desktop-new-folder", "desktop-arrange", "desktop-open-folder",
	"view", "send", "layout", "focus-monitor", "send-monitor", "exec", "settings",
}
ACTIONS_WITH_ARGUMENT :: []string{"view", "send", "layout", "focus-monitor", "send-monitor", "exec"}
WM_LAYOUT_NAMES :: []string{"tile", "float", "monocle"}

// Mouse contexts and buttons for wm.mouse: "title:double", "root:right", "client:mod+left"...
MOUSE_CONTEXTS :: []string{"title", "icon", "root", "client"}
MOUSE_BUTTONS :: []string{"left", "middle", "right", "double", "scroll-up", "scroll-down"}

// wm.mouse defaults; the user's entries replace these one by one.
@(rodata) DEFAULT_MOUSE := [][2]string{
	{"title:double", "maximize"}, {"title:middle", "lower"}, {"title:right", "window-menu"},
	{"title:scroll-up", "shade"}, {"title:scroll-down", "unshade"},
	{"icon:left", "window-menu"}, {"icon:double", "close"},
	{"root:right", "root-menu"}, {"root:middle", "window-list"},
	{"root:scroll-up", "view-prev"}, {"root:scroll-down", "view-next"},
	{"client:mod+left", "move"}, {"client:mod+middle", "toggle-floating"}, {"client:mod+right", "resize"},
}

// Split "name argument" (the argument may be empty).
split_action :: proc(spec: string) -> (name, argument: string) {
	s := strings.trim_space(spec)
	if i := strings.index_any(s, " \t"); i >= 0 { return s[:i], strings.trim_space(s[i + 1:]) }
	return s, ""
}

// Whether `spec` names a built-in action with a usable argument.
valid_wm_action :: proc(spec: string) -> bool {
	name, arg := split_action(spec)
	known := false
	for a in WM_ACTIONS { if a == name { known = true; break } }
	if !known { return false }
	needs := false
	for a in ACTIONS_WITH_ARGUMENT { if a == name { needs = true; break } }
	if needs && arg == "" { return false }
	switch name {
	case "view", "send":
		n, ok := strconv.parse_int(arg, 10)
		return ok && n >= 1 && n <= 32
	case "layout":
		for l in WM_LAYOUT_NAMES { if l == arg { return true } }
		return false
	case "focus-monitor", "send-monitor":
		return arg == "next" || arg == "prev"
	case "exec", "settings":
		return true
	}
	return arg == ""
}

// Whether `spec` is a wm.mouse key: "context:button" with modifiers before the
// button for the client context ("client:mod+left", "client:alt+shift+right").
valid_mouse_binding :: proc(spec: string) -> bool {
	colon := strings.index_byte(spec, ':')
	if colon < 0 { return false }
	ctx := spec[:colon]
	parts := strings.split(spec[colon + 1:], "+", context.temp_allocator)
	known_ctx := false
	for c in MOUSE_CONTEXTS { if c == ctx { known_ctx = true; break } }
	if !known_ctx || len(parts) == 0 { return false }
	button := parts[len(parts) - 1]
	known_button := false
	for b in MOUSE_BUTTONS { if b == button { known_button = true; break } }
	if !known_button { return false }
	for m in parts[:len(parts) - 1] {
		switch strings.to_lower(m, context.temp_allocator) {
		case "mod", "super", "win", "alt", "ctrl", "control", "shift":
		case: return false
		}
	}
	return true
}

// The built-in dwm-inspired window manager.
WM_Options :: struct {
	enabled:             bool,
	mod_key:             string,            // super | alt
	terminal:            string,            // Mod+Shift+Return
	launcher:            string,            // Mod+p
	border_width:        int,
	border_color:        string,            // unfocused border (hex)
	focus_color:         string,            // focused border (hex)
	gaps:                int,               // pixels between tiled windows and the screen edge
	master_factor:       f64,               // 0.05 .. 0.95
	master_count:        int,
	resize_hints:        bool,              // honour size hints in tiled layouts (dwm's resizehints)
	focus_follows_mouse: bool,
	tag_count:           int,               // 1 .. 32
	animation:           int,               // milliseconds for window open/move/resize animations; 0 = off
	screenshot:          string,            // Mod+Shift+s command; "" = contrib/milk-screenshot
	file_manager:        string,            // Mod+e command; "" = Spoil next to milk (../spoil/spoil), else xdg-open ~
	corner_radius:       int,               // rounded window corners in pixels; 0 = square
	rules:               []WM_Rule,
	bindings:            map[string]string, // "super+shift+f" -> command to spawn
	// Floating mode (an openbox-like stacking window manager with title bars).
	mode:                string,            // tiling | floating
	title_bar:           Title_Bar_Options,
	placement:           string,            // smart | center | mouse | cascade: where new windows appear
	snap_distance:       int,               // resistance of screen edges and other windows while moving, pixels; 0 = off
	snap_layouts:        bool,              // dragging to a screen edge snaps to a half, a quarter or maximized
	resize_margin:       int,               // invisible border around windows for resizing with the mouse, pixels
	focus_new:           bool,              // new windows get the focus
	raise_on_focus:      bool,              // focus follows mouse also raises the window
	keys:                map[string]string, // "super+up" -> built-in action (see WM_ACTIONS)
	mouse:               map[string]string, // "title:double" -> action; DEFAULT_MOUSE merged with the user's entries
	menu:                []Menu_Item,       // root menu (right-click on the desktop)
	has_menu:            bool,              // false = milk's default menu
}

Config :: struct {
	version:    int,
	paths:      Paths,
	workspaces: map[int]Workspace,
	linux:      Linux_Options,
	bar:        Bar_Options,
	wm:         WM_Options,
	appearance:    Appearance_Options,
	notifications: Notification_Options,
	clipboard:     Clipboard_Options,
	keyboard:      Keyboard_Options,
	compositor:    Compositor_Options,
	allocator:  runtime_allocator,
}

runtime_allocator :: struct { _: int } // placeholder so Config stays a plain struct

workspace :: proc(cfg: ^Config, index: int) -> (Workspace, bool) {
	ws, ok := cfg.workspaces[index]
	return ws, ok
}

default_indicator :: proc() -> Indicator_Options {
	return {enabled = true, duration = 2.4, font = "sans:bold", font_size = 11, position = "bottom"}
}

default_shortcuts :: proc() -> Shortcut_Options {
	return {mode = "layer", icon_size = 48, single_click = false, font = "sans", font_size = 9,
	        icon_theme = "", margins = {8, 8, 8, 8}, monitor = "primary"}
}

// Defaults reproduce the Noctalia bar of the reference system (light theme).
// The strings and slices returned here are literals: they are only used as
// default values by the loader, which clones everything it stores.
default_bar :: proc() -> Bar_Options {
	b: Bar_Options
	b.enabled = true
	b.height = 40
	b.position = "top"
	b.monitor = "primary"
	b.override_redirect = "auto"
	b.opacity = 0.9
	b.font = "sans"
	b.font_size = 14
	b.icon_font_file = "/usr/share/noctalia/assets/fonts/noctalia-tabler.ttf"
	b.icon_font = "Symbols Nerd Font,MesloLGS Nerd Font,monospace"
	b.icon_size = 19
	b.theme = {background = "#F5EEE6", foreground = "#3C3A38", muted = "#A89E94", accent = "#4A3F35",
	           accent_foreground = "#F5EEE6", surface = "#E9E0D6", warning = "#B5473A"}
	b.start = DEFAULT_BAR_START
	b.center = DEFAULT_BAR_CENTER
	b.end = DEFAULT_BAR_END
	b.launcher_icon = "" // "" = milk's own logo; or an image path
	b.date_format = "%a %d %b"
	b.clock_format = "%H:%M"
	b.locale = "auto"
	b.language = resolve_language(b.locale)
	b.media_idle_text = "" // "" = "Nada Reproduzindo" / "Nothing playing" / … in milk's language
	b.title_max_width = 320
	b.show_empty_workspaces = true
	b.spacing = 14
	b.spacer_width = 10
	b.style = "full"
	b.margin = 8
	b.radius = 14
	return b
}

// Defaults follow dwm's config.def.h, with Super as the modifier. Strings and
// slices are literals: the loader clones what it stores.
default_wm :: proc() -> WM_Options {
	return {
		enabled = true, mod_key = "super", terminal = "alacritty", launcher = `rofi -show drun -theme "$MILK_ROFI_THEME"`,
		border_width = 2, border_color = "#444444", focus_color = "#4A3F35", gaps = 0,
		master_factor = 0.55, master_count = 1, resize_hints = true, focus_follows_mouse = true,
		tag_count = 9, animation = 180, screenshot = "", corner_radius = 10,
		mode = "tiling", title_bar = default_title_bar(), placement = "smart", snap_distance = 16,
		snap_layouts = true, resize_margin = 6, focus_new = true, raise_on_focus = false,
	}
}

default_title_bar :: proc() -> Title_Bar_Options {
	return {height = 32, layout = "NLIMC", align = "left", font = "", font_size = 0, button_style = "icons"}
}

default_desktop_icons :: proc() -> Desktop_Icon_Options {
	return {enabled = false, folder = "", show_hidden = false, sort = "name", thumbnails = true}
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------
Loader :: struct {
	err:  string,
	path: string,
}

@(private)
fail :: proc(l: ^Loader, format: string, args: ..any) -> bool {
	if l.err == "" { l.err = fmt.aprintf(format, ..args) }
	return false
}

@(private)
is_unsafe_relative :: proc(value: string) -> bool {
	if strings.trim_space(value) == "" { return true }
	if strings.has_prefix(value, "/") || strings.has_prefix(value, "\\") { return true }
	for part in strings.split(value, "/", context.temp_allocator) {
		for sub in strings.split(part, "\\", context.temp_allocator) {
			if sub == "." || sub == ".." { return true }
		}
	}
	return false
}

@(private)
relative_path :: proc(l: ^Loader, v: json.Value, field: string) -> (string, bool) {
	s, ok := v.(string)
	if !ok { return "", fail(l, "%s must be a string.", field) }
	if is_unsafe_relative(s) { return "", fail(l, "Invalid relative path in milk.json: %s", field) }
	return strings.clone(s), true
}

@(private)
get_string :: proc(l: ^Loader, obj: json.Object, key, scope: string, default_value: string, allow_null := false) -> (string, bool) {
	v, present := obj[key]
	if !present { return strings.clone(default_value), true }
	if _, is_null := v.(json.Null); is_null && allow_null { return "", true }
	s, ok := v.(string)
	if !ok || strings.trim_space(s) == "" { return "", fail(l, "%s.%s must be a non-empty string.", scope, key) }
	return strings.clone(s), true
}

@(private)
get_choice :: proc(l: ^Loader, obj: json.Object, key, scope: string, default_value: string, choices: []string) -> (string, bool) {
	s, ok := get_string(l, obj, key, scope, default_value)
	if !ok { return "", false }
	for c in choices { if c == s { return s, true } }
	delete(s)
	return "", fail(l, "%s.%s must be one of: %s", scope, key, strings.join(choices, ", ", context.temp_allocator))
}

@(private)
get_bool :: proc(l: ^Loader, obj: json.Object, key, scope: string, default_value: bool) -> (bool, bool) {
	v, present := obj[key]
	if !present { return default_value, true }
	b, ok := v.(bool)
	if !ok { return false, fail(l, "%s.%s must be true or false.", scope, key) }
	return b, true
}

@(private)
get_number :: proc(l: ^Loader, obj: json.Object, key, scope: string, default_value: f64, minimum: f64, maximum: f64 = 1e18) -> (f64, bool) {
	v, present := obj[key]
	if !present { return default_value, true }
	n: f64
	#partial switch x in v {
	case i64: n = f64(x)
	case f64: n = x
	case: return 0, fail(l, "%s.%s must be a number.", scope, key)
	}
	if n < minimum { return 0, fail(l, "%s.%s must be at least %v.", scope, key, minimum) }
	if n > maximum { return 0, fail(l, "%s.%s must be at most %v.", scope, key, maximum) }
	return n, true
}

@(private)
get_object :: proc(l: ^Loader, obj: json.Object, key, scope: string) -> (json.Object, bool) {
	v, present := obj[key]
	if !present { return nil, true }
	o, ok := v.(json.Object)
	if !ok { return nil, fail(l, "%s.%s must be an object.", scope, key) }
	return o, true
}

@(private)
reject_unknown :: proc(l: ^Loader, obj: json.Object, allowed: []string, scope: string) -> bool {
	for key, _ in obj {
		known := false
		for a in allowed { if a == key { known = true; break } }
		if !known { return fail(l, "Unknown key in %s: %s", scope, key) }
	}
	return true
}

@(private)
get_string_list :: proc(l: ^Loader, obj: json.Object, key, scope: string, default_value: []string, choices: []string = nil) -> ([]string, bool) {
	v, present := obj[key]
	if !present {
		out := make([]string, len(default_value))
		for s, i in default_value { out[i] = strings.clone(s) }
		return out, true
	}
	arr, ok := v.(json.Array)
	if !ok { return nil, fail(l, "%s.%s must be an array of strings.", scope, key) }
	out := make([dynamic]string)
	for item in arr {
		s, is_str := item.(string)
		if !is_str { return nil, fail(l, "%s.%s must contain only strings.", scope, key) }
		if choices != nil {
			found := false
			for c in choices { if c == s { found = true; break } }
			if !found { return nil, fail(l, "%s.%s: unknown widget %q (valid: %s)", scope, key, s, strings.join(choices, ", ", context.temp_allocator)) }
		}
		append(&out, strings.clone(s))
	}
	return out[:], true
}

@(private)
parse_linux :: proc(l: ^Loader, root: json.Object, out: ^Linux_Options) -> bool {
	// A missing section behaves like {}: indexing a nil json.Object yields "absent",
	// so every field below receives a freshly cloned default and destroy() can free it.
	ind_defaults := default_indicator()
	sc_defaults := default_shortcuts()
	section, ok := get_object(l, root, "linux", "milk.json")
	if !ok { return false }
	reject_unknown(l, section, {"wallpaperMode", "indicator", "shortcuts", "desktopIcons"}, "linux") or_return
	out.wallpaper_mode = get_choice(l, section, "wallpaperMode", "linux", "fill", WALLPAPER_MODES) or_return

	ind := get_object(l, section, "indicator", "linux") or_return
	{
		reject_unknown(l, ind, {"enabled", "duration", "font", "fontSize", "position"}, "linux.indicator") or_return
		out.indicator.enabled = get_bool(l, ind, "enabled", "linux.indicator", ind_defaults.enabled) or_return
		out.indicator.duration = get_number(l, ind, "duration", "linux.indicator", ind_defaults.duration, 0.1) or_return
		out.indicator.font = get_string(l, ind, "font", "linux.indicator", ind_defaults.font) or_return
		out.indicator.font_size = get_number(l, ind, "fontSize", "linux.indicator", ind_defaults.font_size, 4) or_return
		out.indicator.position = get_choice(l, ind, "position", "linux.indicator", ind_defaults.position, INDICATOR_POSITIONS) or_return
	}

	sc := get_object(l, section, "shortcuts", "linux") or_return
	{
		reject_unknown(l, sc, {"mode", "iconSize", "singleClick", "font", "fontSize", "iconTheme", "margins", "monitor"}, "linux.shortcuts") or_return
		out.shortcuts.mode = get_choice(l, sc, "mode", "linux.shortcuts", sc_defaults.mode, SHORTCUT_MODES) or_return
		size := get_number(l, sc, "iconSize", "linux.shortcuts", f64(sc_defaults.icon_size), 16, 256) or_return
		out.shortcuts.icon_size = int(size)
		out.shortcuts.single_click = get_bool(l, sc, "singleClick", "linux.shortcuts", sc_defaults.single_click) or_return
		out.shortcuts.font = get_string(l, sc, "font", "linux.shortcuts", sc_defaults.font) or_return
		out.shortcuts.font_size = get_number(l, sc, "fontSize", "linux.shortcuts", sc_defaults.font_size, 4) or_return
		out.shortcuts.icon_theme = get_string(l, sc, "iconTheme", "linux.shortcuts", "", true) or_return
		out.shortcuts.monitor = get_string(l, sc, "monitor", "linux.shortcuts", sc_defaults.monitor) or_return
		out.shortcuts.margins = sc_defaults.margins
		if mv, present := sc["margins"]; present {
			arr, is_arr := mv.(json.Array)
			if !is_arr || len(arr) != 4 { return fail(l, "linux.shortcuts.margins must be four non-negative integers: [top, right, bottom, left]") }
			for item, i in arr {
				n, is_int := item.(i64)
				if !is_int || n < 0 { return fail(l, "linux.shortcuts.margins must be four non-negative integers: [top, right, bottom, left]") }
				out.shortcuts.margins[i] = int(n)
			}
		}
	}

	di_defaults := default_desktop_icons()
	di := get_object(l, section, "desktopIcons", "linux") or_return
	{
		reject_unknown(l, di, {"enabled", "folder", "showHidden", "sort", "thumbnails"}, "linux.desktopIcons") or_return
		out.desktop_icons.enabled = get_bool(l, di, "enabled", "linux.desktopIcons", di_defaults.enabled) or_return
		out.desktop_icons.folder = get_string(l, di, "folder", "linux.desktopIcons", "", true) or_return
		out.desktop_icons.show_hidden = get_bool(l, di, "showHidden", "linux.desktopIcons", di_defaults.show_hidden) or_return
		out.desktop_icons.sort = get_choice(l, di, "sort", "linux.desktopIcons", di_defaults.sort, DESKTOP_ICON_SORTS) or_return
		out.desktop_icons.thumbnails = get_bool(l, di, "thumbnails", "linux.desktopIcons", di_defaults.thumbnails) or_return
	}
	return true
}

@(private)
parse_bar :: proc(l: ^Loader, root: json.Object, out: ^Bar_Options) -> bool {
	d := default_bar()
	out.commands = make(map[string]string)
	section, ok := get_object(l, root, "bar", "milk.json")
	if !ok { return false }
	reject_unknown(l, section, {"enabled", "height", "position", "monitor", "overrideRedirect", "opacity", "font", "fontSize",
	                            "iconFontFile", "iconFont", "iconSize", "theme", "start", "center", "end", "commands",
	                            "launcherIcon", "dateFormat", "clockFormat", "locale", "mediaIdleText", "titleMaxWidth",
	                            "showEmptyWorkspaces", "spacing", "spacerWidth", "style", "margin", "radius"}, "bar") or_return
	out.enabled = get_bool(l, section, "enabled", "bar", d.enabled) or_return
	h := get_number(l, section, "height", "bar", f64(d.height), 16, 200) or_return
	out.height = int(h)
	out.position = get_choice(l, section, "position", "bar", d.position, BAR_POSITIONS) or_return
	out.monitor = get_string(l, section, "monitor", "bar", d.monitor) or_return
	out.override_redirect = get_choice(l, section, "overrideRedirect", "bar", d.override_redirect, OVERRIDE_MODES) or_return
	out.opacity = get_number(l, section, "opacity", "bar", d.opacity, 0, 1) or_return
	out.font = get_string(l, section, "font", "bar", d.font) or_return
	fs := get_number(l, section, "fontSize", "bar", f64(d.font_size), 6, 64) or_return
	out.font_size = int(fs)
	out.icon_font_file = get_string(l, section, "iconFontFile", "bar", d.icon_font_file, true) or_return
	out.icon_font = get_string(l, section, "iconFont", "bar", d.icon_font) or_return
	is := get_number(l, section, "iconSize", "bar", f64(d.icon_size), 6, 64) or_return
	out.icon_size = int(is)
	theme := get_object(l, section, "theme", "bar") or_return
	reject_unknown(l, theme, {"background", "foreground", "muted", "accent", "accentForeground", "surface", "warning"}, "bar.theme") or_return
	out.theme.background = get_string(l, theme, "background", "bar.theme", d.theme.background) or_return
	out.theme.foreground = get_string(l, theme, "foreground", "bar.theme", d.theme.foreground) or_return
	out.theme.muted = get_string(l, theme, "muted", "bar.theme", d.theme.muted) or_return
	out.theme.accent = get_string(l, theme, "accent", "bar.theme", d.theme.accent) or_return
	out.theme.accent_foreground = get_string(l, theme, "accentForeground", "bar.theme", d.theme.accent_foreground) or_return
	out.theme.surface = get_string(l, theme, "surface", "bar.theme", d.theme.surface) or_return
	out.theme.warning = get_string(l, theme, "warning", "bar.theme", d.theme.warning) or_return
	out.start = get_string_list(l, section, "start", "bar", d.start, BAR_WIDGETS) or_return
	out.center = get_string_list(l, section, "center", "bar", d.center, BAR_WIDGETS) or_return
	out.end = get_string_list(l, section, "end", "bar", d.end, BAR_WIDGETS) or_return
	commands := get_object(l, section, "commands", "bar") or_return
	for key, value in commands {
		s, is_str := value.(string)
		if !is_str { return fail(l, "bar.commands.%s must be a string.", key) }
		out.commands[strings.clone(key)] = strings.clone(s)
	}
	out.launcher_icon = get_string(l, section, "launcherIcon", "bar", d.launcher_icon, true) or_return
	out.date_format = get_string(l, section, "dateFormat", "bar", d.date_format) or_return
	out.clock_format = get_string(l, section, "clockFormat", "bar", d.clock_format) or_return
	out.locale = get_string(l, section, "locale", "bar", d.locale) or_return
	out.language = resolve_language(out.locale)
	out.media_idle_text = get_string(l, section, "mediaIdleText", "bar", d.media_idle_text) or_return
	tw := get_number(l, section, "titleMaxWidth", "bar", f64(d.title_max_width), 40) or_return
	out.title_max_width = int(tw)
	out.show_empty_workspaces = get_bool(l, section, "showEmptyWorkspaces", "bar", d.show_empty_workspaces) or_return
	sp := get_number(l, section, "spacing", "bar", f64(d.spacing), 0) or_return
	out.spacing = int(sp)
	sw := get_number(l, section, "spacerWidth", "bar", f64(d.spacer_width), 0) or_return
	out.spacer_width = int(sw)
	out.style = get_choice(l, section, "style", "bar", d.style, BAR_STYLES) or_return
	mg := get_number(l, section, "margin", "bar", f64(d.margin), 0, 100) or_return
	out.margin = int(mg)
	rd := get_number(l, section, "radius", "bar", f64(d.radius), 0, 100) or_return
	out.radius = int(rd)
	return true
}

@(private)
parse_wm :: proc(l: ^Loader, root: json.Object, out: ^WM_Options) -> bool {
	d := default_wm()
	out.bindings = make(map[string]string)
	section, ok := get_object(l, root, "wm", "milk.json")
	if !ok { return false }
	reject_unknown(l, section, {"enabled", "modKey", "terminal", "launcher", "borderWidth", "borderColor", "focusColor",
	                            "gaps", "masterFactor", "masterCount", "resizeHints", "focusFollowsMouse", "tagCount",
	                            "animation", "screenshot", "fileManager", "cornerRadius", "rules", "bindings",
	                            "mode", "titleBar", "placement", "snapDistance", "snapLayouts", "resizeMargin",
	                            "focusNew", "raiseOnFocus", "keys", "mouse", "menu"}, "wm") or_return
	out.keys = make(map[string]string)
	out.mouse = make(map[string]string)
	for pair in DEFAULT_MOUSE { out.mouse[strings.clone(pair[0])] = strings.clone(pair[1]) }
	out.enabled = get_bool(l, section, "enabled", "wm", d.enabled) or_return
	out.mod_key = get_choice(l, section, "modKey", "wm", d.mod_key, WM_MOD_KEYS) or_return
	out.terminal = get_string(l, section, "terminal", "wm", d.terminal) or_return
	out.launcher = get_string(l, section, "launcher", "wm", d.launcher) or_return
	bw := get_number(l, section, "borderWidth", "wm", f64(d.border_width), 0, 20) or_return
	out.border_width = int(bw)
	out.border_color = get_string(l, section, "borderColor", "wm", d.border_color) or_return
	out.focus_color = get_string(l, section, "focusColor", "wm", d.focus_color) or_return
	gaps := get_number(l, section, "gaps", "wm", f64(d.gaps), 0, 200) or_return
	out.gaps = int(gaps)
	out.master_factor = get_number(l, section, "masterFactor", "wm", d.master_factor, 0.05, 0.95) or_return
	mc := get_number(l, section, "masterCount", "wm", f64(d.master_count), 0, 32) or_return
	out.master_count = int(mc)
	out.resize_hints = get_bool(l, section, "resizeHints", "wm", d.resize_hints) or_return
	out.focus_follows_mouse = get_bool(l, section, "focusFollowsMouse", "wm", d.focus_follows_mouse) or_return
	tc := get_number(l, section, "tagCount", "wm", f64(d.tag_count), 1, 32) or_return
	out.tag_count = int(tc)
	anim := get_number(l, section, "animation", "wm", f64(d.animation), 0, 2000) or_return
	out.animation = int(anim)
	out.file_manager = get_string(l, section, "fileManager", "wm", "", true) or_return
	cr := get_number(l, section, "cornerRadius", "wm", f64(d.corner_radius), 0, 64) or_return
	out.corner_radius = int(cr)
	// "" or null = the bundled helper (contrib/*-screenshot).
	out.screenshot = strings.clone("")
	if sv, present := section["screenshot"]; present {
		#partial switch v in sv {
		case json.Null:
		case string:
			delete(out.screenshot)
			out.screenshot = strings.clone(v)
		case:
			return fail(l, "wm.screenshot must be a string or null.")
		}
	}

	rules := make([dynamic]WM_Rule)
	if rv, present := section["rules"]; present {
		arr, is_arr := rv.(json.Array)
		if !is_arr { return fail(l, "wm.rules must be an array of objects.") }
		for item, i in arr {
			obj, is_obj := item.(json.Object)
			scope := fmt.tprintf("wm.rules[%d]", i)
			if !is_obj { return fail(l, "%s must be an object.", scope) }
			reject_unknown(l, obj, {"class", "instance", "title", "tags", "floating", "monitor", "pip", "x", "y", "width", "height",
			                        "maximized", "minimized", "fullscreen", "sticky", "decorations", "layer", "focus"}, scope) or_return
			// Appended first, so that destroy() frees what was cloned if a later field fails.
			append(&rules, WM_Rule{})
			out.rules = rules[:]
			rule := &rules[len(rules) - 1]
			rule.class = get_string(l, obj, "class", scope, "", true) or_return
			rule.instance = get_string(l, obj, "instance", scope, "", true) or_return
			rule.title = get_string(l, obj, "title", scope, "", true) or_return
			tags := get_number(l, obj, "tags", scope, 0, 0) or_return
			rule.tags = uint(tags)
			rule.floating = get_bool(l, obj, "floating", scope, false) or_return
			rule.pip = get_bool(l, obj, "pip", scope, false) or_return
			mon := get_number(l, obj, "monitor", scope, -1, -1) or_return
			rule.monitor = int(mon)
			for key in ([]string{"x", "y"}) {
				v, has := obj[key]
				if !has { continue }
				if s, is_str := v.(string); is_str && s == "center" {
					rule.center = true
					continue
				}
				n := get_number(l, obj, key, scope, 0, -100000, 100000) or_return
				if key == "x" { rule.x = int(n) } else { rule.y = int(n) }
			}
			if _, has := obj["width"]; has { rule.width = int(get_number(l, obj, "width", scope, 0, 1, 100000) or_return) }
			if _, has := obj["height"]; has { rule.height = int(get_number(l, obj, "height", scope, 0, 1, 100000) or_return) }
			rule.maximized = get_bool(l, obj, "maximized", scope, false) or_return
			rule.minimized = get_bool(l, obj, "minimized", scope, false) or_return
			rule.fullscreen = get_bool(l, obj, "fullscreen", scope, false) or_return
			rule.sticky = get_bool(l, obj, "sticky", scope, false) or_return
			if _, has := obj["decorations"]; has { rule.decorations = get_bool(l, obj, "decorations", scope, true) or_return }
			if _, has := obj["focus"]; has { rule.focus = get_bool(l, obj, "focus", scope, true) or_return }
			if _, has := obj["layer"]; has {
				rule.layer = get_choice(l, obj, "layer", scope, "normal", RULE_LAYERS) or_return
			} else {
				rule.layer = strings.clone("")
			}
		}
	}
	out.rules = rules[:]

	out.mode = get_choice(l, section, "mode", "wm", d.mode, WM_MODES) or_return
	out.placement = get_choice(l, section, "placement", "wm", d.placement, WM_PLACEMENTS) or_return
	sd := get_number(l, section, "snapDistance", "wm", f64(d.snap_distance), 0, 200) or_return
	out.snap_distance = int(sd)
	out.snap_layouts = get_bool(l, section, "snapLayouts", "wm", d.snap_layouts) or_return
	rm := get_number(l, section, "resizeMargin", "wm", f64(d.resize_margin), 0, 40) or_return
	out.resize_margin = int(rm)
	out.focus_new = get_bool(l, section, "focusNew", "wm", d.focus_new) or_return
	out.raise_on_focus = get_bool(l, section, "raiseOnFocus", "wm", d.raise_on_focus) or_return
	parse_title_bar(l, section, &out.title_bar) or_return

	keys := get_object(l, section, "keys", "wm") or_return
	for key, value in keys {
		action, is_str := value.(string)
		if !is_str || !valid_wm_action(action) {
			return fail(l, "wm.keys.%s must be a built-in action (e.g. \"maximize\", \"view 2\", \"exec firefox\").", key)
		}
		out.keys[strings.clone(key)] = strings.clone(strings.trim_space(action))
	}
	mouse := get_object(l, section, "mouse", "wm") or_return
	for key, value in mouse {
		if !valid_mouse_binding(key) {
			return fail(l, "wm.mouse: %q must be \"context:button\" (contexts: %s; buttons: %s; modifiers before the button).",
			            key, strings.join(MOUSE_CONTEXTS, ", ", context.temp_allocator), strings.join(MOUSE_BUTTONS, ", ", context.temp_allocator))
		}
		action, is_str := value.(string)
		if !is_str || !valid_wm_action(action) { return fail(l, "wm.mouse.%s must be a built-in action.", key) }
		if key in out.mouse {
			old_key, old_value := delete_key(&out.mouse, key)
			delete(old_key)
			delete(old_value)
		}
		out.mouse[strings.clone(key)] = strings.clone(strings.trim_space(action))
	}
	if mv, present := section["menu"]; present {
		if _, is_null := mv.(json.Null); !is_null {
			out.menu = parse_menu_items(l, mv, "wm.menu", 0) or_return
			out.has_menu = true
		}
	}

	bindings := get_object(l, section, "bindings", "wm") or_return
	for key, value in bindings {
		cmd, is_str := value.(string)
		if !is_str { return fail(l, "wm.bindings.%s must be a string.", key) }
		out.bindings[strings.clone(key)] = strings.clone(cmd)
	}
	return true
}

@(private)
parse_title_bar :: proc(l: ^Loader, section: json.Object, out: ^Title_Bar_Options) -> bool {
	d := default_title_bar()
	scope :: "wm.titleBar"
	tb := get_object(l, section, "titleBar", "wm") or_return
	reject_unknown(l, tb, {"height", "layout", "align", "font", "fontSize", "buttonStyle", "activeColor", "inactiveColor",
	                       "activeText", "inactiveText"}, scope) or_return
	h := get_number(l, tb, "height", scope, f64(d.height), 16, 80) or_return
	out.height = int(h)
	out.layout = get_string(l, tb, "layout", scope, d.layout) or_return
	for ch in out.layout {
		switch ch {
		case 'N', 'L', 'I', 'M', 'C', 'S', 'D', 'A':
		case: return fail(l, "%s.layout: unknown letter %q (N icon, L title, I minimize, M maximize, C close, S shade, D all areas, A always on top).", scope, ch)
		}
	}
	out.align = get_choice(l, tb, "align", scope, d.align, TITLE_ALIGNS) or_return
	out.font = get_string(l, tb, "font", scope, "", true) or_return
	fs := get_number(l, tb, "fontSize", scope, 0, 0, 64) or_return
	out.font_size = int(fs)
	out.button_style = get_choice(l, tb, "buttonStyle", scope, d.button_style, TITLE_BUTTON_STYLES) or_return
	out.active_color = get_optional_color(l, tb, "activeColor", scope) or_return
	out.inactive_color = get_optional_color(l, tb, "inactiveColor", scope) or_return
	out.active_text = get_optional_color(l, tb, "activeText", scope) or_return
	out.inactive_text = get_optional_color(l, tb, "inactiveText", scope) or_return
	return true
}

// A #RRGGBB colour or null ("" = follow the theme).
@(private)
get_optional_color :: proc(l: ^Loader, obj: json.Object, key, scope: string) -> (color: string, ok: bool) {
	s := get_string(l, obj, key, scope, "", true) or_return
	if s != "" && !is_hex_color(s) {
		delete(s)
		return "", fail(l, "%s.%s must be a colour written as #RRGGBB, or null.", scope, key)
	}
	return s, true
}

@(private)
MENU_MAX_DEPTH :: 4

// wm.menu entries: {"label", "action"} | {"label", "command"} | {"separator": true} | {"label", "items": [...]}.
@(private)
parse_menu_items :: proc(l: ^Loader, v: json.Value, scope: string, depth: int) -> ([]Menu_Item, bool) {
	arr, is_arr := v.(json.Array)
	if !is_arr { return nil, fail(l, "%s must be an array of menu entries.", scope) }
	if depth >= MENU_MAX_DEPTH { return nil, fail(l, "%s: menus nest at most %d levels deep.", scope, MENU_MAX_DEPTH) }
	items := make([]Menu_Item, len(arr))
	for entry, i in arr {
		item_scope := fmt.tprintf("%s[%d]", scope, i)
		obj, is_obj := entry.(json.Object)
		if !is_obj {
			destroy_menu_items(items)
			return nil, fail(l, "%s must be an object.", item_scope)
		}
		ok := parse_menu_item(l, obj, item_scope, depth, &items[i])
		if !ok {
			destroy_menu_items(items)
			return nil, false
		}
	}
	return items, true
}

@(private)
parse_menu_item :: proc(l: ^Loader, obj: json.Object, scope: string, depth: int, out: ^Menu_Item) -> bool {
	reject_unknown(l, obj, {"label", "action", "command", "separator", "items"}, scope) or_return
	out.separator = get_bool(l, obj, "separator", scope, false) or_return
	if out.separator {
		if len(obj) > 1 { return fail(l, "%s: a separator takes no other keys.", scope) }
		return true
	}
	out.label = get_string(l, obj, "label", scope, "", false) or_return
	if out.label == "" { return fail(l, "%s needs a label.", scope) }
	kinds := 0
	if _, present := obj["action"]; present {
		kinds += 1
		out.action = get_string(l, obj, "action", scope, "") or_return
		if !valid_wm_action(out.action) { return fail(l, "%s.action: unknown action %q.", scope, out.action) }
	}
	if _, present := obj["command"]; present {
		kinds += 1
		out.command = get_string(l, obj, "command", scope, "") or_return
	}
	if iv, present := obj["items"]; present {
		kinds += 1
		out.items = parse_menu_items(l, iv, fmt.tprintf("%s.items", scope), depth + 1) or_return
	}
	if kinds != 1 { return fail(l, "%s needs exactly one of action, command or items.", scope) }
	return true
}

destroy_menu_items :: proc(items: []Menu_Item) {
	for &item in items {
		delete(item.label)
		delete(item.action)
		delete(item.command)
		destroy_menu_items(item.items)
	}
	delete(items)
}

@(private)
parse_extras :: proc(l: ^Loader, root: json.Object, cfg: ^Config) -> bool {
	ap := get_object(l, root, "appearance", "milk.json") or_return
	reject_unknown(l, ap, {"theme", "variant", "animationScale", "customThemes", "matugenScheme"}, "appearance") or_return
	parse_custom_themes(l, ap, cfg) or_return
	names := make([dynamic]string, context.temp_allocator)
	for p in THEME_PRESETS { append(&names, p.name) }
	append(&names, WALLPAPER_THEME)
	for t in cfg.appearance.custom_themes { append(&names, t.name) }
	cfg.appearance.theme = get_choice(l, ap, "theme", "appearance", "milk", names[:]) or_return
	cfg.appearance.variant = get_choice(l, ap, "variant", "appearance", "light", THEME_VARIANTS) or_return
	cfg.appearance.matugen_scheme = get_choice(l, ap, "matugenScheme", "appearance", "tonal-spot", MATUGEN_SCHEMES) or_return
	cfg.appearance.animation_scale = get_number(l, ap, "animationScale", "appearance", 0.7, 0, 3) or_return

	no := get_object(l, root, "notifications", "milk.json") or_return
	reject_unknown(l, no, {"enabled", "timeout", "maxHistory", "doNotDisturb", "position"}, "notifications") or_return
	cfg.notifications.enabled = get_bool(l, no, "enabled", "notifications", true) or_return
	cfg.notifications.timeout = get_number(l, no, "timeout", "notifications", 5, 1, 3600) or_return
	mh := get_number(l, no, "maxHistory", "notifications", 100, 1, 1000) or_return
	cfg.notifications.max_history = int(mh)
	cfg.notifications.do_not_disturb = get_bool(l, no, "doNotDisturb", "notifications", false) or_return
	cfg.notifications.position = get_choice(l, no, "position", "notifications", "top-right", NOTIFICATION_POSITIONS) or_return

	cb := get_object(l, root, "clipboard", "milk.json") or_return
	reject_unknown(l, cb, {"enabled", "maxItems", "maxImageBytes", "persist"}, "clipboard") or_return
	cfg.clipboard.enabled = get_bool(l, cb, "enabled", "clipboard", true) or_return
	mi := get_number(l, cb, "maxItems", "clipboard", 50, 1, 500) or_return
	cfg.clipboard.max_items = int(mi)
	mb := get_number(l, cb, "maxImageBytes", "clipboard", 16 * 1024 * 1024, 0, 256 * 1024 * 1024) or_return
	cfg.clipboard.max_image_bytes = int(mb)
	cfg.clipboard.persist = get_bool(l, cb, "persist", "clipboard", true) or_return

	co := get_object(l, root, "compositor", "milk.json") or_return
	reject_unknown(l, co, {"enabled"}, "compositor") or_return
	cfg.compositor.enabled = get_bool(l, co, "enabled", "compositor", true) or_return

	kb := get_object(l, root, "keyboard", "milk.json") or_return
	reject_unknown(l, kb, {"layout", "variant", "model", "options"}, "keyboard") or_return
	cfg.keyboard.layout = get_string(l, kb, "layout", "keyboard", "", true) or_return
	cfg.keyboard.variant = get_string(l, kb, "variant", "keyboard", "", true) or_return
	cfg.keyboard.model = get_string(l, kb, "model", "keyboard", "", true) or_return
	cfg.keyboard.options = get_string(l, kb, "options", "keyboard", "", true) or_return
	return true
}

@(private)
get_color :: proc(l: ^Loader, obj: json.Object, key, scope: string, default_value: string) -> (string, bool) {
	s, ok := get_string(l, obj, key, scope, default_value)
	if !ok { return "", false }
	if !is_hex_color(s) {
		delete(s)
		return "", fail(l, "%s.%s must be a colour written as #RRGGBB.", scope, key)
	}
	return s, true
}

// appearance.customThemes: stored in cfg.appearance.custom_themes as they are
// parsed (so destroy() frees them after an error too), then sorted by name.
@(private)
parse_custom_themes :: proc(l: ^Loader, ap: json.Object, cfg: ^Config) -> bool {
	obj := get_object(l, ap, "customThemes", "appearance") or_return
	list := make([]Custom_Theme, len(obj))
	cfg.appearance.custom_themes = list[:0]
	n := 0
	for name, v in obj {
		scope := fmt.tprintf("appearance.customThemes.%s", name)
		if !valid_custom_theme_name(name) {
			return fail(l, "%s: a theme name must have 1 to %d characters, no leading or trailing spaces, and must not be a built-in theme name.",
			            scope, CUSTOM_THEME_NAME_MAX)
		}
		t, is_obj := v.(json.Object)
		if !is_obj { return fail(l, "%s must be an object.", scope) }
		reject_unknown(l, t, {"variant", "background", "foreground", "muted", "accent", "accentForeground", "surface", "warning",
		                      "borderColor", "focusColor"}, scope) or_return
		variant := get_choice(l, t, "variant", scope, "light", THEME_VARIANTS) or_return
		ct := &list[n]
		ct.dark = variant == "dark"
		delete(variant)
		ct.name = strings.clone(name)
		n += 1
		cfg.appearance.custom_themes = list[:n]
		base := theme_preset("milk", ct.dark ? "dark" : "light")
		c := &ct.colors
		c.bar.background = get_color(l, t, "background", scope, base.bar.background) or_return
		c.bar.foreground = get_color(l, t, "foreground", scope, base.bar.foreground) or_return
		c.bar.muted = get_color(l, t, "muted", scope, base.bar.muted) or_return
		c.bar.accent = get_color(l, t, "accent", scope, base.bar.accent) or_return
		c.bar.accent_foreground = get_color(l, t, "accentForeground", scope, base.bar.accent_foreground) or_return
		c.bar.surface = get_color(l, t, "surface", scope, base.bar.surface) or_return
		c.bar.warning = get_color(l, t, "warning", scope, base.bar.warning) or_return
		c.border_color = get_color(l, t, "borderColor", scope, base.border_color) or_return
		c.focus_color = get_color(l, t, "focusColor", scope, base.focus_color) or_return
	}
	// Map order is arbitrary: keep the themes sorted by name.
	themes := cfg.appearance.custom_themes
	for i in 1 ..< len(themes) {
		for j := i; j > 0 && themes[j].name < themes[j - 1].name; j -= 1 { themes[j], themes[j - 1] = themes[j - 1], themes[j] }
	}
	return true
}

@(private)
destroy_theme_colors :: proc(c: ^Theme_Colors) {
	delete(c.bar.background); delete(c.bar.foreground); delete(c.bar.muted); delete(c.bar.accent)
	delete(c.bar.accent_foreground); delete(c.bar.surface); delete(c.bar.warning)
	delete(c.border_color); delete(c.focus_color)
}

// Load and validate milk.json. `err` is "" on success.
load :: proc(path: string) -> (cfg: ^Config, err: string) {
	l := Loader{path = path}
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return nil, fmt.aprintf("Configuration file not found: %s", path)
	}
	value, perr := json.parse(data, .JSON5, true, context.temp_allocator)
	if perr != .None {
		return nil, fmt.aprintf("Could not read milk.json: %v", perr)
	}
	root, is_obj := value.(json.Object)
	if !is_obj { return nil, strings.clone("milk.json must contain a JSON object.") }

	cfg = new(Config)
	ok := parse_root(&l, root, cfg)
	if !ok {
		destroy(cfg)
		return nil, l.err
	}
	if cfg.appearance.theme == WALLPAPER_THEME { apply_wallpaper_palette(cfg) }
	return cfg, ""
}

@(private)
parse_root :: proc(l: ^Loader, root: json.Object, cfg: ^Config) -> bool {
	version, has_version := root["version"]
	v, is_int := version.(i64)
	if !has_version || !is_int || v != 1 { return fail(l, "Unsupported milk.json version. Expected version 1.") }
	cfg.version = 1

	paths, has_paths := root["paths"]
	pobj, pok := paths.(json.Object)
	if !has_paths || !pok { return fail(l, "Missing paths in milk.json.") }
	seen := make(map[string]bool, context.temp_allocator)
	values: [3]string
	for key, i in ([]string{"common", "wallpapers", "wallpaperCache"}) {
		raw, present := pobj[key]
		if !present { return fail(l, "Missing paths.%s in milk.json.", key) }
		value := relative_path(l, raw, fmt.tprintf("paths.%s", key)) or_return
		if seen[value] { return fail(l, "Runtime paths must be unique: %s", value) }
		seen[value] = true
		values[i] = value
	}
	cfg.paths = {common = values[0], wallpapers = values[1], wallpaper_cache = values[2]}

	wsraw, has_ws := root["workspaces"]
	wsobj, wok := wsraw.(json.Object)
	if !has_ws || !wok || len(wsobj) == 0 { return fail(l, "milk.json must define at least one workspace.") }
	cfg.workspaces = make(map[int]Workspace)
	folders := make(map[string]bool, context.temp_allocator)
	for key, entry in wsobj {
		index, parsed := strconv.parse_int(key, 10)
		if !parsed || index <= 0 || key[0] == '0' || key[0] == '+' || key[0] == '-' {
			return fail(l, "Invalid workspace id '%s' in milk.json. Use positive numbers.", key)
		}
		eobj, eok := entry.(json.Object)
		if !eok { return fail(l, "Workspace %s must define name, folder, and wallpaper.", key) }
		fraw, has_folder := eobj["folder"]
		nraw, has_name := eobj["name"]
		wraw, has_wp := eobj["wallpaper"]
		if !has_folder || !has_name || !has_wp { return fail(l, "Workspace %s must define name, folder, and wallpaper.", key) }
		if _, fstr := fraw.(string); !fstr { return fail(l, "Workspace %s folder must be a string.", key) }
		folder := relative_path(l, fraw, fmt.tprintf("workspaces.%s.folder", key)) or_return
		if seen[folder] { return fail(l, "Workspace folder conflicts with a shared runtime path: %s", folder) }
		if folders[folder] { return fail(l, "Workspace folders must be unique: %s", folder) }
		folders[folder] = true

		name := ""
		if _, is_null := nraw.(json.Null); !is_null {
			s, is_str := nraw.(string)
			if !is_str { return fail(l, "Workspace %s name must be a string or null.", key) }
			name = strings.clone(s)
		}
		wallpaper := ""
		if _, is_null := wraw.(json.Null); !is_null {
			s, is_str := wraw.(string)
			if !is_str { return fail(l, "Workspace %s wallpaper must be a string or null.", key) }
			if strings.trim_space(s) != "" {
				wallpaper = relative_path(l, wraw, fmt.tprintf("workspaces.%s.wallpaper", key)) or_return
			}
		}
		cfg.workspaces[index] = Workspace{index = index, name = name, folder = folder, wallpaper = wallpaper}
	}

	parse_linux(l, root, &cfg.linux) or_return
	parse_bar(l, root, &cfg.bar) or_return
	parse_wm(l, root, &cfg.wm) or_return
	parse_extras(l, root, cfg) or_return
	return true
}

destroy :: proc(cfg: ^Config) {
	if cfg == nil { return }
	delete(cfg.paths.common); delete(cfg.paths.wallpapers); delete(cfg.paths.wallpaper_cache)
	for _, ws in cfg.workspaces { delete(ws.name); delete(ws.folder); delete(ws.wallpaper) }
	delete(cfg.workspaces)
	delete(cfg.linux.wallpaper_mode)
	delete(cfg.linux.indicator.font); delete(cfg.linux.indicator.position)
	delete(cfg.linux.shortcuts.mode); delete(cfg.linux.shortcuts.font); delete(cfg.linux.shortcuts.icon_theme); delete(cfg.linux.shortcuts.monitor)
	delete(cfg.linux.desktop_icons.folder); delete(cfg.linux.desktop_icons.sort)
	b := &cfg.bar
	delete(b.position); delete(b.monitor); delete(b.override_redirect); delete(b.font); delete(b.icon_font_file); delete(b.icon_font)
	delete(b.theme.background); delete(b.theme.foreground); delete(b.theme.muted); delete(b.theme.accent)
	delete(b.theme.accent_foreground); delete(b.theme.surface); delete(b.theme.warning)
	for s in b.start { delete(s) }; delete(b.start)
	for s in b.center { delete(s) }; delete(b.center)
	for s in b.end { delete(s) }; delete(b.end)
	for k, v in b.commands { delete(k); delete(v) }
	delete(b.commands)
	delete(b.launcher_icon); delete(b.date_format); delete(b.clock_format); delete(b.locale); delete(b.media_idle_text)
	delete(b.style)
	delete(cfg.appearance.theme); delete(cfg.appearance.variant); delete(cfg.appearance.matugen_scheme); delete(cfg.notifications.position)
	for &t in cfg.appearance.custom_themes {
		delete(t.name)
		destroy_theme_colors(&t.colors)
	}
	delete(cfg.appearance.custom_themes)
	delete(cfg.keyboard.layout); delete(cfg.keyboard.variant); delete(cfg.keyboard.model); delete(cfg.keyboard.options)
	w := &cfg.wm
	delete(w.mod_key); delete(w.terminal); delete(w.launcher); delete(w.border_color); delete(w.focus_color); delete(w.screenshot)
	delete(w.file_manager)
	for rule in w.rules { delete(rule.class); delete(rule.instance); delete(rule.title); delete(rule.layer) }
	delete(w.rules)
	for k, v in w.bindings { delete(k); delete(v) }
	delete(w.bindings)
	delete(w.mode); delete(w.placement)
	t := &w.title_bar
	delete(t.layout); delete(t.align); delete(t.font); delete(t.button_style)
	delete(t.active_color); delete(t.inactive_color); delete(t.active_text); delete(t.inactive_text)
	for k, v in w.keys { delete(k); delete(v) }
	delete(w.keys)
	for k, v in w.mouse { delete(k); delete(v) }
	delete(w.mouse)
	destroy_menu_items(w.menu)
	free(cfg)
}
