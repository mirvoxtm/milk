// `milk update`: pull the milk clone and, next to it, Spoil's, lactase's and
// snippy's, rebuild them all and restart the running milk in place, and `milk
// restart`, which is that last step alone.
//
// Restarting in place: the running milk (usually the login session's
// process itself: killing it would end the session) is asked with SIGUSR1 to
// leave its loop the way it stops, letting every window go, and to execute
// the clone's launcher again in the same process, which keeps the session
// and every open window; the new build manages them again. Applications the
// old image started are still children of the process: the new one adopts
// them (adopt_children) so they never linger as zombies.
package milk

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import desktop "../desktop"

g_restart: bool

// The milk clone this binary was built from (<clone>/bin/milk), "" when unknown.
clone_dir :: proc(allocator := context.temp_allocator) -> string {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil { return "" }
	// After a rebuild the running image's file is gone: "/path/bin/milk (deleted)".
	exe = strings.trim_suffix(exe, " (deleted)")
	dir := filepath.dir(filepath.dir(exe))
	if !os.is_file(join({dir, "src", "milk", "main.odin"})) { return "" }
	return strings.clone(dir, allocator)
}

// Execute milk again in this process (after run() returned and every module
// let go of its windows and connections). Returns only when that failed.
restart_self :: proc() {
	args := make([dynamic]cstring, context.temp_allocator)
	path := ""
	if dir := clone_dir(); dir != "" && is_executable(join({dir, "milk"})) {
		path = join({dir, "milk"}) // the launcher: rebuilds when the sources are newer
	} else if exe, err := os.get_executable_path(context.temp_allocator); err == nil {
		path = strings.trim_suffix(exe, " (deleted)")
	}
	if path == "" { return }
	append(&args, strings.clone_to_cstring(path, context.temp_allocator))
	foreground := false
	for a in os.args[1:] {
		if a == "--foreground" || a == "-f" { foreground = true }
		append(&args, strings.clone_to_cstring(a, context.temp_allocator))
	}
	// Already detached (or the session's own process): never fork again.
	if !foreground { append(&args, "--foreground") }
	append(&args, nil)
	os.set_env("MILK_RESTARTED", "1")
	fmt.eprintfln("milk: restarting in place (%s)", path)
	posix.execv(strings.clone_to_cstring(path, context.temp_allocator), raw_data(args))
	fmt.eprintfln("milk: could not restart: %v", posix.errno())
}

@(private)
is_executable :: proc(path: string) -> bool {
	return os.is_file(path) && posix.access(strings.clone_to_cstring(path, context.temp_allocator), {.X_OK}) == .OK
}

// Children of this process that an earlier image of it started (it was
// restarted in place): reaped as they exit.
g_adopted: [dynamic]posix.pid_t

adopt_children :: proc() {
	me := os.get_pid()
	entries, err := os.read_all_directory_by_path("/proc", context.temp_allocator)
	if err != nil { return }
	for e in entries {
		pid, ok := strconv.parse_int(os.base(e.fullpath), 10)
		if !ok || pid == me { continue }
		data, rerr := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator)
		if rerr != nil { continue }
		// "pid (comm) state ppid ...": the command may contain spaces and parentheses.
		text := string(data)
		close := strings.last_index_byte(text, ')')
		if close < 0 { continue }
		fields := strings.fields(text[close + 1:], context.temp_allocator)
		if len(fields) < 2 { continue }
		if ppid, pok := strconv.parse_int(fields[1], 10); pok && ppid == me {
			append(&g_adopted, posix.pid_t(pid))
		}
	}
}

reap_adopted :: proc() {
	for i := len(g_adopted) - 1; i >= 0; i -= 1 {
		status: i32
		r := posix.waitpid(g_adopted[i], &status, {.NOHANG})
		if r == 0 { continue }
		if r < 0 && posix.errno() == .EINTR { continue }
		unordered_remove(&g_adopted, i)
	}
}

// `milk restart`: the running instance restarts in place; without one, start.
cmd_restart :: proc(opts: ^Options) -> int {
	pid_file := join({opts.runtime_root, PID_NAME})
	pid, running := running_pid(pid_file)
	if !running { return cmd_start(opts) }
	if !request_restart(pid, pid_file) { return 1 }
	return 0
}

// Ask the instance `pid` to restart in place and wait until the new image has
// written its pid file again.
@(private)
request_restart :: proc(pid: int, pid_file: string) -> bool {
	before := file_mtime(pid_file)
	if !catches_signal(pid, .SIGUSR1) {
		// The default action of SIGUSR1 is to end the process: the session with it.
		fmt.eprintln("The running milk is too old to restart in place; log out and back in to use the new build.")
		return false
	}
	if posix.kill(posix.pid_t(pid), .SIGUSR1) != .OK {
		fmt.eprintfln("Could not signal milk (pid %d)", pid)
		return false
	}
	for _ in 0 ..< 200 {
		time.sleep(50 * time.Millisecond)
		if file_mtime(pid_file) > before {
			if again, ok := running_pid(pid_file); ok {
				fmt.printfln("milk restarted in place (pid %d); your windows stay open", again)
				return true
			}
		}
	}
	fmt.eprintln("milk did not come back within 10 s; see the session log (~/.local/share/sddm/xorg-session.log)")
	return false
}

