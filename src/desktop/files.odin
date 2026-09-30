// Desktop files (linux.desktopIcons): the entries of a folder, the XDG
// Desktop folder by default, shown as icons next to the area shortcuts.
//
// The folder is read with readdir + fstatat: symlinks are resolved for their
// type (broken ones are kept and flagged), each entry gets a kind from its
// extension (the table Spoil uses, so both show the same icons), .desktop and
// .url files become launchers with their own name and icon, and the list is
// sorted by name, type or date. An inotify watch on the folder schedules a
// rescan (coalesced) when something is added, removed, renamed or rewritten;
// the layer then keeps the cells whose entry did not change, so updates never
// flicker. Without inotify, or while the folder is missing, its modification
// time is polled instead.
package desktop

import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:unicode"
import tx "../tx"

// Entries read from one folder at most; the grid shows far fewer anyway.
@(private)
MAX_FOLDER_ENTRIES :: 4096
// Delay that coalesces a burst of inotify events into one rescan.
@(private)
RESCAN_DELAY :: 0.2
// Polling period while the folder has no inotify watch.
@(private)
FOLDER_POLL :: 2.0

File_Kind :: enum u8 {
	Folder,
	Text,
	Image,
	Audio,
	Video,
	Archive,
	Pdf,
	Code,
	Document,
	Spreadsheet,
	Presentation,
	Executable,
	Generic,
	Broken, // a symlink whose target is missing
}

Desktop_Files :: struct {
	enabled:   bool,
	dir:       string,        // the folder shown (owned)
	items:     [dynamic]Item, // its entries, sorted (owned)
	notify_fd: linux.Fd,      // inotify instance, -1 = none
	watch:     linux.Wd,      // watch on `dir`, -1 = none (polling)
	rescan_at: f64,           // coalesced rescan deadline, 0 = none
	poll_at:   f64,           // next check while there is no watch, 0 = none
	stamp:     i64,           // the folder's mtime (ns) seen by the last scan, -1 = missing
	warned:    bool,          // the folder could not be read (logged once)
	truncated: bool,          // more than MAX_FOLDER_ENTRIES (logged once)
}

files_init :: proc(d: ^Daemon) {
	f := &d.files
	f.items = make([dynamic]Item)
	f.notify_fd = -1
	f.watch = -1
	files_configure(d)
}

files_destroy :: proc(d: ^Daemon) {
	f := &d.files
	files_unwatch(d)
	if f.notify_fd >= 0 { linux.close(f.notify_fd) }
	f.notify_fd = -1
	items_clear(&f.items)
	delete(f.items)
	delete(f.dir)
	f.dir = ""
}

// Follow the configuration (called again on reload): watch the configured
// folder and read it, or forget everything when desktop icons are off.
files_configure :: proc(d: ^Daemon) {
	f := &d.files
	opts := &d.cfg.linux.desktop_icons
	dir := ""
	if opts.enabled {
		dir = strings.trim_space(opts.folder)
		if dir == "~" { dir = home_dir() }
		if strings.has_prefix(dir, "~/") { dir = dir[2:] }
		if dir == "" {
			dir = desktop_dir()
		} else if !strings.has_prefix(dir, "/") {
			dir = join_path({home_dir(), dir}) // relative to $HOME
		}
	}
	if dir != f.dir || opts.enabled != f.enabled {
		files_unwatch(d)
		delete(f.dir)
		f.dir = strings.clone(dir)
		f.warned = false
		f.truncated = false
	}
	f.enabled = opts.enabled
	if !f.enabled {
		items_clear(&f.items)
		if f.notify_fd >= 0 { linux.close(f.notify_fd) }
		f.notify_fd = -1
		f.rescan_at, f.poll_at = 0, 0
		return
	}
	ensure_dir(f.dir)
	if f.notify_fd < 0 {
		fd, err := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
		if err == .NONE {
			f.notify_fd = fd
		} else {
			log.warnf("inotify is unavailable (%v); the desktop folder is polled every %.0f s", err, FOLDER_POLL)
		}
	}
	files_watch(d)
	files_scan(d, false)
}

