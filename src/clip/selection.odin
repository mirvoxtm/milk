// The X selection protocol (ICCCM): fetching the CLIPBOARD from other clients
// (TARGETS, then the chosen target, INCR for large data) and serving an entry
// while milk owns CLIPBOARD.
package clip

import "core:log"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import xlib "vendor:x11/xlib"
import tx "../tx"

// ---------------------------------------------------------------------------
// Fetching
// ---------------------------------------------------------------------------
@(private)
on_owner_change :: proc(cb: ^Clipboard, xe: ^XFixesSelectionNotifyEvent) {
	if xe.selection != cb.atoms.clipboard || !cb.cfg.clipboard.enabled { return }
	switch xe.subtype {
	case XFIXES_SUBTYPE_SET_OWNER:
		if xe.owner == cb.win { return }
		cb.current = 0
		if xe.owner == 0 {
			fetch_reset(cb)
			return
		}
		fetch_begin(cb)
	case XFIXES_SUBTYPE_WINDOW_DESTROY, XFIXES_SUBTYPE_CLIENT_CLOSE:
		// The owner went away: keep its content alive with our copy.
		fetch_reset(cb)
		if cb.current == 0 { return }
		for it in cb.items {
			if it.id == cb.current {
				if become_owner(cb, it, xe.timestamp) { log.debug("Clipboard: the owner exited; milk keeps its content") }
				break
			}
		}
	}
}

@(private)
fetch_reset :: proc(cb: ^Clipboard) {
	f := &cb.fetch
	if f.stage != .Idle && f.prop != 0 && cb.win != 0 { xlib.DeleteProperty(cb.c.dpy, cb.win, f.prop) }
	f.stage = .Idle
	f.target = 0
	f.overflow = false
	clear(&f.queue)
	clear(&f.buf)
	if cap(f.buf) > 4 * 1024 * 1024 {
		delete(f.buf)
		f.buf = nil
	}
}

@(private)
fetch_begin :: proc(cb: ^Clipboard) {
	fetch_reset(cb)
	f := &cb.fetch
	f.serial += 1
	f.prop = cb.atoms.props[f.serial % len(cb.atoms.props)]
	f.stage = .Targets
	f.target = cb.atoms.targets
	f.deadline = tx.now() + FETCH_TIMEOUT
	xlib.DeleteProperty(cb.c.dpy, cb.win, f.prop)
	xlib.ConvertSelection(cb.c.dpy, cb.atoms.clipboard, cb.atoms.targets, f.prop, cb.win, xlib.CurrentTime)
}

// Ask for the next candidate target; gives up when none is left.
@(private)
fetch_next :: proc(cb: ^Clipboard) {
	f := &cb.fetch
	if len(f.queue) == 0 {
		fetch_reset(cb)
		return
	}
	f.target = f.queue[0]
	ordered_remove(&f.queue, 0)
	f.stage = .Data
	f.overflow = false
	clear(&f.buf)
	f.deadline = tx.now() + FETCH_TIMEOUT
	xlib.DeleteProperty(cb.c.dpy, cb.win, f.prop)
	xlib.ConvertSelection(cb.c.dpy, cb.atoms.clipboard, f.target, f.prop, cb.win, xlib.CurrentTime)
}

@(private)
is_image_target :: proc(cb: ^Clipboard, t: xlib.Atom) -> bool {
	return t == cb.atoms.png || t == cb.atoms.jpeg || t == cb.atoms.bmp
}

@(private)
on_selection_notify :: proc(cb: ^Clipboard, ev: ^xlib.XSelectionEvent) {
	f := &cb.fetch
	if f.stage == .Idle || f.stage == .Incr || ev.selection != cb.atoms.clipboard { return }
	if ev.target != f.target { return } // a reply to an abandoned request
	if ev.property == 0 {
		if f.stage == .Targets {
			// No TARGETS support: try plain text directly.
			clear(&f.queue)
			append(&f.queue, cb.atoms.utf8, tx.ATOM_STRING)
		}
		fetch_next(cb)
		return
	}
	if ev.property != f.prop { return }
	#partial switch f.stage {
	case .Targets:
		targets := read_atoms(cb, cb.win, f.prop)
		xlib.DeleteProperty(cb.c.dpy, cb.win, f.prop)
		choose_targets(cb, targets)
		fetch_next(cb)
	case .Data:
		type, _, data, ok := read_property(cb, cb.win, f.prop, true)
		if !ok {
			fetch_next(cb)
			return
		}
		if type == cb.atoms.incr {
			// Reading (and deleting) the INCR property starts the transfer.
			f.stage = .Incr
			clear(&f.buf)
			f.deadline = tx.now() + FETCH_TIMEOUT
			return
		}
		if len(data) == 0 {
			fetch_next(cb)
			return
		}
		finish_fetch(cb, f.target, data)
	}
}

