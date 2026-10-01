// The items' menus (com.canonical.dbusmenu), shown with milk's popup menus.
//
// A right click (or a left click on an ItemIsMenu item) sends AboutToShow(0)
// and GetLayout(0, -1, []) and opens the menu when the layout arrives; the
// chosen entry goes back as Event(id, "clicked"). Qt fills submenus lazily:
// submenus that arrive empty get AboutToShow and the layout is fetched once
// more before the menu opens. Labels lose their mnemonic underscores; check
// and radio entries show milk's check mark; hidden entries are left out and
// disabled ones greyed; icons are not shown. Items without a menu get
// ContextMenu(x, y) and draw their own.
package tray

import "core:log"
import "core:strings"
import xlib "vendor:x11/xlib"
import menu "../menu"

@(private) MENU_IFACE     :: "com.canonical.dbusmenu"
@(private) MENU_MAX_DEPTH :: 8

// Where and for which item a menu was asked for.
Menu_Request :: struct {
	item:         int, // Item.id (-1 = none)
	id:           int, // request number: replies to older requests are ignored
	x, y:         i32, // the menu's corner (screen coordinates)
	px, py:       i32, // the pointer (ContextMenu, Activate)
	time:         xlib.Time,
	retried:      bool, // empty submenus were asked to fill in once
}

// Ask for an item's menu (or let the item show its own).
@(private)
open_item_menu :: proc(t: ^Tray, item: ^Item, req: Menu_Request) {
	if item.menu_path == "" {
		item_call_xy(t, item, "ContextMenu", req.px, req.py, nil)
		return
	}
	t.next_request += 1
	t.menu_req = req
	t.menu_req.item = item.id
	t.menu_req.id = t.next_request
	t.menu_req.retried = false
	about_to_show(t, item, 0)
	get_layout(t, item)
}

@(private)
about_to_show :: proc(t: ^Tray, item: ^Item, id: i32) {
	msg := new_call(item.service, item.menu_path, MENU_IFACE, "AboutToShow")
	if msg == nil { return }
	it: DBusMessageIter
	dbus_message_iter_init_append(msg, &it)
	append_i32(&it, id)
	send_call(t, msg, Call.Ignore, item.id)
}

@(private)
get_layout :: proc(t: ^Tray, item: ^Item) {
	msg := new_call(item.service, item.menu_path, MENU_IFACE, "GetLayout")
	if msg == nil { return }
	it, arr: DBusMessageIter
	dbus_message_iter_init_append(msg, &it)
	append_i32(&it, 0)  // the root
	append_i32(&it, -1) // every level
	dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "s", &arr) // every property
	dbus_message_iter_close_container(&it, &arr)
	send_call(t, msg, Call.Menu_Layout, item.id, t.menu_req.id)
}

@(private)
menu_layout_reply :: proc(t: ^Tray, p: Pending, msg: ^DBusMessage) {
	if p.request != t.menu_req.id { return } // a newer click asked for another menu
	item := find_item(t, p.item)
	if item == nil { return }
	req := t.menu_req
	if is_error(msg) {
		log.debugf("Tray: no menu from %s (%s)", item.key, error_text(msg))
		item_call_xy(t, item, "ContextMenu", req.px, req.py, nil)
		return
	}
	it: DBusMessageIter
	if !dbus_message_iter_init(msg, &it) { return }
	dbus_message_iter_next(&it) // the revision
	lazy := make([dynamic]i32, context.temp_allocator)
	root, _, ok := parse_node(&it, 0, &lazy)
	if !ok {
		log.debugf("Tray: %s sent a malformed menu", item.key)
		return
	}
	if len(lazy) > 0 && !req.retried {
		t.menu_req.retried = true
		for id in lazy { about_to_show(t, item, id) }
		get_layout(t, item)
		return
	}
	if len(root.items) == 0 { return }
	if menu.open(&t.menu, t.c, menu.style_from_config(t.cfg), root.items, req.x, req.y, req.time) {
		t.menu_item = item.id
		t.menu_time = req.time
	}
}

