// milk addition: the window manager's menus (package menu does the drawing
// and the input):
//
// * the root menu (right-click on the desktop): wm.menu when configured —
//   actions, commands, separators and submenus, like openbox's menu.xml —
//   else milk's own, in milk's language;
// * the window menu (title bar right-click, the icon, Alt+Space, the bar's
//   task list through _MILK_WINDOW_MENU);
// * the window list (middle-click on the desktop) and the area list.
//
// Menu entries carry an index into Manager.menu_entries; the entry says what
// to do. Windows are remembered by id, so a window that closed while its menu
// was open is simply ignored.
package wm

import "core:fmt"
import "core:strings"
import xlib "vendor:x11/xlib"
import config "../config"
import menu "../menu"

// What a menu entry does.
Menu_Kind :: enum u8 { Action, Command, Activate, View, Window_Command }

Menu_Entry :: struct {
	kind:  Menu_Kind,
	text:  string, // action or command (borrowed: settings or a literal)
	win:   xlib.Window,
	value: int,
}

// Commands of the window menu.
Win_Command :: enum u8 {
	Minimize, Maximize, Shade, Above, Below, Sticky, Decorations, Fullscreen, Floating, Center,
	Snap_Left, Snap_Right, To_Area, To_Monitor, Close,
}

// Tabler codepoints (the bar's icon font).
@(private) IC_TERMINAL :: 0xEBEF
@(private) IC_FOLDER   :: 0xEAAD
@(private) IC_APPS     :: 0xEBB6
@(private) IC_WINDOW   :: 0xEFE6
@(private) IC_GRID     :: 0xEDBA
@(private) IC_OVERVIEW :: 0xEF95 // Tabler "layout-board"
@(private) IC_PHOTO    :: 0xEB0A
@(private) IC_SETTINGS :: 0xEB20
@(private) IC_REFRESH  :: 0xEB13
@(private) IC_LOGOUT   :: 0xEBA8
@(private) IC_LOCK     :: 0xEAE2 // the lock screen (package lock)
@(private) IC_MINUS    :: 0xEAF2
@(private) IC_MAXIMIZE :: 0xEAEA
@(private) IC_X        :: 0xEB55
@(private) IC_FOLDER_PLUS :: 0xEAAB
@(private) IC_SORT     :: 0xEF18
@(private) IC_DESKTOP  :: 0xEA89
@(private) IC_FULLSCREEN :: 0xEA28
@(private) IC_CENTER   :: 0xF02A

@(private)
tr :: proc(m: ^Manager, pt, en: string) -> string { return config.tr(m.settings.language, pt, en) }

@(private)
menu_reset :: proc(m: ^Manager) {
	clear(&m.menu_entries)
}

@(private)
add_entry :: proc(m: ^Manager, e: Menu_Entry) -> int {
	append(&m.menu_entries, e)
	return len(m.menu_entries) - 1
}

@(private)
open_menu :: proc(m: ^Manager, items: []menu.Item, ctx: Action_Ctx) {
	if len(items) == 0 { return }
	menu.open(&m.menu, m.c, m.settings.menu_style, items, ctx.x, ctx.y, ctx.from_key ? 0 : ctx.time)
}

// The menu answered: run the chosen entry.
menu_dispatch :: proc(m: ^Manager, id: int) {
	if id < 0 || id >= len(m.menu_entries) { return }
	e := m.menu_entries[id]
	ctx := Action_Ctx{time = xlib.CurrentTime}
	if x, y, ok := getrootptr(m); ok { ctx.x, ctx.y = x, y }
	switch e.kind {
	case .Action:
		run_action(m, e.text, m.selmon.sel, ctx)
	case .Command:
		spawn_command(m, e.text)
	case .Activate:
		if c := wintoclient(m, e.win); c != nil { activate_client(m, c) }
	case .View:
		a := Arg{ui = u32(1) << u32(e.value)}
		view(m, &a)
	case .Window_Command:
		if c := wintoclient(m, e.win); c != nil { window_command(m, c, Win_Command(e.value), e.value >> 8) }
	}
}

// Bring a window forward from anywhere: its area, un-minimized, focused, raised.
activate_client :: proc(m: ^Manager, c: ^Client) {
	if !on_current_tags(c) {
		if m.selmon != c.mon {
			unfocus(m, m.selmon.sel, false)
			m.selmon = c.mon
		}
		a := Arg{ui = u32(1) << u32(lowest_tag(c.tags))}
		view(m, &a)
	}
	if c.minimized {
		set_minimized(m, c, false)
		return
	}
	focus(m, c)
	restack(m, c.mon)
}

