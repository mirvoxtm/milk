// StatusNotifierItem: the watcher, the host and the items.
//
// Watcher: milk asks for org.kde.StatusNotifierWatcher without queueing. When
// it gets the name it serves /StatusNotifierWatcher (RegisterStatusNotifierItem,
// RegisterStatusNotifierHost, the RegisteredStatusNotifierItems,
// IsStatusNotifierHostRegistered and ProtocolVersion properties and the
// Registered/Unregistered signals) and is its own host. When another program
// already owns the name, milk registers org.kde.StatusNotifierHost-<pid> with
// it and follows its item list and signals instead; if that watcher leaves,
// milk asks for the name again (the applications register anew with it).
//
// Items: registered as a bus name (path /StatusNotifierItem) or as an object
// path (the sender is the service); listed as "service/path" like KDE's
// watcher. Their properties come from one GetAll, again after any New*
// signal (one call in flight per item); an item that does not answer its
// first GetAll in time, or whose process leaves the bus (NameOwnerChanged),
// is dropped.
package tray

import "core:log"
import "core:strings"
import tx "../tx"

@(private) WATCHER_NAME  :: "org.kde.StatusNotifierWatcher"
@(private) WATCHER_PATH  :: "/StatusNotifierWatcher"
@(private) WATCHER_IFACE :: "org.kde.StatusNotifierWatcher"
@(private) ITEM_IFACE    :: "org.kde.StatusNotifierItem"
@(private) ITEM_PATH     :: "/StatusNotifierItem"

@(private)
WATCHER_XML :: `<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.kde.StatusNotifierWatcher">
    <method name="RegisterStatusNotifierItem"><arg direction="in" name="service" type="s"/></method>
    <method name="RegisterStatusNotifierHost"><arg direction="in" name="service" type="s"/></method>
    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <property name="ProtocolVersion" type="i" access="read"/>
    <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
    <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
    <signal name="StatusNotifierHostRegistered"/>
    <signal name="StatusNotifierHostUnregistered"/>
  </interface>
  <interface name="org.freedesktop.DBus.Properties">
    <method name="Get"><arg direction="in" type="s"/><arg direction="in" type="s"/><arg direction="out" type="v"/></method>
    <method name="GetAll"><arg direction="in" type="s"/><arg direction="out" type="a{sv}"/></method>
  </interface>
  <interface name="org.freedesktop.DBus.Introspectable">
    <method name="Introspect"><arg direction="out" name="xml_data" type="s"/></method>
  </interface>
  <interface name="org.freedesktop.DBus.Peer">
    <method name="Ping"/>
  </interface>
</node>
`

// ---------------------------------------------------------------------------
// The watcher name
// ---------------------------------------------------------------------------
@(private)
request_watcher_name :: proc(t: ^Tray) {
	msg := new_call(DBUS_NAME, DBUS_PATH, DBUS_NAME, "RequestName")
	if msg == nil { return }
	it: DBusMessageIter
	dbus_message_iter_init_append(msg, &it)
	append_string(&it, WATCHER_NAME)
	append_u32(&it, DBUS_NAME_FLAG_DO_NOT_QUEUE)
	if send_call(t, msg, Call.Request_Name) { t.bus.mode = .Waiting }
}

// Our host name: nobody needs the answer.
@(private)
request_name_ignored :: proc(t: ^Tray, name: string) {
	msg := new_call(DBUS_NAME, DBUS_PATH, DBUS_NAME, "RequestName")
	if msg == nil { return }
	it: DBusMessageIter
	dbus_message_iter_init_append(msg, &it)
	append_string(&it, name)
	append_u32(&it, DBUS_NAME_FLAG_DO_NOT_QUEUE)
	send_call(t, msg, Call.Ignore)
}

@(private)
become_watcher :: proc(t: ^Tray) {
	if t.bus.mode == .Watcher { return }
	t.bus.mode = .Watcher
	delete(t.bus.watcher)
	t.bus.watcher = ""
	log.infof("Tray: serving %s on the session bus", WATCHER_NAME)
	// Items waiting for a host (Qt, Electron) register now.
	emit_watcher_signal(t, "StatusNotifierHostRegistered", "")
	bus_write(t)
}

