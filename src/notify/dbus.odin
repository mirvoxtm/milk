// The org.freedesktop.Notifications server (Desktop Notifications spec 1.2)
// on the session bus, through a minimal libdbus-1 binding.
//
// The connection is private (dbus_connection_open_private on
// $DBUS_SESSION_BUS_ADDRESS) and never dispatched by libdbus itself: the milk
// poll loop watches its unix fd, `bus_pump` reads what is available without
// blocking (dbus_connection_read_write with a zero timeout) and pops the
// queued messages one by one.
package notify

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

foreign import libdbus "system:dbus-1"

DBusConnection :: struct {}
DBusMessage :: struct {}

// dbus-errors.h: two strings, a word of bit fields, a pointer.
DBusError :: struct {
	name:     cstring,
	message:  cstring,
	dummy:    u32,
	padding1: rawptr,
}

// dbus-message.h: 72 bytes of private fields on 64-bit; reserve more.
DBusMessageIter :: struct {
	_: [16]rawptr,
}

@(private) DBUS_TYPE_INVALID    :: i32(0)
@(private) DBUS_TYPE_BYTE       :: i32('y')
@(private) DBUS_TYPE_BOOLEAN    :: i32('b')
@(private) DBUS_TYPE_INT16      :: i32('n')
@(private) DBUS_TYPE_UINT16     :: i32('q')
@(private) DBUS_TYPE_INT32      :: i32('i')
@(private) DBUS_TYPE_UINT32     :: i32('u')
@(private) DBUS_TYPE_INT64      :: i32('x')
@(private) DBUS_TYPE_UINT64     :: i32('t')
@(private) DBUS_TYPE_STRING     :: i32('s')
@(private) DBUS_TYPE_ARRAY      :: i32('a')
@(private) DBUS_TYPE_VARIANT    :: i32('v')
@(private) DBUS_TYPE_STRUCT     :: i32('r')
@(private) DBUS_TYPE_DICT_ENTRY :: i32('e')

@(private) DBUS_MESSAGE_TYPE_METHOD_CALL :: i32(1)
@(private) DBUS_MESSAGE_TYPE_SIGNAL      :: i32(4)

@(private) DBUS_NAME_FLAG_ALLOW_REPLACEMENT      :: u32(0x1)
@(private) DBUS_NAME_FLAG_REPLACE_EXISTING       :: u32(0x2)
@(private) DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER :: i32(1)
@(private) DBUS_REQUEST_NAME_REPLY_IN_QUEUE      :: i32(2)
@(private) DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER :: i32(4)

