// The password dialog: a card in milk's theme, centred on the primary
// monitor, with what is being asked (polkit's message and the command), who
// answers (a click switches when several users may), the password field,
// a status line and Cancel / Authenticate. It is an override-redirect window
// that holds the keyboard while it is open, so the password cannot end up in
// another window and milk's own shortcuts stay quiet; Enter answers, Escape
// cancels. Typed text goes through the input method (dead keys compose).
package polkit

import "core:fmt"
import "core:log"
import "core:strings"
import "core:unicode/utf8"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

@(private) DIALOG_W      :: 460
@(private) DIALOG_PAD    :: 26
@(private) DIALOG_RADIUS :: 18
@(private) FIELD_H       :: 46
@(private) BUTTON_H      :: 38
@(private) MAX_PASSWORD  :: 512
@(private) GRAB_RETRY    :: 0.1 // seconds between keyboard grab attempts
@(private) GRAB_GIVE_UP  :: 5.0
@(private) ICON_LOCK     :: rune(0xEAE2) // Tabler "lock"

@(private)
Dialog_Part :: enum { None, User, Field, Cancel, Ok }

@(private)
Dialog :: struct {
	open:        bool,
	win:         xlib.Window,
	pixmap:      xlib.Pixmap,
	rect:        tx.Rect,
	input:       tx.Input,
	grabbed:     bool,
	grab_until:  f64, // keep trying to grab the keyboard until then
	next_grab:   f64,
	// Fonts in the bar's family.
	f_title, f_body, f_small, f_icon: ^tx.Font,
	// The conversation.
	answer:      [MAX_PASSWORD]u8,
	answer_len:  int,
	prompt:      string, // owned: what the helper asks ("Password:"), "" before it asks
	echo:        bool,   // the answer may be shown
	asking:      bool,   // a prompt waits for an answer
	checking:    bool,   // an answer was sent
	error:       string, // owned
	info:        string, // owned
	broken:      bool,   // no helper: only Cancel works
	failures:    int,
	// Layout of the last frame (dialog coordinates).
	hover:       Dialog_Part,
	parts:       [Dialog_Part]tx.Rect,
}

@(private)
Dialog_Theme :: struct {
	bg, fg, muted, accent, accent_fg, surface, warning: tx.Color,
}

@(private)
theme_of :: proc(cfg: ^config.Config) -> Dialog_Theme {
	t := &cfg.bar.theme
	return {
		bg        = tx.color_from_hex(t.background, tx.rgb(0xF5, 0xEE, 0xE6)),
		fg        = tx.color_from_hex(t.foreground, tx.rgb(0x2B, 0x25, 0x20)),
		muted     = tx.color_from_hex(t.muted, tx.rgb(0x8A, 0x80, 0x76)),
		accent    = tx.color_from_hex(t.accent, tx.rgb(0x4A, 0x3F, 0x35)),
		accent_fg = tx.color_from_hex(t.accent_foreground, tx.rgb(0xF5, 0xEE, 0xE6)),
		surface   = tx.color_from_hex(t.surface, tx.rgb(0xE9, 0xE0, 0xD6)),
		warning   = tx.color_from_hex(t.warning, tx.rgb(0xB5, 0x47, 0x3A)),
	}
}

@(private)
tr :: proc(a: ^Agent, pt, en: string) -> string { return config.tr(a.cfg.bar.language, pt, en) }

// ---------------------------------------------------------------------------
// Open / close
// ---------------------------------------------------------------------------
@(private)
dialog_open :: proc(a: ^Agent, r: ^Request) {
	d := &a.dialog
	if !d.open {
		open_fonts(a)
		d.open = true
		d.grabbed = false
		d.grab_until = tx.now() + GRAB_GIVE_UP
		d.next_grab = 0
	}
	d.failures = 0
	d.hover = .None
	dialog_draw(a)
	tx.map_window(a.c, d.win)
	tx.raise_window(a.c, d.win)
	try_grab(a)
	tx.flush(a.c)
}

@(private)
dialog_close :: proc(a: ^Agent) {
	d := &a.dialog
	clear_answer(d)
	if !d.open { return }
	d.open = false
	if d.grabbed { xlib.UngrabKeyboard(a.c.dpy, xlib.CurrentTime) }
	d.grabbed = false
	tx.input_focus(&d.input, false)
	if d.win != 0 { tx.unmap_window(a.c, d.win) }
	close_fonts(a)
	tx.flush(a.c)
}

