// Per-area wallpapers (Find-Wallpaper / Prepare-Wallpaper / Set-Wallpaper).
//
// The configured source is checked to be a complete file and staged
// atomically as WallpaperCache/Wall-<hash>.<ext>, named after the source's
// path, size and time: an image being edited or half-written never reaches
// the screen, and areas showing the same picture share one copy. feh draws it
// and publishes the _XROOTPMAP_ID pixmap that the icon cells, the indicator,
// the bar and the compositor copy from.
//
// An area switch must never wait for a picture to be decoded (feh takes half a
// second on a 4K PNG), so:
//   - the wallpaper already on screen (same picture, mode and screen size) is
//     left alone;
//   - every wallpaper feh has drawn is kept as a screen-sized pixmap, and
//     showing it again only copies that pixmap to the root window, following
//     the convention feh and Esetroot use: a pixmap owned by a short-lived
//     connection kept with RetainPermanent, published as _XROOTPMAP_ID and
//     ESETROOT_PMAP_ID, the previous one freed with XKillClient;
//   - feh itself runs in the background; when it is done the picture is kept
//     and the icon cells copy it.
package desktop

import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

Wallpaper_State :: struct {
	last_applied:       f64, // tx.now() when our last root background landed
	feh_missing_logged: bool,
	shown:              string,      // heap: key of the wallpaper on screen, "" = unknown
	shown_pixmap:       xlib.Pixmap, // _XROOTPMAP_ID when it landed (someone else may replace it)
	drawn:              [dynamic]Drawn_Wallpaper, // least recently shown first
	feh:                Child,       // the running feh (its stderr)
	feh_key:            string,      // heap: what it draws
}

// A wallpaper feh drew, as a copy of the root pixmap (owned by our connection).
@(private)
Drawn_Wallpaper :: struct {
	key:    string, // heap
	pixmap: xlib.Pixmap,
	w, h:   i32,
}

// FEH_TIMEOUT bounds how long a feh call may take before it is given up.
@(private)
FEH_TIMEOUT :: 20.0

// Drawn wallpapers kept (each is a screen-sized pixmap in the X server):
// as many as fit in DRAWN_BUDGET bytes, at most DRAWN_MAX.
@(private)
DRAWN_MAX :: 12
@(private)
DRAWN_BUDGET :: 192 * 1024 * 1024

wallpaper_init :: proc(d: ^Daemon) {
	child_init(&d.wallpaper.feh)
	d.wallpaper.drawn = make([dynamic]Drawn_Wallpaper)
}

wallpaper_destroy :: proc(d: ^Daemon) {
	w := &d.wallpaper
	child_destroy(&w.feh)
	delete(w.feh_key)
	drawn_clear(d)
	delete(w.drawn)
	delete(w.shown)
}

// The source image configured for area `index`, when it exists and is not
// empty (Find-Wallpaper). Used by `milk test` as well.
wallpaper_source :: proc(cfg: ^config.Config, runtime_root: string, index: int, allocator := context.temp_allocator) -> (string, bool) {
	ws, known := config.workspace(cfg, index)
	if !known || ws.wallpaper == "" { return "", false }
	path := join_path({runtime_root, cfg.paths.wallpapers, ws.wallpaper}, context.temp_allocator)
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil || fi.type != .Regular || fi.size <= 0 { return "", false }
	return strings.clone(path, allocator), true
}

// What area `index` wants on the root window: its picture (or a plain
// background in the bar's colour) in the configured mode at the screen's size.
@(private)
Wallpaper_Target :: struct {
	key:    string,        // temp: identifies the drawn result (picture, its stamp, mode, screen size)
	source: string,        // temp: the picture, "" = plain background
	fi:     os.File_Info,
	mode:   string,
	solid:  tx.Color,
}

