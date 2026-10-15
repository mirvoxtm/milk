package display

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

// How long the monitors must stay quiet before milk looks at them: plugging
// a monitor in sends a burst of events, and so does applying a layout.
@(private) SETTLE :: 0.4

// The running milk's side: when the set of monitors changes it applies that
// set's profile (displays.profiles), else extends the screen to the monitor
// plugged in (displays.autoApply); and whenever the monitors change without
// the screen changing size it sends the root window a ConfigureNotify, the
// event everything (window manager, bar, desktop, lactase) re-reads the
// monitors on — X sends one only for a new screen size.
Manager :: struct {
	c:          ^tx.Connection,
	cfg:        ^config.Config,
	event_base: i32,
	ok:         bool,   // RandR 1.2 is there
	check_at:   f64,    // 0 = nothing to look at
	key:        string, // the set of monitors last seen (owned)
	signature:  string, // what they showed (owned): outputs, positions, modes, primary
	screen_w, screen_h: i32,
}

// Start watching the monitors; with autoApply, the profile of the monitors
// connected now is applied (before the window manager reads them).
manager_create :: proc(c: ^tx.Connection, cfg: ^config.Config) -> ^Manager {
	m := new(Manager)
	m.c, m.cfg = c, cfg
	error_base: i32
	if !XRRQueryExtension(c.dpy, &m.event_base, &error_base) { return m }
	s := read_state(c)
	if s == nil { return m }
	defer destroy_state(s)
	m.ok = true
	// Night light selects the same three on the shared connection (the last call wins).
	XRRSelectInput(c.dpy, c.root, RR_SCREEN_CHANGE_NOTIFY_MASK | RR_CRTC_CHANGE_NOTIFY_MASK | RR_OUTPUT_CHANGE_NOTIFY_MASK)
	m.key = setup_key(s)
	log.infof("Display: %s", describe(s))
	if cfg.displays.auto_apply {
		if profile, found := cfg.displays.profiles[m.key]; found && layout_fits(s, profile) && !same_layout(s, profile) {
			if ok, why := apply(c, s, profile); !ok { log.warnf("Display: the saved layout could not be applied: %s", why) }
		}
	}
	m.check_at = tx.now() + SETTLE // the signature after any change above
	return m
}

manager_destroy :: proc(m: ^Manager) {
	if m == nil { return }
	delete(m.key)
	delete(m.signature)
	free(m)
}

manager_reload :: proc(m: ^Manager, cfg: ^config.Config) {
	if m == nil { return }
	m.cfg = cfg
}

// RandR events: look at the monitors once they settle. Never consumes the
// event (night light wants it too).
manager_event :: proc(m: ^Manager, ev: ^xlib.XEvent) -> bool {
	if m == nil || !m.ok { return false }
	t := i32(ev.type)
	if t != m.event_base + RR_SCREEN_CHANGE_NOTIFY && t != m.event_base + RR_NOTIFY { return false }
	XRRUpdateConfiguration(ev)
	m.check_at = tx.now() + SETTLE
	return false
}

manager_tick :: proc(m: ^Manager, now: f64) {
	if m == nil || !m.ok || m.check_at == 0 || now < m.check_at { return }
	m.check_at = 0
	s := read_state(m.c)
	if s == nil { return }
	defer destroy_state(s)
	key := setup_key(s, context.temp_allocator)
	if key != m.key {
		delete(m.key)
		m.key = strings.clone(key)
		log.infof("Display: monitors changed: %s", describe(s))
		if m.cfg.displays.auto_apply && hotplug_apply(m, s, key) { return } // its own events bring us back
	}
	sig := signature(s, context.temp_allocator)
	if sig == m.signature { return }
	same_size := m.signature != "" && s.screen_w == m.screen_w && s.screen_h == m.screen_h
	delete(m.signature)
	m.signature = strings.clone(sig)
	m.screen_w, m.screen_h = s.screen_w, s.screen_h
	if same_size { announce(m, s) }
}

manager_timeout :: proc(m: ^Manager, now: f64) -> f64 {
	if m == nil || m.check_at == 0 { return -1 }
	return max(m.check_at - now, 0)
}

// The set of monitors changed: its profile, else the automatic layout.
@(private="file")
hotplug_apply :: proc(m: ^Manager, s: ^State, key: string) -> bool {
	layout: []config.Display_Output
	if profile, found := m.cfg.displays.profiles[key]; found && layout_fits(s, profile) {
		layout = profile
		log.info("Display: applying the layout saved for these monitors")
	} else {
		layout = auto_layout(s, context.temp_allocator)
	}
	if same_layout(s, layout) { return false }
	ok, why := apply(m.c, s, layout)
	if !ok {
		log.warnf("Display: %s", why)
		return false
	}
	return true
}

// A ConfigureNotify for the root window at its current size: the window
// manager, the bar, the desktop and lactase re-read the monitors on it.
@(private="file")
announce :: proc(m: ^Manager, s: ^State) {
	ev: xlib.XEvent
	ev.xconfigure = {
		type = .ConfigureNotify, display = m.c.dpy, event = m.c.root, window = m.c.root,
		width = s.screen_w, height = s.screen_h,
	}
	xlib.SendEvent(m.c.dpy, m.c.root, false, {.StructureNotify}, &ev)
	xlib.Flush(m.c.dpy)
	log.debug("Display: the monitors changed within the same screen size; told everyone")
}

// What the monitors show, as text: equal texts, equal layouts.
@(private="file")
signature :: proc(s: ^State, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "%dx%d", s.screen_w, s.screen_h)
	for o in s.outputs {
		if o.crtc == 0 { continue }
		fmt.sbprintf(&b, ";%s %dx%d+%d+%d@%d r%d%s", o.name, o.w, o.h, o.x, o.y, int(math.round(o.rate * 10)), int(o.rotation), o.primary ? " p" : "")
	}
	return strings.to_string(b)
}

// "eDP-1 (BOE 0x0747) 1920x1080+0+0, HDMI-1 (DELL U2415) off" for the log.
describe :: proc(s: ^State) -> string {
	b := strings.builder_make(context.temp_allocator)
	for o in s.outputs {
		if !o.connected { continue }
		if strings.builder_len(b) > 0 { strings.write_string(&b, ", ") }
		fmt.sbprintf(&b, "%s (%s)", o.name, o.label)
		if o.crtc == 0 {
			strings.write_string(&b, " off")
		} else {
			fmt.sbprintf(&b, " %dx%d+%d+%d", o.w, o.h, o.x, o.y)
		}
	}
	if strings.builder_len(b) == 0 { return "no monitor connected" }
	return strings.to_string(b)
}

// For a program of its own (the settings app): ask for the monitor events on
// the root window; RandR's first event number, ok = false without RandR.
watch :: proc(c: ^tx.Connection) -> (event_base: i32, ok: bool) {
	error_base: i32
	if !XRRQueryExtension(c.dpy, &event_base, &error_base) { return 0, false }
	XRRSelectInput(c.dpy, c.root, RR_SCREEN_CHANGE_NOTIFY_MASK | RR_CRTC_CHANGE_NOTIFY_MASK | RR_OUTPUT_CHANGE_NOTIFY_MASK)
	return event_base, true
}

// Whether `ev` is a monitor event (see watch); Xlib's idea of the screen is updated.
is_event :: proc(event_base: i32, ev: ^xlib.XEvent) -> bool {
	t := i32(ev.type)
	if t != event_base + RR_SCREEN_CHANGE_NOTIFY && t != event_base + RR_NOTIFY { return false }
	XRRUpdateConfiguration(ev)
	return true
}
