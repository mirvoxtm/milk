package config

// Monitors ("displays"):
//
//     "displays": {"scale": 1, "autoApply": true,
//                  "profiles": {"BOE-0747+DEL-A0F3-3132": [
//                      {"monitor": "BOE-0747", "output": "eDP-1", "mode": "1920x1080", "rate": 60,
//                       "x": 0, "y": 0, "primary": true},
//                      {"monitor": "DEL-A0F3-3132", "output": "HDMI-1", "mode": "2560x1440", "rate": 75,
//                       "x": 1920, "y": 0, "rotation": "normal"}]}}
//
// scale is the applications' UI scale (Xft.dpi = 96 × scale and the XSETTINGS
// DPI; milk's own bar and panels keep their sizes). A profile is the layout
// of one set of monitors: its key names the monitors connected (package
// display: the EDID's maker, product and serial, else the output's name),
// and milk applies it when that set appears (autoApply: at start and when a
// monitor is plugged in or out). A set without a profile is extended to the
// right when a monitor is plugged in.

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

DISPLAY_ROTATIONS :: []string{"normal", "left", "inverted", "right"}
DISPLAY_SCALE_MIN :: 1.0
DISPLAY_SCALE_MAX :: 3.0

Display_Output :: struct {
	monitor:  string, // the monitor's identity (package display)
	output:   string, // the output it was on when saved ("HDMI-1"): a fallback when the identity is not found
	enabled:  bool,
	w, h:     i32,    // the mode, before rotation
	rate:     f64,    // refresh rate in Hz, 0 = the best for that size
	x, y:     i32,
	rotation: string, // DISPLAY_ROTATIONS
	primary:  bool,
}

Display_Options :: struct {
	scale:      f64,
	auto_apply: bool,
	profiles:   map[string][]Display_Output, // setup key → one entry per monitor
}

default_displays :: proc() -> Display_Options {
	return {scale = 1, auto_apply = true}
}

// "1920x1080" → 1920, 1080.
parse_mode_size :: proc(s: string) -> (w, h: i32, ok: bool) {
	x := strings.index_any(s, "xX")
	if x <= 0 { return }
	wv, wok := strconv.parse_int(strings.trim_space(s[:x]), 10)
	hv, hok := strconv.parse_int(strings.trim_space(s[x + 1:]), 10)
	if !wok || !hok || wv <= 0 || hv <= 0 || wv > 32767 || hv > 32767 { return }
	return i32(wv), i32(hv), true
}

@(private)
parse_displays :: proc(l: ^Loader, root: json.Object, cfg: ^Config) -> bool {
	d := default_displays()
	scope :: "displays"
	out := &cfg.displays
	sec := get_object(l, root, "displays", "milk.json") or_return
	reject_unknown(l, sec, {"scale", "autoApply", "profiles"}, scope) or_return
	out.scale = get_number(l, sec, "scale", scope, d.scale, DISPLAY_SCALE_MIN, DISPLAY_SCALE_MAX) or_return
	out.auto_apply = get_bool(l, sec, "autoApply", scope, d.auto_apply) or_return
	profiles := get_object(l, sec, "profiles", scope) or_return
	out.profiles = make(map[string][]Display_Output)
	for key, value in profiles {
		pscope := strings.concatenate({"displays.profiles.", key}, context.temp_allocator)
		arr, is_arr := value.(json.Array)
		if !is_arr || len(arr) == 0 { return fail(l, "%s must be a non-empty array of monitors.", pscope) }
		entries := make([dynamic]Display_Output)
		for item, i in arr {
			e: Display_Output
			ok := parse_display_output(l, item, pscope, i, &e)
			append(&entries, e)
			if !ok {
				out.profiles[strings.clone(key)] = entries[:]
				return false
			}
		}
		out.profiles[strings.clone(key)] = entries[:]
	}
	return true
}

@(private="file")
parse_display_output :: proc(l: ^Loader, item: json.Value, pscope: string, index: int, e: ^Display_Output) -> bool {
	scope := fmt.tprintf("%s[%d]", pscope, index)
	obj, is_obj := item.(json.Object)
	if !is_obj { return fail(l, "%s must be an object.", scope) }
	reject_unknown(l, obj, {"monitor", "output", "enabled", "mode", "rate", "x", "y", "rotation", "primary"}, scope) or_return
	e.monitor = get_string(l, obj, "monitor", scope, "") or_return
	if e.monitor == "" { return fail(l, "%s.monitor must be a non-empty string.", scope) }
	if _, has := obj["output"]; has { e.output = get_string(l, obj, "output", scope, "") or_return }
	e.enabled = get_bool(l, obj, "enabled", scope, true) or_return
	if mv, has := obj["mode"]; has {
		s, is_str := mv.(json.String)
		w, h, ok := parse_mode_size(is_str ? string(s) : "")
		if !ok { return fail(l, "%s.mode must be a size written as \"WIDTHxHEIGHT\" (e.g. \"1920x1080\").", scope) }
		e.w, e.h = w, h
	} else if e.enabled {
		return fail(l, "%s.mode is missing.", scope)
	}
	e.rate = get_number(l, obj, "rate", scope, 0, 0, 1000) or_return
	x := get_number(l, obj, "x", scope, 0, -32768, 32767) or_return
	y := get_number(l, obj, "y", scope, 0, -32768, 32767) or_return
	e.x, e.y = i32(x), i32(y)
	e.rotation = get_choice(l, obj, "rotation", scope, "normal", DISPLAY_ROTATIONS) or_return
	e.primary = get_bool(l, obj, "primary", scope, false) or_return
	return true
}

destroy_display_outputs :: proc(entries: []Display_Output) {
	for e in entries {
		delete(e.monitor)
		delete(e.output)
		delete(e.rotation)
	}
	delete(entries)
}

@(private)
destroy_displays :: proc(cfg: ^Config) {
	for key, entries in cfg.displays.profiles {
		delete(key)
		destroy_display_outputs(entries)
	}
	delete(cfg.displays.profiles)
}

// One profile as milk.json holds it (the settings app writes the whole
// "profiles" object back).
display_output_json :: proc(e: Display_Output, allocator := context.temp_allocator) -> json.Object {
	o := make(json.Object, allocator)
	o["monitor"] = json.String(e.monitor)
	if e.output != "" { o["output"] = json.String(e.output) }
	o["enabled"] = json.Boolean(e.enabled)
	if e.w > 0 && e.h > 0 { o["mode"] = json.String(fmt.aprintf("%dx%d", e.w, e.h, allocator = allocator)) }
	if e.rate > 0 { o["rate"] = json.Float(f64(int(e.rate * 100 + 0.5)) / 100) }
	o["x"] = json.Integer(i64(e.x))
	o["y"] = json.Integer(i64(e.y))
	if e.rotation != "" && e.rotation != "normal" { o["rotation"] = json.String(e.rotation) }
	if e.primary { o["primary"] = json.Boolean(true) }
	return o
}
