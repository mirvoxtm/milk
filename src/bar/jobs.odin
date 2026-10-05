// Helper processes. The bar never blocks the shared event loop on a child:
// every query runs as a job whose stdout is a pipe exposed through
// `poll_fds`, and every child (jobs and detached click commands) is reaped
// with waitpid(WNOHANG) from `tick`.
package bar

import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import tx "../tx"

// External tools the bar can use; detected once per configuration.
Tools :: struct {
	wpctl, pactl, amixer: bool,
	playerctl, busctl:    bool,
	brightnessctl:        bool,
	rsvg_convert:         bool,
	setsid:               bool,
	nmcli:                bool,
	nm_connection_editor: bool,
	bluetoothctl:         bool,
	rfkill:               bool,
}

Job_Kind :: enum {
	Volume_Query,      // stdout parsed into the volume state
	Volume_Change,     // set-volume / mute toggle; the volume is queried again afterwards
	Volume_Set,        // absolute value from the slider; the next pending value follows
	Brightness_Change, // brightnessctl / logind; sysfs is read again afterwards
	Media_Poll,        // busctl snapshot of every MPRIS player
	Media_Stream,      // long-running `playerctl --follow`
	Media_Control,     // play/pause
	Wifi_State,        // radio, devices and saved profiles (Wi-Fi menu)
	Wifi_List,         // visible networks (Wi-Fi menu)
	Wifi_Action,       // radio on/off, connect, disconnect; tag = SSID
	Bt_State,          // adapter, paired and discovered devices (Bluetooth menu)
	Bt_Scan,           // timed discovery
	Bt_Action,         // power, connect, disconnect, pair/trust steps; tag = MAC
	Audio_Query,       // outputs and inputs (the volume card)
	Audio_Set,         // the default output or input
	Script_Run,        // a script widget's command (scripts.odin); tag = the script
	Script_Tail,       // a script widget's command that keeps running, read line by line
	Script_Action,     // a script widget's click or scroll command; left running when the bar goes
}

Job :: struct {
	kind:    Job_Kind,
	pid:     posix.pid_t,
	file:    ^os.File, // read end of the child's stdout; nil when not captured or already closed
	fd:      i32,
	output:  [dynamic]u8,
	started: f64,
	timeout: f64, // seconds; 0 = no limit
	exited:  bool,
	status:  i32, // raw wait status, -1 when unknown
	tag:     string, // owned: what the job is about (an SSID, a MAC)
	step:    int,    // position in a multi-step action
	group:   bool,   // the child leads its own process group (setsid): signals reach what it started too
	killed:  bool,   // stopped for running past its timeout
}

JOB_TIMEOUT :: 5.0

@(private)
detect_tools :: proc(b: ^Bar) {
	b.tools = Tools{
		wpctl         = find_tool("wpctl"),
		pactl         = find_tool("pactl"),
		amixer        = find_tool("amixer"),
		playerctl     = find_tool("playerctl"),
		busctl        = find_tool("busctl"),
		brightnessctl = find_tool("brightnessctl"),
		rsvg_convert  = find_tool("rsvg-convert"),
		setsid        = find_tool("setsid"),
		nmcli         = find_tool("nmcli"),
		nm_connection_editor = find_tool("nm-connection-editor"),
		bluetoothctl  = find_tool("bluetoothctl"),
		rfkill        = find_tool("rfkill"),
	}
}

// Whether an executable called `name` exists somewhere in $PATH.
@(private)
find_tool :: proc(name: string) -> bool {
	path := os.get_env("PATH", context.temp_allocator)
	if path == "" { path = "/usr/local/bin:/usr/bin:/bin" }
	for dir in strings.split(path, ":", context.temp_allocator) {
		if dir == "" { continue }
		full := strings.concatenate({dir, "/", name}, context.temp_allocator)
		if posix.access(strings.clone_to_cstring(full, context.temp_allocator), {.X_OK}) == .OK && os.is_file(full) {
			return true
		}
	}
	return false
}

