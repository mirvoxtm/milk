// Small helpers shared by the desktop modules: paths and XDG directories,
// INI-style files (desktop entries, Windows .url files, icon theme indexes)
// and child processes (synchronous helpers such as feh/rsvg-convert, and
// detached application launches).
package desktop

import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf16"
import tx "../tx"

// Pixel size for a font size given in points at 96 DPI (as the blueprint's fonts.py).
points_to_pixels :: proc(points: f64) -> i32 {
	return max(6, i32(math.round(points * 96.0 / 72.0)))
}

// Join path elements (cleaned) with the given allocator.
join_path :: proc(elems: []string, allocator := context.temp_allocator) -> string {
	joined, _ := os.join_path(elems, allocator)
	return joined
}

// $HOME, or "/" when unset.
home_dir :: proc() -> string {
	if v, found := os.lookup_env("HOME", context.temp_allocator); found && v != "" { return v }
	return "/"
}

// An XDG base directory variable, or `fallback` when unset/empty.
xdg_env_dir :: proc(name: string, fallback: string) -> string {
	if v, found := os.lookup_env(name, context.temp_allocator); found && v != "" { return v }
	return fallback
}

config_home :: proc() -> string {
	return xdg_env_dir("XDG_CONFIG_HOME", join_path({home_dir(), ".config"}))
}

// $XDG_DATA_HOME followed by $XDG_DATA_DIRS (defaults from the Base Directory spec).
data_dirs :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	append(&out, xdg_env_dir("XDG_DATA_HOME", join_path({home_dir(), ".local", "share"})))
	dirs := xdg_env_dir("XDG_DATA_DIRS", "/usr/local/share:/usr/share")
	for d in strings.split(dirs, ":", context.temp_allocator) {
		if d != "" { append(&out, d) }
	}
	return out[:]
}

// XDG_<KEY>_DIR from $XDG_CONFIG_HOME/user-dirs.dirs, without spawning xdg-user-dir.
xdg_user_dir :: proc(key: string, fallback: string) -> string {
	data, err := os.read_entire_file(join_path({config_home(), "user-dirs.dirs"}), context.temp_allocator)
	if err != nil { return fallback }
	wanted := strings.concatenate({"XDG_", key, "_DIR="}, context.temp_allocator)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, wanted) { continue }
		value := strings.trim(strings.trim_space(trimmed[len(wanted):]), "\"")
		value, _ = strings.replace_all(value, "$HOME", home_dir(), context.temp_allocator)
		if strings.has_prefix(value, "~/") { value = join_path({home_dir(), value[2:]}) }
		if value != "" && value != home_dir() { return value }
	}
	return fallback
}

// Create a directory (and its parents); true when it exists afterwards.
ensure_dir :: proc(path: string) -> bool {
	if os.is_directory(path) { return true }
	err := os.make_directory_all(path)
	if err != nil && err != os.General_Error.Exist {
		log.warnf("Could not create %s: %v", path, os.error_string(err))
	}
	return os.is_directory(path)
}

// Lower-cased extension including the dot ("" when there is none).
lower_ext :: proc(path: string, allocator := context.temp_allocator) -> string {
	name := os.base(path)
	dot := strings.last_index_byte(name, '.')
	if dot <= 0 { return "" }
	return strings.to_lower(name[dot:], allocator)
}

// Read a text file, dropping a UTF-8 BOM and converting UTF-16 (BOM) to UTF-8.
read_text_file :: proc(path: string, allocator := context.temp_allocator) -> (text: string, ok: bool) {
	data, err := os.read_entire_file(path, allocator)
	if err != nil { return "", false }
	if len(data) >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
		return string(data[3:]), true
	}
	if len(data) >= 2 && ((data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF)) {
		big_endian := data[0] == 0xFE
		units := make([]u16, (len(data) - 2) / 2, context.temp_allocator)
		for i in 0 ..< len(units) {
			a, b := u16(data[2 + 2 * i]), u16(data[3 + 2 * i])
			units[i] = big_endian ? (a << 8 | b) : (b << 8 | a)
		}
		buf := make([]u8, len(units) * 3 + 4, allocator)
		n := utf16.decode_to_utf8(buf, units)
		return string(buf[:n]), true
	}
	return string(data), true
}

