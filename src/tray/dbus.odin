// The tray's session bus connection, through a minimal libdbus-1 binding
// (the same approach as the notification server in notify/dbus.odin).
//
// The connection is private and never dispatched by libdbus: the milk poll
// loop watches its unix fd, `bus_pump` reads what is available without
// blocking and handles the queued messages one by one. Every call the tray
// makes is asynchronous: the request is sent with its serial remembered in
// `pending` (with a deadline), and the reply is matched by its reply serial
// when it is popped from the queue. An application that never answers only
// costs a timeout; milk never waits for one.
//
// libdbus aborts the process on malformed arguments (bad object paths, bus
// names or UTF-8), so everything that comes from another program is checked
// with valid_bus_name / valid_object_path before it is used in a message.
package tray

import "core:log"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import tx "../tx"

foreign import libdbus "system:dbus-1"

@(private) DBusConnection :: struct {}
@(private) DBusMessage :: struct {}

// dbus-errors.h: two strings, a word of bit fields, a pointer.
@(private)
DBusError :: struct {
	name:     cstring,
	message:  cstring,
	dummy:    u32,
	padding1: rawptr,
}

// dbus-message.h: 72 bytes of private fields on 64-bit; reserve more.
@(private)
DBusMessageIter :: struct {
	_: [16]rawptr,
}

@(private) DBUS_TYPE_INVALID     :: i32(0)
@(private) DBUS_TYPE_BYTE        :: i32('y')
@(private) DBUS_TYPE_BOOLEAN     :: i32('b')
@(private) DBUS_TYPE_INT16       :: i32('n')
@(private) DBUS_TYPE_UINT16      :: i32('q')
@(private) DBUS_TYPE_INT32       :: i32('i')
@(private) DBUS_TYPE_UINT32      :: i32('u')
@(private) DBUS_TYPE_INT64       :: i32('x')
@(private) DBUS_TYPE_UINT64      :: i32('t')
@(private) DBUS_TYPE_STRING      :: i32('s')
@(private) DBUS_TYPE_OBJECT_PATH :: i32('o')
@(private) DBUS_TYPE_SIGNATURE   :: i32('g')
@(private) DBUS_TYPE_ARRAY       :: i32('a')
@(private) DBUS_TYPE_VARIANT     :: i32('v')
@(private) DBUS_TYPE_STRUCT      :: i32('r')
@(private) DBUS_TYPE_DICT_ENTRY  :: i32('e')

@(private) DBUS_MESSAGE_TYPE_METHOD_CALL   :: i32(1)
@(private) DBUS_MESSAGE_TYPE_METHOD_RETURN :: i32(2)
@(private) DBUS_MESSAGE_TYPE_ERROR         :: i32(3)
@(private) DBUS_MESSAGE_TYPE_SIGNAL        :: i32(4)

@(private) DBUS_NAME_FLAG_DO_NOT_QUEUE             :: u32(0x4)
@(private) DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER  :: u32(1)
@(private) DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER  :: u32(4)