@(private)
dialog_destroy :: proc(a: ^Agent) {
	d := &a.dialog
	dialog_close(a)
	tx.input_close(&d.input)
	if d.win != 0 { tx.destroy_window(a.c, d.win) }
	tx.pixmap_free(a.c, d.pixmap)
	delete(d.prompt)
	delete(d.error)
	delete(d.info)
	d^ = {}
}

@(private)
dialog_restyle :: proc(a: ^Agent) {
	close_fonts(a)
	open_fonts(a)
	dialog_draw(a)
}

@(private)
open_fonts :: proc(a: ^Agent) {
	d := &a.dialog
	c := a.c
	b := &a.cfg.bar
	px := i32(max(b.font_size, 10))
	open :: proc(c: ^tx.Connection, pattern: string, px: i32) -> ^tx.Font {
		f, ok := tx.font_open(c, pattern, px)
		if !ok { f, _ = tx.font_open(c, "sans", px) }
		return f
	}
	d.f_title = open(c, fmt.tprintf("%s:bold", b.font), px + 4)
	d.f_body = open(c, b.font, px)
	d.f_small = open(c, b.font, max(px - 2, 9))
	if b.icon_font_file != "" {
		d.f_icon, _ = tx.font_open_file(c, b.icon_font_file, px + 8)
	}
}

@(private)
close_fonts :: proc(a: ^Agent) {
	d := &a.dialog
	for f in ([]^tx.Font{d.f_title, d.f_body, d.f_small, d.f_icon}) { tx.font_close(a.c, f) }
	d.f_title, d.f_body, d.f_small, d.f_icon = nil, nil, nil, nil
}

// The keyboard is ours while the dialog is open; another client may hold it
// for a moment (a menu): keep trying for a few seconds.
@(private)
try_grab :: proc(a: ^Agent) {
	d := &a.dialog
	if !d.open || d.grabbed { return }
	status := xlib.GrabKeyboard(a.c.dpy, d.win, false, .GrabModeAsync, .GrabModeAsync, xlib.CurrentTime)
	d.grabbed = status == 0
	d.next_grab = tx.now() + GRAB_RETRY
	if d.grabbed { tx.input_focus(&d.input, true) }
}

@(private)
dialog_tick :: proc(a: ^Agent, now: f64) {
	d := &a.dialog
	if d.open && !d.grabbed && now < d.grab_until && now >= d.next_grab { try_grab(a) }
}

@(private)
dialog_next_timeout :: proc(a: ^Agent, now: f64) -> f64 {
	d := &a.dialog
	if d.open && !d.grabbed && now < d.grab_until { return max(d.next_grab - now, 0) }
	return -1
}

// ---------------------------------------------------------------------------
// The conversation, as the agent reports it
// ---------------------------------------------------------------------------
@(private)
set_owned :: proc(s: ^string, value: string) {
	delete(s^)
	s^ = strings.clone(value)
}

@(private)
clear_answer :: proc(d: ^Dialog) {
	secure_zero(d.answer[:d.answer_len])
	d.answer_len = 0
}

// A new conversation (a new user, or after a failure): nothing asked yet.
@(private)
dialog_reset_conversation :: proc(a: ^Agent) {
	d := &a.dialog
	clear_answer(d)
	set_owned(&d.prompt, "")
	set_owned(&d.error, "")
	set_owned(&d.info, "")
	d.asking, d.checking, d.broken, d.echo = false, false, false, false
}

@(private)
dialog_set_prompt :: proc(a: ^Agent, text: string, echo: bool) {
	d := &a.dialog
	p := strings.trim_space(text)
	p = strings.trim_suffix(p, ":")
	set_owned(&d.prompt, p)
	d.echo, d.asking, d.checking = echo, true, false
	clear_answer(d)
}

@(private)
dialog_set_error :: proc(a: ^Agent, text: string) {
	set_owned(&a.dialog.error, strings.trim_space(text))
}

@(private)
dialog_set_info :: proc(a: ^Agent, text: string) {
	set_owned(&a.dialog.info, strings.trim_space(text))
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------
@(private)
dialog_event :: proc(a: ^Agent, ev: ^xlib.XEvent) -> bool {
	d := &a.dialog
	#partial switch ev.type {
	case .KeyPress:
		if ev.xkey.window != d.win && !d.grabbed { return false }
		key_press(a, &ev.xkey)
		return true
	case .KeyRelease:
		return ev.xkey.window == d.win || d.grabbed
	case .ButtonPress:
		if ev.xbutton.window != d.win { return false }
		if ev.xbutton.button == .Button1 { click(a, part_at(d, ev.xbutton.x, ev.xbutton.y)) }
		if !d.grabbed { try_grab(a) }
		return true
	case .ButtonRelease:
		return ev.xbutton.window == d.win
	case .MotionNotify:
		if ev.xmotion.window != d.win { return false }
		set_hover(a, part_at(d, ev.xmotion.x, ev.xmotion.y))
		return true
	case .LeaveNotify:
		if ev.xcrossing.window != d.win { return false }
		set_hover(a, .None)
		return true
	}
	return false
}