// Rescan now (after milk changed the folder itself: new folder, rename,
// folder-mode copies), so the icons follow without waiting for inotify.
files_rescan_now :: proc(d: ^Daemon) {
	if !d.files.enabled { return }
	d.files.rescan_at = 0
	files_scan(d, true)
}

// The inotify descriptor, when there is one (see poll_fds).
files_fd :: proc(d: ^Daemon) -> (i32, bool) {
	if !d.files.enabled || d.files.notify_fd < 0 { return -1, false }
	return i32(d.files.notify_fd), true
}

// Drain the inotify queue and schedule a rescan. A watch that went away
// (folder deleted, moved or unmounted) falls back to polling.
files_on_notify :: proc(d: ^Daemon) {
	f := &d.files
	words: [1024]u32 // events are 4-byte aligned
	buf := ([^]u8)(&words[0])[:size_of(words)]
	changed := false
	for {
		n, err := linux.read(f.notify_fd, buf)
		if err == .EINTR { continue }
		if err != .NONE || n <= 0 { break }
		for off := 0; off + size_of(linux.Inotify_Event) <= n; {
			ev := (^linux.Inotify_Event)(&buf[off])
			if ev.mask & {.IGNORED, .DELETE_SELF, .MOVE_SELF, .UNMOUNT} != {} && ev.wd == f.watch {
				log.debugf("The desktop folder %s went away; polling for it", f.dir)
				files_unwatch(d)
			}
			if ev.mask & {.Q_OVERFLOW} != {} { log.debug("inotify queue overflow; rescanning the desktop folder") }
			changed = true
			off += size_of(linux.Inotify_Event) + int(ev.len)
		}
	}
	if changed && f.rescan_at == 0 { f.rescan_at = tx.now() + RESCAN_DELAY }
}

// Timers: the coalesced rescan (held back while an icon is dragged, a band
// drawn or a name edited: their cells must stay put) and polling.
files_tick :: proc(d: ^Daemon, now: f64) {
	f := &d.files
	if !f.enabled { return }
	if f.poll_at > 0 && now >= f.poll_at {
		f.poll_at = now + FOLDER_POLL
		stamp := folder_stamp(f.dir)
		if stamp != f.stamp {
			files_watch(d)
			if f.rescan_at == 0 { f.rescan_at = now }
		}
	}
	if f.rescan_at > 0 && now >= f.rescan_at && !layer_busy(d) {
		f.rescan_at = 0
		files_scan(d, true)
	}
}

// Seconds until files_tick has work (-1 = none).
files_next_timeout :: proc(d: ^Daemon, now: f64) -> f64 {
	f := &d.files
	if !f.enabled { return -1 }
	best := -1.0
	if f.rescan_at > 0 && !layer_busy(d) { best = max(f.rescan_at - now, 0) }
	if f.poll_at > 0 {
		t := max(f.poll_at - now, 0)
		if best < 0 || t < best { best = t }
	}
	return best
}

@(private)
files_watch :: proc(d: ^Daemon) {
	f := &d.files
	if f.notify_fd < 0 || f.watch >= 0 {
		if f.watch < 0 && f.poll_at == 0 { f.poll_at = tx.now() + FOLDER_POLL }
		return
	}
	cdir := strings.clone_to_cstring(f.dir, context.temp_allocator)
	mask := linux.Inotify_Event_Mask{.CREATE, .DELETE, .MOVED_FROM, .MOVED_TO, .CLOSE_WRITE, .ATTRIB,
	                                  .DELETE_SELF, .MOVE_SELF, .ONLYDIR}
	wd, err := linux.inotify_add_watch(f.notify_fd, cdir, mask)
	if err != .NONE {
		if err != .ENOENT { log.warnf("Cannot watch %s (%v); polling it every %.0f s", f.dir, err, FOLDER_POLL) }
		f.poll_at = tx.now() + FOLDER_POLL
		return
	}
	f.watch = wd
	f.poll_at = 0
}

@(private)
files_unwatch :: proc(d: ^Daemon) {
	f := &d.files
	if f.watch >= 0 && f.notify_fd >= 0 { linux.inotify_rm_watch(f.notify_fd, f.watch) }
	f.watch = -1
	if f.enabled { f.poll_at = tx.now() + FOLDER_POLL }
}