// One layout node, (ia{sv}av), as a menu entry (temp allocator); `visible`
// is false for entries the application hides.
@(private)
parse_node :: proc(it: ^DBusMessageIter, depth: int, lazy: ^[dynamic]i32) -> (entry: menu.Item, visible: bool, ok: bool) {
	if dbus_message_iter_get_arg_type(it) != DBUS_TYPE_STRUCT { return }
	s: DBusMessageIter
	dbus_message_iter_recurse(it, &s)
	id := iter_int(&s) or_return
	dbus_message_iter_next(&s)
	Node_Props :: struct {
		label, kind, toggle, display: string,
		enabled, visible:             bool,
		state:                        i64,
	}
	np := Node_Props{enabled = true, visible = true}
	iter_dict(&s, &np, proc(data: rawptr, key: string, value: ^DBusMessageIter) {
		np := (^Node_Props)(data)
		switch key {
		case "label":            np.label, _ = iter_string(value)
		case "type":             np.kind, _ = iter_string(value)
		case "toggle-type":      np.toggle, _ = iter_string(value)
		case "children-display": np.display, _ = iter_string(value)
		case "toggle-state":     np.state, _ = iter_int(value)
		case "enabled":
			v, vok := iter_int(value)
			if vok { np.enabled = v != 0 }
		case "visible":
			v, vok := iter_int(value)
			if vok { np.visible = v != 0 }
		}
	})
	dbus_message_iter_next(&s)
	children := make([dynamic]menu.Item, context.temp_allocator)
	if depth < MENU_MAX_DEPTH && dbus_message_iter_get_arg_type(&s) == DBUS_TYPE_ARRAY {
		arr: DBusMessageIter
		dbus_message_iter_recurse(&s, &arr)
		for dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_VARIANT {
			v: DBusMessageIter
			dbus_message_iter_recurse(&arr, &v)
			if child, child_visible, child_ok := parse_node(&v, depth + 1, lazy); child_ok && child_visible {
				append(&children, child)
			}
			dbus_message_iter_next(&arr)
		}
	}
	entry.id = int(id)
	entry.label = strip_mnemonics(np.label)
	entry.separator = np.kind == "separator"
	entry.disabled = !np.enabled
	entry.checked = np.toggle != "" && np.state == 1
	tidy := tidy_separators(children[:])
	if len(tidy) > 0 {
		entry.items = tidy
	} else if np.display == "submenu" && depth > 0 {
		// Filled on AboutToShow (Qt); greyed out if it stays empty.
		append(lazy, i32(id))
		entry.disabled = true
	}
	return entry, np.visible, true
}

// No separators at either end or two in a row.
@(private)
tidy_separators :: proc(items: []menu.Item) -> []menu.Item {
	out := make([dynamic]menu.Item, context.temp_allocator)
	for it in items {
		if it.separator && (len(out) == 0 || out[len(out) - 1].separator) { continue }
		append(&out, it)
	}
	for len(out) > 0 && out[len(out) - 1].separator { pop(&out) }
	return out[:]
}

// "_Open" → "Open", "__" → "_" (GTK/dbusmenu mnemonics).
@(private)
strip_mnemonics :: proc(label: string) -> string {
	if strings.index_byte(label, '_') < 0 { return label }
	out := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(label); i += 1 {
		if label[i] == '_' {
			if i + 1 < len(label) && label[i + 1] == '_' {
				strings.write_byte(&out, '_')
				i += 1
			}
			continue
		}
		strings.write_byte(&out, label[i])
	}
	return strings.to_string(out)
}

// The menu answered: tell the application which entry was chosen.
@(private)
menu_chosen :: proc(t: ^Tray, id: int) {
	item := find_item(t, t.menu_item)
	if item == nil || item.menu_path == "" { return }
	msg := new_call(item.service, item.menu_path, MENU_IFACE, "Event")
	if msg == nil { return }
	it: DBusMessageIter
	dbus_message_iter_init_append(msg, &it)
	append_i32(&it, i32(id))
	append_string(&it, "clicked")
	append_variant(&it, i32(0))
	append_u32(&it, u32(t.menu_time))
	send_call(t, msg, Call.Ignore, item.id)
	bus_write(t)
}
