// Package wm: the built-in window manager of milk, a port of dwm 6.5
// (with the ewmhtags patch) to Odin.
//
// Differences from dwm: there is no bar and no drw (the milk bar is a
// separate override-redirect window; its strip is kept free with
// set_reserved), the configuration comes from config.WM_Options instead of
// config.h, tiled windows may be separated by a uniform gap, monitors come
// from RandR (tx.monitors) instead of Xinerama, new floating windows without
// a requested position are centred, and a larger EWMH surface is published
// (desktops, work area, client lists, _NET_WM_DESKTOP, window types and the
// usual root client messages) for the bar and the desktop layer.
//
// The package owns no event loop: the caller selects ROOT_EVENT_MASK on the
// root window, feeds every X event to handle_event first, calls tick every
// loop iteration and sleeps at most next_timeout seconds.
package wm

import "base:runtime"
import "core:log"
import "core:strings"
import "core:sys/posix"
import xlib "vendor:x11/xlib"
import config "../config"
import menu "../menu"
import tx "../tx"

ROOT_EVENT_MASK :: xlib.EventMask{.SubstructureRedirect, .SubstructureNotify, .ButtonPress, .PointerMotion,
                                  .EnterWindow, .LeaveWindow, .StructureNotify, .PropertyChange}

// dwm settings that milk does not expose (config.def.h values).
SNAP            :: 32   // snap distance of movemouse, in pixels
LOCK_FULLSCREEN :: true // focusstack keeps the focus on a fullscreen client
// Smallest client width/height. dwm uses its bar height (font height + 2).
MIN_SIZE :: 20

BUTTONMASK :: xlib.EventMask{.ButtonPress, .ButtonRelease}
MOUSEMASK  :: xlib.EventMask{.ButtonPress, .ButtonRelease, .PointerMotion}

// Colour schemes (dwm's SchemeNorm/SchemeSel border colours).
Scheme :: enum u8 {
	Norm,
	Sel,
}

Cursor_Kind :: enum u8 {
	Normal,
	Resize,
	Move,
}

// The strip of one monitor kept free for the bar.
Reservation :: struct {
	monitor: string, // "primary" or a RandR output name, owned
	top:     i32,
	bottom:  i32,
}

Manager :: struct {
	c:             ^tx.Connection,
	dpy:           ^xlib.Display,
	root:          xlib.Window,
	allocator:     runtime.Allocator,
	settings:      Settings,
	atoms:         Atoms,
	started:       bool,
	shutting_down: bool,
	quit:          bool, // Mod+Shift+q
	reload:        bool, // Mod+Shift+r
	panel_request: string, // Mod+v / Mod+n / Mod+Shift+l: "clipboard" | "notifications" | "lock" (static strings)
	sw, sh:        i32,  // screen size
	mons:          ^Monitor,
	selmon:        ^Monitor,
	motion_mon:    ^Monitor, // dwm's static `mon` in motionnotify
	numlockmask:   xlib.InputMask,
	keys:          [dynamic]Key,
	buttons:       [dynamic]Button,
	wmcheckwin:    xlib.Window, // _NET_SUPPORTING_WM_CHECK, also the stacking anchor (see restack)
	cursor:        [Cursor_Kind]xlib.Cursor,
	dir_cursor:    [8]xlib.Cursor, // edge/corner resize cursors, by _NET_WM_MOVERESIZE direction
	pixel:         [Scheme]uint,
	children:      [dynamic]posix.pid_t, // spawned commands not reaped yet
	owned_cmds:    [dynamic]string,      // command strings built for key bindings
	reserved:      Reservation,
	ewmh:          Ewmh_Cache,
	cm:            Compositor_Watch, // see compositor.odin
	// Floating mode and the tools shared with the tiling mode.
	decor:           Decor,               // title bar font (frame.odin)
	menu:            menu.Menu,           // the open menu (menus.odin)
	menu_entries:    [dynamic]Menu_Entry, // what the entries of the open menu do
	switcher:        Switcher,            // Alt+Tab (switcher.odin)
	showing_desktop: bool,
	desktop_hidden:  [dynamic]xlib.Window, // minimized by "show desktop"
	desktop_request: string, // a root menu action for the desktop icons (static strings)
	system_requests: [dynamic]string, // milk: night light, volume and brightness actions for the main loop (static strings)
	cascade_x, cascade_y: i32,            // wm.placement "cascade"
	snap_preview:    xlib.Window,         // outline of a snap layout while dragging
	ev_ctx:          Action_Ctx,          // the event that triggers the current binding
	tap_key:         xlib.KeySym,         // Super pressed on its own, waiting for its release (events.odin)
	tap_time:        xlib.Time,
	ev_client:       ^Client,
	last_click_window: xlib.Window,       // double clicks on title bars
	last_click_button: u32,
	last_click_time:   xlib.Time,
	last_click_x, last_click_y: i32,
	// Windows dropped on the bar's area dots (drop.odin; set by main.odin).
	drop_probe:        Drop_Probe,
	drop_data:         rawptr,
}

