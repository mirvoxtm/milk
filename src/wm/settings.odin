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

// A dwm rule (config.WM_Rule): class/instance match exactly, title is a substring.
Rule :: struct {
	class:    string,
	instance: string,
	title:    string,
	tags:     u32,  // 0 = the current tags
	floating: bool,
	monitor:  int,  // -1 = the current monitor
	pip:      bool, // treat as a picture-in-picture window
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
			class    = strings.clone(r.class),
			instance = strings.clone(r.instance),
			title    = strings.clone(r.title),
			tags     = u32(r.tags & 0xFFFFFFFF),
			floating = r.floating,
			monitor  = r.monitor,
			pip      = r.pip,
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
	return s
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
	s^ = {}
}

// Parse "super+shift+f": modifier names (super, alt, ctrl, shift, and "mod"
// for the configured modifier) followed by an X key name.
parse_key_spec :: proc(spec: string, modkey: xlib.InputMask) -> (mod: xlib.InputMask, sym: xlib.KeySym, ok: bool) {
	parts := strings.split(spec, "+", context.temp_allocator)
	if len(parts) == 0 { return }
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
