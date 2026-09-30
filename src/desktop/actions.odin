// What desktop icons do: open (launchers run, folders go to the file
// manager, other files to xdg-open), the context menu (package menu), Copy
// path (the desktop owns CLIPBOARD for it like any application; milk's
// clipboard history then picks the text up), Move to Trash (freedesktop
// Trash specification: rename into the home trash next to a .trashinfo),
// and the requests of the window manager's root menu (request).
package desktop

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import xlib "vendor:x11/xlib"
import config "../config"
import menu "../menu"
import tx "../tx"

// Most items one Open starts at once (a stray Ctrl+A, Enter).
@(private)
MAX_OPEN :: 16
// Largest Copy path text served in one piece (no INCR transfers).
@(private)
MAX_CLIPBOARD :: 256 * 1024

@(private)
Menu_Action :: enum {
	Open,
	Open_Terminal,
	Copy_Path,
	Rename,
	Trash,
}

// Tabler icon font codepoints (the bar's icon font) for the menu.
@(private) ICON_OPEN     :: 0xEA99 // external-link
@(private) ICON_FOLDER   :: 0xFAF7 // folder-open
@(private) ICON_TERMINAL :: 0xEBEF // terminal-2
@(private) ICON_COPY     :: 0xEA7A // copy
@(private) ICON_RENAME   :: 0xEB04 // pencil
@(private) ICON_TRASH    :: 0xEB41 // trash

// The item a menu acts on, found again by name when the menu closes.
@(private)
Menu_Target :: struct {
	source: Item_Source,
	name:   string, // owned
}

// The CLIPBOARD while it holds a Copy path.
Clipboard_Owner :: struct {
	window: xlib.Window, // created on first use, never mapped
	text:   string,      // owned; "" = not the owner
	time:   xlib.Time,
}

@(private)
tr :: proc(d: ^Daemon, pt, en: string) -> string {
	return config.tr(d.cfg.bar.language, pt, en)
}

// ---------------------------------------------------------------------------
// Opening
// ---------------------------------------------------------------------------

// Open one icon: run a launcher, show a folder, open a file.
open_item :: proc(d: ^Daemon, it: ^Item) {
	switch {
	case it.launcher:
		launch(d, &it.shortcut)
	case it.kind == .Folder:
		open_folder(d, it.path)
	case it.kind == .Broken:
		log.warnf("%s is a broken link; nothing to open", it.path)
	case:
		spawn(d, {"xdg-open", it.path}, filepath.dir(it.path))
	}
}

// Open every selected icon.
open_selection :: proc(d: ^Daemon) {
	sel := selected_cells(d)
	if len(sel) > MAX_OPEN { log.warnf("Opening the first %d of %d selected icons", MAX_OPEN, len(sel)) }
	for i in sel[:min(len(sel), MAX_OPEN)] {
		open_item(d, &d.layer.items[d.layer.cells[i].entry])
	}
}

// Show a folder: wm.fileManager (a shell command, the quoted path appended),
// else Spoil next to the milk folder (bin/milk → ../../spoil/spoil), else
// spoil on $PATH, else xdg-open.
open_folder :: proc(d: ^Daemon, path: string) {
	if cmd := strings.trim_space(d.cfg.wm.file_manager); cmd != "" {
		spawn(d, {"sh", "-c", strings.concatenate({cmd, " ", shell_quote(path)}, context.temp_allocator)}, path)
	} else if spoil, found := spoil_path(); found {
		spawn(d, {spoil, path}, path)
	} else {
		spawn(d, {"xdg-open", path}, path)
	}
}

// wm.terminal (a shell command) started in `dir`.
open_terminal :: proc(d: ^Daemon, dir: string) {
	if cmd := strings.trim_space(d.cfg.wm.terminal); cmd != "" {
		spawn(d, {"sh", "-c", cmd}, dir)
	} else if prefix, found := terminal_prefix(); found {
		spawn(d, prefix[:1], dir)
	} else {
		log.error("No terminal emulator found")
	}
}