@(default_calling_convention="c")
foreign libdbus {
	@(private) dbus_error_init                        :: proc(err: ^DBusError) ---
	@(private) dbus_error_free                        :: proc(err: ^DBusError) ---
	@(private) dbus_connection_open_private           :: proc(address: cstring, err: ^DBusError) -> ^DBusConnection ---
	@(private) dbus_bus_register                      :: proc(conn: ^DBusConnection, err: ^DBusError) -> b32 ---
	@(private) dbus_bus_get_unique_name               :: proc(conn: ^DBusConnection) -> cstring ---
	@(private) dbus_bus_add_match                     :: proc(conn: ^DBusConnection, rule: cstring, err: ^DBusError) ---
	@(private) dbus_connection_set_exit_on_disconnect :: proc(conn: ^DBusConnection, exit_on_disconnect: b32) ---
	@(private) dbus_connection_get_unix_fd            :: proc(conn: ^DBusConnection, fd: ^i32) -> b32 ---
	@(private) dbus_connection_read_write             :: proc(conn: ^DBusConnection, timeout_ms: i32) -> b32 ---
	@(private) dbus_connection_pop_message            :: proc(conn: ^DBusConnection) -> ^DBusMessage ---
	@(private) dbus_connection_send                   :: proc(conn: ^DBusConnection, msg: ^DBusMessage, serial: ^u32) -> b32 ---
	@(private) dbus_connection_close                  :: proc(conn: ^DBusConnection) ---
	@(private) dbus_connection_unref                  :: proc(conn: ^DBusConnection) ---
	@(private) dbus_connection_get_is_connected       :: proc(conn: ^DBusConnection) -> b32 ---
	@(private) dbus_connection_has_messages_to_send   :: proc(conn: ^DBusConnection) -> b32 ---
	@(private) dbus_connection_get_dispatch_status    :: proc(conn: ^DBusConnection) -> i32 --- // 0 = data remains
	@(private) dbus_message_new_method_call           :: proc(dest, path, iface, method: cstring) -> ^DBusMessage ---
	@(private) dbus_message_new_method_return         :: proc(call: ^DBusMessage) -> ^DBusMessage ---
	@(private) dbus_message_new_error                 :: proc(call: ^DBusMessage, name: cstring, text: cstring) -> ^DBusMessage ---
	@(private) dbus_message_new_signal                :: proc(path: cstring, iface: cstring, name: cstring) -> ^DBusMessage ---
	@(private) dbus_message_unref                     :: proc(msg: ^DBusMessage) ---
	@(private) dbus_message_set_no_reply              :: proc(msg: ^DBusMessage, no_reply: b32) ---
	@(private) dbus_message_get_type                  :: proc(msg: ^DBusMessage) -> i32 ---
	@(private) dbus_message_get_sender                :: proc(msg: ^DBusMessage) -> cstring ---
	@(private) dbus_message_get_interface             :: proc(msg: ^DBusMessage) -> cstring ---
	@(private) dbus_message_get_member                :: proc(msg: ^DBusMessage) -> cstring ---
	@(private) dbus_message_get_path                  :: proc(msg: ^DBusMessage) -> cstring ---
	@(private) dbus_message_get_reply_serial          :: proc(msg: ^DBusMessage) -> u32 ---
	@(private) dbus_message_get_error_name            :: proc(msg: ^DBusMessage) -> cstring ---
	@(private) dbus_message_iter_init                 :: proc(msg: ^DBusMessage, iter: ^DBusMessageIter) -> b32 ---
	@(private) dbus_message_iter_init_append          :: proc(msg: ^DBusMessage, iter: ^DBusMessageIter) ---
	@(private) dbus_message_iter_get_arg_type         :: proc(iter: ^DBusMessageIter) -> i32 ---
	@(private) dbus_message_iter_get_element_type     :: proc(iter: ^DBusMessageIter) -> i32 ---
	@(private) dbus_message_iter_next                 :: proc(iter: ^DBusMessageIter) -> b32 ---
	@(private) dbus_message_iter_recurse              :: proc(iter: ^DBusMessageIter, sub: ^DBusMessageIter) ---
	@(private) dbus_message_iter_get_basic            :: proc(iter: ^DBusMessageIter, value: rawptr) ---
	@(private) dbus_message_iter_get_fixed_array      :: proc(iter: ^DBusMessageIter, value: rawptr, n_elements: ^i32) ---
	@(private) dbus_message_iter_append_basic         :: proc(iter: ^DBusMessageIter, type: i32, value: rawptr) -> b32 ---
	@(private) dbus_message_iter_open_container       :: proc(iter: ^DBusMessageIter, type: i32, signature: cstring, sub: ^DBusMessageIter) -> b32 ---
	@(private) dbus_message_iter_close_container      :: proc(iter: ^DBusMessageIter, sub: ^DBusMessageIter) -> b32 ---
}

@(private) DBUS_NAME  :: "org.freedesktop.DBus"
@(private) DBUS_PATH  :: "/org/freedesktop/DBus"
@(private) PROPS_IFACE :: "org.freedesktop.DBus.Properties"

@(private) CALL_TIMEOUT :: 4.0 // seconds an application gets to answer a call

// What a reply answers (see bus_reply in sni.odin).
@(private)
Call :: enum {
	Request_Name,  // org.kde.StatusNotifierWatcher for milk
	Watcher_Owner, // GetNameOwner of the other watcher (host mode)
	Watcher_Items, // its RegisteredStatusNotifierItems
	Item_Owner,    // GetNameOwner of an item's well-known name
	Item_Props,    // GetAll of an item
	Activate,      // a left click (an error falls back to the menu)
	Menu_Layout,   // com.canonical.dbusmenu GetLayout
	Ignore,        // the reply does not matter (errors are logged)
}

@(private)
Pending :: struct {
	serial:   u32,
	call:     Call,
	item:     int, // Item.id the call is about (-1 = none)
	request:  int, // Menu_Layout: the menu request it answers
	deadline: f64,
}

