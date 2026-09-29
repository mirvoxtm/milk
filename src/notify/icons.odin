// Pictures for notifications: the image-data hint, image paths and file://
// URIs, icon names looked up in the XDG icon theme (index.theme, Inherits,
// size matching as in the Icon Theme spec — the same rules as the desktop
// icon layer), and application icons/names from desktop entries.
package notify

import "core:fmt"
import "core:image"
import "core:image/png"
import _ "core:image/jpeg"
import _ "core:image/bmp"
import "core:log"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import config "../config"
import tx "../tx"

SMALL_ICON :: 20 // header icon of a card
BIG_ICON   :: 48 // picture next to the text

@(private)
LOOKUP_SIZE :: 48

@(private)
Dir_Kind :: enum { Threshold, Fixed, Scalable }

@(private)
Theme_Dir :: struct {
	path:                                  string,
	size, min_size, max_size, threshold, scale: int,
	kind:                                  Dir_Kind,
}

@(private)
Icon_Theme :: struct {
	name: string,
	dirs: [dynamic]Theme_Dir,
}

Icon_Loader :: struct {
	svg:         bool, // rsvg-convert is available
	themes:      [dynamic]Icon_Theme,
	fallback:    [dynamic]string, // pixmaps and base directories (unthemed icons)
	paths:       map[string]string, // icon name -> file ("" = not found)
	images:      map[string]tx.Image, // "file@size" -> decoded, fitted image
	initialized: bool,
}

@(private)
icons_init :: proc(l: ^Icon_Loader, cfg: ^config.Config) {
	l.themes = make([dynamic]Icon_Theme)
	l.fallback = make([dynamic]string)
	l.paths = make(map[string]string)
	l.images = make(map[string]tx.Image)
	l.initialized = true
	l.svg = find_in_path("rsvg-convert")

	bases := icon_base_dirs()
	theme := cfg.linux.shortcuts.icon_theme
	if theme == "" { theme = detect_icon_theme() }
	seen := make(map[string]bool, context.temp_allocator)
	queue := make([dynamic]string, context.temp_allocator)
	append(&queue, theme)
	for len(queue) > 0 {
		name := pop_front(&queue)
		if name in seen { continue }
		seen[name] = true
		t, inherits, ok := load_theme(name, bases)
		if !ok { continue }
		append(&l.themes, t)
		append(&queue, ..inherits)
	}
	for name in ([]string{"hicolor", "Adwaita", "breeze", "Papirus"}) {
		if name in seen { continue }
		seen[name] = true
		if t, _, ok := load_theme(name, bases); ok { append(&l.themes, t) }
	}
	for dir in data_dirs() {
		pixmaps := join_path({dir, "pixmaps"})
		if os.is_directory(pixmaps) { append(&l.fallback, strings.clone(pixmaps)) }
	}
}

@(private)
icons_destroy :: proc(l: ^Icon_Loader) {
	if !l.initialized { return }
	for &t in l.themes {
		delete(t.name)
		for dir in t.dirs { delete(dir.path) }
		delete(t.dirs)
	}
	delete(l.themes)
	for f in l.fallback { delete(f) }
	delete(l.fallback)
	for k, v in l.paths { delete(k); delete(v) }
	delete(l.paths)
	for k, &v in l.images { delete(k); tx.image_destroy(&v) }
	delete(l.images)
	l^ = {}
}

// Fill notif.image / notif.icon (and a missing app name) from the request.
@(private)
resolve_images :: proc(n: ^Notifier, notif: ^Notification, req: ^Notify_Request) {
	l := &n.icons
	entry_icon, entry_name := desktop_entry_info(req.desktop_entry, n.cfg.bar.language)
	if notif.app_name == "" && entry_name != "" {
		delete(notif.app_name)
		notif.app_name = strings.clone(entry_name)
	}

	// The large picture: image-data, image-path, then app_icon.
	if len(req.image.data) > 0 {
		notif.image = image_from_raw(req.image, BIG_ICON)
	}
	if notif.image.rgba == nil && req.image_path != "" {
		notif.image = icon_image(l, req.image_path, BIG_ICON)
	}
	if notif.image.rgba == nil && req.app_icon != "" {
		notif.image = icon_image(l, req.app_icon, BIG_ICON)
	}

	// The small application icon: desktop entry, app_icon, the app name.
	candidates := make([dynamic]string, context.temp_allocator)
	if entry_icon != "" { append(&candidates, entry_icon) }
	if req.app_icon != "" { append(&candidates, req.app_icon) }
	if req.app_name != "" {
		lower := strings.to_lower(req.app_name, context.temp_allocator)
		dashed, _ := strings.replace_all(lower, " ", "-", context.temp_allocator)
		append(&candidates, dashed)
		if other_icon, _ := desktop_entry_info(dashed, .English); other_icon != "" { append(&candidates, other_icon) }
	}
	for cand in candidates {
		notif.icon = icon_image(l, cand, SMALL_ICON)
		if notif.icon.rgba != nil { break }
	}
}

