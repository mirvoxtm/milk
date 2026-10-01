// A minimal libdbus-1 binding for the idle manager: one private connection
// per bus (the session bus for org.freedesktop.ScreenSaver, the system bus
// for logind), never dispatched by libdbus itself. Like the notification
// daemon (notify/dbus.odin) the milk poll loop watches the socket, `bus_read`
// reads what is there without blocking and the owner pops the messages.
// Method calls are asynchronous: `bus_send` returns the serial and the reply
// comes back through the queue (dbus_message_get_reply_serial), so nothing
// ever waits on logind or the bus daemon.
package lock

import "core:log"
import "core:strings"

foreign import libdbus "system:dbus-1"

DBusConnection :: struct {}
DBusMessage :: struct {}

DBusError :: struct {
	name:     cstring,
	message:  cstring,
	dummy:    u32,
	padding1: rawptr,
}

DBusMessageIter :: struct {
	_: [16]rawptr,
}

DBUS_TYPE_INVALID :: i32(0)
DBUS_TYPE_BYTE    :: i32('y')
DBUS_TYPE_BOOLEAN :: i32('b')
DBUS_TYPE_INT32   :: i32('i')
DBUS_TYPE_UINT32  :: i32('u')
DBUS_TYPE_INT64   :: i32('x')
DBUS_TYPE_UINT64  :: i32('t')
DBUS_TYPE_STRING  :: i32('s')
DBUS_TYPE_OBJECT_PATH :: i32('o')
DBUS_TYPE_UNIX_FD :: i32('h')

DBUS_MESSAGE_TYPE_METHOD_CALL   :: i32(1)
DBUS_MESSAGE_TYPE_METHOD_RETURN :: i32(2)
DBUS_MESSAGE_TYPE_ERROR         :: i32(3)
DBUS_MESSAGE_TYPE_SIGNAL        :: i32(4)

DBUS_NAME_FLAG_ALLOW_REPLACEMENT :: u32(0x1)
DBUS_NAME_FLAG_REPLACE_EXISTING  :: u32(0x2)
DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER :: i32(1)
DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER :: i32(4)

@(default_calling_convention="c")
foreign libdbus {
	dbus_error_init                        :: proc(err: ^DBusError) ---
	dbus_error_free                        :: proc(err: ^DBusError) ---
	dbus_error_is_set                      :: proc(err: ^DBusError) -> b32 ---
	dbus_connection_open_private           :: proc(address: cstring, err: ^DBusError) -> ^DBusConnection ---
	dbus_bus_register                      :: proc(conn: ^DBusConnection, err: ^DBusError) -> b32 ---
	dbus_bus_request_name                  :: proc(conn: ^DBusConnection, name: cstring, flags: u32, err: ^DBusError) -> i32 ---
	dbus_bus_add_match                     :: proc(conn: ^DBusConnection, rule: cstring, err: ^DBusError) ---
	dbus_bus_get_unique_name               :: proc(conn: ^DBusConnection) -> cstring ---
	dbus_connection_set_exit_on_disconnect :: proc(conn: ^DBusConnection, exit_on_disconnect: b32) ---
	dbus_connection_get_unix_fd            :: proc(conn: ^DBusConnection, fd: ^i32) -> b32 ---
	dbus_connection_read_write             :: proc(conn: ^DBusConnection, timeout_ms: i32) -> b32 ---
	dbus_connection_pop_message            :: proc(conn: ^DBusConnection) -> ^DBusMessage ---
	dbus_connection_send                   :: proc(conn: ^DBusConnection, msg: ^DBusMessage, serial: ^u32) -> b32 ---
	dbus_connection_close                  :: proc(conn: ^DBusConnection) ---
	dbus_connection_unref                  :: proc(conn: ^DBusConnection) ---
	dbus_connection_get_is_connected       :: proc(conn: ^DBusConnection) -> b32 ---
	dbus_connection_has_messages_to_send   :: proc(conn: ^DBusConnection) -> b32 ---
	dbus_connection_get_dispatch_status    :: proc(conn: ^DBusConnection) -> i32 --- // 0 = data remains
	dbus_message_new_method_call           :: proc(dest, path, iface, method: cstring) -> ^DBusMessage ---
	dbus_message_new_method_return         :: proc(call: ^DBusMessage) -> ^DBusMessage ---
	dbus_message_new_error                 :: proc(call: ^DBusMessage, name: cstring, text: cstring) -> ^DBusMessage ---
	dbus_message_new_signal                :: proc(path: cstring, iface: cstring, name: cstring) -> ^DBusMessage ---
	dbus_message_unref                     :: proc(msg: ^DBusMessage) ---
	dbus_message_get_type                  :: proc(msg: ^DBusMessage) -> i32 ---
	dbus_message_get_sender                :: proc(msg: ^DBusMessage) -> cstring ---
	dbus_message_get_interface             :: proc(msg: ^DBusMessage) -> cstring ---
	dbus_message_get_member                :: proc(msg: ^DBusMessage) -> cstring ---
	dbus_message_get_path                  :: proc(msg: ^DBusMessage) -> cstring ---
	dbus_message_get_error_name            :: proc(msg: ^DBusMessage) -> cstring ---
	dbus_message_get_reply_serial          :: proc(msg: ^DBusMessage) -> u32 ---
	dbus_message_get_no_reply              :: proc(msg: ^DBusMessage) -> b32 ---
	dbus_message_iter_init                 :: proc(msg: ^DBusMessage, iter: ^DBusMessageIter) -> b32 ---
	dbus_message_iter_init_append          :: proc(msg: ^DBusMessage, iter: ^DBusMessageIter) ---
	dbus_message_iter_get_arg_type         :: proc(iter: ^DBusMessageIter) -> i32 ---
	dbus_message_iter_next                 :: proc(iter: ^DBusMessageIter) -> b32 ---
	dbus_message_iter_get_basic            :: proc(iter: ^DBusMessageIter, value: rawptr) ---
	dbus_message_iter_append_basic         :: proc(iter: ^DBusMessageIter, type: i32, value: rawptr) -> b32 ---
}