@(default_calling_convention="c")
foreign libdbus {
	dbus_error_init                        :: proc(err: ^DBusError) ---
	dbus_error_free                        :: proc(err: ^DBusError) ---
	dbus_error_is_set                      :: proc(err: ^DBusError) -> b32 ---
	dbus_connection_open_private           :: proc(address: cstring, err: ^DBusError) -> ^DBusConnection ---
	dbus_bus_register                      :: proc(conn: ^DBusConnection, err: ^DBusError) -> b32 ---
	dbus_bus_request_name                  :: proc(conn: ^DBusConnection, name: cstring, flags: u32, err: ^DBusError) -> i32 ---
	dbus_connection_set_exit_on_disconnect :: proc(conn: ^DBusConnection, exit_on_disconnect: b32) ---
	dbus_connection_get_unix_fd            :: proc(conn: ^DBusConnection, fd: ^i32) -> b32 ---
	dbus_connection_read_write             :: proc(conn: ^DBusConnection, timeout_ms: i32) -> b32 ---
	dbus_connection_pop_message            :: proc(conn: ^DBusConnection) -> ^DBusMessage ---
	dbus_connection_send                   :: proc(conn: ^DBusConnection, msg: ^DBusMessage, serial: ^u32) -> b32 ---
	dbus_connection_flush                  :: proc(conn: ^DBusConnection) ---
	dbus_connection_close                  :: proc(conn: ^DBusConnection) ---
	dbus_connection_unref                  :: proc(conn: ^DBusConnection) ---
	dbus_connection_get_is_connected       :: proc(conn: ^DBusConnection) -> b32 ---
	dbus_connection_has_messages_to_send   :: proc(conn: ^DBusConnection) -> b32 ---
	dbus_connection_get_dispatch_status    :: proc(conn: ^DBusConnection) -> i32 --- // 0 = data remains
	dbus_connection_send_with_reply_and_block :: proc(conn: ^DBusConnection, msg: ^DBusMessage, timeout_ms: i32, err: ^DBusError) -> ^DBusMessage ---
	dbus_bus_add_match                     :: proc(conn: ^DBusConnection, rule: cstring, err: ^DBusError) ---
	dbus_bus_get_unique_name               :: proc(conn: ^DBusConnection) -> cstring ---
	dbus_message_new_method_call           :: proc(dest, path, iface, method: cstring) -> ^DBusMessage ---
	dbus_message_get_sender                :: proc(msg: ^DBusMessage) -> cstring ---
	dbus_message_get_type                  :: proc(msg: ^DBusMessage) -> i32 ---
	dbus_message_get_interface             :: proc(msg: ^DBusMessage) -> cstring ---
	dbus_message_get_member                :: proc(msg: ^DBusMessage) -> cstring ---
	dbus_message_get_path                  :: proc(msg: ^DBusMessage) -> cstring ---
	dbus_message_get_no_reply              :: proc(msg: ^DBusMessage) -> b32 ---
	dbus_message_new_method_return         :: proc(call: ^DBusMessage) -> ^DBusMessage ---
	dbus_message_new_error                 :: proc(call: ^DBusMessage, name: cstring, text: cstring) -> ^DBusMessage ---
	dbus_message_new_signal                :: proc(path: cstring, iface: cstring, name: cstring) -> ^DBusMessage ---
	dbus_message_unref                     :: proc(msg: ^DBusMessage) ---
	dbus_message_iter_init                 :: proc(msg: ^DBusMessage, iter: ^DBusMessageIter) -> b32 ---
	dbus_message_iter_init_append          :: proc(msg: ^DBusMessage, iter: ^DBusMessageIter) ---
	dbus_message_iter_get_arg_type         :: proc(iter: ^DBusMessageIter) -> i32 ---
	dbus_message_iter_get_element_type     :: proc(iter: ^DBusMessageIter) -> i32 ---
	dbus_message_iter_next                 :: proc(iter: ^DBusMessageIter) -> b32 ---
	dbus_message_iter_recurse              :: proc(iter: ^DBusMessageIter, sub: ^DBusMessageIter) ---
	dbus_message_iter_get_basic            :: proc(iter: ^DBusMessageIter, value: rawptr) ---
	dbus_message_iter_get_fixed_array      :: proc(iter: ^DBusMessageIter, value: rawptr, n_elements: ^i32) ---
	dbus_message_iter_append_basic         :: proc(iter: ^DBusMessageIter, type: i32, value: rawptr) -> b32 ---
	dbus_message_iter_open_container       :: proc(iter: ^DBusMessageIter, type: i32, signature: cstring, sub: ^DBusMessageIter) -> b32 ---
	dbus_message_iter_close_container      :: proc(iter: ^DBusMessageIter, sub: ^DBusMessageIter) -> b32 ---
}

@(private) BUS_NAME  :: "org.freedesktop.Notifications"
@(private) BUS_PATH  :: "/org/freedesktop/Notifications"
@(private) BUS_IFACE :: "org.freedesktop.Notifications"

SERVER_NAME    :: "milk"
SERVER_VENDOR  :: "Temenos"
SERVER_VERSION :: "0.1.0"
SPEC_VERSION   :: "1.2"

Close_Reason :: enum u32 {
	Expired   = 1,
	Dismissed = 2,
	Closed    = 3, // CloseNotification
	Undefined = 4,
}

