// Small helpers shared by the locker and the idle manager: paths, clock and
// date texts, the lock selection and the blurred wallpaper.
package lock

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:time"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

join_path :: proc(dir, name: string, allocator := context.temp_allocator) -> string {
	if strings.has_suffix(dir, "/") { return strings.concatenate({dir, name}, allocator) }
	return strings.concatenate({dir, "/", name}, allocator)
}

// The selection a running locker owns (one locker per screen, whoever started it).
lock_selection :: proc(c: ^tx.Connection) -> xlib.Atom {
	return tx.atom(c, fmt.tprintf("_MILK_LOCKER_S%d", c.screen))
}

// Whether some locker (milk's or one started from a terminal) holds the screen.
locker_running :: proc(c: ^tx.Connection) -> bool {
	return xlib.GetSelectionOwner(c.dpy, lock_selection(c)) != 0
}

sleep_seconds :: proc(seconds: f64) {
	time.sleep(time.Duration(seconds * f64(time.Second)))
}

@(private)
local_time :: proc() -> (tm: posix.tm, unix_nanos: i64) {
	unix_nanos = time.to_unix_nanoseconds(time.now())
	t := posix.time_t(unix_nanos / 1_000_000_000)
	posix.localtime_r(&t, &tm)
	return
}

// The bar's strftime subset (%H %I %M %S %p %a %A %d %e %b %B %m %y %Y %%).
@(private)
format_clock :: proc(format: string, tm: posix.tm, lang: config.Language, allocator := context.temp_allocator) -> string {
	wday := clamp(int(tm.tm_wday), 0, 6)
	mon := clamp(int(tm.tm_mon), 0, 11)
	sb := strings.builder_make(allocator)
	for i := 0; i < len(format); i += 1 {
		ch := format[i]
		if ch != '%' || i + 1 >= len(format) {
			strings.write_byte(&sb, ch)
			continue
		}
		i += 1
		switch format[i] {
		case 'a': strings.write_string(&sb, config.WEEKDAYS[lang][wday])
		case 'A': strings.write_string(&sb, config.WEEKDAYS_FULL[lang][wday])
		case 'b', 'h': strings.write_string(&sb, config.MONTHS[lang][mon])
		case 'B': strings.write_string(&sb, config.MONTHS_FULL[lang][mon])
		case 'd': fmt.sbprintf(&sb, "%02d", tm.tm_mday)
		case 'e': fmt.sbprintf(&sb, "%2d", tm.tm_mday)
		case 'm': fmt.sbprintf(&sb, "%02d", tm.tm_mon + 1)
		case 'y': fmt.sbprintf(&sb, "%02d", (tm.tm_year + 1900) % 100)
		case 'Y': fmt.sbprintf(&sb, "%d", tm.tm_year + 1900)
		case 'H': fmt.sbprintf(&sb, "%02d", tm.tm_hour)
		case 'I': fmt.sbprintf(&sb, "%02d", (tm.tm_hour + 11) % 12 + 1)
		case 'M': fmt.sbprintf(&sb, "%02d", tm.tm_min)
		case 'S': fmt.sbprintf(&sb, "%02d", tm.tm_sec)
		case 'p': strings.write_string(&sb, tm.tm_hour < 12 ? "AM" : "PM")
		case '%': strings.write_byte(&sb, '%')
		case:
			strings.write_byte(&sb, '%')
			strings.write_byte(&sb, format[i])
		}
	}
	return strings.to_string(sb)
}

// "quarta-feira, 1 de outubro" / "Wednesday, October 1" / "miércoles, 1 de octubre".
@(private)
long_date :: proc(tm: posix.tm, lang: config.Language, allocator := context.temp_allocator) -> string {
	wday := clamp(int(tm.tm_wday), 0, 6)
	mon := clamp(int(tm.tm_mon), 0, 11)
	if lang == .English {
		return fmt.aprintf("%s, %s %d", config.WEEKDAYS_FULL[lang][wday], config.MONTHS_FULL[lang][mon], tm.tm_mday, allocator = allocator)
	}
	return fmt.aprintf("%s, %d de %s", config.WEEKDAYS_FULL[lang][wday], tm.tm_mday, config.MONTHS_FULL[lang][mon], allocator = allocator)
}

// ---------------------------------------------------------------------------
// The lock screen background: the wallpaper, blurred and darkened
// ---------------------------------------------------------------------------