// Start `argv` with stdin/stderr on /dev/null and stdout on `stdout` (or /dev/null).
@(private)
spawn :: proc(argv: []string, stdout: ^os.File = nil, stderr: ^os.File = nil) -> (pid: posix.pid_t, ok: bool) {
	p, err := os.process_start(os.Process_Desc{command = argv, stdout = stdout, stderr = stderr})
	if err != nil {
		log.debugf("Could not start %s: %v", argv[0], err)
		return 0, false
	}
	// Children are reaped with waitpid(WNOHANG); the pidfd handle is not needed.
	if p.handle != 0 && p.handle != ~uintptr(0) { posix.close(posix.FD(p.handle)) }
	return posix.pid_t(p.pid), true
}

// Run a user command through `sh -c`, detached into its own session so it
// survives the bar (and the bar never waits for it).
@(private)
run_detached :: proc(b: ^Bar, command: string) {
	if strings.trim_space(command) == "" { return }
	argv: []string
	if b.tools.setsid {
		argv = {"setsid", "-f", "sh", "-c", command}
	} else {
		argv = {"sh", "-c", command}
	}
	pid, ok := spawn(argv)
	if !ok {
		log.warnf("Could not run bar command: %s", command)
		return
	}
	log.debugf("Bar command started (pid %d): %s", pid, command)
	append(&b.children, pid)
}

// `sh -c command` as the leader of a new session and process group when
// setsid exists, so that killing the group stops whatever the command started.
@(private)
group_argv :: proc(b: ^Bar, command: string, allocator := context.temp_allocator) -> []string {
	argv := make([dynamic]string, 0, 4, allocator)
	if b.tools.setsid { append(&argv, "setsid") }
	append(&argv, "sh", "-c", command)
	return argv[:]
}

// Start a helper process; with `capture` its stdout (and with `merge_stderr`
// its stderr too, for error messages) is collected through a pipe.
@(private)
start_job :: proc(b: ^Bar, kind: Job_Kind, argv: []string, capture: bool, timeout: f64 = JOB_TIMEOUT, merge_stderr := false, tag := "", step := 0) -> ^Job {
	r, w: ^os.File
	if capture {
		err: os.Error
		r, w, err = os.pipe()
		if err != nil {
			log.warnf("Could not create a pipe for %s: %v", argv[0], err)
			return nil
		}
	}
	pid, ok := spawn(argv, w, merge_stderr ? w : nil)
	if w != nil { os.close(w) } // the child holds the write end now
	if !ok {
		if r != nil { os.close(r) }
		return nil
	}
	job := new(Job)
	job.kind = kind
	job.pid = pid
	job.fd = -1
	job.started = tx.now()
	job.timeout = timeout
	job.status = -1
	job.tag = strings.clone(tag)
	job.step = step
	if r != nil {
		job.file = r
		job.fd = i32(os.fd(r))
	}
	append(&b.jobs, job)
	return job
}

@(private)
find_job :: proc(b: ^Bar, fd: i32) -> ^Job {
	for job in b.jobs {
		if job.file != nil && job.fd == fd { return job }
	}
	return nil
}

@(private)
close_job_pipe :: proc(job: ^Job) {
	if job.file != nil {
		os.close(job.file)
		job.file = nil
		job.fd = -1
	}
}

// Read whatever is available on a job's pipe without blocking. Returns false
// when nothing was readable.
@(private)
read_job :: proc(b: ^Bar, job: ^Job) -> bool {
	if job.file == nil { return false }
	pfd := posix.pollfd{fd = posix.FD(job.fd), events = {.IN}}
	if posix.poll(&pfd, 1, 0) <= 0 { return false }
	buf: [16384]u8
	n := posix.read(posix.FD(job.fd), raw_data(buf[:]), len(buf))
	if n > 0 {
		#partial switch job.kind {
		case .Script_Run:
			// Only the first line counts: a command that prints a lot is not kept whole.
			if len(job.output) < SCRIPT_OUTPUT_MAX { append(&job.output, ..buf[:min(int(n), SCRIPT_OUTPUT_MAX - len(job.output))]) }
		case:
			append(&job.output, ..buf[:n])
		}
		if job.kind == .Media_Stream { media_stream_input(b, job) }
		if job.kind == .Script_Tail { script_tail_input(b, job) }
		return true
	}
	if n < 0 {
		errno := posix.errno()
		if errno == .EINTR || errno == .EAGAIN { return false }
	}
	close_job_pipe(job) // EOF (or a broken pipe)
	return true
}

