// MILK for Linux / X11.
//
// One binary, one event loop: the built-in dwm-inspired window manager
// (package wm), the workspace daemon (per-area wallpaper, shortcuts,
// indicator — package desktop) and the status bar (package bar) share a
// single X connection and are driven from here.
//
// Code lives in the clone; runtime data lives in <Documents>/milk/runtime
// (or --runtime-root / $MILK_RUNTIME), mirroring the Windows launchers.
package milk

import "core:c"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import xlib "vendor:x11/xlib"

import bar "../bar"
import clip "../clip"
import config "../config"
import desktop "../desktop"
import notify "../notify"
import oobe "../oobe"
import tx "../tx"
import wm "../wm"

VERSION  :: "0.1.0"

// filepath.join returns an allocator error too; milk never runs out of memory here.
join :: proc(elems: []string, allocator := context.temp_allocator) -> string {
	s, _ := filepath.join(elems, allocator)
	return s
}
PID_NAME :: "milk.pid"
LOG_NAME :: "milk.log"
LEGACY_PID_NAME :: "Temenos.pid"

Options :: struct {
	command:      string,
	value:        string,
	runtime_root: string,
	config_path:  string,
	foreground:   bool,
	no_bar:       bool,
	no_wm:        bool,
	no_setup:     bool,
	verbose:      bool,
}

usage :: proc() {
	fmt.eprintln(`milk - per-workspace wallpapers, shortcuts, indicator and bar for X11

usage: milk [command] [options]

commands:
  start        run in the background, replacing a running instance   [default]
  restart      same as start
  stop         stop the running instance
  status       show whether milk is running and the active area
  reload       re-read milk.json in the running instance
  test         print diagnostics (active area, wallpaper, shortcuts, window manager)
  setup        run the setup wizard (theme, wallpapers, bar, keyboard) now
  settings     open the settings app
  switch N     ask the window manager to activate area N
  version      print the version

options:
  --foreground, -f     stay attached to the terminal and log to stderr
  --no-bar             do not start the bar
  --no-wm              do not act as the window manager (use dwm/openbox instead)
  --no-setup           skip the first-run setup wizard
  --runtime-root DIR   runtime data directory (default: <Documents>/milk/runtime or $MILK_RUNTIME)
  --config FILE        configuration file (default: milk.json next to the binary's parent directory)
  --verbose, -v        debug logging`)
}

main :: proc() {
	opts, ok := parse_args(os.args[1:])
	if !ok {
		usage()
		os.exit(2)
	}
	if opts.runtime_root == "" { opts.runtime_root = default_runtime_root() }
	if opts.config_path == "" { opts.config_path = default_config_path() }

	code := 0
	switch opts.command {
	case "start", "restart": code = cmd_start(&opts)
	case "stop":             code = cmd_stop(&opts)
	case "status":           code = cmd_status(&opts)
	case "reload":           code = cmd_reload(&opts)
	case "test":             code = cmd_test(&opts)
	case "switch":           code = cmd_switch(&opts)
	case "setup":            code = cmd_setup(&opts)
	case "settings":         code = cmd_settings(&opts)
	case "version":          fmt.println("milk", VERSION)
	case "help":             usage()
	case:
		fmt.eprintfln("unknown command: %s", opts.command)
		usage()
		code = 2
	}
	os.exit(code)
}