// The compositor selection as the window manager follows it (compositor.odin).
Compositor_Watch :: struct {
	watching:       bool,
	event_base:     i32,
	selection:      xlib.Atom,
	corners_atom:   xlib.Atom,
	owner:          xlib.Window,
	rounds_corners: bool, // lactase draws the corners: no SHAPE on the windows
}

// Set by the error handler installed while checking for another window manager.
@(private)
g_other_wm: bool

@(private)
xerror_start :: proc "c" (_: ^xlib.Display, ee: ^xlib.XErrorEvent) -> i32 {
	if ee.error_code == u8(xlib.Status.BadAccess) { g_other_wm = true }
	return 0
}

@(private)
xerror_dummy :: proc "c" (_: ^xlib.Display, _: ^xlib.XErrorEvent) -> i32 {
	return 0
}

// dwm's checkotherwm: select SubstructureRedirect on the root window (as part
// of the union with whatever is already selected there, so the other milk
// components keep their events) and see whether the server refuses it.
@(private)
check_other_wm :: proc(c: ^tx.Connection) -> bool {
	g_other_wm = false
	previous := xlib.SetErrorHandler(xerror_start)
	xlib.Sync(c.dpy, false)
	mask := ROOT_EVENT_MASK
	attrs: xlib.XWindowAttributes
	if xlib.GetWindowAttributes(c.dpy, c.root, &attrs) != 0 { mask += attrs.your_event_mask }
	xlib.SelectInput(c.dpy, c.root, mask)
	xlib.Sync(c.dpy, false)
	xlib.SetErrorHandler(previous)
	return !g_other_wm
}

// Become the window manager of the display (no windows are touched yet).
// Returns false, leaving everything untouched, when another window manager runs.
create :: proc(c: ^tx.Connection, cfg: ^config.Config) -> (^Manager, bool) {
	if c == nil || cfg == nil { return nil, false }
	if !check_other_wm(c) {
		log.warn("wm: another window manager is already running")
		return nil, false
	}
	m := new(Manager)
	m.allocator = context.allocator
	m.c = c
	m.dpy = c.dpy
	m.root = c.root
	m.settings = settings_from_config(cfg)
	m.keys = make([dynamic]Key)
	m.buttons = make([dynamic]Button)
	m.children = make([dynamic]posix.pid_t)
	m.menu_entries = make([dynamic]Menu_Entry)
	m.desktop_hidden = make([dynamic]xlib.Window)
	m.reserved.monitor = strings.clone("primary")
	ewmh_init(m)
	return m, true
}

