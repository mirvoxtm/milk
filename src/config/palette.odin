// The "wallpaper" theme (appearance.theme = "wallpaper"): colours made by
// matugen from the wallpaper of the area on screen. milk's desktop daemon runs
// matugen when that wallpaper changes and keeps the result, a light and a dark
// palette, in $XDG_CACHE_HOME/milk/wallpaper-theme.json; load() puts the
// palette of appearance.variant into bar.theme and wm.borderColor/focusColor,
// so everything that reads milk.json through this package (milk, Spoil,
// lactase, the settings app) draws with it. Without that file (matugen never
// ran, or is not installed) the colours written in milk.json stay.
package config

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:time"

WALLPAPER_THEME :: "wallpaper"

// matugen's scheme types (its -t scheme-<name>), appearance.matugenScheme.
@(rodata) MATUGEN_SCHEMES := []string{"tonal-spot", "vibrant", "expressive", "content", "fidelity", "rainbow", "fruit-salad", "neutral", "monochrome"}

Wallpaper_Palette :: struct {
	source: string, // the image the colours come from
	scheme: string, // a MATUGEN_SCHEMES name
	light:  Theme_Colors,
	dark:   Theme_Colors,
}

// $XDG_CACHE_HOME/milk/wallpaper-theme.json.
wallpaper_palette_path :: proc(allocator := context.temp_allocator) -> string {
	cache := os.get_env("XDG_CACHE_HOME", context.temp_allocator)
	if cache == "" {
		home := os.get_env("HOME", context.temp_allocator)
		cache = strings.concatenate({home, "/.cache"}, context.temp_allocator)
	}
	return strings.concatenate({cache, "/milk/wallpaper-theme.json"}, allocator)
}

destroy_wallpaper_palette :: proc(p: ^Wallpaper_Palette) {
	delete(p.source)
	delete(p.scheme)
	destroy_theme_colors(&p.light)
	destroy_theme_colors(&p.dark)
	p^ = {}
}

// The keys of a palette in wallpaper-theme.json (custom themes use the same).
@(private)
palette_get :: proc(obj: json.Object, key: string) -> (string, bool) {
	s, ok := obj[key].(json.String)
	if !ok || !is_hex_color(string(s)) { return "", false }
	return strings.clone(string(s)), true
}

@(private)
colors_from_object :: proc(obj: json.Object) -> (c: Theme_Colors, ok: bool) {
	keys := [9]string{"background", "foreground", "muted", "accent", "accentForeground", "surface", "warning", "borderColor", "focusColor"}
	fields := [9]^string{&c.bar.background, &c.bar.foreground, &c.bar.muted, &c.bar.accent, &c.bar.accent_foreground,
	                     &c.bar.surface, &c.bar.warning, &c.border_color, &c.focus_color}
	for key, i in keys {
		v, good := palette_get(obj, key)
		if !good {
			destroy_theme_colors(&c)
			return {}, false
		}
		fields[i]^ = v
	}
	return c, true
}

@(private)
colors_to_object :: proc(c: Theme_Colors, allocator := context.temp_allocator) -> json.Object {
	obj := make(json.Object, allocator)
	obj["background"] = json.String(c.bar.background)
	obj["foreground"] = json.String(c.bar.foreground)
	obj["muted"] = json.String(c.bar.muted)
	obj["accent"] = json.String(c.bar.accent)
	obj["accentForeground"] = json.String(c.bar.accent_foreground)
	obj["surface"] = json.String(c.bar.surface)
	obj["warning"] = json.String(c.bar.warning)
	obj["borderColor"] = json.String(c.border_color)
	obj["focusColor"] = json.String(c.focus_color)
	return obj
}

// The palette saved in `path` (owned strings; destroy_wallpaper_palette).
read_wallpaper_palette :: proc(path: string) -> (p: Wallpaper_Palette, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return }
	return parse_wallpaper_palette(data)
}

parse_wallpaper_palette :: proc(data: []byte) -> (p: Wallpaper_Palette, ok: bool) {
	value, perr := json.parse(data, .JSON, true, context.temp_allocator)
	if perr != .None { return }
	root := value.(json.Object) or_return
	light := root["light"].(json.Object) or_return
	dark := root["dark"].(json.Object) or_return
	p.light = colors_from_object(light) or_return
	p.dark, ok = colors_from_object(dark)
	if !ok {
		destroy_theme_colors(&p.light)
		return {}, false
	}
	source, _ := root["source"].(json.String)
	scheme, _ := root["scheme"].(json.String)
	p.source = strings.clone(string(source))
	p.scheme = strings.clone(string(scheme))
	return p, true
}