// ---------------------------------------------------------------------------
// Root menu
// ---------------------------------------------------------------------------
open_root_menu :: proc(m: ^Manager, ctx: Action_Ctx) {
	menu_reset(m)
	items := make([dynamic]menu.Item, context.temp_allocator)
	if m.settings.has_menu {
		items = config_items(m, m.settings.root_menu)
	} else {
		default_root_menu(m, &items)
	}
	open_menu(m, items[:], ctx)
}

@(private)
config_items :: proc(m: ^Manager, entries: []config.Menu_Item) -> [dynamic]menu.Item {
	items := make([dynamic]menu.Item, context.temp_allocator)
	for &e in entries {
		switch {
		case e.separator:
			append(&items, menu.Item{separator = true})
		case len(e.items) > 0:
			sub := config_items(m, e.items)
			append(&items, menu.Item{label = e.label, items = sub[:]})
		case e.command != "":
			append(&items, menu.Item{id = add_entry(m, {kind = .Command, text = e.command}), label = e.label})
		case e.action != "":
			name, _ := config.split_action(e.action)
			switch name {
			case "window-list":
				append(&items, menu.Item{label = e.label, items = window_list_items(m)})
			case "area-list":
				append(&items, menu.Item{label = e.label, items = area_list_items(m)})
			case:
				append(&items, menu.Item{id = add_entry(m, {kind = .Action, text = e.action}), label = e.label, accel = accel_for(m, e.action)})
			}
		}
	}
	return items
}

@(private)
default_root_menu :: proc(m: ^Manager, items: ^[dynamic]menu.Item) {
	action :: proc(m: ^Manager, items: ^[dynamic]menu.Item, label: string, spec: string, icon: rune) {
		append(items, menu.Item{id = add_entry(m, {kind = .Action, text = spec}), label = label, icon = icon, accel = accel_for(m, spec)})
	}
	sep :: proc(items: ^[dynamic]menu.Item) { append(items, menu.Item{separator = true}) }
	action(m, items, tr(m, "Terminal", "Terminal"), "terminal", IC_TERMINAL)
	action(m, items, tr(m, "Arquivos", "Files"), "files", IC_FOLDER)
	action(m, items, tr(m, "Aplicativos…", "Applications…"), "launcher", IC_APPS)
	sep(items)
	append(items, menu.Item{label = tr(m, "Janelas", "Windows"), icon = IC_WINDOW, items = window_list_items(m)})
	append(items, menu.Item{label = tr(m, "Áreas", "Areas"), icon = IC_GRID, items = area_list_items(m)})
	action(m, items, tr(m, "Visão geral", "Overview"), "overview", IC_OVERVIEW)
	if m.settings.desktop_icons {
		sep(items)
		action(m, items, tr(m, "Nova pasta", "New folder"), "desktop-new-folder", IC_FOLDER_PLUS)
		action(m, items, tr(m, "Organizar ícones", "Arrange icons"), "desktop-arrange", IC_SORT)
		action(m, items, tr(m, "Abrir a pasta da área de trabalho", "Open the Desktop folder"), "desktop-open-folder", IC_DESKTOP)
	}
	sep(items)
	action(m, items, tr(m, "Papel de parede…", "Wallpaper…"), "settings wallpapers", IC_PHOTO)
	action(m, items, tr(m, "Configurações", "Settings"), "settings", IC_SETTINGS)
	sep(items)
	action(m, items, tr(m, "Recarregar", "Reload"), "reload", IC_REFRESH)
	action(m, items, tr(m, "Bloquear", "Lock"), "lock", IC_LOCK)
	action(m, items, tr(m, "Sair", "Log out"), "quit", IC_LOGOUT)
}

// ---------------------------------------------------------------------------
// Window list and area list
// ---------------------------------------------------------------------------
open_window_list :: proc(m: ^Manager, ctx: Action_Ctx) {
	menu_reset(m)
	open_menu(m, window_list_items(m), ctx)
}

open_area_list :: proc(m: ^Manager, ctx: Action_Ctx) {
	menu_reset(m)
	open_menu(m, area_list_items(m), ctx)
}

