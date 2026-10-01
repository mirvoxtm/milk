// Wallpapers drawn ahead of time (see wallpaper.odin): once an area's
// wallpaper is on screen, the pictures of the other areas are decoded and
// scaled to the screen on a low-priority worker thread, the way feh draws
// them (each monitor filled on its own for fill, max, scale and center; the
// whole screen for tile), and kept as drawn wallpapers, so even the first
// visit to an area only copies a pixmap. Pictures core:image cannot decode
// (webp, progressive JPEG...) go through ImageMagick when it is installed;
// otherwise feh draws them on the first visit, as before.
package desktop

import "base:runtime"
import "core:fmt"
import "core:image"
import _ "core:image/netpbm"
import "core:log"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import xlib "vendor:x11/xlib"
import tx "../tx"

// Pictures larger than this are left to feh (decoding them would need gigabytes).
@(private) PRELOAD_PIXELS_MAX :: 120 * 1024 * 1024
@(private) PRELOAD_BYTES_MAX :: 256 * 1024 * 1024

@(private)
Preload_Job :: struct {
	key:        string,     // heap: the drawn wallpaper's key (wallpaper_target)
	file:       string,     // heap: the picture, "" = plain background
	mode:       string,     // heap
	solid:      tx.Color,
	w, h:       i32,        // screen size
	monitors:   []tx.Rect,  // heap: where each monitor is (fill/max/scale/center draw per monitor)
	generation: int,
}

@(private)
Preload_Done :: struct {
	key:        string, // heap
	px:         []u32,  // heap: 0x00RRGGBB, w×h; nil when it failed
	w, h:       i32,
	generation: int,
}

Preload :: struct {
	mutex:      sync.Mutex,
	sema:       sync.Sema,
	queue:      [dynamic]Preload_Job,  // guarded by mutex
	done:       [dynamic]Preload_Done, // guarded by mutex
	quit:       bool,                  // guarded by mutex
	generation: int,                   // guarded by mutex: bumped to drop queued and running work
	worker:     ^thread.Thread,
	wake_r:     posix.FD,
	wake_w:     posix.FD,
	magick:     string,                // "magick" or "convert"; "" = not installed (heap)
	pending:    map[string]bool,       // main thread: keys queued or being drawn (owned keys)
	failed:     map[string]bool,       // main thread: keys the worker could not draw (left to feh)
}

preload_init :: proc(d: ^Daemon) {
	p := &d.preload
	p.wake_r, p.wake_w = -1, -1
	p.pending = make(map[string]bool)
	p.failed = make(map[string]bool)
}

preload_destroy :: proc(d: ^Daemon) {
	p := &d.preload
	if p.worker != nil {
		sync.mutex_lock(&p.mutex)
		p.quit = true
		sync.mutex_unlock(&p.mutex)
		sync.sema_post(&p.sema)
		thread.join(p.worker)
		thread.destroy(p.worker)
		p.worker = nil
	}
	heap := runtime.heap_allocator()
	for &job in p.queue { job_free(&job) }
	delete(p.queue)
	for r in p.done {
		delete(r.key, heap)
		delete(r.px, heap)
	}
	delete(p.done)
	if p.wake_r >= 0 { posix.close(p.wake_r) }
	if p.wake_w >= 0 { posix.close(p.wake_w) }
	delete(p.magick, heap)
	for key in p.pending { delete(key) }
	delete(p.pending)
	for key in p.failed { delete(key) }
	delete(p.failed)
}

// Start the worker on first use; false when it cannot run.
@(private)
preload_start :: proc(d: ^Daemon) -> bool {
	p := &d.preload
	if p.worker != nil { return true }
	if p.wake_r >= 0 { return false } // tried before and failed
	heap := runtime.heap_allocator()
	p.queue = make([dynamic]Preload_Job, heap)
	p.done = make([dynamic]Preload_Done, heap)
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK { return false }
	p.wake_r, p.wake_w = fds[0], fds[1]
	for fd in fds {
		flags := posix.fcntl(fd, .GETFL)
		posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK)
		posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	}
	if _, found := find_executable("magick"); found {
		p.magick = strings.clone("magick", heap)
	} else if _, found2 := find_executable("convert"); found2 {
		p.magick = strings.clone("convert", heap)
	}
	p.worker = thread.create(preload_worker, .Low)
	if p.worker == nil {
		log.warn("Cannot start the wallpaper worker; wallpapers are drawn on the first visit")
		return false
	}
	p.worker.data = p
	thread.start(p.worker)
	return true
}

