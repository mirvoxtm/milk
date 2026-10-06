package config

import "core:encoding/json"
import "core:strings"

// milk's launcher (milk/launcher.odin), the "launcher" section of milk.json:
// its tabs, what typing finds, and entries of the user's own.
Launcher_Options :: struct {
	tabs:              []string, // LAUNCHER_TABS, in the order shown; the first opens
	milk_entries:      bool,     // areas, settings pages, session… in the apps list
	calculator:        bool,     // "2*(3+4)" + Enter: the result, to copy
	run_commands:      bool,     // a typed command runs with Enter
	web_search:        string,   // a WEB_ENGINES name or a URL with %s; "" = off
	matching:          string,   // rofi's matching: LAUNCHER_MATCHING
	file_search:       bool,     // "/ name", and the offer when nothing matches
	files_folder:      string,   // where the Files tab and file searches look ("~")
	near_button:       bool,     // opened with the bar's button: next to it, not centred
	width:             int,      // pixels
	lines:             int,      // rows shown
	terminal_commands: []string, // more programs that run in the terminal (htop, vim… already do)
	entries:           []Launcher_Entry,
}

// An entry of the user's own: a name to find and a shell command.
Launcher_Entry :: struct {
	name:     string,
	command:  string,
	icon:     string, // an icon theme name or an image path, "" = none
	keywords: string, // more words it is found by
}

LAUNCHER_TABS :: []string{"apps", "windows", "files", "run"}
LAUNCHER_MATCHING :: []string{"normal", "fuzzy", "prefix"}

// Search engines by name ("%s" is the search, URL-encoded).
WEB_ENGINES :: [][2]string{
	{"duckduckgo", "https://duckduckgo.com/?q=%s"},
	{"google", "https://www.google.com/search?q=%s"},
	{"bing", "https://www.bing.com/search?q=%s"},
	{"brave", "https://search.brave.com/search?q=%s"},
	{"startpage", "https://www.startpage.com/do/search?query=%s"},
	{"ecosia", "https://www.ecosia.org/search?q=%s"},
}

@(rodata) DEFAULT_LAUNCHER_TABS := []string{"apps", "windows", "files"}

default_launcher :: proc() -> Launcher_Options {
	return {
		tabs = DEFAULT_LAUNCHER_TABS, milk_entries = true, calculator = true, run_commands = true,
		web_search = "duckduckgo", matching = "normal", file_search = true, files_folder = "~", near_button = true,
		width = 600, lines = 8,
	}
}

// The search URL, "" when web search is off.
web_search_url :: proc(o: ^Launcher_Options) -> string {
	for e in WEB_ENGINES { if e[0] == o.web_search { return e[1] } }
	return o.web_search
}

@(private)
parse_launcher :: proc(l: ^Loader, root: json.Object, out: ^Launcher_Options) -> bool {
	d := default_launcher()
	section := get_object(l, root, "launcher", "milk.json") or_return
	reject_unknown(l, section, {"tabs", "milkEntries", "calculator", "runCommands", "webSearch", "matching", "fileSearch", "filesFolder",
	                            "nearButton", "width", "lines", "terminalCommands", "entries"}, "launcher") or_return
	out.tabs = get_string_list(l, section, "tabs", "launcher", d.tabs) or_return
	if len(out.tabs) == 0 { return fail(l, "launcher.tabs needs at least one tab (%s).", strings.join(LAUNCHER_TABS, ", ", context.temp_allocator)) }
	for t, i in out.tabs {
		known := false
		for k in LAUNCHER_TABS { if k == t { known = true } }
		if !known { return fail(l, "launcher.tabs: unknown tab %q (valid: %s)", t, strings.join(LAUNCHER_TABS, ", ", context.temp_allocator)) }
		for o in out.tabs[:i] { if o == t { return fail(l, "launcher.tabs lists %q twice.", t) } }
	}
	out.milk_entries = get_bool(l, section, "milkEntries", "launcher", d.milk_entries) or_return
	out.calculator = get_bool(l, section, "calculator", "launcher", d.calculator) or_return
	out.run_commands = get_bool(l, section, "runCommands", "launcher", d.run_commands) or_return
	out.web_search = strings.clone(d.web_search)
	if v, present := section["webSearch"]; present {
		delete(out.web_search)
		out.web_search = ""
		#partial switch s in v {
		case json.Null:
		case string:
			value := strings.trim_space(s)
			named := false
			for e in WEB_ENGINES { if e[0] == value { named = true } }
			if value != "" && !named && !((strings.has_prefix(value, "https://") || strings.has_prefix(value, "http://")) && strings.contains(value, "%s")) {
				return fail(l, "launcher.webSearch must be one of %s, a URL with %%s for the search, or null (off).", engine_names())
			}
			out.web_search = strings.clone(value)
		case:
			return fail(l, "launcher.webSearch must be a string or null.")
		}
	}
	out.matching = get_choice(l, section, "matching", "launcher", d.matching, LAUNCHER_MATCHING) or_return
	out.file_search = get_bool(l, section, "fileSearch", "launcher", d.file_search) or_return
	out.files_folder = get_string(l, section, "filesFolder", "launcher", d.files_folder) or_return
	out.near_button = get_bool(l, section, "nearButton", "launcher", d.near_button) or_return
	width := get_number(l, section, "width", "launcher", f64(d.width), 320, 2000) or_return
	out.width = int(width)
	lines := get_number(l, section, "lines", "launcher", f64(d.lines), 3, 30) or_return
	out.lines = int(lines)
	out.terminal_commands = get_string_list(l, section, "terminalCommands", "launcher", nil) or_return
	entries := make([dynamic]Launcher_Entry)
	if v, present := section["entries"]; present {
		arr, is_arr := v.(json.Array)
		if !is_arr { return fail(l, "launcher.entries must be an array of {\"name\": …, \"command\": …}.") }
		for item, i in arr {
			obj, is_obj := item.(json.Object)
			if !is_obj { return fail(l, "launcher.entries[%d] must be an object with a name and a command.", i) }
			scope := "launcher.entries"
			reject_unknown(l, obj, {"name", "command", "icon", "keywords"}, scope) or_return
			e: Launcher_Entry
			e.name = get_string(l, obj, "name", scope, "") or_return
			e.command = get_string(l, obj, "command", scope, "") or_return
			if strings.trim_space(e.name) == "" || strings.trim_space(e.command) == "" {
				delete(e.name); delete(e.command)
				return fail(l, "launcher.entries[%d] needs a name and a command.", i)
			}
			e.icon = get_string(l, obj, "icon", scope, "", true) or_return
			e.keywords = get_string(l, obj, "keywords", scope, "", true) or_return
			append(&entries, e)
		}
	}
	out.entries = entries[:]
	return true
}

@(private)
engine_names :: proc() -> string {
	names := make([dynamic]string, context.temp_allocator)
	for e in WEB_ENGINES { append(&names, e[0]) }
	return strings.join(names[:], ", ", context.temp_allocator)
}

@(private)
destroy_launcher :: proc(o: ^Launcher_Options) {
	for t in o.tabs { delete(t) }
	delete(o.tabs)
	delete(o.web_search)
	delete(o.matching)
	delete(o.files_folder)
	for t in o.terminal_commands { delete(t) }
	delete(o.terminal_commands)
	for e in o.entries { delete(e.name); delete(e.command); delete(e.icon); delete(e.keywords) }
	delete(o.entries)
}
