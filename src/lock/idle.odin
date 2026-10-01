// The idle manager, in the milk process: inactivity stages (dim, lock,
// monitors off, suspend), the lock screen's process, org.freedesktop.ScreenSaver
// on the session bus (screensaver.odin) and logind on the system bus
// (logind.odin).
//
// Inactivity comes from the X server's IDLETIME counter (SYNC extension)
// without polling: the counter is read only when the next stage could be
// due, and once a stage has fired (the screen is dimmed, off...) a SYNC alarm
// on the counter going down reports the first input at once. Inhibitors
// (ScreenSaver.Inhibit, optionally a fullscreen focused window) count as
// activity: the stages restart from when they end.
//
// The lock screen runs as `milk lock` (locker.odin), a child process: one at
// a time, started again when it dies without the user unlocking (that keeps
// the session locked), never replaced by a second one while any locker owns
// the _MILK_LOCKER_S<n> selection (`milk lock` started from a terminal
// included; XFixes reports when that one ends).
//
// Integration (milk/main.odin): offer every X event to handle_event, call
// tick every loop iteration, sleep at most next_timeout, poll poll_fds and
// call handle_fd for the ready ones.
package lock

import "base:runtime"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:sys/posix"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

DIM_LEVEL    :: 0.4  // brightness factor of a dimmed screen
DIM_IN_TIME  :: 2.5  // seconds to dim
DIM_OUT_TIME :: 0.25 // seconds to come back

@(private) LOCK_RETRIES    :: 8   // a lock screen that cannot start (another program holds the keyboard) is tried again this many times, 1 s to 15 s apart
@(private) RESTART_DELAY   :: 2.0 // seconds between attempts to bring back a lock screen that covered the screen
@(private) RELAUNCH_DELAY  :: 0.05
@(private) CRASH_WINDOW    :: 10.0
@(private) SLEEP_LOCK_WAIT :: 1.0 // seconds the suspend waits for the lock screen at most

Manager :: struct {
	c:            ^tx.Connection,
	cfg:          ^config.Config, // owned by the caller
	config_path:  string,         // owned
	runtime_root: string,         // owned
	verbose:      bool,
	allocator:    runtime.Allocator,

	// IDLETIME
	sync_event:   i32, // SYNC event base, -1 = no SYNC (no idle stages)
	idle_counter: XSyncCounter,
	reset_alarm:  XSyncAlarm, // fires on the next input after a stage
	activity_at:  f64,        // tx.now() of the last simulated activity (inhibitor, SimulateUserActivity, resume, unlock)
	last_idle:    f64,
	next_check:   f64,        // tx.now() of the next evaluation, -1 = on input only

	// Stages of the current idle period
	dim:          f64, // current brightness factor (animated)
	dim_from:     f64,
	dim_target:   f64,
	dim_start:    f64,
	dim_time:     f64,
	dim_applied:  f64,
	idle_locked:  bool,
	screen_off:   bool,
	suspended:    bool,
	dpms_known:   bool,
	dpms_ok:      bool,
	dpms_enabled_by_us: bool,
	// The X server's own blanking and DPMS timers, switched off while milk's
	// idle stages are configured (restored when they are not, and on exit).
	server_saver: struct {
		taken:                  bool,
		timeout, interval:      i32,
		blanking:               xlib.ScreenSaverBlanking,
		exposures:              xlib.ScreenSavingExposures,
		dpms:                   bool,
		standby, suspend, off:  u16,
	},

	// The lock screen
	locker_pid:   posix.pid_t,
	ready_fd:     posix.FD,   // the locker writes a byte once it covers the screen
	ready:        bool,
	covered:      bool,       // a lock screen covered the screen since the lock was asked for
	want_locked:  bool,       // locked, or a lock was asked for and is being retried
	external:     bool,       // a locker milk did not start holds the screen
	killing:      bool,       // milk is ending its own locker (logind Unlock)
	lock_failures: int,
	crash_times:  [4]f64,
	relaunch_at:  f64,        // 0 = none
	locked_at:    f64,
	lock_atom:    xlib.Atom,
	xfixes_event: i32,        // -1 = no XFixes

	// Suspend
	sleep_wait:     bool, // logind waits for the lock screen (delay inhibitor held)
	sleep_deadline: f64,

	ss: Screensaver,
	ld: Logind,
}