// dwm's cleanup: every client is released without being destroyed (they stay
// mapped, on screen), grabs are dropped, the focus returns to PointerRoot and
// the WM's root properties are removed. Frees everything.
destroy :: proc(m: ^Manager) {
	if m == nil { return }
	context.allocator = m.allocator
	if m.started {
		anim_finish_all(m)
		cleanup(m)
	}
	menu.destroy(&m.menu)
	switcher_destroy(m)
	if m.snap_preview != 0 { xlib.DestroyWindow(m.dpy, m.snap_preview) }
	decor_destroy(m)
	delete(m.menu_entries)
	delete(m.desktop_hidden)
	delete(m.system_requests)
	reap_children(m)
	delete(m.children)
	delete(m.keys)
	delete(m.buttons)
	for cmd in m.owned_cmds { delete(cmd) }
	delete(m.owned_cmds)
	for m.mons != nil { cleanupmon(m, m.mons) }
	ewmh_free(m)
	settings_destroy(&m.settings)
	delete(m.reserved.monitor)
	free(m)
}

// Keep `top`/`bottom` pixels of a monitor ("primary" or a RandR output name)
// free for the bar: they are removed from that monitor's window area, like
// dwm does for its own bar. Call before start and again on reload.
set_reserved :: proc(m: ^Manager, monitor: string, top, bottom: i32) {
	if m == nil { return }
	context.allocator = m.allocator
	name := monitor == "" ? "primary" : monitor
	if name != m.reserved.monitor {
		delete(m.reserved.monitor)
		m.reserved.monitor = strings.clone(name)
	}
	m.reserved.top = max(top, 0)
	m.reserved.bottom = max(bottom, 0)
	if !m.started { return }
	if update_workareas(m) {
		arrange(m, nil)
		if m.selmon != nil { restack(m, m.selmon) }
	}
	ewmh_sync(m)
	xlib.Flush(m.dpy)
}

// dwm's setup (without the bar) followed by scan: monitors, cursors, colours,
// EWMH root properties, key grabs, and adoption of the windows already mapped.
start :: proc(m: ^Manager) {
	if m == nil || m.started { return }
	context.allocator = m.allocator
	screen := tx.screen_rect(m.c)
	m.sw, m.sh = screen.w, screen.h
	updategeom(m)
	// A restarted milk stays on the desktop that was current (the property
	// survives our shutdown); a fresh session starts on the first tag.
	if desk, ok := tx.get_cardinal(m.c, m.root, "_NET_CURRENT_DESKTOP"); ok && int(desk) < m.settings.tag_count {
		m.selmon.tagset[m.selmon.seltags] = u32(1) << u32(desk)
	}
	m.cursor[.Normal] = xlib.CreateFontCursor(m.dpy, .XC_left_ptr)
	m.cursor[.Resize] = xlib.CreateFontCursor(m.dpy, .XC_sizing)
	m.cursor[.Move] = xlib.CreateFontCursor(m.dpy, .XC_fleur)
	create_dir_cursors(m)
	alloc_colours(m)
	decor_setup(m)
	build_bindings(m)
	ewmh_setup(m)

	// Root cursor and event mask (the union with what the caller selected).
	wa: xlib.XSetWindowAttributes
	wa.cursor = m.cursor[.Normal]
	wa.event_mask = ROOT_EVENT_MASK
	attrs: xlib.XWindowAttributes
	if xlib.GetWindowAttributes(m.dpy, m.root, &attrs) != 0 { wa.event_mask += attrs.your_event_mask }
	xlib.ChangeWindowAttributes(m.dpy, m.root, {.CWEventMask, .CWCursor}, &wa)
	grabkeys(m)
	compositor_watch(m)
	m.started = true
	focus(m, nil)
	scan(m)
	ewmh_sync(m)
	xlib.Sync(m.dpy, false)
	mon := m.selmon
	log.infof("wm: started (%d monitor(s), %d tags, work area %dx%d at %d,%d)",
	          count_monitors(m), m.settings.tag_count, mon.ww, mon.wh, mon.wx, mon.wy)
}

