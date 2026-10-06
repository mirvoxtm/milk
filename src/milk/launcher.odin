// milk's own launcher: `milk launcher [apps|windows|files|run]` (Super+D, the
// bar's launcher button, "milk launcher" in wm.launcher and
// bar.commands.launcher). rofi draws it, in milk's theme, with the tabs of
// launcher.tabs in milk.json (Settings → Launcher):
//   apps     the applications, milk's own entries (areas, the overview, the
//            settings pages, the session…) and the user's launcher.entries,
//            the most used first; and what typing finds (launcher_entries.odin):
//            sums, addresses, files, commands, the web
//   windows  the windows of every area (Enter goes to the window's area)
//   files    the files under launcher.filesFolder, found as you type
//   run      a command
// The apps tab is a rofi script mode served by this same binary (`milk
// launcher script`). What an entry does happens once rofi has closed (and let
// go of the keyboard); milk's actions go through the window manager
// (_MILK_ACTION, see `milk action`). Opened from the bar, the launcher unfolds
// next to the button.
package milk

import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import xlib "vendor:x11/xlib"

import config "../config"
import desktop "../desktop"
import tx "../tx"
import wm "../wm"

@(private="file") ICON_PX     :: 48 // milk's entries' icons in pixels (rofi shows them at 24 px)
@(private="file") TABLER_FONT :: "/usr/share/noctalia/assets/fonts/noctalia-tabler.ttf"

// ---------------------------------------------------------------------------
// milk launcher
// ---------------------------------------------------------------------------
cmd_launcher :: proc(opts: ^Options) -> int {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		fmt.eprintln("milk launcher: cannot tell where this milk is")
		return 1
	}
	lo := config.default_launcher()
	lang := config.Language.English
	cfg, cerr := config.load(opts.config_path)
	if cerr == "" {
		lo = cfg.launcher
		lang = cfg.bar.language
		write_rofi_theme(cfg) // the current colours, even without a running milk
	}
	defer if cfg != nil { config.destroy(cfg) }
	tr :: proc(lang: config.Language, pt, en: string) -> string { return config.tr(lang, pt, en) }
	rofi, found := find_in_path("rofi")
	if !found {
		// Started from a key or the bar, nobody reads stderr: a notification says it.
		fmt.eprintln("milk launcher: rofi is not installed (milk's launcher is drawn by rofi)")
		if _, has := find_in_path("notify-send"); has {
			exec_argv({"notify-send", "-a", "milk", "milk", tr(lang, "O lançador precisa do rofi: instale o pacote rofi.", "The launcher needs rofi: install the rofi package.")})
		}
		return 1
	}

	// rofi shows a script mode by its name: the apps tab is named in milk's language.
	apps := tr(lang, "Aplicativos", "Apps")
	modes := make([dynamic]string, context.temp_allocator)
	for t in lo.tabs {
		switch t {
		case "apps":    append(&modes, fmt.tprintf("%s:'%s' launcher script", apps, exe))
		case "windows": append(&modes, "window")
		case "files":   append(&modes, "recursivebrowser")
		case "run":     append(&modes, "run")
		}
	}
	show := strings.split(modes[0], ":", context.temp_allocator)[0]
	switch opts.value {
	case "":
	case "apps", "windows", "files", "run":
		switch opts.value {
		case "apps":    show = apps
		case "windows": show = "window"
		case "files":   show = "recursivebrowser"
		case "run":     show = "run"
		}
		known := false
		for m in modes { if strings.has_prefix(m, show) { known = true } }
		if !known { append(&modes, opts.value == "apps" ? fmt.tprintf("%s:'%s' launcher script", apps, exe) : show) }
	case:
		fmt.eprintfln("milk launcher: unknown tab %q (apps, windows, files or run)", opts.value)
		return 2
	}
	folder := expand_home(lo.files_folder)
	if !os.is_directory(folder) { folder = home_dir() }
	placeholder := tr(lang, "Buscar…   = conta   ? web   / arquivos   ! comando   > terminal",
	                        "Search…   = sum   ? web   / files   ! command   > terminal")
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, rofi, "-show", show, "-modes", strings.join(modes[:], ","),
	       "-display-window", tr(lang, "Janelas", "Windows"),
	       "-display-recursivebrowser", tr(lang, "Arquivos", "Files"),
	       "-display-run", tr(lang, "Executar", "Run"))
	// milk's theme with the launcher's settings: a file of its own, since rofi
	// takes the Files tab's settings only from a file (braces doubled for fmt).
	b := strings.builder_make(context.temp_allocator)
	if theme := rofi_theme_path(); os.exists(theme) { fmt.sbprintf(&b, "@import \"%s\"\n", rasi_escape(theme)) }
	fmt.sbprintf(&b, "configuration {{\n    matching: \"%s\";\n    recursivebrowser {{ directory: \"%s\"; filter-regex: \"%s\"; command: \"xdg-open\"; }}\n}}\n",
	             lo.matching, rasi_escape(folder), rasi_escape(FILES_FILTER))
	fmt.sbprintf(&b, "window {{ width: %dpx; }}\nlistview {{ lines: %d; }}\nentry {{ placeholder: \"%s\"; }}\n", lo.width, lo.lines, rasi_escape(placeholder))
	if opts.at != "" && lo.near_button {
		if place, monitor, ok := launcher_place(opts.at); ok {
			strings.write_string(&b, place)
			if monitor != "" { append(&argv, "-m", monitor) }
		}
	}
	if path, ok := write_launcher_theme(strings.to_string(b)); ok { append(&argv, "-theme", path) }
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv { cargv[i] = strings.clone_to_cstring(a, context.temp_allocator) }
	posix.execv(cargv[0], raw_data(cargv))
	fmt.eprintfln("milk launcher: cannot run %s: %v", rofi, posix.errno())
	return 1
}

