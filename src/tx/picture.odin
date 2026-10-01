// Pictures as Images: decoding a file (the formats of core:image), the round
// crop of a profile picture, and writing a PNG (stored deflate blocks: a
// valid, uncompressed PNG that needs no zlib).
package tx

import "core:bytes"
import "core:hash"
import "core:image"
import _ "core:image/bmp"
import _ "core:image/jpeg"
import _ "core:image/png"
import _ "core:image/qoi"
import _ "core:image/tga"
import "core:math"
import "core:os"

// Decode a picture file into straight RGBA8.
image_load :: proc(path: string, allocator := context.allocator) -> (out: Image, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) == 0 { return }
	img, lerr := image.load_from_bytes(data, {.alpha_add_if_missing}, context.temp_allocator)
	if lerr != nil || img == nil || img.width <= 0 || img.height <= 0 || img.channels != 4 { return }
	if img.depth != 8 && img.depth != 16 { return }
	n := img.width * img.height
	out = image_make(i32(img.width), i32(img.height), allocator)
	src := img.pixels.buf[:]
	if img.depth == 8 {
		if len(src) < n * 4 { delete(out.rgba, allocator); return {}, false }
		copy(out.rgba, src[:n * 4])
	} else {
		if len(src) < n * 8 { delete(out.rgba, allocator); return {}, false }
		for i in 0 ..< n * 4 { out.rgba[i] = src[2 * i + 1] } // native-endian u16: the high byte
	}
	return out, true
}

// The middle square of `src` (in a portrait, nearer the top, where faces
// are), scaled to `d` × `d`.
image_square :: proc(src: Image, d: i32, allocator := context.allocator) -> Image {
	side := min(src.w, src.h)
	x0, y0 := (src.w - side) / 2, (src.h - side) / 2
	if src.h > src.w { y0 = (src.h - side) / 3 }
	square := image_make(side, side, context.temp_allocator)
	for y in 0 ..< side {
		from := int((y0 + y) * src.w + x0) * 4
		copy(square.rgba[int(y * side) * 4:][:int(side) * 4], src.rgba[from:][:int(side) * 4])
	}
	return image_resize(square, d, d, allocator)
}

// The middle square of `src`, `d` pixels wide, outside a circle transparent
// (an antialiased edge): a profile picture.
image_circle :: proc(src: Image, d: i32, allocator := context.allocator) -> Image {
	out := image_square(src, d, allocator)
	r := f32(d) / 2
	for y in 0 ..< d {
		for x in 0 ..< d {
			dx, dy := f32(x) + 0.5 - r, f32(y) + 0.5 - r
			cover := clamp(r - math.sqrt(dx * dx + dy * dy) + 0.5, 0, 1)
			i := int(y * d + x) * 4 + 3
			out.rgba[i] = u8(f32(out.rgba[i]) * cover)
		}
	}
	return out
}

// A PNG of `img` (RGBA8). The deflate stream is made of stored blocks.
png_encode :: proc(img: Image, allocator := context.allocator) -> []u8 {
	buf: bytes.Buffer
	bytes.buffer_init_allocator(&buf, 0, int(img.w * img.h) * 4 + 1024, allocator)
	be32 :: proc(b: ^bytes.Buffer, v: u32) {
		x := [4]u8{u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)}
		bytes.buffer_write(b, x[:])
	}
	chunk :: proc(b: ^bytes.Buffer, kind: string, data: []u8) {
		be32(b, u32(len(data)))
		start := bytes.buffer_length(b)
		bytes.buffer_write_string(b, kind)
		bytes.buffer_write(b, data)
		be32(b, hash.crc32(bytes.buffer_to_bytes(b)[start:]))
	}
	bytes.buffer_write(&buf, []u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'})
	ihdr: [13]u8
	ihdr[0], ihdr[1], ihdr[2], ihdr[3] = u8(img.w >> 24), u8(img.w >> 16), u8(img.w >> 8), u8(img.w)
	ihdr[4], ihdr[5], ihdr[6], ihdr[7] = u8(img.h >> 24), u8(img.h >> 16), u8(img.h >> 8), u8(img.h)
	ihdr[8], ihdr[9] = 8, 6 // 8 bits per sample, RGBA
	chunk(&buf, "IHDR", ihdr[:])

	// Scanlines, each after its filter byte (0 = none).
	stride := int(img.w) * 4
	raw := make([]u8, (stride + 1) * int(img.h), context.temp_allocator)
	for y in 0 ..< int(img.h) {
		copy(raw[y * (stride + 1) + 1:][:stride], img.rgba[y * stride:][:stride])
	}
	z: bytes.Buffer
	bytes.buffer_init_allocator(&z, 0, len(raw) + len(raw) / 65535 * 5 + 16, context.temp_allocator)
	bytes.buffer_write(&z, []u8{0x78, 0x01})
	for at := 0; at < len(raw) || at == 0; {
		n := min(len(raw) - at, 65535)
		last := at + n >= len(raw)
		header := [5]u8{last ? 1 : 0, u8(n), u8(n >> 8), u8(~u16(n)), u8(~u16(n) >> 8)}
		bytes.buffer_write(&z, header[:])
		bytes.buffer_write(&z, raw[at:][:n])
		at += n
		if last { break }
	}
	be32(&z, hash.adler32(raw))
	chunk(&buf, "IDAT", bytes.buffer_to_bytes(&z))
	chunk(&buf, "IEND", nil)
	return bytes.buffer_to_bytes(&buf)
}