// A copy of the image for `spec` (icon name, absolute path or file:// URI)
// fitted into size x size; rgba == nil when nothing was found.
@(private)
icon_image :: proc(l: ^Icon_Loader, spec: string, size: i32) -> tx.Image {
	path := icon_path(l, spec)
	if path == "" { return {} }
	key := strings.concatenate({path, "@", itoa(int(size))}, context.temp_allocator)
	if img, found := l.images[key]; found {
		if img.rgba == nil { return {} }
		out := tx.image_make(img.w, img.h)
		copy(out.rgba, img.rgba)
		return out
	}
	img, ok := load_icon_file(l, path, size)
	if len(l.images) > 256 {
		for k, &v in l.images { delete(k); tx.image_destroy(&v) }
		clear(&l.images)
	}
	l.images[strings.clone(key)] = img if ok else tx.Image{}
	if !ok { return {} }
	out := tx.image_make(img.w, img.h)
	copy(out.rgba, img.rgba)
	return out
}

// Resolve an icon spec to a file ("" when missing). Names are cached.
@(private)
icon_path :: proc(l: ^Icon_Loader, spec: string) -> string {
	s := strings.trim_space(spec)
	if s == "" { return "" }
	if strings.has_prefix(s, "file://") {
		s = uri_decode(s[len("file://"):])
	}
	if strings.has_prefix(s, "~/") { s = join_path({home_dir(), s[2:]}) }
	if strings.index_byte(s, '/') >= 0 {
		return os.is_file(s) ? s : ""
	}
	if cached, found := l.paths[s]; found { return cached }
	name := s
	for ext in ([]string{".png", ".svg", ".xpm"}) {
		if strings.has_suffix(strings.to_lower(name, context.temp_allocator), ext) {
			name = name[:len(name) - len(ext)]
			break
		}
	}
	found_path := ""
	outer: for &theme in l.themes {
		if p, ok := theme_lookup(l, &theme, name); ok {
			found_path = p
			break outer
		}
	}
	if found_path == "" {
		for dir in l.fallback {
			for ext in icon_extensions(l) {
				candidate := join_path({dir, strings.concatenate({name, ext}, context.temp_allocator)})
				if os.is_file(candidate) {
					found_path = candidate
					break
				}
			}
			if found_path != "" { break }
		}
	}
	l.paths[strings.clone(s)] = strings.clone(found_path)
	return l.paths[s]
}

@(private)
EXTENSIONS_WITH_SVG := [?]string{".png", ".svg"}
@(private)
EXTENSIONS_PNG_ONLY := [?]string{".png"}

@(private)
icon_extensions :: proc(l: ^Icon_Loader) -> []string {
	return EXTENSIONS_WITH_SVG[:] if l.svg else EXTENSIONS_PNG_ONLY[:]
}

@(private)
theme_lookup :: proc(l: ^Icon_Loader, theme: ^Icon_Theme, name: string) -> (string, bool) {
	size := LOOKUP_SIZE
	best := ""
	best_distance := max(int)
	best_size := 0
	exts := icon_extensions(l)
	for &dir in theme.dirs {
		distance := dir_distance(&dir, size)
		if distance > best_distance { continue }
		if distance == best_distance && dir.size <= best_size { continue }
		for ext in exts {
			candidate := join_path({dir.path, strings.concatenate({name, ext}, context.temp_allocator)})
			if !os.is_file(candidate) { continue }
			if distance == 0 { return strings.clone(candidate, context.temp_allocator), true }
			best, best_distance, best_size = candidate, distance, dir.size
			break
		}
	}
	return best, best != ""
}