create :: proc(c: ^tx.Connection, cfg: ^config.Config, config_path, runtime_root: string, verbose := false) -> ^Manager {
	m := new(Manager)
	m.allocator = context.allocator
	m.c = c
	m.cfg = cfg
	m.config_path = strings.clone(config_path)
	m.runtime_root = strings.clone(runtime_root)
	m.verbose = verbose
	m.sync_event = -1
	m.xfixes_event = -1
	m.ready_fd = -1
	m.dim = 1
	m.dim_target = 1
	m.dim_applied = 1
	m.next_check = -1
	m.ld.inhibit_fd = -1
	m.activity_at = tx.now()
	init_idle_counter(m)
	m.lock_atom = lock_selection(c)
	ev, er: i32
	if XFixesQueryExtension(c.dpy, &ev, &er) {
		m.xfixes_event = ev
		XFixesSelectSelectionInput(c.dpy, c.root, m.lock_atom, XFIXES_SELECTION_ANY_MASK)
	}
	if locker_running(c) {
		// A lock screen from before milk (re)started.
		log.info("Lock: a lock screen is already running")
		m.external = true
		m.want_locked = true
		m.locked_at = tx.now()
	}
	ss_open(m)
	ld_open(m)
	sync_server_saver(m)
	m.next_check = tx.now()
	return m
}

destroy :: proc(m: ^Manager) {
	if m == nil { return }
	context.allocator = m.allocator
	// The lock screen outlives milk on purpose: the session stays locked.
	if m.locker_pid > 0 { log.info("Lock: milk stops; the lock screen keeps running") }
	if m.ready_fd >= 0 { posix.close(m.ready_fd) }
	destroy_reset_alarm(m)
	if m.screen_off { screen_on(m) }
	restore_server_saver(m)
	dim_shutdown(m.c)
	ss_close(m)
	ld_close(m)
	delete(m.config_path)
	delete(m.runtime_root)
	free(m)
}

// A new configuration (the caller owns it).
reload :: proc(m: ^Manager, cfg: ^config.Config) {
	if m == nil { return }
	context.allocator = m.allocator
	m.cfg = cfg
	ld_sync_inhibitor(m)
	sync_server_saver(m)
	m.next_check = tx.now()
}

// Whether the screen is locked (by milk's lock screen or another one).
is_locked :: proc(m: ^Manager) -> bool {
	return m != nil && (m.want_locked || m.external)
}

// The brightness factor of the idle dimming: 1 = normal, DIM_LEVEL = dimmed
// (animated between the two). apply_dim (dim.odin) receives every change.
idle_dim_factor :: proc(m: ^Manager) -> f64 {
	if m == nil { return 1 }
	return m.dim
}

// ---------------------------------------------------------------------------
// Loop integration
// ---------------------------------------------------------------------------
handle_event :: proc(m: ^Manager, ev: ^xlib.XEvent) -> bool {
	if m == nil { return false }
	context.allocator = m.allocator
	t := i32(ev.type)
	if m.sync_event >= 0 && t == m.sync_event + XSYNC_ALARM_NOTIFY {
		ae := (^XSyncAlarmNotifyEvent)(ev)
		if ae.alarm != m.reset_alarm || m.reset_alarm == 0 { return true }
		// Input after a stage: the alarm has done its job.
		destroy_reset_alarm(m)
		evaluate(m, tx.now())
		return true
	}
	if m.xfixes_event >= 0 && t == m.xfixes_event + XFIXES_SELECTION_NOTIFY {
		se := (^XFixesSelectionNotifyEvent)(ev)
		if se.selection != m.lock_atom { return false }
		selection_changed(m, se.owner)
		return true
	}
	return false
}