// Another program serves the watcher: register with it as a host and read its items.
@(private)
become_host :: proc(t: ^Tray) {
	t.bus.mode = .Host
	msg := new_call(DBUS_NAME, DBUS_PATH, DBUS_NAME, "GetNameOwner")
	if msg == nil { return }
	it: DBusMessageIter
	dbus_message_iter_init_append(msg, &it)
	append_string(&it, WATCHER_NAME)
	send_call(t, msg, Call.Watcher_Owner)
}

@(private)
host_register :: proc(t: ^Tray) {
	if msg := new_call(WATCHER_NAME, WATCHER_PATH, WATCHER_IFACE, "RegisterStatusNotifierHost"); msg != nil {
		it: DBusMessageIter
		dbus_message_iter_init_append(msg, &it)
		append_string(&it, t.bus.host_name)
		send_call(t, msg, Call.Ignore)
	}
	if msg := new_call(WATCHER_NAME, WATCHER_PATH, PROPS_IFACE, "Get"); msg != nil {
		it: DBusMessageIter
		dbus_message_iter_init_append(msg, &it)
		append_string(&it, WATCHER_IFACE)
		append_string(&it, "RegisteredStatusNotifierItems")
		send_call(t, msg, Call.Watcher_Items)
	}
}

@(private)
emit_watcher_signal :: proc(t: ^Tray, name: cstring, arg: string, with_arg := false) {
	if t.bus.conn == nil || t.bus.mode != .Watcher { return }
	sig := dbus_message_new_signal(WATCHER_PATH, WATCHER_IFACE, name)
	if sig == nil { return }
	if with_arg {
		it: DBusMessageIter
		dbus_message_iter_init_append(sig, &it)
		append_string(&it, arg)
	}
	send_message(t, sig)
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------
@(private)
bus_handle :: proc(t: ^Tray, msg: ^DBusMessage) {
	switch dbus_message_get_type(msg) {
	case DBUS_MESSAGE_TYPE_METHOD_RETURN, DBUS_MESSAGE_TYPE_ERROR:
		if p, ok := take_pending(t, dbus_message_get_reply_serial(msg)); ok { bus_reply(t, p, msg) }
	case DBUS_MESSAGE_TYPE_SIGNAL:
		bus_signal(t, msg)
	case DBUS_MESSAGE_TYPE_METHOD_CALL:
		bus_method(t, msg)
	}
}

@(private)
is_error :: proc(msg: ^DBusMessage) -> bool {
	return msg == nil || dbus_message_get_type(msg) == DBUS_MESSAGE_TYPE_ERROR
}

@(private)
error_text :: proc(msg: ^DBusMessage) -> string {
	if msg == nil { return "no answer" }
	name := string(dbus_message_get_error_name(msg))
	if text, ok := first_string(msg); ok && text != "" { return strings.concatenate({name, ": ", text}, context.temp_allocator) }
	return name
}

// A reply (or nil: the call timed out).
@(private)
bus_reply :: proc(t: ^Tray, p: Pending, msg: ^DBusMessage) {
	switch p.call {
	case .Request_Name:
		code: i64 = -1
		if !is_error(msg) {
			it: DBusMessageIter
			if dbus_message_iter_init(msg, &it) { code, _ = iter_int(&it) }
		}
		if code == i64(DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) || code == i64(DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER) {
			become_watcher(t)
		} else {
			if t.bus.mode != .Host { log.infof("Tray: %s is served by another program; milk shows its items as a host", WATCHER_NAME) }
			become_host(t)
		}
	case .Watcher_Owner:
		if is_error(msg) {
			// Gone in the meantime: try to serve it ourselves.
			request_watcher_name(t)
			return
		}
		owner, _ := first_string(msg)
		delete(t.bus.watcher)
		t.bus.watcher = strings.clone(owner)
		host_register(t)
	case .Watcher_Items:
		if is_error(msg) {
			log.warnf("Tray: cannot read the watcher's items (%s)", error_text(msg))
			return
		}
		it, v: DBusMessageIter
		if !dbus_message_iter_init(msg, &it) || dbus_message_iter_get_arg_type(&it) != DBUS_TYPE_VARIANT { return }
		dbus_message_iter_recurse(&it, &v)
		if dbus_message_iter_get_arg_type(&v) != DBUS_TYPE_ARRAY { return }
		arr: DBusMessageIter
		dbus_message_iter_recurse(&v, &arr)
		for dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_STRING {
			s, _ := iter_string(&arr)
			add_listed_item(t, s)
			dbus_message_iter_next(&arr)
		}
	case .Item_Owner:
		it := find_item(t, p.item)
		if it == nil { return }
		if is_error(msg) {
			log.debugf("Tray: %s has no owner; dropping it", it.key)
			remove_item(t, it)
			return
		}
		owner, _ := first_string(msg)
		delete(it.owner)
		it.owner = strings.clone(owner)
	case .Item_Props:
		it := find_item(t, p.item)
		if it == nil { return }
		it.fetching = false
		if is_error(msg) {
			if !it.ready {
				log.infof("Tray: %s did not answer (%s); dropping it", it.key, error_text(msg))
				remove_item(t, it)
				return
			}
			log.debugf("Tray: cannot refresh %s (%s)", it.key, error_text(msg))
		} else {
			read_properties(t, it, msg)
		}
		if it.refetch {
			it.refetch = false
			request_properties(t, it)
		}
	case .Activate:
		// Items without Activate (or that refuse it) show their menu instead.
		if msg != nil && dbus_message_get_type(msg) == DBUS_MESSAGE_TYPE_ERROR {
			if it := find_item(t, p.item); it != nil {
				log.debugf("Tray: %s refused Activate (%s)", it.key, error_text(msg))
				if t.activate_req.item == it.id { open_item_menu(t, it, t.activate_req) }
			}
		}
	case .Menu_Layout:
		menu_layout_reply(t, p, msg)
	case .Ignore:
		if msg != nil && dbus_message_get_type(msg) == DBUS_MESSAGE_TYPE_ERROR {
			log.debugf("Tray: a call failed (%s)", error_text(msg))
		}
	}
}

@(private)
bus_signal :: proc(t: ^Tray, msg: ^DBusMessage) {
	iface := string(dbus_message_get_interface(msg))
	member := string(dbus_message_get_member(msg))
	sender := string(dbus_message_get_sender(msg))
	switch iface {
	case "org.freedesktop.DBus.Local":
		if member == "Disconnected" { bus_lost(t) }
	case DBUS_NAME:
		if sender != DBUS_NAME || member != "NameOwnerChanged" { return }
		it: DBusMessageIter
		if !dbus_message_iter_init(msg, &it) { return }
		name, _ := iter_string(&it)
		dbus_message_iter_next(&it)
		old_owner, _ := iter_string(&it)
		dbus_message_iter_next(&it)
		new_owner, _ := iter_string(&it)
		name_owner_changed(t, name, old_owner, new_owner)
	case ITEM_IFACE:
		path := string(dbus_message_get_path(msg))
		item := item_for_signal(t, sender, path)
		if item == nil { return }
		switch member {
		case "NewStatus":
			if s, ok := first_string(msg); ok { set_status(t, item, parse_status(s)) }
		case "NewIcon", "NewAttentionIcon", "NewTitle", "NewToolTip", "NewOverlayIcon", "NewIconThemePath", "NewMenu":
			request_properties(t, item)
		}
	case WATCHER_IFACE:
		// The other watcher (host mode) announcing its items.
		if t.bus.mode != .Host || sender != t.bus.watcher { return }
		s, ok := first_string(msg)
		if !ok { return }
		switch member {
		case "StatusNotifierItemRegistered":
			add_listed_item(t, s)
		case "StatusNotifierItemUnregistered":
			service, path := split_item(s)
			for item in t.items {
				if item.kind == .SNI && item.service == service && item.path == path {
					remove_item(t, item)
					break
				}
			}
		}
	}
}

@(private)
name_owner_changed :: proc(t: ^Tray, name, old_owner, new_owner: string) {
	if name == WATCHER_NAME {
		switch t.bus.mode {
		case .Host:
			if new_owner == "" {
				// The other watcher left: serve it ourselves.
				request_watcher_name(t)
			} else if new_owner != t.bus.watcher {
				delete(t.bus.watcher)
				t.bus.watcher = strings.clone(new_owner)
				host_register(t)
			}
		case .Watcher:
			if new_owner != "" && new_owner != t.bus.unique {
				// Replaced (only with our consent, which milk never gives; be safe).
				become_host(t)
			}
		case .Off, .Waiting:
		}
		return
	}
	if new_owner != "" { return }
	// A process left the bus (or released a name): its items go with it.
	for i := len(t.items) - 1; i >= 0; i -= 1 {
		item := t.items[i]
		if item.kind == .SNI && (item.service == name || item.owner == name) { remove_item(t, item) }
	}
}

// Calls to /StatusNotifierWatcher.
@(private)
bus_method :: proc(t: ^Tray, msg: ^DBusMessage) {
	iface := string(dbus_message_get_interface(msg))
	member := string(dbus_message_get_member(msg))
	path := string(dbus_message_get_path(msg))
	if iface == "org.freedesktop.DBus.Peer" && member == "Ping" {
		send_message(t, dbus_message_new_method_return(msg))
		return
	}
	if iface == "org.freedesktop.DBus.Introspectable" || (iface == "" && member == "Introspect") {
		reply := dbus_message_new_method_return(msg)
		it: DBusMessageIter
		dbus_message_iter_init_append(reply, &it)
		xml: cstring = WATCHER_XML
		if path != WATCHER_PATH { xml = path == "/" ? `<node><node name="StatusNotifierWatcher"/></node>` : "<node/>" }
		dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &xml)
		send_message(t, reply)
		return
	}
	if t.bus.mode != .Watcher || path != WATCHER_PATH {
		send_error(t, msg, "org.freedesktop.DBus.Error.UnknownObject", "No such object")
		return
	}
	switch {
	case (iface == WATCHER_IFACE || iface == "") && member == "RegisterStatusNotifierItem":
		arg, ok := first_string(msg)
		if !ok {
			send_error(t, msg, "org.freedesktop.DBus.Error.InvalidArgs", "RegisterStatusNotifierItem expects (s)")
			return
		}
		sender := string(dbus_message_get_sender(msg))
		service, item_path := arg, ITEM_PATH
		if strings.has_prefix(arg, "/") {
			service, item_path = sender, arg
		} else if slash := strings.index_byte(arg, '/'); slash > 0 {
			service, item_path = arg[:slash], arg[slash:]
		}
		if !valid_bus_name(service) || !valid_object_path(item_path) {
			send_error(t, msg, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid service or object path")
			return
		}
		send_message(t, dbus_message_new_method_return(msg))
		// A unique name is its own owner; a well-known one is asked for its owner.
		add_item(t, service, item_path, service[0] == ':' ? service : "")
	case (iface == WATCHER_IFACE || iface == "") && member == "RegisterStatusNotifierHost":
		send_message(t, dbus_message_new_method_return(msg))
		emit_watcher_signal(t, "StatusNotifierHostRegistered", "")
	case iface == PROPS_IFACE && member == "Get":
		it: DBusMessageIter
		if !dbus_message_iter_init(msg, &it) {
			send_error(t, msg, "org.freedesktop.DBus.Error.InvalidArgs", "Get expects (ss)")
			return
		}
		dbus_message_iter_next(&it)
		name, _ := iter_string(&it)
		value, known := watcher_property(t, name)
		if !known {
			send_error(t, msg, "org.freedesktop.DBus.Error.UnknownProperty", strings.concatenate({"No property ", name}, context.temp_allocator))
			return
		}
		reply := dbus_message_new_method_return(msg)
		rit: DBusMessageIter
		dbus_message_iter_init_append(reply, &rit)
		append_variant(&rit, value)
		send_message(t, reply)
	case iface == PROPS_IFACE && member == "GetAll":
		reply := dbus_message_new_method_return(msg)
		it, arr: DBusMessageIter
		dbus_message_iter_init_append(reply, &it)
		dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "{sv}", &arr)
		iface_arg, _ := first_string(msg)
		if iface_arg == WATCHER_IFACE || iface_arg == "" {
			for name in ([]string{"RegisteredStatusNotifierItems", "IsStatusNotifierHostRegistered", "ProtocolVersion"}) {
				value, _ := watcher_property(t, name)
				entry: DBusMessageIter
				dbus_message_iter_open_container(&arr, DBUS_TYPE_DICT_ENTRY, nil, &entry)
				append_string(&entry, name)
				append_variant(&entry, value)
				dbus_message_iter_close_container(&arr, &entry)
			}
		}
		dbus_message_iter_close_container(&it, &arr)
		send_message(t, reply)
	case iface == PROPS_IFACE && member == "Set":
		send_error(t, msg, "org.freedesktop.DBus.Error.PropertyReadOnly", "The watcher's properties are read-only")
	case:
		send_error(t, msg, "org.freedesktop.DBus.Error.UnknownMethod", strings.concatenate({"Unknown method ", iface, ".", member}, context.temp_allocator))
	}
}

