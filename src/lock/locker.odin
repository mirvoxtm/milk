// The lock screen: `milk lock`, a separate process like i3lock.
//
// One override-redirect window covers the whole screen with the wallpaper
// (the _XROOTPMAP_ID pixmap, blurred and darkened; a gradient of the theme
// when there is none) and every monitor shows the clock, the date, the user
// and a password field in milk's theme and font. The keyboard and the pointer
// are grabbed; when either grab cannot be had (after retrying for a moment)
// the locker gives up with LOCKER_EXIT_FAILED instead of pretending to lock.
// It stays on top (any window mapped or restacked above it is answered with a
// raise, its own unmapping with a remap and new grabs), follows screen
// changes, owns the _MILK_LOCKER_S<n> selection (one locker per screen) and
// exits with 0 only after a successful authentication. The password is
// checked by a child process (pam.odin), so the clock and the animations keep
// running while PAM works.
//
// When milk's idle manager starts it, $MILK_LOCK_READY_FD names a pipe that
// gets one byte once the screen is covered and grabbed (milk then lets the
// computer suspend).
package lock

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

LOCKER_EXIT_UNLOCKED :: 0
LOCKER_EXIT_FAILED   :: 1 // no display, no grab: the screen is NOT locked
LOCKER_EXIT_ALREADY  :: 3 // another locker holds the screen

READY_FD_ENV :: "MILK_LOCK_READY_FD"

@(private) MAX_PASSWORD  :: 512
@(private) GRAB_TRIES    :: 80   // × 25 ms: keys of the shortcut that started us may still be held
@(private) MESSAGE_TIME  :: 3.0
@(private) SHAKE_TIME    :: 0.45
@(private) CARET_PERIOD  :: 0.53
@(private) DIM_WALLPAPER :: f32(0.55)

@(private)
Lock_State :: enum { Typing, Checking, Wrong }

@(private)
Style :: struct {
	bg, fg, muted, accent, accent_fg, surface, warning: tx.Color,
	text, text_dim: tx.Color, // on the wallpaper
	font:           string,   // fontconfig family (owned by cfg)
	icon_font_file: string,
	clock_format:   string,
	lang:           config.Language,
}

// The UI drawn on one monitor.
@(private)
Panel :: struct {
	mon:        tx.Rect,
	rect:       tx.Rect, // screen coordinates of the area redrawn every frame
	scale:      f32,
	cv:         tx.Canvas,
	pixmap:     xlib.Pixmap,
	ts:         tx.Text_Surface,
	f_clock:    ^tx.Font,
	f_date:     ^tx.Font,
	f_name:     ^tx.Font,
	f_body:     ^tx.Font,
	f_small:    ^tx.Font,
	f_icon:     ^tx.Font,
}

@(private)
Locker :: struct {
	c:            ^tx.Connection,
	cfg:          ^config.Config, // nil when milk.json could not be read
	style:        Style,
	win:          xlib.Window,
	screen:       tx.Rect,
	bg:           tx.Canvas, // blurred wallpaper, screen sized
	bg_pixmap:    xlib.Pixmap,
	panels:       [dynamic]Panel,
	input:        tx.Input,
	selection:    xlib.Atom,
	rr_event:     i32, // RandR event base, -1 = none
	user:         string, // login name (owned)
	display_name: string, // GECOS name or the login name (owned)
	service:      string, // PAM service
	password:     [MAX_PASSWORD]u8,
	pw_len:       int,
	shown_len:    int, // dots drawn while checking (the buffer is already wiped)
	caps:         bool,
	state:        Lock_State,
	message_until: f64,
	shake_start:  f64,
	caret_epoch:  f64,
	auth_pid:     posix.pid_t,
	auth_fd:      posix.FD,
	ready_fd:     posix.FD,
	clock_text:   string, // owned
	date_text:    string, // owned
	next_clock:   f64,
	next_regrab:  f64,
	raise_wanted: bool,
	last_raise:   f64,
	geometry_dirty: bool,
	wallpaper_dirty: bool, // the root pixmap changed (feh after a screen change)
	gc:           xlib.GC,
	drawn_caret:  bool, // the caret as last drawn (it blinks)
	last_frame:   f64,  // tx.now() of the last render (animations run at 60 frames a second at most)
	dirty:        bool,
	done:         bool,
	attempts:     int,
}