// The folder's modification time in nanoseconds, -1 when it is missing.
@(private)
folder_stamp :: proc(dir: string) -> i64 {
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(dir, context.temp_allocator), &st) != .OK || !posix.S_ISDIR(st.st_mode) { return -1 }
	return i64(st.st_mtim.tv_sec) * 1_000_000_000 + i64(st.st_mtim.tv_nsec)
}

// Read the folder again; `show` hands the result to the layer at once
// (otherwise the caller applies the area next).
@(private)
files_scan :: proc(d: ^Daemon, show: bool) {
	f := &d.files
	f.stamp = folder_stamp(f.dir)
	items, names, complete, ok := read_folder(d, f.dir)
	if !ok {
		if !f.warned && f.stamp >= 0 { log.warnf("Cannot read the desktop folder %s", f.dir) }
		f.warned = true
	} else {
		f.warned = false
		if !complete && !f.truncated {
			log.warnf("%s has more than %d entries; only the first ones are considered", f.dir, MAX_FOLDER_ENTRIES)
		}
		f.truncated = !complete
		follow_renames(d, f.items[:], items[:])
		if complete { places_prune_folder(d, f.dir, names) }
	}
	sort_items(items[:], d.cfg.linux.desktop_icons.sort)
	items_clear(&f.items)
	delete(f.items)
	f.items = items
	if show && d.started && d.area > 0 { layer_refresh(d, false) }
}

// A file renamed outside milk (same inode, old name gone, new name without
// a place) keeps its place.
@(private)
follow_renames :: proc(d: ^Daemon, old, new: []Item) {
	if len(old) == 0 { return }
	names := make(map[string]bool, len(new), context.temp_allocator)
	for it in new { names[it.name] = true }
	for &it in new {
		if _, placed := place_of(d, &it); placed { continue }
		for &prev in old {
			if prev.inode != it.inode || prev.name in names { continue }
			if _, had := place_of(d, &prev); had { place_rename(d, prev.name, it.name) }
			break
		}
	}
}

// One Item per entry of `dir` (dot files only with showHidden), and every
// name in it (temp allocator) for pruning saved places. `complete` is false
// when the folder had more than MAX_FOLDER_ENTRIES entries.
@(private)
read_folder :: proc(d: ^Daemon, dir: string) -> (items: [dynamic]Item, names: []string, complete, ok: bool) {
	items = make([dynamic]Item)
	dp := posix.opendir(strings.clone_to_cstring(dir, context.temp_allocator))
	if dp == nil { return }
	defer posix.closedir(dp)
	fd := posix.dirfd(dp)
	show_hidden := d.cfg.linux.desktop_icons.show_hidden
	specials: map[string]string // read with the first folder
	all := make([dynamic]string, context.temp_allocator)
	complete = true
	for {
		de := posix.readdir(dp)
		if de == nil { break }
		cname := cstring(&de.d_name[0])
		name := string(cname)
		if name == "." || name == ".." || name == "" { continue }
		if len(all) >= MAX_FOLDER_ENTRIES {
			complete = false
			break
		}
		append(&all, strings.clone(name, context.temp_allocator))
		hidden := name[0] == '.'
		if hidden && !show_hidden { continue }

		st: posix.stat_t
		if posix.fstatat(fd, cname, &st, {.SYMLINK_NOFOLLOW}) != .OK { continue } // removed meanwhile
		it := Item{source = .Folder, hidden = hidden, inode = u64(st.st_ino)}
		path := join_path({dir, name})
		if posix.S_ISLNK(st.st_mode) {
			it.is_link = true
			target: posix.stat_t
			if posix.fstatat(fd, cname, &target, {}) == .OK {
				st = target
			} else {
				it.kind = .Broken
			}
		}
		it.size = i64(st.st_size)
		it.mtime = i64(st.st_mtim.tv_sec)
		if it.kind != .Broken {
			if posix.S_ISDIR(st.st_mode) {
				it.kind = .Folder
				if specials == nil { specials = special_folders() }
				it.icon = special_folder_icon(specials, it.is_link ? link_target(fd, dir, cname) : path)
			} else {
				exec := posix.S_ISREG(st.st_mode) && (st.st_mode & {.IXUSR, .IXGRP, .IXOTH}) != {}
				it.kind = kind_for_name(name, exec)
			}
		}
		it.name = strings.clone(name)
		it.path = strings.clone(path)
		if it.kind != .Folder && it.kind != .Broken && is_shortcut_name(name) {
			if s, loaded := load_shortcut(path); loaded {
				it.shortcut = s
				it.launcher = true
			}
		}
		it.label = strings.clone(it.launcher ? it.shortcut.name : name)
		append(&items, it)
	}
	return items, all[:], complete, true
}