// Handle one X event (the caller hands every event to the window manager
// first). Returns true when the event was for the window manager.
handle_event :: proc(m: ^Manager, ev: ^xlib.XEvent) -> bool {
	if m == nil || !m.started || ev == nil { return false }
	context.allocator = m.allocator
	if compositor_event(m, ev) { return true }
	if menu.is_open(&m.menu) && menu.handle_event(&m.menu, ev) {
		if id, ok := menu.take_result(&m.menu); ok { menu_dispatch(m, id) }
		ewmh_sync(m)
		return true
	}
	if ev.type == .ButtonPress { m.tap_key = NO_KEY } // Super with a click (a move, a resize) is no tap
	if (ev.type == .KeyPress || ev.type == .KeyRelease) && switcher_key(m, ev) { return true }
	if ev.type == .ButtonPress && switcher_button(m, &ev.xbutton) { return true }
	if frame_event(m, ev) {
		ewmh_sync(m)
		return true
	}
	consumed := false
	#partial switch ev.type {
	case .ButtonPress:      consumed = buttonpress(m, ev)
	case .ClientMessage:    consumed = clientmessage(m, ev)
	case .ConfigureRequest: consumed = configurerequest(m, ev)
	case .ConfigureNotify:  consumed = configurenotify(m, ev)
	case .DestroyNotify:    consumed = destroynotify(m, ev)
	case .EnterNotify:      consumed = enternotify(m, ev)
	case .FocusIn:          consumed = focusin(m, ev)
	case .KeyPress:         consumed = keypress(m, ev)
	case .KeyRelease:       consumed = keyrelease(m, ev)
	case .MappingNotify:    consumed = mappingnotify(m, ev)
	case .MapRequest:       consumed = maprequest(m, ev)
	case .MotionNotify:     consumed = motionnotify(m, ev)
	case .PropertyNotify:   consumed = propertynotify(m, ev)
	case .UnmapNotify:      consumed = unmapnotify(m, ev)
	case .CirculateRequest: consumed = true // like dwm: ignored
	}
	ewmh_sync(m)
	return consumed
}

// Reap spawned commands that exited (never blocks).
tick :: proc(m: ^Manager, now: f64) {
	if m == nil { return }
	context.allocator = m.allocator
	reap_children(m)
	anim_step(m, now)
}

// The window manager has no timers: children are reaped on the wake-up that
// SIGCHLD causes in the main loop.
next_timeout :: proc(m: ^Manager, now: f64) -> f64 {
	if m != nil && anim_running(m) { return ANIM_FRAME }
	return -1
}

// Apply a new configuration: colours, borders, gaps, master area, tags, keys,
// rules, desktop names and the mode (tiling or floating). The caller owns
// `cfg`; nothing of it is kept.
reload :: proc(m: ^Manager, cfg: ^config.Config) {
	if m == nil || cfg == nil { return }
	context.allocator = m.allocator
	// Menus and the switcher borrow strings from the settings being replaced.
	menu.close(&m.menu)
	clear(&m.menu_entries)
	switcher_finish(m, false)
	old := m.settings
	m.settings = settings_from_config(cfg)
	defer settings_destroy(&old)
	if !m.started { return }
	s := &m.settings
	decor_setup(m)
	if s.floating != old.floating { switch_mode(m) }

	alloc_colours(m)
	mask := tagmask(m)
	for mon := m.mons; mon != nil; mon = mon.next {
		// Runtime changes (Mod+h/l, Mod+i/d) survive unless the setting itself changed.
		if s.mfact != old.mfact { mon.mfact = s.mfact }
		if s.nmaster != old.nmaster { mon.nmaster = s.nmaster }
		for i in 0 ..< 2 {
			mon.tagset[i] &= mask
			if mon.tagset[i] == 0 { mon.tagset[i] = 1 }
		}
		for c := mon.clients; c != nil; c = c.next {
			c.tags &= mask
			if c.tags == 0 { c.tags = mon.tagset[mon.seltags] }
			// PiP windows, docks and desktops stay borderless and on every tag.
			borderless := c.ispip || c.kind == .Dock || c.kind == .Desktop
			if borderless || c.sticky { c.tags = mask }
			if c.frame != 0 {
				// Framed: the border is part of the frame.
				c.title_w = 0
				frame_refresh(m, c)
				grip_update(m, c)
				if c.has_icon { load_icon(m, c) }
				xlib.SetWindowBackground(m.dpy, c.frame, m.pixel[.Norm])
				xlib.ClearWindow(m.dpy, c.frame)
				continue
			}
			if c.isfullscreen {
				if !borderless { c.fsbw = s.border_width }
			} else if !borderless && c.bw != s.border_width {
				c.bw = s.border_width
				wc: xlib.XWindowChanges
				wc.border_width = c.bw
				xlib.ConfigureWindow(m.dpy, c.win, {.CWBorderWidth}, &wc)
			}
			xlib.SetWindowBorder(m.dpy, c.win, m.pixel[.Norm])
		}
	}
	build_bindings(m)
	grabkeys(m)
	for mon := m.mons; mon != nil; mon = mon.next {
		for c := mon.clients; c != nil; c = c.next { grabbuttons(m, c, false) }
	}
	ewmh_write_desktops(m)
	focus(m, nil)
	arrange(m, nil)
	corners_refresh_all(m)
	restack(m, m.selmon)
	ewmh_sync(m)
	xlib.Flush(m.dpy)
	log.info("wm: configuration applied")
}