// ---------------------------------------------------------------------------
// INI files
// ---------------------------------------------------------------------------
Ini_Section :: map[string]string
Ini :: map[string]Ini_Section

// Minimal INI reader (case-sensitive keys, first occurrence wins, no
// interpolation) used for desktop entries, .url files and index.theme.
// Everything is allocated with `allocator` (a scratch allocator in practice).
parse_ini :: proc(text: string, allocator := context.temp_allocator) -> Ini {
	sections := make(Ini, allocator)
	current: ^Ini_Section
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' || line[0] == ';' { continue }
		if line[0] == '[' && line[len(line) - 1] == ']' {
			name := strings.trim_space(line[1:len(line) - 1])
			if name not_in sections { sections[name] = make(Ini_Section, allocator) }
			current = &sections[name]
			continue
		}
		eq := strings.index_byte(line, '=')
		if current == nil || eq < 0 { continue }
		key := strings.trim_space(line[:eq])
		if key == "" || key in current^ { continue }
		current[key] = strings.trim_space(line[eq + 1:])
	}
	return sections
}

// Case-insensitive section lookup (Windows .url files use [InternetShortcut] in any case).
ini_section_fold :: proc(ini: Ini, name: string) -> (Ini_Section, bool) {
	if s, ok := ini[name]; ok { return s, true }
	for key, s in ini {
		if strings.equal_fold(key, name) { return s, true }
	}
	return nil, false
}

// Expand the escape sequences of Desktop Entry string values (\s \n \t \r \\).
unescape_value :: proc(s: string, allocator := context.temp_allocator) -> string {
	if strings.index_byte(s, '\\') < 0 { return s }
	b := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		if ch == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] {
			case 's':  strings.write_byte(&b, ' ')
			case 'n':  strings.write_byte(&b, '\n')
			case 't':  strings.write_byte(&b, '\t')
			case 'r':  strings.write_byte(&b, '\r')
			case '\\': strings.write_byte(&b, '\\')
			case:
				// Unknown escapes are kept verbatim; Exec quoting handles its own.
				strings.write_byte(&b, '\\')
				strings.write_byte(&b, s[i])
			}
			continue
		}
		strings.write_byte(&b, ch)
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Executables and processes
// ---------------------------------------------------------------------------

// Resolve a command name through $PATH (names containing '/' are checked as-is).
find_executable :: proc(name: string, allocator := context.temp_allocator) -> (string, bool) {
	if name == "" { return "", false }
	if strings.index_byte(name, '/') >= 0 {
		path := name
		if strings.has_prefix(path, "~/") { path = join_path({home_dir(), path[2:]}) }
		if is_executable_file(path) { return strings.clone(path, allocator), true }
		return "", false
	}
	path_env := xdg_env_dir("PATH", "/usr/local/bin:/usr/bin:/bin")
	for dir in strings.split(path_env, ":", context.temp_allocator) {
		if dir == "" { continue }
		candidate := join_path({dir, name})
		if is_executable_file(candidate) { return strings.clone(candidate, allocator), true }
	}
	return "", false
}

@(private)
is_executable_file :: proc(path: string) -> bool {
	if !os.is_file(path) { return false }
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	return posix.access(cpath, {.X_OK}) == .OK
}

Run_Result :: struct {
	started:   bool, // the process could be started at all
	not_found: bool, // the executable does not exist
	timed_out: bool,
	exit_code: int,
	stdout:    []byte,
	stderr:    []byte,
}