parse_args :: proc(args: []string) -> (opts: Options, ok: bool) {
	opts.command = "start"
	positional := 0
	i := 0
	for i < len(args) {
		a := args[i]
		switch a {
		case "--foreground", "-f": opts.foreground = true
		case "--no-bar":           opts.no_bar = true
		case "--no-wm":            opts.no_wm = true
		case "--no-setup":         opts.no_setup = true
		case "--verbose", "-v":    opts.verbose = true
		case "--help", "-h":       opts.command = "help"
		case "--runtime-root", "--config":
			if i + 1 >= len(args) {
				fmt.eprintfln("%s needs a value", a)
				return opts, false
			}
			i += 1
			if a == "--config" { opts.config_path = args[i] } else { opts.runtime_root = args[i] }
		case:
			if strings.has_prefix(a, "-") {
				fmt.eprintfln("unknown option: %s", a)
				return opts, false
			}
			switch positional {
			case 0: opts.command = a
			case 1: opts.value = a
			case:
				fmt.eprintfln("unexpected argument: %s", a)
				return opts, false
			}
			positional += 1
		}
		i += 1
	}
	return opts, true
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------
home_dir :: proc() -> string {
	if v, found := os.lookup_env("HOME", context.temp_allocator); found && v != "" { return v }
	return "/"
}

// XDG_<KEY>_DIR from ~/.config/user-dirs.dirs (e.g. "DOCUMENTS" -> ~/Documentos on this system).
xdg_user_dir :: proc(key: string, fallback: string) -> string {
	config_home, found := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
	if !found || config_home == "" { config_home = join({home_dir(), ".config"}) }
	path := join({config_home, "user-dirs.dirs"})
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return fallback }
	wanted := fmt.tprintf("XDG_%s_DIR=", key)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, wanted) { continue }
		value := strings.trim(trimmed[len(wanted):], "\"")
		value, _ = strings.replace_all(value, "$HOME", home_dir(), context.temp_allocator)
		if value != "" { return value }
	}
	return fallback
}

default_runtime_root :: proc() -> string {
	for name in ([]string{"MILK_RUNTIME", "TEMENOS_RUNTIME"}) {
		if env, found := os.lookup_env(name, context.temp_allocator); found && env != "" {
			return strings.clone(env)
		}
	}
	documents := xdg_user_dir("DOCUMENTS", join({home_dir(), "Documents"}))
	runtime := join({documents, "milk", "runtime"}, context.allocator)
	// Runtime data from before the rename keeps working until it is moved.
	legacy := join({documents, "Temenos", "runtime"})
	if !os.is_directory(runtime) && os.is_directory(legacy) {
		delete(runtime)
		return strings.clone(legacy)
	}
	return runtime
}

default_config_path :: proc() -> string {
	if exe_dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		candidates := [?]string{
			join({exe_dir, "..", "milk.json"}),
			join({exe_dir, "milk.json"}),
			join({exe_dir, "..", "Temenos.json"}),
		}
		for candidate in candidates {
			if os.is_file(candidate) {
				cleaned, _ := filepath.clean(candidate)
				return cleaned
			}
		}
	}
	return strings.clone("milk.json")
}

find_in_path :: proc(name: string) -> (string, bool) {
	path_env, found := os.lookup_env("PATH", context.temp_allocator)
	if !found { return "", false }
	for dir in strings.split(path_env, ":", context.temp_allocator) {
		candidate := join({dir, name})
		if os.is_file(candidate) { return candidate, true }
	}
	return "", false
}

// ---------------------------------------------------------------------------
// Single instance (PID file), like the Windows implementation
// ---------------------------------------------------------------------------
read_pid :: proc(pid_file: string) -> (int, bool) {
	data, err := os.read_entire_file(pid_file, context.temp_allocator)
	if err != nil { return 0, false }
	pid, ok := strconv.parse_int(strings.trim_space(string(data)), 10)
	return pid, ok && pid > 0
}

pid_alive :: proc(pid: int) -> bool {
	if posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK { return true }
	return posix.errno() == .EPERM
}

is_milk :: proc(pid: int) -> bool {
	data, err := os.read_entire_file(fmt.tprintf("/proc/%d/cmdline", pid), context.temp_allocator)
	if err != nil { return false }
	return strings.contains(string(data), "milk") || strings.contains(string(data), "temenos")
}

running_pid :: proc(pid_file: string) -> (int, bool) {
	pid, ok := read_pid(pid_file)
	if !ok || !pid_alive(pid) || !is_milk(pid) { return 0, false }
	return pid, true
}