// Reap finished jobs, enforce timeouts and dispatch results.
@(private)
service_jobs :: proc(b: ^Bar, now: f64) {
	for i := len(b.jobs) - 1; i >= 0; i -= 1 {
		job := b.jobs[i]
		if !job.exited {
			status: i32
			r := posix.waitpid(job.pid, &status, {.NOHANG})
			if r == job.pid {
				job.exited = true
				job.status = status
			} else if r < 0 {
				job.exited = true // already reaped elsewhere
			} else if job.timeout > 0 && now - job.started > job.timeout {
				log.debugf("Bar helper %v (pid %d) timed out; killing it", job.kind, job.pid)
				signal_job(job, .SIGKILL)
				job.timeout = 0
				job.killed = true
			}
		}
		if !job.exited { continue }
		// The child is gone: take what is left in the pipe, then close it even
		// if a grandchild still holds the write end.
		for _ in 0 ..< 64 {
			if !read_job(b, job) { break }
		}
		close_job_pipe(job)
		ordered_remove(&b.jobs, i)
		finish_job(b, job, now)
		free_job(job)
	}
}

@(private)
job_succeeded :: proc(job: ^Job) -> bool {
	return job.status >= 0 && posix.WIFEXITED(job.status) && posix.WEXITSTATUS(job.status) == 0
}

@(private)
finish_job :: proc(b: ^Bar, job: ^Job, now: f64) {
	switch job.kind {
	case .Volume_Query:
		volume_query_done(b, string(job.output[:]), job_succeeded(job))
	case .Volume_Change:
		request_volume_refresh(b)
	case .Volume_Set:
		volume_set_done(b)
	case .Brightness_Change:
		brightness_set_done(b)
	case .Media_Poll:
		media_poll_done(b, string(job.output[:]), now)
	case .Media_Stream:
		media_stream_ended(b, job, now)
	case .Media_Control:
		media_control_done(b, now)
	case .Wifi_State, .Wifi_List, .Wifi_Action:
		wifi_job_done(b, job)
	case .Bt_State, .Bt_Scan, .Bt_Action:
		bt_job_done(b, job)
	case .Audio_Query, .Audio_Set:
		audio_job_done(b, job)
	case .Script_Run, .Script_Tail, .Script_Action:
		script_job_done(b, job, now)
	}
}

// Send `sig` to the job's process, and to its whole group when it leads one.
@(private)
signal_job :: proc(job: ^Job, sig: posix.Signal) {
	if job.group { posix.kill(-job.pid, sig) }
	posix.kill(job.pid, sig)
}

@(private)
free_job :: proc(job: ^Job) {
	close_job_pipe(job)
	delete(job.output)
	delete(job.tag)
	free(job)
}

// Stop every helper (used by destroy): kill, then reap synchronously. The
// commands a script widget's click started belong to the user and keep running.
@(private)
kill_jobs :: proc(b: ^Bar) {
	for job in b.jobs {
		if !job.exited && job.kind != .Script_Action {
			signal_job(job, .SIGKILL)
			status: i32
			posix.waitpid(job.pid, &status, {})
		}
		free_job(job)
	}
	clear(&b.jobs)
}

@(private)
kill_job :: proc(b: ^Bar, target: ^Job) {
	for job, i in b.jobs {
		if job != target { continue }
		if !job.exited {
			signal_job(job, .SIGKILL)
			status: i32
			posix.waitpid(job.pid, &status, {})
		}
		ordered_remove(&b.jobs, i)
		free_job(job)
		return
	}
}

// Reap detached click commands.
@(private)
reap_children :: proc(b: ^Bar) {
	for i := len(b.children) - 1; i >= 0; i -= 1 {
		status: i32
		r := posix.waitpid(b.children[i], &status, {.NOHANG})
		if r == b.children[i] || r < 0 { unordered_remove(&b.children, i) }
	}
}