// One private bus connection.
Bus :: struct {
	conn:  ^DBusConnection,
	fd:    i32,
	label: string, // "session" | "system" (literal, for the log)
}

// Connect and register on the bus at `address` (a D-Bus address string).
bus_open :: proc(b: ^Bus, address: string, label: string) -> bool {
	b.label = label
	b.fd = -1
	err: DBusError
	dbus_error_init(&err)
	defer dbus_error_free(&err)
	conn := dbus_connection_open_private(strings.clone_to_cstring(address, context.temp_allocator), &err)
	if conn == nil {
		log.warnf("Lock: cannot connect to the %s bus (%s)", label, err.message)
		return false
	}
	// libdbus would otherwise call exit() when the bus goes away.
	dbus_connection_set_exit_on_disconnect(conn, false)
	if !dbus_bus_register(conn, &err) {
		log.warnf("Lock: cannot register on the %s bus (%s)", label, err.message)
		dbus_connection_close(conn)
		dbus_connection_unref(conn)
		return false
	}
	fd: i32 = -1
	if !dbus_connection_get_unix_fd(conn, &fd) || fd < 0 {
		log.warnf("Lock: the %s bus connection has no file descriptor", label)
		dbus_connection_close(conn)
		dbus_connection_unref(conn)
		return false
	}
	b.conn = conn
	b.fd = fd
	return true
}

bus_close :: proc(b: ^Bus) {
	if b.conn == nil { return }
	// Deliver what is queued (an UnInhibit, a released name), never hanging.
	for i := 0; i < 10 && dbus_connection_has_messages_to_send(b.conn); i += 1 {
		if !dbus_connection_read_write(b.conn, 20) { break }
	}
	dbus_connection_close(b.conn)
	dbus_connection_unref(b.conn)
	b.conn = nil
	b.fd = -1
}

// Read what the socket has and write what it accepts (never blocks); false
// when the connection is gone.
bus_read :: proc(b: ^Bus) -> bool {
	if b.conn == nil { return false }
	if !dbus_connection_read_write(b.conn, 0) { return false }
	return bool(dbus_connection_get_is_connected(b.conn))
}

bus_pop :: proc(b: ^Bus) -> ^DBusMessage {
	if b.conn == nil { return nil }
	return dbus_connection_pop_message(b.conn)
}

// Messages read but not handled yet, or output waiting for the socket.
bus_busy :: proc(b: ^Bus) -> bool {
	if b.conn == nil { return false }
	return dbus_connection_get_dispatch_status(b.conn) == 0 || bool(dbus_connection_has_messages_to_send(b.conn))
}

// Queue a message (unref'd here); returns its serial (0 = not sent).
bus_send :: proc(b: ^Bus, msg: ^DBusMessage) -> u32 {
	if msg == nil { return 0 }
	defer dbus_message_unref(msg)
	if b.conn == nil { return 0 }
	serial: u32
	if !dbus_connection_send(b.conn, msg, &serial) { return 0 }
	dbus_connection_read_write(b.conn, 0) // start writing now
	return serial
}

bus_add_match :: proc(b: ^Bus, rule: string) {
	if b.conn == nil { return }
	dbus_bus_add_match(b.conn, strings.clone_to_cstring(rule, context.temp_allocator), nil) // no reply awaited
}

bus_unique_name :: proc(b: ^Bus) -> string {
	if b.conn == nil { return "" }
	return string(dbus_bus_get_unique_name(b.conn))
}

