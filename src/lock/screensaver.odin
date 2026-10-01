// org.freedesktop.ScreenSaver on the session bus: browsers, video players
// and presentation tools call Inhibit while they play and UnInhibit (or just
// leave the bus) when they stop; the idle manager treats an active inhibitor
// as activity. Also SimulateUserActivity, GetActive (= locked),
// GetActiveTime, GetSessionIdleTime, SetActive(true) and Lock, and the
// ActiveChanged signal when the lock screen comes and goes. Served on
// /org/freedesktop/ScreenSaver and on /ScreenSaver (older Qt/KDE programs).
package lock

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import tx "../tx"

@(private) SS_NAME  :: "org.freedesktop.ScreenSaver"
@(private) SS_PATH  :: "/org/freedesktop/ScreenSaver"
@(private) SS_PATH2 :: "/ScreenSaver"
@(private) SS_IFACE :: "org.freedesktop.ScreenSaver"

@(private)
SS_INTROSPECT :: `<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.freedesktop.ScreenSaver">
    <method name="Inhibit">
      <arg direction="in" name="application_name" type="s"/>
      <arg direction="in" name="reason_for_inhibit" type="s"/>
      <arg direction="out" name="cookie" type="u"/>
    </method>
    <method name="UnInhibit"><arg direction="in" name="cookie" type="u"/></method>
    <method name="SimulateUserActivity"/>
    <method name="Lock"/>
    <method name="GetActive"><arg direction="out" type="b"/></method>
    <method name="SetActive"><arg direction="in" name="e" type="b"/><arg direction="out" type="b"/></method>
    <method name="GetActiveTime"><arg direction="out" name="seconds" type="u"/></method>
    <method name="GetSessionIdleTime"><arg direction="out" name="seconds" type="u"/></method>
    <signal name="ActiveChanged"><arg type="b"/></signal>
  </interface>
  <interface name="org.freedesktop.DBus.Introspectable">
    <method name="Introspect"><arg direction="out" name="xml_data" type="s"/></method>
  </interface>
  <interface name="org.freedesktop.DBus.Peer">
    <method name="Ping"/>
  </interface>
</node>
`

Inhibitor :: struct {
	cookie: u32,
	owner:  string, // the caller's unique bus name (owned)
	app:    string, // owned
	reason: string, // owned
}

Screensaver :: struct {
	bus:         Bus,
	serving:     bool,
	inhibitors:  [dynamic]Inhibitor,
	next_cookie: u32,
}

@(private)
ss_open :: proc(m: ^Manager) {
	ss := &m.ss
	ss.bus.fd = -1
	ss.next_cookie = 1
	address := os.get_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator)
	if address == "" {
		log.info("Lock: no session bus; org.freedesktop.ScreenSaver is not offered")
		return
	}
	if !bus_open(&ss.bus, address, "session") { return }
	bus_add_match(&ss.bus, "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'")
	bus_add_match(&ss.bus, "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameAcquired'")
	bus_add_match(&ss.bus, "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameLost'")
	err: DBusError
	dbus_error_init(&err)
	defer dbus_error_free(&err)
	reply := dbus_bus_request_name(ss.bus.conn, SS_NAME, DBUS_NAME_FLAG_ALLOW_REPLACEMENT | DBUS_NAME_FLAG_REPLACE_EXISTING, &err)
	switch {
	case bool(dbus_error_is_set(&err)):
		log.warnf("Lock: cannot request %s: %s", SS_NAME, err.message)
	case reply == DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER || reply == DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER:
		ss.serving = true
		log.infof("Lock: serving %s on the session bus", SS_NAME)
	case:
		log.infof("Lock: %s belongs to another program; milk waits in the bus queue", SS_NAME)
	}
}

@(private)
ss_close :: proc(m: ^Manager) {
	ss := &m.ss
	for &i in ss.inhibitors { ss_free_inhibitor(&i) }
	delete(ss.inhibitors)
	ss.inhibitors = nil
	bus_close(&ss.bus)
}

@(private)
ss_free_inhibitor :: proc(i: ^Inhibitor) {
	delete(i.owner)
	delete(i.app)
	delete(i.reason)
}

@(private)
ss_pump :: proc(m: ^Manager, read: bool) {
	ss := &m.ss
	if ss.bus.conn == nil { return }
	if read && !bus_read(&ss.bus) {
		log.warn("Lock: the session bus connection was lost; org.freedesktop.ScreenSaver is gone")
		had := len(ss.inhibitors) > 0
		ss_close(m)
		ss.bus.fd = -1
		if had { simulate_activity(m) }
		return
	}
	for {
		msg := bus_pop(&ss.bus)
		if msg == nil { break }
		ss_handle(m, msg)
		dbus_message_unref(msg)
	}
	if ss.bus.conn != nil && dbus_connection_has_messages_to_send(ss.bus.conn) { dbus_connection_read_write(ss.bus.conn, 0) }
}

