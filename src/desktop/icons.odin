// Icons for the desktop cells: XDG icon theme lookup (index.theme, theme
// inheritance, size matching as in the Icon Theme spec), PNG decoding with
// core:image/png, SVG rendered by rsvg-convert, and a coloured rounded square
// with the first letter as the last resort (drawn by the layer).
package desktop

import "core:hash"
import "core:image"
import "core:image/png"
import "core:log"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import config "../config"
import tx "../tx"

@(private)
Dir_Kind :: enum { Threshold, Fixed, Scalable }

@(private)
Theme_Dir :: struct {
	path:      string, // absolute directory (base/theme/subdir), known to exist
	size:      int,
	min_size:  int,
	max_size:  int,
	threshold: int,
	scale:     int,
	kind:      Dir_Kind,
}

@(private)
Icon_Theme :: struct {
	name: string,
	dirs: [dynamic]Theme_Dir,
}

@(private)
Cached_Icon :: struct {
	found: bool,
	image: tx.Image,
}

Icon_Loader :: struct {
	size:        i32,
	svg:         bool, // rsvg-convert is available
	themes:      [dynamic]Icon_Theme,
	fallback:    [dynamic]string, // pixmaps and base directories (unthemed icons)
	cache:       map[string]Cached_Icon,
	initialized: bool,
}

// Icon names tried when an entry has no usable Icon=.
@(private)
LINK_FALLBACK_ICONS :: []string{"text-html", "emblem-web", "applications-internet", "web-browser"}
@(private)
APP_FALLBACK_ICONS :: []string{"application-x-executable"}

icons_init :: proc(l: ^Icon_Loader, cfg: ^config.Config) {
	l.size = i32(cfg.linux.shortcuts.icon_size)
	l.cache = make(map[string]Cached_Icon)
	l.themes = make([dynamic]Icon_Theme)
	l.fallback = make([dynamic]string)
	l.initialized = true
	_, l.svg = find_executable("rsvg-convert")
	if !l.svg { log.info("rsvg-convert not found: SVG icons are skipped (install librsvg for them)") }

	bases := icon_base_dirs()
	theme := cfg.linux.shortcuts.icon_theme
	if theme == "" { theme = detect_icon_theme() }
	// Breadth-first over Inherits=, then the usual fallbacks.
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
	for b in bases { append(&l.fallback, strings.clone(b)) }
	if len(l.themes) > 0 {
		log.debugf("Icon theme %q (%d themes in the lookup chain)", l.themes[0].name, len(l.themes))
	}
}

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
	for key, &entry in l.cache {
		delete(key)
		if entry.found { tx.image_destroy(&entry.image) }
	}
	delete(l.cache)
	l^ = {}
}

// The icon for a shortcut (size x size RGBA), or nil when the glyph must be drawn.
icon_for :: proc(l: ^Icon_Loader, s: ^Shortcut) -> ^tx.Image {
	if s.icon != "" {
		if img := icon_by_name_or_path(l, s.icon); img != nil { return img }
	}
	names := LINK_FALLBACK_ICONS if s.kind == .Link else APP_FALLBACK_ICONS
	for name in names {
		if img := icon_cached(l, name); img != nil { return img }
	}
	return nil
}

// Colour of the fallback glyph square: a hue derived from the name.
glyph_color :: proc(name: string) -> tx.Color {
	hue := f64(hash.crc32(transmute([]byte)name) % 360) / 360.0
	r, g, b := hls_to_rgb(hue, 0.42, 0.55)
	return tx.rgba(u8(r * 255), u8(g * 255), u8(b * 255), 235)
}

// ---------------------------------------------------------------------------
// Lookup
// ---------------------------------------------------------------------------
@(private)
icon_by_name_or_path :: proc(l: ^Icon_Loader, icon: string) -> ^tx.Image {
	if strings.index_byte(icon, '/') >= 0 {
		return icon_cached(l, icon)
	}
	name := icon
	for ext in ([]string{".png", ".svg", ".xpm"}) {
		if strings.has_suffix(strings.to_lower(name, context.temp_allocator), ext) {
			name = name[:len(name) - len(ext)]
			break
		}
	}
	return icon_cached(l, name)
}

// Look an icon name (or absolute path) up once; misses are cached too.
@(private)
icon_cached :: proc(l: ^Icon_Loader, key: string) -> ^tx.Image {
	if entry, ok := &l.cache[key]; ok {
		return &entry.image if entry.found else nil
	}
	img, found := icon_load(l, key)
	l.cache[strings.clone(key)] = Cached_Icon{found = found, image = img}
	entry := &l.cache[key]
	return &entry.image if entry.found else nil
}

