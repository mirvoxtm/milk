// Picture previews for desktop files (linux.desktopIcons.thumbnails): png,
// jpeg and bmp files (and the other formats core:image reads) of at most
// THUMB_BYTES_MAX are shown as a small preview instead of their type icon.
//
// Decoding runs on a worker thread (started with the first preview asked
// for), so the event loop never waits for a decoder; a pipe wakes the loop
// when a preview is ready (poll_fds). Results are kept in memory by
// "path|mtime|size" and on disk in Spoil's thumbnail cache
// (~/.cache/milk/spoil-thumbs: QOI files of at most THUMB_MAX pixels named
// after the FNV-1a hash of that key), so the desktop and the file manager
// decode each picture once. JPEG variants core:image cannot read
// (progressive...) go through ImageMagick when it is installed.
package desktop

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:hash"
import "core:image"
import _ "core:image/bmp"
import _ "core:image/jpeg"
import _ "core:image/netpbm"
import "core:image/png"
import "core:image/qoi"
import _ "core:image/tga"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import tx "../tx"

@(private)
THUMB_MAX :: 128 // stored preview size (longer side), as Spoil's
@(private)
THUMB_BYTES_MAX :: 20 * 1024 * 1024
@(private)
THUMB_PIXELS_MAX :: 64 * 1024 * 1024 // decoded size limit (a 20 MB PNG can hide gigabytes)

@(private)
Thumb_State :: enum u8 { Pending, Ready, Failed }

@(private)
Thumb :: struct {
	state: Thumb_State,
	img:   tx.Image, // fits the icon size (Ready)
}

@(private)
Thumb_Job :: struct {
	key:  string, // heap
	path: string, // heap
}

@(private)
Thumb_Done :: struct {
	key: string, // heap (the job's key, handed back)
	img: tx.Image,
	ok:  bool,
}

Thumbs :: struct {
	mutex:     sync.Mutex,
	sema:      sync.Sema,
	queue:     [dynamic]Thumb_Job,  // guarded by mutex; LIFO, so the last painted icons come first
	done:      [dynamic]Thumb_Done, // guarded by mutex
	quit:      bool,                // guarded by mutex
	started:   bool,                // thumbs_start ran
	worker:    ^thread.Thread,
	cache_dir: string,              // heap; "" = no disk cache
	magick:    string,              // "magick" or "convert"; "" = not installed
	items:     map[string]Thumb,    // main thread only
	wake_r:    posix.FD,
	wake_w:    posix.FD,
}

thumbs_init :: proc(d: ^Daemon) {
	t := &d.thumbs
	t.items = make(map[string]Thumb)
	t.wake_r, t.wake_w = -1, -1
}

// Start the worker on the first preview asked for; false when it cannot run.
@(private)
thumbs_start :: proc(d: ^Daemon) -> bool {
	t := &d.thumbs
	if t.started { return t.worker != nil }
	t.started = true
	heap := runtime.heap_allocator()
	t.queue = make([dynamic]Thumb_Job, heap)
	t.done = make([dynamic]Thumb_Done, heap)
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		log.warn("No pipe for the thumbnail worker; pictures show their type icon")
		return false
	}
	t.wake_r, t.wake_w = fds[0], fds[1]
	for fd in fds {
		flags := posix.fcntl(fd, .GETFL)
		posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK)
		posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	}
	cache := join_path({xdg_env_dir("XDG_CACHE_HOME", join_path({home_dir(), ".cache"})), "milk", "spoil-thumbs"})
	if ensure_dir(cache) { t.cache_dir = strings.clone(cache, heap) }
	if _, found := find_executable("magick"); found {
		t.magick = "magick"
	} else if _, found2 := find_executable("convert"); found2 {
		t.magick = "convert"
	}
	t.worker = thread.create(thumb_worker, .Low)
	if t.worker == nil {
		log.warn("Cannot start the thumbnail worker; pictures show their type icon")
		return false
	}
	t.worker.data = t
	thread.start(t.worker)
	return true
}

thumbs_destroy :: proc(d: ^Daemon) {
	t := &d.thumbs
	if t.worker != nil {
		sync.mutex_lock(&t.mutex)
		t.quit = true
		sync.mutex_unlock(&t.mutex)
		sync.sema_post(&t.sema)
		thread.join(t.worker)
		thread.destroy(t.worker)
	}
	heap := runtime.heap_allocator()
	for job in t.queue { delete(job.key, heap); delete(job.path, heap) }
	delete(t.queue)
	for r in t.done {
		delete(r.key, heap)
		if r.ok { delete(r.img.rgba, heap) }
	}
	delete(t.done)
	thumbs_clear(d)
	delete(t.items)
	delete(t.cache_dir, heap)
	if t.wake_r >= 0 { posix.close(t.wake_r) }
	if t.wake_w >= 0 { posix.close(t.wake_w) }
	t^ = {}
}