tick :: proc(m: ^Manager, now: f64) {
	if m == nil { return }
	context.allocator = m.allocator
	reap_locker(m, now)
	if m.relaunch_at > 0 && now >= m.relaunch_at {
		m.relaunch_at = 0
		if m.want_locked && m.locker_pid == 0 && !m.external {
			if locker_running(m.c) {
				m.external = true
			} else if !spawn_locker(m) {
				lock_given_up(m)
			}
		}
	}
	// The suspend goes on once the lock screen is up, when there is nothing
	// to wait for any more, or after SLEEP_LOCK_WAIT at most.
	gone := m.locker_pid == 0 && !m.external && m.relaunch_at == 0
	if m.sleep_wait && (m.ready || gone || now >= m.sleep_deadline) {
		if !m.ready && now >= m.sleep_deadline { log.warn("Lock: the lock screen was not ready in time; letting the computer sleep") }
		m.sleep_wait = false
		ld_release(m)
	}
	if m.next_check >= 0 && now >= m.next_check { evaluate(m, now) }
	animate_dim(m, now)
	if bus_busy(&m.ss.bus) { ss_pump(m, false) }
	if bus_busy(&m.ld.bus) { ld_pump(m, false) }
}

next_timeout :: proc(m: ^Manager, now: f64) -> f64 {
	if m == nil { return -1 }
	t := -1.0
	add :: proc(t: ^f64, v: f64) { if v >= 0 && (t^ < 0 || v < t^) { t^ = v } }
	if m.next_check >= 0 { add(&t, max(m.next_check - now, 0)) }
	if m.dim != m.dim_target { add(&t, 1.0 / 30) }
	if m.relaunch_at > 0 { add(&t, max(m.relaunch_at - now, 0)) }
	if m.sleep_wait { add(&t, max(m.sleep_deadline - now, 0)) }
	if m.locker_pid > 0 { add(&t, 1) } // reaping (SIGCHLD also wakes the loop)
	if bus_busy(&m.ss.bus) || bus_busy(&m.ld.bus) { add(&t, 0.01) }
	return t
}

poll_fds :: proc(m: ^Manager, allocator := context.temp_allocator) -> []i32 {
	if m == nil { return nil }
	fds := make([dynamic]i32, 0, 3, allocator)
	if m.ss.bus.fd >= 0 { append(&fds, m.ss.bus.fd) }
	if m.ld.bus.fd >= 0 { append(&fds, m.ld.bus.fd) }
	if m.ready_fd >= 0 { append(&fds, i32(m.ready_fd)) }
	return fds[:]
}

handle_fd :: proc(m: ^Manager, fd: i32) {
	if m == nil { return }
	context.allocator = m.allocator
	switch {
	case fd == m.ss.bus.fd && fd >= 0:
		ss_pump(m, true)
	case fd == m.ld.bus.fd && fd >= 0:
		ld_pump(m, true)
	case fd == i32(m.ready_fd) && fd >= 0:
		b: [1]u8
		n := posix.read(m.ready_fd, &b[0], 1)
		posix.close(m.ready_fd)
		m.ready_fd = -1
		if n == 1 {
			m.ready = true
			m.covered = true
			log.debug("Lock: the lock screen is up")
		}
	}
}