// What the Files tab leaves out: hidden files and folders, and build caches.
@(private="file")
FILES_FILTER :: `(.*/)?(\..*|node_modules|__pycache__)(/.*)?`

// The launcher's theme for this run, written aside and renamed (another
// launcher may be reading the previous one).
@(private="file")
write_launcher_theme :: proc(text: string) -> (string, bool) {
	dir := launcher_cache_dir()
	if !os.is_directory(dir) { os.make_directory_all(dir) }
	path := join({dir, "launcher.rasi"})
	tmp := fmt.tprintf("%s.%d.tmp", path, os.get_pid())
	if os.write_entire_file(tmp, transmute([]u8)text) != nil { return "", false }
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return "", false
	}
	return path, true
}

@(private="file")
rasi_escape :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, `\`, `\\`, context.temp_allocator)
	out, _ = strings.replace_all(out, `"`, `\"`, context.temp_allocator)
	return out
}

expand_home :: proc(path: string) -> string {
	p := strings.trim_space(path)
	if p == "~" { return home_dir() }
	if strings.has_prefix(p, "~/") { return join({home_dir(), p[2:]}) }
	return p
}

// Next to the bar's button `at` ("x,y,w,h" on the root window): above it on a
// bottom bar, below it on a top one, lined up with it.
@(private="file")
launcher_place :: proc(at: string) -> (theme_str, monitor: string, ok: bool) {
	parts := strings.split(at, ",", context.temp_allocator)
	if len(parts) != 4 { return }
	v: [4]i32
	for p, i in parts {
		n, nok := strconv.parse_int(strings.trim_space(p), 10)
		if !nok { return }
		v[i] = i32(n)
	}
	a := tx.Rect{v[0], v[1], v[2], v[3]}
	c, connected := tx.connect()
	if !connected { return }
	defer tx.disconnect(c)
	mon := tx.screen_rect(c)
	for m in tx.monitors(c) {
		if tx.rect_contains(m.rect, a.x + a.w / 2, a.y + a.h / 2) {
			mon = m.rect
			monitor = strings.clone(m.name, context.temp_allocator)
			break
		}
	}
	GAP :: 8
	bottom := a.y + a.h / 2 > mon.y + mon.h / 2
	right := a.x + a.w / 2 > mon.x + mon.w / 2
	location := fmt.tprintf("%s %s", bottom ? "south" : "north", right ? "east" : "west")
	x := right ? -(mon.x + mon.w - (a.x + a.w)) : a.x - mon.x
	y := bottom ? -(mon.y + mon.h - a.y + GAP) : a.y + a.h + GAP - mon.y
	theme_str = fmt.tprintf("window {{ location: %s; anchor: %s; x-offset: %dpx; y-offset: %dpx; }}\n", location, location, x, y)
	return theme_str, monitor, true
}

