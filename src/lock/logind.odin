// systemd-logind (or elogind) on the system bus:
//   - lock before sleeping: milk holds a "sleep" delay inhibitor; on
//     PrepareForSleep(true) it starts the lock screen and lets go of the
//     inhibitor once the screen is covered (at most SLEEP_LOCK_WAIT seconds
//     later); on PrepareForSleep(false) it takes a new one;
//   - the session's Lock and Unlock signals (`loginctl lock-session`,
//     `loginctl unlock-session`) lock and unlock; SetLockedHint follows;
//   - Suspend/Reboot/PowerOff for idle.suspendAfter and the session menu.
//
// The system bus is $MILK_SYSTEM_BUS_ADDRESS when set ("none" turns the
// integration off; tests point it at a private bus with a fake logind),
// else $DBUS_SYSTEM_BUS_ADDRESS, else the standard socket. Test builds
// (lock.TEST_BUILD) never connect to the real system bus.
package lock

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import tx "../tx"

@(private) LOGIND_NAME    :: "org.freedesktop.login1"
@(private) LOGIND_PATH    :: "/org/freedesktop/login1"
@(private) LOGIND_MANAGER :: "org.freedesktop.login1.Manager"
@(private) LOGIND_SESSION :: "org.freedesktop.login1.Session"

SYSTEM_BUS_ENV :: "MILK_SYSTEM_BUS_ADDRESS"

Logind :: struct {
	bus:            Bus,
	session_path:   string, // owned; "" until logind answered
	session_serial: u32,    // the GetSession call waiting for its reply
	inhibit_serial: u32,    // the Inhibit call waiting for its reply
	inhibit_fd:     posix.FD,
}

// The system bus address, or false when the integration is off.
system_bus_address :: proc() -> (string, bool) {
	if v, found := os.lookup_env(SYSTEM_BUS_ENV, context.temp_allocator); found && v != "" {
		if v == "none" || v == "off" { return "", false }
		return v, true
	}
	when TEST_BUILD {
		return "", false // tests must never reach the real logind
	} else {
		if v, found := os.lookup_env("DBUS_SYSTEM_BUS_ADDRESS", context.temp_allocator); found && v != "" { return v, true }
		return "unix:path=/run/dbus/system_bus_socket", true
	}
}

@(private)
ld_open :: proc(m: ^Manager) {
	ld := &m.ld
	ld.bus.fd = -1
	ld.inhibit_fd = -1
	address, ok := system_bus_address()
	if !ok {
		log.info("Lock: logind integration is off (no system bus)")
		return
	}
	if !bus_open(&ld.bus, address, "system") { return }
	bus_add_match(&ld.bus, fmt.tprintf("type='signal',sender='%s',interface='%s',member='PrepareForSleep',path='%s'", LOGIND_NAME, LOGIND_MANAGER, LOGIND_PATH))
	// This process's session: $XDG_SESSION_ID, else the session of our pid.
	if id, found := os.lookup_env("XDG_SESSION_ID", context.temp_allocator); found && id != "" {
		ld.session_serial = bus_send(&ld.bus, method_call(LOGIND_NAME, LOGIND_PATH, LOGIND_MANAGER, "GetSession", id))
	} else {
		ld.session_serial = bus_send(&ld.bus, method_call(LOGIND_NAME, LOGIND_PATH, LOGIND_MANAGER, "GetSessionByPID", u32(posix.getpid())))
	}
	ld_sync_inhibitor(m)
}

@(private)
ld_close :: proc(m: ^Manager) {
	ld := &m.ld
	ld_release(m)
	bus_close(&ld.bus)
	delete(ld.session_path)
	ld.session_path = ""
}

// Hold the sleep delay inhibitor exactly while lock.onSuspend is on.
@(private)
ld_sync_inhibitor :: proc(m: ^Manager) {
	ld := &m.ld
	if ld.bus.conn == nil { return }
	if m.cfg.lock.on_suspend {
		if ld.inhibit_fd < 0 && ld.inhibit_serial == 0 && !m.sleep_wait {
			ld.inhibit_serial = bus_send(&ld.bus, method_call(LOGIND_NAME, LOGIND_PATH, LOGIND_MANAGER, "Inhibit",
			                                                  "sleep", "milk", "Lock the screen before sleeping", "delay"))
		}
	} else {
		ld_release(m)
	}
}

// Let logind go on with the suspend (closing the inhibitor's fd).
@(private)
ld_release :: proc(m: ^Manager) {
	ld := &m.ld
	if ld.inhibit_fd >= 0 {
		posix.close(ld.inhibit_fd)
		ld.inhibit_fd = -1
		log.debug("Lock: sleep inhibitor released")
	}
}