// Blur `src` strongly and cheaply: shrink it to about 1/scale (box filter),
// blur the small copy three times (≈ a gaussian), then scale it back up
// bilinearly while multiplying by `darken` (0..1). `src` is replaced.
@(private)
blur_darken :: proc(src: ^tx.Canvas, darken: f32) {
	w, h := src.w, src.h
	if w < 4 || h < 4 { return }
	scale := max(i32(1), w / 320)
	sw := max(w / scale, 2)
	sh := max(h / scale, 2)
	small := make([]f32, int(sw * sh * 3))
	defer delete(small)
	for y in 0 ..< sh {
		for x in 0 ..< sw {
			r, g, b: f32
			n: f32
			for yy in y * scale ..< min((y + 1) * scale, h) {
				row := int(yy) * int(w)
				for xx in x * scale ..< min((x + 1) * scale, w) {
					p := src.px[row + int(xx)]
					r += f32((p >> 16) & 0xFF)
					g += f32((p >> 8) & 0xFF)
					b += f32(p & 0xFF)
					n += 1
				}
			}
			o := int(y * sw + x) * 3
			if n > 0 {
				small[o] = r / n
				small[o + 1] = g / n
				small[o + 2] = b / n
			}
		}
	}
	tmp := make([]f32, len(small))
	defer delete(tmp)
	radius := i32(4)
	for _ in 0 ..< 3 {
		box_blur(small, tmp, sw, sh, radius, true)
		box_blur(tmp, small, sw, sh, radius, false)
	}
	// Upscale (bilinear, sampling at pixel centres) and darken.
	fx := f32(sw) / f32(w)
	fy := f32(sh) / f32(h)
	for y in 0 ..< h {
		sy := clamp((f32(y) + 0.5) * fy - 0.5, 0, f32(sh - 1))
		y0 := i32(sy)
		y1 := min(y0 + 1, sh - 1)
		ty := sy - f32(y0)
		row := int(y) * int(w)
		for x in 0 ..< w {
			sx := clamp((f32(x) + 0.5) * fx - 0.5, 0, f32(sw - 1))
			x0 := i32(sx)
			x1 := min(x0 + 1, sw - 1)
			tx_ := sx - f32(x0)
			out: [3]f32
			for ch in 0 ..< 3 {
				a := small[int(y0 * sw + x0) * 3 + ch]
				b := small[int(y0 * sw + x1) * 3 + ch]
				c := small[int(y1 * sw + x0) * 3 + ch]
				d := small[int(y1 * sw + x1) * 3 + ch]
				top := a + (b - a) * tx_
				bottom := c + (d - c) * tx_
				out[ch] = clamp((top + (bottom - top) * ty) * darken, 0, 255)
			}
			src.px[row + int(x)] = u32(out[0]) << 16 | u32(out[1]) << 8 | u32(out[2])
		}
	}
}

// One horizontal (or vertical) box-blur pass over an RGB float image.
@(private)
box_blur :: proc(src, dst: []f32, w, h, radius: i32, horizontal: bool) {
	n := horizontal ? w : h
	lines := horizontal ? h : w
	for line in 0 ..< lines {
		index :: proc(line, i, w: i32, horizontal: bool) -> int {
			return horizontal ? int(line * w + i) * 3 : int(i * w + line) * 3
		}
		sum: [3]f32
		count: f32
		// Window [i - radius, i + radius] clamped to the line.
		for i in 0 ..< min(radius + 1, n) {
			o := index(line, i, w, horizontal)
			for ch in 0 ..< 3 { sum[ch] += src[o + ch] }
			count += 1
		}
		for i in 0 ..< n {
			o := index(line, i, w, horizontal)
			for ch in 0 ..< 3 { dst[o + ch] = sum[ch] / count }
			add := i + radius + 1
			if add < n {
				ao := index(line, add, w, horizontal)
				for ch in 0 ..< 3 { sum[ch] += src[ao + ch] }
				count += 1
			}
			drop := i - radius
			if drop >= 0 {
				do_ := index(line, drop, w, horizontal)
				for ch in 0 ..< 3 { sum[ch] -= src[do_ + ch] }
				count -= 1
			}
		}
	}
}

// The background when there is no wallpaper: a dark gradient of the theme.
@(private)
fill_fallback :: proc(cv: ^tx.Canvas, top, bottom: tx.Color) {
	for y in 0 ..< cv.h {
		t := f32(y) / f32(max(cv.h - 1, 1))
		col := tx.color_mix(top, bottom, t)
		tx.canvas_fill_rect(cv, {0, y, cv.w, 1}, col)
	}
}