// ---------------------------------------------------------------------------
// Idle stages
// ---------------------------------------------------------------------------
@(private)
init_idle_counter :: proc(m: ^Manager) {
	dpy := m.c.dpy
	ev, er, major, minor: i32
	if !XSyncQueryExtension(dpy, &ev, &er) || XSyncInitialize(dpy, &major, &minor) == 0 {
		log.warn("Lock: the X server has no SYNC extension; the screen will not dim, lock or turn off by itself")
		return
	}
	n: i32
	list := XSyncListSystemCounters(dpy, &n)
	if list == nil { return }
	defer XSyncFreeSystemCounterList(list)
	for i in 0 ..< int(n) {
		if string(list[i].name) == "IDLETIME" {
			m.idle_counter = list[i].counter
			m.sync_event = ev
			return
		}
	}
	log.warn("Lock: the X server has no IDLETIME counter; the screen will not dim, lock or turn off by itself")
}

// Seconds without input (the server's counter, or less after a simulated activity).
idle_seconds :: proc(m: ^Manager, now: f64) -> (f64, bool) {
	if m.sync_event < 0 { return 0, false }
	v: XSyncValue
	if XSyncQueryCounter(m.c.dpy, m.idle_counter, &v) == 0 { return 0, false }
	raw := f64(sync_value_int(v)) / 1000
	return max(min(raw, now - m.activity_at), 0), true
}

// Something counts as activity without input (an inhibitor ended, a program
// called SimulateUserActivity, the computer resumed, the screen unlocked).
simulate_activity :: proc(m: ^Manager) {
	m.activity_at = tx.now()
	xlib.ResetScreenSaver(m.c.dpy) // also wakes monitors put to sleep by the server
	m.next_check = m.activity_at
}

@(private)
evaluate :: proc(m: ^Manager, now: f64) {
	m.next_check = -1
	idle, ok := idle_seconds(m, now)
	if !ok { return }
	if idle + 0.5 < m.last_idle { activity(m) }
	m.last_idle = idle
	ic := &m.cfg.idle
	due := stage_due(m, idle)
	if due && inhibited(m) {
		// Video, a presentation...: as good as input, checked again a full
		// period later.
		m.activity_at = now
		idle = 0
		m.last_idle = 0
		activity(m)
	} else if due {
		if ic.dim_after > 0 && idle >= f64(ic.dim_after) && m.dim_target == 1 {
			log.debugf("Lock: idle for %.0f s, dimming", idle)
			set_dim_target(m, DIM_LEVEL, DIM_IN_TIME)
		}
		if m.cfg.lock.enabled && ic.lock_after > 0 && idle >= f64(ic.lock_after) && !m.idle_locked {
			m.idle_locked = true
			if !is_locked(m) {
				log.infof("Lock: idle for %.0f s, locking", idle)
				lock_now(m, "idle")
			}
		}
		if ic.screen_off_after > 0 && idle >= f64(ic.screen_off_after) && !m.screen_off {
			m.screen_off = true
			log.infof("Lock: idle for %.0f s, turning the monitors off", idle)
			screen_off(m)
		}
		if ic.suspend_after > 0 && idle >= f64(ic.suspend_after) && !m.suspended {
			m.suspended = true
			log.infof("Lock: idle for %.0f s, suspending", idle)
			ld_call(m, "Suspend", false)
		}
	}
	// The next stage still ahead.
	next := -1.0
	consider :: proc(next: ^f64, threshold: int, idle: f64, fired: bool) {
		if threshold <= 0 || fired { return }
		t := f64(threshold)
		if t <= idle { return }
		if next^ < 0 || t < next^ { next^ = t }
	}
	consider(&next, ic.dim_after, idle, m.dim_target != 1)
	consider(&next, m.cfg.lock.enabled ? ic.lock_after : 0, idle, m.idle_locked)
	consider(&next, ic.screen_off_after, idle, m.screen_off)
	consider(&next, ic.suspend_after, idle, m.suspended)
	if next >= 0 { m.next_check = now + (next - idle) + 0.02 }
	if m.dim_target != 1 || m.idle_locked || m.screen_off || m.suspended { arm_reset_alarm(m) }
}

