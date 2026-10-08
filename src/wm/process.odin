// Commands launched from key bindings (dwm's spawn) and their reaping.
package wm

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"

// Run `cmd` through `/bin/sh -c`, detached: own session, empty signal mask,
// default signal dispositions, stdin from /dev/null (stdout/stderr are
// inherited, like dwm), no other inherited descriptors (the X connection is
// closed) and $HOME as the working directory.
spawn_command :: proc(m: ^Manager, cmd: string) -> bool {
	if strings.trim_space(cmd) == "" { return false }
	line := expand_milk(cmd)
	// Everything the child needs is prepared before fork(): after it, the child
	// only makes async-signal-safe calls.
	argv := [4]cstring{"/bin/sh", "-c", strings.clone_to_cstring(line, context.temp_allocator), nil}
	home, _ := os.lookup_env("HOME", context.temp_allocator)
	chome := strings.clone_to_cstring(home, context.temp_allocator)
	has_home := home != ""
	signals := [?]posix.Signal{.SIGPIPE, .SIGCHLD, .SIGHUP, .SIGINT, .SIGTERM, .SIGQUIT, .SIGUSR1, .SIGUSR2}

	pid := posix.fork()
	if pid < 0 {
		log.errorf("wm: cannot run %q: fork failed (%v)", cmd, posix.errno())
		return false
	}
	if pid == 0 {
		posix.setsid()
		empty: posix.sigset_t
		posix.sigemptyset(&empty)
		posix.sigprocmask(.SETMASK, &empty, nil)
		for sig in signals { posix.signal(sig, auto_cast posix.SIG_DFL) }
		null := posix.open("/dev/null", {.RDWR})
		if null >= 0 { posix.dup2(null, 0) }
		for fd in 3 ..< 1024 { posix.close(posix.FD(fd)) }
		if has_home { posix.chdir(chome) }
		posix.execv("/bin/sh", raw_data(argv[:]))
		posix._exit(127)
	}
	append(&m.children, pid)
	log.debugf("wm: started %q (pid %d)", cmd, pid)
	return true
}

// Reap spawned commands that have exited (never blocks).
reap_children :: proc(m: ^Manager) {
	for i := len(m.children) - 1; i >= 0; i -= 1 {
		status: i32
		r := posix.waitpid(m.children[i], &status, {.NOHANG})
		if r == 0 { continue } // still running
		if r < 0 && posix.errno() == .EINTR { continue }
		if r > 0 && posix.WIFEXITED(status) && posix.WEXITSTATUS(status) != 0 {
			log.debugf("wm: command %d exited with status %d", r, posix.WEXITSTATUS(status))
		}
		// Exited, or not our child any more (ECHILD): forget it.
		unordered_remove(&m.children, i)
	}
}

// milk: "milk …" at the start of a command (the default launcher, "milk
// launcher") is the milk that runs, not whatever the PATH finds: no rebuild
// check through the clone's launcher script, and no dependence on ~/.local/bin.
// After a rebuild the running image's file is gone ("/path/bin/milk (deleted)"):
// the new binary at that path runs instead.
expand_milk :: proc(cmd: string) -> string {
	s := strings.trim_left_space(cmd)
	if s != "milk" && !strings.has_prefix(s, "milk ") { return cmd }
	exe, err := os.get_executable_path(context.temp_allocator)
	exe = strings.trim_suffix(exe, " (deleted)")
	if err != nil || strings.index_byte(exe, '\'') >= 0 { return cmd }
	return fmt.tprintf("'%s'%s", exe, s[len("milk"):])
}