// Where a symlink of the folder points (absolute, cleaned; temp allocator).
@(private)
link_target :: proc(dir_fd: posix.FD, dir: string, cname: cstring) -> string {
	buf: [4096]u8
	n := posix.readlinkat(dir_fd, cname, &buf[0], len(buf))
	if n <= 0 { return "" }
	target := string(buf[:n])
	if !strings.has_prefix(target, "/") { target = join_path({dir, target}) }
	cleaned, _ := os.clean_path(target, context.temp_allocator)
	return cleaned
}

// ---------------------------------------------------------------------------
// Kinds (the table of Spoil's fsys.odin)
// ---------------------------------------------------------------------------
@(private, rodata) EXT_IMAGE := []string{"png", "jpg", "jpeg", "jpe", "gif", "bmp", "webp", "svg", "svgz", "tif", "tiff", "ico", "heic", "heif", "avif", "xpm", "qoi", "tga", "ppm", "pgm", "pbm", "pnm", "jxl", "xcf", "psd", "kra"}
@(private, rodata) EXT_AUDIO := []string{"mp3", "flac", "ogg", "oga", "opus", "wav", "m4a", "aac", "wma", "aif", "aiff", "mid", "midi", "ape", "wv", "mka"}
@(private, rodata) EXT_VIDEO := []string{"mp4", "mkv", "webm", "avi", "mov", "wmv", "flv", "m4v", "mpg", "mpeg", "ogv", "3gp", "ts", "m2ts", "vob"}
@(private, rodata) EXT_ARCHIVE := []string{"zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst", "7z", "rar", "lz", "lz4", "lzma", "cab", "deb", "rpm", "jar", "apk", "iso", "img", "dmg", "cpio", "ar"}
@(private, rodata) EXT_CODE := []string{"c", "h", "cpp", "hpp", "cc", "cxx", "hh", "py", "js", "mjs", "cjs", "ts", "jsx", "tsx", "odin", "go", "rs", "java", "kt", "kts", "sh", "bash", "zsh", "fish", "rb", "php", "lua", "pl", "cs", "swift", "html", "htm", "css", "scss", "sass", "less", "json", "json5", "xml", "yaml", "yml", "toml", "ini", "conf", "cfg", "sql", "vim", "mk", "cmake", "diff", "patch", "ps1", "bat", "cmd", "vbs", "zig", "nim", "hs", "ml", "ex", "exs", "erl", "clj", "scm", "el", "dart", "vue", "svelte", "glsl", "hlsl", "desktop", "service", "gradle", "nix", "r", "jl", "m", "mm", "asm", "s"}
@(private, rodata) EXT_TEXT := []string{"txt", "md", "markdown", "rst", "log", "csv", "tsv", "tex", "org", "nfo", "srt", "vtt", "ass", "sub", "adoc", "text", "readme", "me", "1", "man"}
@(private, rodata) EXT_DOC := []string{"doc", "docx", "odt", "rtf", "abw", "pages", "epub", "fodt"}
@(private, rodata) EXT_SHEET := []string{"xls", "xlsx", "ods", "numbers", "fods"}
@(private, rodata) EXT_SLIDES := []string{"ppt", "pptx", "odp", "key", "fodp"}
@(private, rodata) EXT_EXEC := []string{"appimage", "run", "bin", "exe", "msi", "flatpakref"}

