// Window icons (_NET_WM_ICON) for title bars, the task list and the window
// switcher.
package tx

import xlib "vendor:x11/xlib"

// The icon of `win` scaled to size x size: the smallest image at least that
// large (else the largest), from the ARGB images of _NET_WM_ICON. False when
// the window has none.
window_icon :: proc(c: ^Connection, win: xlib.Window, size: i32, allocator := context.allocator) -> (Image, bool) {
	if size <= 0 { return {}, false }
	data := property_longs(c, win, "_NET_WM_ICON", ATOM_CARDINAL, context.temp_allocator)
	best_off := -1
	best_w, best_h: i32
	i := 0
	for i + 2 <= len(data) {
		w, h := i32(data[i] & 0xFFFFFFFF), i32(data[i + 1] & 0xFFFFFFFF)
		n := int(w) * int(h)
		if w <= 0 || h <= 0 || w > 1024 || h > 1024 || i + 2 + n > len(data) { break }
		better := false
		if best_off < 0 {
			better = true
		} else if best_w >= size {
			better = w >= size && w < best_w
		} else {
			better = w > best_w
		}
		if better {
			best_off, best_w, best_h = i + 2, w, h
		}
		i += 2 + n
	}
	if best_off < 0 { return {}, false }
	src := image_from_argb(data[best_off:best_off + int(best_w) * int(best_h)], best_w, best_h, context.temp_allocator)
	if best_w == size && best_h == size {
		return image_resize(src, size, size, allocator), true
	}
	// Keep the aspect ratio inside the size x size box, centred.
	scale := f32(size) / f32(max(best_w, best_h))
	dw, dh := max(i32(f32(best_w) * scale + 0.5), 1), max(i32(f32(best_h) * scale + 0.5), 1)
	scaled := image_resize(src, dw, dh, context.temp_allocator)
	out := image_make(size, size, allocator)
	ox, oy := (size - dw) / 2, (size - dh) / 2
	for y in 0 ..< dh {
		copy(out.rgba[(int(y + oy) * int(size) + int(ox)) * 4:][:int(dw) * 4], scaled.rgba[int(y) * int(dw) * 4:][:int(dw) * 4])
	}
	return out, true
}
