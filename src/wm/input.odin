// Key and button bindings: dwm's keys[]/buttons[] from config.def.h with the
// configured modifier, the milk additions, the user's wm.bindings, and the
// grabs (with NumLock/CapsLock variants).
package wm

import "core:fmt"
import xlib "vendor:x11/xlib"

@(private)
add_key :: proc(m: ^Manager, mod: xlib.InputMask, sym: xlib.KeySym, func: Action, arg: Arg = {}) {
	append(&m.keys, Key{mod = mod, keysym = sym, func = func, arg = arg})
}

// (Re)build the key and button tables from the settings.
build_bindings :: proc(m: ^Manager) {
	clear(&m.keys)
	clear(&m.buttons)
	for cmd in m.owned_cmds { delete(cmd) }
	clear(&m.owned_cmds)
	s := &m.settings
	MOD := s.modkey
	SHIFT :: xlib.InputMask{.ShiftMask}
	CTRL :: xlib.InputMask{.ControlMask}

	add_key(m, MOD, .XK_p, spawn, {cmd = s.launcher})
	add_key(m, MOD, .XK_Return, spawn, {cmd = s.terminal})
	add_key(m, MOD, .XK_j, focusstack, {i = +1})
	add_key(m, MOD, .XK_k, focusstack, {i = -1})
	add_key(m, MOD, .XK_i, incnmaster, {i = +1})
	add_key(m, MOD, .XK_d, spawn, {cmd = s.launcher})
	add_key(m, MOD + SHIFT, .XK_d, incnmaster, {i = -1})
	add_key(m, MOD, .XK_h, setmfact, {f = -0.05})
	add_key(m, MOD, .XK_l, setmfact, {f = +0.05})
	add_key(m, MOD + SHIFT, .XK_Return, zoom)
	add_key(m, MOD, .XK_Tab, view)
	add_key(m, MOD + SHIFT, .XK_c, killclient)
	add_key(m, MOD, .XK_t, setlayout, {lt = .Tile, has_lt = true})
	add_key(m, MOD, .XK_f, setlayout, {lt = .Float, has_lt = true})
	add_key(m, MOD, .XK_m, setlayout, {lt = .Monocle, has_lt = true})
	add_key(m, MOD, .XK_space, setlayout)
	add_key(m, MOD + SHIFT, .XK_space, togglefloating)
	add_key(m, MOD, .XK_0, view, {ui = max(u32)})
	add_key(m, MOD + SHIFT, .XK_0, tag, {ui = max(u32)})
	add_key(m, MOD, .XK_comma, focusmon, {i = -1})
	add_key(m, MOD, .XK_period, focusmon, {i = +1})
	add_key(m, MOD + SHIFT, .XK_comma, tagmon, {i = -1})
	add_key(m, MOD + SHIFT, .XK_period, tagmon, {i = +1})
	for i in 0 ..< min(s.tag_count, 9) {
		sym := xlib.KeySym(uint(xlib.KeySym.XK_1) + uint(i))
		bit := u32(1) << u32(i)
		add_key(m, MOD, sym, view, {ui = bit})
		add_key(m, MOD + CTRL, sym, toggleview, {ui = bit})
		add_key(m, MOD + SHIFT, sym, tag, {ui = bit})
		add_key(m, MOD + CTRL + SHIFT, sym, toggletag, {ui = bit})
	}
	add_key(m, MOD + SHIFT, .XK_q, quit)
	// milk additions.
	add_key(m, MOD, .XK_q, killclient)
	add_key(m, MOD, .XK_e, spawn, {cmd = s.file_manager})
	add_key(m, MOD, .XK_v, open_panel, {cmd = "clipboard"})
	add_key(m, MOD, .XK_n, open_panel, {cmd = "notifications"})
	add_key(m, MOD + SHIFT, .XK_r, reload_config)
	add_key(m, MOD + SHIFT, .XK_f, togglefullscreen)
	add_key(m, MOD + SHIFT, .XK_s, spawn, {cmd = s.screenshot})
	// Hardware keys (no modifier): XF86AudioMute/LowerVolume/RaiseVolume and
	// XF86MonBrightnessUp/Down, handled by contrib/milk-keys.
	media := [?]struct { sym: uint, arg: string }{
		{0x1008FF12, "mute"}, {0x1008FF11, "volume-down"}, {0x1008FF13, "volume-up"},
		{0x1008FF02, "brightness-up"}, {0x1008FF03, "brightness-down"},
	}
	for k in media {
		cmd := fmt.aprintf("%s %s", s.keys_helper, k.arg)
		append(&m.owned_cmds, cmd)
		add_key(m, {}, xlib.KeySym(k.sym), spawn, {cmd = cmd})
	}

	// wm.bindings: a user binding replaces a default one with the same keys.
	for b in s.bindings {
		for i := len(m.keys) - 1; i >= 0; i -= 1 {
			if m.keys[i].mod == b.mod && m.keys[i].keysym == b.keysym { ordered_remove(&m.keys, i) }
		}
		add_key(m, b.mod, b.keysym, spawn, {cmd = b.command})
	}

	append(&m.buttons, Button{click = .Client_Win, mask = MOD, button = 1, func = movemouse})
	append(&m.buttons, Button{click = .Client_Win, mask = MOD, button = 2, func = togglefloating})
	append(&m.buttons, Button{click = .Client_Win, mask = MOD, button = 3, func = resizemouse})
}