@(private)
Bus_Mode :: enum {
	Off,     // no session bus (or it was lost): XEmbed icons only
	Waiting, // the name request is on its way
	Watcher, // milk serves org.kde.StatusNotifierWatcher (and is its host)
	Host,    // another program is the watcher; milk registered with it as a host
}

@(private)
Bus :: struct {
	conn:      ^DBusConnection,
	fd:        i32,
	mode:      Bus_Mode,
	unique:    string, // milk's unique name on the bus (owned)
	host_name: string, // org.kde.StatusNotifierHost-<pid> (owned)
	watcher:   string, // unique name of the other watcher in host mode (owned)
	pending:   [dynamic]Pending,
}

// Connect to the session bus and start the watcher/host negotiation.
@(private)
bus_open :: proc(t: ^Tray) -> bool {
	b := &t.bus
	b.fd = -1
	b.mode = .Off
	address := os.get_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator)
	if address == "" {
		log.warn("Tray: DBUS_SESSION_BUS_ADDRESS is not set; only XEmbed icons are shown")
		return false
	}
	err: DBusError
	dbus_error_init(&err)
	defer dbus_error_free(&err)
	conn := dbus_connection_open_private(strings.clone_to_cstring(address, context.temp_allocator), &err)
	if conn == nil {
		log.warnf("Tray: cannot connect to the session bus (%s); only XEmbed icons are shown", err.message)
		return false
	}
	// libdbus would otherwise call exit() when the bus goes away.
	dbus_connection_set_exit_on_disconnect(conn, false)
	if !dbus_bus_register(conn, &err) {
		log.warnf("Tray: cannot register on the session bus (%s); only XEmbed icons are shown", err.message)
		dbus_connection_close(conn)
		dbus_connection_unref(conn)
		return false
	}
	fd: i32 = -1
	if !dbus_connection_get_unix_fd(conn, &fd) || fd < 0 {
		log.warn("Tray: the bus connection has no file descriptor; only XEmbed icons are shown")
		dbus_connection_close(conn)
		dbus_connection_unref(conn)
		return false
	}
	b.conn = conn
	b.fd = fd
	b.unique = strings.clone(string(dbus_bus_get_unique_name(conn)))
	b.pending = make([dynamic]Pending)
	b.host_name = strings.clone(strings.concatenate({"org.kde.StatusNotifierHost-", itoa(os.get_pid())}, context.temp_allocator))
	// Name owners (items and the watcher vanishing), item signals, the other
	// watcher's signals. No reply is awaited for any of them.
	for rule in ([]cstring{
		"type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'",
		"type='signal',interface='org.kde.StatusNotifierItem'",
		"type='signal',interface='org.kde.StatusNotifierWatcher'",
	}) {
		dbus_bus_add_match(conn, rule, nil)
	}
	request_watcher_name(t)
	request_name_ignored(t, b.host_name)
	bus_write(t)
	return true
}

@(private)
bus_close :: proc(t: ^Tray) {
	b := &t.bus
	if b.conn != nil {
		// Deliver pending signals (StatusNotifierItemUnregistered), but never hang on a stuck bus.
		for i := 0; i < 10 && dbus_connection_has_messages_to_send(b.conn); i += 1 {
			if !dbus_connection_read_write(b.conn, 20) { break }
		}
		dbus_connection_close(b.conn)
		dbus_connection_unref(b.conn)
	}
	b.conn = nil
	b.fd = -1
	b.mode = .Off
	delete(b.unique)
	delete(b.host_name)
	delete(b.watcher)
	delete(b.pending)
	b.unique, b.host_name, b.watcher = "", "", ""
	b.pending = nil
}

// The bus went away: the SNI items go with it, the XEmbed icons stay.
@(private)
bus_lost :: proc(t: ^Tray) {
	log.warn("Tray: the session bus connection was lost; only XEmbed icons are shown now")
	bus_close(t)
	drop_sni_items(t)
}

// Read what the socket has (never blocks) and handle every queued message.
@(private)
bus_pump :: proc(t: ^Tray, read: bool) {
	b := &t.bus
	if b.conn == nil { return }
	if read && !dbus_connection_read_write(b.conn, 0) {
		bus_lost(t)
		return
	}
	for b.conn != nil {
		msg := dbus_connection_pop_message(b.conn)
		if msg == nil { break }
		bus_handle(t, msg)
		dbus_message_unref(msg)
	}
	bus_write(t)
	if b.conn != nil && !dbus_connection_get_is_connected(b.conn) { bus_lost(t) }
}