// Some stage would fire at `idle` seconds.
@(private)
stage_due :: proc(m: ^Manager, idle: f64) -> bool {
	ic := &m.cfg.idle
	if ic.dim_after > 0 && idle >= f64(ic.dim_after) && m.dim_target == 1 { return true }
	if m.cfg.lock.enabled && ic.lock_after > 0 && idle >= f64(ic.lock_after) && !m.idle_locked { return true }
	if ic.screen_off_after > 0 && idle >= f64(ic.screen_off_after) && !m.screen_off { return true }
	if ic.suspend_after > 0 && idle >= f64(ic.suspend_after) && !m.suspended { return true }
	return false
}

// Input (or its equivalent) after an idle period: undo the stages.
@(private)
activity :: proc(m: ^Manager) {
	if m.dim_target != 1 {
		log.debug("Lock: activity, undimming")
		set_dim_target(m, 1, DIM_OUT_TIME)
	}
	if m.screen_off { screen_on(m) }
	m.screen_off = false
	m.idle_locked = false
	m.suspended = false
	destroy_reset_alarm(m)
}

// Inhibitors: ScreenSaver.Inhibit calls, and the focused window being
// fullscreen when idle.inhibitFullscreen is on.
@(private)
inhibited :: proc(m: ^Manager) -> bool {
	if len(m.ss.inhibitors) > 0 {
		log.debugf("Lock: idle held off by %s", m.ss.inhibitors[0].app)
		return true
	}
	if m.cfg.idle.inhibit_fullscreen && fullscreen_focused(m.c) {
		log.debug("Lock: idle held off by a fullscreen window")
		return true
	}
	return false
}

@(private)
fullscreen_focused :: proc(c: ^tx.Connection) -> bool {
	win, ok := tx.get_window(c, c.root, "_NET_ACTIVE_WINDOW")
	if !ok || win == 0 { return false }
	full := tx.atom(c, "_NET_WM_STATE_FULLSCREEN")
	for a in tx.get_atoms(c, win, "_NET_WM_STATE") {
		if a == full { return true }
	}
	return false
}

// An alarm on the next input (the counter going down).
@(private)
arm_reset_alarm :: proc(m: ^Manager) {
	if m.sync_event < 0 || m.reset_alarm != 0 { return }
	attrs: XSyncAlarmAttributes
	attrs.trigger.counter = m.idle_counter
	attrs.trigger.value_type = XSYNC_ABSOLUTE
	attrs.trigger.wait_value = sync_value(1)
	attrs.trigger.test_type = XSYNC_NEGATIVE_TRANSITION
	attrs.delta = sync_value(0)
	attrs.events = true
	mask := XSYNC_CA_COUNTER | XSYNC_CA_VALUE_TYPE | XSYNC_CA_VALUE | XSYNC_CA_TEST_TYPE | XSYNC_CA_DELTA | XSYNC_CA_EVENTS
	m.reset_alarm = XSyncCreateAlarm(m.c.dpy, mask, &attrs)
	tx.flush(m.c)
}

@(private)
destroy_reset_alarm :: proc(m: ^Manager) {
	if m.reset_alarm == 0 { return }
	XSyncDestroyAlarm(m.c.dpy, m.reset_alarm)
	m.reset_alarm = 0
	tx.flush(m.c)
}

@(private)
set_dim_target :: proc(m: ^Manager, target: f64, seconds: f64) {
	if m.dim_target == target { return }
	m.dim_from = m.dim
	m.dim_target = target
	m.dim_start = tx.now()
	m.dim_time = seconds
}

@(private)
animate_dim :: proc(m: ^Manager, now: f64) {
	if m.dim == m.dim_target { return }
	t := m.dim_time > 0 ? (now - m.dim_start) / m.dim_time : 1
	if t >= 1 {
		m.dim = m.dim_target
	} else {
		e := t * t * (3 - 2 * t) // smoothstep
		m.dim = m.dim_from + (m.dim_target - m.dim_from) * e
	}
	if math.abs(m.dim - m.dim_applied) >= 0.004 || m.dim == m.dim_target {
		apply_dim(m.c, m.dim)
		m.dim_applied = m.dim
	}
}

