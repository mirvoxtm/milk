package config

// Night light ("nightLight") and the volume/brightness pop-up ("osd"):
//
//     "nightLight": {"enabled": false, "mode": "sunset", "temperature": 4000,
//                    "from": "20:00", "to": "07:00", "latitude": null, "longitude": null,
//                    "transition": 30},
//     "osd": {"enabled": true, "position": "bottom"}
//
// The night light warms the screen through the gamma ramps of every monitor
// (package nightlight): always, from sunset to sunrise at the configured
// place, or between two times of day. Without a place, "sunset" uses the
// from/to times.

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"

NIGHT_LIGHT_MODES :: []string{"always", "sunset", "manual"}
OSD_POSITIONS     :: []string{"bottom", "center", "top"}

NIGHT_LIGHT_MIN_K :: 1000 // kelvin
NIGHT_LIGHT_MAX_K :: 6500 // neutral: the screen as it is

Night_Light_Options :: struct {
	enabled:     bool,
	mode:        string,     // always | sunset | manual
	temperature: int,        // kelvin at night, NIGHT_LIGHT_MIN_K..NIGHT_LIGHT_MAX_K
	from:        int,        // minutes after midnight: the night starts (manual; sunset without a place)
	to:          int,        // minutes after midnight: the day starts
	latitude:    Maybe(f64), // degrees, north positive
	longitude:   Maybe(f64), // degrees, east positive
	transition:  int,        // minutes the screen takes to warm up at dusk and to cool down before dawn
}

// The pop-up shown when the volume or brightness keys are pressed.
OSD_Options :: struct {
	enabled:  bool,
	position: string, // bottom | center | top
}

// Off; when switched on it follows the sun (Noctalia's default), which is
// 20:00 → 07:00 until a place is set.
default_night_light :: proc() -> Night_Light_Options {
	return {enabled = false, mode = "sunset", temperature = 4000, from = 20 * 60, to = 7 * 60, transition = 30}
}

// "HH:MM" (or "H:MM") → minutes after midnight.
parse_clock_time :: proc(s: string) -> (minutes: int, ok: bool) {
	t := strings.trim_space(s)
	colon := strings.index_byte(t, ':')
	if colon < 1 || colon > 2 || len(t) != colon + 3 { return 0, false }
	for ch, i in t {
		if i != colon && (ch < '0' || ch > '9') { return 0, false }
	}
	h, hok := strconv.parse_int(t[:colon], 10)
	m, mok := strconv.parse_int(t[colon + 1:], 10)
	if !hok || !mok || h > 23 || m > 59 { return 0, false }
	return h * 60 + m, true
}

// Minutes after midnight → "HH:MM".
format_clock_time :: proc(minutes: int, allocator := context.temp_allocator) -> string {
	m := ((minutes % 1440) + 1440) % 1440
	return fmt.aprintf("%02d:%02d", m / 60, m % 60, allocator = allocator)
}

@(private)
get_clock :: proc(l: ^Loader, obj: json.Object, key, scope: string, default_value: int) -> (int, bool) {
	v, present := obj[key]
	if !present { return default_value, true }
	s, is_str := v.(string)
	if is_str {
		if m, ok := parse_clock_time(s); ok { return m, true }
	}
	return 0, fail(l, "%s.%s must be a time of day written as \"HH:MM\" (e.g. \"20:00\").", scope, key)
}

// A number between -limit and limit, or null (not set).
@(private)
get_coordinate :: proc(l: ^Loader, obj: json.Object, key, scope: string, limit: f64) -> (value: Maybe(f64), ok: bool) {
	v, present := obj[key]
	if !present { return nil, true }
	if _, is_null := v.(json.Null); is_null { return nil, true }
	n := get_number(l, obj, key, scope, 0, -limit, limit) or_return
	return n, true
}

// Called by parse_root after the other sections.
@(private)
parse_night_light_osd :: proc(l: ^Loader, root: json.Object, cfg: ^Config) -> bool {
	d := default_night_light()
	scope :: "nightLight"
	nl := get_object(l, root, "nightLight", "milk.json") or_return
	reject_unknown(l, nl, {"enabled", "mode", "temperature", "from", "to", "latitude", "longitude", "transition"}, scope) or_return
	out := &cfg.night_light
	out.enabled = get_bool(l, nl, "enabled", scope, d.enabled) or_return
	out.mode = get_choice(l, nl, "mode", scope, d.mode, NIGHT_LIGHT_MODES) or_return
	t := get_number(l, nl, "temperature", scope, f64(d.temperature), NIGHT_LIGHT_MIN_K, NIGHT_LIGHT_MAX_K) or_return
	out.temperature = int(t)
	out.from = get_clock(l, nl, "from", scope, d.from) or_return
	out.to = get_clock(l, nl, "to", scope, d.to) or_return
	out.latitude = get_coordinate(l, nl, "latitude", scope, 90) or_return
	out.longitude = get_coordinate(l, nl, "longitude", scope, 180) or_return
	tr := get_number(l, nl, "transition", scope, f64(d.transition), 0, 180) or_return
	out.transition = int(tr)

	osd := get_object(l, root, "osd", "milk.json") or_return
	reject_unknown(l, osd, {"enabled", "position"}, "osd") or_return
	cfg.osd.enabled = get_bool(l, osd, "enabled", "osd", true) or_return
	cfg.osd.position = get_choice(l, osd, "position", "osd", "bottom", OSD_POSITIONS) or_return
	return true
}

@(private)
destroy_night_light_osd :: proc(cfg: ^Config) {
	delete(cfg.night_light.mode)
	delete(cfg.osd.position)
}

// Set one value in milk.json (creating the objects on the way), keeping every
// other key; written atomically, keys sorted, like the settings app does.
// Returns false (and logs why) when the file cannot be read, parsed or written.
write_value :: proc(path: string, keys: []string, value: json.Value) -> bool {
	if path == "" || len(keys) == 0 { return false }
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		log.errorf("Cannot read %s: %v", path, rerr)
		return false
	}
	root_value, perr := json.parse(data, .JSON5, true, context.temp_allocator)
	root, is_obj := root_value.(json.Object)
	if perr != .None || !is_obj {
		log.errorf("Cannot parse %s (%v); not changing it", path, perr)
		return false
	}
	set :: proc(obj: ^json.Object, keys: []string, value: json.Value) {
		if len(keys) == 1 {
			obj^[keys[0]] = value
			return
		}
		child, is_child := obj^[keys[0]].(json.Object)
		if !is_child { child = make(json.Object, context.temp_allocator) }
		set(&child, keys[1:], value)
		obj^[keys[0]] = child // maps may move when they grow
	}
	set(&root, keys, value)
	out, merr := json.marshal(root, {spec = .JSON, pretty = true, use_spaces = true, spaces = 2, sort_maps_by_key = true}, context.temp_allocator)
	if merr != nil {
		log.errorf("Cannot encode the configuration: %v", merr)
		return false
	}
	tmp := fmt.tprintf("%s.tmp", path)
	text := strings.concatenate({tidy_json_numbers(string(out)), "\n"}, context.temp_allocator)
	if werr := os.write_entire_file(tmp, text); werr != nil {
		log.errorf("Cannot write %s: %v", tmp, werr)
		return false
	}
	if err := os.rename(tmp, path); err != nil {
		log.errorf("Cannot replace %s: %v", path, err)
		return false
	}
	return true
}