// A method call with string/bool/u32 arguments (Odin values: string, bool, u32, i32).
method_call :: proc(dest, path, iface, method: string, args: ..any) -> ^DBusMessage {
	c :: proc(s: string) -> cstring { return strings.clone_to_cstring(s, context.temp_allocator) }
	msg := dbus_message_new_method_call(c(dest), c(path), c(iface), c(method))
	if msg == nil { return nil }
	it: DBusMessageIter
	dbus_message_iter_init_append(msg, &it)
	for a in args { append_any(&it, a) }
	return msg
}

append_any :: proc(it: ^DBusMessageIter, a: any) {
	switch v in a {
	case string:
		s := strings.clone_to_cstring(v, context.temp_allocator)
		dbus_message_iter_append_basic(it, DBUS_TYPE_STRING, &s)
	case bool:
		b := u32(v ? 1 : 0)
		dbus_message_iter_append_basic(it, DBUS_TYPE_BOOLEAN, &b)
	case u32:
		x := v
		dbus_message_iter_append_basic(it, DBUS_TYPE_UINT32, &x)
	case i32:
		x := v
		dbus_message_iter_append_basic(it, DBUS_TYPE_INT32, &x)
	case:
		log.errorf("Lock: cannot send a %v over D-Bus", a.id)
	}
}

msg_type      :: proc(msg: ^DBusMessage) -> i32 { return dbus_message_get_type(msg) }
msg_member    :: proc(msg: ^DBusMessage) -> string { return string(dbus_message_get_member(msg)) }
msg_interface :: proc(msg: ^DBusMessage) -> string { return string(dbus_message_get_interface(msg)) }
msg_path      :: proc(msg: ^DBusMessage) -> string { return string(dbus_message_get_path(msg)) }
msg_sender    :: proc(msg: ^DBusMessage) -> string { return string(dbus_message_get_sender(msg)) }

// The arguments of a message, read in order.
Args :: struct {
	it:    DBusMessageIter,
	valid: bool,
}

args_of :: proc(msg: ^DBusMessage) -> Args {
	a: Args
	a.valid = bool(dbus_message_iter_init(msg, &a.it))
	return a
}

// The next argument as a string (s, o or g); temp allocator.
arg_string :: proc(a: ^Args) -> (string, bool) {
	if !a.valid { return "", false }
	t := dbus_message_iter_get_arg_type(&a.it)
	if t != DBUS_TYPE_STRING && t != DBUS_TYPE_OBJECT_PATH && t != i32('g') { return "", false }
	s: cstring
	dbus_message_iter_get_basic(&a.it, &s)
	advance(a)
	return strings.clone(string(s), context.temp_allocator), true
}

// The next argument as an integer (any integer type or boolean).
arg_int :: proc(a: ^Args) -> (i64, bool) {
	if !a.valid { return 0, false }
	v: i64
	switch dbus_message_iter_get_arg_type(&a.it) {
	case DBUS_TYPE_BYTE:
		x: u8
		dbus_message_iter_get_basic(&a.it, &x)
		v = i64(x)
	case DBUS_TYPE_BOOLEAN, DBUS_TYPE_UINT32:
		x: u32
		dbus_message_iter_get_basic(&a.it, &x)
		v = i64(x)
	case DBUS_TYPE_INT32:
		x: i32
		dbus_message_iter_get_basic(&a.it, &x)
		v = i64(x)
	case DBUS_TYPE_INT64, DBUS_TYPE_UINT64:
		dbus_message_iter_get_basic(&a.it, &v)
	case:
		return 0, false
	}
	advance(a)
	return v, true
}

// The next argument as a file descriptor (a dup the caller owns), -1 if none.
arg_fd :: proc(a: ^Args) -> (i32, bool) {
	if !a.valid || dbus_message_iter_get_arg_type(&a.it) != DBUS_TYPE_UNIX_FD { return -1, false }
	fd: i32 = -1
	dbus_message_iter_get_basic(&a.it, &fd)
	advance(a)
	return fd, fd >= 0
}

@(private)
advance :: proc(a: ^Args) {
	// dbus_message_iter_next returns false at the last argument; the type of
	// the (now exhausted) iterator then reads DBUS_TYPE_INVALID.
	dbus_message_iter_next(&a.it)
}

// Reply to a method call with values (or nothing).
reply_values :: proc(b: ^Bus, call: ^DBusMessage, values: ..any) {
	if dbus_message_get_no_reply(call) { return }
	msg := dbus_message_new_method_return(call)
	if msg == nil { return }
	it: DBusMessageIter
	dbus_message_iter_init_append(msg, &it)
	for v in values { append_any(&it, v) }
	bus_send(b, msg)
}

reply_error :: proc(b: ^Bus, call: ^DBusMessage, name, text: string) {
	if dbus_message_get_no_reply(call) { return }
	bus_send(b, dbus_message_new_error(call, strings.clone_to_cstring(name, context.temp_allocator),
	                                     strings.clone_to_cstring(text, context.temp_allocator)))
}
