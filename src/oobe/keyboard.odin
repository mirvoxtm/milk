// Keyboard page: layouts and variants from the XKB rules list, applied live
// with setxkbmap on the wizard's display so the user can try them in the
// test field. The original setting is restored when the wizard is skipped.
package oobe

import "core:log"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import xlib "vendor:x11/xlib"
import tx "../tx"

@(private) XKB_RULES :: []string{"/usr/share/X11/xkb/rules/evdev.lst", "/usr/share/X11/xkb/rules/base.lst"}
// Shown first: the layouts people here most likely use.
@(private) PREFERRED_LAYOUTS :: []string{"br", "us", "pt", "es", "de", "fr", "gb"}

@(private)
Kb_Entry :: struct {
	code, desc: string, // slices of Keyboard.data
}

@(private)
Keyboard :: struct {
	data:            []u8,
	layouts:         [dynamic]Kb_Entry,
	variants:        map[string][dynamic]Kb_Entry, // layout code -> variants
	filtered:        [dynamic]int,                 // indices into layouts matching the search
	layout:          string,                       // the choice (owned)
	variant:         string,
	orig_layout:     string,                       // the X server's setting when the wizard started (owned)
	orig_variant:    string,
	search:          [dynamic]u8,
	test:            [dynamic]u8,
	scroll_layouts:  i32,
	scroll_variants: i32,
	reveal:          bool, // scroll the selected layout into view on the next frame
	applied:         bool, // setxkbmap changed the server's keymap
	tool_missing:    bool,
}

@(private)
keyboard_init :: proc(w: ^Wizard) {
	kb := &w.kb
	for path in XKB_RULES {
		data, err := os.read_entire_file(path, w.allocator)
		if err == nil {
			kb.data = data
			break
		}
	}
	if kb.data == nil { log.warn("Setup: no XKB rules list found; the keyboard page only shows the current layout") }
	parse_rules(kb)

	// The server's current setting (first group only).
	server_layout, server_variant := server_keymap(w)
	kb.orig_layout = strings.clone(server_layout)
	kb.orig_variant = strings.clone(server_variant)
	layout := first_item(server_layout)
	variant := first_item(server_variant)
	if w.cfg.keyboard.layout != "" {
		layout = first_item(w.cfg.keyboard.layout)
		variant = first_item(w.cfg.keyboard.variant)
	}
	if layout == "" { layout = "us" }
	kb.layout = strings.clone(layout)
	kb.variant = strings.clone(variant)
	keyboard_filter(w)
	kb.reveal = true
}

@(private)
first_item :: proc(s: string) -> string {
	if i := strings.index_byte(s, ','); i >= 0 { return strings.trim_space(s[:i]) }
	return strings.trim_space(s)
}

// _XKB_RULES_NAMES on the root window: rules, model, layout, variant, options.
@(private)
server_keymap :: proc(w: ^Wizard) -> (layout, variant: string) {
	p, ok := tx.get_property(w.c, w.c.root, "_XKB_RULES_NAMES", tx.ATOM_STRING)
	if !ok { return "", "" }
	defer tx.property_free(p)
	if p.format != 8 { return "", "" }
	raw := string(([^]u8)(p.data)[:p.count])
	parts := strings.split(raw, "\x00", context.temp_allocator)
	if len(parts) > 2 { layout = strings.clone(parts[2], context.temp_allocator) }
	if len(parts) > 3 { variant = strings.clone(parts[3], context.temp_allocator) }
	return
}