@(private)
icon_load :: proc(l: ^Icon_Loader, key: string) -> (tx.Image, bool) {
	if strings.index_byte(key, '/') >= 0 {
		path := key
		if strings.has_prefix(path, "~/") { path = join_path({home_dir(), path[2:]}) }
		if !os.is_file(path) { return {}, false }
		return load_icon_file(l, path)
	}
	for &theme in l.themes {
		if path, found := theme_lookup(l, &theme, key); found {
			if img, ok := load_icon_file(l, path); ok { return img, true }
		}
	}
	exts := icon_extensions(l)
	for dir in l.fallback {
		for ext in exts {
			candidate := join_path({dir, strings.concatenate({key, ext}, context.temp_allocator)})
			if os.is_file(candidate) {
				if img, ok := load_icon_file(l, candidate); ok { return img, true }
			}
		}
	}
	return {}, false
}

// XPM is not decodable here; skipping it lets the lookup find a PNG/SVG elsewhere.
@(private)
EXTENSIONS_WITH_SVG := [?]string{".png", ".svg"}
@(private)
EXTENSIONS_PNG_ONLY := [?]string{".png"}

@(private)
icon_extensions :: proc(l: ^Icon_Loader) -> []string {
	return EXTENSIONS_WITH_SVG[:] if l.svg else EXTENSIONS_PNG_ONLY[:]
}

// LookupIcon from the Icon Theme spec: an exact size match wins, otherwise
// the closest directory (ties prefer the larger icon, which scales down better).
@(private)
theme_lookup :: proc(l: ^Icon_Loader, theme: ^Icon_Theme, name: string) -> (string, bool) {
	size := int(l.size)
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
			if distance == 0 { return candidate, true }
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

// ~/.icons, $XDG_DATA_HOME/icons, $XDG_DATA_DIRS/icons (existing ones).
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

// The GTK icon theme name from the usual settings files, else "hicolor".
@(private)
detect_icon_theme :: proc() -> string {
	files := []string{
		join_path({config_home(), "gtk-3.0", "settings.ini"}),
		join_path({config_home(), "gtk-4.0", "settings.ini"}),
		join_path({home_dir(), ".gtkrc-2.0"}),
	}
	for path in files {
		text, ok := read_text_file(path)
		if !ok { continue }
		rest := text
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

// Read a theme's index.theme; only directories that exist are kept.
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
		if text, read_ok := read_text_file(join_path({root, "index.theme"})); read_ok {
			index = parse_ini(text)
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
ini_int :: proc(section: Ini_Section, key: string, fallback: int) -> int {
	v, ok := section[key]
	if !ok { return fallback }
	n, parsed := strconv.parse_int(strings.trim_space(v), 10)
	return n if parsed else fallback
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

// Load an icon file and fit it into size x size (aspect kept, centred).
@(private)
load_icon_file :: proc(l: ^Icon_Loader, path: string) -> (tx.Image, bool) {
	ext := lower_ext(path)
	img: ^image.Image
	err: image.Error
	switch ext {
	case ".svg", ".svgz":
		if !l.svg { return {}, false }
		size := strings.clone(itoa(int(l.size)), context.temp_allocator)
		res := run_sync({"rsvg-convert", "-w", size, "-h", size, "--keep-aspect-ratio", path}, 10, true)
		if !res.started || res.exit_code != 0 || len(res.stdout) == 0 {
			log.debugf("rsvg-convert failed for %s: %s", path, strings.trim_space(string(res.stderr)))
			return {}, false
		}
		img, err = png.load_from_bytes(res.stdout, {.alpha_add_if_missing}, context.allocator)
	case ".xpm":
		return {}, false
	case:
		data, rerr := os.read_entire_file(path, context.allocator)
		if rerr != nil { return {}, false }
		defer delete(data)
		img, err = image.load_from_bytes(data, {.alpha_add_if_missing}, context.allocator)
	}
	if err != nil || img == nil {
		log.debugf("Could not decode icon %s: %v", path, err)
		if img != nil { image.destroy(img) }
		return {}, false
	}
	defer image.destroy(img)
	rgba, ok := to_rgba(img)
	if !ok { return {}, false }
	defer tx.image_destroy(&rgba)
	return fit_icon(rgba, l.size), true
}

// core:image result (any channel count, 8 or 16 bits) → straight RGBA8.
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
		// 16-bit samples are native-endian u16.
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
fit_icon :: proc(src: tx.Image, size: i32) -> tx.Image {
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

@(private)
hls_to_rgb :: proc(h, l, s: f64) -> (f64, f64, f64) {
	if s == 0 { return l, l, l }
	m2 := l * (1 + s) if l <= 0.5 else l + s - l * s
	m1 := 2 * l - m2
	v :: proc(m1, m2, hue: f64) -> f64 {
		h := hue - math.floor(hue)
		if h < 1.0 / 6 { return m1 + (m2 - m1) * h * 6 }
		if h < 0.5 { return m2 }
		if h < 2.0 / 3 { return m1 + (m2 - m1) * (2.0 / 3 - h) * 6 }
		return m1
	}
	return v(m1, m2, h + 1.0 / 3), v(m1, m2, h), v(m1, m2, h - 1.0 / 3)
}

@(private)
itoa :: proc(v: int) -> string {
	buf := make([]u8, 24, context.temp_allocator)
	return strconv.write_int(buf, i64(v), 10)
}