// With any idle stage configured milk decides when the screen blanks: the
// server's screen saver and DPMS timers (600 s by default on Xorg) would
// otherwise turn the monitors off on their own, inhibitors or not.
@(private)
sync_server_saver :: proc(m: ^Manager) {
	ic := &m.cfg.idle
	wanted := ic.dim_after > 0 || ic.lock_after > 0 || ic.screen_off_after > 0 || ic.suspend_after > 0
	if !wanted {
		restore_server_saver(m)
		return
	}
	sv := &m.server_saver
	if sv.taken { return }
	dpy := m.c.dpy
	xlib.GetScreenSaver(dpy, &sv.timeout, &sv.interval, &sv.blanking, &sv.exposures)
	xlib.SetScreenSaver(dpy, 0, sv.interval, sv.blanking, sv.exposures)
	ev, er: i32
	sv.dpms = bool(DPMSQueryExtension(dpy, &ev, &er)) && bool(DPMSCapable(dpy))
	if sv.dpms {
		DPMSGetTimeouts(dpy, &sv.standby, &sv.suspend, &sv.off)
		DPMSSetTimeouts(dpy, 0, 0, 0)
	}
	sv.taken = true
	tx.flush(m.c)
	log.debugf("Lock: the X server's own screen saver (%d s) and DPMS timers are off while milk handles idle", sv.timeout)
}

@(private)
restore_server_saver :: proc(m: ^Manager) {
	sv := &m.server_saver
	if !sv.taken { return }
	dpy := m.c.dpy
	xlib.SetScreenSaver(dpy, sv.timeout, sv.interval, sv.blanking, sv.exposures)
	if sv.dpms { DPMSSetTimeouts(dpy, sv.standby, sv.suspend, sv.off) }
	sv.taken = false
	tx.flush(m.c)
}

@(private)
screen_off :: proc(m: ^Manager) {
	dpy := m.c.dpy
	if !m.dpms_known {
		m.dpms_known = true
		ev, er: i32
		m.dpms_ok = bool(DPMSQueryExtension(dpy, &ev, &er)) && bool(DPMSCapable(dpy))
		if !m.dpms_ok { log.info("Lock: the X server has no DPMS; the monitors stay on") }
	}
	if !m.dpms_ok { return }
	level: u16
	state: u8
	DPMSInfo(dpy, &level, &state)
	if state == 0 {
		DPMSEnable(dpy)
		m.dpms_enabled_by_us = true
	}
	DPMSForceLevel(dpy, DPMS_MODE_OFF)
	tx.flush(m.c)
}

@(private)
screen_on :: proc(m: ^Manager) {
	if !m.dpms_ok { return }
	dpy := m.c.dpy
	DPMSForceLevel(dpy, DPMS_MODE_ON)
	if m.dpms_enabled_by_us {
		DPMSDisable(dpy)
		m.dpms_enabled_by_us = false
	}
	tx.flush(m.c)
}

// ---------------------------------------------------------------------------
// The lock screen process
// ---------------------------------------------------------------------------

// Lock the screen now (the lock action, the session menu, `milk lock`,
// logind, ScreenSaver.Lock, idle, suspend).
lock_now :: proc(m: ^Manager, reason: string) {
	if m == nil { return }
	context.allocator = m.allocator
	if m.want_locked && (m.locker_pid > 0 || m.relaunch_at > 0 || m.external) { return }
	m.want_locked = true
	m.lock_failures = 0
	m.ready = false
	m.covered = false
	if locker_running(m.c) {
		log.infof("Lock: %s: a lock screen is already running", reason)
		m.external = true
		announce_locked(m)
		return
	}
	log.infof("Lock: locking the screen (%s)", reason)
	if !spawn_locker(m) {
		lock_given_up(m)
		return
	}
	announce_locked(m)
}

