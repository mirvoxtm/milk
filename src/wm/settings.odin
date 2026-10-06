// Settings: the part of config.WM_Options (plus the desktop names) the window
// manager keeps, cloned so that the caller may free its config.Config.
package wm

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import xlib "vendor:x11/xlib"
import config "../config"
import menu "../menu"
import tx "../tx"

// A dwm rule (config.WM_Rule): class/instance match exactly, title is a substring.
// The optional fields place and dress the window when it appears (openbox's <applications>).
Rule :: struct {
	class:       string,
	instance:    string,
	title:       string,
	tags:        u32,  // 0 = the current tags
	floating:    bool,
	monitor:     int,  // -1 = the current monitor
	pip:         bool, // treat as a picture-in-picture window
	x, y:        Maybe(i32),
	center:      bool,
	width:       Maybe(i32),
	height:      Maybe(i32),
	maximized:   bool,
	minimized:   bool,
	fullscreen:  bool,
	sticky:      bool,
	decorations: Maybe(bool),
	layer:       Maybe(Layer),
	focus:       Maybe(bool),
}

// Where new floating windows appear (wm.placement).
Placement :: enum u8 { Smart, Center, Mouse, Cascade }

// A wm.keys entry: the key runs a built-in action (actions.odin run_action).
Key_Action :: struct {
	mod:    xlib.InputMask,
	keysym: xlib.KeySym,
	action: string,
}

// A wm.mouse entry ("context:mods+button" → action).
Mouse_Binding :: struct {
	ctx:    string, // title | icon | root | client
	mod:    xlib.InputMask,
	button: u32, // 1..5; 0 = double click
	action: string,
}

// Colours the floating mode draws with (title bars, the window switcher).
Decor_Colors :: struct {
	active_bg, inactive_bg, active_fg, inactive_fg: tx.Color,
	bg, fg, muted, surface, accent, accent_fg, warning: tx.Color,
}

// An extra key binding from wm.bindings: spawn `command`.
Binding :: struct {
	mod:     xlib.InputMask,
	keysym:  xlib.KeySym,
	command: string,
}

Settings :: struct {
	modkey:              xlib.InputMask,
	terminal:            string,
	launcher:            string,
	border_width:        i32,
	border_color:        string,
	focus_color:         string,
	gaps:                i32,
	mfact:               f32,
	nmaster:             i32,
	resize_hints:        bool,
	focus_follows_mouse: bool,
	tag_count:           int,
	animation:           f64, // seconds, 0 = off
	screenshot:          string,
	keys_helper:         string, // contrib/milk-keys (volume/brightness keys)
	file_manager:        string, // Mod+e
	corner_radius:       i32,
	rules:               []Rule,
	bindings:            []Binding,
	desktop_names:       []string, // tag_count entries
	area_icons:          []rune,   // tag_count entries: workspaces.N.icon, 0 = none
	overview_anim:       f64,      // seconds of the overview's zoom, 0 = none
	// Floating mode.
	floating:            bool,
	title_height:        i32,
	title_layout:        string, // letters, see config.Title_Bar_Options
	title_align:         int,    // 0 left, 1 centre, 2 right
	title_font:          string, // fontconfig pattern
	title_font_px:       i32,
	title_circles:       bool,   // coloured dots instead of icons
	colors:              Decor_Colors,
	placement:           Placement,
	snap_distance:       i32,
	snap_layouts:        bool,
	resize_margin:       i32,
	focus_new:           bool,
	raise_on_focus:      bool,
	key_actions:         []Key_Action,
	default_keys:        []Key_Action, // config.DEFAULT_KEYS of the mode, with wm.defaultKeys
	mouse:               []Mouse_Binding,
	root_menu:           []config.Menu_Item, // wm.menu (deep copy); empty with has_menu = false: milk's menu
	has_menu:            bool,
	language:            config.Language,
	menu_style:          menu.Style, // strings owned
	desktop_icons:       bool,       // linux.desktopIcons.enabled: the root menu offers the icon actions
	icon_font_file:      string,     // the bar's Tabler font (window switcher icons)
}