// Run the lock screen until the user authenticates. Returns the exit code.
run_locker :: proc(config_path: string) -> int {
	cfg, err := config.load(config_path)
	if err != "" {
		log.warnf("Lock: %s; using the default look", err)
		delete(err)
		cfg = nil
	}
	defer if cfg != nil { config.destroy(cfg) }

	if display, found := os.lookup_env("DISPLAY", context.temp_allocator); !found || display == "" {
		log.error("Lock: DISPLAY is not set; the screen is NOT locked")
		return LOCKER_EXIT_FAILED
	}
	c, ok := tx.connect()
	if !ok {
		log.error("Lock: cannot open the X display; the screen is NOT locked")
		return LOCKER_EXIT_FAILED
	}
	// Losing the X connection must never look like a successful unlock.
	tx.io_error_cleanup = proc() { posix._exit(LOCKER_EXIT_FAILED) }
	defer tx.disconnect(c)
	// Closing the terminal that ran `milk lock` must not unlock the screen.
	posix.signal(.SIGHUP, auto_cast posix.SIG_IGN)
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

	l := new(Locker)
	defer free(l)
	l.c = c
	l.cfg = cfg
	l.auth_fd = -1
	l.ready_fd = ready_fd_from_env()
	l.rr_event = -1
	make_style(l)
	l.service = pam_service()
	user_names(l)
	defer {
		delete(l.user)
		delete(l.display_name)
		delete(l.clock_text)
		delete(l.date_text)
	}

	l.selection = lock_selection(c)
	if xlib.GetSelectionOwner(c.dpy, l.selection) != 0 {
		log.info("Lock: another locker already holds the screen")
		return LOCKER_EXIT_ALREADY
	}
	l.screen = tx.screen_rect(c)
	build_background(l)
	create_window(l)
	defer destroy_window(l)
	xlib.SetSelectionOwner(c.dpy, l.selection, l.win, xlib.CurrentTime)
	if xlib.GetSelectionOwner(c.dpy, l.selection) != l.win {
		log.info("Lock: another locker took the screen first")
		return LOCKER_EXIT_ALREADY
	}
	if !grab_input(l) {
		log.error("Lock: cannot grab the keyboard and the pointer (another program holds them); the screen is NOT locked")
		return LOCKER_EXIT_FAILED
	}
	log.infof("Lock: screen locked (user %s, PAM service %q)", l.user, l.service)
	when TEST_BUILD { log.warn("Lock: TEST BUILD: the password is the compiled-in MILK_LOCK_TEST_PASSWORD, PAM is never called") }
	layout_panels(l)
	defer destroy_panels(l)
	l.caps = caps_lock_on(c)
	update_clock(l, tx.now())
	render(l)
	tx.sync(c)
	signal_ready(l)

	locker_loop(l)

	if l.auth_pid > 0 { finish_auth(l, true) }
	secure_zero(l.password[:])
	xlib.UngrabKeyboard(c.dpy, xlib.CurrentTime)
	xlib.UngrabPointer(c.dpy, xlib.CurrentTime)
	log.info("Lock: unlocked")
	return LOCKER_EXIT_UNLOCKED
}

@(private)
ready_fd_from_env :: proc() -> posix.FD {
	v, found := os.lookup_env(READY_FD_ENV, context.temp_allocator)
	if !found { return -1 }
	n, ok := strconv.parse_int(v, 10)
	if !ok || n < 3 { return -1 }
	os.unset_env(READY_FD_ENV) // children (none today) must not inherit the promise
	return posix.FD(n)
}