@(private)
dir_distance :: proc(dir: ^Theme_Dir, size: int) -> int {
	if dir.scale != 1 { return 1 << 20 }
	switch dir.kind {
	case .Fixed:
		return abs(dir.size - size)
	case .Scalable:
		if size < dir.min_size { return dir.min_size - size }
		if size > dir.max_size { return size - dir.max_size }
		return 0
	case .Threshold:
		if size < dir.size - dir.threshold { return dir.min_size - size }
		if size > dir.size + dir.threshold { return size - dir.max_size }
		return 0
	}
	return 1 << 20
}

@(private)
load_theme :: proc(name: string, bases: []string) -> (theme: Icon_Theme, inherits: []string, ok: bool) {
	roots := make([dynamic]string, context.temp_allocator)
	for b in bases {
		root := join_path({b, name})
		if os.is_directory(root) { append(&roots, root) }
	}
	if len(roots) == 0 { return }
	index: Ini
	found := false
	for root in roots {
		data, err := os.read_entire_file(join_path({root, "index.theme"}), context.temp_allocator)
		if err == nil {
			index = parse_ini(string(data))
			found = true
			break
		}
	}
	if !found { return }
	header := index["Icon Theme"] or_else nil
	inherit_list := make([dynamic]string, context.temp_allocator)
	for part in strings.split(header["Inherits"] or_else "", ",", context.temp_allocator) {
		p := strings.trim_space(part)
		if p != "" { append(&inherit_list, p) }
	}
	theme.name = strings.clone(name)
	theme.dirs = make([dynamic]Theme_Dir)
	for part in strings.split(header["Directories"] or_else "", ",", context.temp_allocator) {
		sub := strings.trim_space(part)
		section, has := index[sub]
		if sub == "" || !has { continue }
		base := Theme_Dir{
			size = ini_int(section, "Size", 0),
			scale = ini_int(section, "Scale", 1),
			threshold = ini_int(section, "Threshold", 2),
		}
		if base.size <= 0 { continue }
		base.min_size = ini_int(section, "MinSize", base.size)
		base.max_size = ini_int(section, "MaxSize", base.size)
		switch section["Type"] or_else "Threshold" {
		case "Fixed":    base.kind = .Fixed
		case "Scalable": base.kind = .Scalable
		case:            base.kind = .Threshold
		}
		for root in roots {
			path := join_path({root, sub})
			if !os.is_directory(path) { continue }
			dir := base
			dir.path = strings.clone(path)
			append(&theme.dirs, dir)
		}
	}
	return theme, inherit_list[:], true
}

@(private)
detect_icon_theme :: proc() -> string {
	files := []string{
		join_path({config_home(), "gtk-3.0", "settings.ini"}),
		join_path({config_home(), "gtk-4.0", "settings.ini"}),
		join_path({home_dir(), ".gtkrc-2.0"}),
	}
	for path in files {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil { continue }
		rest := string(data)
		for line in strings.split_lines_iterator(&rest) {
			trimmed := strings.trim_space(line)
			if !strings.has_prefix(trimmed, "gtk-icon-theme-name") { continue }
			eq := strings.index_byte(trimmed, '=')
			if eq < 0 { continue }
			value := strings.trim(strings.trim_space(trimmed[eq + 1:]), "\"")
			if value != "" { return value }
		}
	}
	return "hicolor"
}