@(private)
wallpaper_target :: proc(d: ^Daemon, index: int) -> (t: Wallpaper_Target, ok: bool) {
	screen := tx.screen_rect(d.c)
	t.mode = d.cfg.linux.wallpaper_mode
	source, found := wallpaper_source(d.cfg, d.runtime_root, index)
	if found {
		fi, err := os.stat(source, context.temp_allocator)
		if err != nil { return }
		t.source, t.fi = source, fi
		t.key = fmt.tprintf("%s|%d|%d|%s|%dx%d", source, time.time_to_unix_nano(fi.modification_time), fi.size, t.mode, screen.w, screen.h)
	} else {
		// No wallpaper for this area: a plain background in the bar's colour.
		t.solid = solid_color(d)
		t.mode = "tile"
		t.key = fmt.tprintf("solid|%02X%02X%02X|%dx%d", t.solid.r, t.solid.g, t.solid.b, screen.w, screen.h)
	}
	return t, true
}

// Show the wallpaper of area `index`; keeps the current one when nothing
// usable is configured. Returns at once: feh, when it is needed, runs in the
// background (wallpaper_feh_done).
@(private)
apply_wallpaper :: proc(d: ^Daemon, index: int) {
	w := &d.wallpaper
	target, ok := wallpaper_target(d, index)
	if !ok { return }
	key := target.key

	if key == w.shown && w.shown_pixmap != 0 {
		if pm, has := tx.get_pixmap_id(d.c, d.c.root, "_XROOTPMAP_ID"); has && pm == w.shown_pixmap {
			// Already on screen; a slower request for another area must not land over it.
			if child_running(&w.feh) && w.feh_key != key { feh_cancel(d) }
			return
		}
	}
	if child_running(&w.feh) && w.feh_key == key { return } // being drawn
	if i := drawn_find(w, key); i >= 0 {
		feh_cancel(d)
		if show_drawn(d, i) {
			log.debugf("Area %d: wallpaper shown from memory", index)
			return
		}
	}

	file: string
	if target.source != "" {
		staged, staged_ok := stage_wallpaper(d, target.source, target.fi)
		if !staged_ok { return }
		file = staged
	} else {
		solid, solid_ok := solid_background(d)
		if !solid_ok { return }
		file = solid
	}
	feh_start(d, key, file, target.mode)
}

@(private)
solid_color :: proc(d: ^Daemon) -> tx.Color {
	return tx.color_from_hex(d.cfg.bar.theme.background, tx.rgb(0xF5, 0xEE, 0xE6))
}

// A small tile in the bar's background colour (WallpaperCache/Solid-RRGGBB.ppm).
@(private)
solid_background :: proc(d: ^Daemon) -> (string, bool) {
	cache_dir := join_path({d.runtime_root, d.cfg.paths.wallpaper_cache})
	if !ensure_dir(cache_dir) { return "", false }
	col := solid_color(d)
	path := join_path({cache_dir, fmt.tprintf("Solid-%02X%02X%02X.ppm", col.r, col.g, col.b)})
	if os.is_file(path) { return path, true }
	SIDE :: 16
	data := make([dynamic]u8, context.temp_allocator)
	append(&data, ..transmute([]u8)fmt.tprintf("P6\n%d %d\n255\n", SIDE, SIDE))
	for _ in 0 ..< SIDE * SIDE { append(&data, col.r, col.g, col.b) }
	if err := os.write_entire_file(path, data[:]); err != nil {
		log.warnf("Could not write %s: %v", path, err)
		return "", false
	}
	return path, true
}

// WallpaperCache/Wall-<hash of path, time and size>.<ext>
@(private)
staged_name :: proc(source: string, fi: os.File_Info) -> string {
	ext := lower_ext(source)
	if ext == "" { ext = ".img" }
	signature := fmt.tprintf("%s|%d|%d", source, time.time_to_unix_nano(fi.modification_time), fi.size)
	return fmt.tprintf("Wall-%016x%s", hash.fnv64a(transmute([]u8)signature), ext)
}

