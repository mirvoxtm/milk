// Which areas show an icon: the "Show on" submenu of an icon's context menu
// keeps it to some areas (Steam on area 4 only); without a choice an icon is
// on every area. The choice lives in DesktopIcons.json next to the places and
// is keyed the same way (shortcuts of Common/ by name, files by folder and
// name):
//
//   "areas": {"shortcuts": {"Firefox.desktop": [2, 3]},
//             "folders": {"/home/me/Desktop": {"steam.desktop": [4]}}}
//
// The shortcuts of an area's own folder belong to that area already and have
// no choice. With linux.desktopIcons.newIcons = "current-area", a file that
// appears in the desktop folder while milk runs is kept to the area on
// screen. A choice outlives its file for a while on purpose: programs such as
// Steam delete and write their launcher again when they update.
package desktop

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import config "../config"
import menu "../menu"

// Areas 1..31 (wm.tagCount is at most 31).
Area_Set :: bit_set[1 ..= 31; u32]

// Menu ids of the "Show on" submenu: AREA_MENU_BASE = every area, + n = area n.
@(private) AREA_MENU_BASE :: 1000

@(private) ICON_AREAS :: 0xEDBA // layout-grid

// The areas that show `it`, when it was kept to some (otherwise every area).
item_areas :: proc(d: ^Daemon, it: ^Item) -> (Area_Set, bool) {
	table := areas_table(d, it.source, false)
	if table == nil { return {}, false }
	return table[it.name]
}

// Is `it` shown on area `area`?
item_on_area :: proc(d: ^Daemon, it: ^Item, area: int) -> bool {
	set, kept := item_areas(d, it)
	if !kept || area < 1 || area > 31 { return true }
	return area in set
}

// Can the user choose the areas of `it`? Not for the shortcuts of an area's
// own folder (they are that area's).
item_has_area_choice :: proc(d: ^Daemon, it: ^Item) -> bool {
	if it.source == .Folder { return true }
	common := join_path({d.runtime_root, d.cfg.paths.common})
	return filepath.dir(it.path) == common
}

// Keep `it` to `set` (empty: every area).
item_set_areas :: proc(d: ^Daemon, it: ^Item, set: Area_Set) {
	set_areas_by_name(d, it.source, it.name, set)
}

@(private)
set_areas_by_name :: proc(d: ^Daemon, source: Item_Source, name: string, set: Area_Set) {
	table := areas_table(d, source, set != {})
	if table == nil { return }
	if set == {} {
		if key, _, found := areas_take(table, name); found {
			delete(key)
			places_touch(d)
		}
		return
	}
	if old, found := table[name]; found {
		if old == set { return }
		table[name] = set
	} else {
		table[strings.clone(name)] = set
	}
	places_touch(d)
}

// A folder file was renamed (by milk or outside it): its areas go with it.
areas_rename :: proc(d: ^Daemon, old_name, new_name: string) {
	table := areas_table(d, .Folder, false)
	if table == nil { return }
	key, set, found := areas_take(table, old_name)
	if !found { return }
	delete(key)
	if prev, _, had := areas_take(table, new_name); had { delete(prev) }
	table[strings.clone(new_name)] = set
	places_touch(d)
}

// A folder file milk moved to the trash: its choice goes too.
areas_forget :: proc(d: ^Daemon, name: string) {
	table := areas_table(d, .Folder, false)
	if table == nil { return }
	if key, _, found := areas_take(table, name); found {
		delete(key)
		places_touch(d)
	}
}

// Files that appeared in the folder while milk ran (`added`), with
// newIcons = "current-area": keep them to the area on screen, unless they
// already have a choice (a launcher written again by its program).
areas_adopt_new :: proc(d: ^Daemon, added: []string) {
	if d.cfg.linux.desktop_icons.new_icons != "current-area" || d.area < 1 || d.area > 31 { return }
	for name in added {
		table := areas_table(d, .Folder, false)
		if table != nil && name in table { continue }
		set_areas_by_name(d, .Folder, name, {d.area})
	}
}

// How many areas the menu offers: the window manager's, or as many as milk.json describes.
@(private)
area_count :: proc(d: ^Daemon) -> int {
	n := max(d.cfg.wm.tag_count, 1)
	for index, _ in d.cfg.workspaces { n = max(n, index) }
	return min(n, 31)
}

// The "Show on" submenu for the icons the menu is opened for.
@(private)
areas_submenu :: proc(d: ^Daemon, targets: []^Item) -> menu.Item {
	all_free := true // no target is kept to some areas
	common: Area_Set = ~Area_Set{} // the areas every target is kept to
	for it in targets {
		set, kept := item_areas(d, it)
		if kept {
			all_free = false
			common &= set
		}
	}
	if all_free { common = {} }
	items := make([dynamic]menu.Item, context.temp_allocator)
	append(&items, menu.Item{id = AREA_MENU_BASE, label = tr(d, "Todas as áreas", "Every area"), checked = all_free})
	append(&items, menu.Item{separator = true})
	for n in 1 ..= area_count(d) {
		label := fmt.tprintf("%s %d", tr(d, "Área", "Area"), n)
		if ws, known := config.workspace(d.cfg, n); known && ws.name != "" { label = fmt.tprintf("%s · %s", label, ws.name) }
		item := menu.Item{id = AREA_MENU_BASE + n, label = label, checked = !all_free && n in common}
		if n == d.area { item.accel = tr(d, "atual", "current") }
		append(&items, item)
	}
	return menu.Item{label = tr(d, "Mostrar em", "Show on"), icon = ICON_AREAS, items = items[:]}
}

// A "Show on" entry was chosen for `targets`: every area clears the choice;
// an area keeps icons shown everywhere to that one area, otherwise it is
// added or (when every target has it) taken away; no area left means every area.
@(private)
areas_menu_run :: proc(d: ^Daemon, targets: []^Item, id: int) {
	n := id - AREA_MENU_BASE
	if n == 0 {
		for it in targets { item_set_areas(d, it, {}) }
	} else if n >= 1 && n <= 31 {
		all_free, all_have := true, true
		for it in targets {
			set, kept := item_areas(d, it)
			if kept { all_free = false }
			if !kept || n not_in set { all_have = false }
		}
		for it in targets {
			set, kept := item_areas(d, it)
			switch {
			case all_free:   set = {n}
			case all_have:   set -= {n}
			case kept:       set += {n}
			case:            continue // shown everywhere: stays so
			}
			item_set_areas(d, it, set)
		}
	}
	layer_refresh(d, false)
}

// The table for items of `source` (the current folder's for files); nil
// when there is none and `create` is false.
@(private)
areas_table :: proc(d: ^Daemon, source: Item_Source, create: bool) -> ^map[string]Area_Set {
	p := &d.places
	if source == .Area { return &p.area_shortcuts }
	dir := d.files.dir
	if dir == "" { return nil }
	if table, found := &p.area_folders[dir]; found { return table }
	if !create { return nil }
	p.area_folders[strings.clone(dir)] = make(map[string]Area_Set)
	return &p.area_folders[dir]
}

@(private)
areas_take :: proc(table: ^map[string]Area_Set, name: string) -> (key: string, set: Area_Set, found: bool) {
	if _, has := table[name]; !has { return }
	key, set = delete_key(table, name)
	return key, set, true
}