// Clone what the window manager needs from the configuration.
settings_from_config :: proc(cfg: ^config.Config) -> Settings {
	w := &cfg.wm
	s: Settings
	s.modkey = w.mod_key == "alt" ? {.Mod1Mask} : {.Mod4Mask}
	s.terminal = strings.clone(w.terminal)
	s.launcher = strings.clone(w.launcher)
	s.border_width = i32(clamp(w.border_width, 0, 100))
	s.border_color = strings.clone(w.border_color)
	s.focus_color = strings.clone(w.focus_color)
	s.gaps = i32(clamp(w.gaps, 0, 1000))
	s.mfact = f32(clamp(w.master_factor, 0.05, 0.95))
	s.nmaster = i32(max(w.master_count, 0))
	s.resize_hints = w.resize_hints
	s.focus_follows_mouse = w.focus_follows_mouse
	s.tag_count = clamp(w.tag_count, 1, 32)
	// wm.animation (ms) scaled by appearance.animationScale (0 = off).
	s.animation = config.anim_duration(cfg, f64(clamp(w.animation, 0, 2000)) / 1000)
	s.screenshot = strings.trim_space(w.screenshot) != "" ? strings.clone(w.screenshot) : contrib_command("milk-screenshot")
	s.keys_helper = contrib_command("milk-keys")
	s.corner_radius = i32(clamp(w.corner_radius, 0, 64))
	s.file_manager = strings.trim_space(w.file_manager) != "" ? strings.clone(w.file_manager) : spoil_command()

	rules := make([]Rule, len(w.rules))
	for r, i in w.rules {
		rules[i] = Rule{
			class      = strings.clone(r.class),
			instance   = strings.clone(r.instance),
			title      = strings.clone(r.title),
			tags       = u32(r.tags & 0xFFFFFFFF),
			floating   = r.floating,
			monitor    = r.monitor,
			pip        = r.pip,
			center     = r.center,
			maximized  = r.maximized,
			minimized  = r.minimized,
			fullscreen = r.fullscreen,
			sticky     = r.sticky,
			decorations = r.decorations,
			focus      = r.focus,
		}
		if v, ok := r.x.?; ok { rules[i].x = i32(v) }
		if v, ok := r.y.?; ok { rules[i].y = i32(v) }
		if v, ok := r.width.?; ok { rules[i].width = i32(v) }
		if v, ok := r.height.?; ok { rules[i].height = i32(v) }
		switch r.layer {
		case "above":  rules[i].layer = .Above
		case "below":  rules[i].layer = .Below
		case "normal": rules[i].layer = .Normal
		}
	}
	s.rules = rules

	bindings := make([dynamic]Binding)
	for spec, command in w.bindings {
		mod, sym, ok := parse_key_spec(spec, s.modkey)
		if !ok {
			log.warnf("wm: ignoring the binding %q: expected modifiers (super, alt, ctrl, shift, mod) and a key name, e.g. \"super+shift+f\"", spec)
			continue
		}
		append(&bindings, Binding{mod = mod, keysym = sym, command = strings.clone(command)})
	}
	s.bindings = bindings[:]

	names := make([]string, s.tag_count)
	for i in 0 ..< s.tag_count {
		ws, found := config.workspace(cfg, i + 1)
		if found && strings.trim_space(ws.name) != "" {
			names[i] = strings.clone(ws.name)
		} else {
			names[i] = fmt.aprintf("%d", i + 1)
		}
	}
	s.desktop_names = names
	s.area_icons = make([]rune, s.tag_count)
	for i in 0 ..< s.tag_count {
		if r, has := config.workspace_icon(cfg, i + 1); has { s.area_icons[i] = r }
	}
	s.overview_anim = config.anim_duration(cfg, 0.36)

	floating_from_config(cfg, &s)
	return s
}