// Terminate a previous instance (SIGTERM, then SIGKILL after 2 s).
stop_instance :: proc(pid_file: string) -> (stopped: bool) {
	pid, ok := running_pid(pid_file)
	if !ok || pid == os.get_pid() { return false }
	posix.kill(posix.pid_t(pid), .SIGTERM)
	for _ in 0 ..< 40 {
		time.sleep(50 * time.Millisecond)
		if !pid_alive(pid) { return true }
	}
	posix.kill(posix.pid_t(pid), .SIGKILL)
	time.sleep(200 * time.Millisecond)
	return true
}

write_pid :: proc(pid_file: string) -> bool {
	return os.write_entire_file(pid_file, fmt.tprintf("%d\n", os.get_pid())) == nil
}

remove_pid :: proc(pid_file: string) {
	if pid, ok := read_pid(pid_file); ok && pid == os.get_pid() {
		os.remove(pid_file)
	}
}

// ---------------------------------------------------------------------------
// Signals and daemonising
// ---------------------------------------------------------------------------
g_stop:    bool
g_reload:  bool
g_wake_fd: posix.FD = -1
g_pid_file: string

signal_handler :: proc "c" (sig: posix.Signal) {
	#partial switch sig {
	case .SIGTERM, .SIGINT: g_stop = true
	case .SIGHUP:           g_reload = true
	case:
	}
	if g_wake_fd >= 0 {
		b: [1]u8 = {1}
		posix.write(g_wake_fd, &b[0], 1)
	}
}

// Self-pipe so that poll() wakes up on signals; SIGCHLD is caught (no-op) so
// children stay reapable by the modules that spawned them.
install_signals :: proc() -> (wake_read: posix.FD, ok: bool) {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK { return -1, false }
	for fd in fds {
		flags := posix.fcntl(fd, .GETFL)
		posix.fcntl(fd, .SETFL, flags | c.int(posix.O_NONBLOCK))
	}
	g_wake_fd = fds[1]
	act: posix.sigaction_t
	act.sa_handler = signal_handler
	posix.sigemptyset(&act.sa_mask)
	act.sa_flags = {.RESTART}
	for sig in ([]posix.Signal{.SIGTERM, .SIGINT, .SIGHUP, .SIGCHLD}) {
		posix.sigaction(sig, &act, nil)
	}
	ignore: posix.sigaction_t
	ignore.sa_handler = proc "c" (_: posix.Signal) {}
	posix.sigemptyset(&ignore.sa_mask)
	ignore.sa_flags = {.RESTART}
	posix.sigaction(.SIGPIPE, &ignore, nil)
	return fds[0], true
}

