// The agent's system bus connection: a minimal libdbus-1 binding like the lock
// screen's (lock/dbus.odin), plus the containers polkit's signatures need:
// the subject (sa{sv}) it registers with, and the details (a{ss}) and
// identities (a(sa{sv})) of BeginAuthentication. The connection is private
// and never dispatched by libdbus: the milk poll loop watches its socket,
// `bus_read` reads what is there without blocking and the agent pops the
// messages. Every call is asynchronous (the reply is matched by its serial).
package polkit

import "core:log"
import "core:strings"

foreign import libdbus "system:dbus-1"

@(private) DBusConnection :: struct {}
@(private) DBusMessage :: struct {}

@(private)
DBusError :: struct {
	name:     cstring,
	message:  cstring,
	dummy:    u32,
	padding1: rawptr,
}

@(private)
DBusMessageIter :: struct {
	_: [16]rawptr,
}

@(private) DBUS_TYPE_INVALID     :: i32(0)
@(private) DBUS_TYPE_BYTE        :: i32('y')
@(private) DBUS_TYPE_BOOLEAN     :: i32('b')
@(private) DBUS_TYPE_INT32       :: i32('i')
@(private) DBUS_TYPE_UINT32      :: i32('u')
@(private) DBUS_TYPE_INT64       :: i32('x')
@(private) DBUS_TYPE_UINT64      :: i32('t')
@(private) DBUS_TYPE_STRING      :: i32('s')
@(private) DBUS_TYPE_OBJECT_PATH :: i32('o')
@(private) DBUS_TYPE_ARRAY       :: i32('a')
@(private) DBUS_TYPE_VARIANT     :: i32('v')
@(private) DBUS_TYPE_STRUCT      :: i32('r')
@(private) DBUS_TYPE_DICT_ENTRY  :: i32('e')

@(private) DBUS_MESSAGE_TYPE_METHOD_CALL   :: i32(1)
@(private) DBUS_MESSAGE_TYPE_METHOD_RETURN :: i32(2)
@(private) DBUS_MESSAGE_TYPE_ERROR         :: i32(3)
@(private) DBUS_MESSAGE_TYPE_SIGNAL        :: i32(4)

@(default_calling_convention="c")
foreign libdbus {
	@(private) dbus_error_init                        :: proc(err: ^DBusError) ---
	@(private) dbus_error_free                        :: proc(err: ^DBusError) ---
	@(private) dbus_connection_open_private           :: proc(address: cstring, err: ^DBusError) -> ^DBusConnection ---
	@(private) dbus_bus_register                      :: proc(conn: ^DBusConnection, err: ^DBusError) -> b32 ---
	@(private) dbus_connection_set_exit_on_disconnect :: proc(conn: ^DBusConnection, exit_on_disconnect: b32) ---
	@(private) dbus_connection_get_unix_fd            :: proc(conn: ^DBusConnection, fd: ^i32) -> b32 ---
	@(private) dbus_connection_read_write             :: proc(conn: ^DBusConnection, timeout_ms: i32) -> b32 ---
	@(private) dbus_connection_pop_message            :: proc(conn: ^DBusConnection) -> ^DBusMessage ---
	@(private) dbus_connection_send                   :: proc(conn: ^DBusConnection, msg: ^DBusMessage, serial: ^u32) -> b32 ---
	@(private) dbus_connection_flush                  :: proc(conn: ^DBusConnection) ---
	@(private) dbus_connection_close                  :: proc(conn: ^DBusConnection) ---
	@(private) dbus_connection_unref                  :: proc(conn: ^DBusConnection) ---
	@(private) dbus_connection_get_is_connected       :: proc(conn: ^DBusConnection) -> b32 ---
	@(private) dbus_connection_has_messages_to_send   :: proc(conn: ^DBusConnection) -> b32 ---
	@(private) dbus_message_new_method_call           :: proc(dest, path, iface, method: cstring) -> ^DBusMessage ---
	@(private) dbus_message_new_method_return         :: proc(call: ^DBusMessage) -> ^DBusMessage ---
	@(private) dbus_message_new_error                 :: proc(call: ^DBusMessage, name: cstring, text: cstring) -> ^DBusMessage ---
	@(private) dbus_message_ref                       :: proc(msg: ^DBusMessage) -> ^DBusMessage ---
	@(private) dbus_message_unref                     :: proc(msg: ^DBusMessage) ---
	@(private) dbus_message_get_type                  :: proc(msg: ^DBusMessage) -> i32 ---
	@(private) dbus_message_get_interface             :: proc(msg: ^DBusMessage) -> cstring ---
	@(private) dbus_message_get_member                :: proc(msg: ^DBusMessage) -> cstring ---
	@(private) dbus_message_get_path                  :: proc(msg: ^DBusMessage) -> cstring ---
	@(private) dbus_message_get_error_name            :: proc(msg: ^DBusMessage) -> cstring ---
	@(private) dbus_message_get_reply_serial          :: proc(msg: ^DBusMessage) -> u32 ---
	@(private) dbus_message_get_no_reply              :: proc(msg: ^DBusMessage) -> b32 ---
	@(private) dbus_message_iter_init                 :: proc(msg: ^DBusMessage, iter: ^DBusMessageIter) -> b32 ---
	@(private) dbus_message_iter_init_append          :: proc(msg: ^DBusMessage, iter: ^DBusMessageIter) ---
	@(private) dbus_message_iter_get_arg_type         :: proc(iter: ^DBusMessageIter) -> i32 ---
	@(private) dbus_message_iter_next                 :: proc(iter: ^DBusMessageIter) -> b32 ---
	@(private) dbus_message_iter_recurse              :: proc(iter: ^DBusMessageIter, sub: ^DBusMessageIter) ---
	@(private) dbus_message_iter_get_basic            :: proc(iter: ^DBusMessageIter, value: rawptr) ---
	@(private) dbus_message_iter_append_basic         :: proc(iter: ^DBusMessageIter, type: i32, value: rawptr) -> b32 ---
	@(private) dbus_message_iter_open_container       :: proc(iter: ^DBusMessageIter, type: i32, signature: cstring, sub: ^DBusMessageIter) -> b32 ---
	@(private) dbus_message_iter_close_container      :: proc(iter: ^DBusMessageIter, sub: ^DBusMessageIter) -> b32 ---
}