// Candidate targets, best first: images only when no plain text is offered
// (office suites offer a picture of the copied cells next to their text).
@(private)
choose_targets :: proc(cb: ^Clipboard, targets: []xlib.Atom) {
	a := &cb.atoms
	f := &cb.fetch
	clear(&f.queue)
	if slice.contains(targets, a.secret) {
		log.debug("Clipboard: a password manager marked this content as secret; not recording it")
		return
	}
	text_order := [?]xlib.Atom{a.utf8, a.text_plain_utf8, tx.ATOM_STRING, a.text_plain}
	image_order := [?]xlib.Atom{a.png, a.jpeg, a.bmp}
	has_text := false
	for t in text_order { if slice.contains(targets, t) { has_text = true } }
	if has_text {
		for t in text_order { if slice.contains(targets, t) { append(&f.queue, t) } }
	} else {
		for t in image_order { if slice.contains(targets, t) { append(&f.queue, t) } }
	}
}

@(private)
on_own_property :: proc(cb: ^Clipboard, ev: ^xlib.XPropertyEvent) {
	f := &cb.fetch
	if f.stage != .Incr || ev.atom != f.prop || ev.state != .PropertyNewValue { return }
	_, _, data, ok := read_property(cb, cb.win, f.prop, true)
	if !ok { return }
	f.deadline = tx.now() + FETCH_TIMEOUT
	if len(data) == 0 {
		// The zero-length chunk ends the transfer.
		if f.overflow {
			log.infof("Clipboard: skipped a %s larger than the configured limit", is_image_target(cb, f.target) ? "picture" : "text")
			fetch_reset(cb)
			return
		}
		if len(f.buf) == 0 {
			fetch_next(cb)
			return
		}
		finish_fetch(cb, f.target, f.buf[:])
		return
	}
	if f.overflow { return }
	limit := is_image_target(cb, f.target) ? cb.cfg.clipboard.max_image_bytes : TEXT_LIMIT
	if len(f.buf) + len(data) > limit {
		f.overflow = true // keep deleting chunks until the owner finishes
		clear(&f.buf)
		return
	}
	append(&f.buf, ..data)
}

@(private)
finish_fetch :: proc(cb: ^Clipboard, target: xlib.Atom, data: []u8) {
	a := &cb.atoms
	defer fetch_reset(cb)
	if is_image_target(cb, target) {
		if len(data) > cb.cfg.clipboard.max_image_bytes {
			log.infof("Clipboard: skipped a %d-byte picture (clipboard.maxImageBytes is %d)", len(data), cb.cfg.clipboard.max_image_bytes)
			return
		}
		mime := target == a.png ? "image/png" : target == a.jpeg ? "image/jpeg" : "image/bmp"
		add_image(cb, mime, data)
		return
	}
	if len(data) > TEXT_LIMIT { return }
	text: string
	if target == tx.ATOM_STRING {
		text = latin1_to_utf8(data)
	} else {
		text = sanitize_utf8(data)
	}
	text = strings.trim_right(text, "\x00")
	if len(strings.trim_space(text)) == 0 { return }
	add_text(cb, text)
}

@(private)
latin1_to_utf8 :: proc(data: []u8, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, len(data) + len(data) / 8, allocator)
	for ch in data { strings.write_rune(&b, rune(ch)) }
	return strings.to_string(b)
}