@(private)
signal_ready :: proc(l: ^Locker) {
	if l.ready_fd < 0 { return }
	b := [1]u8{'L'}
	posix.write(l.ready_fd, &b[0], 1)
	posix.close(l.ready_fd)
	l.ready_fd = -1
}

@(private)
make_style :: proc(l: ^Locker) {
	s := &l.style
	theme := config.default_bar().theme
	if l.cfg != nil { theme = l.cfg.bar.theme }
	s.bg = tx.color_from_hex(theme.background, tx.rgb(0xF5, 0xEE, 0xE6))
	s.fg = tx.color_from_hex(theme.foreground, tx.rgb(0x3C, 0x3A, 0x38))
	s.muted = tx.color_from_hex(theme.muted, tx.rgb(0xA8, 0x9E, 0x94))
	s.accent = tx.color_from_hex(theme.accent, tx.rgb(0x4A, 0x3F, 0x35))
	s.accent_fg = tx.color_from_hex(theme.accent_foreground, tx.rgb(0xF5, 0xEE, 0xE6))
	s.surface = tx.color_from_hex(theme.surface, tx.rgb(0xE9, 0xE0, 0xD6))
	s.warning = tx.color_from_hex(theme.warning, tx.rgb(0xB5, 0x47, 0x3A))
	s.text = tx.rgba(0xFF, 0xFF, 0xFF, 0xF2)
	s.text_dim = tx.rgba(0xFF, 0xFF, 0xFF, 0xC0)
	if l.cfg != nil {
		s.font = l.cfg.bar.font
		s.icon_font_file = l.cfg.bar.icon_font_file
		s.clock_format = l.cfg.bar.clock_format
		s.lang = l.cfg.bar.language
	} else {
		s.font = "sans"
		s.icon_font_file = ""
		s.clock_format = "%H:%M"
		s.lang = config.resolve_language("auto")
	}
}

@(private)
tr :: proc(l: ^Locker, pt, en: string) -> string { return config.tr(l.style.lang, pt, en) }

// The login name of this process's user and the name shown on the screen.
@(private)
user_names :: proc(l: ^Locker) {
	pw := posix.getpwuid(posix.getuid())
	name := ""
	gecos := ""
	if pw != nil {
		name = string(pw.pw_name)
		gecos = string(pw.pw_gecos)
	}
	if name == "" { name = os.get_env("USER", context.temp_allocator) }
	l.user = strings.clone(name)
	if i := strings.index_byte(gecos, ','); i >= 0 { gecos = gecos[:i] }
	gecos = strings.trim_space(gecos)
	l.display_name = strings.clone(gecos != "" ? gecos : name)
}

// ---------------------------------------------------------------------------
// Window, background and grabs
// ---------------------------------------------------------------------------
@(private)
build_background :: proc(l: ^Locker) {
	c := l.c
	tx.canvas_destroy(&l.bg)
	if pm, ok := tx.root_pixmap(c); ok {
		if cv, grabbed := tx.canvas_grab(c, xlib.Drawable(pm), l.screen); grabbed {
			l.bg = cv
			blur_darken(&l.bg, DIM_WALLPAPER)
			return
		}
	}
	l.bg = tx.canvas_make(l.screen.w, l.screen.h)
	s := &l.style
	fill_fallback(&l.bg, tx.color_mix(s.accent, tx.rgb(0, 0, 0), 0.55), tx.color_mix(s.fg, tx.rgb(0, 0, 0), 0.75))
}