// The bar's launcher button: milk's launcher next to it (unless
// bar.commands.launcher is the user's own command, which the bar runs).
open_launcher :: proc(r: ^Runner, anchor: tx.Rect) -> bool {
	cmd := strings.trim_space(r.cfg.bar.commands["launcher"] or_else "")
	words := strings.fields(cmd, context.temp_allocator)
	if len(words) < 2 || words[0] != "milk" || words[1] != "launcher" { return false }
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil { return false }
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, exe, "launcher")
	append(&argv, ..words[2:])
	append(&argv, "--at", fmt.tprintf("%d,%d,%d,%d", anchor.x, anchor.y, anchor.w, anchor.h))
	if !spawn_detached(argv[:]) {
		log.warn("Could not start the launcher")
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Doing what an entry says, once rofi has gone
// ---------------------------------------------------------------------------
// `info` is the entry's: "app:<desktop file>", "cmd:<n>" (launcher.entries),
// "wm:<action>", "ask:<action>", "settings:<page>", "lock", "copy:<text>",
// "open:<path or address>", "web:<search>", "run:<command>", "term:<command>".
launcher_run :: proc(info: string, cfg: ^config.Config) {
	if !leave_rofi() { return } // the parent goes back to rofi, which closes
	history_add(info)
	colon := strings.index_byte(info, ':')
	kind := colon >= 0 ? info[:colon] : info
	arg := colon >= 0 ? info[colon + 1:] : ""
	switch kind {
	case "app":
		launch_desktop_file(arg, cfg)
	case "cmd":
		n, ok := strconv.parse_int(arg, 10)
		if ok && cfg != nil && n >= 0 && n < len(cfg.launcher.entries) { exec_shell(cfg.launcher.entries[n].command) }
	case "wm":
		if c, ok := tx.connect(); ok {
			send_action(c, arg)
			tx.disconnect(c)
		}
	case "ask":
		if confirm(arg, cfg) {
			if c, ok := tx.connect(); ok {
				send_action(c, arg)
				tx.disconnect(c)
			}
		}
	case "settings":
		exec_self({"settings", arg})
	case "lock":
		exec_self({"lock"})
	case "copy":
		serve_clipboard(arg, cfg == nil || cfg.clipboard.enabled)
	case "open":
		exec_argv({"xdg-open", arg})
	case "web":
		if cfg != nil {
			url := config.web_search_url(&cfg.launcher)
			if url != "" {
				q, _ := strings.replace_all(url, "%s", url_encode(arg), context.temp_allocator)
				exec_argv({"xdg-open", q})
			}
		}
	case "run":
		exec_shell(arg)
	case "term":
		exec_in_terminal(arg, cfg, true)
	}
	posix._exit(0)
}

// Fork: the parent goes back to rofi (true only in the child). The child gets
// a session of its own and lets go of rofi's pipe (rofi waits for its end),
// then waits until rofi has quit (its pid file; rofi's scripts are children
// of init, not of rofi) and let go of the keyboard.
@(private="file")
leave_rofi :: proc() -> bool {
	rofi := 0
	runtime_dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if data, err := os.read_entire_file(join({runtime_dir != "" ? runtime_dir : "/tmp", "rofi.pid"}), context.temp_allocator); err == nil {
		rofi, _ = strconv.parse_int(strings.trim_space(string(data)), 10)
	}
	pid := posix.fork()
	if pid != 0 { return false }
	posix.setsid()
	null := posix.open("/dev/null", {.RDWR})
	if null >= 0 {
		for fd in ([]posix.FD{0, 1, 2}) { posix.dup2(null, fd) }
		if null > 2 { posix.close(null) }
	}
	deadline := time.tick_now()
	for rofi > 1 && time.tick_since(deadline) < 3 * time.Second {
		if posix.kill(posix.pid_t(rofi), posix.Signal(0)) != .OK && posix.errno() == .ESRCH { break }
		time.sleep(10 * time.Millisecond)
	}
	if c, ok := tx.connect(); ok {
		for time.tick_since(deadline) < 3 * time.Second {
			if xlib.GrabKeyboard(c.dpy, c.root, false, .GrabModeAsync, .GrabModeAsync, xlib.CurrentTime) == wm.GRAB_SUCCESS {
				xlib.UngrabKeyboard(c.dpy, xlib.CurrentTime)
				break
			}
			time.sleep(10 * time.Millisecond)
		}
		tx.disconnect(c)
	}
	home := strings.clone_to_cstring(home_dir(), context.temp_allocator)
	posix.chdir(home)
	return true
}

// Become `argv` (looked up in $PATH).
@(private="file")
exec_argv :: proc(argv: []string) {
	if len(argv) == 0 { return }
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv { cargv[i] = strings.clone_to_cstring(a, context.temp_allocator) }
	posix.execvp(cargv[0], raw_data(cargv))
}

@(private="file")
exec_shell :: proc(cmd: string) {
	exec_argv({"/bin/sh", "-c", cmd})
}

// Run this milk with `args` in place of this process.
@(private="file")
exec_self :: proc(args: []string) {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil { return }
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, exe)
	append(&argv, ..args)
	exec_argv(argv[:])
}

