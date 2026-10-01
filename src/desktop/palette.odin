// The wallpaper theme (appearance.theme = "wallpaper"): after an area's
// wallpaper is applied, matugen makes a light and a dark palette from it and
// they are published as config.wallpaper_palette_path(), which config.load
// reads. The caller (milk's main loop) reloads the theme when theme_changed
// says so.
//
// matugen runs as a child process whose output is read through poll_fds, so
// the event loop never waits for it; results are kept per image, scheme and
// image stamp in ~/.cache/milk/palettes, so going back to an area costs
// nothing. Newer matugen asks which colour to use when an image has several
// (--source-color-index 0 answers that) and reads its own config file (a
// private empty one keeps the user's templates out of it); when that first
// call fails, a plain call follows for older versions.
package desktop

import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import config "../config"
import tx "../tx"

@(private)
MATUGEN_TIMEOUT :: 30.0

Palette_State :: struct {
	pid:          posix.pid_t, // the running matugen, 0 = none
	fd:           posix.FD,    // its stdout (non-blocking), -1 = none
	out:          [dynamic]u8,
	deadline:     f64,
	plain:        bool,   // the running call is the fallback without the newer options
	source:       string, // heap: the image of the running call
	scheme:       string, // heap
	key:          string, // heap: source|mtime|size|scheme of the running call
	current:      string, // heap: key of the palette published last
	again:        bool,   // the area changed while matugen ran: look again when it ends
	changed:      bool,   // a new palette was published (theme_changed)
	missing:      bool,   // matugen is not installed (logged once)
}

palette_init :: proc(d: ^Daemon) {
	d.palette.fd = -1
	d.palette.out = make([dynamic]u8)
}

palette_destroy :: proc(d: ^Daemon) {
	p := &d.palette
	palette_stop(d)
	delete(p.out)
	delete(p.current)
}

// Whether a new wallpaper palette was published since the last call.
theme_changed :: proc(d: ^Daemon) -> bool {
	changed := d.palette.changed
	d.palette.changed = false
	return changed
}

// The wallpaper theme is on and area `index`'s wallpaper is (now) on screen.
@(private)
palette_update :: proc(d: ^Daemon, index: int) {
	p := &d.palette
	if d.cfg.appearance.theme != config.WALLPAPER_THEME {
		// Another theme: forget the last palette, so coming back publishes one again.
		if p.pid != 0 { palette_stop(d) }
		delete(p.current)
		p.current = ""
		return
	}
	if p.pid != 0 {
		p.again = true
		return
	}
	source, found := wallpaper_source(d.cfg, d.runtime_root, index)
	if !found { return } // a plain background: the last palette stays
	fi, err := os.stat(source, context.temp_allocator)
	if err != nil { return }
	scheme := d.cfg.appearance.matugen_scheme
	key := fmt.tprintf("%s|%d|%d|%s", source, time.time_to_unix_nano(fi.modification_time), fi.size, scheme)
	if key == p.current { return }

	cache := palette_cache_file(key)
	if pal, ok := config.read_wallpaper_palette(cache); ok {
		defer config.destroy_wallpaper_palette(&pal)
		palette_publish(d, pal, key)
		return
	}
	palette_start(d, source, scheme, key, false)
}

// ~/.cache/milk/palettes/<hash of the key>.json
@(private)
palette_cache_file :: proc(key: string) -> string {
	dir := join_path({xdg_env_dir("XDG_CACHE_HOME", join_path({home_dir(), ".cache"})), "milk", "palettes"})
	return fmt.tprintf("%s/%016x.json", dir, hash.fnv64a(transmute([]u8)key))
}

// The private matugen configuration (no templates): ~/.cache/milk/matugen.toml.
@(private)
palette_matugen_config :: proc() -> string {
	path := join_path({xdg_env_dir("XDG_CACHE_HOME", join_path({home_dir(), ".cache"})), "milk", "matugen.toml"})
	if !os.is_file(path) {
		ensure_dir(path[:strings.last_index_byte(path, '/')])
		_ = os.write_entire_file(path, transmute([]u8)string("# milk runs matugen with this file: colours only, no templates.\n[config]\n\n[templates]\n"))
	}
	return path
}