// The pipe the worker writes to when a wallpaper is ready (-1 = none).
preload_fd :: proc(d: ^Daemon) -> (i32, bool) {
	if d.preload.worker == nil || d.preload.wake_r < 0 { return -1, false }
	return i32(d.preload.wake_r), true
}

// Drop queued and running work (configuration or screen changed); results
// already drawn stay.
preload_reset :: proc(d: ^Daemon) {
	p := &d.preload
	sync.mutex_lock(&p.mutex)
	p.generation += 1
	for &job in p.queue { job_free(&job) }
	clear(&p.queue)
	sync.mutex_unlock(&p.mutex)
	for key in p.pending { delete(key) }
	clear(&p.pending)
	for key in p.failed { delete(key) }
	clear(&p.failed)
}

// Draw the other areas' wallpapers ahead of time (neighbours first), as far
// as the drawn list has room for them.
preload_schedule :: proc(d: ^Daemon) {
	p := &d.preload
	w := &d.wallpaper
	if d.area <= 0 { return }
	n := area_count(d)
	order := make([dynamic]int, context.temp_allocator)
	for step in 1 ..= n {
		for index in ([]int{d.area + step, d.area - step}) {
			if index >= 1 && index <= n && !slice.contains(order[:], index) { append(&order, index) }
		}
	}
	room := drawn_capacity(d) - len(w.drawn) - len(p.pending)
	screen := tx.screen_rect(d.c)
	monitors: [dynamic]tx.Rect
	for index in order {
		if room <= 0 { break }
		target, ok := wallpaper_target(d, index)
		if !ok || target.key == w.shown || drawn_find(w, target.key) >= 0 || target.key in p.pending || target.key in p.failed { continue }
		// The worker reads the picture itself (a half-written one fails to
		// decode and is left to feh): no copy on the main thread.
		file := target.source
		if !preload_start(d) { return }
		if monitors == nil {
			monitors = make([dynamic]tx.Rect, context.temp_allocator)
			for m in tx.monitors(d.c) { append(&monitors, m.rect) }
			if len(monitors) == 0 { append(&monitors, screen) }
		}
		heap := runtime.heap_allocator()
		job := Preload_Job{
			key = strings.clone(target.key, heap), file = strings.clone(file, heap), mode = strings.clone(target.mode, heap),
			solid = target.solid, w = screen.w, h = screen.h, monitors = slice.clone(monitors[:], heap),
		}
		sync.mutex_lock(&p.mutex)
		job.generation = p.generation
		append(&p.queue, job)
		sync.mutex_unlock(&p.mutex)
		sync.sema_post(&p.sema)
		p.pending[strings.clone(target.key)] = true
		room -= 1
	}
}

// Take the finished wallpapers into the drawn list.
preload_collect :: proc(d: ^Daemon) {
	p := &d.preload
	buf: [64]u8
	for posix.read(p.wake_r, &buf[0], len(buf)) > 0 {}
	heap := runtime.heap_allocator()
	sync.mutex_lock(&p.mutex)
	done := p.done
	p.done = make([dynamic]Preload_Done, heap)
	generation := p.generation
	sync.mutex_unlock(&p.mutex)
	defer delete(done)
	for r in done {
		defer {
			delete(r.key, heap)
			delete(r.px, heap)
		}
		if r.generation != generation { continue }
		if key, _, found := pending_take(p, r.key); found { delete(key) }
		screen := tx.screen_rect(d.c)
		if r.px == nil {
			p.failed[strings.clone(r.key)] = true // feh draws it on the visit
			continue
		}
		if r.w != screen.w || r.h != screen.h || drawn_find(&d.wallpaper, r.key) >= 0 { continue }
		pm := xlib.CreatePixmap(d.c.dpy, xlib.Drawable(d.c.root), u32(r.w), u32(r.h), u32(d.c.depth))
		tx.canvas_upload(d.c, tx.Canvas{w = r.w, h = r.h, px = r.px}, xlib.Drawable(pm), 0, 0)
		drawn_add(d, r.key, pm, r.w, r.h)
		log.debugf("Wallpaper drawn ahead: %s", r.key)
	}
	tx.flush(d.c)
}

@(private)
pending_take :: proc(p: ^Preload, key: string) -> (owned: string, value: bool, found: bool) {
	if _, has := p.pending[key]; !has { return }
	owned, value = delete_key(&p.pending, key)
	return owned, value, true
}

@(private)
job_free :: proc(job: ^Preload_Job) {
	heap := runtime.heap_allocator()
	delete(job.key, heap)
	delete(job.file, heap)
	delete(job.mode, heap)
	delete(job.monitors, heap)
}