// Stage the source in the cache folder; a copy made earlier is reused without
// reading the source again.
@(private)
stage_wallpaper :: proc(d: ^Daemon, source: string, fi: os.File_Info) -> (string, bool) {
	cache_dir := join_path({d.runtime_root, d.cfg.paths.wallpaper_cache})
	if !ensure_dir(cache_dir) { return "", false }
	target := join_path({cache_dir, staged_name(source, fi)})
	if tfi, err := os.stat(target, context.temp_allocator); err == nil && tfi.size == fi.size { return target, true }

	data, rerr := os.read_entire_file(source, context.allocator)
	if rerr != nil {
		log.warnf("Could not read wallpaper %s: %s", source, os.error_string(rerr))
		return "", false
	}
	defer delete(data)
	if i64(len(data)) != fi.size || !image_complete(lower_ext(source), data) {
		// Still being written or not an image (yet): leave the current wallpaper alone.
		log.warnf("Wallpaper %s is not a complete image; keeping the current wallpaper", source)
		return "", false
	}
	temporary := strings.concatenate({target, ".tmp"}, context.temp_allocator)
	if werr := os.write_entire_file(temporary, data); werr != nil {
		log.warnf("Could not write %s: %s", temporary, os.error_string(werr))
		os.remove(temporary)
		return "", false
	}
	if merr := os.rename(temporary, target); merr != nil {
		log.warnf("Could not move %s into place: %s", temporary, os.error_string(merr))
		os.remove(temporary)
		return "", false
	}
	return target, true
}

// Remove staged copies no area uses any more, and the per-area copies of
// earlier versions (AreaN.<ext>, recognised by the AreaN.stamp written with
// them). Never in the wallpapers folder itself, where AreaN.png may be a
// picture of the user's.
wallpaper_prune :: proc(d: ^Daemon) {
	cache_dir := join_path({d.runtime_root, d.cfg.paths.wallpaper_cache})
	if cache_dir == join_path({d.runtime_root, d.cfg.paths.wallpapers}) { return }
	infos, err := os.read_all_directory_by_path(cache_dir, context.temp_allocator)
	if err != nil { return }
	stamped := make(map[string]bool, allocator = context.temp_allocator) // "AreaN."
	for fi in infos {
		name := os.base(fi.fullpath)
		if strings.has_prefix(name, "Area") && strings.has_suffix(name, ".stamp") { stamped[name[:len(name) - len("stamp")]] = true }
	}
	wanted := make(map[string]bool, allocator = context.temp_allocator)
	for index, _ in d.cfg.workspaces {
		source, found := wallpaper_source(d.cfg, d.runtime_root, index)
		if !found { continue }
		if fi, serr := os.stat(source, context.temp_allocator); serr == nil { wanted[staged_name(source, fi)] = true }
	}
	for fi in infos {
		name := os.base(fi.fullpath)
		dot := strings.index_byte(name, '.')
		legacy := strings.has_prefix(name, "Area") && dot > 4 && name[:dot + 1] in stamped
		staged := strings.has_prefix(name, "Wall-")
		if (legacy || staged) && !(name in wanted) { os.remove(fi.fullpath) }
	}
}

// Draw the wallpaper with feh in the background.
@(private)
feh_start :: proc(d: ^Daemon, key, file, mode: string) {
	w := &d.wallpaper
	exe, found := find_executable("feh")
	if !found {
		if !w.feh_missing_logged {
			w.feh_missing_logged = true
			log.error("feh is not installed; cannot apply the wallpaper")
		}
		return
	}
	argv := []string{exe, "--no-fehbg", fmt.tprintf("--bg-%s", mode), file}
	if !child_start(&w.feh, argv, .Stderr, FEH_TIMEOUT) {
		log.error("Could not run feh")
		return
	}
	delete(w.feh_key)
	w.feh_key = strings.clone(key)
	log.debugf("feh: drawing %s (%s)", file, mode)
}