@(private)
INTROSPECT_XML :: `<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.freedesktop.Notifications">
    <method name="GetCapabilities"><arg direction="out" name="capabilities" type="as"/></method>
    <method name="Notify">
      <arg direction="in" name="app_name" type="s"/>
      <arg direction="in" name="replaces_id" type="u"/>
      <arg direction="in" name="app_icon" type="s"/>
      <arg direction="in" name="summary" type="s"/>
      <arg direction="in" name="body" type="s"/>
      <arg direction="in" name="actions" type="as"/>
      <arg direction="in" name="hints" type="a{sv}"/>
      <arg direction="in" name="expire_timeout" type="i"/>
      <arg direction="out" name="id" type="u"/>
    </method>
    <method name="CloseNotification"><arg direction="in" name="id" type="u"/></method>
    <method name="GetServerInformation">
      <arg direction="out" name="name" type="s"/>
      <arg direction="out" name="vendor" type="s"/>
      <arg direction="out" name="version" type="s"/>
      <arg direction="out" name="spec_version" type="s"/>
    </method>
    <signal name="NotificationClosed"><arg name="id" type="u"/><arg name="reason" type="u"/></signal>
    <signal name="ActionInvoked"><arg name="id" type="u"/><arg name="action_key" type="s"/></signal>
  </interface>
  <interface name="org.freedesktop.DBus.Introspectable">
    <method name="Introspect"><arg direction="out" name="xml_data" type="s"/></method>
  </interface>
  <interface name="org.freedesktop.DBus.Peer">
    <method name="Ping"/>
    <method name="GetMachineId"><arg direction="out" name="machine_uuid" type="s"/></method>
  </interface>
</node>
`

// A parsed Notify call (strings live in the temp allocator).
@(private)
Notify_Request :: struct {
	app_name:      string,
	replaces_id:   u32,
	app_icon:      string,
	summary:       string,
	body:          string,
	actions:       [dynamic]Action,
	urgency:       u8,
	expire_ms:     i32,
	image_path:    string,
	desktop_entry: string,
	transient:     bool,
	resident:      bool,
	image:         Raw_Image,
}

// image-data hint: (iiibiiay).
@(private)
Raw_Image :: struct {
	width, height, rowstride: i32,
	has_alpha:                bool,
	bits, channels:           i32,
	data:                     []u8, // points into the message; copy before it is freed
}

// Where milk stands on the bus.
Bus_State :: enum {
	Unavailable, // no session bus: the panel still works (history of nothing)
	Waiting,     // another daemon owns org.freedesktop.Notifications; milk is queued
	Serving,     // milk owns the name
}

// Connect to the session bus and ask for org.freedesktop.Notifications.
// milk takes the name over when the current owner allows replacement, and
// otherwise waits in the bus queue (NameAcquired arrives when the owner
// leaves). The name also allows replacement, so another daemon started
// later can take it; milk then goes back to waiting and keeps its history.
@(private)
bus_open :: proc(n: ^Notifier) -> bool {
	n.bus_state = .Unavailable
	address := os.get_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator)
	if address == "" {
		log.warn("Notifications: DBUS_SESSION_BUS_ADDRESS is not set; only the panel works")
		return false
	}
	err: DBusError
	dbus_error_init(&err)
	defer dbus_error_free(&err)
	conn := dbus_connection_open_private(strings.clone_to_cstring(address, context.temp_allocator), &err)
	if conn == nil {
		log.warnf("Notifications: cannot connect to the session bus (%s); only the panel works", err.message)
		return false
	}
	// libdbus would otherwise call exit() when the bus goes away.
	dbus_connection_set_exit_on_disconnect(conn, false)
	if !dbus_bus_register(conn, &err) {
		log.warnf("Notifications: cannot register on the session bus (%s); only the panel works", err.message)
		dbus_connection_close(conn)
		dbus_connection_unref(conn)
		return false
	}
	fd: i32 = -1
	if !dbus_connection_get_unix_fd(conn, &fd) || fd < 0 {
		log.warn("Notifications: the bus connection has no file descriptor; only the panel works")
		dbus_connection_close(conn)
		dbus_connection_unref(conn)
		return false
	}
	n.bus = conn
	n.bus_fd = fd
	// Ownership changes of the name (NameAcquired/NameLost are always sent
	// to the connection concerned; the rules make that explicit).
	for rule in ([]cstring{
		"type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameAcquired',arg0='org.freedesktop.Notifications'",
		"type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameLost',arg0='org.freedesktop.Notifications'",
		"type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.freedesktop.Notifications'",
	}) {
		dbus_bus_add_match(conn, rule, nil) // no reply awaited
	}
	reply := dbus_bus_request_name(conn, BUS_NAME, DBUS_NAME_FLAG_ALLOW_REPLACEMENT | DBUS_NAME_FLAG_REPLACE_EXISTING, &err)
	switch {
	case bool(dbus_error_is_set(&err)):
		log.warnf("Notifications: cannot request %s: %s", BUS_NAME, err.message)
		bus_set_state(n, .Waiting)
	case reply == DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER || reply == DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER:
		bus_set_state(n, .Serving)
	case:
		bus_set_state(n, .Waiting)
	}
	return true
}

