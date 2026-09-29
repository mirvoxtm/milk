// Wallpaper candidates and their thumbnails.
//
// Images are collected from the runtime Wallpapers folder, the XDG Pictures
// folder (and its Wallpapers subfolder), /usr/share/wallpapers and
// /usr/share/backgrounds. Decoding a 5K PNG takes a while, so thumbnails are
// made by a few worker threads (pure CPU work, no X calls) while the wizard
// keeps drawing; the main loop polls their state. Finished thumbnails are
// cached as QOI files under <runtime>/.thumbs, keyed by path, size and mtime.
package oobe

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:hash"
import "core:image"
import _ "core:image/bmp"
import _ "core:image/jpeg"
import _ "core:image/png"
import "core:image/qoi"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import tx "../tx"

@(private) THUMB_W        :: 480
@(private) THUMB_H        :: 270
@(private) MAX_CANDIDATES :: 60
@(private) THUMB_WORKERS  :: 3

@(private) Thumb_State :: enum i32 { Pending, Ready, Failed }

@(private)
Scaled :: struct {
	img:   tx.Image,
	w, h:  i32,
	stamp: u64,
}

@(private)
Candidate :: struct {
	path:   string,      // wizard allocator
	thumb:  tx.Image,    // heap allocator; written by a worker before `state` becomes Ready
	state:  Thumb_State, // atomic
	seen:   bool,        // the main thread noticed the final state
	scaled: [2]Scaled,   // resized copies (wizard allocator)
}

@(private)
Thumbs :: struct {
	items:     []Candidate,
	next:      int,  // atomic: next item to decode
	cancel:    bool, // atomic
	workers:   [dynamic]^thread.Thread,
	cache_dir: string,
	pending:   int,  // items whose final state the main thread has not seen
	stamp:     u64,
}

@(private)
join_path :: proc(parts: []string, allocator := context.temp_allocator) -> string {
	s, _ := filepath.join(parts, allocator)
	return s
}

@(private)
home_dir :: proc() -> string {
	if v, found := os.lookup_env("HOME", context.temp_allocator); found && v != "" { return v }
	return "/"
}

// XDG_<KEY>_DIR from ~/.config/user-dirs.dirs (~/Imagens on a Portuguese system).
@(private)
xdg_user_dir :: proc(key: string, fallback: string) -> string {
	config_home, found := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
	if !found || config_home == "" { config_home = join_path({home_dir(), ".config"}) }
	data, err := os.read_entire_file(join_path({config_home, "user-dirs.dirs"}), context.temp_allocator)
	if err != nil { return fallback }
	wanted := fmt.tprintf("XDG_%s_DIR=", key)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, wanted) { continue }
		value := strings.trim(trimmed[len(wanted):], "\"")
		value, _ = strings.replace_all(value, "$HOME", home_dir(), context.temp_allocator)
		if value != "" { return value }
	}
	return fallback
}

@(private)
is_image_name :: proc(name: string) -> bool {
	lower := strings.to_lower(name, context.temp_allocator)
	if strings.contains(lower, "screenshot") || strings.has_prefix(lower, "captura") { return false }
	for ext in ([]string{".jpg", ".jpeg", ".png", ".bmp"}) {
		if strings.has_suffix(lower, ext) { return true }
	}
	return false
}

// Width in names such as "5120x2880.png" (KDE wallpaper packages).
@(private)
name_width :: proc(name: string) -> (w, h: int, ok: bool) {
	stem := filepath.stem(name)
	x := strings.index_byte(stem, 'x')
	if x <= 0 { return }
	w, ok = strconv.parse_int(stem[:x], 10)
	if !ok { return }
	h, ok = strconv.parse_int(stem[x + 1:], 10)
	return
}

