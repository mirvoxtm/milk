// Package clip: clipboard history for milk (text and images) and its panel.
//
// A hidden window watches the CLIPBOARD selection through XFixes. Every time
// another client takes ownership, milk asks for TARGETS and fetches the best
// representation (an image when the source offers no plain text, else text),
// INCR transfers included, and puts it at the top of the history. Clicking an
// entry in the panel makes milk the CLIPBOARD owner again and serves that entry
// to whoever pastes. When the source application exits, milk takes over the
// clipboard with its copy so the content survives.
//
// Integration: create → start; offer every X event to handle_event (it claims
// only its own windows, XFixes events and the requestor windows of its INCR
// transfers); call tick every loop iteration and sleep at most next_timeout.
package clip

import "base:runtime"
import "core:log"
import "core:path/filepath"
import xlib "vendor:x11/xlib"
import tx "../tx"
import config "../config"

// ---------------------------------------------------------------------------
// XFixes (selection owner notifications)
// ---------------------------------------------------------------------------
foreign import xfixes "system:Xfixes"

@(private) XFIXES_SET_SELECTION_OWNER_NOTIFY_MASK      :: uint(1 << 0)
@(private) XFIXES_SELECTION_WINDOW_DESTROY_NOTIFY_MASK :: uint(1 << 1)
@(private) XFIXES_SELECTION_CLIENT_CLOSE_NOTIFY_MASK   :: uint(1 << 2)
@(private) XFIXES_SELECTION_NOTIFY                     :: 0 // event offset from the extension's event base
@(private) XFIXES_SUBTYPE_SET_OWNER                    :: 0
@(private) XFIXES_SUBTYPE_WINDOW_DESTROY               :: 1
@(private) XFIXES_SUBTYPE_CLIENT_CLOSE                 :: 2

@(private)
XFixesSelectionNotifyEvent :: struct {
	type:                i32,
	serial:              uint,
	send_event:          b32,
	display:             ^xlib.Display,
	window:              xlib.Window,
	subtype:             i32,
	owner:               xlib.Window,
	selection:           xlib.Atom,
	timestamp:           xlib.Time,
	selection_timestamp: xlib.Time,
}