// Switch between serving and waiting (logged once per change).
@(private)
bus_set_state :: proc(n: ^Notifier, state: Bus_State) {
	if n.bus_state == state && state != .Waiting { return }
	previous := n.bus_state
	n.bus_state = state
	switch state {
	case .Serving:
		log.infof("Notifications: serving %s on the session bus", BUS_NAME)
	case .Waiting:
		bus_update_owner(n, "")
		if previous != .Waiting {
			log.infof("Notifications: %s is owned by another notification service (%s); milk waits in the bus queue, the panel still works",
			          BUS_NAME, n.owner_label != "" ? n.owner_label : "unknown")
		}
	case .Unavailable:
	}
	if n.panel.open { panel_render(n) }
}

// Remember which program owns the name (`unique` = its bus name, or "" to ask the bus).
@(private)
bus_update_owner :: proc(n: ^Notifier, unique: string) {
	label := bus_owner_label(n, unique)
	delete(n.owner_label, n.allocator)
	n.owner_label = strings.clone(label, n.allocator)
}

// "noctalia": /proc/<pid>/comm of the name's owner ("" when unknown).
@(private)
bus_owner_label :: proc(n: ^Notifier, unique: string) -> string {
	if n.bus == nil { return "" }
	owner := unique
	if owner == "" {
		s, ok := bus_call_string(n, "GetNameOwner", BUS_NAME)
		if !ok { return "" }
		owner = s
	}
	msg := dbus_message_new_method_call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID")
	if msg == nil { return "" }
	defer dbus_message_unref(msg)
	it: DBusMessageIter
	dbus_message_iter_init_append(msg, &it)
	arg := strings.clone_to_cstring(owner, context.temp_allocator)
	dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &arg)
	err: DBusError
	dbus_error_init(&err)
	defer dbus_error_free(&err)
	reply := dbus_connection_send_with_reply_and_block(n.bus, msg, 300, &err)
	if reply == nil { return "" }
	defer dbus_message_unref(reply)
	rit: DBusMessageIter
	if !dbus_message_iter_init(reply, &rit) { return "" }
	pid, ok := iter_int(&rit)
	if !ok || pid <= 0 { return "" }
	data, rerr := os.read_entire_file(fmt.tprintf("/proc/%d/comm", pid), context.temp_allocator)
	if rerr != nil { return fmt.tprintf("pid %d", pid) }
	return strings.trim_space(string(data))
}

// A org.freedesktop.DBus method taking and returning one string (blocking, 300 ms at most).
@(private)
bus_call_string :: proc(n: ^Notifier, method: cstring, arg: string) -> (string, bool) {
	msg := dbus_message_new_method_call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", method)
	if msg == nil { return "", false }
	defer dbus_message_unref(msg)
	it: DBusMessageIter
	dbus_message_iter_init_append(msg, &it)
	carg := strings.clone_to_cstring(arg, context.temp_allocator)
	dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &carg)
	err: DBusError
	dbus_error_init(&err)
	defer dbus_error_free(&err)
	reply := dbus_connection_send_with_reply_and_block(n.bus, msg, 300, &err)
	if reply == nil { return "", false }
	defer dbus_message_unref(reply)
	rit: DBusMessageIter
	if !dbus_message_iter_init(reply, &rit) { return "", false }
	return iter_string(&rit)
}