@(private)
file_mtime :: proc(path: string) -> i64 {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil { return 0 }
	return time.time_to_unix_nano(fi.modification_time)
}

// Run a command in `dir` with the terminal as its output; true on status 0.
@(private)
run_visible :: proc(argv: []string, dir: string = "", env_extra: []string = nil) -> bool {
	env: []string
	if len(env_extra) > 0 {
		base, _ := os.environ(context.temp_allocator)
		all := make([dynamic]string, context.temp_allocator)
		append(&all, ..base)
		append(&all, ..env_extra)
		env = all[:]
	}
	p, err := os.process_start(os.Process_Desc{command = argv, working_dir = dir, env = env,
	                                           stdout = os.stdout, stderr = os.stderr})
	if err != nil {
		fmt.eprintfln("  could not run %s: %v", argv[0], err)
		return false
	}
	state, werr := os.process_wait(p)
	return werr == nil && state.exited && state.exit_code == 0
}

// The output of a command (trimmed), "" on failure.
@(private)
run_output :: proc(argv: []string) -> string {
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = argv}, context.temp_allocator)
	if err != nil || !state.success { return "" }
	return strings.trim_space(string(stdout))
}

// `milk update [--check]` (opts.value = "check" for the check only).
cmd_update :: proc(opts: ^Options) -> int {
	clone := clone_dir()
	if clone == "" {
		fmt.eprintln("milk update: cannot tell which clone this milk was built from")
		return 1
	}
	if _, found := find_in_path("git"); !found {
		fmt.eprintln("milk update: git is not installed")
		return 1
	}
	parent := filepath.dir(clone)
	Repo :: struct { name, dir: string }
	repos := make([dynamic]Repo, context.temp_allocator)
	append(&repos, Repo{"milk", clone})
	for name in ([]string{"spoil", "lactase", "snippy"}) {
		dir := join({parent, name})
		if os.is_dir(join({dir, ".git"})) { append(&repos, Repo{name, dir}) }
	}
	check_only := opts.value == "check"

	if check_only {
		behind_any := false
		for r in repos {
			if !run_visible({"git", "-C", r.dir, "fetch", "--quiet"}) {
				fmt.printfln("%s: could not reach its remote", r.name)
				continue
			}
			count := run_output({"git", "-C", r.dir, "rev-list", "--count", "HEAD..@{upstream}"})
			if count == "" || count == "0" {
				fmt.printfln("%s: up to date", r.name)
			} else {
				fmt.printfln("%s: %s new commit(s)", r.name, count)
				behind_any = true
			}
		}
		return behind_any ? 10 : 0
	}

	fmt.printfln("Updating milk %s (%s)", VERSION, clone)
	failed := false
	for r in repos {
		fmt.printfln("\n== %s (%s)", r.name, r.dir)
		before := run_output({"git", "-C", r.dir, "rev-parse", "HEAD"})
		if !run_visible({"git", "-C", r.dir, "pull", "--ff-only"}) {
			fmt.printfln("  ! could not pull %s (local changes or a diverged branch?); building what is there", r.name)
		}
		after := run_output({"git", "-C", r.dir, "rev-parse", "HEAD"})
		if before != "" && after != "" && before != after {
			run_visible({"git", "-C", r.dir, "--no-pager", "log", "--oneline", "--no-decorate", fmt.tprintf("%s..%s", before, after)})
		}
		build := join({r.dir, "build.sh"})
		if !is_executable(build) { continue }
		env := []string{fmt.tprintf("MILK_SRC=%s", join({clone, "src"}))}
		if !run_visible({build}, r.dir, env if r.name != "milk" else nil) {
			fmt.printfln("  ✗ %s did not build; the previous binary stays", r.name)
			if r.name == "milk" { failed = true }
		}
	}
	if failed { return 1 }

	pid_file := join({opts.runtime_root, PID_NAME})
	pid, running := running_pid(pid_file)
	if !running {
		fmt.println("\n✓ Updated. milk is not running; the next start uses the new build.")
		return 0
	}
	// lactase first: the compositor is replaced while milk keeps managing the windows.
	if path, found := desktop.lactase_path(); found {
		if strings.has_prefix(run_output({path, "status"}), "lactase is running") {
			run_visible({path, "restart"})
		}
	}
	fmt.println()
	return request_restart(pid, pid_file) ? 0 : 1
}
