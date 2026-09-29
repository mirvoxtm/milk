// The history: adding entries (deduplicated, capped), removing them, and
// persisting them under <runtime>/Clipboard (index.json + one file per entry).
// Also image decoding (core:image) and a small PNG encoder (zlib).
package clip

import "core:bytes"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:image"
import "core:image/bmp"
import "core:image/jpeg"
import "core:image/png"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import tx "../tx"

@(private) INDEX_NAME :: "index.json"
@(private) FILE_PERMS :: os.Permissions{.Read_User, .Write_User}
@(private) DIR_PERMS  :: os.Permissions{.Read_User, .Write_User, .Execute_User}

// ---------------------------------------------------------------------------
// Entries
// ---------------------------------------------------------------------------
@(private)
item_hash :: proc(kind: Kind, data: []u8) -> u64 {
	return hash.fnv64a(data, 0xcbf29ce484222325 + u64(kind))
}

@(private)
item_clear_preview :: proc(it: ^Item) {
	for line in it.preview { delete(line) }
	delete(it.preview)
	it.preview = nil
}

@(private)
item_free :: proc(it: ^Item) {
	if it == nil { return }
	delete(it.data)
	delete(it.mime)
	tx.image_destroy(&it.thumb)
	item_clear_preview(it)
	free(it)
}

// Put an entry at the top. `data` is copied. An identical entry is moved to the top instead.
@(private)
add_item :: proc(cb: ^Clipboard, kind: Kind, mime: string, data: []u8, w, h: i32) -> ^Item {
	hv := item_hash(kind, data)
	for it, i in cb.items {
		if it.kind == kind && it.hash == hv && bytes.equal(it.data, data) {
			ordered_remove(&cb.items, i)
			inject_at(&cb.items, 0, it)
			cb.current = it.id
			schedule_save(cb)
			panel_changed(cb)
			return it
		}
	}
	it := new(Item)
	it.id = cb.next_id
	cb.next_id += 1
	it.kind = kind
	it.mime = strings.clone(mime)
	it.data = slice.clone(data)
	it.hash = hv
	it.w, it.h = w, h
	inject_at(&cb.items, 0, it)
	cb.current = it.id
	enforce_cap(cb)
	schedule_save(cb)
	panel_changed(cb)
	return it
}

@(private)
add_text :: proc(cb: ^Clipboard, text: string) {
	add_item(cb, .Text, "text/plain;charset=utf-8", transmute([]u8)text, 0, 0)
	log.debugf("Clipboard: recorded %d bytes of text", len(text))
}

@(private)
add_image :: proc(cb: ^Clipboard, mime: string, data: []u8) {
	img, ok := decode_image(mime, data)
	if !ok {
		log.infof("Clipboard: could not decode the copied %s; not recording it", mime)
		return
	}
	defer tx.image_destroy(&img)
	stored_mime := mime
	stored := data
	if mime == "image/bmp" {
		// BMP is uncompressed: keep it as PNG.
		if encoded := png_encode(img, context.temp_allocator); encoded != nil {
			stored = encoded
			stored_mime = "image/png"
		}
	}
	it := add_item(cb, .Image, stored_mime, stored, img.w, img.h)
	if it.thumb_state == .None { make_thumb(cb, it, img) }
	log.debugf("Clipboard: recorded a %dx%d picture (%s, %d bytes)", img.w, img.h, stored_mime, len(stored))
}

// Drop the oldest unpinned entries beyond clipboard.maxItems.
@(private)
enforce_cap :: proc(cb: ^Clipboard) -> (changed: bool) {
	limit := max(cb.cfg.clipboard.max_items, 1)
	for i := len(cb.items) - 1; i >= 0 && len(cb.items) > limit; i -= 1 {
		if cb.items[i].pinned { continue }
		item_free(cb.items[i])
		ordered_remove(&cb.items, i)
		changed = true
	}
	return
}

@(private)
remove_item :: proc(cb: ^Clipboard, index: int) {
	if index < 0 || index >= len(cb.items) { return }
	it := cb.items[index]
	if it.id == cb.current && !cb.owned.active { cb.current = 0 }
	item_free(it)
	ordered_remove(&cb.items, index)
	schedule_save(cb)
}

// "Clear all": everything except pinned entries.
@(private)
clear_unpinned :: proc(cb: ^Clipboard) {
	for i := len(cb.items) - 1; i >= 0; i -= 1 {
		if !cb.items[i].pinned { remove_item(cb, i) }
	}
}

