// Package polkit: milk's polkit authentication agent. When a program asks
// polkit for something that needs a password (pkexec, GParted, an update
// tool, mounting a disk), polkitd asks the agent of the session, which shows
// milk's password dialog (dialog.odin) and relays the answer to polkit's
// helper (helper.odin); without an agent such programs just fail.
//
// The agent registers for this session (XDG_SESSION_ID, else logind's
// session of milk's pid) with RegisterAuthenticationAgent and then serves
// org.freedesktop.PolicyKit1.AuthenticationAgent at AGENT_PATH:
// BeginAuthentication is answered once the user authenticates (or with
// Error.Cancelled when they dismiss the dialog), CancelAuthentication closes
// the dialog. Requests that come while one is on screen wait in a queue.
// When another agent already serves the session, milk's stays off.
//
// The system bus is $MILK_SYSTEM_BUS_ADDRESS when set ("none" turns the agent
// off; tests point it at a private bus with a fake polkitd), else
// $DBUS_SYSTEM_BUS_ADDRESS, else the standard socket.
package polkit

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

@(private) AUTHORITY_NAME  :: "org.freedesktop.PolicyKit1"
@(private) AUTHORITY_PATH  :: "/org/freedesktop/PolicyKit1/Authority"
@(private) AUTHORITY_IFACE :: "org.freedesktop.PolicyKit1.Authority"
@(private) AGENT_IFACE     :: "org.freedesktop.PolicyKit1.AuthenticationAgent"
@(private) AGENT_PATH      :: "/org/milk/PolicyKit1/AuthenticationAgent"
@(private) ERROR_CANCELLED :: "org.freedesktop.PolicyKit1.Error.Cancelled"
@(private) LOGIND_NAME     :: "org.freedesktop.login1"
@(private) LOGIND_PATH     :: "/org/freedesktop/login1"

SYSTEM_BUS_ENV :: "MILK_SYSTEM_BUS_ADDRESS"

@(private, rodata)
INTROSPECTION := `<node>
 <interface name="org.freedesktop.PolicyKit1.AuthenticationAgent">
  <method name="BeginAuthentication">
   <arg type="s" name="action_id" direction="in"/>
   <arg type="s" name="message" direction="in"/>
   <arg type="s" name="icon_name" direction="in"/>
   <arg type="a{ss}" name="details" direction="in"/>
   <arg type="s" name="cookie" direction="in"/>
   <arg type="a(sa{sv})" name="identities" direction="in"/>
  </method>
  <method name="CancelAuthentication">
   <arg type="s" name="cookie" direction="in"/>
  </method>
 </interface>
</node>`

@(private)
Agent_State :: enum { Off, Finding_Session, Registering, Registered }

// One BeginAuthentication call.
@(private)
Request :: struct {
	call:      ^DBusMessage, // referenced until it is answered
	cookie:    string,
	action_id: string,
	message:   string,
	command:   string,          // details["command_line"] or ["program"], "" when not given
	users:     [dynamic]string, // who may authenticate (user names)
	user:      int,             // index into users
}

Agent :: struct {
	c:         ^tx.Connection,
	cfg:       ^config.Config,
	allocator: runtime.Allocator,
	bus:       Bus,
	state:     Agent_State,
	session:   string, // owned: the logind session id registered for
	serial:    u32,    // the GetSessionByPID or RegisterAuthenticationAgent call waiting for its reply
	queue:     [dynamic]^Request, // queue[0] is on screen
	helper:    Helper,
	dialog:    Dialog,
}

// The system bus address, or false when the agent is off.
@(private)
system_bus_address :: proc() -> (string, bool) {
	if v, found := os.lookup_env(SYSTEM_BUS_ENV, context.temp_allocator); found && v != "" {
		if v == "none" || v == "off" { return "", false }
		return v, true
	}
	if v, found := os.lookup_env("DBUS_SYSTEM_BUS_ADDRESS", context.temp_allocator); found && v != "" { return v, true }
	return "unix:path=/run/dbus/system_bus_socket", true
}