// The session asked to unlock (logind Unlock): end milk's lock screen.
unlock_requested :: proc(m: ^Manager) {
	m.relaunch_at = 0
	if m.locker_pid > 0 {
		log.info("Lock: the session was unlocked; closing the lock screen")
		m.killing = true
		posix.kill(m.locker_pid, .SIGTERM)
		return
	}
	if m.external { log.info("Lock: the session was unlocked, but the lock screen was not started by this milk; it stays") }
	if m.want_locked && !m.external { unlocked(m) }
}

@(private)
announce_locked :: proc(m: ^Manager) {
	m.locked_at = tx.now()
	ss_active_changed(m, true)
	ld_set_locked_hint(m, true)
}

@(private)
unlocked :: proc(m: ^Manager) {
	was := m.want_locked || m.external
	m.want_locked = false
	m.external = false
	m.killing = false
	m.ready = false
	m.covered = false
	m.relaunch_at = 0
	m.lock_failures = 0
	if !was { return }
	simulate_activity(m)
	ss_active_changed(m, false)
	ld_set_locked_hint(m, false)
}

@(private)
lock_given_up :: proc(m: ^Manager) {
	log.error("Lock: could not lock the screen")
	m.want_locked = false
	m.relaunch_at = 0
	ss_active_changed(m, false)
	ld_set_locked_hint(m, false)
}

// The lock selection changed owner: a locker started or ended.
@(private)
selection_changed :: proc(m: ^Manager, owner: xlib.Window) {
	if owner != 0 {
		if m.locker_pid > 0 {
			m.ready = true // milk's own lock screen is up
			m.covered = true
		} else if !m.external {
			log.info("Lock: a lock screen started outside milk")
			m.external = true
			m.want_locked = true
			announce_locked(m)
		}
		return
	}
	if m.external && m.locker_pid == 0 {
		log.info("Lock: the lock screen ended")
		unlocked(m)
	}
}

// Start `milk lock` with the ready pipe on fd 3.
@(private)
spawn_locker :: proc(m: ^Manager) -> bool {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		log.errorf("Lock: cannot find milk's executable: %v", err)
		return false
	}
	exe = strings.trim_suffix(exe, " (deleted)") // argv[0] only: /proc/self/exe is what runs
	// Everything the child needs is prepared before fork(). The child runs
	// /proc/self/exe: this milk's own code even when a rebuild replaced the
	// file (the path then reads "... (deleted)").
	args := make([dynamic]cstring, context.temp_allocator)
	cs :: proc(s: string) -> cstring { return strings.clone_to_cstring(s, context.temp_allocator) }
	append(&args, cs(exe), "lock", "--config", cs(m.config_path), "--runtime-root", cs(m.runtime_root))
	if m.verbose { append(&args, "--verbose") }
	append(&args, nil)
	env := make([dynamic]cstring, context.temp_allocator)
	if vars, eerr := os.environ(context.temp_allocator); eerr == nil {
		for v in vars {
			if strings.has_prefix(v, READY_FD_ENV + "=") { continue }
			append(&env, cs(v))
		}
	}
	append(&env, READY_FD_ENV + "=3")
	append(&env, nil)
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		log.error("Lock: cannot create a pipe for the lock screen")
		return false
	}
	posix.fcntl(fds[0], .SETFD, posix.FD_CLOEXEC)
	signals := [?]posix.Signal{.SIGPIPE, .SIGCHLD, .SIGHUP, .SIGINT, .SIGTERM, .SIGQUIT, .SIGUSR1, .SIGUSR2}
	path: cstring = "/proc/self/exe"
	if !os.exists("/proc/self/exe") { path = args[0] }

	pid := posix.fork()
	if pid < 0 {
		posix.close(fds[0])
		posix.close(fds[1])
		log.error("Lock: cannot start the lock screen (fork failed)")
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
		if fds[1] != 3 { posix.dup2(fds[1], 3) }
		for fd in 4 ..< 1024 { posix.close(posix.FD(fd)) }
		posix.execve(path, raw_data(args[:]), raw_data(env[:]))
		posix._exit(127)
	}
	posix.close(fds[1])
	if m.ready_fd >= 0 { posix.close(m.ready_fd) }
	m.ready_fd = fds[0]
	m.locker_pid = pid
	m.ready = false
	log.debugf("Lock: lock screen started (pid %d)", pid)
	return true
}