@(private)
Bus :: struct {
	conn: ^DBusConnection,
	fd:   i32,
}

@(private)
bus_open :: proc(b: ^Bus, address: string) -> bool {
	b.fd = -1
	err: DBusError
	dbus_error_init(&err)
	defer dbus_error_free(&err)
	conn := dbus_connection_open_private(cstr(address), &err)
	if conn == nil {
		log.warnf("Polkit: cannot connect to the system bus (%s)", err.message)
		return false
	}
	dbus_connection_set_exit_on_disconnect(conn, false) // else libdbus calls exit() when the bus goes away
	if !dbus_bus_register(conn, &err) {
		log.warnf("Polkit: cannot register on the system bus (%s)", err.message)
		dbus_connection_close(conn)
		dbus_connection_unref(conn)
		return false
	}
	fd: i32 = -1
	if !dbus_connection_get_unix_fd(conn, &fd) || fd < 0 {
		dbus_connection_close(conn)
		dbus_connection_unref(conn)
		return false
	}
	b.conn, b.fd = conn, fd
	return true
}

@(private)
bus_close :: proc(b: ^Bus) {
	if b.conn == nil { return }
	// Deliver what is queued (the unregistration, last replies), never hanging.
	for i := 0; i < 10 && dbus_connection_has_messages_to_send(b.conn); i += 1 {
		if !dbus_connection_read_write(b.conn, 20) { break }
	}
	dbus_connection_close(b.conn)
	dbus_connection_unref(b.conn)
	b.conn = nil
	b.fd = -1
}

// Read and write what the socket allows (never blocks); false once the connection is gone.
@(private)
bus_read :: proc(b: ^Bus) -> bool {
	if b.conn == nil { return false }
	if !dbus_connection_read_write(b.conn, 0) { return false }
	return bool(dbus_connection_get_is_connected(b.conn))
}

// Queue a message (unref'd here); its serial, 0 when it was not sent.
@(private)
bus_send :: proc(b: ^Bus, msg: ^DBusMessage) -> u32 {
	if msg == nil { return 0 }
	defer dbus_message_unref(msg)
	if b.conn == nil { return 0 }
	serial: u32
	if !dbus_connection_send(b.conn, msg, &serial) { return 0 }
	dbus_connection_read_write(b.conn, 0)
	return serial
}