@(private)
create_window :: proc(l: ^Locker) {
	c := l.c
	attrs: xlib.XSetWindowAttributes
	attrs.override_redirect = true
	attrs.background_pixel = c.black
	attrs.event_mask = {.KeyPress, .KeyRelease, .ButtonPress, .Exposure, .StructureNotify, .VisibilityChange}
	r := l.screen
	l.win = xlib.CreateWindow(c.dpy, c.root, r.x, r.y, u32(max(r.w, 1)), u32(max(r.h, 1)), 0, c.depth, .InputOutput, c.visual,
	                          {.CWOverrideRedirect, .CWBackPixel, .CWEventMask}, &attrs)
	hint := xlib.XClassHint{res_name = "milk-lock", res_class = "Milk-lock"}
	xlib.SetClassHint(c.dpy, l.win, &hint)
	xlib.StoreName(c.dpy, l.win, "milk lock")
	tx.set_utf8_string(c, l.win, "_NET_WM_NAME", "milk lock")
	tx.set_atom_list(c, l.win, "_NET_WM_WINDOW_TYPE", {tx.atom(c, "_NET_WM_WINDOW_TYPE_SPLASH")})
	tx.set_atom_list(c, l.win, "_NET_WM_STATE", {tx.atom(c, "_NET_WM_STATE_ABOVE"), tx.atom(c, "_NET_WM_STATE_FULLSCREEN")})
	upload_background(l)
	hide_pointer(c)
	l.input = tx.input_open(c, l.win)
	tx.input_focus(&l.input, true)
	// Windows mapped or restacked above the lock screen, and screen changes.
	xlib.SelectInput(c.dpy, c.root, {.SubstructureNotify, .StructureNotify, .PropertyChange})
	ev_base, err_base: i32
	if XRRQueryExtension(c.dpy, &ev_base, &err_base) {
		l.rr_event = ev_base
		XRRSelectInput(c.dpy, c.root, RR_SCREEN_CHANGE_NOTIFY_MASK | RR_CRTC_CHANGE_NOTIFY_MASK)
	}
	xlib.MapRaised(c.dpy, l.win)
	tx.sync(c)
}

@(private)
upload_background :: proc(l: ^Locker) {
	c := l.c
	tx.pixmap_free(c, l.bg_pixmap)
	l.bg_pixmap = tx.canvas_to_pixmap(c, l.bg)
	xlib.SetWindowBackgroundPixmap(c.dpy, l.win, l.bg_pixmap)
	xlib.ClearWindow(c.dpy, l.win)
}

@(private)
destroy_window :: proc(l: ^Locker) {
	c := l.c
	tx.input_close(&l.input)
	if l.win != 0 {
		xlib.DestroyWindow(c.dpy, l.win)
		l.win = 0
	}
	tx.pixmap_free(c, l.bg_pixmap)
	l.bg_pixmap = 0
	if l.gc != nil { xlib.FreeGC(c.dpy, l.gc) }
	tx.canvas_destroy(&l.bg)
	tx.sync(c)
}

// The pointer is hidden while the screen is locked (XFixes; the server shows
// it again when the locker's connection closes, whatever happens).
@(private)
hide_pointer :: proc(c: ^tx.Connection) {
	ev, er: i32
	if XFixesQueryExtension(c.dpy, &ev, &er) { XFixesHideCursor(c.dpy, c.root) }
}

// Grab the keyboard and the pointer, retrying while someone else holds them
// (the keys of the shortcut that started the locker, an open menu).
@(private)
grab_input :: proc(l: ^Locker) -> bool {
	c := l.c
	keyboard, pointer := false, false
	for attempt in 0 ..< GRAB_TRIES {
		if !keyboard {
			keyboard = xlib.GrabKeyboard(c.dpy, l.win, false, .GrabModeAsync, .GrabModeAsync, xlib.CurrentTime) == 0
		}
		if !pointer {
			pointer = xlib.GrabPointer(c.dpy, l.win, false, {.ButtonPress, .ButtonRelease},
			                           .GrabModeAsync, .GrabModeAsync, 0, 0, xlib.CurrentTime) == 0
		}
		if keyboard && pointer { return true }
		if attempt == 0 { log.debug("Lock: the keyboard or the pointer is grabbed by another program; retrying") }
		time.sleep(25 * time.Millisecond)
	}
	if !keyboard { log.error("Lock: the keyboard stays grabbed by another program") }
	if !pointer { log.error("Lock: the pointer stays grabbed by another program") }
	xlib.UngrabKeyboard(c.dpy, xlib.CurrentTime)
	xlib.UngrabPointer(c.dpy, xlib.CurrentTime)
	return false
}