@(private)
scan_dir :: proc(dir: string, recursive: bool, depth: int, out: ^[dynamic]string, seen: ^map[string]bool) {
	if len(out) >= MAX_CANDIDATES || depth > 5 || !os.is_directory(dir) { return }
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	names := make([dynamic]string, context.temp_allocator)
	subdirs := make([dynamic]string, context.temp_allocator)
	for fi in infos {
		if strings.has_prefix(fi.name, ".") { continue }
		full := join_path({dir, fi.name})
		#partial switch fi.type {
		case .Directory:
			append(&subdirs, full)
		case .Regular, .Symlink:
			if is_image_name(fi.name) { append(&names, full) }
		}
	}
	sort_strings(names[:])
	sort_strings(subdirs[:])
	// A KDE wallpaper package ships one picture in several sizes: keep the
	// widest landscape one.
	base := filepath.base(dir)
	if (base == "images" || base == "images_dark") && strings.has_suffix(filepath.dir(dir), "contents") && len(names) > 1 {
		best := -1
		best_w := 0
		for n, i in names {
			nw, nh, ok := name_width(filepath.base(n))
			if ok && nw > nh && nw > best_w { best, best_w = i, nw }
		}
		if best >= 0 {
			keep := names[best]
			clear(&names)
			append(&names, keep)
		}
	}
	for n in names {
		if len(out) >= MAX_CANDIDATES { return }
		if seen[n] { continue }
		seen[n] = true
		append(out, n)
	}
	if recursive {
		for d in subdirs { scan_dir(d, true, depth + 1, out, seen) }
	}
}

@(private)
sort_strings :: proc(a: []string) {
	for i in 1 ..< len(a) {
		for j := i; j > 0 && a[j] < a[j - 1]; j -= 1 { a[j], a[j - 1] = a[j - 1], a[j] }
	}
}

// Collect the candidates and start the decoder threads.
@(private)
thumbs_start :: proc(w: ^Wizard) {
	t := &w.thumbs
	paths := make([dynamic]string, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	pictures := xdg_user_dir("PICTURES", join_path({home_dir(), "Pictures"}))
	scan_dir(join_path({w.runtime_root, w.cfg.paths.wallpapers}), false, 0, &paths, &seen)
	scan_dir(join_path({pictures, "Wallpapers"}), true, 0, &paths, &seen)
	scan_dir(pictures, false, 0, &paths, &seen)
	scan_dir("/usr/share/wallpapers", true, 0, &paths, &seen)
	scan_dir("/usr/share/backgrounds", true, 0, &paths, &seen)

	t.items = make([]Candidate, len(paths), w.allocator)
	for p, i in paths { t.items[i].path = strings.clone(p, w.allocator) }
	t.pending = len(t.items)
	log.debugf("Setup: %d wallpaper candidates", len(t.items))

	cache := join_path({w.runtime_root, ".thumbs"})
	if err := os.make_directory_all(cache); err == nil || err == .Exist || os.is_directory(cache) {
		t.cache_dir = strings.clone(cache, w.allocator)
	}
	if len(t.items) == 0 { return }
	for _ in 0 ..< min(THUMB_WORKERS, len(t.items)) {
		th := thread.create(thumb_worker, .Low)
		if th == nil { continue }
		th.data = t
		thread.start(th)
		append(&t.workers, th)
	}
	if len(t.workers) == 0 {
		// No threads: nothing will be decoded; show the "no wallpaper" tile only.
		for &item in t.items { item.state = .Failed }
	}
}

@(private)
thumb_worker :: proc(th: ^thread.Thread) {
	t := (^Thumbs)(th.data)
	context.allocator = runtime.heap_allocator()
	for {
		if sync.atomic_load(&t.cancel) { return }
		i := sync.atomic_add(&t.next, 1)
		if i >= len(t.items) { return }
		item := &t.items[i]
		img, ok := load_thumb(item.path, t.cache_dir)
		if ok {
			item.thumb = img
			sync.atomic_store(&item.state, Thumb_State.Ready)
		} else {
			sync.atomic_store(&item.state, Thumb_State.Failed)
		}
	}
}

// Decode (or read from the cache) one thumbnail. Runs on a worker thread.
@(private)
load_thumb :: proc(path, cache_dir: string) -> (tx.Image, bool) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { return {}, false }
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)
	context.temp_allocator = scratch
	heap := runtime.heap_allocator()

	cache_file := ""
	if cache_dir != "" {
		if fi, err := os.stat(path, scratch); err == nil {
			key := fmt.aprintf("%s|%d|%v|%dx%d", path, fi.size, fi.modification_time, THUMB_W, THUMB_H, allocator = scratch)
			cache_file = fmt.aprintf("%s/%16x.qoi", cache_dir, hash.fnv64a(transmute([]u8)key), allocator = scratch)
			if data, rerr := os.read_entire_file(cache_file, scratch); rerr == nil {
				img, lerr := qoi.load_from_bytes(data, {}, scratch)
				if lerr == nil && img != nil && img.width == THUMB_W && img.height == THUMB_H && img.channels == 4 && img.depth == 8 {
					out := tx.image_make(THUMB_W, THUMB_H, heap)
					copy(out.rgba, img.pixels.buf[:])
					return out, true
				}
			}
		}
	}

	data, rerr := os.read_entire_file(path, scratch)
	if rerr != nil { return {}, false }
	img, lerr := image.load_from_bytes(data, {}, scratch)
	if lerr != nil || img == nil { return {}, false }
	// Portrait pictures and icons are no wallpapers.
	if img.width < 640 || img.height < 360 || img.height > img.width { return {}, false }
	src, ok := image_view(img, scratch)
	if !ok { return {}, false }
	out := cover_resize(src, THUMB_W, THUMB_H, heap)

	if cache_file != "" {
		enc: image.Image
		enc.width, enc.height, enc.channels, enc.depth = THUMB_W, THUMB_H, 4, 8
		buf := make([dynamic]u8, len(out.rgba), scratch)
		copy(buf[:], out.rgba)
		enc.pixels = bytes.Buffer{buf = buf}
		tmp := fmt.aprintf("%s.%x.tmp", cache_file, uintptr(&arena), allocator = scratch)
		if qoi.save_to_file(tmp, &enc, {}, scratch) == nil {
			if os.rename(tmp, cache_file) != nil { os.remove(tmp) }
		}
	}
	return out, true
}