// The floating-mode part of the settings.
@(private)
floating_from_config :: proc(cfg: ^config.Config, s: ^Settings) {
	w := &cfg.wm
	tb := &w.title_bar
	s.floating = w.mode == "floating"
	s.title_height = i32(clamp(tb.height, 16, 80))
	s.title_layout = strings.clone(tb.layout)
	switch tb.align {
	case "center": s.title_align = 1
	case "right":  s.title_align = 2
	case:          s.title_align = 0
	}
	s.title_font = strings.clone(tb.font != "" ? tb.font : cfg.bar.font)
	s.title_font_px = i32(tb.font_size > 0 ? tb.font_size : max(cfg.bar.font_size - 1, 9))
	s.title_circles = tb.button_style == "circles"

	t := &cfg.bar.theme
	col := &s.colors
	col.bg = tx.color_from_hex(t.background)
	col.fg = tx.color_from_hex(t.foreground)
	col.muted = tx.color_from_hex(t.muted)
	col.surface = tx.color_from_hex(t.surface)
	col.accent = tx.color_from_hex(t.accent)
	col.accent_fg = tx.color_from_hex(t.accent_foreground)
	col.warning = tx.color_from_hex(t.warning)
	pick :: proc(hex: string, fallback: tx.Color) -> tx.Color { return hex != "" ? tx.color_from_hex(hex, fallback) : fallback }
	col.active_bg = pick(tb.active_color, col.bg)
	col.inactive_bg = pick(tb.inactive_color, tx.color_mix(col.bg, col.surface, 0.7))
	col.active_fg = pick(tb.active_text, col.fg)
	col.inactive_fg = pick(tb.inactive_text, col.muted)

	switch w.placement {
	case "center":  s.placement = .Center
	case "mouse":   s.placement = .Mouse
	case "cascade": s.placement = .Cascade
	case:           s.placement = .Smart
	}
	s.snap_distance = i32(clamp(w.snap_distance, 0, 200))
	s.snap_layouts = w.snap_layouts
	s.resize_margin = i32(clamp(w.resize_margin, 0, 40))
	s.focus_new = w.focus_new
	s.raise_on_focus = w.raise_on_focus

	keys := make([dynamic]Key_Action)
	for spec, action in w.keys {
		mod, sym, ok := parse_key_spec(spec, s.modkey)
		if !ok {
			log.warnf("wm: ignoring wm.keys %q: expected modifiers and a key name, e.g. \"super+Up\"", spec)
			continue
		}
		append(&keys, Key_Action{mod = mod, keysym = sym, action = strings.clone(action)})
	}
	s.key_actions = keys[:]

	// The default keys. The ones the user changed come first: the first key
	// that matches runs, so Super+3 given to a shortcut beats the area keys.
	defaults := make([dynamic]Key_Action)
	for changed in ([]bool{true, false}) {
		for d in config.DEFAULT_KEYS {
			if !config.default_key_active(d, s.floating) || (d.id in w.default_keys) != changed { continue }
			for spec in strings.fields(config.default_key_specs(w, d), context.temp_allocator) {
				areas := strings.index_byte(spec, '#') >= 0
				if areas != (strings.index_byte(d.action, '#') >= 0) {
					log.warnf("wm: ignoring wm.defaultKeys.%s %q: the area shortcuts take \"#\" for the number (\"super+#\"), the others a key", d.id, spec)
					continue
				}
				for n in 1 ..= (areas ? min(s.tag_count, 9) : 1) {
					one, action := spec, d.action
					if areas { one, action = config.expand_area(spec, n), config.expand_area(d.action, n) }
					mod, sym, ok := parse_key_spec(one, s.modkey)
					if !ok {
						log.warnf("wm: ignoring wm.defaultKeys.%s %q: expected modifiers and a key name, e.g. \"super+Up\"", d.id, spec)
						break
					}
					append(&defaults, Key_Action{mod = mod, keysym = sym, action = strings.clone(action)})
				}
			}
		}
	}
	s.default_keys = defaults[:]

	mouse := make([dynamic]Mouse_Binding)
	for spec, action in w.mouse {
		colon := strings.index_byte(spec, ':')
		if colon < 0 { continue }
		parts := strings.split(spec[colon + 1:], "+", context.temp_allocator)
		b := Mouse_Binding{ctx = strings.clone(spec[:colon]), action = strings.clone(action)}
		for part in parts[:len(parts) - 1] {
			switch strings.to_lower(part, context.temp_allocator) {
			case "super", "win": b.mod += {.Mod4Mask}
			case "alt":          b.mod += {.Mod1Mask}
			case "ctrl", "control": b.mod += {.ControlMask}
			case "shift":        b.mod += {.ShiftMask}
			case "mod":          b.mod += s.modkey
			}
		}
		switch parts[len(parts) - 1] {
		case "left":        b.button = 1
		case "middle":      b.button = 2
		case "right":       b.button = 3
		case "scroll-up":   b.button = 4
		case "scroll-down": b.button = 5
		case "double":      b.button = 0
		}
		append(&mouse, b)
	}
	s.mouse = mouse[:]

	s.has_menu = w.has_menu
	s.root_menu = clone_menu_items(w.menu)
	s.language = cfg.bar.language
	s.menu_style = menu.style_from_config(cfg)
	s.menu_style.font = strings.clone(s.menu_style.font)
	s.menu_style.icon_font_file = strings.clone(s.menu_style.icon_font_file)
	s.icon_font_file = strings.clone(cfg.bar.icon_font_file)
	s.desktop_icons = cfg.linux.desktop_icons.enabled
}

@(private)
clone_menu_items :: proc(items: []config.Menu_Item) -> []config.Menu_Item {
	if len(items) == 0 { return nil }
	out := make([]config.Menu_Item, len(items))
	for it, i in items {
		out[i] = config.Menu_Item{
			label = strings.clone(it.label), action = strings.clone(it.action), command = strings.clone(it.command),
			separator = it.separator, items = clone_menu_items(it.items),
		}
	}
	return out
}