// A logind Manager method taking one boolean (Suspend, Reboot, PowerOff).
@(private)
ld_call :: proc(m: ^Manager, method: string, interactive: bool) {
	ld := &m.ld
	if ld.bus.conn == nil {
		log.warnf("Lock: cannot %s without logind", method)
		return
	}
	bus_send(&ld.bus, method_call(LOGIND_NAME, LOGIND_PATH, LOGIND_MANAGER, method, interactive))
}

@(private)
ld_set_locked_hint :: proc(m: ^Manager, locked: bool) {
	ld := &m.ld
	if ld.bus.conn == nil || ld.session_path == "" { return }
	bus_send(&ld.bus, method_call(LOGIND_NAME, ld.session_path, LOGIND_SESSION, "SetLockedHint", locked))
}

@(private)
ld_pump :: proc(m: ^Manager, read: bool) {
	ld := &m.ld
	if ld.bus.conn == nil { return }
	if read && !bus_read(&ld.bus) {
		log.warn("Lock: the system bus connection was lost; logind integration is off")
		ld_close(m)
		return
	}
	for {
		msg := bus_pop(&ld.bus)
		if msg == nil { break }
		ld_handle(m, msg)
		dbus_message_unref(msg)
	}
	if ld.bus.conn != nil && dbus_connection_has_messages_to_send(ld.bus.conn) { dbus_connection_read_write(ld.bus.conn, 0) }
}

@(private)
ld_handle :: proc(m: ^Manager, msg: ^DBusMessage) {
	ld := &m.ld
	switch msg_type(msg) {
	case DBUS_MESSAGE_TYPE_METHOD_RETURN, DBUS_MESSAGE_TYPE_ERROR:
		serial := dbus_message_get_reply_serial(msg)
		is_error := msg_type(msg) == DBUS_MESSAGE_TYPE_ERROR
		error_text := ""
		if is_error {
			args := args_of(msg)
			text, _ := arg_string(&args)
			error_text = fmt.tprintf("%s: %s", string(dbus_message_get_error_name(msg)), text)
		}
		switch {
		case serial != 0 && serial == ld.session_serial:
			ld.session_serial = 0
			if is_error {
				log.warnf("Lock: logind does not know this session (%s); `loginctl lock-session` will not lock", error_text)
				return
			}
			args := args_of(msg)
			path, ok := arg_string(&args)
			if !ok { return }
			delete(ld.session_path)
			ld.session_path = strings.clone(path)
			bus_add_match(&ld.bus, fmt.tprintf("type='signal',sender='%s',interface='%s',path='%s'", LOGIND_NAME, LOGIND_SESSION, path))
			log.debugf("Lock: logind session %s", path)
			if is_locked(m) { ld_set_locked_hint(m, true) }
		case serial != 0 && serial == ld.inhibit_serial:
			ld.inhibit_serial = 0
			if is_error {
				log.warnf("Lock: logind refused the sleep inhibitor (%s); the screen may not lock before suspending", error_text)
				return
			}
			args := args_of(msg)
			fd, ok := arg_fd(&args)
			if !ok { return }
			if !m.cfg.lock.on_suspend || m.sleep_wait {
				posix.close(posix.FD(fd))
				return
			}
			ld.inhibit_fd = posix.FD(fd)
			log.debug("Lock: holding a sleep delay inhibitor")
		case is_error:
			log.warnf("Lock: logind: %s", error_text)
		}
	case DBUS_MESSAGE_TYPE_SIGNAL:
		iface := msg_interface(msg)
		member := msg_member(msg)
		if iface == "org.freedesktop.DBus.Local" && member == "Disconnected" {
			log.warn("Lock: the system bus went away; logind integration is off")
			ld_close(m)
			return
		}
		switch {
		case iface == LOGIND_MANAGER && member == "PrepareForSleep":
			args := args_of(msg)
			start, _ := arg_int(&args)
			prepare_for_sleep(m, start != 0)
		case iface == LOGIND_SESSION && msg_path(msg) == ld.session_path && ld.session_path != "":
			switch member {
			case "Lock":
				lock_now(m, "logind Lock")
			case "Unlock":
				unlock_requested(m)
			}
		}
	}
}

@(private)
prepare_for_sleep :: proc(m: ^Manager, start: bool) {
	if start {
		log.info("Lock: the computer is going to sleep")
		if !m.cfg.lock.on_suspend {
			ld_release(m)
			return
		}
		if is_locked(m) && (m.ready || m.external) {
			ld_release(m)
			return
		}
		lock_now(m, "suspend")
		m.sleep_wait = true
		m.sleep_deadline = tx.now() + SLEEP_LOCK_WAIT
		return
	}
	log.info("Lock: the computer woke up")
	m.sleep_wait = false
	ld_release(m)
	ld_sync_inhibitor(m)
	simulate_activity(m)
}