// An 8-bit RGBA view of a decoded image (converted when it is not RGBA8 already).
@(private)
image_view :: proc(img: ^image.Image, allocator: runtime.Allocator) -> (tx.Image, bool) {
	if img.width <= 0 || img.height <= 0 || img.channels < 1 || img.channels > 4 { return {}, false }
	if img.depth != 8 && img.depth != 16 { return {}, false }
	px := img.pixels.buf[:]
	n := img.width * img.height
	if img.depth == 8 && img.channels == 4 && len(px) >= n * 4 {
		return tx.Image{w = i32(img.width), h = i32(img.height), rgba = px[:n * 4]}, true
	}
	bpc := img.depth / 8
	if len(px) < n * img.channels * bpc { return {}, false }
	out := tx.image_make(i32(img.width), i32(img.height), allocator)
	sample :: #force_inline proc(px: []u8, index, bpc: int) -> u8 {
		return px[index] if bpc == 1 else px[index * 2 + 1]
	}
	for i in 0 ..< n {
		base := i * img.channels
		r, g, b, a: u8
		switch img.channels {
		case 1: r = sample(px, base, bpc); g = r; b = r; a = 255
		case 2: r = sample(px, base, bpc); g = r; b = r; a = sample(px, base + 1, bpc)
		case 3: r = sample(px, base, bpc); g = sample(px, base + 1, bpc); b = sample(px, base + 2, bpc); a = 255
		case 4: r = sample(px, base, bpc); g = sample(px, base + 1, bpc); b = sample(px, base + 2, bpc); a = sample(px, base + 3, bpc)
		}
		out.rgba[i * 4], out.rgba[i * 4 + 1], out.rgba[i * 4 + 2], out.rgba[i * 4 + 3] = r, g, b, a
	}
	return out, true
}