@(private)
bus_close :: proc(n: ^Notifier) {
	if n.bus == nil { return }
	// Deliver pending signals, but never hang on a stuck bus.
	for i := 0; i < 10 && dbus_connection_has_messages_to_send(n.bus); i += 1 {
		if !dbus_connection_read_write(n.bus, 20) { break }
	}
	dbus_connection_close(n.bus)
	dbus_connection_unref(n.bus)
	n.bus = nil
	n.bus_fd = -1
	n.bus_state = .Unavailable
}

// Read what the socket has (never blocks) and handle every queued message.
@(private)
bus_pump :: proc(n: ^Notifier, read: bool) {
	if n.bus == nil { return }
	if read && !dbus_connection_read_write(n.bus, 0) {
		bus_lost(n)
		return
	}
	for n.bus != nil {
		msg := dbus_connection_pop_message(n.bus)
		if msg == nil { break }
		bus_handle(n, msg)
		dbus_message_unref(msg)
	}
	bus_write(n)
	if n.bus != nil && !dbus_connection_get_is_connected(n.bus) { bus_lost(n) }
}

// Write what the socket accepts now; the rest goes out on a later tick
// (next_timeout stays short while output is pending). Never blocks: a
// blocking flush could freeze the whole milk loop behind a busy bus.
@(private)
bus_write :: proc(n: ^Notifier) {
	if n.bus == nil || !dbus_connection_has_messages_to_send(n.bus) { return }
	if !dbus_connection_read_write(n.bus, 0) { bus_lost(n) }
}

// Messages already read from the socket but not handled yet (poll() would
// not report them).
@(private)
bus_has_input :: proc(n: ^Notifier) -> bool {
	return n.bus != nil && dbus_connection_get_dispatch_status(n.bus) == 0
}

@(private)
bus_has_output :: proc(n: ^Notifier) -> bool {
	return n.bus != nil && bool(dbus_connection_has_messages_to_send(n.bus))
}

@(private)
bus_lost :: proc(n: ^Notifier) {
	log.warn("Notifications: the session bus connection was lost; only the panel works now")
	bus_close(n)
	if n.panel.open { panel_render(n) }
}