// Write what the socket accepts now; the rest goes out on a later tick.
@(private)
bus_write :: proc(t: ^Tray) {
	b := &t.bus
	if b.conn == nil || !dbus_connection_has_messages_to_send(b.conn) { return }
	if !dbus_connection_read_write(b.conn, 0) { bus_lost(t) }
}

@(private)
bus_has_input :: proc(t: ^Tray) -> bool {
	return t.bus.conn != nil && dbus_connection_get_dispatch_status(t.bus.conn) == 0
}

@(private)
bus_has_output :: proc(t: ^Tray) -> bool {
	return t.bus.conn != nil && bool(dbus_connection_has_messages_to_send(t.bus.conn))
}

// Calls that ran out of time: their handlers see a nil reply.
@(private)
bus_expire :: proc(t: ^Tray, now: f64) {
	b := &t.bus
	for i := 0; i < len(b.pending); {
		p := b.pending[i]
		if now < p.deadline {
			i += 1
			continue
		}
		ordered_remove(&b.pending, i)
		bus_reply(t, p, nil)
	}
}

// The earliest deadline of the pending calls (-1 = none).
@(private)
bus_deadline :: proc(t: ^Tray) -> f64 {
	d := -1.0
	for p in t.bus.pending {
		if d < 0 || p.deadline < d { d = p.deadline }
	}
	return d
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

// A method call; nil when the destination or path is not valid.
@(private)
new_call :: proc(dest, path, iface, method: string) -> ^DBusMessage {
	if !valid_bus_name(dest) || !valid_object_path(path) { return nil }
	return dbus_message_new_method_call(cstr(dest), cstr(path), cstr(iface), cstr(method))
}

// Send `msg` (consumed). With a `call` other than nil the reply is awaited;
// without one the receiver is told not to answer.
@(private)
send_call :: proc(t: ^Tray, msg: ^DBusMessage, call: Maybe(Call), item := -1, request := 0) -> bool {
	if msg == nil { return false }
	defer dbus_message_unref(msg)
	b := &t.bus
	if b.conn == nil { return false }
	kind, awaited := call.?
	if !awaited { dbus_message_set_no_reply(msg, true) }
	serial: u32
	if !dbus_connection_send(b.conn, msg, &serial) { return false }
	if awaited { append(&b.pending, Pending{serial = serial, call = kind, item = item, request = request, deadline = tx.now() + CALL_TIMEOUT}) }
	return true
}

// A reply, a signal or an error we send (consumed).
@(private)
send_message :: proc(t: ^Tray, msg: ^DBusMessage) {
	if msg == nil { return }
	if t.bus.conn != nil { dbus_connection_send(t.bus.conn, msg, nil) }
	dbus_message_unref(msg)
}

@(private)
send_error :: proc(t: ^Tray, call: ^DBusMessage, name: cstring, text: string) {
	send_message(t, dbus_message_new_error(call, name, cstr(text)))
}

// Forget the calls about an item that is gone.
@(private)
drop_pending :: proc(t: ^Tray, item: int) {
	for i := len(t.bus.pending) - 1; i >= 0; i -= 1 {
		if t.bus.pending[i].item == item { ordered_remove(&t.bus.pending, i) }
	}
}

@(private)
take_pending :: proc(t: ^Tray, serial: u32) -> (Pending, bool) {
	for p, i in t.bus.pending {
		if p.serial == serial {
			ordered_remove(&t.bus.pending, i)
			return p, true
		}
	}
	return {}, false
}

@(private)
append_string :: proc(it: ^DBusMessageIter, s: string) {
	v := cstr(valid_utf8(s))
	dbus_message_iter_append_basic(it, DBUS_TYPE_STRING, &v)
}

@(private)
append_i32 :: proc(it: ^DBusMessageIter, v: i32) {
	x := v
	dbus_message_iter_append_basic(it, DBUS_TYPE_INT32, &x)
}

@(private)
append_u32 :: proc(it: ^DBusMessageIter, v: u32) {
	x := v
	dbus_message_iter_append_basic(it, DBUS_TYPE_UINT32, &x)
}

@(private)
append_bool :: proc(it: ^DBusMessageIter, v: bool) {
	x := u32(v ? 1 : 0)
	dbus_message_iter_append_basic(it, DBUS_TYPE_BOOLEAN, &x)
}

// A variant holding one basic value or a string array.
@(private)
Variant :: union { string, i32, bool, []string }

@(private)
append_variant :: proc(it: ^DBusMessageIter, v: Variant) {
	sub: DBusMessageIter
	switch x in v {
	case string:
		dbus_message_iter_open_container(it, DBUS_TYPE_VARIANT, "s", &sub)
		append_string(&sub, x)
	case i32:
		dbus_message_iter_open_container(it, DBUS_TYPE_VARIANT, "i", &sub)
		append_i32(&sub, x)
	case bool:
		dbus_message_iter_open_container(it, DBUS_TYPE_VARIANT, "b", &sub)
		append_bool(&sub, x)
	case []string:
		dbus_message_iter_open_container(it, DBUS_TYPE_VARIANT, "as", &sub)
		arr: DBusMessageIter
		dbus_message_iter_open_container(&sub, DBUS_TYPE_ARRAY, "s", &arr)
		for s in x { append_string(&arr, s) }
		dbus_message_iter_close_container(&sub, &arr)
	}
	dbus_message_iter_close_container(it, &sub)
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------
@(private)
iter_string :: proc(it: ^DBusMessageIter) -> (string, bool) {
	t := dbus_message_iter_get_arg_type(it)
	if t != DBUS_TYPE_STRING && t != DBUS_TYPE_OBJECT_PATH && t != DBUS_TYPE_SIGNATURE { return "", false }
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

// The first argument of a message as a string.
@(private)
first_string :: proc(msg: ^DBusMessage) -> (string, bool) {
	it: DBusMessageIter
	if !dbus_message_iter_init(msg, &it) { return "", false }
	return iter_string(&it)
}

// Call `each` for every entry of an a{sv} dictionary (the value iterator
// points into the variant).
@(private)
iter_dict :: proc(it: ^DBusMessageIter, data: rawptr, each: proc(data: rawptr, key: string, value: ^DBusMessageIter)) -> bool {
	if dbus_message_iter_get_arg_type(it) != DBUS_TYPE_ARRAY { return false }
	arr: DBusMessageIter
	dbus_message_iter_recurse(it, &arr)
	for dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_DICT_ENTRY {
		entry, value: DBusMessageIter
		dbus_message_iter_recurse(&arr, &entry)
		key, key_ok := iter_string(&entry)
		dbus_message_iter_next(&entry)
		if key_ok && dbus_message_iter_get_arg_type(&entry) == DBUS_TYPE_VARIANT {
			dbus_message_iter_recurse(&entry, &value)
			each(data, key, &value)
		}
		dbus_message_iter_next(&arr)
	}
	return true
}

// ---------------------------------------------------------------------------
// Validation (libdbus aborts on invalid names, paths and strings)
// ---------------------------------------------------------------------------
@(private)
valid_bus_name :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 255 { return false }
	unique := s[0] == ':'
	body := unique ? s[1:] : s
	if len(body) == 0 || body[0] == '.' { return false }
	elements := 0
	start := true
	for i in 0 ..< len(body) {
		ch := body[i]
		switch {
		case ch == '.':
			if start { return false }
			start = true
			continue
		case ch >= 'a' && ch <= 'z', ch >= 'A' && ch <= 'Z', ch == '_', ch == '-':
		case ch >= '0' && ch <= '9':
			if start && !unique { return false }
		case:
			return false
		}
		if start { elements += 1 }
		start = false
	}
	return !start && elements >= 2
}

@(private)
valid_object_path :: proc(s: string) -> bool {
	if len(s) == 0 || s[0] != '/' { return false }
	if s == "/" { return true }
	if s[len(s) - 1] == '/' { return false }
	prev_slash := false
	for i in 0 ..< len(s) {
		ch := s[i]
		switch {
		case ch == '/':
			if prev_slash { return false }
			prev_slash = true
			continue
		case ch >= 'a' && ch <= 'z', ch >= 'A' && ch <= 'Z', ch >= '0' && ch <= '9', ch == '_':
		case:
			return false
		}
		prev_slash = false
	}
	return true
}

// `s` itself when it is valid UTF-8 without NULs, else a cleaned copy (temp allocator).
@(private)
valid_utf8 :: proc(s: string) -> string {
	if utf8.valid_string(s) && strings.index_byte(s, 0) < 0 { return s }
	out := strings.builder_make(context.temp_allocator)
	for r in s {
		if r == utf8.RUNE_ERROR || r == 0 { continue }
		strings.write_rune(&out, r)
	}
	return strings.to_string(out)
}

@(private)
cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

@(private)
itoa :: proc(v: int) -> string {
	buf: [24]u8
	i := len(buf)
	n := v < 0 ? -v : v
	for {
		i -= 1
		buf[i] = u8('0' + n % 10)
		n /= 10
		if n == 0 { break }
	}
	if v < 0 {
		i -= 1
		buf[i] = '-'
	}
	return strings.clone(string(buf[i:]), context.temp_allocator)
}