// Invalid sequences become U+FFFD so Xft never sees broken UTF-8.
@(private)
sanitize_utf8 :: proc(data: []u8, allocator := context.temp_allocator) -> string {
	s := string(data)
	if utf8.valid_string(s) { return s }
	b := strings.builder_make(0, len(data), allocator)
	for r in s { strings.write_rune(&b, r) } // the iterator yields RUNE_ERROR for bad bytes
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Property access
// ---------------------------------------------------------------------------
// Read a whole property; the bytes live in the temp allocator.
@(private)
read_property :: proc(cb: ^Clipboard, win: xlib.Window, prop: xlib.Atom, delete_it: bool) -> (type: xlib.Atom, format: i32, data: []u8, ok: bool) {
	nitems, after: uint
	raw: rawptr
	status := xlib.GetWindowProperty(cb.c.dpy, win, prop, 0, 1 << 26, b32(delete_it), xlib.Atom(0),
	                                 &type, &format, &nitems, &after, &raw)
	if status != 0 { return }
	defer if raw != nil { xlib.Free(raw) }
	if type == 0 { return } // no such property
	size := int(nitems)
	switch format {
	case 16: size *= size_of(i16)
	case 32: size *= size_of(uint) // format-32 data arrives as C longs
	}
	data = make([]u8, size, context.temp_allocator)
	if size > 0 && raw != nil { copy(data, ([^]u8)(raw)[:size]) }
	return type, format, data, true
}

@(private)
read_atoms :: proc(cb: ^Clipboard, win: xlib.Window, prop: xlib.Atom) -> []xlib.Atom {
	_, format, data, ok := read_property(cb, win, prop, false)
	if !ok || format != 32 { return nil }
	longs := slice.reinterpret([]uint, data)
	out := make([]xlib.Atom, len(longs), context.temp_allocator)
	for v, i in longs { out[i] = xlib.Atom(v & 0xFFFFFFFF) }
	return out
}

// ---------------------------------------------------------------------------
// Serving (milk owns CLIPBOARD)
// ---------------------------------------------------------------------------
@(private)
owned_clear :: proc(cb: ^Clipboard) {
	o := &cb.owned
	delete(o.data)
	delete(o.png)
	delete(o.mime)
	o^ = {}
}

// Make `it` the clipboard content. `time` should be the triggering event's timestamp.
@(private)
become_owner :: proc(cb: ^Clipboard, it: ^Item, time: xlib.Time) -> bool {
	owned_clear(cb)
	cb.owned = {active = true, id = it.id, kind = it.kind, mime = strings.clone(it.mime), data = slice.clone(it.data), time = time}
	xlib.SetSelectionOwner(cb.c.dpy, cb.atoms.clipboard, cb.win, time)
	if xlib.GetSelectionOwner(cb.c.dpy, cb.atoms.clipboard) != cb.win {
		log.warn("Clipboard: could not take ownership of CLIPBOARD")
		owned_clear(cb)
		return false
	}
	fetch_reset(cb)
	cb.current = it.id
	return true
}

@(private)
on_selection_clear :: proc(cb: ^Clipboard, ev: ^xlib.XSelectionClearEvent) {
	if ev.selection != cb.atoms.clipboard { return }
	owned_clear(cb)
}

@(private)
owned_targets :: proc(cb: ^Clipboard) -> []xlib.Atom {
	a := &cb.atoms
	list := make([dynamic]xlib.Atom, context.temp_allocator)
	append(&list, a.targets, a.timestamp)
	switch cb.owned.kind {
	case .Text:
		append(&list, a.utf8, a.text_plain_utf8, a.text_plain, tx.ATOM_STRING, a.text)
	case .Image:
		append(&list, a.png)
		if cb.owned.mime != "image/png" { append(&list, tx.atom(cb.c, cb.owned.mime)) }
	}
	return list[:]
}

// The bytes and the property type for a requested target.
@(private)
owned_data :: proc(cb: ^Clipboard, target: xlib.Atom) -> (data: []u8, type: xlib.Atom, ok: bool) {
	a := &cb.atoms
	o := &cb.owned
	switch o.kind {
	case .Text:
		switch target {
		case a.utf8, a.text:    return o.data, a.utf8, true
		case a.text_plain_utf8: return o.data, a.text_plain_utf8, true
		case a.text_plain:      return o.data, a.text_plain, true
		case tx.ATOM_STRING:    return utf8_to_latin1(o.data), tx.ATOM_STRING, true
		}
	case .Image:
		if target == a.png {
			if o.mime == "image/png" { return o.data, a.png, true }
			if o.png == nil {
				if img, decoded := decode_image(o.mime, o.data); decoded {
					o.png = png_encode(img)
					tx.image_destroy(&img)
				}
			}
			if o.png != nil { return o.png, a.png, true }
			return nil, 0, false
		}
		if target == tx.atom(cb.c, o.mime) { return o.data, target, true }
	}
	return nil, 0, false
}

@(private)
utf8_to_latin1 :: proc(data: []u8) -> []u8 {
	out := make([dynamic]u8, 0, len(data), context.temp_allocator)
	for r in string(data) { append(&out, r < 256 ? u8(r) : '?') }
	return out[:]
}

@(private)
on_selection_request :: proc(cb: ^Clipboard, req: ^xlib.XSelectionRequestEvent) {
	reply: xlib.XEvent
	reply.xselection = xlib.XSelectionEvent{
		type = .SelectionNotify, requestor = req.requestor, selection = req.selection,
		target = req.target, property = 0, time = req.time,
	}
	prop := req.property != 0 ? req.property : req.target // obsolete clients pass None
	if cb.owned.active && req.selection == cb.atoms.clipboard && req.requestor != 0 {
		if serve(cb, req.requestor, prop, req.target) { reply.xselection.property = prop }
	}
	xlib.SendEvent(cb.c.dpy, req.requestor, false, {}, &reply)
}

@(private)
serve :: proc(cb: ^Clipboard, requestor: xlib.Window, prop, target: xlib.Atom) -> bool {
	dpy := cb.c.dpy
	a := &cb.atoms
	switch target {
	case a.targets:
		list := owned_targets(cb)
		xlib.ChangeProperty(dpy, requestor, prop, tx.ATOM_ATOM, 32, tx.PROP_MODE_REPLACE, raw_data(list), i32(len(list)))
		return true
	case a.timestamp:
		v := uint(cb.owned.time)
		xlib.ChangeProperty(dpy, requestor, prop, a.integer, 32, tx.PROP_MODE_REPLACE, &v, 1)
		return true
	case a.multiple:
		return false
	}
	data, type, ok := owned_data(cb, target)
	if !ok { return false }
	if len(data) <= cb.incr_threshold {
		xlib.ChangeProperty(dpy, requestor, prop, type, 8, tx.PROP_MODE_REPLACE, raw_data(data), i32(len(data)))
		return true
	}
	// INCR: announce the size, then send one chunk each time the requestor
	// deletes the property. We need PropertyNotify on the requestor; the window
	// manager on this connection may already select other events there, so the
	// mask is extended rather than replaced.
	attrs: xlib.XWindowAttributes
	if xlib.GetWindowAttributes(dpy, requestor, &attrs) == 0 { return false }
	added := false
	if .PropertyChange not_in attrs.your_event_mask {
		xlib.SelectInput(dpy, requestor, attrs.your_event_mask + {.PropertyChange})
		added = true
	}
	size := uint(len(data))
	xlib.ChangeProperty(dpy, requestor, prop, a.incr, 32, tx.PROP_MODE_REPLACE, &size, 1)
	append(&cb.transfers, Transfer{requestor = requestor, property = prop, type = type, data = slice.clone(data),
	                               added_mask = added, deadline = tx.now() + TRANSFER_TIMEOUT})
	return true
}

@(private)
on_transfer_property :: proc(cb: ^Clipboard, ev: ^xlib.XPropertyEvent) -> bool {
	if ev.state != .PropertyDelete { return false }
	for i in 0 ..< len(cb.transfers) {
		t := &cb.transfers[i]
		if t.requestor != ev.window || t.property != ev.atom { continue }
		n := min(INCR_CHUNK, len(t.data) - t.offset)
		chunk := t.data[t.offset:][:n]
		xlib.ChangeProperty(cb.c.dpy, t.requestor, t.property, t.type, 8, tx.PROP_MODE_REPLACE, raw_data(chunk), i32(n))
		t.offset += n
		t.deadline = tx.now() + TRANSFER_TIMEOUT
		if n == 0 { transfer_remove(cb, i) } // the zero-length chunk was just written
		return true
	}
	return false
}

@(private)
transfer_remove :: proc(cb: ^Clipboard, index: int) {
	t := cb.transfers[index]
	if t.added_mask {
		attrs: xlib.XWindowAttributes
		if xlib.GetWindowAttributes(cb.c.dpy, t.requestor, &attrs) != 0 {
			still := false
			for other, j in cb.transfers { if j != index && other.requestor == t.requestor { still = true } }
			if !still { xlib.SelectInput(cb.c.dpy, t.requestor, attrs.your_event_mask - {.PropertyChange}) }
		}
	}
	delete(t.data)
	ordered_remove(&cb.transfers, index)
}