// Save a palette (written aside, then moved into place: readers never see half a file).
write_wallpaper_palette :: proc(path: string, p: Wallpaper_Palette) -> bool {
	root := make(json.Object, context.temp_allocator)
	root["source"] = json.String(p.source)
	root["scheme"] = json.String(p.scheme)
	root["light"] = colors_to_object(p.light)
	root["dark"] = colors_to_object(p.dark)
	out, merr := json.marshal(root, {spec = .JSON, pretty = true, use_spaces = true, spaces = 2, sort_maps_by_key = true}, context.temp_allocator)
	if merr != nil { return false }
	dir := path[:max(strings.last_index_byte(path, '/'), 0)]
	if dir != "" && !os.exists(dir) { _ = os.make_directory_all(dir) }
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, out) != nil {
		os.remove(tmp)
		return false
	}
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return false
	}
	return true
}

// A palette from matugen's `--json hex` output: matugen 4 writes
// colors.<name>.{light,dark}.color, matugen 3 colors.<name>.{light,dark} and
// matugen 2 colors.{light,dark}.<name>.
// The Material roles map onto milk's colours: the bar sits on the surface,
// panels on a raised container, the accent is the primary colour.
palette_from_matugen :: proc(data: []byte, source, scheme: string) -> (p: Wallpaper_Palette, ok: bool) {
	value, perr := json.parse(data, .JSON, true, context.temp_allocator)
	if perr != .None { return }
	root := value.(json.Object) or_return
	colors := root["colors"].(json.Object) or_return

	role :: proc(colors: json.Object, name: string, dark: bool) -> (string, bool) {
		variant := dark ? "dark" : "light"
		if entry, is_obj := colors[name].(json.Object); is_obj {
			#partial switch v in entry[variant] {
			case json.Object: // matugen 4: {"dark": {"color": "#..."}, "light": {...}}
				if s, is_str := v["color"].(json.String); is_str && is_hex_color(string(s)) { return string(s), true }
			case json.String: // matugen 3: {"dark": "#...", "light": "#..."}
				if is_hex_color(string(v)) { return string(v), true }
			}
			return "", false
		}
		if group, is_obj := colors[variant].(json.Object); is_obj {
			if s, is_str := group[name].(json.String); is_str && is_hex_color(string(s)) { return string(s), true }
		}
		return "", false
	}
	build :: proc(colors: json.Object, dark: bool) -> (c: Theme_Colors, ok: bool) {
		names := [9]string{"surface", "on_surface", "outline", "primary", "on_primary", "surface_container_high", "error",
		                   "outline_variant", "primary"}
		fields := [9]^string{&c.bar.background, &c.bar.foreground, &c.bar.muted, &c.bar.accent, &c.bar.accent_foreground,
		                     &c.bar.surface, &c.bar.warning, &c.border_color, &c.focus_color}
		for name, i in names {
			s, found := role(colors, name, dark)
			if !found {
				destroy_theme_colors(&c)
				return {}, false
			}
			fields[i]^ = strings.to_upper(s)
		}
		return c, true
	}
	p.light = build(colors, false) or_return
	p.dark, ok = build(colors, true)
	if !ok {
		destroy_theme_colors(&p.light)
		return {}, false
	}
	p.source = strings.clone(source)
	p.scheme = strings.clone(scheme)
	return p, true
}

// When milk.json or the wallpaper palette last changed (unix nanoseconds):
// programs that follow the theme (Spoil) reload when this moves.
theme_stamp :: proc(config_path: string) -> i64 {
	stamp: i64
	for path in ([]string{config_path, wallpaper_palette_path()}) {
		fi, err := os.stat(path, context.temp_allocator)
		if err != nil { continue }
		stamp = max(stamp, time.time_to_unix_nano(fi.modification_time))
	}
	return stamp
}

// The wallpaper theme's colours replace bar.theme and the border colours.
@(private)
apply_wallpaper_palette :: proc(cfg: ^Config) {
	p, ok := read_wallpaper_palette(wallpaper_palette_path())
	if !ok { return }
	defer destroy_wallpaper_palette(&p)
	c := cfg.appearance.variant == "dark" ? &p.dark : &p.light
	b := &cfg.bar.theme
	swap :: proc(field: ^string, value: ^string) {
		delete(field^)
		field^ = value^
		value^ = ""
	}
	swap(&b.background, &c.bar.background)
	swap(&b.foreground, &c.bar.foreground)
	swap(&b.muted, &c.bar.muted)
	swap(&b.accent, &c.bar.accent)
	swap(&b.accent_foreground, &c.bar.accent_foreground)
	swap(&b.surface, &c.bar.surface)
	swap(&b.warning, &c.bar.warning)
	swap(&cfg.wm.border_color, &c.border_color)
	swap(&cfg.wm.focus_color, &c.focus_color)
}
