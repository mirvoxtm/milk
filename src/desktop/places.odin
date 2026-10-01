// Saved icon places (linux.desktopIcons): the grid cell of every desktop
// icon, as (column, row) so that a place survives resolution, font and icon
// size changes, kept in <runtime>/DesktopIcons.json:
//
//   {"version": 1,
//    "shortcuts": {"Firefox.desktop": [0, 2]},
//    "folders": {"/home/me/Desktop": {"notes.txt": [1, 0]}},
//    "areas": {...}}
//
// ("areas": the areas each icon is kept to, areas.odin).
//
// Area shortcuts share one table (Common/ and every area folder), files get
// one table per desktop folder. An icon without a place takes the first free
// cell and keeps it from then on, so new files never push the others around;
// a place outside the current grid or taken by another icon is kept on disk
// and used again when it fits. Writes are atomic and batched.
package desktop

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"
import tx "../tx"

PLACES_FILE :: "DesktopIcons.json"
// Batches the writes of a burst of changes (auto placement of new files).
@(private)
PLACES_SAVE_DELAY :: 1.0

// A grid cell: column, row.
Place :: [2]int

Places :: struct {
	path:      string,                        // the JSON file (owned)
	shortcuts: map[string]Place,              // keys owned
	folders:   map[string]map[string]Place,   // folder → name → place, keys owned
	area_shortcuts: map[string]Area_Set,          // areas.odin, keys owned
	area_folders:   map[string]map[string]Area_Set, // folder → name → areas, keys owned
	save_at:   f64,                           // pending write (tx.now() deadline), 0 = none
}

places_init :: proc(d: ^Daemon) {
	p := &d.places
	p.path = strings.clone(join_path({d.runtime_root, PLACES_FILE}))
	p.shortcuts = make(map[string]Place)
	p.folders = make(map[string]map[string]Place)
	p.area_shortcuts = make(map[string]Area_Set)
	p.area_folders = make(map[string]map[string]Area_Set)
	places_load(d)
}

// Read DesktopIcons.json again (milk reload: picks up edits made by hand);
// changes of ours not written yet are written first.
places_reread :: proc(d: ^Daemon) {
	p := &d.places
	if p.save_at > 0 { places_save(d) }
	places_clear_all(p)
	places_load(d)
}

@(private)
places_clear_all :: proc(p: ^Places) {
	places_clear_table(&p.shortcuts)
	for dir, &table in p.folders {
		delete(dir)
		places_clear_table(&table)
		delete(table)
	}
	clear(&p.folders)
	for key in p.area_shortcuts { delete(key) }
	clear(&p.area_shortcuts)
	for dir, &table in p.area_folders {
		delete(dir)
		for key in table { delete(key) }
		delete(table)
	}
	clear(&p.area_folders)
}

places_destroy :: proc(d: ^Daemon) {
	p := &d.places
	if p.save_at > 0 { places_save(d) }
	places_clear_all(p)
	delete(p.shortcuts)
	delete(p.folders)
	delete(p.area_shortcuts)
	delete(p.area_folders)
	delete(p.path)
	p^ = {}
}

// Save when the batching delay is over.
places_tick :: proc(d: ^Daemon, now: f64) {
	if d.places.save_at > 0 && now >= d.places.save_at { places_save(d) }
}

places_next_timeout :: proc(d: ^Daemon, now: f64) -> f64 {
	if d.places.save_at <= 0 { return -1 }
	return max(d.places.save_at - now, 0)
}

// The saved place of an item.
place_of :: proc(d: ^Daemon, it: ^Item) -> (Place, bool) {
	table := places_table(d, it.source, false)
	if table == nil { return {}, false }
	return table[it.name]
}

// Remember where an item is (saved after PLACES_SAVE_DELAY).
place_store :: proc(d: ^Daemon, it: ^Item, p: Place) {
	table := places_table(d, it.source, true)
	if old, found := table[it.name]; found {
		if old == p { return }
		table[it.name] = p
	} else {
		table[strings.clone(it.name)] = p
	}
	places_touch(d)
}

// A folder file was renamed by milk: its place goes with it.
place_rename :: proc(d: ^Daemon, old_name, new_name: string) {
	table := places_table(d, .Folder, false)
	if table == nil { return }
	key, p, found := places_take(table, old_name)
	if !found { return }
	delete(key)
	if prev, _, had := places_take(table, new_name); had { delete(prev) }
	table[strings.clone(new_name)] = p
	places_touch(d)
}

// Forget the places of the items shown (desktop-arrange): they fill the grid
// in order again.
places_forget_shown :: proc(d: ^Daemon) {
	for &it in d.layer.items {
		table := places_table(d, it.source, false)
		if table == nil { continue }
		if key, _, found := places_take(table, it.name); found {
			delete(key)
			places_touch(d)
		}
	}
}

// Drop the places of files that are no longer in `dir` (`names` is the whole
// listing). Shortcut copies of folder mode come and go with the area, so the
// names milk manages keep their places.
places_prune_folder :: proc(d: ^Daemon, dir: string, names: []string) {
	table, found := &d.places.folders[dir]
	if !found { return }
	present := make(map[string]bool, len(names), context.temp_allocator)
	for n in names { present[n] = true }
	if d.cfg.linux.shortcuts.mode == "folder" {
		for n in managed_names(d.runtime_root, d.cfg) { present[n] = true }
	}
	stale := make([dynamic]string, context.temp_allocator)
	for name in table { if name not_in present { append(&stale, name) } }
	for name in stale {
		key, _, _ := places_take(table, name)
		delete(key)
	}
	if len(stale) > 0 { places_touch(d) }
}