// ---------------------------------------------------------------------------
// Worker thread
// ---------------------------------------------------------------------------
@(private)
preload_worker :: proc(t: ^thread.Thread) {
	p := (^Preload)(t.data)
	heap := runtime.heap_allocator()
	for {
		sync.sema_wait(&p.sema)
		sync.mutex_lock(&p.mutex)
		if p.quit {
			sync.mutex_unlock(&p.mutex)
			return
		}
		if len(p.queue) == 0 {
			sync.mutex_unlock(&p.mutex)
			continue
		}
		job := p.queue[0]
		ordered_remove(&p.queue, 0)
		current := p.generation
		sync.mutex_unlock(&p.mutex)

		px: []u32
		if job.generation == current { px = render_wallpaper(p, &job) }
		result := Preload_Done{key = strings.clone(job.key, heap), px = px, w = job.w, h = job.h, generation = job.generation}
		job_free(&job)
		sync.mutex_lock(&p.mutex)
		append(&p.done, result)
		sync.mutex_unlock(&p.mutex)
		b := u8(1)
		posix.write(p.wake_w, &b, 1)
	}
}

// The screen-sized picture of a job (heap), nil when it cannot be drawn here.
@(private)
render_wallpaper :: proc(p: ^Preload, job: ^Preload_Job) -> []u32 {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { return nil }
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)
	context.allocator = scratch
	context.temp_allocator = scratch
	heap := runtime.heap_allocator()

	out := make([]u32, int(job.w) * int(job.h), heap)
	if job.file == "" {
		c := u32(job.solid.r) << 16 | u32(job.solid.g) << 8 | u32(job.solid.b)
		slice.fill(out, c)
		return out
	}
	src, ok := decode_wallpaper(p, job.file, scratch)
	if !ok {
		delete(out, heap)
		return nil
	}
	if job.mode == "tile" {
		for y in 0 ..< int(job.h) {
			sy := y % int(src.h)
			for x in 0 ..< int(job.w) { out[y * int(job.w) + x] = pixel_over_black(src, x % int(src.w), sy) }
		}
		return out
	}
	sw, sh := f64(src.w), f64(src.h)
	for m in job.monitors {
		mw, mh := f64(m.w), f64(m.h)
		switch job.mode {
		case "fill": // cover the monitor, centre crop
			s := max(mw / sw, mh / sh)
			rw, rh := mw / s, mh / s
			resample_into(out, job.w, job.h, m, src, (sw - rw) / 2, (sh - rh) / 2, rw, rh)
		case "max": // fit inside, centred on black
			s := min(mw / sw, mh / sh)
			tw, th := i32(math.round(sw * s)), i32(math.round(sh * s))
			r := tx.Rect{m.x + (m.w - tw) / 2, m.y + (m.h - th) / 2, tw, th}
			resample_into(out, job.w, job.h, r, src, 0, 0, sw, sh)
		case "scale": // stretch
			resample_into(out, job.w, job.h, m, src, 0, 0, sw, sh)
		case "center": // native size, centred, cut at the monitor's edges
			ox, oy := m.x + (m.w - src.w) / 2, m.y + (m.h - src.h) / 2
			for y in max(m.y, oy) ..< min(m.y + m.h, oy + src.h) {
				for x in max(m.x, ox) ..< min(m.x + m.w, ox + src.w) {
					if x < 0 || y < 0 || x >= job.w || y >= job.h { continue }
					out[int(y) * int(job.w) + int(x)] = pixel_over_black(src, int(x - ox), int(y - oy))
				}
			}
		}
	}
	return out
}

@(private)
pixel_over_black :: #force_inline proc(src: tx.Image, x, y: int) -> u32 {
	i := (y * int(src.w) + x) * 4
	a := u32(src.rgba[i + 3])
	r := u32(src.rgba[i]) * a / 255
	g := u32(src.rgba[i + 1]) * a / 255
	b := u32(src.rgba[i + 2]) * a / 255
	return r << 16 | g << 8 | b
}

// Decode a picture into RGBA8 (scratch): core:image first, ImageMagick for the rest.
@(private)
decode_wallpaper :: proc(p: ^Preload, path: string, scratch: runtime.Allocator) -> (tx.Image, bool) {
	data, rerr := os.read_entire_file(path, scratch)
	if rerr != nil || len(data) == 0 || len(data) > PRELOAD_BYTES_MAX { return {}, false }
	header, herr := image.load_from_bytes(data, {.info}, scratch)
	if herr == nil && header != nil && header.width * header.height > PRELOAD_PIXELS_MAX { return {}, false }
	img, lerr := image.load_from_bytes(data, {.alpha_add_if_missing}, scratch)
	if lerr == nil && img != nil {
		if rgba, converted := to_rgba(img); converted { return rgba, true }
	}
	if p.magick == "" { return {}, false }
	source := fmt.aprintf("%s[0]", path, allocator = scratch)
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = {p.magick, source, "-auto-orient", "-depth", "8", "ppm:-"}}, scratch)
	if err != nil || !state.success || len(stdout) == 0 { return {}, false }
	pnm, perr := image.load_from_bytes(stdout, {.alpha_add_if_missing}, scratch)
	if perr != nil || pnm == nil || pnm.width * pnm.height > PRELOAD_PIXELS_MAX { return {}, false }
	return to_rgba(pnm)
}