// Icon= and Name= of <id>.desktop in the XDG application directories.
@(private)
desktop_entry_info :: proc(id: string, lang: config.Language) -> (icon, name: string) {
	entry := strings.trim_space(id)
	if entry == "" || strings.index_byte(entry, '/') >= 0 { return }
	if strings.has_suffix(entry, ".desktop") { entry = entry[:len(entry) - len(".desktop")] }
	file := strings.concatenate({entry, ".desktop"}, context.temp_allocator)
	for dir in data_dirs() {
		data, err := os.read_entire_file(join_path({dir, "applications", file}), context.temp_allocator)
		if err != nil { continue }
		ini := parse_ini(string(data))
		section, ok := ini["Desktop Entry"]
		if !ok { continue }
		icon = section["Icon"] or_else ""
		name = section["Name"] or_else ""
		// Name[pt_BR], else Name[pt] (Name[es_ES], else Name[es]...).
		if lang != .English {
			full := config.language_code(lang)
			short := full[:2]
			if v, has := section[fmt.tprintf("Name[%s]", full)]; has && v != "" {
				name = v
			} else if v2, has2 := section[fmt.tprintf("Name[%s]", short)]; has2 && v2 != "" {
				name = v2
			}
		}
		return
	}
	return
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

// The image-data hint (RGB or RGBA rows with a stride) as a fitted RGBA image.
@(private)
image_from_raw :: proc(raw: Raw_Image, size: i32) -> tx.Image {
	src := tx.image_make(raw.width, raw.height)
	defer tx.image_destroy(&src)
	ch := int(raw.channels)
	for y in 0 ..< int(raw.height) {
		row := y * int(raw.rowstride)
		for x in 0 ..< int(raw.width) {
			i := row + x * ch
			o := (y * int(raw.width) + x) * 4
			src.rgba[o] = raw.data[i]
			src.rgba[o + 1] = raw.data[i + 1]
			src.rgba[o + 2] = raw.data[i + 2]
			src.rgba[o + 3] = (ch == 4 && raw.has_alpha) ? raw.data[i + 3] : 255
		}
	}
	return fit_image(src, size)
}

@(private)
load_icon_file :: proc(l: ^Icon_Loader, path: string, size: i32) -> (tx.Image, bool) {
	ext := lower_ext(path)
	img: ^image.Image
	err: image.Error
	switch ext {
	case ".svg", ".svgz":
		if !l.svg { return {}, false }
		s := itoa(int(size))
		state, stdout, _, perr := os.process_exec(os.Process_Desc{command = {"rsvg-convert", "-w", s, "-h", s, "--keep-aspect-ratio", path}}, context.temp_allocator)
		if perr != nil || state.exit_code != 0 || len(stdout) == 0 {
			log.debugf("Notifications: rsvg-convert failed for %s", path)
			return {}, false
		}
		img, err = png.load_from_bytes(stdout, {.alpha_add_if_missing}, context.allocator)
	case ".xpm":
		return {}, false
	case:
		data, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr != nil { return {}, false }
		img, err = image.load_from_bytes(data, {.alpha_add_if_missing}, context.allocator)
	}
	if err != nil || img == nil {
		log.debugf("Notifications: cannot decode %s: %v", path, err)
		if img != nil { image.destroy(img) }
		return {}, false
	}
	defer image.destroy(img)
	rgba, ok := to_rgba(img)
	if !ok { return {}, false }
	defer tx.image_destroy(&rgba)
	return fit_image(rgba, size), true
}

@(private)
to_rgba :: proc(img: ^image.Image) -> (tx.Image, bool) {
	if img.width <= 0 || img.height <= 0 || img.channels < 1 || img.channels > 4 { return {}, false }
	if img.depth != 8 && img.depth != 16 { return {}, false }
	n := img.width * img.height
	bytes_per := img.depth / 8
	src := img.pixels.buf[:]
	if len(src) < n * img.channels * bytes_per { return {}, false }
	out := tx.image_make(i32(img.width), i32(img.height))
	sample :: proc(src: []u8, i, bytes_per: int) -> u8 {
		if bytes_per == 1 { return src[i] }
		v := u16(src[2 * i]) | u16(src[2 * i + 1]) << 8
		return u8(v >> 8)
	}
	for p in 0 ..< n {
		base := p * img.channels
		r, g, b, a: u8
		switch img.channels {
		case 1:
			r = sample(src, base, bytes_per); g = r; b = r; a = 255
		case 2:
			r = sample(src, base, bytes_per); g = r; b = r; a = sample(src, base + 1, bytes_per)
		case 3:
			r = sample(src, base, bytes_per); g = sample(src, base + 1, bytes_per); b = sample(src, base + 2, bytes_per); a = 255
		case 4:
			r = sample(src, base, bytes_per); g = sample(src, base + 1, bytes_per); b = sample(src, base + 2, bytes_per); a = sample(src, base + 3, bytes_per)
		}
		out.rgba[p * 4] = r
		out.rgba[p * 4 + 1] = g
		out.rgba[p * 4 + 2] = b
		out.rgba[p * 4 + 3] = a
	}
	return out, true
}

// Scale so the longer side equals `size`, centred on a transparent square.
@(private)
fit_image :: proc(src: tx.Image, size: i32) -> tx.Image {
	out := tx.image_make(size, size)
	w, h := size, size
	if src.w > src.h {
		h = max(1, i32(math.round(f64(size) * f64(src.h) / f64(src.w))))
	} else if src.h > src.w {
		w = max(1, i32(math.round(f64(size) * f64(src.w) / f64(src.h))))
	}
	scaled := src
	resized := false
	if src.w != w || src.h != h {
		scaled = tx.image_resize(src, w, h)
		resized = true
	}
	defer if resized { tx.image_destroy(&scaled) }
	ox, oy := (size - w) / 2, (size - h) / 2
	for y in 0 ..< h {
		copy(out.rgba[int((oy + y) * size + ox) * 4:][:int(w) * 4], scaled.rgba[int(y * w) * 4:][:int(w) * 4])
	}
	return out
}

// ---------------------------------------------------------------------------
// Small helpers (paths, INI files)
// ---------------------------------------------------------------------------
@(private)
join_path :: proc(elems: []string, allocator := context.temp_allocator) -> string {
	joined, _ := os.join_path(elems, allocator)
	return joined
}

@(private)
home_dir :: proc() -> string {
	if v, found := os.lookup_env("HOME", context.temp_allocator); found && v != "" { return v }
	return "/"
}

@(private)
env_or :: proc(name: string, fallback: string) -> string {
	if v, found := os.lookup_env(name, context.temp_allocator); found && v != "" { return v }
	return fallback
}

@(private)
config_home :: proc() -> string { return env_or("XDG_CONFIG_HOME", join_path({home_dir(), ".config"})) }

@(private)
data_dirs :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	append(&out, env_or("XDG_DATA_HOME", join_path({home_dir(), ".local", "share"})))
	for d in strings.split(env_or("XDG_DATA_DIRS", "/usr/local/share:/usr/share"), ":", context.temp_allocator) {
		if d != "" { append(&out, d) }
	}
	return out[:]
}