// feh's stderr is readable (or it may have exited: wallpaper_tick).
@(private)
wallpaper_feh_read :: proc(d: ^Daemon) {
	if done, ok := child_read(&d.wallpaper.feh); done { wallpaper_feh_done(d, ok) }
}

@(private)
wallpaper_feh_done :: proc(d: ^Daemon, ok: bool) {
	w := &d.wallpaper
	key := w.feh_key
	w.feh_key = ""
	defer delete(key)
	if !ok {
		log.errorf("feh could not draw the wallpaper: %s", strings.trim_space(string(w.feh.out[:])))
		return
	}
	wallpaper_landed(d, key)
	drawn_keep(d, key)
	// The cells painted meanwhile copied the previous picture.
	layer_refresh_backgrounds(d)
	indicator_refresh(d)
	tx.flush(d.c)
}

// Stop a feh call whose picture is no longer wanted.
@(private)
feh_cancel :: proc(d: ^Daemon) {
	w := &d.wallpaper
	if !child_running(&w.feh) { return }
	child_kill(&w.feh)
	delete(w.feh_key)
	w.feh_key = ""
}

// Our wallpaper `key` is now the root background.
@(private)
wallpaper_landed :: proc(d: ^Daemon, key: string) {
	w := &d.wallpaper
	pm, _ := tx.get_pixmap_id(d.c, d.c.root, "_XROOTPMAP_ID")
	w.shown_pixmap = pm
	if w.shown != key {
		delete(w.shown)
		w.shown = strings.clone(key)
	}
	w.last_applied = tx.now()
}

@(private)
wallpaper_tick :: proc(d: ^Daemon, now: f64) {
	w := &d.wallpaper
	if !child_running(&w.feh) { return }
	if w.feh.fd < 0 {
		// Its output ended before it exited.
		if done, ok := child_poll(&w.feh); done { wallpaper_feh_done(d, ok) }
		return
	}
	if now < w.feh.deadline { return }
	log.errorf("feh did not finish within %.0f s", FEH_TIMEOUT)
	feh_cancel(d)
}

@(private)
wallpaper_next_timeout :: proc(d: ^Daemon, now: f64) -> f64 {
	feh := &d.wallpaper.feh
	if !child_running(feh) { return -1 }
	if feh.fd < 0 { return CHILD_REAP_POLL }
	return max(feh.deadline - now, 0)
}

// Whether a root background change now is ours (feh running or just landed).
@(private)
wallpaper_own_change :: proc(d: ^Daemon) -> bool {
	return child_running(&d.wallpaper.feh) || tx.now() - d.wallpaper.last_applied < OWN_WALLPAPER_WINDOW
}

@(private)
drawn_find :: proc(w: ^Wallpaper_State, key: string) -> int {
	for &e, i in w.drawn { if e.key == key { return i } }
	return -1
}

// Keep a copy of the root pixmap feh just made for `key`.
@(private)
drawn_keep :: proc(d: ^Daemon, key: string) {
	w := &d.wallpaper
	if drawn_find(w, key) >= 0 { return }
	root_pm, ok := tx.root_pixmap(d.c)
	if !ok { return }
	pw, ph, sized := tx.drawable_size(d.c, xlib.Drawable(root_pm))
	if !sized { return }
	pm := xlib.CreatePixmap(d.c.dpy, xlib.Drawable(d.c.root), u32(pw), u32(ph), u32(d.c.depth))
	gc := xlib.CreateGC(d.c.dpy, xlib.Drawable(pm), {}, nil)
	xlib.CopyArea(d.c.dpy, xlib.Drawable(root_pm), xlib.Drawable(pm), gc, 0, 0, u32(pw), u32(ph), 0, 0)
	xlib.FreeGC(d.c.dpy, gc)
	drawn_add(d, key, pm, pw, ph)
}