@(private)
move_to_top :: proc(cb: ^Clipboard, index: int) {
	if index <= 0 || index >= len(cb.items) { return }
	it := cb.items[index]
	ordered_remove(&cb.items, index)
	inject_at(&cb.items, 0, it)
	schedule_save(cb)
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------
@(private)
Index_Entry :: struct {
	id:     u64,
	kind:   string, // text | image
	mime:   string,
	pinned: bool,
	w:      i32,
	h:      i32,
}

@(private)
Index_File :: struct {
	version: int,
	items:   []Index_Entry,
}

@(private)
item_file_name :: proc(id: u64, mime: string, allocator := context.temp_allocator) -> string {
	ext := "txt"
	switch mime {
	case "image/png":  ext = "png"
	case "image/jpeg": ext = "jpg"
	case "image/bmp":  ext = "bmp"
	}
	return fmt.aprintf("%d.%s", id, ext, allocator = allocator)
}

@(private)
join_path :: proc(parts: []string) -> string {
	s, _ := filepath.join(parts, context.temp_allocator)
	return s
}

@(private)
save_history :: proc(cb: ^Clipboard) {
	cb.save_due = -1
	if !cb.cfg.clipboard.persist { return }
	if !os.is_directory(cb.dir) {
		if err := os.make_directory_all(cb.dir, DIR_PERMS); err != nil && err != .Exist {
			log.warnf("Clipboard: cannot create %s: %v", cb.dir, err)
			return
		}
	}
	entries := make([dynamic]Index_Entry, context.temp_allocator)
	keep := make(map[string]bool, context.temp_allocator)
	keep[INDEX_NAME] = true
	for it in cb.items {
		name := item_file_name(it.id, it.mime)
		if !it.saved {
			if err := os.write_entire_file(join_path({cb.dir, name}), it.data, FILE_PERMS); err != nil {
				log.warnf("Clipboard: cannot write %s: %v", name, err)
				continue
			}
			it.saved = true
		}
		keep[name] = true
		append(&entries, Index_Entry{id = it.id, kind = it.kind == .Text ? "text" : "image", mime = it.mime,
		                             pinned = it.pinned, w = it.w, h = it.h})
	}
	out, merr := json.marshal(Index_File{version = 1, items = entries[:]}, {pretty = true, use_spaces = true, spaces = 1}, context.temp_allocator)
	if merr != nil {
		log.warnf("Clipboard: cannot encode the history index: %v", merr)
		return
	}
	index_path := join_path({cb.dir, INDEX_NAME})
	tmp := strings.concatenate({index_path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, out, FILE_PERMS); err != nil {
		log.warnf("Clipboard: cannot write %s: %v", tmp, err)
		return
	}
	if err := os.rename(tmp, index_path); err != nil {
		log.warnf("Clipboard: cannot replace %s: %v", index_path, err)
		return
	}
	// Files of deleted entries.
	infos, derr := os.read_all_directory_by_path(cb.dir, context.temp_allocator)
	if derr != nil { return }
	for fi in infos {
		if fi.type != .Regular || keep[fi.name] { continue }
		os.remove(fi.fullpath)
	}
}

@(private)
load_history :: proc(cb: ^Clipboard) {
	path := join_path({cb.dir, INDEX_NAME})
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return }
	index: Index_File
	if uerr := json.unmarshal(data, &index, allocator = context.temp_allocator); uerr != nil {
		log.warnf("Clipboard: ignoring the unreadable history index %s: %v", path, uerr)
		return
	}
	for e in index.items {
		kind: Kind = e.kind == "image" ? .Image : .Text
		mime := e.mime
		if kind == .Text { mime = "text/plain;charset=utf-8" }
		if kind == .Image && mime != "image/png" && mime != "image/jpeg" && mime != "image/bmp" { continue }
		if e.id == 0 { continue }
		bytes_, rerr := os.read_entire_file(join_path({cb.dir, item_file_name(e.id, mime)}), context.allocator)
		if rerr != nil { continue }
		it := new(Item)
		it.id = e.id
		it.kind = kind
		it.mime = strings.clone(mime)
		it.data = bytes_
		it.hash = item_hash(kind, bytes_)
		it.w, it.h = e.w, e.h
		it.pinned = e.pinned
		it.saved = true
		append(&cb.items, it)
		cb.next_id = max(cb.next_id, e.id + 1)
	}
	enforce_cap(cb)
	log.infof("Clipboard: loaded %d entries from %s", len(cb.items), cb.dir)
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------
@(private)
decode_image :: proc(mime: string, data: []u8) -> (out: tx.Image, ok: bool) {
	img: ^image.Image
	err: image.Error
	switch mime {
	case "image/png":  img, err = png.load_from_bytes(data, {.alpha_add_if_missing})
	case "image/jpeg": img, err = jpeg.load_from_bytes(data, {.alpha_add_if_missing})
	case "image/bmp":  img, err = bmp.load_from_bytes(data, {.alpha_add_if_missing})
	case: return
	}
	if err != nil || img == nil {
		if img != nil { image.destroy(img) }
		return
	}
	defer image.destroy(img)
	if img.width <= 0 || img.height <= 0 || img.channels < 1 || img.channels > 4 { return }
	w, h, ch := img.width, img.height, img.channels
	out = tx.image_make(i32(w), i32(h))
	px := bytes.buffer_to_bytes(&img.pixels)
	n := w * h
	if img.depth == 16 {
		src := slice.reinterpret([]u16, px)
		if len(src) < n * ch { tx.image_destroy(&out); return {}, false }
		for i in 0 ..< n {
			convert_pixel(out.rgba[i * 4:][:4], ch, u8(src[i * ch] >> 8), ch > 1 ? u8(src[i * ch + 1] >> 8) : 0,
			              ch > 2 ? u8(src[i * ch + 2] >> 8) : 0, ch > 3 ? u8(src[i * ch + 3] >> 8) : 0)
		}
	} else if img.depth == 8 {
		if len(px) < n * ch { tx.image_destroy(&out); return {}, false }
		if ch == 4 {
			copy(out.rgba, px[:n * 4])
		} else {
			for i in 0 ..< n {
				p := px[i * ch:]
				convert_pixel(out.rgba[i * 4:][:4], ch, p[0], ch > 1 ? p[1] : 0, ch > 2 ? p[2] : 0, 0)
			}
		}
	} else {
		tx.image_destroy(&out)
		return {}, false
	}
	return out, true
}

@(private)
convert_pixel :: #force_inline proc(dst: []u8, channels: int, a, b, c, d: u8) {
	switch channels {
	case 1: dst[0], dst[1], dst[2], dst[3] = a, a, a, 255
	case 2: dst[0], dst[1], dst[2], dst[3] = a, a, a, b
	case 3: dst[0], dst[1], dst[2], dst[3] = a, b, c, 255
	case:   dst[0], dst[1], dst[2], dst[3] = a, b, c, d
	}
}

foreign import zlib "system:z"
@(default_calling_convention="c")
foreign zlib {
	@(private) compressBound :: proc(source_len: c.ulong) -> c.ulong ---
	@(private) compress2     :: proc(dest: [^]u8, dest_len: ^c.ulong, source: [^]u8, source_len: c.ulong, level: c.int) -> c.int ---
}

// RGBA → PNG (8-bit RGBA, "Sub" filter, zlib level 6). Returns nil on failure.
@(private)
png_encode :: proc(img: tx.Image, allocator := context.allocator) -> []u8 {
	w, h := int(img.w), int(img.h)
	stride := w * 4
	raw := make([]u8, h * (stride + 1))
	defer delete(raw)
	for y in 0 ..< h {
		row := raw[y * (stride + 1):]
		row[0] = 1 // Sub
		src := img.rgba[y * stride:][:stride]
		for x in 0 ..< stride {
			left := x >= 4 ? src[x - 4] : 0
			row[1 + x] = src[x] - left
		}
	}
	bound := compressBound(c.ulong(len(raw)))
	comp := make([]u8, int(bound))
	defer delete(comp)
	comp_len := bound
	if compress2(raw_data(comp), &comp_len, raw_data(raw), c.ulong(len(raw)), 6) != 0 { return nil }

	out := make([dynamic]u8, 0, int(comp_len) + 64, allocator)
	append(&out, 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A)
	be32 :: proc(out: ^[dynamic]u8, v: u32) { append(out, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)) }
	chunk :: proc(out: ^[dynamic]u8, type: string, data: []u8) {
		be32(out, u32(len(data)))
		start := len(out)
		append(out, ..transmute([]u8)type)
		append(out, ..data)
		be32(out, hash.crc32(out[start:]))
	}
	ihdr: [13]u8
	ihdr[0], ihdr[1], ihdr[2], ihdr[3] = u8(w >> 24), u8(w >> 16), u8(w >> 8), u8(w)
	ihdr[4], ihdr[5], ihdr[6], ihdr[7] = u8(h >> 24), u8(h >> 16), u8(h >> 8), u8(h)
	ihdr[8] = 8  // bit depth
	ihdr[9] = 6  // RGBA
	chunk(&out, "IHDR", ihdr[:])
	chunk(&out, "IDAT", comp[:int(comp_len)])
	chunk(&out, "IEND", nil)
	return out[:]
}
