// Desktop shortcuts: .desktop / .url parsing, launching, and the
// Windows-style "copy into the Desktop folder" mode.
//
// The Windows version manages .lnk and .url files; on Linux the equivalents
// are XDG desktop entries (.desktop) and Windows Internet Shortcuts (.url),
// read from Common/ and the area's folder (an area file replaces a common one
// with the same name).
package desktop

import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import config "../config"

Shortcut_Kind :: enum {
	Application,
	Link,
}

// One parsed shortcut. Every string is owned (see shortcut_destroy).
Shortcut :: struct {
	path:     string, // the .desktop/.url file
	filename: string,
	name:     string, // localized display name
	kind:     Shortcut_Kind,
	exec:     string, // Application: Exec line (unescaped)
	url:      string, // Link: target URL
	icon:     string, // Icon= (theme name or path), may be ""
	terminal: bool,
	workdir:  string, // Path=, may be ""
}

shortcut_destroy :: proc(s: ^Shortcut, allocator := context.allocator) {
	delete(s.path, allocator)
	delete(s.filename, allocator)
	delete(s.name, allocator)
	delete(s.exec, allocator)
	delete(s.url, allocator)
	delete(s.icon, allocator)
	delete(s.workdir, allocator)
	s^ = {}
}

// Terminal emulators tried for Terminal=true entries, with their "execute" flag.
@(private)
TERMINALS := [?][2]string{
	{"x-terminal-emulator", "-e"}, {"alacritty", "-e"}, {"kitty", ""}, {"foot", ""}, {"st", "-e"},
	{"urxvt", "-e"}, {"xterm", "-e"}, {"xfce4-terminal", "-x"}, {"gnome-terminal", "--"}, {"konsole", "-e"},
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------
is_shortcut_name :: proc(name: string) -> bool {
	lower := strings.to_lower(name, context.temp_allocator)
	return strings.has_suffix(lower, ".desktop") || strings.has_suffix(lower, ".url")
}

// Shortcut file names in `dir`, sorted case-insensitively (temp allocator).
list_shortcut_files :: proc(dir: string) -> []string {
	if dir == "" || !os.is_directory(dir) { return nil }
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return nil }
	names := make([dynamic]string, context.temp_allocator)
	for fi in infos {
		name := os.base(fi.fullpath)
		if !is_shortcut_name(name) || strings.has_prefix(name, ".") { continue }
		regular := fi.type == .Regular
		if fi.type == .Symlink || fi.type == .Undetermined {
			target, serr := os.stat(fi.fullpath, context.temp_allocator)
			regular = serr == nil && target.type == .Regular
		}
		if regular { append(&names, name) }
	}
	slice.sort_by(names[:], proc(a, b: string) -> bool {
		la := strings.to_lower(a, context.temp_allocator)
		lb := strings.to_lower(b, context.temp_allocator)
		return la < lb if la != lb else a < b
	})
	return names[:]
}

// Number of shortcut files in `dir` (for `milk test`).
shortcut_count :: proc(dir: string) -> int {
	return len(list_shortcut_files(dir))
}

// Locale suffixes for localized keys, most specific first ("pt_BR", "pt").
@(private)
locale_suffixes :: proc() -> []string {
	value := ""
	for name in ([]string{"LC_ALL", "LC_MESSAGES", "LANG"}) {
		if v, found := os.lookup_env(name, context.temp_allocator); found && v != "" {
			value = v
			break
		}
	}
	if dot := strings.index_byte(value, '.'); dot >= 0 {
		modifier := ""
		if at := strings.index_byte(value, '@'); at > dot { modifier = value[at:] }
		value = strings.concatenate({value[:dot], modifier}, context.temp_allocator)
	}
	if value == "" || value == "C" || value == "POSIX" || strings.has_prefix(value, "C@") { return nil }
	lang, country, modifier := value, "", ""
	if at := strings.index_byte(lang, '@'); at >= 0 { modifier = lang[at:]; lang = lang[:at] }
	if us := strings.index_byte(lang, '_'); us >= 0 { country = lang[us:]; lang = lang[:us] }
	out := make([dynamic]string, context.temp_allocator)
	if country != "" && modifier != "" { append(&out, strings.concatenate({lang, country, modifier}, context.temp_allocator)) }
	if country != "" { append(&out, strings.concatenate({lang, country}, context.temp_allocator)) }
	if modifier != "" { append(&out, strings.concatenate({lang, modifier}, context.temp_allocator)) }
	append(&out, lang)
	return out[:]
}