@(private)
parse_rules :: proc(kb: ^Keyboard) {
	text := string(kb.data)
	section := ""
	all := make([dynamic]Kb_Entry, context.temp_allocator)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "! ") {
			section = strings.trim_space(line[2:])
			continue
		}
		t := strings.trim_space(line)
		if t == "" { continue }
		sp := strings.index_any(t, " \t")
		if sp < 0 { continue }
		code := t[:sp]
		desc := strings.trim_space(t[sp:])
		switch section {
		case "layout":
			if code != "custom" { append(&all, Kb_Entry{code, desc}) }
		case "variant":
			colon := strings.index(desc, ": ")
			if colon < 0 { continue }
			owner := desc[:colon]
			list := kb.variants[owner]
			append(&list, Kb_Entry{code, desc[colon + 2:]})
			kb.variants[owner] = list
		}
	}
	// A keyboard with and without dead keys (thinkpad / thinkpad_nodeadkeys):
	// the dead-key one first, so accents work unless chosen otherwise.
	for _, &list in kb.variants {
		for i := 0; i < len(list); i += 1 {
			v := list[i]
			if !strings.contains(v.code, "nodeadkeys") { continue }
			base := strings.trim_suffix(strings.trim_suffix(v.code, "nodeadkeys"), "_")
			for j := i + 1; j < len(list); j += 1 {
				if list[j].code != base { continue }
				twin := list[j]
				ordered_remove(&list, j)
				inject_at(&list, i, twin)
				i += 1
				break
			}
		}
	}
	for code in PREFERRED_LAYOUTS {
		for e in all { if e.code == code { append(&kb.layouts, e) } }
	}
	outer: for e in all {
		for code in PREFERRED_LAYOUTS { if e.code == code { continue outer } }
		append(&kb.layouts, e)
	}
}

@(private)
keyboard_destroy :: proc(w: ^Wizard) {
	kb := &w.kb
	delete(kb.layouts)
	for _, list in kb.variants { delete(list) }
	delete(kb.variants)
	delete(kb.filtered)
	delete(kb.search)
	delete(kb.test)
	delete(kb.layout)
	delete(kb.variant)
	delete(kb.orig_layout)
	delete(kb.orig_variant)
	delete(kb.data)
	kb^ = {}
}

@(private)
keyboard_filter :: proc(w: ^Wizard) {
	kb := &w.kb
	clear(&kb.filtered)
	query := strings.to_lower(strings.trim_space(string(kb.search[:])), context.temp_allocator)
	for e, i in kb.layouts {
		if query != "" {
			desc := strings.to_lower(e.desc, context.temp_allocator)
			if !strings.contains(desc, query) && !strings.has_prefix(e.code, query) { continue }
		}
		append(&kb.filtered, i)
	}
	kb.scroll_layouts = 0
	kb.reveal = true
}

@(private)
layout_desc :: proc(w: ^Wizard, code: string) -> string {
	for e in w.kb.layouts { if e.code == code { return e.desc } }
	return code
}

@(private)
layout_variants :: proc(w: ^Wizard) -> []Kb_Entry {
	if list, ok := w.kb.variants[w.kb.layout]; ok { return list[:] }
	return nil
}

// "Portuguese (Brazil, no dead keys)" under "Portuguese (Brazil)" -> "No dead keys".
@(private)
variant_label :: proc(w: ^Wizard, desc: string) -> string {
	parent := layout_desc(w, w.kb.layout)
	rest := ""
	if strings.has_suffix(parent, ")") {
		prefix := strings.concatenate({parent[:len(parent) - 1], ", "}, context.temp_allocator)
		if strings.has_prefix(desc, prefix) { rest = desc[len(prefix):] }
	} else {
		prefix := strings.concatenate({parent, " ("}, context.temp_allocator)
		if strings.has_prefix(desc, prefix) { rest = desc[len(prefix):] }
	}
	if rest == "" { return desc }
	rest = strings.trim_suffix(rest, ")")
	r, n := utf8.decode_rune_in_string(rest)
	if n <= 0 { return desc }
	return strings.concatenate({strings.to_upper(utf8_string(r), context.temp_allocator), rest[n:]}, context.temp_allocator)
}

