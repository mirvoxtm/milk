// milk addition: the lock screen and the session menu.
//
// `milk lock` asks the running milk to lock (SIGUSR2; its idle manager then
// runs and watches the lock screen) and only locks by itself when no milk
// runs or the running one does not answer. The bar's power button opens the
// session menu: Lock, Suspend, Log out (milk quits, which ends the session),
// Restart and Power off (through logind; package lock).
package milk

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
import lock "../lock"
import menu "../menu"
import nightlight "../nightlight"
import notify "../notify"
import tx "../tx"

@(private="file") SESSION_LOCK     :: 1
@(private="file") SESSION_SUSPEND  :: 2
@(private="file") SESSION_LOGOUT   :: 3
@(private="file") SESSION_REBOOT   :: 4
@(private="file") SESSION_POWEROFF :: 5

// Tabler codepoints (the bar's icon font).
@(private="file") ICON_LOCK    :: rune(0xEAE2)
@(private="file") ICON_MOON    :: rune(0xEAF8)
@(private="file") ICON_LOGOUT  :: rune(0xEBA8)
@(private="file") ICON_REFRESH :: rune(0xEB13)
@(private="file") ICON_POWER   :: rune(0xEB0D)

Session_Menu :: struct {
	m:          menu.Menu,
	last_press: xlib.Time, // of the latest button press (the click that opens the menu)
	locked:     bool,      // the lock state last seen
}

g_lock: bool // SIGUSR2: `milk lock` asked this instance to lock

// ---------------------------------------------------------------------------
// milk lock
// ---------------------------------------------------------------------------
cmd_lock :: proc(opts: ^Options) -> int {
	context.logger = make_logger(opts)
	if _, from_milk := os.lookup_env(lock.READY_FD_ENV, context.temp_allocator); !from_milk {
		// A running milk locks for us and keeps the lock screen running.
		pid_file := join({opts.runtime_root, PID_NAME})
		if pid, ok := running_pid(pid_file); ok && catches_signal(pid, .SIGUSR2) && posix.kill(posix.pid_t(pid), .SIGUSR2) == .OK {
			if wait_for_lock_screen(3 * time.Second) {
				fmt.println("Screen locked by milk")
				return 0
			}
			log.warn("milk did not lock the screen in time; locking here")
		}
	}
	return lock.run_locker(opts.config_path)
}

// Whether `pid` handles `sig` (an older milk would die of a signal it does
// not know, ending the session): its bit in SigCgt of /proc/<pid>/status.
catches_signal :: proc(pid: int, sig: posix.Signal) -> bool {
	data, err := os.read_entire_file(fmt.tprintf("/proc/%d/status", pid), context.temp_allocator)
	if err != nil { return false }
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if !strings.has_prefix(line, "SigCgt:") { continue }
		mask, ok := strconv.parse_u64(strings.trim_space(line[len("SigCgt:"):]), 16)
		return ok && mask & (u64(1) << (u64(sig) - 1)) != 0
	}
	return false
}

@(private="file")
wait_for_lock_screen :: proc(limit: time.Duration) -> bool {
	c, connected := tx.connect()
	if !connected { return false }
	defer tx.disconnect(c)
	start := time.tick_now()
	for time.tick_since(start) < limit {
		if lock.locker_running(c) { return true }
		time.sleep(50 * time.Millisecond)
	}
	return false
}

// ---------------------------------------------------------------------------
// In the running milk
// ---------------------------------------------------------------------------
session_start :: proc(r: ^Runner) {
	// Absolute paths: the lock screen starts from milk's working directory ("/" once daemonized).
	config_path := r.opts.config_path
	if abs, err := filepath.abs(config_path, context.temp_allocator); err == nil { config_path = abs }
	runtime_root := r.opts.runtime_root
	if abs, err := filepath.abs(runtime_root, context.temp_allocator); err == nil { runtime_root = abs }
	// The idle dimming goes through night light, which owns the gamma ramps.
	if r.night != nil {
		lock.set_dim_hook(proc(data: rawptr, factor: f64) { nightlight.set_dim((^nightlight.Night_Light)(data), factor) }, r.night)
	}
	r.idle = lock.create(r.c, r.cfg, config_path, runtime_root, r.opts.verbose)
}

session_stop :: proc(r: ^Runner) {
	menu.destroy(&r.session.m)
	lock.destroy(r.idle)
	r.idle = nil
}

// Every X event: the idle manager's (SYNC alarms, the lock selection) and the
// session menu's. True when the event is used up.
session_event :: proc(r: ^Runner, ev: ^xlib.XEvent) -> bool {
	if ev.type == .ButtonPress { r.session.last_press = ev.xbutton.time }
	if lock.handle_event(r.idle, ev) { return true }
	if !menu.handle_event(&r.session.m, ev) { return false }
	if id, ok := menu.take_result(&r.session.m); ok { session_action(r, id) }
	return true
}

// Requests made through signals and the window manager's "lock" action.
session_tick :: proc(r: ^Runner) {
	if g_lock {
		g_lock = false
		lock.lock_now(r.idle, "milk lock")
	}
	locked := lock.is_locked(r.idle)
	if locked && !r.session.locked {
		// Menus and panels hold grabs the lock screen needs, and would wait
		// open behind it.
		menu.close_all()
		if r.bar != nil { bar.close_popups(r.bar) }
		if r.notes != nil { notify.close_panel(r.notes) }
		if r.clips != nil { clip.close_panel(r.clips) }
	}
	r.session.locked = locked
	if r.notes != nil { notify.set_paused(r.notes, locked) } // no popups over the lock screen
}

// The bar's power button: the session menu next to it.
open_session_menu :: proc(r: ^Runner, anchor: tx.Rect) -> bool {
	if cmd, ok := r.cfg.bar.commands["session"]; ok && strings.trim_space(cmd) != "" { return false } // the user's own command
	lang := r.cfg.bar.language
	power := lock.can_power(r.idle)
	items := []menu.Item{
		{id = SESSION_LOCK, label = config.tr(lang, "Bloquear", "Lock"), icon = ICON_LOCK},
		{id = SESSION_SUSPEND, label = config.tr(lang, "Suspender", "Suspend"), icon = ICON_MOON, disabled = !power},
		{separator = true},
		{id = SESSION_LOGOUT, label = config.tr(lang, "Sair", "Log out"), icon = ICON_LOGOUT},
		{id = SESSION_REBOOT, label = config.tr(lang, "Reiniciar", "Restart"), icon = ICON_REFRESH, disabled = !power},
		{id = SESSION_POWEROFF, label = config.tr(lang, "Desligar", "Power off"), icon = ICON_POWER, disabled = !power},
	}
	// Right-aligned with the button, above a bottom bar or below a top one.
	mon := tx.monitor_rect(r.c, r.cfg.bar.monitor)
	x := anchor.x + anchor.w
	y := anchor.y + anchor.h + 6
	if anchor.y > mon.y + mon.h / 2 { y = anchor.y - 6 }
	return menu.open(&r.session.m, r.c, menu.style_from_config(r.cfg), items, x, y, r.session.last_press)
}

@(private="file")
session_action :: proc(r: ^Runner, id: int) {
	switch id {
	case SESSION_LOCK:     lock.lock_now(r.idle, "session menu")
	case SESSION_SUSPEND:  lock.power_action(r.idle, "Suspend")
	case SESSION_REBOOT:   lock.power_action(r.idle, "Reboot")
	case SESSION_POWEROFF: lock.power_action(r.idle, "PowerOff")
	case SESSION_LOGOUT:
		log.info("Log out from the session menu")
		g_stop = true
	}
}
