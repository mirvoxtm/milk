// The conversation with polkit's authentication helper. polkitd leaves the
// password check to polkit-agent-helper-1, which runs PAM as root and reports
// the result to polkitd itself; the agent only relays its prompts and the
// answers. Since polkit 124 the helper may sit behind a systemd socket
// (/run/polkit/agent-helper.socket): the agent connects and writes the user
// name and the cookie, one per line. Otherwise it is installed setuid and
// the agent spawns it with the user name as its argument, writing the cookie
// on its stdin. Either way the helper then writes lines
//   PAM_PROMPT_ECHO_OFF <prompt>   a hidden answer (the password)
//   PAM_PROMPT_ECHO_ON <prompt>    a visible one
//   PAM_ERROR_MSG <text>, PAM_TEXT_INFO <text>
//   SUCCESS, FAILURE
// (the text C-escaped, g_strescape) and reads one line per prompt.
//
// Tests replace the system's: MILK_POLKIT_SOCKET is the socket ("none" = do
// not try one) and MILK_POLKIT_HELPER the program spawned otherwise.
package polkit

import "core:c"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

@(private) HELPER_SOCKET :: "/run/polkit/agent-helper.socket"

// Where distributions install the setuid helper.
@(private, rodata)
HELPER_PATHS := []string{
	"/usr/lib/polkit-1/polkit-agent-helper-1",
	"/usr/libexec/polkit-agent-helper-1",
	"/usr/libexec/polkit-1/polkit-agent-helper-1",
	"/usr/lib/policykit-1/polkit-agent-helper-1",
}

@(private)
Helper_Event_Kind :: enum { Prompt, Error, Info, Success, Failure }

@(private)
Helper_Event :: struct {
	kind: Helper_Event_Kind,
	text: string, // temp allocator
	echo: bool,   // Prompt: the answer may be shown
}

@(private)
Helper :: struct {
	fd:      posix.FD,    // what the helper writes; -1 = no session
	wfd:     posix.FD,    // where the answers go (the socket again, or the child's stdin)
	pid:     posix.pid_t, // the spawned helper, 0 with the socket
	buf:     [dynamic]u8, // a line not complete yet
	zombies: [dynamic]posix.pid_t,
}

@(private)
helper_init :: proc(h: ^Helper) {
	h.fd, h.wfd = -1, -1
}

@(private)
helper_running :: proc(h: ^Helper) -> bool { return h.fd >= 0 }

// Start a conversation for `user`; false when no helper can be reached.
@(private)
helper_start :: proc(h: ^Helper, user, cookie: string) -> bool {
	helper_stop(h)
	clear(&h.buf)
	socket_path := HELPER_SOCKET
	if v, found := os.lookup_env("MILK_POLKIT_SOCKET", context.temp_allocator); found && v != "" { socket_path = v }
	if socket_path != "none" && os.exists(socket_path) {
		if fd, ok := connect_unix(socket_path); ok {
			h.fd, h.wfd = fd, fd
			if write_line(h.wfd, user) && write_line(h.wfd, cookie) {
				log.debugf("Polkit: helper reached through %s", socket_path)
				return true
			}
			helper_stop(h)
		}
		log.warnf("Polkit: cannot use %s; trying the setuid helper", socket_path)
	}
	return spawn_helper(h, user, cookie)
}