daemonize :: proc(log_path: string) -> bool {
	pid := posix.fork()
	if pid < 0 { return false }
	if pid > 0 { posix._exit(0) }
	posix.setsid()
	pid = posix.fork()
	if pid < 0 { return false }
	if pid > 0 { posix._exit(0) }
	posix.chdir("/")
	null := posix.open("/dev/null", {})
	clog := strings.clone_to_cstring(log_path, context.temp_allocator)
	logfd := posix.open(clog, {.WRONLY, .CREAT, .TRUNC}, posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if null >= 0 {
		posix.dup2(null, 0)
		posix.close(null)
	}
	if logfd >= 0 {
		posix.dup2(logfd, 1)
		posix.dup2(logfd, 2)
		posix.close(logfd)
	}
	return true
}

// Assigning context.logger only affects the current scope, so the caller sets it.
make_logger :: proc(opts: ^Options) -> log.Logger {
	level := opts.verbose ? log.Level.Debug : log.Level.Info
	options := opts.foreground ? log.Options{.Level, .Terminal_Color} : log.Options{.Level, .Date, .Time}
	return log.create_console_logger(level, options)
}

// ---------------------------------------------------------------------------
// start
// ---------------------------------------------------------------------------
cmd_start :: proc(opts: ^Options) -> int {
	cfg, err := config.load(opts.config_path)
	if err != "" {
		fmt.eprintfln("milk: %s", err)
		return 1
	}
	if display, found := os.lookup_env("DISPLAY", context.temp_allocator); !found || display == "" {
		fmt.eprintln("milk: DISPLAY is not set; start it from an X session (.xinitrc, openbox autostart).")
		return 1
	}
	if !os.is_directory(opts.runtime_root) {
		if mkerr := os.make_directory_all(opts.runtime_root); mkerr != nil && mkerr != .Exist {
			fmt.eprintfln("milk: could not create %s: %v", opts.runtime_root, mkerr)
			return 1
		}
	}
	if !opts.foreground {
		if !daemonize(join({opts.runtime_root, LOG_NAME})) {
			fmt.eprintln("milk: could not fork into the background")
			return 1
		}
	}
	context.logger = make_logger(opts)
	return run(opts, cfg)
}

Runner :: struct {
	opts:    ^Options,
	cfg:     ^config.Config,
	c:       ^tx.Connection,
	manager: ^wm.Manager,
	daemon:  ^desktop.Daemon,
	bar:     ^bar.Bar,
	notes:   ^notify.Notifier,
	clips:   ^clip.Clipboard,
	wake_fd: posix.FD,
}

// The strip the bar occupies on its monitor, which the window manager must keep free.
bar_reservation :: proc(cfg: ^config.Config, opts: ^Options) -> (monitor: string, top, bottom: i32) {
	if !cfg.bar.enabled || opts.no_bar { return cfg.bar.monitor, 0, 0 }
	size := i32(cfg.bar.height)
	if cfg.bar.style == "floating" { size += i32(cfg.bar.margin) }
	if cfg.bar.position == "bottom" { return cfg.bar.monitor, 0, size }
	return cfg.bar.monitor, size, 0
}

// setxkbmap from the keyboard section (empty fields keep the server's setting).
apply_keyboard :: proc(cfg: ^config.Config) {
	kb := &cfg.keyboard
	if kb.layout == "" && kb.variant == "" && kb.model == "" && kb.options == "" { return }
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "setxkbmap")
	if kb.layout != ""  { append(&argv, "-layout", kb.layout) }
	if kb.variant != "" { append(&argv, "-variant", kb.variant) }
	if kb.model != ""   { append(&argv, "-model", kb.model) }
	if kb.options != "" { append(&argv, "-option", "", "-option", kb.options) }
	process, err := os.process_start({command = argv[:]})
	if err != nil {
		log.warnf("Could not run setxkbmap: %v", err)
		return
	}
	state, _ := os.process_wait(process, 5 * time.Second)
	if state.exit_code != 0 { log.warnf("setxkbmap exited with %d", state.exit_code) }
}

// Bar clicks on the bell and the clipboard open their panels.
bar_click :: proc(data: rawptr, id: string, anchor: tx.Rect) -> bool {
	r := (^Runner)(data)
	switch id {
	case "notifications":
		if r.notes == nil { return false }
		if r.clips != nil { clip.close_panel(r.clips) }
		if r.bar != nil { bar.close_popups(r.bar) }
		notify.toggle_panel(r.notes)
		return true
	case "clipboard":
		if r.clips == nil { return false }
		if r.notes != nil { notify.close_panel(r.notes) }
		if r.bar != nil { bar.close_popups(r.bar) }
		clip.toggle_panel(r.clips, anchor)
		return true
	}
	return false
}

create_bar :: proc(r: ^Runner) {
	b, ok := bar.create(r.c, r.cfg)
	if !ok {
		log.warn("The bar could not be created; continuing without it")
		return
	}
	r.bar = b
	bar.set_config_path(b, r.opts.config_path)
	bar.set_click_handler(b, bar_click, r)
}