// The kind of a file from its name (and its execute bit when there is no
// telling extension).
kind_for_name :: proc(name: string, executable: bool) -> File_Kind {
	ext := lower_ext(name)
	if ext != "" { ext = ext[1:] }
	switch {
	case ext == "":
		if executable { return .Executable }
		switch strings.to_lower(name, context.temp_allocator) {
		case "makefile", "dockerfile", "pkgbuild", "cmakelists.txt", "justfile", "gemfile", "rakefile":
			return .Code
		case "readme", "license", "copying", "authors", "changelog", "todo", "news", "install":
			return .Text
		}
		return .Generic
	case ext == "pdf":                     return .Pdf
	case slice.contains(EXT_IMAGE, ext):   return .Image
	case slice.contains(EXT_AUDIO, ext):   return .Audio
	case slice.contains(EXT_VIDEO, ext):   return .Video
	case slice.contains(EXT_ARCHIVE, ext): return .Archive
	case slice.contains(EXT_DOC, ext):     return .Document
	case slice.contains(EXT_SHEET, ext):   return .Spreadsheet
	case slice.contains(EXT_SLIDES, ext):  return .Presentation
	case slice.contains(EXT_CODE, ext):    return .Code
	case slice.contains(EXT_TEXT, ext):    return .Text
	case slice.contains(EXT_EXEC, ext):    return .Executable
	}
	return executable ? .Executable : .Generic
}

// Theme icon names for a kind, most specific first.
@(private, rodata) NAMES_FOLDER  := []string{"folder", "inode-directory"}
@(private, rodata) NAMES_TEXT    := []string{"text-x-generic"}
@(private, rodata) NAMES_IMAGE   := []string{"image-x-generic"}
@(private, rodata) NAMES_AUDIO   := []string{"audio-x-generic"}
@(private, rodata) NAMES_VIDEO   := []string{"video-x-generic"}
@(private, rodata) NAMES_ARCHIVE := []string{"package-x-generic", "application-x-archive"}
@(private, rodata) NAMES_PDF     := []string{"application-pdf", "x-office-document", "text-x-generic"}
@(private, rodata) NAMES_CODE    := []string{"text-x-script", "text-x-generic"}
@(private, rodata) NAMES_DOC     := []string{"x-office-document", "text-x-generic"}
@(private, rodata) NAMES_SHEET   := []string{"x-office-spreadsheet", "text-x-generic"}
@(private, rodata) NAMES_SLIDES  := []string{"x-office-presentation", "text-x-generic"}
@(private, rodata) NAMES_EXEC    := []string{"application-x-executable"}
@(private, rodata) NAMES_GENERIC := []string{"application-x-generic", "text-x-generic", "unknown"}
@(private, rodata) NAMES_BROKEN  := []string{"inode-symlink", "emblem-symbolic-link", "application-x-generic"}

kind_icon_names :: proc(k: File_Kind) -> []string {
	switch k {
	case .Folder:       return NAMES_FOLDER
	case .Text:         return NAMES_TEXT
	case .Image:        return NAMES_IMAGE
	case .Audio:        return NAMES_AUDIO
	case .Video:        return NAMES_VIDEO
	case .Archive:      return NAMES_ARCHIVE
	case .Pdf:          return NAMES_PDF
	case .Code:         return NAMES_CODE
	case .Document:     return NAMES_DOC
	case .Spreadsheet:  return NAMES_SHEET
	case .Presentation: return NAMES_SLIDES
	case .Executable:   return NAMES_EXEC
	case .Generic:      return NAMES_GENERIC
	case .Broken:       return NAMES_BROKEN
	}
	return NAMES_GENERIC
}