// Connect and register; nil when there is no system bus.
create :: proc(c: ^tx.Connection, cfg: ^config.Config) -> ^Agent {
	address, ok := system_bus_address()
	if !ok {
		log.info("Polkit: no system bus; the authentication agent is off")
		return nil
	}
	a := new(Agent)
	a.c, a.cfg, a.allocator = c, cfg, context.allocator
	helper_init(&a.helper)
	if !bus_open(&a.bus, address) {
		free(a)
		return nil
	}
	if id, found := os.lookup_env("XDG_SESSION_ID", context.temp_allocator); found && id != "" {
		register(a, id)
	} else {
		msg, it := new_call(LOGIND_NAME, LOGIND_PATH, "org.freedesktop.login1.Manager", "GetSessionByPID")
		append_u32(&it, u32(posix.getpid()))
		a.serial = bus_send(&a.bus, msg)
		a.state = .Finding_Session
	}
	return a
}

destroy :: proc(a: ^Agent) {
	if a == nil { return }
	context.allocator = a.allocator
	for r in a.queue {
		reply_error(&a.bus, r.call, ERROR_CANCELLED, "milk is stopping")
		request_free(r)
	}
	delete(a.queue)
	if a.state == .Registered {
		msg, it := new_call(AUTHORITY_NAME, AUTHORITY_PATH, AUTHORITY_IFACE, "UnregisterAuthenticationAgent")
		append_subject(&it, "unix-session", "session-id", a.session)
		append_string(&it, AGENT_PATH)
		bus_send(&a.bus, msg)
	}
	bus_close(&a.bus)
	dialog_destroy(a)
	helper_destroy(&a.helper)
	delete(a.session)
	free(a)
}

// New colours or fonts: the dialog follows.
reload :: proc(a: ^Agent, cfg: ^config.Config) {
	if a == nil { return }
	context.allocator = a.allocator
	a.cfg = cfg
	if a.dialog.open { dialog_restyle(a) }
}

poll_fds :: proc(a: ^Agent, allocator := context.temp_allocator) -> []i32 {
	out := make([dynamic]i32, allocator)
	if a == nil { return out[:] }
	if a.bus.fd >= 0 { append(&out, a.bus.fd) }
	if a.helper.fd >= 0 { append(&out, i32(a.helper.fd)) }
	return out[:]
}

handle_fd :: proc(a: ^Agent, fd: i32) {
	if a == nil { return }
	context.allocator = a.allocator
	if fd == a.bus.fd {
		pump(a)
	} else if fd == i32(a.helper.fd) {
		helper_events(a)
	}
}

tick :: proc(a: ^Agent, now: f64) {
	if a == nil { return }
	context.allocator = a.allocator
	helper_reap(&a.helper)
	dialog_tick(a, now)
	// Replies queued while handling X events go out now.
	if a.bus.conn != nil && dbus_connection_has_messages_to_send(a.bus.conn) { dbus_connection_read_write(a.bus.conn, 0) }
}

next_timeout :: proc(a: ^Agent, now: f64) -> f64 {
	if a == nil { return -1 }
	return dialog_next_timeout(a, now)
}

// X events for the dialog; true when the event was its own (while it is open
// it holds the keyboard, so every key is).
handle_event :: proc(a: ^Agent, ev: ^xlib.XEvent) -> bool {
	if a == nil || !a.dialog.open { return false }
	context.allocator = a.allocator
	return dialog_event(a, ev)
}

// ---------------------------------------------------------------------------
// Registration and the bus
// ---------------------------------------------------------------------------
@(private)
register :: proc(a: ^Agent, session: string) {
	delete(a.session)
	a.session = strings.clone(session)
	msg, it := new_call(AUTHORITY_NAME, AUTHORITY_PATH, AUTHORITY_IFACE, "RegisterAuthenticationAgent")
	append_subject(&it, "unix-session", "session-id", session)
	append_string(&it, locale())
	append_string(&it, AGENT_PATH)
	a.serial = bus_send(&a.bus, msg)
	a.state = .Registering
}

// The language polkit translates its messages to.
@(private)
locale :: proc() -> string {
	for name in ([]string{"LC_ALL", "LC_MESSAGES", "LANG"}) {
		if v, found := os.lookup_env(name, context.temp_allocator); found && v != "" { return v }
	}
	return "C"
}