// Grabs and stacking are re-asserted every second: cheap, and it repairs a
// grab lost to an unmap the locker missed.
@(private)
reassert :: proc(l: ^Locker) {
	c := l.c
	xlib.GrabKeyboard(c.dpy, l.win, false, .GrabModeAsync, .GrabModeAsync, xlib.CurrentTime)
	xlib.GrabPointer(c.dpy, l.win, false, {.ButtonPress, .ButtonRelease}, .GrabModeAsync, .GrabModeAsync, 0, 0, xlib.CurrentTime)
}

// ---------------------------------------------------------------------------
// Event loop
// ---------------------------------------------------------------------------
@(private)
locker_loop :: proc(l: ^Locker) {
	c := l.c
	for !l.done {
		for tx.pending(c) > 0 {
			ev: xlib.XEvent
			tx.next_event(c, &ev)
			if tx.input_filter(&ev) { continue }
			locker_event(l, &ev)
		}
		now := tx.now()
		locker_tick(l, now)
		if l.done { break }
		if l.dirty { render(l) }
		tx.flush(c)
		free_all(context.temp_allocator)

		// Always poll (without waiting when events are queued): the password
		// check's answer must be read even while X keeps the loop busy.
		timeout := tx.pending(c) > 0 ? 0 : locker_timeout(l, now)
		fds: [2]posix.pollfd
		fds[0] = {fd = posix.FD(c.fd), events = {.IN}}
		n := 1
		if l.auth_fd >= 0 {
			fds[1] = {fd = l.auth_fd, events = {.IN}}
			n = 2
		}
		ms := i32(math.ceil(timeout * 1000))
		posix.poll(&fds[0], posix.nfds_t(n), ms)
		if n == 2 && fds[1].revents != {} { auth_done(l) }
	}
}

@(private)
locker_timeout :: proc(l: ^Locker, now: f64) -> f64 {
	t := min(l.next_clock, l.next_regrab) - now
	if l.message_until > now { t = min(t, l.message_until - now) }
	if now - l.shake_start < SHAKE_TIME || l.state == .Checking || l.geometry_dirty || l.wallpaper_dirty || l.raise_wanted {
		t = min(t, 1.0 / 60)
	}
	// Caret blink (on and off for CARET_PERIOD each).
	if l.state != .Checking {
		phase := math.mod(now - l.caret_epoch, CARET_PERIOD)
		t = min(t, CARET_PERIOD - phase + 0.002)
	}
	return clamp(t, 0, 1)
}

@(private)
locker_tick :: proc(l: ^Locker, now: f64) {
	if now >= l.next_clock { update_clock(l, now) }
	if now >= l.next_regrab {
		reassert(l)
		l.next_regrab = now + 1
		l.raise_wanted = true
	}
	if l.raise_wanted && now - l.last_raise >= 0.05 {
		// A window that keeps raising itself must not make us spin: at most
		// 20 raises a second.
		l.raise_wanted = false
		l.last_raise = now
		xlib.RaiseWindow(l.c.dpy, l.win)
	}
	if l.geometry_dirty {
		l.geometry_dirty = false
		screen_changed(l)
	} else if l.wallpaper_dirty {
		l.wallpaper_dirty = false
		build_background(l)
		upload_background(l)
		l.dirty = true
	}
	if l.message_until > 0 && now >= l.message_until {
		l.message_until = 0
		if l.state == .Wrong { l.state = .Typing }
		l.dirty = true
	}
	animating := now - l.shake_start < SHAKE_TIME + 0.05 || l.state == .Checking
	if animating && now - l.last_frame >= 1.0 / 60 { l.dirty = true }
	if caret_visible(l, now) != l.drawn_caret { l.dirty = true }
}