@(private)
bus_handle :: proc(n: ^Notifier, msg: ^DBusMessage) {
	kind := dbus_message_get_type(msg)
	iface := string(dbus_message_get_interface(msg))
	member := string(dbus_message_get_member(msg))
	if kind == DBUS_MESSAGE_TYPE_SIGNAL {
		if iface == "org.freedesktop.DBus.Local" && member == "Disconnected" {
			bus_lost(n)
			return
		}
		if iface != "org.freedesktop.DBus" || string(dbus_message_get_sender(msg)) != "org.freedesktop.DBus" { return }
		it: DBusMessageIter
		if !dbus_message_iter_init(msg, &it) { return }
		name, ok := iter_string(&it)
		if !ok || name != BUS_NAME { return }
		switch member {
		case "NameAcquired":
			bus_set_state(n, .Serving)
		case "NameLost":
			log.info("Notifications: another notification service took over; milk keeps its history and waits")
			bus_set_state(n, .Waiting)
		case "NameOwnerChanged":
			// (name, old owner, new owner): follow who serves while milk waits.
			dbus_message_iter_next(&it)
			dbus_message_iter_next(&it)
			new_owner, _ := iter_string(&it)
			self := string(dbus_bus_get_unique_name(n.bus))
			if n.bus_state == .Waiting && new_owner != "" && new_owner != self {
				before := strings.clone(n.owner_label, context.temp_allocator)
				bus_update_owner(n, new_owner)
				if n.owner_label != before {
					log.infof("Notifications: %s is now owned by %s", BUS_NAME, n.owner_label != "" ? n.owner_label : new_owner)
					if n.panel.open { panel_render(n) }
				}
			}
		}
		return
	}
	if kind != DBUS_MESSAGE_TYPE_METHOD_CALL { return }

	switch {
	case (iface == BUS_IFACE || iface == "") && member == "GetCapabilities":
		reply := dbus_message_new_method_return(msg)
		it, arr: DBusMessageIter
		dbus_message_iter_init_append(reply, &it)
		dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "s", &arr)
		for cap in ([]cstring{"body", "body-markup", "actions", "icon-static", "persistence"}) {
			v := cap
			dbus_message_iter_append_basic(&arr, DBUS_TYPE_STRING, &v)
		}
		dbus_message_iter_close_container(&it, &arr)
		bus_send(n, reply)
	case (iface == BUS_IFACE || iface == "") && member == "GetServerInformation":
		reply := dbus_message_new_method_return(msg)
		it: DBusMessageIter
		dbus_message_iter_init_append(reply, &it)
		for s in ([]cstring{SERVER_NAME, SERVER_VENDOR, SERVER_VERSION, SPEC_VERSION}) {
			v := s
			dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &v)
		}
		bus_send(n, reply)
	case (iface == BUS_IFACE || iface == "") && member == "Notify":
		req, ok := parse_notify(msg)
		if !ok {
			bus_error(n, msg, "org.freedesktop.DBus.Error.InvalidArgs", "Notify expects (susssasa{sv}i)")
			return
		}
		id := notification_post(n, &req)
		reply := dbus_message_new_method_return(msg)
		it: DBusMessageIter
		dbus_message_iter_init_append(reply, &it)
		v := id
		dbus_message_iter_append_basic(&it, DBUS_TYPE_UINT32, &v)
		bus_send(n, reply)
	case (iface == BUS_IFACE || iface == "") && member == "CloseNotification":
		it: DBusMessageIter
		id: u32
		if !dbus_message_iter_init(msg, &it) || dbus_message_iter_get_arg_type(&it) != DBUS_TYPE_UINT32 {
			bus_error(n, msg, "org.freedesktop.DBus.Error.InvalidArgs", "CloseNotification expects (u)")
			return
		}
		dbus_message_iter_get_basic(&it, &id)
		// Reply first: the signal must not overtake the method return.
		bus_send(n, dbus_message_new_method_return(msg))
		notification_remove(n, id, .Closed)
	case iface == "org.freedesktop.DBus.Introspectable" || (iface == "" && member == "Introspect"):
		if member != "Introspect" {
			bus_error(n, msg, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method")
			return
		}
		reply := dbus_message_new_method_return(msg)
		it: DBusMessageIter
		dbus_message_iter_init_append(reply, &it)
		xml: cstring = INTROSPECT_XML
		if string(dbus_message_get_path(msg)) != BUS_PATH {
			xml = "<node><node name=\"org\"/></node>"
			if string(dbus_message_get_path(msg)) == "/org" { xml = "<node><node name=\"freedesktop\"/></node>" }
			if string(dbus_message_get_path(msg)) == "/org/freedesktop" { xml = "<node><node name=\"Notifications\"/></node>" }
		}
		dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &xml)
		bus_send(n, reply)
	case iface == "org.freedesktop.DBus.Peer":
		switch member {
		case "Ping":
			bus_send(n, dbus_message_new_method_return(msg))
		case "GetMachineId":
			data, err := os.read_entire_file("/etc/machine-id", context.temp_allocator)
			if err != nil {
				bus_error(n, msg, "org.freedesktop.DBus.Error.Failed", "No machine id")
				return
			}
			reply := dbus_message_new_method_return(msg)
			it: DBusMessageIter
			dbus_message_iter_init_append(reply, &it)
			id := strings.clone_to_cstring(strings.trim_space(string(data)), context.temp_allocator)
			dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &id)
			bus_send(n, reply)
		case:
			bus_error(n, msg, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method")
		}
	case:
		text := strings.clone_to_cstring(strings.concatenate({"Unknown method ", iface, ".", member}, context.temp_allocator), context.temp_allocator)
		bus_error(n, msg, "org.freedesktop.DBus.Error.UnknownMethod", text)
	}
}