@(private)
palette_start :: proc(d: ^Daemon, source, scheme, key: string, plain: bool) {
	p := &d.palette
	exe, found := find_executable("matugen")
	if !found {
		// The installer may have put it in ~/.local/bin, which a login session may lack in PATH.
		local := join_path({home_dir(), ".local", "bin", "matugen"})
		if is_executable_file(local) { exe, found = local, true }
	}
	if !found {
		if !p.missing { log.warn("The wallpaper theme needs matugen, which is not installed; keeping the current colours") }
		p.missing = true
		return
	}
	p.missing = false
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, exe, "image", source, "--json", "hex", "--dry-run", "-q", "-t", fmt.tprintf("scheme-%s", scheme))
	if !plain { append(&argv, "--source-color-index", "0", "-c", palette_matugen_config()) }

	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK { return }
	flags := posix.fcntl(fds[0], .GETFL)
	posix.fcntl(fds[0], .SETFL, flags | posix.O_NONBLOCK)
	posix.fcntl(fds[0], .SETFD, posix.FD_CLOEXEC)
	cexe := strings.clone_to_cstring(exe, context.temp_allocator)
	cargs := make([]cstring, len(argv) + 1, context.temp_allocator)
	for arg, i in argv { cargs[i] = strings.clone_to_cstring(arg, context.temp_allocator) }

	child := posix.fork()
	if child < 0 {
		posix.close(fds[0])
		posix.close(fds[1])
		return
	}
	if child == 0 {
		// Only async-signal-safe calls after fork().
		empty: posix.sigset_t
		posix.sigemptyset(&empty)
		posix.sigprocmask(.SETMASK, &empty, nil)
		null := posix.open("/dev/null", {.RDWR})
		if null >= 0 {
			posix.dup2(null, 0) // never a terminal: matugen must not ask anything
			posix.dup2(null, 2)
		}
		posix.dup2(fds[1], 1)
		for fd in 3 ..< 1024 { posix.close(posix.FD(fd)) }
		posix.execv(cexe, raw_data(cargs))
		posix._exit(127)
	}
	posix.close(fds[1])
	p.pid = child
	p.fd = fds[0]
	p.plain = plain
	p.deadline = tx.now() + MATUGEN_TIMEOUT
	clear(&p.out)
	if p.source != source { delete(p.source); p.source = strings.clone(source) }
	if p.scheme != scheme { delete(p.scheme); p.scheme = strings.clone(scheme) }
	if p.key != key { delete(p.key); p.key = strings.clone(key) }
	log.debugf("matugen: colours of %s (%s)", source, scheme)
}

// matugen's stdout is readable.
@(private)
palette_read :: proc(d: ^Daemon) {
	p := &d.palette
	buf: [16384]u8
	for {
		n := posix.read(p.fd, &buf[0], len(buf))
		if n > 0 {
			append(&p.out, ..buf[:n])
			continue
		}
		if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EWOULDBLOCK) { return }
		if n < 0 && posix.errno() == .EINTR { continue }
		break // end of output
	}
	posix.close(p.fd)
	p.fd = -1
	status: i32
	for posix.waitpid(p.pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	p.pid = 0
	pal: config.Wallpaper_Palette
	ok := false
	if posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0 {
		pal, ok = config.palette_from_matugen(p.out[:], p.source, p.scheme)
	}
	if ok {
		defer config.destroy_wallpaper_palette(&pal)
		if !config.write_wallpaper_palette(palette_cache_file(p.key), pal) {
			log.debugf("Could not cache the palette of %s", p.source)
		}
		palette_publish(d, pal, p.key)
	} else if !p.plain {
		palette_start(d, p.source, p.scheme, p.key, true)
		return
	} else {
		log.warnf("matugen could not make colours from %s; keeping the current ones", p.source)
		// Do not try this image again until it (or the scheme) changes.
		delete(p.current)
		p.current = strings.clone(p.key)
	}
	palette_followup(d)
}

// The area changed while matugen ran: its wallpaper may want other colours.
@(private)
palette_followup :: proc(d: ^Daemon) {
	if !d.palette.again { return }
	d.palette.again = false
	if d.area > 0 { palette_update(d, d.area) }
}

@(private)
palette_publish :: proc(d: ^Daemon, pal: config.Wallpaper_Palette, key: string) {
	p := &d.palette
	delete(p.current)
	p.current = strings.clone(key)
	path := config.wallpaper_palette_path()
	if old, ok := config.read_wallpaper_palette(path); ok {
		defer config.destroy_wallpaper_palette(&old)
		if old.light == pal.light && old.dark == pal.dark && old.source == pal.source && old.scheme == pal.scheme { return }
	}
	if !config.write_wallpaper_palette(path, pal) {
		log.warnf("Could not write %s", path)
		return
	}
	log.infof("Wallpaper theme: colours from %s (%s)", pal.source, pal.scheme)
	p.changed = true
}

// Stop a running matugen (reload to another theme, shutdown).
@(private)
palette_stop :: proc(d: ^Daemon) {
	p := &d.palette
	if p.fd >= 0 {
		posix.close(p.fd)
		p.fd = -1
	}
	if p.pid != 0 {
		posix.kill(p.pid, .SIGKILL)
		status: i32
		for posix.waitpid(p.pid, &status, {}) < 0 && posix.errno() == .EINTR {}
		p.pid = 0
	}
	p.again = false
	delete(p.source); p.source = ""
	delete(p.scheme); p.scheme = ""
	delete(p.key); p.key = ""
}

// A matugen that takes too long is stopped (the colours stay as they are).
@(private)
palette_tick :: proc(d: ^Daemon, now: f64) {
	p := &d.palette
	if p.pid == 0 || now < p.deadline { return }
	log.warnf("matugen did not finish within %.0f s; keeping the current colours", MATUGEN_TIMEOUT)
	key := strings.clone(p.key, context.temp_allocator)
	palette_stop(d)
	delete(p.current)
	p.current = strings.clone(key)
	palette_followup(d)
}

@(private)
palette_next_timeout :: proc(d: ^Daemon, now: f64) -> f64 {
	if d.palette.pid == 0 { return -1 }
	return max(d.palette.deadline - now, 0)
}