@(private)
update_clock :: proc(l: ^Locker, now: f64) {
	tm, nanos := local_time()
	clock := format_clock(l.style.clock_format, tm, l.style.lang)
	date := long_date(tm, l.style.lang)
	if clock != l.clock_text || date != l.date_text {
		delete(l.clock_text)
		delete(l.date_text)
		l.clock_text = strings.clone(clock)
		l.date_text = strings.clone(date)
		l.dirty = true
	}
	period: i64 = strings.contains(l.style.clock_format, "%S") ? 1 : 60
	period_ns := period * 1_000_000_000
	l.next_clock = now + f64(period_ns - nanos %% period_ns) / 1e9 + 0.005
}

@(private)
locker_event :: proc(l: ^Locker, ev: ^xlib.XEvent) {
	c := l.c
	if l.rr_event >= 0 && i32(ev.type) == l.rr_event + RR_SCREEN_CHANGE_NOTIFY {
		XRRUpdateConfiguration(ev)
		l.geometry_dirty = true
		return
	}
	if l.rr_event >= 0 && i32(ev.type) == l.rr_event + RR_NOTIFY {
		l.geometry_dirty = true // a monitor was turned on, off or moved
		return
	}
	#partial switch ev.type {
	case .KeyPress:
		on_key(l, &ev.xkey)
	case .KeyRelease:
		set_caps(l, .LockMask in ev.xkey.state)
	case .Expose:
		if ev.xexpose.window == l.win && ev.xexpose.count == 0 { l.dirty = true }
	case .MapNotify:
		if ev.xmap.window != l.win { l.raise_wanted = true }
	case .ConfigureNotify:
		if ev.xconfigure.window == c.root {
			if ev.xconfigure.width != l.screen.w || ev.xconfigure.height != l.screen.h { l.geometry_dirty = true }
		} else if ev.xconfigure.window != l.win {
			l.raise_wanted = true
		}
	case .CirculateNotify:
		if ev.xcirculate.window != l.win { l.raise_wanted = true }
	case .VisibilityNotify:
		if ev.xvisibility.window == l.win && ev.xvisibility.state != .VisibilityUnobscured { l.raise_wanted = true }
	case .UnmapNotify:
		// Someone unmapped the lock screen (which also ends the grabs).
		if ev.xunmap.window == l.win {
			log.warn("Lock: the lock screen was unmapped; mapping it again")
			xlib.MapRaised(c.dpy, l.win)
			tx.sync(c)
			reassert(l)
			l.dirty = true
		}
	case .PropertyNotify:
		if ev.xproperty.window == c.root {
			name := tx.atom_name(c, ev.xproperty.atom)
			if name == "_XROOTPMAP_ID" || name == "ESETROOT_PMAP_ID" { l.wallpaper_dirty = true }
		}
	case .SelectionClear:
		// Another program took the selection: keep locking all the same.
		if ev.xselectionclear.window == l.win {
			xlib.SetSelectionOwner(c.dpy, l.selection, l.win, xlib.CurrentTime)
		}
	}
}

// Caps Lock before any key is pressed (the pointer query reports the modifiers).
@(private)
caps_lock_on :: proc(c: ^tx.Connection) -> bool {
	root, child: xlib.Window
	rx, ry, wx, wy: i32
	mask: xlib.KeyMask
	if !xlib.QueryPointer(c.dpy, c.root, &root, &child, &rx, &ry, &wx, &wy, &mask) { return false }
	return u32(mask) & (1 << 1) != 0 // LockMask
}

@(private)
set_caps :: proc(l: ^Locker, on: bool) {
	if l.caps == on { return }
	l.caps = on
	l.dirty = true
}

