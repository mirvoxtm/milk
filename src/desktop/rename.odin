// Inline renaming of a desktop file (F2, or Rename… in the context menu): a
// text field over the icon's label, in the bar's theme. While it is open it
// grabs the keyboard and the pointer (events on milk's own windows still go
// to them): Enter or a click elsewhere renames, Escape cancels. Dead keys
// compose through tx's input method. It opens with the name selected up to
// the extension and renames with renameat2(RENAME_NOREPLACE), so an
// existing file is never overwritten: the field turns red and stays open.
package desktop

import "core:log"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "core:unicode/utf8"
import xlib "vendor:x11/xlib"
import tx "../tx"

@(private) RENAME_PAD    :: 6
@(private) RENAME_RADIUS :: 6

Rename_Editor :: struct {
	active:  bool,
	window:  xlib.Window,
	pixmap:  xlib.Pixmap,
	input:   tx.Input,
	rect:    tx.Rect,
	dir:     string,      // the folder (owned)
	name:    string,      // the file's current name (owned)
	text:    [dynamic]u8, // what is typed (UTF-8)
	caret:   int,         // byte offset
	anchor:  int,         // other end of the selection; == caret: none
	scroll:  i32,         // horizontal text offset, pixels
	failed:  bool,        // the name was refused: warning outline
}

foreign import xft_rename "system:Xft"
@(default_calling_convention = "c")
foreign xft_rename {
	@(private) XftDrawSetClipRectangles :: proc(draw: ^tx.XftDraw, x, y: i32, rects: [^]xlib.XRectangle, n: i32) -> b32 ---
}

// Edit the name of the file shown by cell `index` (desktop folder entries,
// launchers excepted).
rename_start :: proc(d: ^Daemon, index: int) {
	l := &d.layer
	if !d.files.enabled || index < 0 || index >= len(l.cells) || l.font == nil { return }
	it := &l.items[l.cells[index].entry]
	if it.source != .Folder || it.launcher { return }
	rename_cancel(d)
	c := d.c
	ed := &d.rename
	cell := &l.cells[index]
	w := max(l.cell_w + 48, 180)
	h := l.font.ascent + l.font.descent + 2 * RENAME_PAD
	x := cell.rect.x + (cell.rect.w - w) / 2
	y := cell.rect.y + l.pad + l.icon_size + 2
	screen := tx.screen_rect(c)
	x = clamp(x, 2, max(2, screen.w - w - 2))
	ed.rect = {x, y, w, h}
	ed.window = tx.create_overlay(c, ed.rect, {.ButtonPress, .ButtonRelease, .KeyPress, .KeyRelease},
	                              "_NET_WM_WINDOW_TYPE_UTILITY", "milk: rename")
	tx.shape_rounded(c, ed.window, w, h, RENAME_RADIUS)
	ed.dir = strings.clone(d.files.dir)
	ed.name = strings.clone(it.name)
	clear(&ed.text)
	append(&ed.text, ..transmute([]u8)it.name)
	// The name up to its extension is selected (all of it for folders and dot files).
	stem := len(ed.text)
	if it.kind != .Folder {
		if dot := strings.last_index_byte(it.name, '.'); dot > 0 { stem = dot }
	}
	ed.anchor, ed.caret = 0, stem
	ed.scroll = 0
	ed.failed = false
	ed.active = true
	tx.map_window(c, ed.window)
	tx.raise_window(c, ed.window)
	rename_paint(d)
	tx.sync(c)
	if !rename_grab(d) {
		log.warn("Cannot rename: the keyboard is grabbed by another program")
		rename_close(d)
		return
	}
	ed.input = tx.input_open(c, ed.window)
	tx.input_focus(&ed.input, true)
	tx.flush(c)
}

// Close the editor without renaming.
rename_cancel :: proc(d: ^Daemon) {
	if d.rename.active { rename_close(d) }
}

rename_destroy :: proc(d: ^Daemon) {
	rename_cancel(d)
	delete(d.rename.text)
	d.rename.text = nil
}

// Events while the editor is open; true when the event was the editor's.
rename_event :: proc(d: ^Daemon, ev: ^xlib.XEvent) -> bool {
	ed := &d.rename
	if !ed.active { return false }
	#partial switch ev.type {
	case .KeyPress:
		if ev.xkey.window != ed.window { return false }
		rename_key(d, &ev.xkey)
		return true
	case .KeyRelease:
		return ev.xkey.window == ed.window
	case .ButtonPress:
		be := &ev.xbutton
		inside := be.window == ed.window && be.x >= 0 && be.y >= 0 && be.x < ed.rect.w && be.y < ed.rect.h
		if inside {
			if be.button == .Button1 {
				ed.caret = rename_offset_at(d, be.x)
				ed.anchor = ed.caret
				rename_paint(d)
				tx.flush(d.c)
			}
			return true
		}
		// A click anywhere else renames; it still reaches milk's own windows.
		rename_commit(d)
		return be.window == ed.window
	case .ButtonRelease:
		return ev.xbutton.window == ed.window
	case .Expose:
		return ev.xexpose.window == ed.window
	}
	return false
}