@(private)
spawn_helper :: proc(h: ^Helper, user, cookie: string) -> bool {
	path := ""
	if v, found := os.lookup_env("MILK_POLKIT_HELPER", context.temp_allocator); found && v != "" {
		path = v
	} else {
		for p in HELPER_PATHS {
			if os.exists(p) { path = p; break }
		}
	}
	if path == "" {
		log.error("Polkit: polkit-agent-helper-1 was not found")
		return false
	}
	to_child, from_child: [2]posix.FD
	if posix.pipe(&to_child) != .OK { return false }
	if posix.pipe(&from_child) != .OK {
		posix.close(to_child[0]); posix.close(to_child[1])
		return false
	}
	// Prepared before fork(): the child only makes async-signal-safe calls.
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	argv := [3]cstring{cpath, strings.clone_to_cstring(user, context.temp_allocator), nil}
	signals := [?]posix.Signal{.SIGPIPE, .SIGCHLD, .SIGHUP, .SIGINT, .SIGTERM, .SIGQUIT, .SIGUSR1, .SIGUSR2}
	pid := posix.fork()
	if pid < 0 {
		for fd in ([]posix.FD{to_child[0], to_child[1], from_child[0], from_child[1]}) { posix.close(fd) }
		log.errorf("Polkit: cannot start the helper (fork: %v)", posix.errno())
		return false
	}
	if pid == 0 {
		empty: posix.sigset_t
		posix.sigemptyset(&empty)
		posix.sigprocmask(.SETMASK, &empty, nil)
		for sig in signals { posix.signal(sig, auto_cast posix.SIG_DFL) }
		posix.dup2(to_child[0], 0)
		posix.dup2(from_child[1], 1)
		for fd in 3 ..< 1024 { posix.close(posix.FD(fd)) }
		posix.execv(cpath, raw_data(argv[:]))
		posix._exit(127)
	}
	posix.close(to_child[0])
	posix.close(from_child[1])
	cloexec(to_child[1])
	cloexec(from_child[0])
	nonblocking(from_child[0])
	h.pid, h.fd, h.wfd = pid, from_child[0], to_child[1]
	if !write_line(h.wfd, cookie) {
		helper_stop(h)
		return false
	}
	log.debugf("Polkit: started %s for %s (pid %d)", path, user, pid)
	return true
}

// End the conversation (the helper stops when its input closes; a spawned
// one also gets SIGTERM and is reaped later).
@(private)
helper_stop :: proc(h: ^Helper) {
	if h.wfd >= 0 && h.wfd != h.fd { posix.close(h.wfd) }
	if h.fd >= 0 { posix.close(h.fd) }
	h.fd, h.wfd = -1, -1
	if h.pid > 0 {
		posix.kill(h.pid, .SIGTERM)
		append(&h.zombies, h.pid)
		h.pid = 0
	}
	clear(&h.buf)
}

@(private)
helper_destroy :: proc(h: ^Helper) {
	helper_stop(h)
	helper_reap(h)
	delete(h.buf)
	delete(h.zombies)
}

// Collect the helpers that have exited (never blocks).
@(private)
helper_reap :: proc(h: ^Helper) {
	for i := len(h.zombies) - 1; i >= 0; i -= 1 {
		status: i32
		r := posix.waitpid(h.zombies[i], &status, {.NOHANG})
		if r == 0 { continue }
		if r < 0 && posix.errno() == .EINTR { continue }
		unordered_remove(&h.zombies, i)
	}
}

// Answer the current prompt.
@(private)
helper_answer :: proc(h: ^Helper, text: string) -> bool {
	if h.wfd < 0 { return false }
	return write_line(h.wfd, text)
}

// What the helper said since the last call. The conversation is over after
// Success or Failure (also when the helper went away without a result).
@(private)
helper_read :: proc(h: ^Helper) -> []Helper_Event {
	out := make([dynamic]Helper_Event, context.temp_allocator)
	if h.fd < 0 { return out[:] }
	buf: [4096]u8
	ended := false
	for {
		n := posix.read(h.fd, &buf[0], len(buf))
		if n > 0 {
			append(&h.buf, ..buf[:n])
			continue
		}
		if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EWOULDBLOCK) { break }
		if n < 0 && posix.errno() == .EINTR { continue }
		ended = true // end of output or an error
		break
	}
	for {
		nl := -1
		for b, i in h.buf { if b == '\n' { nl = i; break } }
		if nl < 0 { break }
		line := strings.clone(string(h.buf[:nl]), context.temp_allocator)
		remove_range(&h.buf, 0, nl + 1)
		ev, ok := parse_helper_line(line)
		if !ok { continue }
		append(&out, ev)
		if ev.kind == .Success || ev.kind == .Failure {
			helper_stop(h)
			return out[:]
		}
	}
	if ended {
		log.warn("Polkit: the helper ended without a result")
		helper_stop(h)
		append(&out, Helper_Event{kind = .Failure})
	}
	return out[:]
}

