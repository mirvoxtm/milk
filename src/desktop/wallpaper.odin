// Per-area wallpapers (Find-Wallpaper / Prepare-Wallpaper / Set-Wallpaper).
//
// The configured source is validated, staged atomically as
// WallpaperCache/AreaN.<ext> (so an image being edited or half-written never
// reaches the screen) and applied with feh, which also publishes the
// _XROOTPMAP_ID pixmap that the icon cells and the indicator copy from.
package desktop

import "core:fmt"
import "core:image"
import "core:image/bmp"
import "core:image/jpeg"
import "core:image/png"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"
import config "../config"
import tx "../tx"

Wallpaper_State :: struct {
	last_applied:       f64, // tx.now() when our last feh call returned
	feh_missing_logged: bool,
}

// FEH_TIMEOUT bounds how long a feh call may block the event loop.
@(private)
FEH_TIMEOUT :: 20.0

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

// Apply the wallpaper of area `index`; keeps the current one when nothing
// usable is configured. Returns true when feh set a new wallpaper.
@(private)
apply_wallpaper :: proc(d: ^Daemon, index: int) -> bool {
	source, found := wallpaper_source(d.cfg, d.runtime_root, index)
	cached: string
	mode := d.cfg.linux.wallpaper_mode
	if !found {
		// No wallpaper for this area: a plain background in the bar's colour.
		solid, ok := solid_background(d)
		if !ok { return false }
		log.debugf("Area %d: no wallpaper configured, using the bar colour", index)
		cached = solid
		mode = "tile"
	} else {
		prepared: bool
		cached, prepared = prepare_wallpaper(d, source, index)
		if !prepared { return false }
	}

	argv := []string{"feh", "--no-fehbg", fmt.tprintf("--bg-%s", mode), cached}
	res := run_sync(argv, FEH_TIMEOUT, false)
	d.wallpaper.last_applied = tx.now()
	if res.not_found {
		if !d.wallpaper.feh_missing_logged {
			d.wallpaper.feh_missing_logged = true
			log.error("feh is not installed; cannot apply the wallpaper")
		}
		return false
	}
	if !res.started {
		log.error("Could not run feh")
		return false
	}
	if res.timed_out {
		log.errorf("feh did not finish within %.0f s", FEH_TIMEOUT)
		return false
	}
	if res.exit_code != 0 {
		log.errorf("feh exited with %d: %s", res.exit_code, strings.trim_space(string(res.stderr)))
		return false
	}
	log.debugf("Area %d wallpaper applied: %s", index, cached)
	return true
}

// A small tile in the bar's background colour (WallpaperCache/Solid-RRGGBB.ppm).
@(private)
solid_background :: proc(d: ^Daemon) -> (string, bool) {
	cache_dir := join_path({d.runtime_root, d.cfg.paths.wallpaper_cache})
	if !ensure_dir(cache_dir) { return "", false }
	col := tx.color_from_hex(d.cfg.bar.theme.background, tx.rgb(0xF5, 0xEE, 0xE6))
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

// Stage the source as WallpaperCache/AreaN.<ext>; an unchanged source (per the
// stamp file) is reused without being read again.
@(private)
prepare_wallpaper :: proc(d: ^Daemon, source: string, index: int) -> (string, bool) {
	cache_dir := join_path({d.runtime_root, d.cfg.paths.wallpaper_cache})
	if !ensure_dir(cache_dir) { return "", false }
	ext := lower_ext(source)
	if ext == "" { ext = ".img" }
	target := join_path({cache_dir, fmt.tprintf("Area%d%s", index, ext)})
	stamp := join_path({cache_dir, fmt.tprintf("Area%d.stamp", index)})

	fi, serr := os.stat(source, context.temp_allocator)
	if serr != nil { return "", false }
	signature := fmt.tprintf("%s\n%d\n%d\n%s\n", source, time.time_to_unix_nano(fi.modification_time), fi.size, target)
	if old, err := os.read_entire_file(stamp, context.temp_allocator); err == nil && string(old) == signature && os.is_file(target) {
		return target, true
	}

	data, rerr := os.read_entire_file(source, context.allocator)
	if rerr != nil {
		log.warnf("Could not read wallpaper %s: %s", source, os.error_string(rerr))
		return "", false
	}
	defer delete(data)
	if i64(len(data)) != fi.size || !validate_image(ext, data) {
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
	if serr2 := os.write_entire_file(stamp, signature); serr2 != nil {
		log.debugf("Could not write %s: %s", stamp, os.error_string(serr2))
	}
	remove_stale_cache(cache_dir, index, target)
	return target, true
}

// Remove AreaN.* files left from a previously configured image of another type.
@(private)
remove_stale_cache :: proc(cache_dir: string, index: int, keep: string) {
	infos, err := os.read_all_directory_by_path(cache_dir, context.temp_allocator)
	if err != nil { return }
	prefix := fmt.tprintf("Area%d.", index)
	for fi in infos {
		name := os.base(fi.fullpath)
		if !strings.has_prefix(name, prefix) || strings.has_suffix(name, ".stamp") || strings.has_suffix(name, ".tmp") { continue }
		if fi.fullpath == keep || os.base(keep) == name { continue }
		os.remove(fi.fullpath)
	}
}

// Decode png/jpeg/bmp with core:image; other formats (webp, gif...) are
// accepted when non-empty, as feh/imlib2 decodes more than core:image.
@(private)
validate_image :: proc(ext: string, data: []byte) -> bool {
	if len(data) == 0 { return false }
	switch ext {
	case ".png":
		img, err := png.load_from_bytes(data, {}, context.allocator)
		defer if img != nil { png.destroy(img) }
		return err == nil && img != nil && img.width >= 2 && img.height >= 2
	case ".jpg", ".jpeg", ".jpe", ".jfif":
		img, err := jpeg.load_from_bytes(data, {}, context.allocator)
		defer if img != nil { jpeg.destroy(img) }
		if err == nil && img != nil { return img.width >= 2 && img.height >= 2 }
		if jerr, is_jpeg := err.(image.JPEG_Error); is_jpeg {
			#partial switch jerr {
			case .Unsupported_Frame_Type, .Unsupported_12_Bit_Depth, .Multiple_SOS_Markers, .Extra_Data_After_SOS:
				// Progressive/arithmetic/12-bit JPEGs are valid but beyond core:image.
				return jpeg_structure_ok(data)
			}
		}
		return false
	case ".bmp", ".dib":
		img, err := bmp.load_from_bytes(data, {}, context.allocator)
		defer if img != nil { bmp.destroy(img) }
		if err == nil && img != nil { return img.width >= 2 && img.height >= 2 }
		if _, is_bmp := err.(image.BMP_Error); is_bmp { return bmp_structure_ok(data) }
		return false
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