@(private)
reap_locker :: proc(m: ^Manager, now: f64) {
	if m.locker_pid <= 0 { return }
	status: i32
	r := posix.waitpid(m.locker_pid, &status, {.NOHANG})
	if r == 0 { return }
	if r < 0 && posix.errno() == .EINTR { return }
	pid := m.locker_pid
	m.locker_pid = 0
	if m.ready_fd >= 0 {
		posix.close(m.ready_fd)
		m.ready_fd = -1
	}
	exited := r > 0 && posix.WIFEXITED(status)
	code := exited ? int(posix.WEXITSTATUS(status)) : -1
	switch {
	case m.killing:
		unlocked(m)
	case exited && code == LOCKER_EXIT_UNLOCKED:
		log.info("Lock: unlocked")
		unlocked(m)
	case exited && code == LOCKER_EXIT_ALREADY:
		// Another locker holds the screen; XFixes reports when it ends.
		m.external = true
	case !m.ready && !m.covered:
		// It never covered the screen (no grab, exec failed, crashed while
		// starting): a few more tries, then the lock is given up, honestly.
		m.lock_failures += 1
		if m.lock_failures > LOCK_RETRIES {
			lock_given_up(m)
		} else {
			delay := min(f64(int(1) << uint(m.lock_failures - 1)), 15)
			log.warnf("Lock: the lock screen could not start (status %d, attempt %d); trying again in %.0f s", code, m.lock_failures, delay)
			m.relaunch_at = now + delay
		}
	case !m.ready:
		// The session was locked and the lock screen keeps failing to come
		// back: keep trying, the session must not be left unlocked.
		m.lock_failures += 1
		if m.lock_failures <= LOCK_RETRIES || m.lock_failures % 30 == 0 {
			log.errorf("Lock: the lock screen cannot start again (status %d); retrying", code)
		}
		m.relaunch_at = now + RESTART_DELAY
	case:
		// Crashed or killed by someone else: the session must stay locked.
		if r > 0 && posix.WIFSIGNALED(status) {
			log.warnf("Lock: the lock screen (pid %d) died of signal %d; starting it again", pid, posix.WTERMSIG(status))
		} else {
			log.warnf("Lock: the lock screen (pid %d) stopped unexpectedly (status %d); starting it again", pid, code)
		}
		m.lock_failures = 0
		recent := 0
		for t in m.crash_times { if t > 0 && now - t < CRASH_WINDOW { recent += 1 } }
		copy(m.crash_times[1:], m.crash_times[:len(m.crash_times) - 1])
		m.crash_times[0] = now
		m.relaunch_at = now + (recent >= 3 ? 1.0 : RELAUNCH_DELAY)
	}
}

// ---------------------------------------------------------------------------
// The session menu (milk/main.odin)
// ---------------------------------------------------------------------------

// Whether logind can be asked to suspend, reboot or power off.
can_power :: proc(m: ^Manager) -> bool {
	return m != nil && m.ld.bus.conn != nil
}

// "Suspend" | "Reboot" | "PowerOff" through logind (interactive: polkit may ask).
power_action :: proc(m: ^Manager, method: string) {
	if m == nil { return }
	context.allocator = m.allocator
	log.infof("Lock: asking logind to %s", method)
	ld_call(m, method, true)
}