run :: proc(opts: ^Options, cfg: ^config.Config) -> int {
	// Everything milk starts (the settings app from the gear card, helper
	// scripts) finds this instance's runtime folder, pid file included.
	os.set_env("MILK_RUNTIME", opts.runtime_root)
	pid_file := join({opts.runtime_root, PID_NAME}, context.allocator)
	g_pid_file = pid_file
	if stop_instance(pid_file) { log.info("Replaced the previous milk instance") }
	// An instance started before the rename to milk records itself as Temenos.pid.
	if stop_instance(join({opts.runtime_root, LEGACY_PID_NAME})) { log.info("Replaced the running Temenos instance") }
	if !write_pid(pid_file) { log.warnf("Could not write %s", pid_file) }
	defer remove_pid(pid_file)

	c, connected := tx.connect()
	if !connected {
		log.error("Could not open the X display")
		return 1
	}
	tx.io_error_cleanup = proc() { remove_pid(g_pid_file) }
	defer tx.disconnect(c)

	cfg := cfg
	apply_keyboard(cfg)
	// First run: the setup wizard (theme, wallpapers, bar, keyboard) comes
	// before the window manager; its choices are read back from milk.json.
	if !opts.no_setup && oobe.needed(opts.runtime_root) {
		log.info("First run: starting the setup wizard")
		oobe.app_version = VERSION
		if oobe.run(c, opts.config_path, opts.runtime_root) {
			if fresh, err := config.load(opts.config_path); err == "" {
				config.destroy(cfg)
				cfg = fresh
				apply_keyboard(cfg)
			} else {
				log.errorf("The setup wizard wrote an invalid configuration (%s); keeping the previous one", err)
			}
		}
	}

	write_rofi_theme(cfg)
	r := Runner{opts = opts, cfg = cfg, c = c}
	mask := desktop.ROOT_EVENT_MASK
	if cfg.bar.enabled && !opts.no_bar { mask |= bar.ROOT_EVENT_MASK }
	if cfg.wm.enabled && !opts.no_wm { mask |= wm.ROOT_EVENT_MASK }
	xlib.SelectInput(c.dpy, c.root, mask)

	// The window manager comes first: the bar and the desktop layer read the
	// EWMH properties it publishes.
	if cfg.wm.enabled && !opts.no_wm {
		if m, wok := wm.create(c, cfg); wok {
			r.manager = m
			monitor, top, bottom := bar_reservation(cfg, opts)
			wm.set_reserved(m, monitor, top, bottom)
			wm.start(m)
		} else {
			log.warn("Another window manager is running; the built-in one stays off (use --no-wm or wm.enabled=false to silence this)")
			fallback := desktop.ROOT_EVENT_MASK
			if cfg.bar.enabled && !opts.no_bar { fallback |= bar.ROOT_EVENT_MASK }
			xlib.SelectInput(c.dpy, c.root, fallback)
		}
	}
	defer if r.manager != nil { wm.destroy(r.manager) }

	daemon, dok := desktop.create(c, cfg, opts.runtime_root)
	if !dok {
		log.error("Could not initialise the desktop daemon")
		return 1
	}
	r.daemon = daemon
	defer desktop.destroy(daemon)

	if cfg.bar.enabled && !opts.no_bar { create_bar(&r) }
	defer if r.bar != nil { bar.destroy(r.bar) }

	if cfg.notifications.enabled {
		if n, nok := notify.create(c, cfg); nok { r.notes = n }
	}
	defer if r.notes != nil { notify.destroy(r.notes) }
	if cfg.clipboard.enabled {
		if cb, cok := clip.create(c, cfg, opts.runtime_root); cok { r.clips = cb }
	}
	defer if r.clips != nil { clip.destroy(r.clips) }

	wake_read, sig_ok := install_signals()
	if !sig_ok {
		log.error("Could not install signal handlers")
		return 1
	}
	r.wake_fd = wake_read

	wm_label := tx.wm_name(c)
	if r.manager != nil { wm_label = "built-in" }
	log.infof("milk %s started (pid %d, wm %s, runtime %s)", VERSION, os.get_pid(), wm_label == "" ? "unknown" : wm_label, opts.runtime_root)
	// The bar first: the desktop layer and the area toast keep clear of it.
	if r.bar != nil { bar.start(r.bar) }
	desktop.start(daemon)
	if r.notes != nil { notify.start(r.notes) }
	if r.clips != nil { clip.start(r.clips) }
	loop(&r)
	log.info("milk stopped")
	return 0
}