// Forget every preview (the icon size changed); they are asked again.
thumbs_clear :: proc(d: ^Daemon) {
	t := &d.thumbs
	for key, &th in t.items {
		delete(key)
		tx.image_destroy(&th.img)
	}
	clear(&t.items)
}

// The pipe the worker writes to when a preview is ready (-1 = none).
thumbs_fd :: proc(d: ^Daemon) -> (i32, bool) {
	if d.thumbs.worker == nil || d.thumbs.wake_r < 0 { return -1, false }
	return i32(d.thumbs.wake_r), true
}

thumb_key :: proc(it: ^Item) -> string {
	return fmt.tprintf("%s|%d|%d", it.path, it.mtime, it.size)
}

@(private)
thumbnailable :: proc(d: ^Daemon, it: ^Item) -> bool {
	if !d.cfg.linux.desktop_icons.thumbnails || (d.thumbs.started && d.thumbs.worker == nil) { return false }
	if it.source != .Folder || it.kind != .Image || it.size <= 0 || it.size > THUMB_BYTES_MAX { return false }
	switch lower_ext(it.name) {
	case ".png", ".jpg", ".jpeg", ".jpe", ".bmp", ".qoi", ".tga", ".ppm", ".pgm", ".pbm", ".pnm":
		return true
	}
	return false
}

// Is the preview of `it` ready (without asking for it)?
thumb_ready :: proc(d: ^Daemon, it: ^Item) -> bool {
	if !thumbnailable(d, it) { return false }
	th, found := d.thumbs.items[thumb_key(it)]
	return found && th.state == .Ready
}

// The preview of `it` when it is ready; asked for on first use.
thumb_for :: proc(d: ^Daemon, it: ^Item) -> ^tx.Image {
	if !thumbnailable(d, it) { return nil }
	t := &d.thumbs
	key := thumb_key(it)
	if th, found := &t.items[key]; found {
		return &th.img if th.state == .Ready else nil
	}
	if !thumbs_start(d) { return nil }
	heap := runtime.heap_allocator()
	t.items[strings.clone(key)] = Thumb{state = .Pending}
	sync.mutex_lock(&t.mutex)
	append(&t.queue, Thumb_Job{key = strings.clone(key, heap), path = strings.clone(it.path, heap)})
	sync.mutex_unlock(&t.mutex)
	sync.sema_post(&t.sema)
	return nil
}

// Take the finished previews and repaint the icons that show them.
thumbs_collect :: proc(d: ^Daemon) {
	t := &d.thumbs
	buf: [64]u8
	for posix.read(t.wake_r, &buf[0], len(buf)) > 0 {}
	sync.mutex_lock(&t.mutex)
	done := t.done
	t.done = make([dynamic]Thumb_Done, runtime.heap_allocator())
	sync.mutex_unlock(&t.mutex)
	defer delete(done)
	heap := runtime.heap_allocator()
	l := &d.layer
	for r in done {
		defer delete(r.key, heap)
		th, found := &t.items[r.key]
		if !found {
			if r.ok { delete(r.img.rgba, heap) }
			continue
		}
		if !r.ok {
			th.state = .Failed
			continue
		}
		w, h := fit_size(r.img.w, r.img.h, l.icon_size)
		th.img = tx.image_resize(r.img, w, h)
		th.state = .Ready
		delete(r.img.rgba, heap)
		for &cell in l.cells {
			it := &l.items[cell.entry]
			if it.source != .Folder || it.kind != .Image || thumb_key(it) != r.key { continue }
			cell.look = item_look(d, it)
			cell_paint(d, &cell)
		}
	}
	thumbs_prune(d)
}

// Drop the previews of files that are no longer shown.
@(private)
thumbs_prune :: proc(d: ^Daemon) {
	t := &d.thumbs
	if len(t.items) <= 2 * len(d.layer.items) + 16 { return }
	wanted := make(map[string]bool, len(d.layer.items), context.temp_allocator)
	for &it in d.layer.items { wanted[thumb_key(&it)] = true }
	stale := make([dynamic]string, context.temp_allocator)
	for key, th in t.items {
		if key not_in wanted && th.state != .Pending { append(&stale, key) }
	}
	for key in stale {
		k, th := delete_key(&t.items, key)
		tx.image_destroy(&th.img)
		delete(k)
	}
}

// Size of a w×h picture scaled so that its longer side is at most `box`.
@(private)
fit_size :: proc(w, h, box: i32) -> (i32, i32) {
	if w <= box && h <= box { return max(w, 1), max(h, 1) }
	if w >= h { return box, max(1, i32(f32(box) * f32(h) / f32(w) + 0.5)) }
	return max(1, i32(f32(box) * f32(w) / f32(h) + 0.5)), box
}