// `cmd` (a shell command line) in milk's terminal (wm.terminal); `stay`
// leaves a shell open once it is done.
@(private="file")
exec_in_terminal :: proc(cmd: string, cfg: ^config.Config, stay: bool) {
	terminal := cfg != nil ? strings.trim_space(cfg.wm.terminal) : ""
	if terminal == "" { terminal = "xterm" }
	inner := cmd
	if stay { inner = fmt.tprintf(`%s; exec "${{SHELL:-sh}}"`, cmd) }
	exec_shell(fmt.tprintf("%s %s sh -c %s", terminal, terminal_flag(terminal), shell_quote(inner)))
}

// How a terminal emulator is told what to run.
@(private="file")
terminal_flag :: proc(terminal: string) -> string {
	words := strings.fields(terminal, context.temp_allocator)
	if len(words) == 0 { return "-e" }
	switch os.base(words[0]) {
	case "kitty", "foot", "footclient": return ""
	case "gnome-terminal", "kgx", "ptyxis": return "--"
	case "wezterm": return "start --"
	case "xfce4-terminal", "terminator": return "-x"
	}
	return "-e"
}

shell_quote :: proc(s: string) -> string {
	q, _ := strings.replace_all(s, "'", `'\''`, context.temp_allocator)
	return fmt.tprintf("'%s'", q)
}

// Start a desktop entry (its Exec line, in a terminal for Terminal=true).
@(private="file")
launch_desktop_file :: proc(path: string, cfg: ^config.Config) {
	s, ok := desktop.load_shortcut(path, context.temp_allocator)
	if !ok || s.kind != .Application { return }
	argv := desktop.parse_exec(&s)
	if len(argv) == 0 { return }
	if s.workdir != "" && os.is_directory(s.workdir) {
		posix.chdir(strings.clone_to_cstring(s.workdir, context.temp_allocator))
	}
	if s.terminal {
		words := make([dynamic]string, context.temp_allocator)
		for a in argv { append(&words, shell_quote(a)) }
		exec_in_terminal(strings.join(words[:], " "), cfg, false)
		return
	}
	exec_argv(argv)
}

@(private="file")
url_encode :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for ch in transmute([]u8)s {
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.', '~':
			strings.write_byte(&b, ch)
		case ' ':
			strings.write_byte(&b, '+')
		case:
			fmt.sbprintf(&b, "%%%02X", ch)
		}
	}
	return strings.to_string(b)
}

// "Are you sure?" for logging out, restarting and switching off: a small
// rofi list whose first row (the one Enter takes) is Cancel.
@(private="file")
confirm :: proc(spec: string, cfg: ^config.Config) -> bool {
	rofi, found := find_in_path("rofi")
	if !found { return false }
	lang := cfg != nil ? cfg.bar.language : config.Language.English
	question, yes: string
	switch spec {
	case "quit":     question, yes = config.tr(lang, "Sair da sessão?", "Log out?"), config.tr(lang, "Sim, sair", "Yes, log out")
	case "reboot":   question, yes = config.tr(lang, "Reiniciar o computador?", "Restart the computer?"), config.tr(lang, "Sim, reiniciar", "Yes, restart")
	case "poweroff": question, yes = config.tr(lang, "Desligar o computador?", "Power off the computer?"), config.tr(lang, "Sim, desligar", "Yes, power off")
	case: return false
	}
	no := config.tr(lang, "Cancelar", "Cancel")
	r, w, perr := os.pipe()
	if perr != nil { return false }
	os.write_string(w, fmt.tprintf("%s\n%s\n", no, yes))
	os.close(w)
	defer os.close(r)
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, rofi, "-dmenu", "-i", "-no-custom", "-no-show-icons", "-mesg", question,
	       "-theme-str", `window { width: 420px; } listview { lines: 2; } mode-switcher { enabled: false; } inputbar { enabled: false; }`)
	theme := rofi_theme_path()
	if os.exists(theme) { append(&argv, "-theme", theme) }
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = argv[:], stdin = r}, context.temp_allocator)
	if err != nil || state.exit_code != 0 { return false }
	return strings.trim_space(string(stdout)) == yes
}