// Keep a drawn wallpaper (the pixmap now belongs to the list); the least
// recently shown one goes when the list is full, never the one on screen.
@(private)
drawn_add :: proc(d: ^Daemon, key: string, pm: xlib.Pixmap, pw, ph: i32) {
	w := &d.wallpaper
	for len(w.drawn) >= drawn_capacity(d) {
		victim := -1
		for e, i in w.drawn {
			if e.key != w.shown { victim = i; break }
		}
		if victim < 0 { break }
		old := w.drawn[victim]
		xlib.FreePixmap(d.c.dpy, old.pixmap)
		delete(old.key)
		ordered_remove(&w.drawn, victim)
	}
	append(&w.drawn, Drawn_Wallpaper{key = strings.clone(key), pixmap = pm, w = pw, h = ph})
}

// How many screen-sized pixmaps fit in DRAWN_BUDGET (at least 3, at most DRAWN_MAX).
@(private)
drawn_capacity :: proc(d: ^Daemon) -> int {
	screen := tx.screen_rect(d.c)
	bytes := max(int(screen.w) * int(screen.h) * 4, 1)
	return clamp(DRAWN_BUDGET / bytes, 3, DRAWN_MAX)
}

// The wallpaper of area `index` as milk keeps it (a screen-sized pixmap owned
// by milk's connection, valid until the next main-loop iteration), for the
// overview's cards; ok = false when it has not been drawn yet.
area_wallpaper :: proc(d: ^Daemon, index: int) -> (pm: xlib.Pixmap, w, h: i32, ok: bool) {
	if d == nil { return }
	target, known := wallpaper_target(d, index)
	if !known { return }
	if i := drawn_find(&d.wallpaper, target.key); i >= 0 {
		e := d.wallpaper.drawn[i]
		return e.pixmap, e.w, e.h, true
	}
	if target.key == d.wallpaper.shown {
		if root, has := tx.root_pixmap(d.c); has {
			w, h, ok = tx.drawable_size(d.c, xlib.Drawable(root))
			return root, w, h, ok
		}
	}
	return
}

// Forget the drawn wallpapers (the screen size changed).
wallpaper_forget_drawn :: proc(d: ^Daemon) {
	preload_reset(d)
	drawn_clear(d)
	delete(d.wallpaper.shown)
	d.wallpaper.shown = ""
}

@(private)
drawn_clear :: proc(d: ^Daemon) {
	w := &d.wallpaper
	for e in w.drawn {
		xlib.FreePixmap(d.c.dpy, e.pixmap)
		delete(e.key)
	}
	clear(&w.drawn)
}

// Put drawn wallpaper `i` on the root window the way feh does (see the top of
// this file); the X server has done it by the time this returns.
@(private)
show_drawn :: proc(d: ^Daemon, i: int) -> bool {
	w := &d.wallpaper
	e := w.drawn[i]
	tmp, connected := tx.connect(xlib.DisplayString(d.c.dpy))
	if !connected { return false }
	dpy := tmp.dpy
	root := tmp.root
	pm := xlib.CreatePixmap(dpy, xlib.Drawable(root), u32(e.w), u32(e.h), u32(tmp.depth))
	gc := xlib.CreateGC(dpy, xlib.Drawable(pm), {}, nil)
	xlib.CopyArea(dpy, xlib.Drawable(e.pixmap), xlib.Drawable(pm), gc, 0, 0, u32(e.w), u32(e.h), 0, 0)
	xlib.FreeGC(dpy, gc)
	// The previous wallpaper's owner, kept alive only for it, is let go
	// (never one of our own drawn copies).
	old_root, has_root := tx.get_pixmap_id(tmp, root, "_XROOTPMAP_ID")
	old_set, has_set := tx.get_pixmap_id(tmp, root, "ESETROOT_PMAP_ID")
	if has_root && has_set && old_root == old_set && !drawn_owns(w, old_set) {
		if _, _, exists := tx.drawable_size(tmp, xlib.Drawable(old_set)); exists { xlib.KillClient(dpy, xlib.XID(old_set)) }
	}
	ids := [1]xlib.Pixmap{pm}
	for name in ([]string{"_XROOTPMAP_ID", "ESETROOT_PMAP_ID"}) {
		xlib.ChangeProperty(dpy, root, tx.atom(tmp, name), tx.ATOM_PIXMAP, 32, tx.PROP_MODE_REPLACE, &ids[0], 1)
	}
	xlib.SetWindowBackgroundPixmap(dpy, root, pm)
	xlib.ClearWindow(dpy, root)
	xlib.SetCloseDownMode(dpy, .RetainPermanent)
	xlib.Sync(dpy, false)
	tx.disconnect(tmp)

	wallpaper_landed(d, e.key)
	// Most recently shown last.
	moved := w.drawn[i]
	ordered_remove(&w.drawn, i)
	append(&w.drawn, moved)
	return true
}

