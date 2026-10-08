// milk addition: the built-in actions of wm.keys, wm.mouse and wm.menu
// (config.WM_ACTIONS), run by name — openbox's <action name="...">. Most act on
// a target window (the focused one for keys, the clicked one for the mouse);
// menus open at the pointer or next to the window.
package wm

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

// Where and when the action was asked for (menus open there; the window
// switcher watches the modifiers of `state` to know when to stop).
Action_Ctx :: struct {
	x, y:     i32,
	time:     xlib.Time,
	button:   u32,             // the mouse button of a mouse binding (drags follow it), 0 = key
	state:    xlib.InputMask,  // modifiers held (keys)
	from_key: bool,
}

// A key binding that runs an action (Key.arg.cmd = the action).
key_action :: proc(m: ^Manager, arg: ^Arg) {
	ctx := m.ev_ctx
	ctx.from_key = true
	if x, y, ok := getrootptr(m); ok { ctx.x, ctx.y = x, y }
	run_action(m, arg.cmd, m.selmon.sel, ctx)
}

// A mouse binding of the client or root context (Button.arg.cmd = the action).
mouse_action :: proc(m: ^Manager, arg: ^Arg) {
	target := m.ev_client
	run_action(m, arg.cmd, target, m.ev_ctx)
}

// Run one action ("name" or "name argument") on `target` (may be nil).
run_action :: proc(m: ^Manager, spec: string, target: ^Client, ctx: Action_Ctx) {
	name, arg := config.split_action(spec)
	c := target
	switch name {
	case "none":
	case "close":
		if c != nil { kill_client(m, c) }
	case "kill":
		if c != nil { force_kill(m, c) }
	case "minimize":
		if c != nil { set_minimized(m, c, true) }
	case "maximize":
		if c != nil { toggle_maximize(m, c) }
	case "maximize-horizontal":
		if c != nil { set_maximized(m, c, !c.max_horz, c.max_vert) }
	case "maximize-vertical":
		if c != nil { set_maximized(m, c, c.max_horz, !c.max_vert) }
	case "restore":
		// Super+Down: out of maximize/snap first, then minimized.
		if c == nil { break }
		if c.max_horz || c.max_vert || c.snapped != .None { set_maximized(m, c, false, false) } else { set_minimized(m, c, true) }
	case "fullscreen":
		if c != nil { setfullscreen(m, c, !c.isfullscreen) }
	case "shade":
		if c != nil { set_shaded(m, c, true) }
	case "unshade":
		if c != nil { set_shaded(m, c, false) }
	case "above":
		if c != nil { set_layer(m, c, c.layer == .Above ? .Normal : .Above) }
	case "below":
		if c != nil { set_layer(m, c, c.layer == .Below ? .Normal : .Below) }
	case "sticky":
		if c != nil { set_sticky(m, c, !c.sticky) }
	case "decorations":
		if c != nil { set_decorated(m, c, c.nodecor) }
	case "center":
		if c != nil { center_client(m, c) }
	case "raise":
		if c != nil {
			focus(m, c)
			restack(m, c.mon)
		}
	case "lower":
		if c != nil { lower_client(m, c) }
	case "snap-left":         if c != nil { snap_toward(m, c, .Left) }
	case "snap-right":        if c != nil { snap_toward(m, c, .Right) }
	case "snap-top":          if c != nil { snap_toward(m, c, .Top) }
	case "snap-bottom":       if c != nil { snap_toward(m, c, .Bottom) }
	case "snap-top-left":     if c != nil { set_snapped(m, c, .Top_Left) }
	case "snap-top-right":    if c != nil { set_snapped(m, c, .Top_Right) }
	case "snap-bottom-left":  if c != nil { set_snapped(m, c, .Bottom_Left) }
	case "snap-bottom-right": if c != nil { set_snapped(m, c, .Bottom_Right) }
	case "move", "resize":
		if c == nil || ctx.button == 0 { break }
		if !m.settings.floating {
			// dwm's Mod+drag: may turn a tiled window into a floating one.
			if c != m.selmon.sel { focus(m, c) }
			a := Arg{}
			if name == "move" { movemouse(m, &a) } else { resizemouse(m, &a) }
			break
		}
		dir := MR_MOVE
		if name == "resize" { dir = nearest_corner(c, ctx.x, ctx.y) }
		moveresize(m, c, dir, ctx.x, ctx.y, ctx.button)
	case "window-menu":
		if c != nil { open_window_menu(m, c, ctx) }
	case "root-menu":
		open_root_menu(m, ctx)
	case "window-list":
		open_window_list(m, ctx)
	case "area-list":
		open_area_list(m, ctx)
	case "switch-windows":
		switcher_start(m, 1, ctx)
	case "switch-windows-reverse":
		switcher_start(m, -1, ctx)
	case "show-desktop":
		toggle_show_desktop(m)
	case "overview":
		overview_toggle(m)
	case "focus-next", "focus-prev":
		a := Arg{i = name == "focus-next" ? 1 : -1}
		focusstack(m, &a)
	case "toggle-floating":
		if c != nil && c == m.selmon.sel { togglefloating(m, nil) }
	case "view-next", "view-prev":
		view_step(m, name == "view-next" ? 1 : -1, false)
	case "send-next", "send-prev":
		view_step(m, name == "send-next" ? 1 : -1, true)
	case "view-last":
		a := Arg{ui = 0}
		view(m, &a)
	case "view-all":
		a := Arg{ui = max(u32)}
		view(m, &a)
	case "send-all":
		a := Arg{ui = max(u32)}
		if c != nil && c == m.selmon.sel { tag(m, &a) }
	case "view", "send", "toggle-view", "toggle-tag":
		n, _ := strconv.parse_int(arg, 10)
		if n < 1 || n > m.settings.tag_count { break }
		a := Arg{ui = u32(1) << u32(n - 1)}
		switch name {
		case "view":        view(m, &a)
		case "toggle-view": toggleview(m, &a)
		case:
			if c == nil || c != m.selmon.sel { break }
			if name == "toggle-tag" { toggletag(m, &a); break }
			if c.sticky { set_sticky(m, c, false) }
			tag(m, &a)
		}
	case "layout":
		a := Arg{has_lt = true}
		switch arg {
		case "tile":    a.lt = .Tile
		case "float":   a.lt = .Float
		case "monocle": a.lt = .Monocle
		}
		setlayout(m, &a)
	case "layout-last":
		a := Arg{}
		setlayout(m, &a)
	// dwm's tiling keys.
	case "zoom":
		a := Arg{}
		zoom(m, &a)
	case "master-grow", "master-shrink":
		a := Arg{f = name == "master-grow" ? 0.05 : -0.05}
		setmfact(m, &a)
	case "master-more", "master-fewer":
		a := Arg{i = name == "master-more" ? 1 : -1}
		incnmaster(m, &a)
	case "focus-monitor":
		a := Arg{i = arg == "prev" ? -1 : 1}
		focusmon(m, &a)
	case "send-monitor":
		a := Arg{i = arg == "prev" ? -1 : 1}
		tagmon(m, &a)
	case "terminal":   spawn_command(m, m.settings.terminal)
	case "launcher":   spawn_command(m, m.settings.launcher)
	case "files":      spawn_command(m, m.settings.file_manager)
	case "screenshot": spawn_command(m, m.settings.screenshot)
	case "exec":       spawn_command(m, arg)
	case "clipboard":     m.panel_request = "clipboard"
	case "notifications": m.panel_request = "notifications"
	case "lock":          m.panel_request = "lock" // main.odin starts the lock screen (package lock)
	case "desktop-new-folder":  m.desktop_request = "desktop-new-folder"
	case "desktop-arrange":     m.desktop_request = "desktop-arrange"
	case "desktop-open-folder": m.desktop_request = "desktop-open-folder"
	// milk: done by the main loop (night light, the bar's volume and brightness with the pop-up).
	case "night-light":     append(&m.system_requests, "night-light")
	case "volume-up":       append(&m.system_requests, "volume-up")
	case "volume-down":     append(&m.system_requests, "volume-down")
	case "mute":            append(&m.system_requests, "mute")
	case "brightness-up":   append(&m.system_requests, "brightness-up")
	case "brightness-down": append(&m.system_requests, "brightness-down")
	case "suspend":         append(&m.system_requests, "suspend")
	case "reboot":          append(&m.system_requests, "reboot")
	case "poweroff":        append(&m.system_requests, "poweroff")
	case "settings":
		exe, err := os.get_executable_path(context.temp_allocator)
		if err != nil { break }
		cmd := fmt.tprintf("'%s' settings", strings.trim_suffix(exe, " (deleted)"))
		if arg != "" { cmd = fmt.tprintf("%s %s", cmd, arg) }
		spawn_command(m, cmd)
	case "reload": m.reload = true
	case "quit":   m.quit = true
	}
}

