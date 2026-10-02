// Key and button bindings: dwm's keys[]/buttons[] from config.def.h with the
// configured modifier, the milk additions, the user's wm.bindings, and the
// grabs (with NumLock/CapsLock variants).
package wm

import xlib "vendor:x11/xlib"

@(private)
add_key :: proc(m: ^Manager, mod: xlib.InputMask, sym: xlib.KeySym, func: Action, arg: Arg = {}) {
	append(&m.keys, Key{mod = mod, keysym = sym, func = func, arg = arg})
}

// (Re)build the key and button tables from the settings: the default keys,
// then wm.keys (built-in actions) and wm.bindings (commands), each replacing
// an earlier binding of the same keys; the buttons come from wm.mouse.
build_bindings :: proc(m: ^Manager) {
	clear(&m.keys)
	clear(&m.buttons)
	for cmd in m.owned_cmds { delete(cmd) }
	clear(&m.owned_cmds)
	s := &m.settings
	act :: proc(m: ^Manager, mod: xlib.InputMask, sym: xlib.KeySym, action: string) {
		add_key(m, mod, sym, key_action, {cmd = action})
	}

	// The defaults (config.DEFAULT_KEYS, with the user's wm.defaultKeys): dwm's
	// keys (the layout keys only in the tiling mode), the floating mode's
	// openbox-like keys and milk's own. The hardware keys (XF86AudioMute...,
	// XF86MonBrightnessUp/Down) run the actions of the same name, which the main
	// loop hands to the bar (it shows the volume/brightness pop-up; without a
	// bar it runs contrib/milk-keys).
	for k in s.default_keys { act(m, k.mod, k.keysym, k.action) }

	// wm.keys and wm.bindings: a user binding replaces a default one with the same keys.
	replace :: proc(m: ^Manager, mod: xlib.InputMask, sym: xlib.KeySym) {
		for i := len(m.keys) - 1; i >= 0; i -= 1 {
			if m.keys[i].mod == mod && m.keys[i].keysym == sym { ordered_remove(&m.keys, i) }
		}
	}
	for k in s.key_actions {
		replace(m, k.mod, k.keysym)
		if k.action != "none" { act(m, k.mod, k.keysym, k.action) }
	}
	for b in s.bindings {
		replace(m, b.mod, b.keysym)
		add_key(m, b.mod, b.keysym, spawn, {cmd = b.command})
	}

	// wm.mouse: the client and root contexts (the title bar reads the settings itself).
	for b in s.mouse {
		if b.button == 0 || b.action == "none" { continue }
		click: Click
		switch b.ctx {
		case "client": click = .Client_Win
		case "root":   click = .Root_Win
		case:          continue
		}
		append(&m.buttons, Button{click = click, mask = b.mod, button = b.button, func = mouse_action, arg = {cmd = b.action}})
	}
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
		if tap := tap_sym(first); tap != NO_KEY { first = tap } // "super" on its own: both Super keys
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