// Our own windows: the _NET_SUPPORTING_WM_CHECK window.
window_ids :: proc(m: ^Manager, allocator := context.temp_allocator) -> []xlib.Window {
	if m == nil || m.wmcheckwin == 0 { return nil }
	out := make([]xlib.Window, 1, allocator)
	out[0] = m.wmcheckwin
	return out
}

// Mod+Shift+q was pressed.
quit_requested :: proc(m: ^Manager) -> bool {
	return m != nil && m.quit
}

// A root menu action for the desktop icons ("desktop-new-folder",
// "desktop-arrange", "desktop-open-folder"); "" when none. Cleared by the call.
desktop_requested :: proc(m: ^Manager) -> string {
	if m == nil { return "" }
	req := m.desktop_request
	m.desktop_request = ""
	return req
}

// milk: actions the main loop performs, in the order they were asked for
// ("night-light", "volume-up", "volume-down", "mute", "brightness-up",
// "brightness-down"; a held key repeats them). Cleared by the call.
system_requested :: proc(m: ^Manager, allocator := context.temp_allocator) -> []string {
	if m == nil || len(m.system_requests) == 0 { return nil }
	out := make([]string, len(m.system_requests), allocator)
	copy(out, m.system_requests[:])
	clear(&m.system_requests)
	return out
}

// Mod+Shift+r was pressed (the flag is cleared by this call).
// A panel the user asked for with Mod+v (clipboard) or Mod+n (notifications); "" when none.
panel_requested :: proc(m: ^Manager) -> string {
	if m == nil { return "" }
	req := m.panel_request
	m.panel_request = ""
	return req
}

reload_requested :: proc(m: ^Manager) -> bool {
	if m == nil || !m.reload { return false }
	m.reload = false
	return true
}

// ---------------------------------------------------------------------------
// Startup and shutdown helpers
// ---------------------------------------------------------------------------

// Border pixels from the configured colours (dwm's scheme[...][ColBorder]).
@(private)
alloc_colours :: proc(m: ^Manager) {
	m.pixel[.Norm] = alloc_pixel(m, m.settings.border_color, "#444444")
	m.pixel[.Sel] = alloc_pixel(m, m.settings.focus_color, "#005577")
}

@(private)
alloc_pixel :: proc(m: ^Manager, hex: string, fallback: string) -> uint {
	value := hex
	if !valid_hex_colour(value) {
		log.warnf("wm: invalid colour %q, using %s", hex, fallback)
		value = fallback
	}
	col := tx.color_from_hex(value)
	xc := xlib.XColor{red = u16(col.r) * 257, green = u16(col.g) * 257, blue = u16(col.b) * 257}
	if xlib.AllocColor(m.dpy, m.c.colormap, &xc) != xlib.Status(0) { return xc.pixel }
	// TrueColor fallback: compute the pixel directly.
	return uint(col.r) << 16 | uint(col.g) << 8 | uint(col.b)
}