@(default_calling_convention="c")
foreign xfixes {
	@(private) XFixesQueryExtension       :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	@(private) XFixesQueryVersion         :: proc(dpy: ^xlib.Display, major, minor: ^i32) -> i32 ---
	@(private) XFixesSelectSelectionInput :: proc(dpy: ^xlib.Display, win: xlib.Window, selection: xlib.Atom, event_mask: uint) ---
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------
@(private) FETCH_TIMEOUT    :: 4.0  // seconds without progress before a fetch is abandoned
@(private) TRANSFER_TIMEOUT :: 10.0 // seconds without progress before an outgoing INCR is dropped
@(private) SAVE_DELAY       :: 0.6  // debounce for writing the history to disk
@(private) TEXT_LIMIT       :: 16 * 1024 * 1024
@(private) INCR_CHUNK       :: 256 * 1024

Kind :: enum u8 { Text, Image }

@(private)
Thumb_State :: enum u8 { None, Ready, Failed }

// One history entry. `data` is UTF-8 text or the encoded image (PNG, or the
// source's JPEG/BMP bytes when they could not be converted).
Item :: struct {
	id:          u64,
	kind:        Kind,
	mime:        string, // "text/plain;charset=utf-8", "image/png", "image/jpeg", "image/bmp"
	data:        []u8,
	hash:        u64,
	w, h:        i32,    // image size in pixels
	pinned:      bool,
	saved:       bool,   // its file exists in the store
	thumb:       tx.Image,
	thumb_state: Thumb_State,
	preview:     []string, // cached wrapped text lines (panel)
}

@(private)
Atoms :: struct {
	clipboard, targets, timestamp, multiple, incr, integer, utf8, text, text_plain_utf8, text_plain: xlib.Atom,
	png, jpeg, bmp, secret: xlib.Atom,
	props: [4]xlib.Atom, // rotating properties for incoming conversions
}

@(private)
Fetch_Stage :: enum u8 { Idle, Targets, Data, Incr }

@(private)
Fetch :: struct {
	stage:    Fetch_Stage,
	prop:     xlib.Atom,
	serial:   int,
	target:   xlib.Atom,
	queue:    [dynamic]xlib.Atom, // remaining candidate targets, best first
	buf:      [dynamic]u8,
	overflow: bool,
	deadline: f64,
}

// What milk serves while it owns CLIPBOARD.
@(private)
Owned :: struct {
	active: bool,
	id:     u64,
	kind:   Kind,
	mime:   string,
	data:   []u8,
	png:    []u8, // image/png rendition of a JPEG/BMP item (encoded on demand)
	time:   xlib.Time,
}

// An outgoing INCR transfer.
@(private)
Transfer :: struct {
	requestor:  xlib.Window,
	property:   xlib.Atom,
	type:       xlib.Atom,
	data:       []u8,
	offset:     int,
	added_mask: bool, // we added PropertyChange to our mask on the requestor
	deadline:   f64,
}

Clipboard :: struct {
	c:                 ^tx.Connection,
	cfg:               ^config.Config, // owned by the caller
	allocator:         runtime.Allocator,
	dir:               string, // <runtime>/Clipboard
	started:           bool,
	watching:          bool,
	win:               xlib.Window, // hidden, never mapped
	has_xfixes:        bool,
	event_base:        i32,
	atoms:             Atoms,
	items:             [dynamic]^Item, // newest first
	next_id:           u64,
	current:           u64, // id of the item that matches the clipboard now (0 = unknown)
	fetch:             Fetch,
	owned:             Owned,
	transfers:         [dynamic]Transfer,
	incr_threshold:    int, // bytes; larger replies use INCR
	save_due:          f64, // -1 = nothing to save
	panel:             Panel,
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
create :: proc(c: ^tx.Connection, cfg: ^config.Config, runtime_root: string) -> (^Clipboard, bool) {
	if c == nil || cfg == nil { return nil, false }
	cb := new(Clipboard)
	cb.c = c
	cb.cfg = cfg
	cb.allocator = context.allocator
	cb.dir, _ = filepath.join({runtime_root, "Clipboard"}, context.allocator)
	cb.next_id = 1
	cb.save_due = -1
	cb.panel.hover_item = -1
	cb.panel.hover_hit = -1
	a := &cb.atoms
	a.clipboard = tx.atom(c, "CLIPBOARD")
	a.targets = tx.atom(c, "TARGETS")
	a.timestamp = tx.atom(c, "TIMESTAMP")
	a.multiple = tx.atom(c, "MULTIPLE")
	a.incr = tx.atom(c, "INCR")
	a.integer = xlib.Atom(19) // INTEGER
	a.utf8 = tx.atom(c, "UTF8_STRING")
	a.text = tx.atom(c, "TEXT")
	a.text_plain_utf8 = tx.atom(c, "text/plain;charset=utf-8")
	a.text_plain = tx.atom(c, "text/plain")
	a.png = tx.atom(c, "image/png")
	a.jpeg = tx.atom(c, "image/jpeg")
	a.bmp = tx.atom(c, "image/bmp")
	a.secret = tx.atom(c, "x-kde-passwordManagerHint")
	for i in 0 ..< len(a.props) { a.props[i] = tx.atom(c, i == 0 ? "MILK_CLIP_0" : i == 1 ? "MILK_CLIP_1" : i == 2 ? "MILK_CLIP_2" : "MILK_CLIP_3") }
	req := xlib.ExtendedMaxRequestSize(c.dpy)
	if req == 0 { req = xlib.MaxRequestSize(c.dpy) }
	cb.incr_threshold = clamp(int(req) * 4 - 1024, 4096, INCR_CHUNK)
	return cb, true
}

destroy :: proc(cb: ^Clipboard) {
	if cb == nil { return }
	context.allocator = cb.allocator
	close_panel(cb)
	panel_destroy(cb)
	if cb.save_due >= 0 { save_history(cb) }
	fetch_reset(cb)
	delete(cb.fetch.queue)
	delete(cb.fetch.buf)
	owned_clear(cb)
	for i := len(cb.transfers) - 1; i >= 0; i -= 1 { transfer_remove(cb, i) }
	delete(cb.transfers)
	if cb.win != 0 {
		if cb.watching && cb.has_xfixes { XFixesSelectSelectionInput(cb.c.dpy, cb.win, cb.atoms.clipboard, 0) }
		tx.destroy_window(cb.c, cb.win)
	}
	for it in cb.items { item_free(it) }
	delete(cb.items)
	delete(cb.dir)
	free(cb)
}

// Create the hidden window, subscribe to CLIPBOARD owner changes and load the history.
start :: proc(cb: ^Clipboard) {
	if cb == nil || cb.started { return }
	context.allocator = cb.allocator
	c := cb.c
	cb.started = true
	cb.win = tx.create_overlay(c, {-100, -100, 1, 1}, {.PropertyChange}, "_NET_WM_WINDOW_TYPE_UTILITY", "milk clipboard")
	err_base: i32
	if XFixesQueryExtension(c.dpy, &cb.event_base, &err_base) {
		major, minor: i32 = 5, 0
		XFixesQueryVersion(c.dpy, &major, &minor)
		cb.has_xfixes = true
	} else {
		log.warn("Clipboard: the XFixes extension is missing; clipboard history is off")
	}
	if cb.cfg.clipboard.persist { load_history(cb) }
	update_watch(cb)
	tx.flush(c)
}

// Returns true when the event belonged to the clipboard alone.
handle_event :: proc(cb: ^Clipboard, ev: ^xlib.XEvent) -> bool {
	if cb == nil || !cb.started || ev == nil { return false }
	context.allocator = cb.allocator
	if cb.has_xfixes && i32(ev.type) == cb.event_base + XFIXES_SELECTION_NOTIFY {
		xe := (^XFixesSelectionNotifyEvent)(ev)
		if xe.window != cb.win { return false }
		on_owner_change(cb, xe)
		tx.flush(cb.c)
		return true
	}
	// The outside-click guard only covers the dispatch of the click that closed the panel.
	cb.panel.closed_now = false
	win := ev.xany.window
	if ev.type == .ButtonPress {
		// A click on another window (the bar, the desktop, a client) closes the panel,
		// unless it is the very click that opened it (the bar may see it first).
		if cb.panel.open && win != cb.panel.win && ev.xbutton.serial >= cb.panel.open_serial {
			close_panel(cb)
			cb.panel.closed_now = true
			return false
		}
	}
	claimed := false
	switch {
	case win == cb.win && cb.win != 0:
		#partial switch ev.type {
		case .SelectionNotify:  on_selection_notify(cb, &ev.xselection)
		case .SelectionRequest: on_selection_request(cb, &ev.xselectionrequest)
		case .SelectionClear:   on_selection_clear(cb, &ev.xselectionclear)
		case .PropertyNotify:   on_own_property(cb, &ev.xproperty)
		}
		claimed = true
	case cb.panel.win != 0 && win == cb.panel.win:
		panel_event(cb, ev)
		claimed = true
	case ev.type == .PropertyNotify && len(cb.transfers) > 0:
		claimed = on_transfer_property(cb, &ev.xproperty)
	}
	if claimed { tx.flush(cb.c) }
	return claimed
}

tick :: proc(cb: ^Clipboard, now: f64) {
	if cb == nil || !cb.started { return }
	context.allocator = cb.allocator
	if cb.fetch.stage != .Idle && now >= cb.fetch.deadline {
		log.debugf("Clipboard: the owner stopped answering (%v); giving up", cb.fetch.stage)
		fetch_reset(cb)
	}
	for i := len(cb.transfers) - 1; i >= 0; i -= 1 {
		if now >= cb.transfers[i].deadline {
			log.debug("Clipboard: an INCR transfer timed out")
			transfer_remove(cb, i)
		}
	}
	if cb.save_due >= 0 && now >= cb.save_due { save_history(cb) }
	panel_tick(cb, now)
}

next_timeout :: proc(cb: ^Clipboard, now: f64) -> f64 {
	if cb == nil || !cb.started { return -1 }
	best := -1.0
	consider :: proc(best: ^f64, deadline, now: f64) {
		d := max(deadline - now, 0)
		if best^ < 0 || d < best^ { best^ = d }
	}
	if cb.fetch.stage != .Idle { consider(&best, cb.fetch.deadline, now) }
	for t in cb.transfers { consider(&best, t.deadline, now) }
	if cb.save_due >= 0 { consider(&best, cb.save_due, now) }
	if panel_animating(cb) { consider(&best, now + 1.0 / 60, now) }
	return best
}

reload :: proc(cb: ^Clipboard, cfg: ^config.Config) {
	if cb == nil || cfg == nil { return }
	context.allocator = cb.allocator
	close_panel(cb)
	cb.cfg = cfg
	panel_release_look(cb) // fonts and colours are rebuilt on the next open
	for it in cb.items { item_clear_preview(it) }
	if enforce_cap(cb) { schedule_save(cb) }
	if cfg.clipboard.persist && cb.started { schedule_save(cb) }
	if cb.started { update_watch(cb) }
	tx.flush(cb.c)
}

toggle_panel :: proc(cb: ^Clipboard, anchor: tx.Rect) {
	if cb == nil || !cb.started { return }
	context.allocator = cb.allocator
	if cb.panel.open {
		close_panel(cb)
		return
	}
	// The click on the bar icon that just closed the panel (as an outside click) must not reopen it.
	if cb.panel.closed_now { return }
	panel_show(cb, anchor)
	tx.flush(cb.c)
}

// Open the panel centred on the primary monitor (for a Super+V binding); toggles when open.
open_panel_centered :: proc(cb: ^Clipboard) {
	if cb == nil || !cb.started { return }
	context.allocator = cb.allocator
	if cb.panel.open {
		close_panel(cb)
		return
	}
	panel_show(cb, {}, true)
	tx.flush(cb.c)
}

panel_open :: proc(cb: ^Clipboard) -> bool {
	return cb != nil && cb.panel.open
}

close_panel :: proc(cb: ^Clipboard) {
	if cb == nil || !cb.panel.open { return }
	context.allocator = cb.allocator
	panel_hide(cb)
	tx.flush(cb.c)
}

window_ids :: proc(cb: ^Clipboard, allocator := context.temp_allocator) -> []xlib.Window {
	if cb == nil { return nil }
	ids := make([dynamic]xlib.Window, allocator)
	if cb.win != 0 { append(&ids, cb.win) }
	if cb.panel.win != 0 { append(&ids, cb.panel.win) }
	return ids[:]
}

// ---------------------------------------------------------------------------
// Internals shared by the other files
// ---------------------------------------------------------------------------
@(private)
update_watch :: proc(cb: ^Clipboard) {
	if !cb.has_xfixes || cb.win == 0 { return }
	want := cb.cfg.clipboard.enabled
	if want == cb.watching { return }
	mask := uint(0)
	if want {
		mask = XFIXES_SET_SELECTION_OWNER_NOTIFY_MASK | XFIXES_SELECTION_WINDOW_DESTROY_NOTIFY_MASK | XFIXES_SELECTION_CLIENT_CLOSE_NOTIFY_MASK
	}
	XFixesSelectSelectionInput(cb.c.dpy, cb.win, cb.atoms.clipboard, mask)
	cb.watching = want
	if want {
		// Record what is on the clipboard right now.
		owner := xlib.GetSelectionOwner(cb.c.dpy, cb.atoms.clipboard)
		if owner != 0 && owner != cb.win { fetch_begin(cb) }
	} else {
		fetch_reset(cb)
	}
}

@(private)
schedule_save :: proc(cb: ^Clipboard) {
	if !cb.cfg.clipboard.persist { return }
	if cb.save_due < 0 { cb.save_due = tx.now() + SAVE_DELAY }
}

@(private)
tr :: proc(cb: ^Clipboard, pt, en: string) -> string { return config.tr(cb.cfg.bar.language, pt, en) }
