// Saving the choices: milk.json (edited like the bar's quick settings: parsed,
// changed, written back pretty-printed with sorted keys, atomically), the
// wallpapers copied into the runtime folder, the Alacritty theme import, and
// the marker file.
package oobe

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import config "../config"

@(private)
write_marker :: proc(w: ^Wizard) {
	if !os.is_directory(w.runtime_root) { _ = os.make_directory_all(w.runtime_root) }
	path := join_path({w.runtime_root, MARKER_NAME})
	stamp := fmt.tprintf("milk setup %s\n", w.state == .Finished ? "completed" : "skipped")
	if err := os.write_entire_file(path, stamp); err != nil {
		log.errorf("Setup: cannot create %s: %v", path, err)
	}
}

// A child object (a fresh one when missing); store it back with root[key] = ...
// after changing it, since inserting may move the map.
@(private)
json_child :: proc(parent: json.Object, key: string) -> json.Object {
	if child, ok := parent[key].(json.Object); ok { return child }
	return make(json.Object, context.temp_allocator)
}

@(private)
apply_choices :: proc(w: ^Wizard) -> bool {
	names, ok := copy_wallpapers(w)
	if !ok { return false }
	if !write_config(w, names) { return false }
	update_alacritty(w)
	return true
}

// Copy the chosen pictures into <runtime>/<paths.wallpapers>; returns the file
// name for each area ("" = no wallpaper). Everything is staged as *.new first
// so that a picture already in the folder can be reused under another name.
@(private)
copy_wallpapers :: proc(w: ^Wizard) -> (names: []string, ok: bool) {
	// An unchanged picture is not written again (the desktop would re-stage it).
	same_file_content :: proc(a, b: string) -> bool {
		if a == b { return true }
		fa, ea := os.stat(a, context.temp_allocator)
		fb, eb := os.stat(b, context.temp_allocator)
		if ea != nil || eb != nil || fa.size != fb.size { return false }
		return content_key(a, fa.size) == content_key(b, fb.size)
	}
	names = make([]string, len(w.areas), context.temp_allocator)
	dir := join_path({w.runtime_root, w.cfg.paths.wallpapers})
	Copy :: struct { src, dst: string }
	copies := make([dynamic]Copy, context.temp_allocator)
	for n, i in w.areas {
		choice := area_choice(w, i)
		if choice < 0 || choice >= len(w.thumbs.items) { continue }
		src := w.thumbs.items[choice].path
		ext := strings.to_lower(filepath.ext(src), context.temp_allocator)
		if ext == ".jpeg" { ext = ".jpg" }
		name := w.wp_per_area ? fmt.tprintf("Area%d%s", n, ext) : fmt.tprintf("All%s", ext)
		names[i] = name
		already := false
		for cp in copies { if cp.dst == name { already = true } }
		if !already && !same_file_content(src, join_path({dir, name})) { append(&copies, Copy{src, name}) }
	}
	if len(copies) == 0 { return names, true }
	if err := os.make_directory_all(dir); err != nil && !os.is_directory(dir) {
		log.errorf("Setup: cannot create %s: %v", dir, err)
		return nil, false
	}
	for cp in copies {
		staged := join_path({dir, fmt.tprintf("%s.new", cp.dst)})
		if err := os.copy_file(staged, cp.src); err != nil {
			log.errorf("Setup: cannot copy %s: %v", cp.src, err)
			return nil, false
		}
	}
	for cp in copies {
		staged := join_path({dir, fmt.tprintf("%s.new", cp.dst)})
		final := join_path({dir, cp.dst})
		if err := os.rename(staged, final); err != nil {
			log.errorf("Setup: cannot move %s into place: %v", final, err)
			return nil, false
		}
	}
	return names, true
}