// ---------------------------------------------------------------------------
// milk action
// ---------------------------------------------------------------------------
// Ask milk's window manager to run an action: a line appended to _MILK_ACTION
// on the root window, which it reads and deletes. Nobody took it within a
// second: it is removed (it must not run when a later milk starts).
send_action :: proc(c: ^tx.Connection, spec: string) -> bool {
	atom := tx.atom(c, wm.MILK_ACTION)
	line := fmt.tprintf("%s\n", spec)
	xlib.ChangeProperty(c.dpy, c.root, atom, tx.atom(c, "UTF8_STRING"), 8, xlib.PropModeAppend, raw_data(line), i32(len(line)))
	tx.sync(c)
	for _ in 0 ..< 100 {
		if !action_pending(c, atom) { return true }
		time.sleep(10 * time.Millisecond)
	}
	xlib.DeleteProperty(c.dpy, c.root, atom)
	tx.sync(c)
	return false
}

@(private="file")
action_pending :: proc(c: ^tx.Connection, atom: xlib.Atom) -> bool {
	type: xlib.Atom
	format: i32
	n, after: uint
	data: rawptr
	if xlib.GetWindowProperty(c.dpy, c.root, atom, 0, 0, false, xlib.AnyPropertyType, &type, &format, &n, &after, &data) != 0 { return false }
	if data != nil { xlib.Free(data) }
	return type != 0
}

// `milk action NAME [ARGUMENT]` (and `milk overview`): a window manager action
// in the running milk (config.WM_ACTIONS, "exec" excepted).
cmd_action :: proc(spec: string) -> int {
	name, arg := config.split_action(spec)
	plain := true // as the window manager takes them (wm/commands.odin)
	for ch in arg {
		if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-') { plain = false }
	}
	if name == "exec" || !plain || !config.valid_wm_action(spec) {
		fmt.eprintfln("milk action: %q is not one of milk's actions", spec)
		return 2
	}
	c, connected := tx.connect()
	if !connected {
		fmt.eprintln("Could not open the X display")
		return 1
	}
	defer tx.disconnect(c)
	if !send_action(c, spec) {
		fmt.eprintln("milk's window manager is not running here (or did not answer)")
		return 1
	}
	return 0
}

// Start argv on its own: a new session, adopted by init, never waited for.
spawn_detached :: proc(argv: []string) -> bool {
	if len(argv) == 0 { return false }
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv { cargv[i] = strings.clone_to_cstring(a, context.temp_allocator) }
	pid := posix.fork()
	if pid < 0 { return false }
	if pid == 0 {
		if posix.fork() != 0 { posix._exit(0) }
		posix.setsid()
		empty: posix.sigset_t
		posix.sigemptyset(&empty)
		posix.sigprocmask(.SETMASK, &empty, nil)
		for sig in ([]posix.Signal{.SIGPIPE, .SIGCHLD, .SIGHUP, .SIGINT, .SIGTERM, .SIGUSR1, .SIGUSR2}) {
			posix.signal(sig, auto_cast posix.SIG_DFL)
		}
		null := posix.open("/dev/null", {.RDWR})
		if null >= 0 { posix.dup2(null, 0) }
		for fd in 3 ..< 1024 { posix.close(posix.FD(fd)) }
		posix.execvp(cargv[0], raw_data(cargv))
		posix._exit(127)
	}
	status: c.int
	posix.waitpid(pid, &status, {})
	return true
}