// Scale to exactly dw×dh, cropping the longer side (like feh --bg-fill), with a box filter.
@(private)
cover_resize :: proc(src: tx.Image, dw, dh: i32, allocator := context.allocator) -> tx.Image {
	dst := tx.image_make(dw, dh, allocator)
	if src.w <= 0 || src.h <= 0 { return dst }
	sw, sh := f32(src.w), f32(src.h)
	scale := max(f32(dw) / sw, f32(dh) / sh)
	cw := f32(dw) / scale
	ch := f32(dh) / scale
	ox := (sw - cw) / 2
	oy := (sh - ch) / 2
	stride := int(src.w)
	for y in 0 ..< int(dh) {
		sy0 := clamp(int(oy + f32(y) * ch / f32(dh)), 0, int(src.h) - 1)
		sy1 := clamp(int(oy + f32(y + 1) * ch / f32(dh)), sy0 + 1, int(src.h))
		for x in 0 ..< int(dw) {
			sx0 := clamp(int(ox + f32(x) * cw / f32(dw)), 0, int(src.w) - 1)
			sx1 := clamp(int(ox + f32(x + 1) * cw / f32(dw)), sx0 + 1, int(src.w))
			r, g, b, a, n: u32
			for sy in sy0 ..< sy1 {
				row := sy * stride
				for sx in sx0 ..< sx1 {
					i := (row + sx) * 4
					r += u32(src.rgba[i])
					g += u32(src.rgba[i + 1])
					b += u32(src.rgba[i + 2])
					a += u32(src.rgba[i + 3])
					n += 1
				}
			}
			o := (y * int(dw) + x) * 4
			dst.rgba[o] = u8(r / n)
			dst.rgba[o + 1] = u8(g / n)
			dst.rgba[o + 2] = u8(b / n)
			dst.rgba[o + 3] = u8(a / n)
		}
	}
	return dst
}

// Pick up finished thumbnails. Returns true when something visible changed.
@(private)
thumbs_poll :: proc(w: ^Wizard) -> bool {
	t := &w.thumbs
	if t.pending == 0 { return false }
	changed := false
	for &item, i in t.items {
		if item.seen { continue }
		st := sync.atomic_load(&item.state)
		if st == .Pending { continue }
		item.seen = true
		t.pending -= 1
		changed = true
		if st == .Ready && i == backdrop_candidate(w) { w.base_dirty = true }
	}
	if t.pending == 0 { thumbs_stop(w) }
	return changed && shows_thumbnails(w)
}

@(private)
thumbs_busy :: proc(w: ^Wizard) -> bool { return w.thumbs.pending > 0 }

// Stop the workers (the one decoding finishes its picture first).
@(private)
thumbs_stop :: proc(w: ^Wizard) {
	t := &w.thumbs
	sync.atomic_store(&t.cancel, true)
	for th in t.workers {
		thread.join(th)
		thread.destroy(th)
	}
	clear(&t.workers)
}

@(private)
thumbs_destroy :: proc(w: ^Wizard) {
	thumbs_stop(w)
	t := &w.thumbs
	heap := runtime.heap_allocator()
	for &item in t.items {
		if sync.atomic_load(&item.state) == .Ready { delete(item.thumb.rgba, heap) }
		for &s in item.scaled { tx.image_destroy(&s.img) }
		delete(item.path)
	}
	delete(t.items)
	delete(t.workers)
	delete(t.cache_dir)
	t^ = {}
}

@(private)
candidate_ready :: proc(w: ^Wizard, index: int) -> bool {
	if index < 0 || index >= len(w.thumbs.items) { return false }
	item := &w.thumbs.items[index]
	return item.seen && sync.atomic_load(&item.state) == .Ready
}

@(private)
candidate_thumb :: proc(w: ^Wizard, index: int) -> (tx.Image, bool) {
	if !candidate_ready(w, index) { return {}, false }
	return w.thumbs.items[index].thumb, true
}