// CLEANMASK: drop NumLock/CapsLock and the button bits.
cleanmask :: proc(m: ^Manager, mask: xlib.InputMask) -> xlib.InputMask {
	return (mask - m.numlockmask - {.LockMask}) &
	       {.ShiftMask, .ControlMask, .Mod1Mask, .Mod2Mask, .Mod3Mask, .Mod4Mask, .Mod5Mask}
}

// Which modifier NumLock is bound to.
updatenumlockmask :: proc(m: ^Manager) {
	m.numlockmask = {}
	modmap := xlib.GetModifierMapping(m.dpy)
	if modmap == nil { return }
	defer xlib.FreeModifiermap(modmap)
	numlock := xlib.KeysymToKeycode(m.dpy, .XK_Num_Lock)
	codes := ([^]xlib.KeyCode)(modmap.modifiermap)
	per := int(modmap.max_keypermod)
	for i in 0 ..< 8 {
		for j in 0 ..< per {
			if numlock != 0 && codes[i * per + j] == numlock {
				m.numlockmask = {xlib.InputMaskBits(i)}
			}
		}
	}
}

// Grab every key of the table on the root window, with the lock variants.
grabkeys :: proc(m: ^Manager) {
	updatenumlockmask(m)
	modifiers := [4]xlib.InputMask{{}, {.LockMask}, m.numlockmask, m.numlockmask + {.LockMask}}
	xlib.UngrabKey(m.dpy, xlib.AnyKey, {.AnyModifier}, m.root)
	start, end: i32
	xlib.DisplayKeycodes(m.dpy, &start, &end)
	skip: i32
	raw := xlib.GetKeyboardMapping(m.dpy, xlib.KeyCode(start), end - start + 1, &skip)
	if raw == nil { return }
	defer xlib.Free(raw)
	syms := ([^]xlib.KeySym)(raw)
	for k in start ..= end {
		// Skip modifier codes: only the first keysym of each keycode is compared.
		first := syms[(k - start) * skip]
		if first == xlib.KeySym(0) { continue }
		for key in m.keys {
			if key.keysym != first { continue }
			for mod in modifiers {
				xlib.GrabKey(m.dpy, k, key.mod + mod, m.root, true, .GrabModeAsync, .GrabModeAsync)
			}
		}
	}
}

// Click-to-focus grab on unfocused clients plus the Mod+button grabs.
grabbuttons :: proc(m: ^Manager, c: ^Client, focused: bool) {
	updatenumlockmask(m)
	modifiers := [4]xlib.InputMask{{}, {.LockMask}, m.numlockmask, m.numlockmask + {.LockMask}}
	xlib.UngrabButton(m.dpy, xlib.AnyButton, {.AnyModifier}, c.win)
	if !focused {
		xlib.GrabButton(m.dpy, xlib.AnyButton, {.AnyModifier}, c.win, false, BUTTONMASK,
		                .GrabModeSync, .GrabModeSync, 0, 0)
	}
	for b in m.buttons {
		if b.click != .Client_Win { continue }
		for mod in modifiers {
			xlib.GrabButton(m.dpy, b.button, b.mask + mod, c.win, false, BUTTONMASK,
			                .GrabModeAsync, .GrabModeSync, 0, 0)
		}
	}
	// milk: picture-in-picture windows resize from their edges without a
	// modifier. The pointer is frozen until buttonpress decides whether the
	// press starts a resize or is replayed to the application.
	if c.ispip {
		for mod in modifiers {
			xlib.GrabButton(m.dpy, 1, mod, c.win, false, BUTTONMASK, .GrabModeSync, .GrabModeAsync, 0, 0)
		}
	}
}