// logind's session object path ends with the escaped id ("_32" is "2").
@(private)
session_id_of_path :: proc(path: string) -> string {
	last := path[strings.last_index_byte(path, '/') + 1:]
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(last); i += 1 {
		if last[i] == '_' && i + 2 < len(last) {
			hex := last[i + 1:i + 3]
			v := 0
			ok := true
			for ch in hex {
				switch ch {
				case '0' ..= '9': v = v * 16 + int(ch - '0')
				case 'a' ..= 'f': v = v * 16 + int(ch - 'a' + 10)
				case: ok = false
				}
			}
			if ok {
				strings.write_byte(&b, u8(v))
				i += 2
				continue
			}
		}
		strings.write_byte(&b, last[i])
	}
	return strings.to_string(b)
}

@(private)
pump :: proc(a: ^Agent) {
	if !bus_read(&a.bus) {
		log.warn("Polkit: the system bus connection was lost; the authentication agent is off")
		shut_down(a)
		return
	}
	for {
		msg := dbus_connection_pop_message(a.bus.conn)
		if msg == nil { break }
		handle_message(a, msg)
		dbus_message_unref(msg)
		if a.bus.conn == nil { return }
	}
	if dbus_connection_has_messages_to_send(a.bus.conn) { dbus_connection_read_write(a.bus.conn, 0) }
}

// The bus is gone or polkit refused us: nothing to serve.
@(private)
shut_down :: proc(a: ^Agent) {
	for r in a.queue { request_free(r) }
	clear(&a.queue)
	helper_stop(&a.helper)
	dialog_close(a)
	bus_close(&a.bus)
	a.state = .Off
}

@(private)
handle_message :: proc(a: ^Agent, msg: ^DBusMessage) {
	switch msg_type(msg) {
	case DBUS_MESSAGE_TYPE_METHOD_RETURN, DBUS_MESSAGE_TYPE_ERROR:
		if dbus_message_get_reply_serial(msg) != a.serial || a.serial == 0 { return }
		a.serial = 0
		failed := msg_type(msg) == DBUS_MESSAGE_TYPE_ERROR
		why := ""
		if failed {
			text, _ := first_string(msg)
			why = fmt.tprintf("%s: %s", string(dbus_message_get_error_name(msg)), text)
		}
		#partial switch a.state {
		case .Finding_Session:
			path, ok := first_string(msg)
			if failed || !ok {
				log.warnf("Polkit: logind does not know milk's session (%s); the authentication agent is off", why)
				shut_down(a)
				return
			}
			register(a, session_id_of_path(path))
		case .Registering:
			if failed {
				log.infof("Polkit: not registered as the authentication agent (%s)", why)
				shut_down(a)
				return
			}
			a.state = .Registered
			log.infof("Polkit: authentication agent of session %s", a.session)
		}
	case DBUS_MESSAGE_TYPE_SIGNAL:
		if msg_interface(msg) == "org.freedesktop.DBus.Local" && msg_member(msg) == "Disconnected" {
			log.warn("Polkit: the system bus went away; the authentication agent is off")
			shut_down(a)
		}
	case DBUS_MESSAGE_TYPE_METHOD_CALL:
		iface, member := msg_interface(msg), msg_member(msg)
		switch {
		case msg_path(msg) != AGENT_PATH:
			reply_error(&a.bus, msg, "org.freedesktop.DBus.Error.UnknownObject", "No such object")
		case iface == "org.freedesktop.DBus.Introspectable" && member == "Introspect":
			reply_string(&a.bus, msg, INTROSPECTION)
		case (iface == AGENT_IFACE || iface == "") && member == "BeginAuthentication":
			begin_authentication(a, msg)
		case (iface == AGENT_IFACE || iface == "") && member == "CancelAuthentication":
			it: DBusMessageIter
			cookie := ""
			if dbus_message_iter_init(msg, &it) { cookie, _ = next_string(&it) }
			if cancel_request(a, cookie, "polkit cancelled it") {
				reply_empty(&a.bus, msg)
			} else {
				reply_error(&a.bus, msg, "org.freedesktop.PolicyKit1.Error.Failed", fmt.tprintf("No pending authentication for cookie %s", cookie))
			}
		case:
			reply_error(&a.bus, msg, "org.freedesktop.DBus.Error.UnknownMethod", fmt.tprintf("Unknown method %s", member))
		}
	}
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------
@(private)
begin_authentication :: proc(a: ^Agent, msg: ^DBusMessage) {
	it: DBusMessageIter
	if !dbus_message_iter_init(msg, &it) {
		reply_error(&a.bus, msg, "org.freedesktop.DBus.Error.InvalidArgs", "No arguments")
		return
	}
	action_id, _ := next_string(&it)
	message, _ := next_string(&it)
	_, _ = next_string(&it) // icon_name
	details := read_string_dict(&it)
	cookie, cookie_ok := next_string(&it)
	if !cookie_ok {
		reply_error(&a.bus, msg, "org.freedesktop.DBus.Error.InvalidArgs", "Expected (sssa{ss}sa(sa{sv}))")
		return
	}
	r := new(Request)
	r.call = dbus_message_ref(msg)
	r.cookie = strings.clone(cookie)
	r.action_id = strings.clone(action_id)
	r.message = strings.clone(message)
	command := details["command_line"]
	if command == "" { command = details["program"] }
	r.command = strings.clone(command)
	read_identities(&it, &r.users)
	if len(r.users) == 0 {
		reply_error(&a.bus, msg, "org.freedesktop.PolicyKit1.Error.Failed", "No user can authenticate")
		request_free(r)
		return
	}
	// This session's user when polkit accepts them, else the first one (root, an admin).
	me := user_name(u32(posix.getuid()))
	for u, i in r.users { if u == me { r.user = i; break } }
	log.infof("Polkit: authentication for %s (%d user(s) may answer)", action_id, len(r.users))
	append(&a.queue, r)
	if len(a.queue) == 1 { show_request(a) }
}

