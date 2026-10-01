// milk as the XSETTINGS manager (freedesktop.org XSETTINGS specification),
// for appearance.themeApps (apptheme.odin): GTK 3 and 4 read their theme and
// icon theme from the _XSETTINGS_SETTINGS property of the owner of the
// _XSETTINGS_S<screen> selection and follow its changes live. milk only
// takes the selection when nobody holds it (xsettingsd, gnome-settings-daemon
// and the like stay in charge), publishes only the settings it decides
// (everything else keeps coming from gtk-3.0/settings.ini), and gives the
// selection up (its window is destroyed) when the option is turned off or
// milk stops.
package milk

import "core:fmt"
import "core:log"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "../tx"

XSettings :: struct {
	win:       xlib.Window, // the selection owner window; 0 = not the manager
	selection: xlib.Atom,
	serial:    u32,
	values:    [dynamic]XSetting, // published, in this order
	other:     bool,              // someone else holds the selection (logged once)
}

@(private)
XSetting :: struct {
	name, value: string, // owned
	serial:      u32,     // when it last changed
}

// Become the manager unless another program is; true when milk is it.
xsettings_start :: proc(xs: ^XSettings, c: ^tx.Connection) -> bool {
	if xs.win != 0 { return true }
	xs.selection = tx.atom(c, fmt.tprintf("_XSETTINGS_S%d", c.screen))
	if owner := xlib.GetSelectionOwner(c.dpy, xs.selection); owner != 0 {
		if !xs.other { log.info("Another XSETTINGS manager is running: GTK apps take milk's colours when they start") }
		xs.other = true
		return false
	}
	attrs: xlib.XSetWindowAttributes
	attrs.override_redirect = true
	attrs.event_mask = {.PropertyChange}
	win := xlib.CreateWindow(c.dpy, c.root, -1, -1, 1, 1, 0, 0, .InputOnly, nil, {.CWOverrideRedirect, .CWEventMask}, &attrs)
	if win == 0 { return false }
	// A real timestamp for the selection (ICCCM): the time of a property change.
	prop := tx.atom(c, "_XSETTINGS_SETTINGS")
	xlib.ChangeProperty(c.dpy, win, prop, prop, 8, xlib.PropModeAppend, nil, 0)
	ev: xlib.XEvent
	xlib.WindowEvent(c.dpy, win, {.PropertyChange}, &ev)
	stamp := ev.xproperty.time
	xlib.SetSelectionOwner(c.dpy, xs.selection, win, stamp)
	if xlib.GetSelectionOwner(c.dpy, xs.selection) != win {
		xlib.DestroyWindow(c.dpy, win)
		return false
	}
	xs.win = win
	xs.other = false
	// MANAGER announcement: running clients start reading our settings.
	msg: xlib.XEvent
	msg.xclient.type = .ClientMessage
	msg.xclient.window = c.root
	msg.xclient.message_type = tx.atom(c, "MANAGER")
	msg.xclient.format = 32
	msg.xclient.data.l = {int(stamp), int(xs.selection), int(win), 0, 0}
	xlib.SendEvent(c.dpy, c.root, false, {.StructureNotify}, &msg)
	xsettings_write(xs, c)
	log.info("XSETTINGS: milk is the settings manager (GTK theme and icons follow milk)")
	return true
}

// Stop being the manager: GTK apps fall back to their settings.ini.
xsettings_stop :: proc(xs: ^XSettings, c: ^tx.Connection) {
	if xs.win != 0 {
		xlib.DestroyWindow(c.dpy, xs.win)
		tx.flush(c)
	}
	xs.win = 0
	for v in xs.values {
		delete(v.name)
		delete(v.value)
	}
	delete(xs.values)
	xs.values = nil
}

// Publish exactly `settings` (name, value pairs); unchanged values are not
// written again. Returns true when something changed.
xsettings_set :: proc(xs: ^XSettings, c: ^tx.Connection, settings: [][2]string) -> bool {
	same := len(settings) == len(xs.values)
	if same {
		for s, i in settings {
			if xs.values[i].name != s[0] || xs.values[i].value != s[1] { same = false; break }
		}
	}
	if same { return false }
	xs.serial += 1
	next := make([dynamic]XSetting, 0, len(settings))
	for s in settings {
		changed := xs.serial
		for v in xs.values {
			if v.name == s[0] && v.value == s[1] { changed = v.serial }
		}
		append(&next, XSetting{strings.clone(s[0]), strings.clone(s[1]), changed})
	}
	for v in xs.values {
		delete(v.name)
		delete(v.value)
	}
	delete(xs.values)
	xs.values = next
	if xs.win != 0 { xsettings_write(xs, c) }
	return true
}

// Another manager took the selection over: milk is not the manager any more.
// Returns true when the event was ours.
xsettings_event :: proc(xs: ^XSettings, c: ^tx.Connection, ev: ^xlib.XEvent) -> (lost: bool, ours: bool) {
	if xs.win == 0 || ev.xany.window != xs.win { return false, false }
	if ev.type == .SelectionClear && ev.xselectionclear.selection == xs.selection {
		log.info("XSETTINGS: another settings manager took over")
		xlib.DestroyWindow(c.dpy, xs.win)
		xs.win = 0
		xs.other = true
		return true, true
	}
	return false, true
}

// The _XSETTINGS_SETTINGS property: byte order, serial, count, then each
// setting (string type) padded to 4 bytes.
@(private)
xsettings_write :: proc(xs: ^XSettings, c: ^tx.Connection) {
	b := make([dynamic]u8, context.temp_allocator)
	put32 :: proc(b: ^[dynamic]u8, v: u32) {
		bytes := transmute([4]u8)v // native order, announced in the first byte
		append(b, bytes[0], bytes[1], bytes[2], bytes[3])
	}
	put16 :: proc(b: ^[dynamic]u8, v: u16) {
		bytes := transmute([2]u8)v
		append(b, bytes[0], bytes[1])
	}
	pad :: proc(b: ^[dynamic]u8) {
		for len(b) % 4 != 0 { append(b, 0) }
	}
	append(&b, ODIN_ENDIAN == .Little ? 0 : 1, 0, 0, 0)
	put32(&b, xs.serial)
	put32(&b, u32(len(xs.values)))
	for v in xs.values {
		append(&b, 1, 0) // XSettingsTypeString, unused
		put16(&b, u16(len(v.name)))
		append(&b, ..transmute([]u8)v.name)
		pad(&b)
		put32(&b, v.serial)
		put32(&b, u32(len(v.value)))
		append(&b, ..transmute([]u8)v.value)
		pad(&b)
	}
	prop := tx.atom(c, "_XSETTINGS_SETTINGS")
	xlib.ChangeProperty(c.dpy, xs.win, prop, prop, 8, xlib.PropModeReplace, raw_data(b), i32(len(b)))
	tx.flush(c)
}