@(private)
part_at :: proc(d: ^Dialog, x, y: i32) -> Dialog_Part {
	for p in ([]Dialog_Part{.Ok, .Cancel, .User, .Field}) {
		if tx.rect_contains(d.parts[p], x, y) { return p }
	}
	return .None
}

@(private)
set_hover :: proc(a: ^Agent, p: Dialog_Part) {
	if a.dialog.hover == p { return }
	a.dialog.hover = p
	dialog_draw(a)
}

@(private)
click :: proc(a: ^Agent, p: Dialog_Part) {
	#partial switch p {
	case .Ok:     submit(a)
	case .Cancel: cancel(a)
	case .User:   next_user(a)
	}
}

@(private)
cancel :: proc(a: ^Agent) {
	if len(a.queue) == 0 { return }
	log.infof("Polkit: %s dismissed", a.queue[0].action_id)
	finish_request(a, false, "The user dismissed the authentication dialog")
}

@(private)
submit :: proc(a: ^Agent) {
	d := &a.dialog
	if !d.asking || d.checking || d.broken { return }
	if submit_answer(a, d.answer[:d.answer_len]) {
		d.asking, d.checking = false, true
		set_owned(&d.error, "")
	}
	clear_answer(d)
	dialog_draw(a)
}

@(private)
key_press :: proc(a: ^Agent, ev: ^xlib.XKeyEvent) {
	d := &a.dialog
	text, sym := tx.input_lookup(&d.input, ev)
	ctrl := .ControlMask in ev.state
	#partial switch sym {
	case .XK_Escape:
		cancel(a)
		return
	case .XK_Return, .XK_KP_Enter:
		submit(a)
		return
	case .XK_BackSpace:
		if ctrl {
			clear_answer(d)
		} else if d.answer_len > 0 {
			n := d.answer_len - 1
			for n > 0 && (d.answer[n] & 0xC0) == 0x80 { n -= 1 } // a whole UTF-8 character
			secure_zero(d.answer[n:d.answer_len])
			d.answer_len = n
		}
		dialog_draw(a)
		return
	case .XK_Tab:
		next_user(a)
		return
	}
	if ctrl && (sym == .XK_u || sym == .XK_U) {
		clear_answer(d)
		dialog_draw(a)
		return
	}
	if !d.asking || d.checking || text == "" { return }
	for ch in text { if ch < 0x20 || ch == 0x7F { return } } // control characters
	if d.answer_len + len(text) > MAX_PASSWORD { return }
	copy(d.answer[d.answer_len:], text)
	d.answer_len += len(text)
	secure_zero(transmute([]u8)text)
	dialog_draw(a)
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------
@(private)
Text_Item :: struct {
	font:     ^tx.Font,
	x, y:     i32, // baseline
	s:        string,
	color:    tx.Color,
}

// Words of `s` in lines at most `max_w` wide (at most `max_lines`, the last one ellipsised).
@(private)
wrap :: proc(c: ^tx.Connection, f: ^tx.Font, s: string, max_w: i32, max_lines: int) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for para in strings.split_lines(s, context.temp_allocator) {
		line := strings.builder_make(context.temp_allocator)
		for word in strings.fields(para, context.temp_allocator) {
			try := strings.to_string(line) == "" ? word : fmt.tprintf("%s %s", strings.to_string(line), word)
			if tx.text_width(c, f, try) <= max_w || strings.to_string(line) == "" {
				strings.builder_reset(&line)
				strings.write_string(&line, try)
				continue
			}
			append(&out, strings.clone(strings.to_string(line), context.temp_allocator))
			strings.builder_reset(&line)
			strings.write_string(&line, word)
		}
		if strings.to_string(line) != "" { append(&out, strings.clone(strings.to_string(line), context.temp_allocator)) }
	}
	if len(out) > max_lines {
		last := strings.concatenate({out[max_lines - 1], " …"}, context.temp_allocator)
		out[max_lines - 1] = tx.text_ellipsize(c, f, last, max_w)
		resize(&out, max_lines)
	}
	for &l in out { l = tx.text_ellipsize(c, f, l, max_w) }
	return out[:]
}