// Every managed window, grouped by area (headers), minimized ones included.
@(private)
window_list_items :: proc(m: ^Manager) -> []menu.Item {
	items := make([dynamic]menu.Item, context.temp_allocator)
	for t in 0 ..< m.settings.tag_count {
		bit := u32(1) << u32(t)
		first := true
		for mon := m.mons; mon != nil; mon = mon.next {
			for c := mon.clients; c != nil; c = c.next {
				if c.kind != .Normal || c.nofocus || lowest_tag(c.tags) != t || c.tags & bit == 0 { continue }
				if first {
					if len(items) > 0 { append(&items, menu.Item{separator = true}) }
					append(&items, menu.Item{header = true, label = area_label(m, t)})
					first = false
				}
				label := c.name
				if c.minimized { label = fmt.tprintf("(%s)", c.name) }
				append(&items, menu.Item{id = add_entry(m, {kind = .Activate, win = c.win}), label = label,
				                         checked = c == m.selmon.sel})
			}
		}
	}
	if len(items) == 0 { append(&items, menu.Item{label = tr(m, "Nenhuma janela", "No windows"), disabled = true}) }
	return items[:]
}

@(private)
area_list_items :: proc(m: ^Manager) -> []menu.Item {
	items := make([dynamic]menu.Item, context.temp_allocator)
	current := m.selmon.tagset[m.selmon.seltags]
	for t in 0 ..< m.settings.tag_count {
		append(&items, menu.Item{id = add_entry(m, {kind = .View, value = t}), label = area_label(m, t),
		                         checked = current & (u32(1) << u32(t)) != 0, accel = accel_for(m, fmt.tprintf("view %d", t + 1))})
	}
	return items[:]
}

@(private)
area_label :: proc(m: ^Manager, t: int) -> string {
	name := t < len(m.settings.desktop_names) ? m.settings.desktop_names[t] : ""
	number := fmt.tprintf("%d", t + 1)
	if name == "" || name == number { return fmt.tprintf(tr(m, "Área %d", "Area %d"), t + 1) }
	return fmt.tprintf("%d · %s", t + 1, name)
}

// ---------------------------------------------------------------------------
// Window menu
// ---------------------------------------------------------------------------
open_window_menu :: proc(m: ^Manager, c: ^Client, ctx: Action_Ctx) {
	menu_reset(m)
	pos := ctx
	if ctx.from_key {
		// From the keyboard: under the title bar's left end.
		pos.x = c.x + c.ext[0]
		pos.y = c.y + max(c.ext[2], 0)
		if !is_visible(c) { pos.x, pos.y = ctx.x, ctx.y }
	}
	cmd :: proc(m: ^Manager, c: ^Client, which: Win_Command, arg := 0) -> int {
		return add_entry(m, {kind = .Window_Command, win = c.win, value = int(which) | arg << 8})
	}
	items := make([dynamic]menu.Item, context.temp_allocator)
	floating := m.settings.floating
	free := is_free(m, c)
	append(&items, menu.Item{id = cmd(m, c, .Minimize), label = tr(m, "Minimizar", "Minimize"), icon = IC_MINUS,
	                         accel = accel_for(m, "minimize"), disabled = c.kind != .Normal})
	if floating || c.isfloating {
		label := c.max_horz && c.max_vert ? tr(m, "Restaurar", "Restore") : tr(m, "Maximizar", "Maximize")
		append(&items, menu.Item{id = cmd(m, c, .Maximize), label = label, icon = IC_MAXIMIZE, accel = accel_for(m, "maximize"), disabled = !free})
	}
	if has_title(c) {
		append(&items, menu.Item{id = cmd(m, c, .Shade), label = tr(m, "Enrolar", "Shade"), checked = c.shaded})
	}
	append(&items, menu.Item{id = cmd(m, c, .Fullscreen), label = tr(m, "Tela cheia", "Fullscreen"), checked = c.isfullscreen,
	                         accel = accel_for(m, "fullscreen")})
	append(&items, menu.Item{separator = true})
	if floating {
		append(&items, menu.Item{id = cmd(m, c, .Above), label = tr(m, "Sempre no topo", "Always on top"), checked = c.layer == .Above})
		append(&items, menu.Item{id = cmd(m, c, .Below), label = tr(m, "Sempre atrás", "Always below"), checked = c.layer == .Below})
	} else {
		append(&items, menu.Item{id = cmd(m, c, .Floating), label = tr(m, "Flutuante", "Floating"), checked = c.isfloating,
		                         disabled = c.isfullscreen || c.ispip})
	}
	append(&items, menu.Item{id = cmd(m, c, .Sticky), label = tr(m, "Em todas as áreas", "On every area"), checked = c.sticky})
	if c.frame != 0 {
		append(&items, menu.Item{id = cmd(m, c, .Decorations), label = tr(m, "Barra de título", "Title bar"), checked = !c.nodecor,
		                         disabled = c.isfullscreen})
	}
	if free {
		snap := make([dynamic]menu.Item, context.temp_allocator)
		append(&snap, menu.Item{id = cmd(m, c, .Snap_Left), label = tr(m, "Metade esquerda", "Left half"), accel = accel_for(m, "snap-left")})
		append(&snap, menu.Item{id = cmd(m, c, .Snap_Right), label = tr(m, "Metade direita", "Right half"), accel = accel_for(m, "snap-right")})
		append(&snap, menu.Item{id = cmd(m, c, .Center), label = tr(m, "Centralizar", "Centre"), icon = IC_CENTER, accel = accel_for(m, "center")})
		append(&items, menu.Item{label = tr(m, "Posição", "Position"), items = snap[:]})
	}
	areas := make([dynamic]menu.Item, context.temp_allocator)
	for t in 0 ..< m.settings.tag_count {
		append(&areas, menu.Item{id = cmd(m, c, .To_Area, t), label = area_label(m, t), checked = !c.sticky && c.tags == u32(1) << u32(t)})
	}
	append(&items, menu.Item{label = tr(m, "Mover para a área", "Move to area"), icon = IC_GRID, items = areas[:], disabled = c.ispip})
	if m.mons != nil && m.mons.next != nil {
		append(&items, menu.Item{id = cmd(m, c, .To_Monitor), label = tr(m, "Mover para o outro monitor", "Move to the other monitor")})
	}
	append(&items, menu.Item{separator = true})
	append(&items, menu.Item{id = cmd(m, c, .Close), label = tr(m, "Fechar", "Close"), icon = IC_X, accel = accel_for(m, "close")})
	open_menu(m, items[:], pos)
}