@(private)
rename_grab :: proc(d: ^Daemon) -> bool {
	c := d.c
	ed := &d.rename
	for attempt in 0 ..< 20 {
		if xlib.GrabKeyboard(c.dpy, ed.window, false, .GrabModeAsync, .GrabModeAsync, xlib.CurrentTime) == 0 { break }
		if attempt == 19 { return false }
		time.sleep(10 * time.Millisecond)
	}
	// owner_events: clicks on milk's windows go to them, the others come here.
	mask := xlib.EventMask{.ButtonPress, .ButtonRelease}
	if xlib.GrabPointer(c.dpy, ed.window, true, mask, .GrabModeAsync, .GrabModeAsync, 0, 0, xlib.CurrentTime) != 0 {
		log.debug("Rename: could not grab the pointer; a click elsewhere will not end the edit")
	}
	return true
}

@(private)
rename_close :: proc(d: ^Daemon) {
	ed := &d.rename
	c := d.c
	xlib.UngrabKeyboard(c.dpy, xlib.CurrentTime)
	xlib.UngrabPointer(c.dpy, xlib.CurrentTime)
	tx.input_close(&ed.input)
	if ed.window != 0 {
		tx.unmap_window(c, ed.window)
		tx.destroy_window(c, ed.window)
	}
	tx.pixmap_free(c, ed.pixmap)
	delete(ed.dir)
	delete(ed.name)
	text := ed.text
	clear(&text)
	ed^ = {text = text}
	tx.flush(c)
}

// Rename to what was typed; a refused name keeps the editor open.
@(private)
rename_commit :: proc(d: ^Daemon) {
	ed := &d.rename
	name := string(ed.text[:])
	if name == ed.name {
		rename_close(d)
		return
	}
	if name == "" || name == "." || name == ".." || strings.index_byte(name, '/') >= 0 || len(name) > 255 {
		rename_refuse(d)
		return
	}
	old_path := strings.clone_to_cstring(join_path({ed.dir, ed.name}), context.temp_allocator)
	new_path := strings.clone_to_cstring(join_path({ed.dir, name}), context.temp_allocator)
	if err := linux.renameat2(linux.AT_FDCWD, old_path, linux.AT_FDCWD, new_path, {.NOREPLACE}); err != .NONE {
		if err == .EEXIST {
			rename_refuse(d)
			return
		}
		log.errorf("Cannot rename %s to %s: %v", ed.name, name, err)
		rename_close(d)
		return
	}
	log.infof("Renamed %s to %s", ed.name, name)
	place_rename(d, ed.name, name)
	areas_rename(d, ed.name, name)
	delete(d.layer.pending_select)
	d.layer.pending_select = strings.clone(name)
	rename_close(d)
	files_rescan_now(d)
}

@(private)
rename_refuse :: proc(d: ^Daemon) {
	d.rename.failed = true
	rename_paint(d)
	tx.flush(d.c)
}

@(private)
rename_key :: proc(d: ^Daemon, ke: ^xlib.XKeyEvent) {
	ed := &d.rename
	text, sym := tx.input_lookup(&ed.input, ke)
	ctrl := .ControlMask in ke.state
	shift := .ShiftMask in ke.state
	#partial switch sym {
	case .XK_Return, .XK_KP_Enter:
		rename_commit(d)
		return
	case .XK_Escape:
		rename_close(d)
		return
	case .XK_BackSpace:
		if !rename_delete_selection(ed) && ed.caret > 0 {
			_, size := utf8.decode_last_rune(ed.text[:ed.caret])
			remove_range(&ed.text, ed.caret - size, ed.caret)
			ed.caret -= size
			ed.anchor = ed.caret
		}
	case .XK_Delete, .XK_KP_Delete:
		if !rename_delete_selection(ed) && ed.caret < len(ed.text) {
			_, size := utf8.decode_rune(ed.text[ed.caret:])
			remove_range(&ed.text, ed.caret, ed.caret + size)
		}
	case .XK_Left, .XK_KP_Left:
		if ed.caret != ed.anchor && !shift {
			ed.caret = min(ed.caret, ed.anchor)
		} else if ed.caret > 0 {
			_, size := utf8.decode_last_rune(ed.text[:ed.caret])
			ed.caret -= size
		}
		if !shift { ed.anchor = ed.caret }
	case .XK_Right, .XK_KP_Right:
		if ed.caret != ed.anchor && !shift {
			ed.caret = max(ed.caret, ed.anchor)
		} else if ed.caret < len(ed.text) {
			_, size := utf8.decode_rune(ed.text[ed.caret:])
			ed.caret += size
		}
		if !shift { ed.anchor = ed.caret }
	case .XK_Home, .XK_KP_Home:
		ed.caret = 0
		if !shift { ed.anchor = 0 }
	case .XK_End, .XK_KP_End:
		ed.caret = len(ed.text)
		if !shift { ed.anchor = ed.caret }
	case .XK_a:
		if ctrl {
			ed.anchor, ed.caret = 0, len(ed.text)
		} else {
			rename_insert(ed, text)
		}
	case:
		if !ctrl { rename_insert(ed, text) }
	}
	ed.failed = false
	rename_paint(d)
	tx.flush(d.c)
}