@(private)
watcher_property :: proc(t: ^Tray, name: string) -> (Variant, bool) {
	switch name {
	case "RegisteredStatusNotifierItems":
		keys := make([dynamic]string, context.temp_allocator)
		for item in t.items {
			if item.kind == .SNI { append(&keys, item.key) }
		}
		return keys[:], true
	case "IsStatusNotifierHostRegistered":
		return true, true
	case "ProtocolVersion":
		return i32(0), true
	}
	return nil, false
}

// ---------------------------------------------------------------------------
// Items
// ---------------------------------------------------------------------------

// "service/path" (or a bare service: the default path).
@(private)
split_item :: proc(s: string) -> (service, path: string) {
	if slash := strings.index_byte(s, '/'); slash > 0 { return s[:slash], s[slash:] }
	return s, ITEM_PATH
}

// An item from the other watcher's list (host mode).
@(private)
add_listed_item :: proc(t: ^Tray, s: string) {
	service, path := split_item(s)
	if !valid_bus_name(service) || !valid_object_path(path) { return }
	add_item(t, service, path, service[0] == ':' ? service : "")
}

@(private)
add_item :: proc(t: ^Tray, service, path, owner: string) {
	key := strings.concatenate({service, path}, context.temp_allocator)
	for item in t.items {
		if item.kind == .SNI && item.key == key {
			// Registered again (an application restarting its icon): read it anew.
			if owner != "" && owner != item.owner {
				delete(item.owner)
				item.owner = strings.clone(owner)
			}
			request_properties(t, item)
			return
		}
	}
	item := new(Item)
	item.kind = .SNI
	item.id = t.next_id
	t.next_id += 1
	item.service = strings.clone(service)
	item.path = strings.clone(path)
	item.owner = strings.clone(owner)
	item.key = strings.clone(key)
	item.status = .Active
	append(&t.items, item)
	log.debugf("Tray: item %s registered", key)
	emit_watcher_signal(t, "StatusNotifierItemRegistered", key, true)
	if owner == "" {
		if msg := new_call(DBUS_NAME, DBUS_PATH, DBUS_NAME, "GetNameOwner"); msg != nil {
			it: DBusMessageIter
			dbus_message_iter_init_append(msg, &it)
			append_string(&it, service)
			send_call(t, msg, Call.Item_Owner, item.id)
		}
	}
	request_properties(t, item)
}