loop :: proc(r: ^Runner) {
	conn := r.c
	for !g_stop {
		for tx.pending(conn) > 0 {
			ev: xlib.XEvent
			tx.next_event(conn, &ev)
			// Dead keys typed into milk's text fields (the Wi-Fi password)
			// are consumed by the input method and come back composed.
			if tx.input_filter(&ev) { continue }
			if r.manager != nil { wm.handle_event(r.manager, &ev) }
			desktop.handle_event(r.daemon, &ev)
			if r.bar != nil { bar.handle_event(r.bar, &ev) }
			if r.notes != nil { notify.handle_event(r.notes, &ev) }
			if r.clips != nil { clip.handle_event(r.clips, &ev) }
			if g_stop { break }
		}
		if r.manager != nil {
			if wm.quit_requested(r.manager) { g_stop = true }
			if wm.reload_requested(r.manager) { g_reload = true }
			switch wm.panel_requested(r.manager) {
			case "clipboard":
				if r.clips != nil {
					if r.notes != nil { notify.close_panel(r.notes) }
					if r.bar != nil { bar.close_popups(r.bar) }
					clip.open_panel_centered(r.clips)
				}
			case "notifications":
				if r.notes != nil {
					if r.clips != nil { clip.close_panel(r.clips) }
					if r.bar != nil { bar.close_popups(r.bar) }
					notify.toggle_panel(r.notes)
				}
			}
		}
		if r.bar != nil && bar.reload_requested(r.bar) { g_reload = true }
		if g_reload {
			g_reload = false
			reload(r)
		}
		now := tx.now()
		if r.manager != nil { wm.tick(r.manager, now) }
		desktop.tick(r.daemon, now)
		if r.bar != nil { bar.tick(r.bar, now) }
		if r.notes != nil { notify.tick(r.notes, now) }
		if r.clips != nil { clip.tick(r.clips, now) }
		if r.bar != nil && r.notes != nil { bar.set_badge(r.bar, "notifications", notify.unread_count(r.notes)) }

		timeout := desktop.next_timeout(r.daemon, now)
		if r.bar != nil {
			bt := bar.next_timeout(r.bar, now)
			if bt >= 0 && (timeout < 0 || bt < timeout) { timeout = bt }
		}
		if r.manager != nil {
			wt := wm.next_timeout(r.manager, now)
			if wt >= 0 && (timeout < 0 || wt < timeout) { timeout = wt }
		}
		if r.notes != nil {
			nt := notify.next_timeout(r.notes, now)
			if nt >= 0 && (timeout < 0 || nt < timeout) { timeout = nt }
		}
		if r.clips != nil {
			ct := clip.next_timeout(r.clips, now)
			if ct >= 0 && (timeout < 0 || ct < timeout) { timeout = ct }
		}

		// Everything allocated from the temp allocator during this iteration is
		// released here; the poll set is built afterwards so it stays valid.
		free_all(context.temp_allocator)
		fds := make([dynamic]posix.pollfd, context.temp_allocator)
		append(&fds, posix.pollfd{fd = posix.FD(conn.fd), events = {.IN}})
		append(&fds, posix.pollfd{fd = r.wake_fd, events = {.IN}})
		bar_fds := 0
		if r.bar != nil {
			for fd in bar.poll_fds(r.bar) { append(&fds, posix.pollfd{fd = posix.FD(fd), events = {.IN}}) }
			bar_fds = len(fds) - 2
		}
		if r.notes != nil {
			for fd in notify.poll_fds(r.notes) { append(&fds, posix.pollfd{fd = posix.FD(fd), events = {.IN}}) }
		}
		if tx.pending(conn) > 0 { continue }

		timeout_ms: c.int = -1
		if timeout >= 0 { timeout_ms = c.int(timeout * 1000) + 1 }
		n := posix.poll(raw_data(fds), posix.nfds_t(len(fds)), timeout_ms)
		if n <= 0 { continue }
		if fds[1].revents != {} {
			buf: [64]u8
			for posix.read(r.wake_fd, &buf[0], len(buf)) > 0 {}
		}
		for pf, i in fds[2:] {
			if pf.revents == {} { continue }
			if i < bar_fds {
				if r.bar != nil { bar.handle_fd(r.bar, i32(pf.fd)) }
			} else if r.notes != nil {
				notify.handle_fd(r.notes, i32(pf.fd))
			}
		}
	}
}