// ---------------------------------------------------------------------------
// The calculator's result on the clipboard
// ---------------------------------------------------------------------------
// Own CLIPBOARD with `text` until someone else takes it. With milk's
// clipboard history on, milk copies it at once and keeps it when this process
// ends, so it ends a moment after the first copy.
@(private="file")
serve_clipboard :: proc(text: string, history_on: bool) {
	c, connected := tx.connect()
	if !connected { return }
	defer tx.disconnect(c)
	dpy := c.dpy
	win := xlib.CreateSimpleWindow(dpy, c.root, -10, -10, 1, 1, 0, 0, 0)
	xlib.SelectInput(dpy, win, {.PropertyChange})
	// The server time to own the selection with: a property change's.
	stamp := tx.atom(c, "_MILK_STAMP")
	xlib.ChangeProperty(dpy, win, stamp, tx.ATOM_STRING, 8, xlib.PropModeAppend, nil, 0)
	ev: xlib.XEvent
	ts: xlib.Time
	for {
		xlib.NextEvent(dpy, &ev)
		if ev.type == .PropertyNotify && ev.xproperty.window == win { ts = ev.xproperty.time; break }
	}
	clipboard := tx.atom(c, "CLIPBOARD")
	xlib.SetSelectionOwner(dpy, clipboard, win, ts)
	if xlib.GetSelectionOwner(dpy, clipboard) != win { return }
	utf8 := tx.atom(c, "UTF8_STRING")
	targets_atom := tx.atom(c, "TARGETS")
	timestamp := tx.atom(c, "TIMESTAMP")
	text_targets := []xlib.Atom{utf8, tx.atom(c, "text/plain;charset=utf-8"), tx.ATOM_STRING, tx.atom(c, "TEXT"), tx.atom(c, "text/plain")}
	served_at: f64
	start := tx.now()
	for {
		now := tx.now()
		if served_at > 0 && history_on && now - served_at > 1.5 { return }
		if now - start > 8 * 3600 { return }
		if tx.pending(c) == 0 {
			pfd := posix.pollfd{fd = posix.FD(c.fd), events = {.IN}}
			posix.poll(&pfd, 1, 250)
			if tx.pending(c) == 0 { continue }
		}
		xlib.NextEvent(dpy, &ev)
		#partial switch ev.type {
		case .SelectionClear:
			return
		case .SelectionRequest:
			req := &ev.xselectionrequest
			reply: xlib.XEvent
			reply.xselection = {type = .SelectionNotify, requestor = req.requestor, selection = req.selection, target = req.target, time = req.time}
			prop := req.property != 0 ? req.property : req.target
			switch {
			case req.target == targets_atom:
				list := make([dynamic]xlib.Atom, context.temp_allocator)
				append(&list, targets_atom, timestamp)
				append(&list, ..text_targets)
				xlib.ChangeProperty(dpy, req.requestor, prop, tx.ATOM_ATOM, 32, xlib.PropModeReplace, raw_data(list), i32(len(list)))
				reply.xselection.property = prop
			case req.target == timestamp:
				value := [1]uint{uint(ts)}
				xlib.ChangeProperty(dpy, req.requestor, prop, tx.atom(c, "INTEGER"), 32, xlib.PropModeReplace, &value[0], 1)
				reply.xselection.property = prop
			case:
				for t in text_targets {
					if req.target != t { continue }
					type := t == tx.ATOM_STRING ? tx.ATOM_STRING : utf8
					xlib.ChangeProperty(dpy, req.requestor, prop, type, 8, xlib.PropModeReplace, raw_data(text), i32(len(text)))
					reply.xselection.property = prop
					served_at = tx.now()
					break
				}
			}
			xlib.SendEvent(dpy, req.requestor, false, {}, &reply)
			xlib.Flush(dpy)
		}
	}
}

// ---------------------------------------------------------------------------
// Icons for milk's entries: Tabler glyphs on a rounded plate, in the theme's
// colours, as PNG files in $XDG_CACHE_HOME/milk/launcher (one per glyph and
// colours, drawn the first time)
// ---------------------------------------------------------------------------
Icon_Painter :: struct {
	c:         ^tx.Connection,
	font:      ^tx.Font,
	dir:       string,
	plate, fg: tx.Color,
}