@(private)
cstr :: proc(s: string) -> cstring { return strings.clone_to_cstring(s, context.temp_allocator) }

@(private)
new_call :: proc(dest, path, iface, method: string) -> (^DBusMessage, DBusMessageIter) {
	it: DBusMessageIter
	msg := dbus_message_new_method_call(cstr(dest), cstr(path), cstr(iface), cstr(method))
	if msg != nil { dbus_message_iter_init_append(msg, &it) }
	return msg, it
}

@(private)
append_string :: proc(it: ^DBusMessageIter, s: string) {
	v := cstr(s)
	dbus_message_iter_append_basic(it, DBUS_TYPE_STRING, &v)
}

@(private)
append_u32 :: proc(it: ^DBusMessageIter, v: u32) {
	x := v
	dbus_message_iter_append_basic(it, DBUS_TYPE_UINT32, &x)
}

// A polkit subject: (kind, {key: value}) with one string or uint32 detail.
@(private)
append_subject :: proc(it: ^DBusMessageIter, kind: string, key: string, value: union { string, u32 }) {
	st, dict, entry, variant: DBusMessageIter
	dbus_message_iter_open_container(it, DBUS_TYPE_STRUCT, nil, &st)
	append_string(&st, kind)
	dbus_message_iter_open_container(&st, DBUS_TYPE_ARRAY, "{sv}", &dict)
	dbus_message_iter_open_container(&dict, DBUS_TYPE_DICT_ENTRY, nil, &entry)
	append_string(&entry, key)
	switch v in value {
	case string:
		dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "s", &variant)
		append_string(&variant, v)
	case u32:
		dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "u", &variant)
		append_u32(&variant, v)
	}
	dbus_message_iter_close_container(&entry, &variant)
	dbus_message_iter_close_container(&dict, &entry)
	dbus_message_iter_close_container(&st, &dict)
	dbus_message_iter_close_container(it, &st)
}

@(private)
reply_empty :: proc(b: ^Bus, call: ^DBusMessage) {
	if call == nil || dbus_message_get_no_reply(call) { return }
	bus_send(b, dbus_message_new_method_return(call))
}

@(private)
reply_string :: proc(b: ^Bus, call: ^DBusMessage, s: string) {
	if call == nil || dbus_message_get_no_reply(call) { return }
	msg := dbus_message_new_method_return(call)
	if msg == nil { return }
	it: DBusMessageIter
	dbus_message_iter_init_append(msg, &it)
	append_string(&it, s)
	bus_send(b, msg)
}

@(private)
reply_error :: proc(b: ^Bus, call: ^DBusMessage, name, text: string) {
	if call == nil || dbus_message_get_no_reply(call) { return }
	bus_send(b, dbus_message_new_error(call, cstr(name), cstr(text)))
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------
@(private) msg_type      :: proc(msg: ^DBusMessage) -> i32 { return dbus_message_get_type(msg) }
@(private) msg_member    :: proc(msg: ^DBusMessage) -> string { return string(dbus_message_get_member(msg)) }
@(private) msg_interface :: proc(msg: ^DBusMessage) -> string { return string(dbus_message_get_interface(msg)) }
@(private) msg_path      :: proc(msg: ^DBusMessage) -> string { return string(dbus_message_get_path(msg)) }

// The current argument as a string (s, o or g; temp allocator) and move on.
@(private)
next_string :: proc(it: ^DBusMessageIter) -> (string, bool) {
	t := dbus_message_iter_get_arg_type(it)
	if t != DBUS_TYPE_STRING && t != DBUS_TYPE_OBJECT_PATH && t != i32('g') { return "", false }
	s: cstring
	dbus_message_iter_get_basic(it, &s)
	dbus_message_iter_next(it)
	return strings.clone(string(s), context.temp_allocator), true
}

// Any integer type as i64 (no move).
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
	case DBUS_TYPE_INT64, DBUS_TYPE_UINT64:
		v: i64
		dbus_message_iter_get_basic(it, &v)
		return v, true
	}
	return 0, false
}

// The first argument of a reply as a string.
@(private)
first_string :: proc(msg: ^DBusMessage) -> (string, bool) {
	it: DBusMessageIter
	if !dbus_message_iter_init(msg, &it) { return "", false }
	return next_string(&it)
}