@(private)
ss_handle :: proc(m: ^Manager, msg: ^DBusMessage) {
	ss := &m.ss
	b := &ss.bus
	iface := msg_interface(msg)
	member := msg_member(msg)
	switch msg_type(msg) {
	case DBUS_MESSAGE_TYPE_SIGNAL:
		if iface != "org.freedesktop.DBus" { return }
		args := args_of(msg)
		name, _ := arg_string(&args)
		switch member {
		case "NameAcquired":
			if name == SS_NAME && !ss.serving {
				ss.serving = true
				log.infof("Lock: serving %s on the session bus", SS_NAME)
			}
		case "NameLost":
			if name == SS_NAME && ss.serving {
				ss.serving = false
				log.infof("Lock: another program took %s", SS_NAME)
			}
		case "NameOwnerChanged":
			arg_string(&args) // old owner
			new_owner, _ := arg_string(&args)
			if new_owner != "" || !strings.has_prefix(name, ":") { return }
			// A client left the bus: its inhibitors go with it.
			removed := false
			for i := len(ss.inhibitors) - 1; i >= 0; i -= 1 {
				if ss.inhibitors[i].owner != name { continue }
				log.infof("Lock: %s left; its idle inhibitor %d is released", ss.inhibitors[i].app, ss.inhibitors[i].cookie)
				ss_free_inhibitor(&ss.inhibitors[i])
				ordered_remove(&ss.inhibitors, i)
				removed = true
			}
			if removed && len(ss.inhibitors) == 0 { simulate_activity(m) }
		}
		return
	case DBUS_MESSAGE_TYPE_METHOD_CALL:
	case:
		return
	}

	path := msg_path(msg)
	if iface == "org.freedesktop.DBus.Introspectable" || (iface == "" && member == "Introspect") {
		xml := SS_INTROSPECT
		switch path {
		case "/":                  xml = `<node><node name="org"/><node name="ScreenSaver"/></node>`
		case "/org":               xml = `<node><node name="freedesktop"/></node>`
		case "/org/freedesktop":   xml = `<node><node name="ScreenSaver"/></node>`
		}
		reply_values(b, msg, xml)
		return
	}
	if iface == "org.freedesktop.DBus.Peer" {
		if member == "Ping" { reply_values(b, msg) } else { reply_error(b, msg, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method") }
		return
	}
	if (iface != SS_IFACE && iface != "") || (path != SS_PATH && path != SS_PATH2) {
		reply_error(b, msg, "org.freedesktop.DBus.Error.UnknownMethod", fmt.tprintf("Unknown method %s.%s on %s", iface, member, path))
		return
	}
	now := tx.now()
	switch member {
	case "Inhibit":
		args := args_of(msg)
		app, ok1 := arg_string(&args)
		reason, ok2 := arg_string(&args)
		if !ok1 || !ok2 {
			reply_error(b, msg, "org.freedesktop.DBus.Error.InvalidArgs", "Inhibit expects (ss)")
			return
		}
		cookie := ss.next_cookie
		ss.next_cookie += 1
		if ss.next_cookie == 0 { ss.next_cookie = 1 }
		append(&ss.inhibitors, Inhibitor{cookie = cookie, owner = strings.clone(msg_sender(msg)),
		                                 app = strings.clone(app), reason = strings.clone(reason)})
		log.infof("Lock: %s holds idle off (%s), cookie %d", app != "" ? app : msg_sender(msg), reason, cookie)
		reply_values(b, msg, cookie)
	case "UnInhibit":
		args := args_of(msg)
		cookie, ok := arg_int(&args)
		if !ok {
			reply_error(b, msg, "org.freedesktop.DBus.Error.InvalidArgs", "UnInhibit expects (u)")
			return
		}
		found := false
		for i := 0; i < len(ss.inhibitors); i += 1 {
			if ss.inhibitors[i].cookie != u32(cookie) { continue }
			log.infof("Lock: %s released its idle inhibitor %d", ss.inhibitors[i].app, cookie)
			ss_free_inhibitor(&ss.inhibitors[i])
			ordered_remove(&ss.inhibitors, i)
			found = true
			break
		}
		reply_values(b, msg)
		if found && len(ss.inhibitors) == 0 { simulate_activity(m) }
	case "SimulateUserActivity":
		simulate_activity(m)
		reply_values(b, msg)
	case "Lock":
		lock_now(m, "ScreenSaver.Lock")
		reply_values(b, msg)
	case "GetActive":
		reply_values(b, msg, is_locked(m))
	case "SetActive":
		args := args_of(msg)
		on, _ := arg_int(&args)
		if on != 0 { lock_now(m, "ScreenSaver.SetActive") }
		reply_values(b, msg, on != 0)
	case "GetActiveTime":
		secs: u32 = 0
		if is_locked(m) { secs = u32(max(now - m.locked_at, 0)) }
		reply_values(b, msg, secs)
	case "GetSessionIdleTime":
		idle, _ := idle_seconds(m, now)
		reply_values(b, msg, u32(idle))
	case:
		reply_error(b, msg, "org.freedesktop.DBus.Error.UnknownMethod", fmt.tprintf("Unknown method %s", member))
	}
}

// ActiveChanged(locked) on the bus.
@(private)
ss_active_changed :: proc(m: ^Manager, active: bool) {
	ss := &m.ss
	if ss.bus.conn == nil || !ss.serving { return }
	sig := dbus_message_new_signal(SS_PATH, SS_IFACE, "ActiveChanged")
	if sig == nil { return }
	it: DBusMessageIter
	dbus_message_iter_init_append(sig, &it)
	append_any(&it, active)
	bus_send(&ss.bus, sig)
}