@(private)
bus_send :: proc(n: ^Notifier, msg: ^DBusMessage) {
	if msg == nil { return }
	if n.bus != nil { dbus_connection_send(n.bus, msg, nil) }
	dbus_message_unref(msg)
}

@(private)
bus_error :: proc(n: ^Notifier, call: ^DBusMessage, name: cstring, text: cstring) {
	bus_send(n, dbus_message_new_error(call, name, text))
}

@(private)
emit_closed :: proc(n: ^Notifier, id: u32, reason: Close_Reason) {
	if n.bus == nil { return }
	sig := dbus_message_new_signal(BUS_PATH, BUS_IFACE, "NotificationClosed")
	if sig == nil { return }
	it: DBusMessageIter
	dbus_message_iter_init_append(sig, &it)
	v_id := id
	v_reason := u32(reason)
	dbus_message_iter_append_basic(&it, DBUS_TYPE_UINT32, &v_id)
	dbus_message_iter_append_basic(&it, DBUS_TYPE_UINT32, &v_reason)
	bus_send(n, sig)
	bus_write(n)
}

@(private)
emit_action :: proc(n: ^Notifier, id: u32, key: string) {
	if n.bus == nil { return }
	sig := dbus_message_new_signal(BUS_PATH, BUS_IFACE, "ActionInvoked")
	if sig == nil { return }
	it: DBusMessageIter
	dbus_message_iter_init_append(sig, &it)
	v_id := id
	v_key := strings.clone_to_cstring(key, context.temp_allocator)
	dbus_message_iter_append_basic(&it, DBUS_TYPE_UINT32, &v_id)
	dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &v_key)
	bus_send(n, sig)
	bus_write(n)
}

// ---------------------------------------------------------------------------
// Reading Notify arguments
// ---------------------------------------------------------------------------
@(private)
iter_string :: proc(it: ^DBusMessageIter) -> (string, bool) {
	t := dbus_message_iter_get_arg_type(it)
	if t != DBUS_TYPE_STRING && t != i32('o') && t != i32('g') { return "", false }
	s: cstring
	dbus_message_iter_get_basic(it, &s)
	return strings.clone(string(s), context.temp_allocator), true
}

// Any integer (or boolean) type as i64.
@(private)
iter_int :: proc(it: ^DBusMessageIter) -> (i64, bool) {
	switch dbus_message_iter_get_arg_type(it) {
	case DBUS_TYPE_BYTE:
		v: u8
		dbus_message_iter_get_basic(it, &v)
		return i64(v), true
	case DBUS_TYPE_BOOLEAN, DBUS_TYPE_UINT32:
		v: u32
		dbus_message_iter_get_basic(it, &v)
		return i64(v), true
	case DBUS_TYPE_INT32:
		v: i32
		dbus_message_iter_get_basic(it, &v)
		return i64(v), true
	case DBUS_TYPE_INT16:
		v: i16
		dbus_message_iter_get_basic(it, &v)
		return i64(v), true
	case DBUS_TYPE_UINT16:
		v: u16
		dbus_message_iter_get_basic(it, &v)
		return i64(v), true
	case DBUS_TYPE_INT64, DBUS_TYPE_UINT64:
		v: i64
		dbus_message_iter_get_basic(it, &v)
		return v, true
	}
	return 0, false
}