reload :: proc(r: ^Runner) {
	cfg, err := config.load(r.opts.config_path)
	if err != "" {
		log.errorf("Reload failed, keeping the previous configuration: %s", err)
		return
	}
	old := r.cfg
	r.cfg = cfg
	if r.manager != nil {
		monitor, top, bottom := bar_reservation(cfg, r.opts)
		wm.set_reserved(r.manager, monitor, top, bottom)
		wm.reload(r.manager, cfg)
	}
	desktop.reload(r.daemon, cfg)
	want_bar := cfg.bar.enabled && !r.opts.no_bar
	if r.bar != nil && !want_bar {
		bar.destroy(r.bar)
		r.bar = nil
	} else if r.bar != nil {
		bar.reload(r.bar, cfg)
	} else if want_bar {
		create_bar(r)
		if r.bar != nil { bar.start(r.bar) }
	}
	if r.notes != nil { notify.reload(r.notes, cfg) }
	if r.clips != nil { clip.reload(r.clips, cfg) }
	apply_keyboard(cfg)
	write_rofi_theme(cfg)
	config.destroy(old)
	log.info("Configuration reloaded")
}

// ---------------------------------------------------------------------------
// stop / status / reload / switch / test
// ---------------------------------------------------------------------------
cmd_stop :: proc(opts: ^Options) -> int {
	pid_file := join({opts.runtime_root, PID_NAME})
	if stop_instance(pid_file) || stop_instance(join({opts.runtime_root, LEGACY_PID_NAME})) {
		fmt.println("milk stopped")
		return 0
	}
	fmt.println("milk is not running")
	return 1
}

cmd_reload :: proc(opts: ^Options) -> int {
	pid_file := join({opts.runtime_root, PID_NAME})
	pid, ok := running_pid(pid_file)
	if !ok {
		fmt.println("milk is not running")
		return 1
	}
	posix.kill(posix.pid_t(pid), .SIGHUP)
	fmt.printfln("Reload requested (pid %d)", pid)
	return 0
}

cmd_status :: proc(opts: ^Options) -> int {
	pid_file := join({opts.runtime_root, PID_NAME})
	pid, ok := running_pid(pid_file)
	if !ok {
		fmt.println("milk is not running")
		return 1
	}
	fmt.printfln("milk is running (pid %d)", pid)
	if c, connected := tx.connect(); connected {
		defer tx.disconnect(c)
		if index, has := desktop.current_desktop_index(c); has {
			fmt.printfln("Current area: %d of %d", index, desktop.desktop_count(c))
		}
	}
	return 0
}

cmd_switch :: proc(opts: ^Options) -> int {
	n, ok := strconv.parse_int(opts.value, 10)
	if !ok || n < 1 {
		fmt.eprintln("usage: milk switch N   (N >= 1)")
		return 2
	}
	c, connected := tx.connect()
	if !connected {
		fmt.eprintln("Could not open the X display")
		return 1
	}
	defer tx.disconnect(c)
	tx.send_client_message(c, "_NET_CURRENT_DESKTOP", {n - 1, 0, 0, 0, 0})
	tx.sync(c)
	fmt.printfln("Requested area %d (EWMH _NET_CURRENT_DESKTOP; dwm ignores this message, use its tag keys)", n)
	return 0
}