// A key in the user's language (Name[pt_BR], Name[pt]), else the plain one.
localized :: proc(section: Ini_Section, key: string) -> string {
	for suffix in locale_suffixes() {
		if v, ok := section[strings.concatenate({key, "[", suffix, "]"}, context.temp_allocator)]; ok && v != "" { return v }
	}
	return section[key] or_else ""
}

@(private)
truthy :: proc(value: string) -> bool {
	return strings.equal_fold(strings.trim_space(value), "true")
}

// Parse a .desktop or .url file. `ok` is false for entries that must not be
// shown (hidden, TryExec missing, unsupported type, broken file).
load_shortcut :: proc(path: string, allocator := context.allocator) -> (s: Shortcut, ok: bool) {
	text, read_ok := read_text_file(path)
	if !read_ok {
		log.warnf("Could not read %s", path)
		return
	}
	ini := parse_ini(text)
	filename := os.base(path)
	stem := filename
	if dot := strings.last_index_byte(filename, '.'); dot > 0 { stem = filename[:dot] }

	if strings.has_suffix(strings.to_lower(filename, context.temp_allocator), ".url") {
		section, found := ini_section_fold(ini, "InternetShortcut")
		if !found { return }
		url := section["URL"] or_else ""
		if url == "" { return }
		s = Shortcut{kind = .Link, name = stem, url = url}
		return own_shortcut(s, path, filename, allocator), true
	}

	entry, has_entry := ini["Desktop Entry"]
	if !has_entry { return }
	if truthy(entry["Hidden"] or_else "") || truthy(entry["NoDisplay"] or_else "") { return }
	s.name = unescape_value(localized(entry, "Name"))
	if s.name == "" { s.name = stem }
	s.icon = unescape_value(localized(entry, "Icon"))
	switch entry["Type"] or_else "Application" {
	case "Link":
		s.kind = .Link
		s.url = unescape_value(entry["URL"] or_else "")
		if s.url == "" { return }
	case "Application":
		s.kind = .Application
		s.exec = unescape_value(entry["Exec"] or_else "")
		if strings.trim_space(s.exec) == "" { return }
		if try_exec := unescape_value(entry["TryExec"] or_else ""); try_exec != "" {
			if _, found := find_executable(try_exec); !found { return }
		}
		s.terminal = truthy(entry["Terminal"] or_else "")
		s.workdir = unescape_value(entry["Path"] or_else "")
	case:
		return
	}
	return own_shortcut(s, path, filename, allocator), true
}

@(private)
own_shortcut :: proc(s: Shortcut, path, filename: string, allocator := context.allocator) -> Shortcut {
	return Shortcut{
		path = strings.clone(path, allocator),
		filename = strings.clone(filename, allocator),
		name = strings.clone(s.name, allocator),
		kind = s.kind,
		exec = strings.clone(s.exec, allocator),
		url = strings.clone(s.url, allocator),
		icon = strings.clone(s.icon, allocator),
		terminal = s.terminal,
		workdir = strings.clone(s.workdir, allocator),
	}
}