// Run a window menu command.
@(private)
window_command :: proc(m: ^Manager, c: ^Client, which: Win_Command, arg: int) {
	switch which {
	case .Minimize:    set_minimized(m, c, true)
	case .Maximize:    toggle_maximize(m, c)
	case .Shade:       set_shaded(m, c, !c.shaded)
	case .Above:       set_layer(m, c, c.layer == .Above ? .Normal : .Above)
	case .Below:       set_layer(m, c, c.layer == .Below ? .Normal : .Below)
	case .Sticky:      set_sticky(m, c, !c.sticky)
	case .Decorations: set_decorated(m, c, c.nodecor)
	case .Fullscreen:  setfullscreen(m, c, !c.isfullscreen)
	case .Center:      center_client(m, c)
	case .Snap_Left:   set_snapped(m, c, .Left)
	case .Snap_Right:  set_snapped(m, c, .Right)
	case .Floating:
		if c != m.selmon.sel { focus(m, c) }
		togglefloating(m, nil)
	case .To_Area:
		if arg < 0 || arg >= m.settings.tag_count { return }
		if c.sticky { set_sticky(m, c, false) }
		c.tags = u32(1) << u32(arg)
		focus(m, nil)
		arrange(m, c.mon)
	case .To_Monitor:
		sendmon(m, c, c.mon.next != nil ? c.mon.next : m.mons)
	case .Close:
		kill_client(m, c)
	}
}

// The first key bound to an action, written like "Super+Up" (for menus).
accel_for :: proc(m: ^Manager, action: string) -> string {
	for k in m.keys {
		if k.func != key_action || k.arg.cmd != action { continue }
		b := strings.builder_make(context.temp_allocator)
		mods := [?]struct { mask: xlib.InputMaskBits, name: string }{
			{.Mod4Mask, "Super"}, {.ControlMask, "Ctrl"}, {.Mod1Mask, "Alt"}, {.ShiftMask, "Shift"},
		}
		for mod in mods {
			if mod.mask in k.mod {
				strings.write_string(&b, mod.name)
				strings.write_byte(&b, '+')
			}
		}
		name := string(xlib.KeysymToString(k.keysym))
		if len(name) == 1 { name = strings.to_upper(name, context.temp_allocator) }
		if tap_sym(k.keysym) != NO_KEY && k.mod == {} { name = "Super" }
		strings.write_string(&b, name)
		return strings.to_string(b)
	}
	return ""
}