@(private)
on_key :: proc(l: ^Locker, ke: ^xlib.XKeyEvent) {
	text, sym := tx.input_lookup(&l.input, ke)
	if sym == .XK_Caps_Lock {
		// The modifier changes after this press; the release reports it.
		return
	}
	set_caps(l, .LockMask in ke.state)
	if l.state == .Checking { return }
	ctrl := .ControlMask in ke.state
	l.caret_epoch = tx.now()
	l.dirty = true
	#partial switch sym {
	case .XK_Return, .XK_KP_Enter:
		submit(l)
		return
	case .XK_Escape:
		clear_password(l)
		return
	case .XK_BackSpace:
		if ctrl {
			clear_password(l)
		} else if l.pw_len > 0 {
			// Remove the last UTF-8 character.
			n := l.pw_len - 1
			for n > 0 && (l.password[n] & 0xC0) == 0x80 { n -= 1 }
			secure_zero(l.password[n:l.pw_len])
			l.pw_len = n
		}
		return
	}
	if ctrl && (sym == .XK_u || sym == .XK_U) {
		clear_password(l)
		return
	}
	if text == "" { return }
	// Control characters (Tab, Ctrl+letter) are not part of a password.
	for r in text { if r < 0x20 || r == 0x7F { return } }
	if l.pw_len + len(text) > MAX_PASSWORD { return }
	copy(l.password[l.pw_len:], text)
	l.pw_len += len(text)
	secure_zero(transmute([]u8)text) // the lookup's copy in the temp allocator
	if l.state == .Wrong {
		l.state = .Typing
		l.message_until = 0
	}
}

@(private)
clear_password :: proc(l: ^Locker) {
	secure_zero(l.password[:l.pw_len])
	l.pw_len = 0
	if l.state == .Wrong {
		l.state = .Typing
		l.message_until = 0
	}
	l.dirty = true
}

// ---------------------------------------------------------------------------
// Authentication (in a child process)
// ---------------------------------------------------------------------------
@(private)
submit :: proc(l: ^Locker) {
	if l.pw_len == 0 || l.auth_pid > 0 { return }
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		log.error("Lock: cannot create a pipe for the password check")
		return
	}
	// PAM's helpers (unix_chkpwd) must not inherit the pipe.
	posix.fcntl(fds[0], .SETFD, posix.FD_CLOEXEC)
	posix.fcntl(fds[1], .SETFD, posix.FD_CLOEXEC)
	l.attempts += 1
	pid := posix.fork()
	if pid < 0 {
		posix.close(fds[0])
		posix.close(fds[1])
		log.error("Lock: cannot start the password check (fork failed)")
		return
	}
	if pid == 0 {
		// Child: no X, no output except the verdict byte.
		posix.close(fds[0])
		ok := authenticate(l.user, l.password[:l.pw_len], l.service)
		secure_zero(l.password[:])
		b := [1]u8{ok ? '1' : '0'}
		posix.write(fds[1], &b[0], 1)
		posix._exit(0)
	}
	posix.close(fds[1])
	l.auth_pid = pid
	l.auth_fd = fds[0]
	l.shown_len = utf8.rune_count(string(l.password[:l.pw_len]))
	secure_zero(l.password[:l.pw_len])
	l.pw_len = 0
	l.state = .Checking
	l.message_until = 0
	l.dirty = true
}

@(private)
auth_done :: proc(l: ^Locker) {
	b: [1]u8
	n := posix.read(l.auth_fd, &b[0], 1)
	ok := n == 1 && b[0] == '1'
	if n != 1 { log.warn("Lock: the password check ended without an answer") }
	finish_auth(l, false)
	l.shown_len = 0
	if ok {
		log.infof("Lock: authenticated after %d attempt(s)", l.attempts)
		l.done = true
		return
	}
	log.info("Lock: wrong password")
	l.state = .Wrong
	now := tx.now()
	l.message_until = now + MESSAGE_TIME
	l.shake_start = now
	l.caret_epoch = now
	l.dirty = true
}