// The XDG user folders with an icon of their own ("folder-documents"...),
// by cleaned path (temp allocator).
@(private)
special_folders :: proc() -> map[string]string {
	out := make(map[string]string, 16, context.temp_allocator)
	home, _ := os.clean_path(home_dir(), context.temp_allocator)
	out[home] = "user-home"
	pairs := [?][2]string{
		{"DESKTOP", "user-desktop"}, {"DOCUMENTS", "folder-documents"}, {"DOWNLOAD", "folder-download"},
		{"PICTURES", "folder-pictures"}, {"MUSIC", "folder-music"}, {"VIDEOS", "folder-videos"},
		{"TEMPLATES", "folder-templates"}, {"PUBLICSHARE", "folder-publicshare"},
	}
	for p in pairs {
		dir := xdg_user_dir(p[0], "")
		if dir == "" { continue }
		cleaned, _ := os.clean_path(dir, context.temp_allocator)
		if cleaned != home { out[cleaned] = p[1] }
	}
	return out
}

@(private)
special_folder_icon :: proc(specials: map[string]string, path: string) -> string {
	if path == "" { return "" }
	cleaned, _ := os.clean_path(path, context.temp_allocator)
	return specials[cleaned] or_else ""
}

// ---------------------------------------------------------------------------
// Sorting (linux.desktopIcons.sort)
// ---------------------------------------------------------------------------
@(private)
sort_items :: proc(items: []Item, order: string) {
	switch order {
	case "type":     slice.sort_by(items, item_less_type)
	case "modified": slice.sort_by(items, item_less_modified)
	case:            slice.sort_by(items, item_less_name)
	}
}

// Folders first, then by label (natural, case- and accent-insensitive).
@(private)
item_less_name :: proc(a, b: Item) -> bool {
	if (a.kind == .Folder) != (b.kind == .Folder) { return a.kind == .Folder }
	ka, kb := sort_key(a.label), sort_key(b.label)
	if ka != kb { return natural_less(ka, kb) }
	return a.name < b.name
}

// Folders first, then by kind and extension, then by name.
@(private)
item_less_type :: proc(a, b: Item) -> bool {
	if (a.kind == .Folder) != (b.kind == .Folder) { return a.kind == .Folder }
	if a.launcher != b.launcher { return a.launcher }
	if a.kind != b.kind { return a.kind < b.kind }
	ea, eb := lower_ext(a.name), lower_ext(b.name)
	if ea != eb { return ea < eb }
	return item_less_name(a, b)
}

// Newest first.
@(private)
item_less_modified :: proc(a, b: Item) -> bool {
	if a.mtime != b.mtime { return a.mtime > b.mtime }
	return item_less_name(a, b)
}

// Lower-cased name without accents: "Música" sorts like "musica" (temp allocator).
@(private)
sort_key :: proc(name: string) -> string {
	b := strings.builder_make(0, len(name), context.temp_allocator)
	for r in name { strings.write_rune(&b, fold_rune(r)) }
	return strings.to_string(b)
}

@(private)
fold_rune :: proc(r: rune) -> rune {
	l := unicode.to_lower(r)
	switch l {
	case 'á', 'à', 'â', 'ã', 'ä', 'å': return 'a'
	case 'é', 'è', 'ê', 'ë':           return 'e'
	case 'í', 'ì', 'î', 'ï':           return 'i'
	case 'ó', 'ò', 'ô', 'õ', 'ö':      return 'o'
	case 'ú', 'ù', 'û', 'ü':           return 'u'
	case 'ç':                          return 'c'
	case 'ñ':                          return 'n'
	case 'ý', 'ÿ':                     return 'y'
	}
	return l
}

// Natural order on folded keys: "img2" < "img10".
@(private)
natural_less :: proc(a, b: string) -> bool {
	is_digit :: #force_inline proc(ch: u8) -> bool { return ch >= '0' && ch <= '9' }
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		ca, cb := a[i], b[j]
		if is_digit(ca) && is_digit(cb) {
			si := i
			for i < len(a) && is_digit(a[i]) { i += 1 }
			sj := j
			for j < len(b) && is_digit(b[j]) { j += 1 }
			na := strings.trim_left(a[si:i], "0")
			nb := strings.trim_left(b[sj:j], "0")
			if len(na) != len(nb) { return len(na) < len(nb) }
			if na != nb { return na < nb }
			if (i - si) != (j - sj) { return (i - si) > (j - sj) } // "01" before "1"
			continue
		}
		if ca != cb { return ca < cb }
		i += 1
		j += 1
	}
	return len(a) - i < len(b) - j
}