@(private)
drawn_owns :: proc(w: ^Wallpaper_State, pm: xlib.Pixmap) -> bool {
	for e in w.drawn { if e.pixmap == pm { return true } }
	return false
}

// Is the image file complete? Only the structure is looked at (decoding a 4K
// picture would take longer than showing it): PNG ends with its IEND chunk,
// JPEG has an end-of-image marker after its scan, BMP is as long as its
// header says; other formats (webp, gif...) are accepted when not empty, as
// feh/imlib2 decodes more than we check.
@(private)
image_complete :: proc(ext: string, data: []byte) -> bool {
	if len(data) == 0 { return false }
	switch ext {
	case ".png":
		SIGNATURE :: "\x89PNG\r\n\x1a\n"
		if len(data) < 8 + 25 + 12 || string(data[:8]) != SIGNATURE { return false }
		tail := data[max(len(data) - 64, 8):]
		return strings.contains(string(tail), "IEND")
	case ".jpg", ".jpeg", ".jpe", ".jfif":
		return jpeg_structure_ok(data)
	case ".bmp", ".dib":
		return bmp_structure_ok(data)
	}
	return true
}

// JPEG sanity check for variants the decoder does not support: a frame header
// with plausible dimensions and an EOI marker after the first scan (a
// truncated file has none).
@(private)
jpeg_structure_ok :: proc(data: []byte) -> bool {
	if len(data) < 4 || data[0] != 0xFF || data[1] != 0xD8 { return false }
	i := 2
	width, height := 0, 0
	for i + 4 <= len(data) {
		if data[i] != 0xFF { return false }
		marker := data[i + 1]
		if marker == 0xFF { i += 1; continue } // fill byte
		if marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01 { i += 2; continue }
		length := int(data[i + 2]) << 8 | int(data[i + 3])
		if length < 2 || i + 2 + length > len(data) { return false }
		switch marker {
		case 0xC0 ..= 0xC3, 0xC5 ..= 0xC7, 0xC9 ..= 0xCB, 0xCD ..= 0xCF:
			if length >= 7 {
				height = int(data[i + 5]) << 8 | int(data[i + 6])
				width = int(data[i + 7]) << 8 | int(data[i + 8])
			}
		case 0xDA: // start of scan: entropy-coded data follows, look for EOI
			if width < 2 || height < 2 { return false }
			for j := i + 2 + length; j + 1 < len(data); j += 1 {
				if data[j] == 0xFF && data[j + 1] == 0xD9 { return true }
			}
			return false
		}
		i += 2 + length
	}
	return false
}

// BMP sanity check for variants the decoder does not support.
@(private)
bmp_structure_ok :: proc(data: []byte) -> bool {
	if len(data) < 26 || data[0] != 'B' || data[1] != 'M' { return false }
	le32 :: proc(b: []byte) -> i32 { return i32(u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24) }
	declared := le32(data[2:6])
	if declared > 0 && int(declared) > len(data) { return false } // truncated
	header_size := le32(data[14:18])
	if header_size == 12 { return true } // OS/2 core header: 16-bit sizes, accept
	width, height := le32(data[18:22]), abs(le32(data[22:26]))
	return width >= 2 && height >= 2
}