// The settings app: a normal window (the window manager floats it) that saves
// milk.json and signals the running instance itself.
cmd_settings :: proc(opts: ^Options) -> int {
	c, connected := tx.connect()
	if !connected {
		fmt.eprintln("Could not open the X display")
		return 1
	}
	defer tx.disconnect(c)
	context.logger = make_logger(opts)
	if !os.is_directory(opts.runtime_root) { os.make_directory_all(opts.runtime_root) }
	oobe.app_version = VERSION
	oobe.run_settings(c, opts.config_path, opts.runtime_root)
	return 0
}

// Run the setup wizard on demand, then ask a running instance to reload.
cmd_setup :: proc(opts: ^Options) -> int {
	c, connected := tx.connect()
	if !connected {
		fmt.eprintln("Could not open the X display")
		return 1
	}
	defer tx.disconnect(c)
	context.logger = make_logger(opts)
	if !os.is_directory(opts.runtime_root) { os.make_directory_all(opts.runtime_root) }
	oobe.app_version = VERSION
	if !oobe.run(c, opts.config_path, opts.runtime_root) { return 1 }
	pid_file := join({opts.runtime_root, PID_NAME})
	if pid, ok := running_pid(pid_file); ok { posix.kill(posix.pid_t(pid), .SIGHUP) }
	return 0
}

// The Linux counterpart of `Temenos.ps1 -Test` in the Windows version.
cmd_test :: proc(opts: ^Options) -> int {
	fmt.println("milk", VERSION)
	cfg, err := config.load(opts.config_path)
	if err != "" {
		fmt.printfln("Config: %s -- ERROR: %s", opts.config_path, err)
	} else {
		fmt.printfln("Config: %s (%d areas, bar %s, built-in wm %s)", opts.config_path, len(cfg.workspaces),
		             cfg.bar.enabled ? "enabled" : "disabled", cfg.wm.enabled ? "enabled" : "disabled")
	}
	fmt.printfln("Runtime: %s", opts.runtime_root)
	pid_file := join({opts.runtime_root, PID_NAME})
	if pid, running := running_pid(pid_file); running {
		fmt.printfln("Daemon: running (pid %d)", pid)
	} else {
		fmt.println("Daemon: not running")
	}
	if feh, found := find_in_path("feh"); found { fmt.printfln("feh: %s", feh) } else { fmt.println("feh: NOT FOUND (wallpapers cannot be applied)") }

	c, connected := tx.connect()
	if !connected {
		fmt.println("X display: unavailable (DISPLAY not set or server unreachable)")
		return 1
	}
	defer tx.disconnect(c)
	wm := tx.wm_name(c)
	fmt.printfln("Window manager: %s", wm == "" ? "unknown (no _NET_SUPPORTING_WM_CHECK)" : wm)
	index, has_index := desktop.current_desktop_index(c)
	if has_index {
		fmt.printfln("Current area: %d", index)
	} else {
		fmt.println("Current area: unknown (_NET_CURRENT_DESKTOP is not published; dwm needs the ewmhtags patch)")
	}
	fmt.printfln("Total areas: %d", desktop.desktop_count(c))
	mon := tx.monitor_rect(c)
	fmt.printfln("Primary monitor: %dx%d at %d,%d", mon.w, mon.h, mon.x, mon.y)
	if cfg != nil && has_index {
		if source, found := desktop.wallpaper_source(cfg, opts.runtime_root, index); found {
			fmt.printfln("Wallpaper: %s", source)
		} else {
			fmt.println("Wallpaper: none configured")
		}
		common := join({opts.runtime_root, cfg.paths.common})
		if ws, known := config.workspace(cfg, index); known {
			area := join({opts.runtime_root, ws.folder})
			fmt.printfln("Shortcuts: %d common, %d in %s", desktop.shortcut_count(common), desktop.shortcut_count(area), ws.folder)
		} else {
			fmt.printfln("Shortcuts: %d common (area %d is not in milk.json)", desktop.shortcut_count(common), index)
		}
	}
	return 0
}