@(private)
utf8_string :: proc(r: rune) -> string {
	buf, n := utf8.encode_rune(r)
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

@(private)
variant_desc :: proc(w: ^Wizard) -> string {
	if w.kb.variant == "" { return tr(w, "Padrão", "Default") }
	for v in layout_variants(w) { if v.code == w.kb.variant { return variant_label(w, v.desc) } }
	return w.kb.variant
}

@(private)
keyboard_select_layout :: proc(w: ^Wizard, index: int) {
	kb := &w.kb
	if index < 0 || index >= len(kb.layouts) { return }
	code := kb.layouts[index].code
	if code == kb.layout && kb.variant == "" { return }
	delete(kb.layout)
	kb.layout = strings.clone(code)
	delete(kb.variant)
	kb.variant = strings.clone("")
	kb.scroll_variants = 0
	keyboard_apply(w)
	w.dirty = true
}

// -1 selects the layout's default variant.
@(private)
keyboard_select_variant :: proc(w: ^Wizard, index: int) {
	kb := &w.kb
	variants := layout_variants(w)
	code := ""
	if index >= 0 && index < len(variants) { code = variants[index].code }
	if code == kb.variant { return }
	delete(kb.variant)
	kb.variant = strings.clone(code)
	keyboard_apply(w)
	w.dirty = true
}

// Arrow keys move through the (filtered) layout list.
@(private)
keyboard_step :: proc(w: ^Wizard, dir: int) {
	kb := &w.kb
	if len(kb.filtered) == 0 { return }
	pos := -1
	for li, i in kb.filtered { if kb.layouts[li].code == kb.layout { pos = i } }
	next := clamp(pos + dir, 0, len(kb.filtered) - 1)
	if pos < 0 { next = 0 }
	keyboard_select_layout(w, kb.filtered[next])
	kb.reveal = true
	w.dirty = true
}

@(private)
keyboard_reveal :: proc(w: ^Wizard) { w.kb.reveal = true }

@(private)
keyboard_apply :: proc(w: ^Wizard) {
	kb := &w.kb
	if kb.tool_missing { return }
	display := string(xlib.DisplayString(w.c.dpy))
	cmd := []string{"setxkbmap", "-display", display, "-layout", kb.layout, "-variant", kb.variant}
	state, _, stderr, err := os.process_exec(os.Process_Desc{command = cmd}, context.temp_allocator)
	if err != nil {
		log.warnf("Setup: cannot run setxkbmap (%v); the layout is only saved", err)
		kb.tool_missing = true
		return
	}
	if !state.success {
		log.warnf("Setup: setxkbmap -layout %s -variant %q failed: %s", kb.layout, kb.variant, strings.trim_space(string(stderr)))
		return
	}
	kb.applied = true
	log.debugf("Setup: keyboard %s %s", kb.layout, kb.variant)
}

// Put the server's original keymap back (the wizard was skipped).
@(private)
keyboard_restore :: proc(w: ^Wizard) {
	kb := &w.kb
	if !kb.applied || kb.orig_layout == "" { return }
	display := string(xlib.DisplayString(w.c.dpy))
	cmd := []string{"setxkbmap", "-display", display, "-layout", kb.orig_layout, "-variant", kb.orig_variant}
	_, _, _, _ = os.process_exec(os.Process_Desc{command = cmd}, context.temp_allocator)
	kb.applied = false
}

@(private)
field_insert :: proc(w: ^Wizard, s: string) {
	kb := &w.kb
	switch w.focus {
	case .None:
	case .Search:
		if len(kb.search) + len(s) > 64 { return }
		append(&kb.search, ..transmute([]u8)s)
		keyboard_filter(w)
	case .Test:
		if len(kb.test) + len(s) > 160 { return }
		append(&kb.test, ..transmute([]u8)s)
	case .Text:
		settings_text_insert(w, s)
	}
	w.dirty = true
}

@(private)
field_backspace :: proc(w: ^Wizard) {
	kb := &w.kb
	buf: ^[dynamic]u8
	switch w.focus {
	case .None:   return
	case .Search: buf = &kb.search
	case .Test:   buf = &kb.test
	case .Text:   buf = settings_text_buffer(w)
	}
	if buf == nil { return }
	if len(buf) == 0 { return }
	_, n := utf8.decode_last_rune(buf[:])
	resize(buf, len(buf) - max(n, 1))
	if w.focus == .Search { keyboard_filter(w) }
	if w.focus == .Text { settings_text_edited(w) }
	w.dirty = true
}