// Path of a helper script shipped in contrib/ next to bin/ (quoted for sh -c).
@(private)
contrib_command :: proc(name: string) -> string {
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err == nil {
		path, _ := filepath.join({dir, "..", "contrib", name}, context.temp_allocator)
		clean, _ := filepath.clean(path, context.temp_allocator)
		if os.is_file(clean) { return fmt.aprintf("'%s'", clean) }
	}
	return strings.clone(name) // on $PATH
}

// Spoil, milk's file manager, lives next to the milk folder (../spoil/spoil);
// without it Mod+e opens the home folder with the default file manager.
@(private)
spoil_command :: proc() -> string {
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err == nil {
		path, _ := filepath.join({dir, "..", "..", "spoil", "spoil"}, context.temp_allocator)
		clean, _ := filepath.clean(path, context.temp_allocator)
		if os.is_file(clean) { return fmt.aprintf("'%s'", clean) }
	}
	// Installed elsewhere: the installer links it into ~/.local/bin.
	return strings.clone(`command -v spoil >/dev/null 2>&1 && exec spoil || exec xdg-open "$HOME"`)
}

settings_destroy :: proc(s: ^Settings) {
	delete(s.file_manager)
	delete(s.screenshot)
	delete(s.keys_helper)
	delete(s.terminal)
	delete(s.launcher)
	delete(s.border_color)
	delete(s.focus_color)
	for r in s.rules {
		delete(r.class)
		delete(r.instance)
		delete(r.title)
	}
	delete(s.rules)
	for b in s.bindings { delete(b.command) }
	delete(s.bindings)
	for n in s.desktop_names { delete(n) }
	delete(s.desktop_names)
	delete(s.area_icons)
	delete(s.title_layout)
	delete(s.title_font)
	for k in s.key_actions { delete(k.action) }
	delete(s.key_actions)
	for k in s.default_keys { delete(k.action) }
	delete(s.default_keys)
	for b in s.mouse { delete(b.ctx); delete(b.action) }
	delete(s.mouse)
	config.destroy_menu_items(s.root_menu)
	delete(s.menu_style.font)
	delete(s.menu_style.icon_font_file)
	delete(s.icon_font_file)
	s^ = {}
}

// Parse "super+shift+f": modifier names (super, alt, ctrl, shift, and "mod"
// for the configured modifier) followed by an X key name; a key without
// modifiers ("Print", "F5") is bound alone, and "super" alone is Super tapped.
parse_key_spec :: proc(spec: string, modkey: xlib.InputMask) -> (mod: xlib.InputMask, sym: xlib.KeySym, ok: bool) {
	parts := strings.split(spec, "+", context.temp_allocator)
	if len(parts) == 0 { return }
	// "super" on its own: tapped (pressed and released with nothing else).
	if len(parts) == 1 {
		switch strings.to_lower(strings.trim_space(parts[0]), context.temp_allocator) {
		case "super", "win", "mod4": return {}, .XK_Super_L, true
		}
	}
	for part, i in parts {
		name := strings.trim_space(part)
		if i == len(parts) - 1 {
			sym = keysym_from_name(name)
			break
		}
		switch strings.to_lower(name, context.temp_allocator) {
		case "super", "win", "mod4":  mod += {.Mod4Mask}
		case "alt", "mod1":           mod += {.Mod1Mask}
		case "ctrl", "control":       mod += {.ControlMask}
		case "shift":                 mod += {.ShiftMask}
		case "mod":                   mod += modkey
		case:                         return {}, {}, false
		}
	}
	return mod, sym, sym != xlib.KeySym(0)
}

// XStringToKeysym is case-sensitive: accept "return"/"Return", "f1"/"F1",
// "Space"/"space". Letters use their lower-case keysym, which is the one at
// index 0 of the keyboard mapping (what grabkeys and keypress compare).
keysym_from_name :: proc(name: string) -> xlib.KeySym {
	if name == "" { return xlib.KeySym(0) }
	candidates := [3]string{name, strings.to_lower(name, context.temp_allocator), ""}
	if len(name) == 1 && name[0] >= 'A' && name[0] <= 'Z' {
		candidates[0] = candidates[1]
	}
	lower := candidates[1]
	candidates[2] = strings.concatenate({strings.to_upper(lower[:1], context.temp_allocator), lower[1:]}, context.temp_allocator)
	for candidate in candidates {
		if candidate == "" { continue }
		sym := xlib.StringToKeysym(strings.clone_to_cstring(candidate, context.temp_allocator))
		if sym != xlib.KeySym(0) { return sym }
	}
	return xlib.KeySym(0)
}