@(private)
write_config :: proc(w: ^Wizard, wallpapers: []string) -> bool {
	path := w.config_path
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		log.errorf("Setup: cannot read %s: %v", path, rerr)
		return false
	}
	value, perr := json.parse(data, .JSON5, true, context.temp_allocator)
	root, is_obj := value.(json.Object)
	if perr != .None || !is_obj {
		log.errorf("Setup: cannot parse %s (%v); not changing it", path, perr)
		return false
	}
	theme_name, colors, dark := chosen_theme(w)

	appearance := json_child(root, "appearance")
	appearance["theme"] = json.String(theme_name)
	appearance["variant"] = json.String(dark ? "dark" : "light")
	root["appearance"] = appearance

	bar := json_child(root, "bar")
	theme := make(json.Object, context.temp_allocator)
	theme["background"] = json.String(colors.bar.background)
	theme["foreground"] = json.String(colors.bar.foreground)
	theme["muted"] = json.String(colors.bar.muted)
	theme["accent"] = json.String(colors.bar.accent)
	theme["accentForeground"] = json.String(colors.bar.accent_foreground)
	theme["surface"] = json.String(colors.bar.surface)
	theme["warning"] = json.String(colors.bar.warning)
	bar["theme"] = theme
	bar["position"] = json.String(w.bar_top ? "top" : "bottom")
	bar["style"] = json.String(w.bar_floating ? "floating" : "full")
	if w.locale_index != locale_choice(w.cfg.bar.locale) {
		bar["locale"] = json.String(config.LANGUAGE_CODES[w.locale_index])
	}
	if w.set.lay.dirty {
		// A widget layout was picked on the bar page.
		bar["start"] = lay_json(w, 0)
		bar["center"] = lay_json(w, 1)
		bar["end"] = lay_json(w, 2)
	}
	root["bar"] = bar

	wm := json_child(root, "wm")
	wm["borderColor"] = json.String(colors.border_color)
	wm["focusColor"] = json.String(colors.focus_color)
	root["wm"] = wm

	ensure_workspaces(&root, w.areas[:])
	workspaces := json_child(root, "workspaces")
	for n, i in w.areas {
		key := fmt.tprintf("%d", n)
		ws, found := workspaces[key].(json.Object)
		if !found { continue }
		ws["wallpaper"] = wallpapers[i] == "" ? json.Value(json.Null(nil)) : json.Value(json.String(wallpapers[i]))
		workspaces[key] = ws
	}
	root["workspaces"] = workspaces

	// The keyboard is only written when it was configured already or the user
	// picked something else than the system's layout (which milk then leaves
	// alone, second layouts such as "us,ru" included).
	kb_changed := w.kb.layout != first_item(w.kb.orig_layout) || w.kb.variant != first_item(w.kb.orig_variant)
	if w.kb.layout != "" && (kb_changed || w.cfg.keyboard.layout != "") {
		kb := json_child(root, "keyboard")
		kb["layout"] = json.String(w.kb.layout)
		if w.kb.variant != "" {
			kb["variant"] = json.String(w.kb.variant)
		} else {
			delete_key(&kb, "variant")
		}
		root["keyboard"] = kb
	}

	if !write_json(root, path) { return false }
	log.infof("Setup: %s updated (theme %s %s, bar %s %s)", path, theme_name, dark ? "dark" : "light",
	          w.bar_top ? "top" : "bottom", w.bar_floating ? "floating" : "full")
	return true
}

// Write milk.json back: pretty, sorted keys, replaced atomically.
@(private)
write_json :: proc(root: json.Object, path: string) -> bool {
	out, merr := json.marshal(root, {spec = .JSON, pretty = true, use_spaces = true, spaces = 2, sort_maps_by_key = true}, context.temp_allocator)
	if merr != nil {
		log.errorf("Setup: cannot encode the configuration: %v", merr)
		return false
	}
	tmp := fmt.tprintf("%s.tmp", path)
	text := strings.concatenate({config.tidy_json_numbers(string(out)), "\n"}, context.temp_allocator)
	if werr := os.write_entire_file(tmp, text); werr != nil {
		log.errorf("Setup: cannot write %s: %v", tmp, werr)
		return false
	}
	if err := os.rename(tmp, path); err != nil {
		log.errorf("Setup: cannot replace %s: %v", path, err)
		return false
	}
	return true
}