// An a{ss} as a map (temp allocator); the iterator moves past it.
@(private)
read_string_dict :: proc(it: ^DBusMessageIter) -> map[string]string {
	out := make(map[string]string, allocator = context.temp_allocator)
	if dbus_message_iter_get_arg_type(it) != DBUS_TYPE_ARRAY { return out }
	arr: DBusMessageIter
	dbus_message_iter_recurse(it, &arr)
	for dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_DICT_ENTRY {
		entry: DBusMessageIter
		dbus_message_iter_recurse(&arr, &entry)
		key, kok := next_string(&entry)
		value, vok := next_string(&entry)
		if kok && vok { out[key] = value }
		dbus_message_iter_next(&arr)
	}
	dbus_message_iter_next(it)
	return out
}

// The identities a(sa{sv}) as user names: unix-user (uid) and the members of
// unix-group (gid), without repeats.
@(private)
read_identities :: proc(it: ^DBusMessageIter, users: ^[dynamic]string) {
	if dbus_message_iter_get_arg_type(it) != DBUS_TYPE_ARRAY { return }
	add :: proc(users: ^[dynamic]string, name: string) {
		if name == "" { return }
		for u in users { if u == name { return } }
		append(users, strings.clone(name))
	}
	arr: DBusMessageIter
	dbus_message_iter_recurse(it, &arr)
	for dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_STRUCT {
		st, dict: DBusMessageIter
		dbus_message_iter_recurse(&arr, &st)
		kind, _ := next_string(&st)
		if dbus_message_iter_get_arg_type(&st) == DBUS_TYPE_ARRAY {
			dbus_message_iter_recurse(&st, &dict)
			for dbus_message_iter_get_arg_type(&dict) == DBUS_TYPE_DICT_ENTRY {
				entry, variant: DBusMessageIter
				dbus_message_iter_recurse(&dict, &entry)
				key, _ := next_string(&entry)
				if dbus_message_iter_get_arg_type(&entry) == DBUS_TYPE_VARIANT {
					dbus_message_iter_recurse(&entry, &variant)
					if id, ok := iter_int(&variant); ok {
						switch {
						case kind == "unix-user" && key == "uid":
							add(users, user_name(u32(id)))
						case kind == "unix-group" && key == "gid":
							if g := posix.getgrgid(posix.gid_t(id)); g != nil && g.gr_mem != nil {
								for i := 0; g.gr_mem[i] != nil; i += 1 { add(users, string(g.gr_mem[i])) }
							}
						}
					}
				}
				dbus_message_iter_next(&dict)
			}
		}
		dbus_message_iter_next(&arr)
	}
}