// The item a signal comes from: its process and object path.
@(private)
item_for_signal :: proc(t: ^Tray, sender, path: string) -> ^Item {
	fallback: ^Item
	for item in t.items {
		if item.kind != .SNI || item.path != path { continue }
		if item.owner == sender || item.service == sender { return item }
		if item.owner == "" { fallback = item }
	}
	return fallback
}

@(private)
request_properties :: proc(t: ^Tray, item: ^Item) {
	if item.fetching {
		item.refetch = true
		return
	}
	msg := new_call(item.service, item.path, PROPS_IFACE, "GetAll")
	if msg == nil { return }
	it: DBusMessageIter
	dbus_message_iter_init_append(msg, &it)
	append_string(&it, ITEM_IFACE)
	if send_call(t, msg, Call.Item_Props, item.id) { item.fetching = true }
}

@(private)
parse_status :: proc(s: string) -> Status {
	switch s {
	case "Passive":        return .Passive
	case "NeedsAttention": return .Needs_Attention
	}
	return .Active
}

@(private)
set_status :: proc(t: ^Tray, item: ^Item, status: Status) {
	if item.status == status { return }
	item.status = status
	resolve_picture(t, item)
	t.changed = true
}

// What GetAll answered (only the properties milk uses).
@(private)
Props :: struct {
	t:                 ^Tray,
	id, title:         string,
	status:            string,
	icon_name:         string,
	attention_name:    string,
	theme_path:        string,
	menu:              string,
	item_is_menu:      bool,
	pixmap, attention: Raw_Pixmap,
}