// Replace the selection with typed text (control characters dropped).
@(private)
rename_insert :: proc(ed: ^Rename_Editor, text: string) {
	clean := make([dynamic]u8, 0, len(text), context.temp_allocator)
	for r in text {
		if r < 0x20 || r == 0x7F { continue }
		bytes, n := utf8.encode_rune(r)
		append(&clean, ..bytes[:n])
	}
	if len(clean) == 0 { return }
	rename_delete_selection(ed)
	inject_at(&ed.text, ed.caret, ..clean[:])
	ed.caret += len(clean)
	ed.anchor = ed.caret
}

@(private)
rename_delete_selection :: proc(ed: ^Rename_Editor) -> bool {
	if ed.caret == ed.anchor { return false }
	lo, hi := min(ed.caret, ed.anchor), max(ed.caret, ed.anchor)
	remove_range(&ed.text, lo, hi)
	ed.caret, ed.anchor = lo, lo
	return true
}

// The byte offset closest to x (window coordinates).
@(private)
rename_offset_at :: proc(d: ^Daemon, x: i32) -> int {
	ed := &d.rename
	font := d.layer.font
	text := string(ed.text[:])
	target := x - RENAME_PAD + ed.scroll
	best, best_dist := 0, abs(target)
	for _, i in text {
		if i == 0 { continue }
		dist := abs(tx.text_width(d.c, font, text[:i]) - target)
		if dist < best_dist { best, best_dist = i, dist }
	}
	if dist := abs(tx.text_width(d.c, font, text) - target); dist < best_dist { best = len(text) }
	return best
}

@(private)
rename_paint :: proc(d: ^Daemon) {
	ed := &d.rename
	c := d.c
	font := d.layer.font
	theme := &d.cfg.bar.theme
	bg := tx.color_from_hex(theme.background, tx.rgb(0xF5, 0xEE, 0xE6))
	fg := tx.color_from_hex(theme.foreground, tx.rgb(0x3C, 0x3A, 0x38))
	accent := tx.color_from_hex(theme.accent, tx.rgb(0x4A, 0x3F, 0x35))
	accent_fg := tx.color_from_hex(theme.accent_foreground, tx.rgb(0xF5, 0xEE, 0xE6))
	warning := tx.color_from_hex(theme.warning, tx.rgb(0xB5, 0x47, 0x3A))
	w, h := ed.rect.w, ed.rect.h
	text := string(ed.text[:])
	inner := w - 2 * RENAME_PAD
	caret_x := tx.text_width(c, font, text[:ed.caret])
	if caret_x - ed.scroll > inner - 1 { ed.scroll = caret_x - inner + 1 }
	if caret_x - ed.scroll < 0 { ed.scroll = caret_x }
	ed.scroll = max(0, min(ed.scroll, max(0, tx.text_width(c, font, text) - inner + 1)))

	cv := tx.canvas_make(w, h, context.temp_allocator)
	tx.canvas_fill(&cv, bg)
	tx.canvas_stroke_rounded_rect(&cv, {0, 0, w, h}, RENAME_RADIUS, ed.failed ? 2 : 1, ed.failed ? warning : accent)
	lo, hi := min(ed.caret, ed.anchor), max(ed.caret, ed.anchor)
	x0 := RENAME_PAD - ed.scroll
	sel_x := x0 + tx.text_width(c, font, text[:lo])
	sel_w := tx.text_width(c, font, text[lo:hi])
	if hi > lo {
		sel, _ := tx.rect_intersect({sel_x, 3, sel_w, h - 6}, {RENAME_PAD - 1, 0, inner + 2, h})
		tx.canvas_fill_rect(&cv, sel, accent)
	} else {
		tx.canvas_fill_rect(&cv, {x0 + caret_x, 4, 1, h - 8}, fg)
	}
	pm := tx.canvas_to_pixmap(c, cv)
	ts := tx.text_surface_make(c, xlib.Drawable(pm))
	clip := xlib.XRectangle{RENAME_PAD, 0, u16(inner), u16(h)}
	XftDrawSetClipRectangles(ts.draw, 0, 0, &clip, 1)
	baseline := (h - font.ascent - font.descent) / 2 + font.ascent
	tx.draw_text(&ts, font, x0, baseline, text[:lo], fg)
	tx.draw_text(&ts, font, sel_x, baseline, text[lo:hi], accent_fg)
	tx.draw_text(&ts, font, sel_x + sel_w, baseline, text[hi:], fg)
	tx.text_surface_destroy(&ts)
	tx.set_background(c, ed.window, pm)
	tx.pixmap_free(c, ed.pixmap)
	ed.pixmap = pm
}