@(private)
user_name :: proc(uid: u32) -> string {
	pw := posix.getpwuid(posix.uid_t(uid))
	if pw == nil || pw.pw_name == nil { return "" }
	return strings.clone(string(pw.pw_name), context.temp_allocator)
}

@(private)
request_free :: proc(r: ^Request) {
	if r.call != nil { dbus_message_unref(r.call) }
	delete(r.cookie)
	delete(r.action_id)
	delete(r.message)
	delete(r.command)
	for u in r.users { delete(u) }
	delete(r.users)
	free(r)
}

// Show queue[0] and start its conversation.
@(private)
show_request :: proc(a: ^Agent) {
	if len(a.queue) == 0 {
		dialog_close(a)
		return
	}
	dialog_open(a, a.queue[0])
	start_conversation(a)
}

@(private)
start_conversation :: proc(a: ^Agent) {
	r := a.queue[0]
	dialog_reset_conversation(a)
	if !helper_start(&a.helper, r.users[r.user], r.cookie) {
		dialog_set_error(a, config.tr(a.cfg.bar.language, "Não foi possível falar com o verificador de senhas do polkit.",
		                              "Could not reach polkit's password checker."))
		a.dialog.broken = true
	}
	dialog_draw(a)
}

// The helper wrote something.
@(private)
helper_events :: proc(a: ^Agent) {
	if len(a.queue) == 0 {
		helper_stop(&a.helper)
		return
	}
	for ev in helper_read(&a.helper) {
		switch ev.kind {
		case .Prompt:
			dialog_set_prompt(a, ev.text, ev.echo)
		case .Error:
			dialog_set_error(a, ev.text)
		case .Info:
			dialog_set_info(a, ev.text)
		case .Success:
			log.infof("Polkit: %s authorised", a.queue[0].action_id)
			finish_request(a, true, "")
			return
		case .Failure:
			// Wrong password (or the helper gave up): say so and ask again. PAM's
			// own message is kept when it says more than "Authentication failure"
			// (a locked account, an expired password).
			log.info("Polkit: authentication failed")
			why := strings.clone(a.dialog.error, context.temp_allocator)
			if why == "" || strings.contains(strings.to_lower(why, context.temp_allocator), "authentication failure") {
				why = config.tr(a.cfg.bar.language, "Senha incorreta. Tente de novo.", "Wrong password. Try again.")
			}
			start_conversation(a)
			if !a.dialog.broken {
				dialog_set_error(a, why)
				a.dialog.failures += 1
				dialog_draw(a)
			}
			return
		}
	}
	dialog_draw(a)
}

// The user typed an answer.
@(private)
submit_answer :: proc(a: ^Agent, answer: []u8) -> bool {
	if len(a.queue) == 0 || !helper_running(&a.helper) { return false }
	return helper_answer(&a.helper, string(answer))
}

// The user switched to another identity: a new conversation for it.
@(private)
next_user :: proc(a: ^Agent) {
	if len(a.queue) == 0 { return }
	r := a.queue[0]
	if len(r.users) < 2 { return }
	r.user = (r.user + 1) % len(r.users)
	start_conversation(a)
}

// Answer queue[0] and go on with the next request.
@(private)
finish_request :: proc(a: ^Agent, granted: bool, why: string) {
	if len(a.queue) == 0 { return }
	r := a.queue[0]
	ordered_remove(&a.queue, 0)
	helper_stop(&a.helper)
	if granted {
		reply_empty(&a.bus, r.call)
	} else {
		reply_error(&a.bus, r.call, ERROR_CANCELLED, why)
	}
	request_free(r)
	show_request(a)
}

// Cancel the request with `cookie` (on screen or waiting); false when unknown.
@(private)
cancel_request :: proc(a: ^Agent, cookie, why: string) -> bool {
	for r, i in a.queue {
		if r.cookie != cookie { continue }
		if i == 0 {
			log.infof("Polkit: %s cancelled (%s)", r.action_id, why)
			finish_request(a, false, why)
		} else {
			ordered_remove(&a.queue, i)
			reply_error(&a.bus, r.call, ERROR_CANCELLED, why)
			request_free(r)
		}
		return true
	}
	return false
}