icons_init :: proc(p: ^Icon_Painter, c: ^tx.Connection, cfg: ^config.Config) {
	p.c = c
	p.plate = tx.color_from_hex("#E9E0D6")
	p.fg = tx.color_from_hex("#4A3F35")
	if cfg != nil {
		p.plate = tx.color_from_hex(cfg.bar.theme.surface, p.plate)
		p.fg = tx.color_from_hex(cfg.bar.theme.accent, p.fg)
	}
	p.dir = launcher_cache_dir()
	font_file := cfg != nil && cfg.bar.icon_font_file != "" ? cfg.bar.icon_font_file : TABLER_FONT
	if c != nil && os.exists(font_file) { p.font, _ = tx.font_open_file(c, font_file, ICON_PX * 5 / 8) }
}

icons_destroy :: proc(p: ^Icon_Painter) {
	if p.c != nil { tx.font_close(p.c, p.font) }
	p.font = nil
}

launcher_cache_dir :: proc() -> string {
	cache, found := os.lookup_env("XDG_CACHE_HOME", context.temp_allocator)
	if !found || cache == "" { cache = join({home_dir(), ".cache"}) }
	return join({cache, "milk", "launcher"})
}

// The PNG of `glyph`, drawn now when it is not there yet ("" = no icon font).
icon_path :: proc(p: ^Icon_Painter, glyph: rune) -> string {
	if glyph == 0 || p.font == nil { return "" }
	name := fmt.tprintf("%X-%02X%02X%02X-%02X%02X%02X-%d.png", glyph, p.plate.r, p.plate.g, p.plate.b, p.fg.r, p.fg.g, p.fg.b, ICON_PX)
	path := join({p.dir, name})
	if os.exists(path) { return path }
	if !tx.font_has_glyph(p.c, p.font, glyph) { return "" }
	if !os.is_directory(p.dir) { os.make_directory_all(p.dir) }
	img, ok := paint_icon(p, glyph)
	if !ok { return "" }
	data := tx.png_encode(img, context.temp_allocator)
	// Written aside and renamed: rofi may read it while another launcher draws it.
	tmp := fmt.tprintf("%s.%d.tmp", path, os.get_pid())
	if os.write_entire_file(tmp, data) != nil { return "" }
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return ""
	}
	return path
}

@(private="file")
paint_icon :: proc(p: ^Icon_Painter, glyph: rune) -> (tx.Image, bool) {
	c := p.c
	S :: ICON_PX
	// The glyph's coverage: white on black in a pixmap, read back.
	pm := xlib.CreatePixmap(c.dpy, xlib.Drawable(c.root), S, S, u32(c.depth))
	defer xlib.FreePixmap(c.dpy, pm)
	cv := tx.canvas_make(S, S, context.temp_allocator)
	tx.canvas_upload(c, cv, xlib.Drawable(pm), 0, 0)
	text := fmt.tprintf("%r", glyph)
	ext := tx.text_extents(c, p.font, text)
	ts := tx.text_surface_make(c, xlib.Drawable(pm))
	gx := (S - i32(ext.width)) / 2 + i32(ext.x)
	gy := (S - i32(ext.height)) / 2 + i32(ext.y)
	tx.draw_text(&ts, p.font, gx, gy, text, {255, 255, 255, 255})
	tx.text_surface_destroy(&ts)
	grab, ok := tx.canvas_grab(c, xlib.Drawable(pm), {0, 0, S, S}, context.temp_allocator)
	if !ok { return {}, false }
	img := tx.image_make(S, S, context.temp_allocator)
	radius := f32(S) * 0.26
	half := f32(S) / 2
	for y in 0 ..< i32(S) {
		for x in 0 ..< i32(S) {
			// The plate: a rounded square with a soft edge.
			qx := abs(f32(x) + 0.5 - half) - (half - radius)
			qy := abs(f32(y) + 0.5 - half) - (half - radius)
			d := math.sqrt(max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)) + min(max(qx, qy), 0) - radius
			plate := clamp(0.5 - d, 0, 1)
			g := f32(grab.px[y * S + x] >> 16 & 0xFF) / 255 // the glyph's coverage
			i := (y * S + x) * 4
			img.rgba[i] = u8(f32(p.plate.r) * (1 - g) + f32(p.fg.r) * g)
			img.rgba[i + 1] = u8(f32(p.plate.g) * (1 - g) + f32(p.fg.g) * g)
			img.rgba[i + 2] = u8(f32(p.plate.b) * (1 - g) + f32(p.fg.b) * g)
			img.rgba[i + 3] = u8(plate * 255)
		}
	}
	return img, true
}