@(private)
parse_notify :: proc(msg: ^DBusMessage) -> (req: Notify_Request, ok: bool) {
	req.actions = make([dynamic]Action, context.temp_allocator)
	req.urgency = 1
	it: DBusMessageIter
	if !dbus_message_iter_init(msg, &it) { return }
	req.app_name = iter_string(&it) or_return
	dbus_message_iter_next(&it)
	id := iter_int(&it) or_return
	req.replaces_id = u32(id)
	dbus_message_iter_next(&it)
	req.app_icon = iter_string(&it) or_return
	dbus_message_iter_next(&it)
	req.summary = iter_string(&it) or_return
	dbus_message_iter_next(&it)
	req.body = iter_string(&it) or_return
	dbus_message_iter_next(&it)

	// actions: as, pairs of (key, label)
	if dbus_message_iter_get_arg_type(&it) != DBUS_TYPE_ARRAY { return }
	{
		arr: DBusMessageIter
		dbus_message_iter_recurse(&it, &arr)
		strs := make([dynamic]string, context.temp_allocator)
		for dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_STRING {
			s, _ := iter_string(&arr)
			append(&strs, s)
			dbus_message_iter_next(&arr)
		}
		for i := 0; i + 1 < len(strs); i += 2 {
			append(&req.actions, Action{key = strs[i], label = strs[i + 1]})
		}
	}
	dbus_message_iter_next(&it)

	// hints: a{sv}
	if dbus_message_iter_get_arg_type(&it) != DBUS_TYPE_ARRAY { return }
	{
		arr: DBusMessageIter
		dbus_message_iter_recurse(&it, &arr)
		for dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_DICT_ENTRY {
			entry, value: DBusMessageIter
			dbus_message_iter_recurse(&arr, &entry)
			key, key_ok := iter_string(&entry)
			dbus_message_iter_next(&entry)
			if key_ok && dbus_message_iter_get_arg_type(&entry) == DBUS_TYPE_VARIANT {
				dbus_message_iter_recurse(&entry, &value)
				parse_hint(&req, key, &value)
			}
			dbus_message_iter_next(&arr)
		}
	}
	dbus_message_iter_next(&it)

	timeout, has_timeout := iter_int(&it)
	req.expire_ms = has_timeout ? i32(timeout) : -1
	return req, true
}

@(private)
parse_hint :: proc(req: ^Notify_Request, key: string, value: ^DBusMessageIter) {
	switch key {
	case "urgency":
		if v, ok := iter_int(value); ok { req.urgency = u8(clamp(v, 0, 2)) }
	case "transient":
		if v, ok := iter_int(value); ok { req.transient = v != 0 }
	case "resident":
		if v, ok := iter_int(value); ok { req.resident = v != 0 }
	case "desktop-entry":
		if s, ok := iter_string(value); ok { req.desktop_entry = s }
	case "image-path", "image_path":
		if s, ok := iter_string(value); ok { req.image_path = s }
	case "image-data", "image_data", "icon_data":
		// image-data wins over the deprecated names.
		if len(req.image.data) > 0 && key != "image-data" { return }
		if img, ok := parse_image(value); ok { req.image = img }
	}
}

@(private)
parse_image :: proc(value: ^DBusMessageIter) -> (img: Raw_Image, ok: bool) {
	if dbus_message_iter_get_arg_type(value) != DBUS_TYPE_STRUCT { return }
	s: DBusMessageIter
	dbus_message_iter_recurse(value, &s)
	w := iter_int(&s) or_return
	dbus_message_iter_next(&s)
	h := iter_int(&s) or_return
	dbus_message_iter_next(&s)
	stride := iter_int(&s) or_return
	dbus_message_iter_next(&s)
	alpha := iter_int(&s) or_return
	dbus_message_iter_next(&s)
	bits := iter_int(&s) or_return
	dbus_message_iter_next(&s)
	channels := iter_int(&s) or_return
	dbus_message_iter_next(&s)
	if dbus_message_iter_get_arg_type(&s) != DBUS_TYPE_ARRAY || dbus_message_iter_get_element_type(&s) != DBUS_TYPE_BYTE { return }
	arr: DBusMessageIter
	dbus_message_iter_recurse(&s, &arr)
	data: [^]u8
	count: i32
	dbus_message_iter_get_fixed_array(&arr, &data, &count)
	if data == nil || count <= 0 { return }
	img = Raw_Image{
		width = i32(w), height = i32(h), rowstride = i32(stride), has_alpha = alpha != 0,
		bits = i32(bits), channels = i32(channels), data = data[:count],
	}
	if img.width <= 0 || img.height <= 0 || img.width > 4096 || img.height > 4096 { return }
	if img.bits != 8 || (img.channels != 3 && img.channels != 4) { return }
	if int(img.rowstride) * int(img.height - 1) + int(img.width * img.channels) > len(img.data) { return }
	return img, true
}