@(private)
dialog_draw :: proc(a: ^Agent) {
	d := &a.dialog
	if !d.open || len(a.queue) == 0 || d.f_body == nil { return }
	c := a.c
	r := a.queue[0]
	th := theme_of(a.cfg)
	W := i32(DIALOG_W)
	inner := W - 2 * DIALOG_PAD
	texts := make([dynamic]Text_Item, context.temp_allocator)
	put :: proc(texts: ^[dynamic]Text_Item, f: ^tx.Font, x, box_y, box_h: i32, s: string, color: tx.Color) {
		if f == nil || s == "" { return }
		append(texts, Text_Item{f, x, box_y + (box_h - f.height) / 2 + f.ascent, s, color})
	}

	// Measure first: the card is as tall as what it holds.
	message := r.message != "" ? r.message : tr(a, "Um programa precisa de permissão de administrador.", "A program needs administrator rights.")
	msg_lines := wrap(c, d.f_body, message, inner, 4)
	line_h := d.f_body.height + 3
	header_h := i32(44)
	y_msg := DIALOG_PAD + header_h + 16
	y_user := y_msg + i32(len(msg_lines)) * line_h + 14
	user_h := i32(30)
	y_field := y_user + user_h + 8
	y_status := y_field + FIELD_H + 6
	status_h := d.f_small.height + 8
	y_buttons := y_status + status_h + 12
	H := y_buttons + BUTTON_H + DIALOG_PAD

	// Window: centred on the primary monitor.
	mon := tx.monitor_rect(c, "primary")
	rect := tx.Rect{mon.x + (mon.w - W) / 2, mon.y + (mon.h - H) / 2 - mon.h / 12, W, H}
	if d.win == 0 {
		d.win = tx.create_overlay(c, rect, {.ButtonPress, .ButtonRelease, .PointerMotion, .LeaveWindow, .KeyPress, .KeyRelease},
		                          "_NET_WM_WINDOW_TYPE_DIALOG", "milk authentication")
		d.input = tx.input_open(c, d.win)
	}
	if rect != d.rect {
		tx.move_resize(c, d.win, rect)
		tx.shape_rounded(c, d.win, W, H, DIALOG_RADIUS)
		d.rect = rect
	}

	cv := tx.canvas_make(W, H, context.temp_allocator)
	tx.canvas_fill(&cv, th.bg)
	tx.canvas_stroke_rounded_rect(&cv, {0, 0, W, H}, DIALOG_RADIUS, 1, tx.color_with_alpha(th.muted, 110))

	// Header: the lock in an accent circle, the title and the command (or the action).
	tx.canvas_fill_circle(&cv, f32(DIALOG_PAD) + 22, f32(DIALOG_PAD) + 22, 22, th.accent)
	if d.f_icon != nil && tx.font_has_glyph(c, d.f_icon, ICON_LOCK) {
		buf, n := utf8.encode_rune(ICON_LOCK)
		glyph := strings.clone(string(buf[:n]), context.temp_allocator)
		ext := tx.text_extents(c, d.f_icon, glyph)
		append(&texts, Text_Item{d.f_icon, DIALOG_PAD + (44 - i32(ext.width)) / 2 + i32(ext.x),
		                         DIALOG_PAD + (44 - i32(ext.height)) / 2 + i32(ext.y), glyph, th.accent_fg})
	}
	tx0 := i32(DIALOG_PAD + 44 + 14)
	put(&texts, d.f_title, tx0, DIALOG_PAD, 26, tr(a, "Autenticação necessária", "Authentication required"), th.fg)
	detail := r.command != "" ? r.command : r.action_id
	put(&texts, d.f_small, tx0, DIALOG_PAD + 26, 18, tx.text_ellipsize(c, d.f_small, detail, W - DIALOG_PAD - tx0), th.muted)

	for l, i in msg_lines {
		put(&texts, d.f_body, DIALOG_PAD, y_msg + i32(i) * line_h, line_h, l, th.fg)
	}

	// Who answers; a click (or Tab) switches when several users may.
	who := len(r.users) > 0 ? r.users[r.user] : "?"
	user_label := fmt.tprintf(tr(a, "Como %s", "As %s"), who)
	user_rect := tx.Rect{DIALOG_PAD - 8, y_user, inner + 16, user_h}
	d.parts[.User] = {}
	if len(r.users) > 1 {
		d.parts[.User] = user_rect
		if d.hover == .User { tx.canvas_fill_rounded_rect(&cv, user_rect, 10, th.surface) }
		hint := tr(a, "trocar", "switch")
		hw := tx.text_width(c, d.f_small, hint)
		put(&texts, d.f_small, user_rect.x + user_rect.w - 8 - hw, y_user, user_h, hint, th.accent)
	}
	put(&texts, d.f_body, DIALOG_PAD, y_user, user_h, user_label, th.muted)

	// The field: dots (or the text when it may be shown) and a caret.
	field := tx.Rect{DIALOG_PAD, y_field, inner, FIELD_H}
	d.parts[.Field] = field
	focused := d.asking && !d.checking
	tx.canvas_fill_rounded_rect(&cv, field, 14, focused ? th.bg : th.surface)
	tx.canvas_stroke_rounded_rect(&cv, field, 14, focused ? 2 : 1, focused ? th.accent : tx.color_with_alpha(th.muted, 120))
	fx := field.x + 16
	switch {
	case d.answer_len > 0 && d.echo:
		s := tx.text_ellipsize(c, d.f_body, string(d.answer[:d.answer_len]), field.w - 40)
		put(&texts, d.f_body, fx, field.y, field.h, s, th.fg)
		fx += tx.text_width(c, d.f_body, s) + 2
	case d.answer_len > 0:
		n := utf8.rune_count(d.answer[:d.answer_len])
		dot := f32(4)
		step := i32(14)
		shown := min(n, int((field.w - 40) / step))
		for i in 0 ..< shown {
			tx.canvas_fill_circle(&cv, f32(fx + i32(i) * step) + dot, f32(field.y) + f32(field.h) / 2, dot, th.fg)
		}
		fx += i32(shown) * step + 2
	case:
		placeholder := d.prompt != "" ? d.prompt : tr(a, "Senha", "Password")
		if d.checking { placeholder = "" }
		put(&texts, d.f_body, fx + (focused ? 8 : 0), field.y, field.h, placeholder, th.muted)
	}
	if focused { tx.canvas_fill_rect(&cv, {fx, field.y + 12, 2, field.h - 24}, th.accent) }

	// Status: checking, an error, or the helper's information.
	status, status_color := "", th.muted
	switch {
	case d.checking:   status = tr(a, "Verificando…", "Checking…")
	case d.error != "": status, status_color = d.error, th.warning
	case d.info != "":  status = d.info
	case !d.asking && !d.broken: status = tr(a, "Aguardando o polkit…", "Waiting for polkit…")
	}
	put(&texts, d.f_small, DIALOG_PAD + 4, y_status, status_h, tx.text_ellipsize(c, d.f_small, status, inner - 4), status_color)

	// Buttons, right-aligned: Cancel, Authenticate.
	ok_label := tr(a, "Autenticar", "Authenticate")
	cancel_label := tr(a, "Cancelar", "Cancel")
	ok_w := max(tx.text_width(c, d.f_body, ok_label) + 40, 120)
	cancel_w := max(tx.text_width(c, d.f_body, cancel_label) + 36, 100)
	ok := tx.Rect{W - DIALOG_PAD - ok_w, y_buttons, ok_w, BUTTON_H}
	cn := tx.Rect{ok.x - 10 - cancel_w, y_buttons, cancel_w, BUTTON_H}
	d.parts[.Ok], d.parts[.Cancel] = ok, cn
	can_ok := d.asking && !d.checking && !d.broken
	ok_fill := can_ok ? th.accent : tx.color_mix(th.surface, th.bg, 0.3)
	if can_ok && d.hover == .Ok { ok_fill = tx.color_mix(th.accent, th.bg, 0.18) }
	tx.canvas_fill_rounded_rect(&cv, ok, f32(BUTTON_H) / 2, ok_fill)
	put(&texts, d.f_body, ok.x + (ok.w - tx.text_width(c, d.f_body, ok_label)) / 2, ok.y, ok.h, ok_label, can_ok ? th.accent_fg : th.muted)
	if d.hover == .Cancel { tx.canvas_fill_rounded_rect(&cv, cn, f32(BUTTON_H) / 2, th.surface) }
	put(&texts, d.f_body, cn.x + (cn.w - tx.text_width(c, d.f_body, cancel_label)) / 2, cn.y, cn.h, cancel_label, th.fg)

	pm := tx.canvas_to_pixmap(c, cv)
	ts := tx.text_surface_make(c, xlib.Drawable(pm))
	for t in texts { tx.draw_text(&ts, t.font, t.x, t.y, t.s, t.color) }
	tx.text_surface_destroy(&ts)
	tx.set_background(c, d.win, pm)
	tx.pixmap_free(c, d.pixmap)
	d.pixmap = pm
	tx.flush(c)
}