// Point the theme import of ~/.config/alacritty/milk.toml (or $MILK_ALACRITTY_CONFIG)
// at contrib/alacritty/<theme>-<variant>.toml, or for a custom theme at the
// colours generated for it (custom_alacritty_dir). Only an existing file with
// an `import = [...]` line is touched.
@(private)
update_alacritty :: proc(w: ^Wizard) {
	target := ""
	if v, found := os.lookup_env(ALACRITTY_ENV, context.temp_allocator); found && v != "" {
		target = v
	} else {
		target = join_path({home_dir(), ".config", "alacritty", "milk.toml"})
	}
	data, err := os.read_entire_file(target, context.temp_allocator)
	if err != nil { return }
	theme_name, colors, dark := chosen_theme(w)
	custom_path := "" // the generated file of a custom theme
	if theme_is_custom(w) {
		p, ok := write_custom_alacritty(theme_name, colors, dark)
		if !ok { return }
		custom_path = p
	}
	wanted := custom_path != "" ? filepath.base(custom_path) : fmt.tprintf("%s-%s.toml", theme_name, dark ? "dark" : "light")

	lines := strings.split(string(data), "\n", context.temp_allocator)
	changed := false
	for &line in lines {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, "import") || !strings.contains(trimmed, "[") { continue }
		open := strings.index_byte(line, '[')
		close := strings.last_index_byte(line, ']')
		if open < 0 || close <= open { continue }
		items := strings.split(line[open + 1:close], ",", context.temp_allocator)
		replaced := false
		for &item in items {
			s := strings.trim_space(item)
			unq := strings.trim(s, "\"'")
			base := filepath.base(unq)
			if !is_theme_file(base) { continue }
			if custom_path != "" {
				item = fmt.tprintf(" \"%s\"", custom_path)
			} else {
				dir := filepath.dir(unq)
				if is_custom_alacritty_file(base) {
					// Back to a preset: those live in contrib/alacritty.
					dir = contrib_theme_dir(w)
					if dir == "" { return }
				}
				item = fmt.tprintf(" \"%s/%s\"", dir, wanted)
			}
			replaced = true
		}
		if !replaced {
			path := custom_path
			if path == "" {
				contrib := contrib_theme_dir(w)
				if contrib == "" { return }
				path = fmt.tprintf("%s/%s", contrib, wanted)
			}
			append_item := fmt.tprintf(" \"%s\"", path)
			new_items := make([dynamic]string, context.temp_allocator)
			for it in items { if strings.trim_space(it) != "" { append(&new_items, it) } }
			append(&new_items, append_item)
			items = new_items[:]
		}
		joined := strings.join(items, ",", context.temp_allocator)
		line = strings.concatenate({line[:open + 1], strings.trim_left_space(joined), line[close:]}, context.temp_allocator)
		changed = true
		break
	}
	if !changed { return }
	out := strings.join(lines, "\n", context.temp_allocator)
	tmp := fmt.tprintf("%s.tmp", target)
	if werr := os.write_entire_file(tmp, out); werr != nil {
		log.warnf("Setup: cannot write %s: %v", tmp, werr)
		return
	}
	if rerr := os.rename(tmp, target); rerr != nil {
		log.warnf("Setup: cannot update %s: %v", target, rerr)
		return
	}
	log.infof("Setup: %s now imports %s", target, wanted)
}

@(private)
is_theme_file :: proc(name: string) -> bool {
	if is_custom_alacritty_file(name) { return true }
	for p in config.THEME_PRESETS {
		for v in ([]string{"light", "dark"}) {
			if name == fmt.tprintf("%s-%s.toml", p.name, v) { return true }
		}
	}
	return false
}

// contrib/alacritty next to the milk.json in use (the clone), when it exists.
@(private)
contrib_theme_dir :: proc(w: ^Wizard) -> string {
	dir := join_path({filepath.dir(w.config_path), "contrib", "alacritty"})
	abs, err := filepath.abs(dir, context.temp_allocator)
	if err == nil { dir = abs }
	return os.is_directory(dir) ? dir : ""
}

// milk.json requires name, folder and wallpaper for every workspace: create
// the missing areas (Area6..Area9 when milk.json listed only five) and fill in
// missing keys, so writing one key of a new area never produces an invalid file.
ensure_workspaces :: proc(root: ^json.Object, areas: []int) {
	workspaces := json_child(root^, "workspaces")
	for n in areas {
		key := fmt.tprintf("%d", n)
		ws, found := workspaces[key].(json.Object)
		if !found {
			ws = make(json.Object, context.temp_allocator)
		}
		if _, has := ws["name"]; !has { ws["name"] = json.String("") }
		if _, has := ws["folder"]; !has { ws["folder"] = json.String(fmt.tprintf("Area%d", n)) }
		if _, has := ws["wallpaper"]; !has { ws["wallpaper"] = json.Null(nil) }
		workspaces[strings.clone(key, context.temp_allocator)] = ws
	}
	root["workspaces"] = workspaces
}