// The media keys without the main loop's help (no bar to change the volume
// or the brightness): run contrib/milk-keys as milk used to.
run_keys_helper :: proc(m: ^Manager, action: string) {
	if m == nil { return }
	spawn_command(m, fmt.tprintf("%s %s", m.settings.keys_helper, action))
}

// The resize direction of the corner of `c` nearest to a root point.
nearest_corner :: proc(c: ^Client, x, y: i32) -> int {
	right := x >= c.x + width(c) / 2
	bottom := y >= c.y + height(c) / 2
	switch {
	case right && bottom: return MR_SIZE_BOTTOMRIGHT
	case right:           return MR_SIZE_TOPRIGHT
	case bottom:          return MR_SIZE_BOTTOMLEFT
	}
	return MR_SIZE_TOPLEFT
}

// The next/previous area, wrapping; `send` takes the focused window along.
@(private)
view_step :: proc(m: ^Manager, dir: int, send: bool) {
	n := m.settings.tag_count
	cur := lowest_tag(m.selmon.tagset[m.selmon.seltags])
	next := (cur + dir + n) % n
	a := Arg{ui = u32(1) << u32(next)}
	if send {
		sel := m.selmon.sel
		if sel == nil { return }
		if sel.sticky { set_sticky(m, sel, false) }
		tag(m, &a)
		view(m, &a)
		focus(m, sel)
		restack(m, m.selmon)
		return
	}
	view(m, &a)
}