// Drop the places of shortcuts that exist in no area any more.
places_prune_shortcuts :: proc(d: ^Daemon) {
	table := &d.places.shortcuts
	if len(table) == 0 { return }
	present := make(map[string]bool, 64, context.temp_allocator)
	for n in managed_names(d.runtime_root, d.cfg) { present[n] = true }
	stale := make([dynamic]string, context.temp_allocator)
	for name in table { if name not_in present { append(&stale, name) } }
	for name in stale {
		key, _, _ := places_take(table, name)
		delete(key)
	}
	if len(stale) > 0 { places_touch(d) }
}

@(private)
places_touch :: proc(d: ^Daemon) {
	if d.places.save_at == 0 { d.places.save_at = tx.now() + PLACES_SAVE_DELAY }
}

// The table for items of `source` (the current folder's for files); nil
// when there is none and `create` is false.
@(private)
places_table :: proc(d: ^Daemon, source: Item_Source, create: bool) -> ^map[string]Place {
	p := &d.places
	if source == .Area { return &p.shortcuts }
	dir := d.files.dir
	if dir == "" { return nil }
	if table, found := &p.folders[dir]; found { return table }
	if !create { return nil }
	p.folders[strings.clone(dir)] = make(map[string]Place)
	return &p.folders[dir]
}

// Remove `name` from a table, returning the owned key for the caller to free.
@(private)
places_take :: proc(table: ^map[string]Place, name: string) -> (key: string, p: Place, found: bool) {
	if _, has := table[name]; !has { return }
	key, p = delete_key(table, name)
	return key, p, true
}

@(private)
places_clear_table :: proc(table: ^map[string]Place) {
	for key in table { delete(key) }
	clear(table)
}

// ---------------------------------------------------------------------------
// File
// ---------------------------------------------------------------------------
@(private)
places_load :: proc(d: ^Daemon) {
	p := &d.places
	data, err := os.read_entire_file(p.path, context.temp_allocator)
	if err != nil { return } // no places yet
	root, perr := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	obj, is_obj := root.(json.Object)
	if perr != nil || !is_obj {
		log.warnf("%s is not valid JSON; the icon places start afresh", p.path)
		return
	}
	read_table :: proc(value: json.Value, out: ^map[string]Place) {
		table, ok := value.(json.Object)
		if !ok { return }
		for name, v in table {
			arr, is_arr := v.(json.Array)
			if !is_arr || len(arr) != 2 || name == "" || name in out { continue }
			col, ok1 := arr[0].(json.Integer)
			row, ok2 := arr[1].(json.Integer)
			if !ok1 || !ok2 || col < 0 || row < 0 || col > 10_000 || row > 10_000 { continue }
			out[strings.clone(name)] = {int(col), int(row)}
		}
	}
	read_table(obj["shortcuts"], &p.shortcuts)
	if folders, ok := obj["folders"].(json.Object); ok {
		for dir, value in folders {
			if dir == "" || dir in p.folders { continue }
			table := make(map[string]Place)
			read_table(value, &table)
			p.folders[strings.clone(dir)] = table
		}
	}
	read_areas :: proc(value: json.Value, out: ^map[string]Area_Set) {
		table, ok := value.(json.Object)
		if !ok { return }
		for name, v in table {
			arr, is_arr := v.(json.Array)
			if !is_arr || name == "" || name in out { continue }
			set: Area_Set
			for a in arr {
				if n, is_int := a.(json.Integer); is_int && n >= 1 && n <= 31 { set += {int(n)} }
			}
			if set != {} { out[strings.clone(name)] = set }
		}
	}
	if areas, ok := obj["areas"].(json.Object); ok {
		read_areas(areas["shortcuts"], &p.area_shortcuts)
		if folders, has := areas["folders"].(json.Object); has {
			for dir, value in folders {
				if dir == "" || dir in p.area_folders { continue }
				table := make(map[string]Area_Set)
				read_areas(value, &table)
				p.area_folders[strings.clone(dir)] = table
			}
		}
	}
}

@(private)
places_save :: proc(d: ^Daemon) {
	p := &d.places
	p.save_at = 0
	Areas :: struct {
		shortcuts: map[string][]int,
		folders:   map[string]map[string][]int,
	}
	File :: struct {
		version:   int,
		shortcuts: map[string]Place,
		folders:   map[string]map[string]Place,
		areas:     Areas,
	}
	as_list :: proc(set: Area_Set) -> []int {
		out := make([dynamic]int, context.temp_allocator)
		for n in set { append(&out, n) }
		return out[:]
	}
	areas := Areas{shortcuts = make(map[string][]int, allocator = context.temp_allocator),
	               folders = make(map[string]map[string][]int, allocator = context.temp_allocator)}
	for name, set in p.area_shortcuts { areas.shortcuts[name] = as_list(set) }
	for dir, table in p.area_folders {
		if len(table) == 0 { continue }
		t := make(map[string][]int, allocator = context.temp_allocator)
		for name, set in table { t[name] = as_list(set) }
		areas.folders[dir] = t
	}
	doc := File{version = 1, shortcuts = p.shortcuts, folders = p.folders, areas = areas}
	data, merr := json.marshal(doc, {pretty = true, use_spaces = true, spaces = 2, sort_maps_by_key = true}, context.temp_allocator)
	if merr != nil {
		log.warnf("Could not encode the icon places: %v", merr)
		return
	}
	temporary := strings.concatenate({p.path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(temporary, data); err != nil {
		log.warnf("Could not write %s: %s", temporary, os.error_string(err))
		os.remove(temporary)
		return
	}
	if err := os.rename(temporary, p.path); err != nil {
		log.warnf("Could not replace %s: %s", p.path, os.error_string(err))
		os.remove(temporary)
	}
}