@(private)
parse_helper_line :: proc(line: string) -> (Helper_Event, bool) {
	prefixes := [?]struct { p: string, kind: Helper_Event_Kind, echo: bool }{
		{"PAM_PROMPT_ECHO_OFF ", .Prompt, false},
		{"PAM_PROMPT_ECHO_ON ", .Prompt, true},
		{"PAM_ERROR_MSG ", .Error, false},
		{"PAM_TEXT_INFO ", .Info, false},
	}
	for x in prefixes {
		if strings.has_prefix(line, x.p) {
			return {kind = x.kind, text = unescape(line[len(x.p):]), echo = x.echo}, true
		}
	}
	switch {
	case strings.has_prefix(line, "SUCCESS"): return {kind = .Success}, true
	case strings.has_prefix(line, "FAILURE"): return {kind = .Failure}, true
	}
	log.debugf("Polkit: unknown line from the helper: %q", line)
	return {}, false
}

// Undo g_strescape (g_strcompress): \n \t \\ \" ... and octal \NNN.
@(private)
unescape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		if ch != '\\' || i + 1 >= len(s) {
			strings.write_byte(&b, ch)
			continue
		}
		i += 1
		switch s[i] {
		case 'b': strings.write_byte(&b, '\b')
		case 'f': strings.write_byte(&b, '\f')
		case 'n': strings.write_byte(&b, '\n')
		case 'r': strings.write_byte(&b, '\r')
		case 't': strings.write_byte(&b, '\t')
		case 'v': strings.write_byte(&b, '\v')
		case '0' ..= '7':
			v := 0
			j := i
			for j < len(s) && j < i + 3 && s[j] >= '0' && s[j] <= '7' {
				v = v * 8 + int(s[j] - '0')
				j += 1
			}
			strings.write_byte(&b, u8(v & 0xFF))
			i = j - 1
		case:
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Small POSIX helpers
// ---------------------------------------------------------------------------
@(private)
connect_unix :: proc(path: string) -> (posix.FD, bool) {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 { return -1, false }
	cloexec(fd)
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	if len(path) >= len(addr.sun_path) {
		posix.close(fd)
		return -1, false
	}
	for i in 0 ..< len(path) { addr.sun_path[i] = path[i] }
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		log.debugf("Polkit: cannot connect to %s: %v", path, posix.errno())
		posix.close(fd)
		return -1, false
	}
	nonblocking(fd)
	return fd, true
}

// Write `text` and a newline completely (the socket may be non-blocking).
@(private)
write_line :: proc(fd: posix.FD, text: string) -> bool {
	data := strings.concatenate({text, "\n"}, context.temp_allocator)
	defer secure_zero(transmute([]u8)data) // it may hold the password
	off: int = 0
	tries := 0
	for off < len(data) {
		left := len(data) - off
		n := int(posix.write(fd, raw_data(data[off:]), c.size_t(left)))
		if n > 0 {
			off += n
			continue
		}
		if n < 0 && posix.errno() == .EINTR { continue }
		if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EWOULDBLOCK) && tries < 100 {
			tries += 1
			time.sleep(2 * time.Millisecond)
			continue
		}
		return false
	}
	return true
}

@(private)
nonblocking :: proc(fd: posix.FD) {
	flags := posix.fcntl(fd, .GETFL)
	posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK)
}

@(private)
cloexec :: proc(fd: posix.FD) {
	posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
}

// Overwrite memory that held a password (never optimised away).
@(private)
secure_zero :: proc(b: []u8) {
	if len(b) > 0 { mem.zero_explicit(raw_data(b), len(b)) }
}