// Put a window at the bottom of its layer.
lower_client :: proc(m: ^Manager, c: ^Client) {
	xlib.LowerWindow(m.dpy, top_window(c))
	grip_restack(m, c)
	// Keep desktop windows under everything.
	for o := c.mon.clients; o != nil; o = o.next {
		if o.kind == .Desktop { xlib.LowerWindow(m.dpy, o.win) }
	}
	if c == m.selmon.sel {
		// The focus goes to the window now on top.
		c.mon.sel = nil
		unfocus(m, c, false)
		detachstack(c)
		c.snext = nil
		last := &c.mon.stack
		for last^ != nil { last = &last^.snext }
		last^ = c
		focus(m, nil)
	}
	m.ewmh.stacking_dirty = true
}

// Disconnect a client without asking (xkill).
@(private)
force_kill :: proc(m: ^Manager, c: ^Client) {
	xlib.GrabServer(m.dpy)
	previous := xlib.SetErrorHandler(xerror_dummy)
	xlib.SetCloseDownMode(m.dpy, .DestroyAll)
	xlib.KillClient(m.dpy, xlib.XID(c.win))
	xlib.Sync(m.dpy, false)
	xlib.SetErrorHandler(previous)
	xlib.UngrabServer(m.dpy)
}

// milk addition: actions asked for from outside (`milk action NAME`, the
// launcher's milk entries): lines appended to the _MILK_ACTION property of the
// root window, which the window manager reads, deletes and runs. Commands
// ("exec") are not taken this way.
MILK_ACTION :: "_MILK_ACTION"

@(private)
run_requested_actions :: proc(m: ^Manager, time: xlib.Time) {
	atom := tx.atom(m.c, MILK_ACTION)
	type: xlib.Atom
	format: i32
	n, after: uint
	data: rawptr
	if xlib.GetWindowProperty(m.dpy, m.root, atom, 0, 1 << 16, true, xlib.AnyPropertyType, &type, &format, &n, &after, &data) != 0 || data == nil { return }
	defer xlib.Free(data)
	if format != 8 { return }
	text := string(([^]u8)(data)[:n])
	ctx := Action_Ctx{time = time}
	if x, y, ok := getrootptr(m); ok { ctx.x, ctx.y = x, y }
	for line in strings.split_lines_iterator(&text) {
		spec := strings.trim_space(line)
		name, arg := config.split_action(spec)
		if spec == "" || name == "exec" { continue }
		// Plain arguments only ("view 3", "settings bar"): "settings" puts its
		// argument in a command line.
		plain := true
		for ch in arg {
			if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-') { plain = false }
		}
		if !plain || !config.valid_wm_action(spec) {
			log.warnf("wm: unknown action %q asked for through %s", spec, MILK_ACTION)
			continue
		}
		log.debugf("wm: running %q (asked for from outside)", spec)
		run_action(m, spec, m.selmon.sel, ctx)
	}
}