// Spoil, milk's file manager: next to the milk folder, else on $PATH.
@(private)
spoil_path :: proc() -> (string, bool) {
	if dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		path, _ := filepath.join({dir, "..", "..", "spoil", "spoil"}, context.temp_allocator)
		clean, _ := filepath.clean(path, context.temp_allocator)
		if is_executable_file(clean) { return clean, true }
	}
	return find_executable("spoil")
}

@(private)
spawn :: proc(d: ^Daemon, argv: []string, workdir: string) {
	dir := workdir if workdir != "" && os.is_directory(workdir) else home_dir()
	pid, ok := spawn_detached(argv, dir)
	if !ok { return }
	append(&d.children, pid)
	log.infof("Started %s", strings.join(argv, " ", context.temp_allocator))
}

// 'text' for sh -c.
@(private)
shell_quote :: proc(s: string) -> string {
	escaped, _ := strings.replace_all(s, "'", `'\''`, context.temp_allocator)
	return strings.concatenate({"'", escaped, "'"}, context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Context menu
// ---------------------------------------------------------------------------

// Right click on an icon: select it (unless it is part of the selection)
// and offer what applies to the selection.
desktop_context_menu :: proc(d: ^Daemon, index: int, be: ^xlib.XButtonEvent) {
	l := &d.layer
	if !l.cells[index].selected { layer_select(d, index) }
	l.cursor = index
	sel := selected_cells(d)
	files, folders := 0, 0
	for i in sel {
		it := &l.items[l.cells[i].entry]
		if it.source == .Folder { files += 1 }
		if it.kind == .Folder && !it.launcher { folders += 1 }
	}
	single := &l.items[l.cells[index].entry]
	items := make([dynamic]menu.Item, context.temp_allocator)
	open_icon := rune(ICON_FOLDER) if folders == len(sel) else rune(ICON_OPEN)
	append(&items, menu.Item{id = int(Menu_Action.Open), label = tr(d, "Abrir", "Open"), icon = open_icon})
	if len(sel) == 1 && folders == 1 {
		append(&items, menu.Item{id = int(Menu_Action.Open_Terminal), label = tr(d, "Abrir no terminal", "Open in terminal"), icon = ICON_TERMINAL})
	}
	append(&items, menu.Item{separator = true})
	copy_label := len(sel) > 1 ? tr(d, "Copiar caminhos", "Copy paths") : tr(d, "Copiar caminho", "Copy path")
	append(&items, menu.Item{id = int(Menu_Action.Copy_Path), label = copy_label, icon = ICON_COPY})
	if len(sel) == 1 && single.source == .Folder && !single.launcher {
		append(&items, menu.Item{id = int(Menu_Action.Rename), label = tr(d, "Renomear…", "Rename…"), icon = ICON_RENAME})
	}
	if files > 0 {
		append(&items, menu.Item{separator = true})
		append(&items, menu.Item{id = int(Menu_Action.Trash), label = tr(d, "Mover para a lixeira", "Move to Trash"), icon = ICON_TRASH})
	}
	menu_targets_clear(d)
	for i in sel {
		it := &l.items[l.cells[i].entry]
		append(&d.menu_targets, Menu_Target{it.source, strings.clone(it.name)})
	}
	if !menu.open(&d.menu, d.c, menu.style_from_config(d.cfg), items[:], be.x_root, be.y_root, be.time) {
		menu_targets_clear(d)
	}
}

// Forward an event to the open menu; true when it was the menu's.
desktop_menu_event :: proc(d: ^Daemon, ev: ^xlib.XEvent) -> bool {
	if !menu.is_open(&d.menu) { return false }
	if !menu.handle_event(&d.menu, ev) { return false }
	if id, chosen := menu.take_result(&d.menu); chosen {
		menu_run(d, Menu_Action(id))
	}
	if !menu.is_open(&d.menu) { menu_targets_clear(d) }
	return true
}

@(private)
menu_run :: proc(d: ^Daemon, action: Menu_Action) {
	l := &d.layer
	// The icons the menu was opened for, as they are now (a rescan may have run).
	targets := make([dynamic]int, context.temp_allocator)
	for t in d.menu_targets {
		for &cell, i in l.cells {
			if cell.source == t.source && cell.name == t.name { append(&targets, i) }
		}
	}
	if len(targets) == 0 { return }
	switch action {
	case .Open:
		for i in targets[:min(len(targets), MAX_OPEN)] { open_item(d, &l.items[l.cells[i].entry]) }
	case .Open_Terminal:
		open_terminal(d, l.items[l.cells[targets[0]].entry].path)
	case .Copy_Path:
		paths := make([dynamic]string, context.temp_allocator)
		for i in targets { append(&paths, l.items[l.cells[i].entry].path) }
		clipboard_set(d, strings.join(paths[:], "\n", context.temp_allocator))
	case .Rename:
		rename_start(d, targets[0])
	case .Trash:
		trash_cells(d, targets[:])
	}
}

@(private)
menu_targets_clear :: proc(d: ^Daemon) {
	for t in d.menu_targets { delete(t.name) }
	clear(&d.menu_targets)
}

// ---------------------------------------------------------------------------
// Clipboard (Copy path)
// ---------------------------------------------------------------------------

// Own CLIPBOARD with `text` (UTF-8).
clipboard_set :: proc(d: ^Daemon, text: string) {
	cb := &d.clipboard
	c := d.c
	if len(text) > MAX_CLIPBOARD {
		log.warnf("Not copying %d bytes of paths to the clipboard", len(text))
		return
	}
	if cb.window == 0 {
		cb.window = tx.create_overlay(c, {-10, -10, 1, 1}, {}, "_NET_WM_WINDOW_TYPE_UTILITY", "milk desktop clipboard")
	}
	delete(cb.text)
	cb.text = strings.clone(text)
	cb.time = d.last_time
	xlib.SetSelectionOwner(c.dpy, tx.atom(c, "CLIPBOARD"), cb.window, cb.time)
	if xlib.GetSelectionOwner(c.dpy, tx.atom(c, "CLIPBOARD")) != cb.window {
		log.warn("Could not take the clipboard")
		delete(cb.text)
		cb.text = ""
	}
}

clipboard_destroy :: proc(d: ^Daemon) {
	cb := &d.clipboard
	if cb.window != 0 { tx.destroy_window(d.c, cb.window) }
	delete(cb.text)
	cb^ = {}
}

// Selection requests and the loss of CLIPBOARD; true when the event was ours.
clipboard_event :: proc(d: ^Daemon, ev: ^xlib.XEvent) -> bool {
	cb := &d.clipboard
	if cb.window == 0 { return false }
	#partial switch ev.type {
	case .SelectionClear:
		if ev.xselectionclear.window != cb.window { return false }
		delete(cb.text)
		cb.text = ""
		return true
	case .SelectionRequest:
		req := &ev.xselectionrequest
		if req.owner != cb.window { return false }
		reply: xlib.XEvent
		reply.xselection = xlib.XSelectionEvent{
			type = .SelectionNotify, requestor = req.requestor, selection = req.selection,
			target = req.target, property = 0, time = req.time,
		}
		prop := req.property != 0 ? req.property : req.target // obsolete clients pass None
		if cb.text != "" && req.selection == tx.atom(d.c, "CLIPBOARD") && clipboard_serve(d, req.requestor, prop, req.target) {
			reply.xselection.property = prop
		}
		xlib.SendEvent(d.c.dpy, req.requestor, false, {}, &reply)
		tx.flush(d.c)
		return true
	}
	return false
}

@(private)
clipboard_serve :: proc(d: ^Daemon, requestor: xlib.Window, prop, target: xlib.Atom) -> bool {
	c := d.c
	cb := &d.clipboard
	utf8 := tx.atom(c, "UTF8_STRING")
	switch target {
	case tx.atom(c, "TARGETS"):
		list := []xlib.Atom{tx.atom(c, "TARGETS"), tx.atom(c, "TIMESTAMP"), utf8, tx.atom(c, "text/plain;charset=utf-8"),
		                    tx.atom(c, "text/plain"), tx.ATOM_STRING, tx.atom(c, "TEXT")}
		xlib.ChangeProperty(c.dpy, requestor, prop, tx.ATOM_ATOM, 32, tx.PROP_MODE_REPLACE, raw_data(list), i32(len(list)))
	case tx.atom(c, "TIMESTAMP"):
		v := uint(cb.time)
		xlib.ChangeProperty(c.dpy, requestor, prop, tx.atom(c, "INTEGER"), 32, tx.PROP_MODE_REPLACE, &v, 1)
	case utf8, tx.atom(c, "TEXT"), tx.atom(c, "text/plain;charset=utf-8"), tx.atom(c, "text/plain"):
		type := target == tx.atom(c, "TEXT") ? utf8 : target
		xlib.ChangeProperty(c.dpy, requestor, prop, type, 8, tx.PROP_MODE_REPLACE, raw_data(cb.text), i32(len(cb.text)))
	case tx.ATOM_STRING:
		latin := make([dynamic]u8, 0, len(cb.text), context.temp_allocator)
		for r in cb.text { append(&latin, r < 256 ? u8(r) : '?') }
		xlib.ChangeProperty(c.dpy, requestor, prop, tx.ATOM_STRING, 8, tx.PROP_MODE_REPLACE, raw_data(latin), i32(len(latin)))
	case:
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Trash
// ---------------------------------------------------------------------------

// Move the selected folder files to the trash (Delete).
trash_selection :: proc(d: ^Daemon) {
	trash_cells(d, selected_cells(d))
}

@(private)
trash_cells :: proc(d: ^Daemon, cells: []int) {
	moved := 0
	for i in cells {
		it := &d.layer.items[d.layer.cells[i].entry]
		if it.source != .Folder { continue }
		if trash_file(it.path) { moved += 1 }
	}
	if moved > 0 {
		log.infof("Moved %d item(s) to the trash", moved)
		files_rescan_now(d)
	}
}

// Move `path` into the home trash ($XDG_DATA_HOME/Trash, freedesktop Trash
// specification 1.0): a free name is reserved by creating its .trashinfo
// with O_EXCL, then the file is renamed into files/. A rename cannot cross
// file systems, so a file on another device than the trash is refused.
trash_file :: proc(path: string) -> bool {
	trash := join_path({data_home(), "Trash"})
	files_dir := join_path({trash, "files"})
	info_dir := join_path({trash, "info"})
	for dir in ([]string{trash, files_dir, info_dir}) {
		if !os.is_directory(dir) { os.make_directory_all(dir, os.perm_number(0o700)) }
	}
	if !os.is_directory(files_dir) || !os.is_directory(info_dir) {
		log.errorf("Cannot create the trash in %s", trash)
		return false
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	st, trash_st: posix.stat_t
	if posix.lstat(cpath, &st) != .OK {
		log.warnf("Cannot move %s to the trash: it no longer exists", path)
		return false
	}
	if posix.stat(strings.clone_to_cstring(files_dir, context.temp_allocator), &trash_st) != .OK || st.st_dev != trash_st.st_dev {
		log.warnf("Not moving %s to the trash: it is on another file system than %s", path, trash)
		return false
	}
	base := os.base(path)
	stem, ext := base, ""
	if dot := strings.last_index_byte(base, '.'); dot > 0 { stem, ext = base[:dot], base[dot:] }
	info_text := fmt.tprintf("[Trash Info]\nPath=%s\nDeletionDate=%s\n", uri_escape_path(path), local_timestamp())
	for n in 1 ..< 10_000 {
		name := base if n == 1 else fmt.tprintf("%s.%d%s", stem, n, ext)
		info := strings.clone_to_cstring(join_path({info_dir, strings.concatenate({name, ".trashinfo"}, context.temp_allocator)}), context.temp_allocator)
		fd := posix.open(info, {.WRONLY, .CREAT, .EXCL}, {.IRUSR, .IWUSR})
		if fd < 0 {
			if posix.errno() == .EEXIST { continue }
			log.errorf("Cannot write the trash information for %s: %v", path, posix.errno())
			return false
		}
		target := strings.clone_to_cstring(join_path({files_dir, name}), context.temp_allocator)
		taken: posix.stat_t
		if posix.lstat(target, &taken) == .OK {
			posix.close(fd)
			posix.unlink(info)
			continue
		}
		written := posix.write(fd, raw_data(info_text), uint(len(info_text)))
		posix.close(fd)
		if written != int(len(info_text)) {
			posix.unlink(info)
			log.errorf("Cannot write the trash information for %s", path)
			return false
		}
		if posix.rename(cpath, target) != 0 {
			err := posix.errno()
			posix.unlink(info)
			log.errorf("Cannot move %s to the trash: %v", path, err)
			return false
		}
		return true
	}
	return false
}

// Percent-encode a path for a .trashinfo (RFC 2396, '/' kept).
@(private)
uri_escape_path :: proc(path: string) -> string {
	b := strings.builder_make(0, len(path), context.temp_allocator)
	for i in 0 ..< len(path) {
		ch := path[i]
		switch ch {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.', '~', '/':
			strings.write_byte(&b, ch)
		case:
			fmt.sbprintf(&b, "%%%02X", ch)
		}
	}
	return strings.to_string(b)
}

// The local time as YYYY-MM-DDThh:mm:ss (DeletionDate).
@(private)
local_timestamp :: proc() -> string {
	now := posix.time(nil)
	tm: posix.tm
	posix.localtime_r(&now, &tm)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02d", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec)
}

// ---------------------------------------------------------------------------
// Requests from the window manager's root menu
// ---------------------------------------------------------------------------

// Run a root-menu action: "desktop-new-folder" (a new folder in the desktop
// folder, selected and ready to be renamed), "desktop-arrange" (forget the
// saved places and lay the icons out in `sort` order) or
// "desktop-open-folder" (the desktop folder in the file manager).
request :: proc(d: ^Daemon, action: string) {
	context.allocator = d.allocator
	switch action {
	case "desktop-new-folder":
		new_folder(d)
	case "desktop-arrange":
		if !d.files.enabled || len(d.layer.items) == 0 { return }
		places_forget_shown(d)
		layer_sync(d, false)
	case "desktop-open-folder":
		dir := desktop_folder(d)
		ensure_dir(dir)
		open_folder(d, dir)
	case:
		log.warnf("Unknown desktop request %q", action)
	}
	tx.flush(d.c)
}

// The folder the desktop shows (the XDG Desktop folder when icons are off).
@(private)
desktop_folder :: proc(d: ^Daemon) -> string {
	return d.files.dir if d.files.enabled else desktop_dir()
}

@(private)
new_folder :: proc(d: ^Daemon) {
	dir := desktop_folder(d)
	if !ensure_dir(dir) { return }
	base := tr(d, "Nova pasta", "New folder")
	for n in 1 ..< 1000 {
		name := base if n == 1 else fmt.tprintf("%s (%d)", base, n)
		path := strings.clone_to_cstring(join_path({dir, name}), context.temp_allocator)
		if posix.mkdir(path, {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH}) != .OK {
			if posix.errno() == .EEXIST { continue }
			log.errorf("Cannot create a folder in %s: %v", dir, posix.errno())
			return
		}
		log.infof("Created %s", join_path({dir, name}))
		if d.files.enabled {
			delete(d.layer.pending_select)
			d.layer.pending_select = strings.clone(name)
			d.layer.pending_rename = true
			files_rescan_now(d)
		}
		return
	}
}
