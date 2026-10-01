// Pictures of the SNI items: IconPixmap first (the image closest to the icon
// size, scaled), else IconName looked up in the item's IconThemePath and then
// in the user's icon theme with the desktop icons' loader (index.theme,
// inheritance, rsvg-convert for SVG). NeedsAttention items show their
// attention picture when they have one.
package tray

import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import desktop "../desktop"
import tx "../tx"

// The a(iiay) image closest to `size`: the smallest at least that large,
// else the largest.
@(private)
best_pixmap :: proc(value: ^DBusMessageIter, size: i32) -> (best: Raw_Pixmap) {
	if dbus_message_iter_get_arg_type(value) != DBUS_TYPE_ARRAY { return }
	arr: DBusMessageIter
	dbus_message_iter_recurse(value, &arr)
	for dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_STRUCT {
		defer dbus_message_iter_next(&arr)
		s: DBusMessageIter
		dbus_message_iter_recurse(&arr, &s)
		w, wok := iter_int(&s)
		dbus_message_iter_next(&s)
		h, hok := iter_int(&s)
		dbus_message_iter_next(&s)
		if !wok || !hok || w <= 0 || h <= 0 || w > 1024 || h > 1024 { continue }
		if dbus_message_iter_get_arg_type(&s) != DBUS_TYPE_ARRAY || dbus_message_iter_get_element_type(&s) != DBUS_TYPE_BYTE { continue }
		bytes: DBusMessageIter
		dbus_message_iter_recurse(&s, &bytes)
		data: [^]u8
		count: i32
		dbus_message_iter_get_fixed_array(&bytes, &data, &count)
		if data == nil || int(count) < int(w) * int(h) * 4 { continue }
		better := false
		switch {
		case best.data == nil:             better = true
		case best.w >= size:               better = i32(w) >= size && i32(w) < best.w
		case:                              better = i32(w) > best.w
		}
		if better { best = Raw_Pixmap{w = i32(w), h = i32(h), data = data[:count]} }
	}
	return
}

// ARGB32 (network byte order) → RGBA, fitted into size x size.
@(private)
pixmap_image :: proc(raw: Raw_Pixmap, size: i32) -> tx.Image {
	if raw.data == nil { return {} }
	src := tx.image_make(raw.w, raw.h, context.temp_allocator)
	for i in 0 ..< int(raw.w) * int(raw.h) {
		src.rgba[i * 4] = raw.data[i * 4 + 1]
		src.rgba[i * 4 + 1] = raw.data[i * 4 + 2]
		src.rgba[i * 4 + 2] = raw.data[i * 4 + 3]
		src.rgba[i * 4 + 3] = raw.data[i * 4]
	}
	return fit_image(src, size)
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
	if src.w != w || src.h != h { scaled = tx.image_resize(src, w, h, context.temp_allocator) }
	ox, oy := (size - w) / 2, (size - h) / 2
	for y in 0 ..< h {
		copy(out.rgba[int((oy + y) * size + ox) * 4:][:int(w) * 4], scaled.rgba[int(y * w) * 4:][:int(w) * 4])
	}
	return out
}

@(private)
clone_image :: proc(img: tx.Image) -> tx.Image {
	out := tx.image_make(img.w, img.h)
	copy(out.rgba, img.rgba)
	return out
}

// Pick the picture for the item's state.
@(private)
resolve_picture :: proc(t: ^Tray, item: ^Item) {
	tx.image_destroy(&item.picture)
	if item.status == .Needs_Attention {
		if item.attention_pixmap.rgba != nil {
			item.picture = clone_image(item.attention_pixmap)
			return
		}
		if img, ok := lookup_icon(t, item.theme_path, item.attention_name); ok {
			item.picture = img
			return
		}
	}
	if item.pixmap.rgba != nil {
		item.picture = clone_image(item.pixmap)
		return
	}
	if img, ok := lookup_icon(t, item.theme_path, item.icon_name); ok { item.picture = img }
}

// An icon name (or path) as a size x size picture (a copy).
@(private)
lookup_icon :: proc(t: ^Tray, theme_path, icon: string) -> (tx.Image, bool) {
	name := strings.trim_space(icon)
	if name == "" { return {}, false }
	if !t.loader_ready {
		desktop.icons_init(&t.loader, t.cfg)
		t.loader.size = t.size
		t.loader_ready = true
	}
	if theme_path != "" && strings.index_byte(name, '/') < 0 {
		if file := theme_path_file(t, theme_path, name); file != "" {
			if img := desktop.lookup_icon(&t.loader, file); img != nil { return clone_image(img^), true }
		}
	}
	if img := desktop.lookup_icon(&t.loader, name); img != nil { return clone_image(img^), true }
	return {}, false
}

// `name` in an item's own icon directory (flat, or laid out like a theme:
// hicolor/22x22/apps/name.png): the PNG closest to the icon size, else an SVG.
@(private)
theme_path_file :: proc(t: ^Tray, dir, name: string) -> string {
	key := strings.concatenate({dir, "\x00", name}, context.temp_allocator)
	if cached, ok := t.theme_files[key]; ok { return cached }
	base := name
	for ext in ([]string{".png", ".svg"}) {
		if strings.has_suffix(base, ext) { base = base[:len(base) - len(ext)] }
	}
	Search :: struct {
		t:          ^Tray,
		base:       string,
		best:       string,
		best_score: int,
	}
	s := Search{t = t, base = base, best_score = max(int)}
	walk :: proc(s: ^Search, dir: string, depth: int, size_hint: int) {
		infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil { return }
		for fi in infos {
			name := os.base(fi.fullpath)
			if fi.type == .Directory {
				if depth < 4 && !strings.has_prefix(name, ".") { walk(s, fi.fullpath, depth + 1, dir_size(name, size_hint)) }
				continue
			}
			score := -1
			if !strings.has_prefix(name, s.base) { continue }
			if ext := name[len(s.base):]; ext == ".png" {
				target := int(s.t.size)
				switch {
				case size_hint <= 0:      score = 100
				case size_hint >= target: score = size_hint - target
				case:                     score = (target - size_hint) * 2 + 1
				}
			} else if ext == ".svg" && s.t.loader.svg {
				score = 50
			}
			if score >= 0 && score < s.best_score {
				s.best = fi.fullpath
				s.best_score = score
			}
		}
	}
	// "22x22", "22x22@2", "scalable" or a bare "22".
	dir_size :: proc(name: string, inherited: int) -> int {
		n := name
		if x := strings.index_byte(n, 'x'); x > 0 { n = n[:x] }
		if v, ok := strconv.parse_int(n, 10); ok && v > 0 { return v }
		return inherited
	}
	walk(&s, dir, 0, 0)
	if len(t.theme_files) > 256 {
		for k, v in t.theme_files {
			delete(k)
			delete(v)
		}
		clear(&t.theme_files)
	}
	t.theme_files[strings.clone(key)] = strings.clone(s.best)
	return t.theme_files[key]
}