// Run a command synchronously with a timeout, capturing stderr (and stdout
// when asked). Used for short helpers (feh, rsvg-convert); never for the
// applications the user launches.
run_sync :: proc(argv: []string, timeout: f64, capture_stdout: bool, allocator := context.temp_allocator) -> (res: Run_Result) {
	if len(argv) == 0 { return }
	if _, found := find_executable(argv[0]); !found {
		res.not_found = true
		return
	}
	out_r, out_w: ^os.File
	if capture_stdout {
		r, w, perr := os.pipe()
		if perr != nil { return }
		out_r, out_w = r, w
	}
	err_r, err_w, perr := os.pipe()
	if perr != nil {
		if out_r != nil { os.close(out_r); os.close(out_w) }
		return
	}
	p, serr := os.process_start(os.Process_Desc{command = argv, stdout = out_w, stderr = err_w})
	if out_w != nil { os.close(out_w) }
	os.close(err_w)
	defer if out_r != nil { os.close(out_r) }
	defer os.close(err_r)
	if serr != nil {
		res.not_found = serr == os.General_Error.Not_Exist
		return
	}
	res.started = true

	out_buf := make([dynamic]byte, allocator)
	err_buf := make([dynamic]byte, allocator)
	out_open := out_r != nil
	err_open := true
	deadline := tx.now() + timeout
	chunk: [8192]u8
	for out_open || err_open {
		remaining := deadline - tx.now()
		if remaining <= 0 {
			res.timed_out = true
			break
		}
		fds: [2]posix.pollfd
		n := 0
		if out_open { fds[n] = {fd = posix.FD(os.fd(out_r)), events = {.IN}}; n += 1 }
		if err_open { fds[n] = {fd = posix.FD(os.fd(err_r)), events = {.IN}}; n += 1 }
		rc := posix.poll(&fds[0], posix.nfds_t(n), i32(remaining * 1000) + 1)
		if rc < 0 {
			if posix.errno() == .EINTR { continue }
			break
		}
		for i in 0 ..< n {
			if fds[i].revents == {} { continue }
			got := posix.read(fds[i].fd, &chunk[0], len(chunk))
			if got < 0 && posix.errno() == .EINTR { continue }
			is_out := out_open && fds[i].fd == posix.FD(os.fd(out_r))
			if got <= 0 {
				if is_out { out_open = false } else { err_open = false }
				continue
			}
			if is_out { append(&out_buf, ..chunk[:got]) } else { append(&err_buf, ..chunk[:got]) }
		}
	}
	if res.timed_out {
		_ = os.process_kill(p)
	}
	wait := max(deadline - tx.now(), 0.5)
	state, werr := os.process_wait(p, os.TIMEOUT_INFINITE if res.timed_out else time.Duration(wait * f64(time.Second)))
	if werr != nil && !state.exited {
		// Still running after the deadline: kill it and reap it.
		_ = os.process_kill(p)
		state, _ = os.process_wait(p)
		res.timed_out = true
	}
	res.exit_code = state.exit_code
	res.stdout = out_buf[:]
	res.stderr = err_buf[:]
	return
}

// Start an application detached from milk: its own session (so it
// survives us and our signals), default signal mask, stdio on /dev/null,
// working directory `workdir`. The pid must be reaped later (see reap_children).
spawn_detached :: proc(argv: []string, workdir: string) -> (pid: posix.pid_t, ok: bool) {
	if len(argv) == 0 { return 0, false }
	exe, found := find_executable(argv[0])
	if !found {
		log.errorf("Cannot launch %q: command not found", argv[0])
		return 0, false
	}
	// Everything the child needs is prepared before fork(): after it, the
	// child only makes async-signal-safe calls.
	cexe := strings.clone_to_cstring(exe, context.temp_allocator)
	cargs := make([]cstring, len(argv) + 1, context.temp_allocator)
	for arg, i in argv { cargs[i] = strings.clone_to_cstring(arg, context.temp_allocator) }
	cdir := strings.clone_to_cstring(workdir, context.temp_allocator)
	has_dir := workdir != ""

	child := posix.fork()
	if child < 0 {
		log.errorf("Cannot launch %q: fork failed (%v)", argv[0], posix.errno())
		return 0, false
	}
	if child == 0 {
		posix.setsid()
		empty: posix.sigset_t
		posix.sigemptyset(&empty)
		posix.sigprocmask(.SETMASK, &empty, nil)
		for sig in ([]posix.Signal{.SIGPIPE, .SIGCHLD, .SIGHUP, .SIGINT, .SIGTERM, .SIGQUIT}) {
			posix.signal(sig, auto_cast posix.SIG_DFL)
		}
		null := posix.open("/dev/null", {.RDWR})
		if null >= 0 {
			posix.dup2(null, 0)
			posix.dup2(null, 1)
			posix.dup2(null, 2)
		}
		for fd in 3 ..< 1024 { posix.close(posix.FD(fd)) }
		if has_dir { posix.chdir(cdir) }
		posix.execv(cexe, raw_data(cargs))
		posix._exit(127)
	}
	return child, true
}