@(private)
finish_auth :: proc(l: ^Locker, kill: bool) {
	if l.auth_fd >= 0 {
		posix.close(l.auth_fd)
		l.auth_fd = -1
	}
	if l.auth_pid > 0 {
		if kill { posix.kill(l.auth_pid, .SIGKILL) }
		status: i32
		posix.waitpid(l.auth_pid, &status, {})
		l.auth_pid = 0
	}
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------
@(private)
screen_changed :: proc(l: ^Locker) {
	c := l.c
	screen := tx.screen_rect(c)
	if screen == l.screen && same_monitors(l) { return } // a CRTC event that changed nothing here
	log.infof("Lock: the screen changed to %dx%d", screen.w, screen.h)
	l.screen = screen
	tx.move_resize(c, l.win, screen)
	build_background(l)
	upload_background(l)
	layout_panels(l)
	l.raise_wanted = true
	l.dirty = true
}

// Whether the panels still match the monitors.
@(private)
same_monitors :: proc(l: ^Locker) -> bool {
	mons := tx.monitors(l.c)
	n := 0
	for m in mons {
		found := false
		for p in l.panels { if p.mon == m.rect { found = true } }
		if !found { return false }
		n += 1
	}
	for p in l.panels {
		found := false
		for m in mons { if m.rect == p.mon { found = true } }
		if !found { return false }
	}
	return n > 0
}

@(private)
layout_panels :: proc(l: ^Locker) {
	destroy_panels(l)
	c := l.c
	for m in tx.monitors(c) {
		// Mirrored outputs share a rectangle: one panel is enough.
		dup := false
		for p in l.panels { if p.mon == m.rect { dup = true } }
		if dup { continue }
		p: Panel
		p.mon = m.rect
		p.scale = clamp(f32(m.rect.h) / 1080, 0.55, 2.2)
		s := p.scale
		w := min(m.rect.w - 40, i32(760 * s))
		top := m.rect.y + i32(f32(m.rect.h) * 0.11)
		bottom := m.rect.y + i32(f32(m.rect.h) * 0.86)
		p.rect = {m.rect.x + (m.rect.w - w) / 2, top, w, bottom - top}
		if r, ok := tx.rect_intersect(p.rect, l.screen); ok { p.rect = r } else { continue }
		font := l.style.font
		p.f_clock = open_font(c, fmt.tprintf("%s:light", font), i32(128 * s))
		p.f_date = open_font(c, font, i32(26 * s))
		p.f_name = open_font(c, fmt.tprintf("%s:medium", font), i32(23 * s))
		p.f_body = open_font(c, font, i32(18 * s))
		p.f_small = open_font(c, font, i32(15 * s))
		if l.style.icon_font_file != "" && os.is_file(l.style.icon_font_file) {
			p.f_icon, _ = tx.font_open_file(c, l.style.icon_font_file, i32(50 * s))
		}
		p.cv = tx.canvas_make(p.rect.w, p.rect.h)
		p.pixmap = xlib.CreatePixmap(c.dpy, xlib.Drawable(c.root), u32(p.rect.w), u32(p.rect.h), u32(c.depth))
		p.ts = tx.text_surface_make(c, xlib.Drawable(p.pixmap))
		append(&l.panels, p)
	}
}

@(private)
open_font :: proc(c: ^tx.Connection, pattern: string, px: i32) -> ^tx.Font {
	f, ok := tx.font_open(c, pattern, max(px, 6))
	if !ok { f, _ = tx.font_open(c, "sans", max(px, 6)) }
	return f
}

@(private)
destroy_panels :: proc(l: ^Locker) {
	c := l.c
	for &p in l.panels {
		tx.text_surface_destroy(&p.ts)
		tx.pixmap_free(c, p.pixmap)
		tx.canvas_destroy(&p.cv)
		for f in ([]^tx.Font{p.f_clock, p.f_date, p.f_name, p.f_body, p.f_small, p.f_icon}) {
			if f != nil { tx.font_close(c, f) }
		}
	}
	clear(&l.panels)
	delete(l.panels)
	l.panels = nil
}