// ---------------------------------------------------------------------------
// Scaling
// ---------------------------------------------------------------------------

// The source pixels one output pixel takes, with their weights.
@(private)
Contribution :: struct {
	first:   int, // source index of weights[0]
	weights: []f32,
}

// For n_out output pixels covering source positions [start, start + length)
// of an axis with n_src pixels: an area average when shrinking, linear
// interpolation when enlarging.
@(private)
axis_contributions :: proc(n_out: int, start, length: f64, n_src: int) -> []Contribution {
	out := make([]Contribution, n_out)
	scale := f64(n_out) / length
	for o in 0 ..< n_out {
		if scale >= 1 {
			c := start + (f64(o) + 0.5) / scale - 0.5
			i0 := int(math.floor(c))
			t := f32(c - f64(i0))
			a, b := clamp(i0, 0, n_src - 1), clamp(i0 + 1, 0, n_src - 1)
			if a == b {
				out[o] = {first = a, weights = slice.clone([]f32{1})}
			} else {
				out[o] = {first = a, weights = slice.clone([]f32{1 - t, t})}
			}
			continue
		}
		lo := start + f64(o) / scale
		hi := start + f64(o + 1) / scale
		i0 := clamp(int(math.floor(lo)), 0, n_src - 1)
		i1 := clamp(int(math.ceil(hi)) - 1, i0, n_src - 1)
		weights := make([]f32, i1 - i0 + 1)
		total: f32
		for i in i0 ..= i1 {
			w := f32(min(hi, f64(i + 1)) - max(lo, f64(i)))
			if w < 0 { w = 0 }
			weights[i - i0] = w
			total += w
		}
		if total <= 0 {
			weights[0], total = 1, 1
		}
		for &w in weights { w /= total }
		out[o] = {first = i0, weights = weights}
	}
	return out
}

// Scale the source region (rx, ry, rw, rh) into rect `r` of `out` (screen
// sized, w×h), one output row at a time (vertical pass into a row of floats,
// then horizontal pass), cut at the screen's edges.
@(private)
resample_into :: proc(out: []u32, w, h: i32, r: tx.Rect, src: tx.Image, rx, ry, rw, rh: f64) {
	if r.w <= 0 || r.h <= 0 || rw <= 0 || rh <= 0 { return }
	xs := axis_contributions(int(r.w), rx, rw, int(src.w))
	ys := axis_contributions(int(r.h), ry, rh, int(src.h))
	col0, col1 := int(src.w), 0
	for c in xs {
		col0 = min(col0, c.first)
		col1 = max(col1, c.first + len(c.weights))
	}
	span := col1 - col0
	row := make([]f32, span * 3)
	for oy in 0 ..< int(r.h) {
		y := int(r.y) + oy
		if y < 0 || y >= int(h) { continue }
		slice.zero(row)
		cy := ys[oy]
		for wy, k in cy.weights {
			sy := cy.first + k
			base := sy * int(src.w)
			for sx in col0 ..< col1 {
				i := (base + sx) * 4
				a := f32(src.rgba[i + 3]) / 255
				j := (sx - col0) * 3
				row[j] += f32(src.rgba[i]) * a * wy
				row[j + 1] += f32(src.rgba[i + 1]) * a * wy
				row[j + 2] += f32(src.rgba[i + 2]) * a * wy
			}
		}
		dst := out[y * int(w):]
		for ox in 0 ..< int(r.w) {
			x := int(r.x) + ox
			if x < 0 || x >= int(w) { continue }
			cx := xs[ox]
			rr, gg, bb: f32
			for wx, k in cx.weights {
				j := (cx.first + k - col0) * 3
				rr += row[j] * wx
				gg += row[j + 1] * wx
				bb += row[j + 2] * wx
			}
			dst[x] = u32(clamp(rr + 0.5, 0, 255)) << 16 | u32(clamp(gg + 0.5, 0, 255)) << 8 | u32(clamp(bb + 0.5, 0, 255))
		}
	}
}