@(private)
icon_base_dirs :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	candidates := make([dynamic]string, context.temp_allocator)
	append(&candidates, join_path({home_dir(), ".icons"}))
	for d in data_dirs() { append(&candidates, join_path({d, "icons"})) }
	outer: for c in candidates {
		for o in out { if o == c { continue outer } }
		if os.is_directory(c) { append(&out, c) }
	}
	return out[:]
}

@(private)
find_in_path :: proc(name: string) -> bool {
	for dir in strings.split(env_or("PATH", "/usr/local/bin:/usr/bin:/bin"), ":", context.temp_allocator) {
		if dir != "" && os.is_file(join_path({dir, name})) { return true }
	}
	return false
}

@(private)
lower_ext :: proc(path: string) -> string {
	name := path
	if slash := strings.last_index_byte(path, '/'); slash >= 0 { name = path[slash + 1:] }
	dot := strings.last_index_byte(name, '.')
	if dot <= 0 { return "" }
	return strings.to_lower(name[dot:], context.temp_allocator)
}

@(private)
uri_decode :: proc(s: string) -> string {
	if strings.index_byte(s, '%') < 0 { return s }
	out := make([dynamic]u8, context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			if v, ok := strconv.parse_int(s[i + 1:i + 3], 16); ok {
				append(&out, u8(v))
				i += 2
				continue
			}
		}
		append(&out, s[i])
	}
	return string(out[:])
}

@(private)
itoa :: proc(v: int) -> string {
	buf := make([]u8, 24, context.temp_allocator)
	return strconv.write_int(buf, i64(v), 10)
}

@(private) Ini_Section :: map[string]string
@(private) Ini :: map[string]Ini_Section

@(private)
parse_ini :: proc(text: string) -> Ini {
	sections := make(Ini, context.temp_allocator)
	current: ^Ini_Section
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' || line[0] == ';' { continue }
		if line[0] == '[' && line[len(line) - 1] == ']' {
			name := strings.trim_space(line[1:len(line) - 1])
			if name not_in sections { sections[name] = make(Ini_Section, context.temp_allocator) }
			current = &sections[name]
			continue
		}
		eq := strings.index_byte(line, '=')
		if current == nil || eq < 0 { continue }
		key := strings.trim_space(line[:eq])
		if key == "" || key in current^ { continue }
		current[key] = strings.trim_space(line[eq + 1:])
	}
	return sections
}

@(private)
ini_int :: proc(section: Ini_Section, key: string, fallback: int) -> int {
	v, ok := section[key]
	if !ok { return fallback }
	n, parsed := strconv.parse_int(strings.trim_space(v), 10)
	return n if parsed else fallback
}