@(private)
read_properties :: proc(t: ^Tray, item: ^Item, msg: ^DBusMessage) {
	it: DBusMessageIter
	if !dbus_message_iter_init(msg, &it) { return }
	p := Props{t = t}
	iter_dict(&it, &p, proc(data: rawptr, key: string, value: ^DBusMessageIter) {
		p := (^Props)(data)
		switch key {
		case "Id":                  p.id, _ = iter_string(value)
		case "Title":               p.title, _ = iter_string(value)
		case "Status":              p.status, _ = iter_string(value)
		case "IconName":            p.icon_name, _ = iter_string(value)
		case "AttentionIconName":   p.attention_name, _ = iter_string(value)
		case "IconThemePath":       p.theme_path, _ = iter_string(value)
		case "Menu":                p.menu, _ = iter_string(value)
		case "ItemIsMenu":
			v, _ := iter_int(value)
			p.item_is_menu = v != 0
		case "IconPixmap":          p.pixmap = best_pixmap(value, p.t.size)
		case "AttentionIconPixmap": p.attention = best_pixmap(value, p.t.size)
		}
	})
	replace :: proc(dst: ^string, s: string) {
		if dst^ == s { return }
		delete(dst^)
		dst^ = strings.clone(s)
	}
	title := p.title != "" ? p.title : p.id
	replace(&item.title, title)
	replace(&item.icon_name, p.icon_name)
	replace(&item.attention_name, p.attention_name)
	replace(&item.theme_path, p.theme_path)
	menu_path := p.menu
	if menu_path == "/" || menu_path == "/NO_DBUSMENU" || !valid_object_path(menu_path) { menu_path = "" }
	replace(&item.menu_path, menu_path)
	item.item_is_menu = p.item_is_menu
	item.status = parse_status(p.status)
	tx.image_destroy(&item.pixmap)
	tx.image_destroy(&item.attention_pixmap)
	item.pixmap = pixmap_image(p.pixmap, t.size)
	item.attention_pixmap = pixmap_image(p.attention, t.size)
	if !item.ready { log.infof("Tray: showing %q (%s)", item.title, item.key) }
	item.ready = true
	resolve_picture(t, item)
	t.changed = true
}

// Every SNI item goes (the bus was lost).
@(private)
drop_sni_items :: proc(t: ^Tray) {
	for i := len(t.items) - 1; i >= 0; i -= 1 {
		if t.items[i].kind == .SNI { remove_item(t, t.items[i]) }
	}
}

// ---------------------------------------------------------------------------
// Calls on items
// ---------------------------------------------------------------------------
@(private)
item_call_xy :: proc(t: ^Tray, item: ^Item, method: string, x, y: i32, call: Maybe(Call)) -> bool {
	msg := new_call(item.service, item.path, ITEM_IFACE, method)
	if msg == nil { return false }
	it: DBusMessageIter
	dbus_message_iter_init_append(msg, &it)
	append_i32(&it, x)
	append_i32(&it, y)
	return send_call(t, msg, call, item.id)
}

@(private)
item_scroll :: proc(t: ^Tray, item: ^Item, delta: i32) {
	msg := new_call(item.service, item.path, ITEM_IFACE, "Scroll")
	if msg == nil { return }
	it: DBusMessageIter
	dbus_message_iter_init_append(msg, &it)
	append_i32(&it, delta)
	append_string(&it, "vertical")
	send_call(t, msg, nil, item.id)
}