// The thumbnail cover-scaled to w×h (two sizes are cached per candidate).
@(private)
candidate_scaled :: proc(w: ^Wizard, index: int, sw, sh: i32) -> (tx.Image, bool) {
	src, ok := candidate_thumb(w, index)
	if !ok || sw <= 0 || sh <= 0 { return {}, false }
	if sw == src.w && sh == src.h { return src, true }
	item := &w.thumbs.items[index]
	w.thumbs.stamp += 1
	for &s in item.scaled {
		if s.w == sw && s.h == sh && len(s.img.rgba) > 0 {
			s.stamp = w.thumbs.stamp
			return s.img, true
		}
	}
	slot := &item.scaled[0]
	if item.scaled[1].stamp < slot.stamp { slot = &item.scaled[1] }
	tx.image_destroy(&slot.img)
	slot.img = cover_resize(src, sw, sh, w.allocator)
	slot.w, slot.h, slot.stamp = sw, sh, w.thumbs.stamp
	return slot.img, true
}

// Candidates the grid shows: everything not known to have failed.
@(private)
visible_candidates :: proc(w: ^Wizard) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for &item, i in w.thumbs.items {
		if item.seen && sync.atomic_load(&item.state) == .Failed { continue }
		append(&out, i)
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Wallpaper choices
// ---------------------------------------------------------------------------
@(private)
candidate_index :: proc(w: ^Wizard, path: string) -> int {
	for item, i in w.thumbs.items { if item.path == path { return i } }
	return -1
}

// Start from what milk.json already names (files present in the runtime folder).
@(private)
wallpaper_preselect :: proc(w: ^Wizard) {
	resize(&w.wp_choice, len(w.areas))
	wp_dir := join_path({w.runtime_root, w.cfg.paths.wallpapers})
	for n, i in w.areas {
		w.wp_choice[i] = -1
		if ws, ok := w.cfg.workspaces[n]; ok && ws.wallpaper != "" {
			w.wp_choice[i] = candidate_index(w, join_path({wp_dir, ws.wallpaper}))
		}
	}
	same := true
	for v in w.wp_choice { if v != w.wp_choice[0] { same = false } }
	w.wp_per_area = !same && len(w.areas) > 1
	w.wp_single = len(w.wp_choice) > 0 ? w.wp_choice[0] : -1
}

@(private)
area_choice :: proc(w: ^Wizard, i: int) -> int {
	if !w.wp_per_area { return w.wp_single }
	if i < 0 || i >= len(w.wp_choice) { return -1 }
	return w.wp_choice[i]
}

// The picture behind the card: the area being edited, else area 1.
@(private)
backdrop_candidate :: proc(w: ^Wizard) -> int {
	if !w.wp_per_area { return w.wp_single }
	if w.page == .Wallpaper { return area_choice(w, w.wp_tab) }
	return area_choice(w, 0)
}

@(private)
wallpaper_set_mode :: proc(w: ^Wizard, per_area: bool) {
	if per_area == w.wp_per_area { return }
	if per_area {
		all_unset := true
		for v in w.wp_choice { if v >= 0 { all_unset = false } }
		if all_unset {
			for &v in w.wp_choice { v = w.wp_single }
		}
		w.wp_tab = 0
	} else if len(w.wp_choice) > 0 {
		w.wp_single = w.wp_choice[clamp(w.wp_tab, 0, len(w.wp_choice) - 1)]
	}
	w.wp_per_area = per_area
	w.base_dirty = true
	w.dirty = true
}

// A tile was clicked: -1 = no wallpaper. In per-area mode the next area is selected afterwards.
@(private)
wallpaper_pick :: proc(w: ^Wizard, index: int) {
	if w.wp_per_area && len(w.wp_choice) > 0 {
		w.wp_choice[w.wp_tab] = index
		if w.wp_tab < len(w.wp_choice) - 1 { w.wp_tab += 1 }
	} else {
		w.wp_single = index
	}
	w.base_dirty = true
	w.dirty = true
}