@(private)
valid_hex_colour :: proc(s: string) -> bool {
	text := s
	if len(text) > 0 && text[0] == '#' { text = text[1:] }
	if len(text) != 6 && len(text) != 8 { return false }
	for ch in text {
		switch ch {
		case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
		case: return false
		}
	}
	return true
}

// Adopt the windows that are already mapped (or iconic): first the normal
// ones, then the transients so that their parents are managed already.
@(private)
scan :: proc(m: ^Manager) {
	wins := tx.root_children(m.c)
	for w in wins {
		wa: xlib.XWindowAttributes
		trans: xlib.Window
		if xlib.GetWindowAttributes(m.dpy, w, &wa) == 0 || wa.override_redirect ||
		   xlib.GetTransientForHint(m.dpy, w, &trans) != xlib.Status(0) { continue }
		if w == m.wmcheckwin || is_milk_window(m, w) { continue }
		if wa.map_state == .IsViewable || getstate(m, w) == int(xlib.WMHintState.IconicState) {
			manage(m, w, &wa, true)
		}
	}
	for w in wins {
		wa: xlib.XWindowAttributes
		trans: xlib.Window
		if xlib.GetWindowAttributes(m.dpy, w, &wa) == 0 || wa.override_redirect { continue }
		if is_milk_window(m, w) || wintoclient(m, w) != nil { continue }
		if xlib.GetTransientForHint(m.dpy, w, &trans) != xlib.Status(0) &&
		   (wa.map_state == .IsViewable || getstate(m, w) == int(xlib.WMHintState.IconicState)) {
			manage(m, w, &wa, true)
		}
	}
}

@(private)
cleanup :: proc(m: ^Manager) {
	m.shutting_down = true
	// Show every client before letting go (dwm only does this on the selected
	// monitor with view(~0); clients hidden on other monitors would stay off-screen).
	all := tagmask(m)
	for mon := m.mons; mon != nil; mon = mon.next {
		if mon.tagset[mon.seltags] != all {
			mon.seltags ~= 1
			mon.tagset[mon.seltags] = all
		}
		arrange(m, mon)
	}
	// dwm's "foo" layout: nothing is re-tiled while the clients are released.
	for mon := m.mons; mon != nil; mon = mon.next { mon.lt[mon.sellt] = .Float }
	// Bottom first: a framed window taken out of its frame lands on top, so
	// the stacking order survives for the next window manager.
	for w in tx.root_children(m.c) {
		if c := wintoclient(m, w); c != nil { unmanage(m, c, false) }
	}
	for mon := m.mons; mon != nil; mon = mon.next {
		for mon.stack != nil { unmanage(m, mon.stack, false) }
	}
	xlib.UngrabKey(m.dpy, xlib.AnyKey, {.AnyModifier}, m.root)
	for cur in m.cursor {
		if cur != 0 { xlib.FreeCursor(m.dpy, cur) }
	}
	m.cursor = {}
	for cur in m.dir_cursor {
		if cur != 0 { xlib.FreeCursor(m.dpy, cur) }
	}
	m.dir_cursor = {}
	ewmh_teardown(m)
	xlib.Sync(m.dpy, false)
	xlib.SetInputFocus(m.dpy, xlib.PointerRoot, .RevertToPointerRoot, xlib.CurrentTime)
	xlib.DeleteProperty(m.dpy, m.root, m.atoms.net_active_window)
	// Stop redirecting the root window (another window manager may take over),
	// keeping the events the other components selected.
	attrs: xlib.XWindowAttributes
	if xlib.GetWindowAttributes(m.dpy, m.root, &attrs) != 0 {
		xlib.SelectInput(m.dpy, m.root, attrs.your_event_mask - {.SubstructureRedirect})
	}
	xlib.Sync(m.dpy, false)
	m.started = false
	log.info("wm: stopped, clients released")
}