// ---------------------------------------------------------------------------
// Worker thread
// ---------------------------------------------------------------------------
@(private)
thumb_worker :: proc(th: ^thread.Thread) {
	t := (^Thumbs)(th.data)
	context.allocator = runtime.heap_allocator()
	for {
		sync.sema_wait(&t.sema)
		sync.mutex_lock(&t.mutex)
		if t.quit {
			sync.mutex_unlock(&t.mutex)
			return
		}
		if len(t.queue) == 0 {
			sync.mutex_unlock(&t.mutex)
			continue
		}
		job := pop(&t.queue)
		sync.mutex_unlock(&t.mutex)

		img, ok := make_thumb(t, job.path, job.key)
		delete(job.path)
		sync.mutex_lock(&t.mutex)
		append(&t.done, Thumb_Done{key = job.key, img = img, ok = ok})
		sync.mutex_unlock(&t.mutex)
		b := u8(1)
		posix.write(t.wake_w, &b, 1)
	}
}

// One preview (from the disk cache or decoded) of at most THUMB_MAX pixels,
// heap-allocated. Runs on the worker thread.
@(private)
make_thumb :: proc(t: ^Thumbs, path, key: string) -> (tx.Image, bool) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { return {}, false }
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)
	context.allocator = scratch
	context.temp_allocator = scratch
	heap := runtime.heap_allocator()

	cache_file := ""
	if t.cache_dir != "" {
		cache_file = fmt.aprintf("%s/%016x.qoi", t.cache_dir, hash.fnv64a(transmute([]u8)key), allocator = scratch)
		if data, err := os.read_entire_file(cache_file, scratch); err == nil {
			img, lerr := qoi.load_from_bytes(data, {}, scratch)
			if lerr == nil && img != nil && img.channels == 4 && img.depth == 8 && img.width > 0 && img.height > 0 &&
			   img.width <= THUMB_MAX && img.height <= THUMB_MAX {
				out := tx.image_make(i32(img.width), i32(img.height), heap)
				copy(out.rgba, img.pixels.buf[:])
				return out, true
			}
		}
	}

	src, ok := decode_picture(t, path, scratch)
	if !ok { return {}, false }
	w, h := fit_size(src.w, src.h, THUMB_MAX)
	out := tx.image_resize(src, w, h, heap)
	if cache_file != "" {
		enc: image.Image
		enc.width, enc.height, enc.channels, enc.depth = int(w), int(h), 4, 8
		buf := make([dynamic]u8, len(out.rgba), scratch)
		copy(buf[:], out.rgba)
		enc.pixels = bytes.Buffer{buf = buf}
		temporary := fmt.aprintf("%s.%d.tmp", cache_file, posix.getpid(), allocator = scratch)
		if qoi.save_to_file(temporary, &enc, {}, scratch) == nil {
			if os.rename(temporary, cache_file) != nil { os.remove(temporary) }
		}
	}
	return out, true
}

// Decode a picture into straight RGBA8 (in the scratch arena, which is the
// context allocator of the worker), refusing huge ones.
@(private)
decode_picture :: proc(t: ^Thumbs, path: string, scratch: runtime.Allocator) -> (tx.Image, bool) {
	data, rerr := os.read_entire_file(path, scratch)
	if rerr != nil || len(data) == 0 || len(data) > THUMB_BYTES_MAX { return {}, false }
	header, herr := image.load_from_bytes(data, {.info}, scratch)
	if herr == nil && header != nil && header.width * header.height > THUMB_PIXELS_MAX { return {}, false }
	img, lerr := image.load_from_bytes(data, {.alpha_add_if_missing}, scratch)
	if lerr == nil && img != nil {
		if rgba, converted := to_rgba(img); converted { return rgba, true }
	}
	return magick_decode(t, path, scratch)
}

// Progressive JPEG and friends, through ImageMagick (already scaled down).
@(private)
magick_decode :: proc(t: ^Thumbs, path: string, scratch: runtime.Allocator) -> (tx.Image, bool) {
	if t.magick == "" { return {}, false }
	geometry := fmt.aprintf("%dx%d", THUMB_MAX, THUMB_MAX, allocator = scratch)
	hint := fmt.aprintf("jpeg:size=%dx%d", THUMB_MAX * 2, THUMB_MAX * 2, allocator = scratch)
	source := fmt.aprintf("%s[0]", path, allocator = scratch)
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = {t.magick, "-define", hint, source, "-auto-orient", "-thumbnail", geometry, "png:-"}}, scratch)
	if err != nil || !state.success || len(stdout) == 0 { return {}, false }
	img, lerr := png.load_from_bytes(stdout, {.alpha_add_if_missing}, scratch)
	if lerr != nil || img == nil { return {}, false }
	return to_rgba(img)
}