// Common shortcuts first, then the area's; an area file replaces a common
// one of the same name (keeping its position). Hidden entries are dropped.
collect_entries :: proc(common_dir, area_dir: string, allocator := context.allocator) -> [dynamic]Shortcut {
	Item :: struct { filename, path: string }
	items := make([dynamic]Item, context.temp_allocator)
	for dir in ([]string{common_dir, area_dir}) {
		for name in list_shortcut_files(dir) {
			path := join_path({dir, name})
			replaced := false
			for &it in items {
				if it.filename == name { it.path = path; replaced = true; break }
			}
			if !replaced { append(&items, Item{name, path}) }
		}
	}
	out := make([dynamic]Shortcut, 0, len(items), allocator)
	for it in items {
		if s, ok := load_shortcut(it.path, allocator); ok { append(&out, s) }
	}
	return out
}

// ---------------------------------------------------------------------------
// Launching
// ---------------------------------------------------------------------------

// Split an Exec value into argv (Desktop Entry spec quoting) and expand or
// drop its field codes; nothing is passed as a file/URL argument.
parse_exec :: proc(s: ^Shortcut, allocator := context.temp_allocator) -> []string {
	Token :: struct { text: string, quoted: bool }
	tokens := make([dynamic]Token, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	in_token, quoted, in_quotes := false, false, false
	line := s.exec
	for i := 0; i < len(line); i += 1 {
		ch := line[i]
		if in_quotes {
			if ch == '\\' && i + 1 < len(line) && strings.index_byte("\"`$\\", line[i + 1]) >= 0 {
				i += 1
				strings.write_byte(&b, line[i])
			} else if ch == '"' {
				in_quotes = false
			} else {
				strings.write_byte(&b, ch)
			}
			continue
		}
		switch ch {
		case ' ', '\t', '\n':
			if in_token {
				append(&tokens, Token{strings.clone(strings.to_string(b), context.temp_allocator), quoted})
				strings.builder_reset(&b)
				in_token, quoted = false, false
			}
		case '"':
			in_token, quoted, in_quotes = true, true, true
		case '\'':
			// Not part of the spec, but common in hand-written files: shell-style single quotes.
			in_token, quoted = true, true
			for i + 1 < len(line) && line[i + 1] != '\'' {
				i += 1
				strings.write_byte(&b, line[i])
			}
			i += 1
		case '\\':
			in_token = true
			if i + 1 < len(line) {
				i += 1
				strings.write_byte(&b, line[i])
			}
		case:
			in_token = true
			strings.write_byte(&b, ch)
		}
	}
	if in_token { append(&tokens, Token{strings.clone(strings.to_string(b), context.temp_allocator), quoted}) }

	argv := make([dynamic]string, allocator)
	for t in tokens {
		if !t.quoted && len(t.text) == 2 && t.text[0] == '%' {
			switch t.text[1] {
			case 'f', 'F', 'u', 'U', 'd', 'D', 'n', 'N', 'v', 'm':
				continue
			case 'i':
				if s.icon != "" {
					append(&argv, strings.clone("--icon", allocator))
					append(&argv, strings.clone(s.icon, allocator))
				}
				continue
			case 'c':
				append(&argv, strings.clone(s.name, allocator))
				continue
			case 'k':
				append(&argv, strings.clone(s.path, allocator))
				continue
			}
		}
		// Field codes embedded in a word ("--file=%f"): drop them, keep "%%" as "%".
		out := strings.builder_make(allocator)
		for i := 0; i < len(t.text); i += 1 {
			if t.text[i] == '%' && i + 1 < len(t.text) {
				i += 1
				if t.text[i] == '%' { strings.write_byte(&out, '%') }
				continue
			}
			strings.write_byte(&out, t.text[i])
		}
		if strings.builder_len(out) > 0 || t.quoted { append(&argv, strings.to_string(out)) }
	}
	return argv[:]
}

// $TERMINAL, or the first known terminal emulator, as an argv prefix.
@(private)
terminal_prefix :: proc() -> ([]string, bool) {
	out := make([dynamic]string, context.temp_allocator)
	if preferred, found := os.lookup_env("TERMINAL", context.temp_allocator); found && preferred != "" {
		flag := "-e"
		base := os.base(preferred)
		for t in TERMINALS {
			if t[0] == base { flag = t[1]; break }
		}
		append(&out, preferred)
		if flag != "" { append(&out, flag) }
		return out[:], true
	}
	for t in TERMINALS {
		if path, found := find_executable(t[0]); found {
			append(&out, path)
			if t[1] != "" { append(&out, t[1]) }
			return out[:], true
		}
	}
	return nil, false
}

// Launch a shortcut detached from milk; the pid is reaped in tick.
launch :: proc(d: ^Daemon, s: ^Shortcut) {
	argv: [dynamic]string
	argv.allocator = context.temp_allocator
	switch s.kind {
	case .Link:
		append(&argv, "xdg-open", s.url)
	case .Application:
		cmd := parse_exec(s)
		if len(cmd) == 0 {
			log.errorf("%s has an empty Exec line", s.filename)
			return
		}
		if s.terminal {
			prefix, found := terminal_prefix()
			if !found {
				log.errorf("No terminal emulator found to run %s", s.name)
				return
			}
			append(&argv, ..prefix)
		}
		append(&argv, ..cmd)
	}
	workdir := home_dir()
	if s.workdir != "" && os.is_directory(s.workdir) { workdir = s.workdir }
	pid, ok := spawn_detached(argv[:], workdir)
	if !ok { return }
	append(&d.children, pid)
	log.infof("Launched %s: %s", s.name, strings.join(argv[:], " ", context.temp_allocator))
}

// ---------------------------------------------------------------------------
// Folder mode (Set-DesktopState): for setups with an external icon manager
// (pcmanfm --desktop, xfdesktop, nautilus-desktop...)
// ---------------------------------------------------------------------------

// Every shortcut file name milk owns: Common/ plus all workspace folders
// (Get-ManagedShortcutNames).
@(private)
managed_names :: proc(root: string, cfg: ^config.Config) -> []string {
	seen := make(map[string]bool, context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	add :: proc(seen: ^map[string]bool, out: ^[dynamic]string, dir: string) {
		for name in list_shortcut_files(dir) {
			if name in seen { continue }
			seen[name] = true
			append(out, name)
		}
	}
	add(&seen, &out, join_path({root, cfg.paths.common}))
	for _, ws in cfg.workspaces { add(&seen, &out, join_path({root, ws.folder})) }
	return out[:]
}

// The XDG Desktop directory (XDG_DESKTOP_DIR, e.g. "~/Área de trabalho").
desktop_dir :: proc() -> string {
	return xdg_user_dir("DESKTOP", join_path({home_dir(), "Desktop"}))
}

// Remove the managed names from the Desktop folder, then copy the common
// shortcuts followed by the area's ones (the area wins on equal names).
@(private)
folder_sync :: proc(d: ^Daemon, common_dir, area_dir: string) {
	target_dir := desktop_dir()
	if !ensure_dir(target_dir) { return }
	folder_remove_managed(d, d.cfg)
	for dir in ([]string{common_dir, area_dir}) {
		for name in list_shortcut_files(dir) {
			source := join_path({dir, name})
			target := join_path({target_dir, name})
			if err := os.copy_file(target, source); err != nil {
				log.warnf("Could not copy %s: %s", source, os.error_string(err))
				continue
			}
			if strings.has_suffix(strings.to_lower(name, context.temp_allocator), ".desktop") {
				// File managers only trust executable launchers.
				os.change_mode(target, os.perm_number(0o755))
			}
		}
	}
	log.debugf("Desktop folder %s synchronised", target_dir)
}

@(private)
folder_remove_managed :: proc(d: ^Daemon, cfg: ^config.Config) {
	target_dir := desktop_dir()
	for name in managed_names(d.runtime_root, cfg) {
		target := join_path({target_dir, name})
		if _, err := os.lstat(target, context.temp_allocator); err != nil { continue }
		if rerr := os.remove(target); rerr != nil {
			log.warnf("Could not remove %s: %s", target, os.error_string(rerr))
		}
	}
}
