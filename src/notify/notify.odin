// Package notify: milk's notification daemon and notification centre.
//
// * A freedesktop Desktop Notifications 1.2 server (dbus.odin) on the session
//   bus, driven by the milk poll loop (poll_fds / handle_fd / tick).
// * Toast popups (popup.odin): Material cards stacked at the top-right (or
//   bottom-right) of the primary monitor's work area, sliding in from the
//   right; they expire, pause while hovered, and carry action buttons.
// * A Windows 11 style side panel (panel.odin): the notification history
//   grouped by application, "clear all", do-not-disturb and a month calendar,
//   sliding in from the right edge of the work area.
//
// Persistence: an expired popup only hides; the notification stays in the
// panel (the "persistence" capability) until it is dismissed, clicked,
// closed by its sender or pushed out of the history. Transient notifications
// skip the history and are closed (reason 1) when their popup expires.
//
// Like every milk component, frames are composed on a CPU canvas over a copy
// of the screen taken before the window appears (no compositor needed).
package notify

import "base:runtime"
import "core:log"
import "core:strings"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

@(private) FRAME :: 1.0 / 60.0

Action :: struct {
	key:   string,
	label: string,
}

Notification :: struct {
	id:            u32,
	app_name:      string, // as sent, or the desktop entry's Name
	app_icon:      string,
	summary:       string,
	body:          string, // plain text: markup stripped, entities decoded
	desktop_entry: string,
	actions:       [dynamic]Action, // "default" included (has_default)
	urgency:       u8,  // 0 low, 1 normal, 2 critical
	expire_ms:     i32, // -1 = server default, 0 = never
	transient:     bool,
	resident:      bool,
	has_default:   bool,
	image:         tx.Image, // large picture (BIG_ICON square); rgba == nil = none
	icon:          tx.Image, // small application icon (SMALL_ICON square); rgba == nil = none
	unix_time:     i64,      // arrival, seconds since the epoch
	read:          bool,
}

@(private)
Theme :: struct {
	background, foreground, muted, accent, accent_foreground, surface, warning: tx.Color,
	secondary: tx.Color, // body text
	hover:     tx.Color, // hovered buttons
	outline:   tx.Color,
}

@(private)
Fonts :: struct {
	title:  ^tx.Font, // summary (bold)
	body:   ^tx.Font,
	small:  ^tx.Font, // app names, times
	header: ^tx.Font, // panel titles (bold)
	icons:  ^tx.Font, // Tabler, button size
	big:    ^tx.Font, // Tabler, empty state
}

Notifier :: struct {
	c:          ^tx.Connection,
	cfg:        ^config.Config, // owned by the caller
	allocator:  runtime.Allocator,
	bus:        ^DBusConnection,
	bus_fd:     i32,
	bus_state:  Bus_State,
	owner_label: string, // program owning the name while milk waits ("noctalia")
	next_id:    u32,
	history:    [dynamic]^Notification, // oldest first
	dnd:        bool, // do not disturb (runtime; follows the config when it changes)
	cfg_dnd:    bool, // the configuration value last seen
	paused:     bool, // the screen is locked: no popups (history still collected)
	started:    bool,
	theme:      Theme,
	fonts:      Fonts,
	icons:      Icon_Loader,
	popups:     [dynamic]^Popup,
	column_rect: tx.Rect, // where popups stack (work-area edge), computed when the first popup appears
	clip_right:  i32,     // right edge of the primary monitor: sliding windows are cut there
	panel:      Panel,
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// Connect to the session bus and ask for org.freedesktop.Notifications
// (taking it over when allowed, otherwise waiting in the queue). Returns false
// only when notifications are disabled; without a bus it runs panel-only.
create :: proc(c: ^tx.Connection, cfg: ^config.Config) -> (^Notifier, bool) {
	if c == nil || cfg == nil { return nil, false }
	if !cfg.notifications.enabled {
		log.info("Notifications: disabled in the configuration")
		return nil, false
	}
	n := new(Notifier)
	n.c = c
	n.cfg = cfg
	n.allocator = context.allocator
	n.bus_fd = -1
	n.next_id = 1
	n.dnd = cfg.notifications.do_not_disturb
	n.cfg_dnd = n.dnd
	n.panel.hover = -1
	// Without a bus (or while another daemon owns the name) the panel still
	// works: create only fails when notifications are disabled.
	bus_open(n)
	apply_look(n)
	icons_init(&n.icons, cfg)
	return n, true
}

destroy :: proc(n: ^Notifier) {
	if n == nil { return }
	context.allocator = n.allocator
	panel_destroy(n)
	for p in n.popups { popup_free(n, p) }
	delete(n.popups)
	for notif in n.history { notification_free(notif) }
	delete(n.history)
	bus_close(n)
	delete(n.owner_label)
	release_look(n)
	icons_destroy(&n.icons)
	free(n)
}

start :: proc(n: ^Notifier) {
	if n == nil { return }
	n.started = true
}

// Events for the notifier's own windows (popups and panel). Returns true when used.
handle_event :: proc(n: ^Notifier, ev: ^xlib.XEvent) -> bool {
	if n == nil { return false }
	context.allocator = n.allocator
	win := ev.xany.window
	if n.panel.win != 0 && win == n.panel.win {
		panel_event(n, ev)
		return true
	}
	if n.panel.cal_win != 0 && win == n.panel.cal_win {
		panel_event_calendar(n, ev)
		return true
	}
	for p in n.popups {
		if p.win == win {
			popup_event(n, p, ev)
			return true
		}
	}
	return false
}

tick :: proc(n: ^Notifier, now: f64) {
	if n == nil { return }
	context.allocator = n.allocator
	// Messages may already sit in libdbus' queue (read during a flush).
	bus_pump(n, false)
	popups_tick(n, now)
	panel_tick(n, now)
	tx.flush(n.c)
}

// Seconds until tick must run again; -1 = idle.
next_timeout :: proc(n: ^Notifier, now: f64) -> f64 {
	if n == nil { return -1 }
	t := popups_timeout(n, now)
	if bus_has_input(n) { return 0 }
	if bus_has_output(n) && (t < 0 || t > 0.01) { t = 0.01 }
	pt := panel_timeout(n, now)
	if pt >= 0 && (t < 0 || pt < t) { t = pt }
	return t
}

poll_fds :: proc(n: ^Notifier, allocator := context.temp_allocator) -> []i32 {
	if n == nil || n.bus == nil || n.bus_fd < 0 { return nil }
	fds := make([]i32, 1, allocator)
	fds[0] = n.bus_fd
	return fds
}

handle_fd :: proc(n: ^Notifier, fd: i32) {
	if n == nil || fd != n.bus_fd { return }
	context.allocator = n.allocator
	bus_pump(n, true)
	tx.flush(n.c)
}

// No popups while the screen is locked (they would show what the lock screen
// hides until it raises itself again); notifications still reach the history.
set_paused :: proc(n: ^Notifier, paused: bool) {
	if n == nil || n.paused == paused { return }
	context.allocator = n.allocator
	n.paused = paused
	if paused { popups_hide_all(n) }
}

// The configuration was reloaded (`cfg` replaces the previous one).
reload :: proc(n: ^Notifier, cfg: ^config.Config) {
	if n == nil || cfg == nil { return }
	context.allocator = n.allocator
	was_open := n.panel.open
	panel_hide_now(n)
	popups_hide_all(n)
	n.cfg = cfg
	if cfg.notifications.do_not_disturb != n.cfg_dnd {
		n.dnd = cfg.notifications.do_not_disturb
		n.cfg_dnd = n.dnd
	}
	release_look(n)
	apply_look(n)
	history_trim(n)
	if was_open { panel_show(n) }
}

// New colours only (the wallpaper theme): popups and the panel stay where
// they are and are painted again.
retheme :: proc(n: ^Notifier, cfg: ^config.Config) {
	if n == nil || cfg == nil { return }
	context.allocator = n.allocator
	n.cfg = cfg
	release_look(n)
	apply_look(n)
	for p in n.popups { if p.win != 0 { popup_render(n, p) } }
	if n.panel.open && n.panel.win != 0 { panel_render(n) }
	tx.flush(n.c)
}

toggle_panel :: proc(n: ^Notifier) {
	if n == nil { return }
	context.allocator = n.allocator
	if panel_open(n) {
		close_panel(n)
	} else {
		panel_show(n)
	}
}

panel_open :: proc(n: ^Notifier) -> bool {
	if n == nil { return false }
	return n.panel.open && n.panel.phase != .Closing
}

close_panel :: proc(n: ^Notifier) {
	if n == nil { return }
	context.allocator = n.allocator
	panel_start_close(n)
}

// Notifications not seen in the panel yet (the bar shows a badge when > 0).
unread_count :: proc(n: ^Notifier) -> int {
	if n == nil { return 0 }
	count := 0
	for notif in n.history { if !notif.read && !notif.transient { count += 1 } }
	return count
}

window_ids :: proc(n: ^Notifier, allocator := context.temp_allocator) -> []xlib.Window {
	if n == nil { return nil }
	out := make([dynamic]xlib.Window, allocator)
	if n.panel.win != 0 { append(&out, n.panel.win) }
	if n.panel.cal_win != 0 { append(&out, n.panel.cal_win) }
	for p in n.popups { if p.win != 0 { append(&out, p.win) } }
	return out[:]
}

// ---------------------------------------------------------------------------
// Look
// ---------------------------------------------------------------------------
@(private)
apply_look :: proc(n: ^Notifier) {
	th := &n.cfg.bar.theme
	t := &n.theme
	t.background = tx.color_from_hex(th.background, tx.rgb(0xF5, 0xEE, 0xE6))
	t.foreground = tx.color_from_hex(th.foreground, tx.rgb(0x3C, 0x3A, 0x38))
	t.muted = tx.color_from_hex(th.muted, tx.rgb(0xA8, 0x9E, 0x94))
	t.accent = tx.color_from_hex(th.accent, tx.rgb(0x4A, 0x3F, 0x35))
	t.accent_foreground = tx.color_from_hex(th.accent_foreground, tx.rgb(0xF5, 0xEE, 0xE6))
	t.surface = tx.color_from_hex(th.surface, tx.rgb(0xE9, 0xE0, 0xD6))
	t.warning = tx.color_from_hex(th.warning, tx.rgb(0xB5, 0x47, 0x3A))
	t.background.a = 255
	t.surface.a = 255
	t.secondary = tx.color_mix(t.foreground, t.muted, 0.45)
	t.hover = tx.color_mix(t.surface, t.muted, 0.30)
	t.outline = tx.color_with_alpha(t.muted, 60)

	size := i32(max(n.cfg.bar.font_size, 10))
	font := n.cfg.bar.font if n.cfg.bar.font != "" else "sans"
	open :: proc(c: ^tx.Connection, pattern: string, px: i32) -> ^tx.Font {
		f, ok := tx.font_open(c, pattern, px)
		if !ok { f, _ = tx.font_open(c, "sans", px) }
		return f
	}
	bold := strings.concatenate({font, ":bold"}, context.temp_allocator)
	n.fonts.title = open(n.c, bold, size)
	n.fonts.body = open(n.c, font, size - 1)
	n.fonts.small = open(n.c, font, size - 2)
	n.fonts.header = open(n.c, bold, size + 2)
	if n.cfg.bar.icon_font_file != "" {
		n.fonts.icons, _ = tx.font_open_file(n.c, n.cfg.bar.icon_font_file, 18)
		n.fonts.big, _ = tx.font_open_file(n.c, n.cfg.bar.icon_font_file, 44)
	}
}

@(private)
release_look :: proc(n: ^Notifier) {
	f := &n.fonts
	for font in ([]^tx.Font{f.title, f.body, f.small, f.header, f.icons, f.big}) {
		if font != nil { tx.font_close(n.c, font) }
	}
	f^ = {}
}

@(private)
tr :: proc(n: ^Notifier, pt, en: string) -> string { return config.tr(n.cfg.bar.language, pt, en) }

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------
@(private)
find_notification :: proc(n: ^Notifier, id: u32) -> (^Notification, int) {
	for notif, i in n.history { if notif.id == id { return notif, i } }
	return nil, -1
}

// A Notify call: create or replace, show the popup, return the id.
@(private)
notification_post :: proc(n: ^Notifier, req: ^Notify_Request) -> u32 {
	context.allocator = n.allocator
	notif: ^Notification
	if req.replaces_id != 0 {
		index: int
		notif, index = find_notification(n, req.replaces_id)
		// A replacement moves to the top of the list.
		if notif != nil { ordered_remove(&n.history, index) }
	}
	if notif != nil {
		notification_clear_fields(notif)
	} else {
		notif = new(Notification)
		notif.id = n.next_id
		n.next_id += 1
		if n.next_id == 0 { n.next_id = 1 }
	}
	notif.app_name = strings.clone(req.app_name)
	notif.app_icon = strings.clone(req.app_icon)
	notif.summary = strings.clone(strip_markup(req.summary, context.temp_allocator))
	notif.body = strings.clone(strip_markup(req.body, context.temp_allocator))
	notif.desktop_entry = strings.clone(req.desktop_entry)
	notif.actions = make([dynamic]Action)
	for a in req.actions {
		if a.key == "default" { notif.has_default = true }
		append(&notif.actions, Action{key = strings.clone(a.key), label = strings.clone(strip_markup(a.label, context.temp_allocator))})
	}
	notif.urgency = req.urgency
	notif.expire_ms = req.expire_ms
	notif.transient = req.transient
	notif.resident = req.resident
	notif.unix_time = now_unix()
	notif.read = n.panel.open
	resolve_images(n, notif, req)
	append(&n.history, notif)
	id := notif.id
	log.debugf("Notifications: #%d from %q: %q", id, notif.app_name, notif.summary)
	history_trim(n)

	if !n.panel.open && !n.dnd && !n.paused && n.started {
		popup_show(n, notif)
	} else {
		if n.panel.open { panel_refresh(n) }
		// Transient and not shown: nothing keeps it.
		if notif.transient { notification_remove(n, id, .Expired) }
	}
	return id
}

// Remove a notification everywhere and tell its sender.
@(private)
notification_remove :: proc(n: ^Notifier, id: u32, reason: Close_Reason) {
	notif, index := find_notification(n, id)
	if notif == nil { return }
	ordered_remove(&n.history, index)
	popup_forget(n, id)
	emit_closed(n, id, reason)
	notification_free(notif)
	if n.panel.open { panel_refresh(n) }
}

// The user activated a notification (body click or button).
@(private)
notification_invoke :: proc(n: ^Notifier, id: u32, key: string) {
	notif, _ := find_notification(n, id)
	if notif == nil { return }
	if key != "" { emit_action(n, id, key) }
	if notif.resident {
		popup_forget(n, id)
		if n.panel.open { panel_refresh(n) }
	} else {
		notification_remove(n, id, .Dismissed)
	}
}

// The popup of a notification went away by itself (expired or pushed out):
// transient notifications end there, the others stay in the panel.
@(private)
notification_popup_gone :: proc(n: ^Notifier, id: u32) {
	notif, _ := find_notification(n, id)
	if notif != nil && notif.transient { notification_remove(n, id, .Expired) }
}

// Keep at most max_history notifications (transient ones do not count).
@(private)
history_trim :: proc(n: ^Notifier) {
	limit := max(n.cfg.notifications.max_history, 1)
	for {
		count := 0
		oldest: ^Notification
		for notif in n.history {
			if notif.transient { continue }
			if oldest == nil { oldest = notif }
			count += 1
		}
		if count <= limit || oldest == nil { break }
		notification_remove(n, oldest.id, .Expired)
	}
}

// A deep copy (popups keep one so they can still slide out after removal).
@(private)
notification_clone :: proc(src: ^Notification) -> ^Notification {
	dst := new(Notification)
	dst^ = src^
	dst.app_name = strings.clone(src.app_name)
	dst.app_icon = strings.clone(src.app_icon)
	dst.summary = strings.clone(src.summary)
	dst.body = strings.clone(src.body)
	dst.desktop_entry = strings.clone(src.desktop_entry)
	dst.actions = make([dynamic]Action)
	for a in src.actions { append(&dst.actions, Action{key = strings.clone(a.key), label = strings.clone(a.label)}) }
	dst.image = {}
	dst.icon = {}
	if src.image.rgba != nil {
		dst.image = tx.image_make(src.image.w, src.image.h)
		copy(dst.image.rgba, src.image.rgba)
	}
	if src.icon.rgba != nil {
		dst.icon = tx.image_make(src.icon.w, src.icon.h)
		copy(dst.icon.rgba, src.icon.rgba)
	}
	return dst
}

@(private)
notification_clear_fields :: proc(notif: ^Notification) {
	delete(notif.app_name)
	delete(notif.app_icon)
	delete(notif.summary)
	delete(notif.body)
	delete(notif.desktop_entry)
	for a in notif.actions {
		delete(a.key)
		delete(a.label)
	}
	delete(notif.actions)
	notif.actions = nil
	notif.has_default = false
	tx.image_destroy(&notif.image)
	tx.image_destroy(&notif.icon)
	notif.image = {}
	notif.icon = {}
}

@(private)
notification_free :: proc(notif: ^Notification) {
	notification_clear_fields(notif)
	free(notif)
}

// Buttons shown for a notification (the "default" action is the body click).
@(private)
visible_actions :: proc(notif: ^Notification, allocator := context.temp_allocator) -> []Action {
	out := make([dynamic]Action, allocator)
	for a in notif.actions {
		if a.key == "default" || a.label == "" { continue }
		append(&out, a)
	}
	return out[:]
}

// "Firefox", or the desktop entry, or a generic name.
@(private)
display_app_name :: proc(n: ^Notifier, notif: ^Notification) -> string {
	if notif.app_name != "" { return notif.app_name }
	if notif.desktop_entry != "" { return notif.desktop_entry }
	return tr(n, "Notificação", "Notification")
}

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

// Plain text from the spec's markup subset: tags removed (<br> becomes a new
// line), entities decoded, runs of blank lines collapsed.
strip_markup :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		ch := s[i]
		if ch == '<' {
			end := strings.index_byte(s[i:], '>')
			if end < 0 {
				strings.write_byte(&sb, ch)
				i += 1
				continue
			}
			tag := strings.to_lower(strings.trim_space(s[i + 1:i + end]), context.temp_allocator)
			if strings.has_prefix(tag, "br") || tag == "/p" { strings.write_byte(&sb, '\n') }
			i += end + 1
			continue
		}
		if ch == '&' {
			end := strings.index_byte(s[i:], ';')
			if end > 1 && end <= 10 {
				entity := s[i + 1:i + end]
				decoded := ""
				switch entity {
				case "amp":  decoded = "&"
				case "lt":   decoded = "<"
				case "gt":   decoded = ">"
				case "quot": decoded = "\""
				case "apos": decoded = "'"
				case "nbsp": decoded = " "
				case:
					if len(entity) > 1 && entity[0] == '#' {
						code := 0
						valid := true
						if entity[1] == 'x' || entity[1] == 'X' {
							for d in entity[2:] {
								switch d {
								case '0' ..= '9': code = code * 16 + int(d - '0')
								case 'a' ..= 'f': code = code * 16 + int(d - 'a') + 10
								case 'A' ..= 'F': code = code * 16 + int(d - 'A') + 10
								case: valid = false
								}
							}
						} else {
							for d in entity[1:] {
								if d < '0' || d > '9' { valid = false; break }
								code = code * 10 + int(d - '0')
							}
						}
						if valid && code > 0 && code < 0x110000 {
							strings.write_rune(&sb, rune(code))
							i += end + 1
							continue
						}
					}
				}
				if decoded != "" {
					strings.write_string(&sb, decoded)
					i += end + 1
					continue
				}
			}
		}
		strings.write_byte(&sb, ch)
		i += 1
	}
	text := strings.trim_space(strings.to_string(sb))
	for strings.contains(text, "\n\n\n") {
		text, _ = strings.replace_all(text, "\n\n\n", "\n\n", allocator)
	}
	return text
}

// Word-wrap `s` into at most `max_lines` lines of `max_w` pixels; the last
// line is ellipsised when text remains.
@(private)
wrap_text :: proc(c: ^tx.Connection, f: ^tx.Font, s: string, max_w: i32, max_lines: int, allocator := context.temp_allocator) -> []string {
	lines := make([dynamic]string, allocator)
	if f == nil || s == "" || max_lines <= 0 { return lines[:] }
	paragraphs := strings.split_lines(s, context.temp_allocator)
	for para, pi in paragraphs {
		rest := strings.trim_space(para)
		if rest == "" {
			// Keep single blank lines between paragraphs, not at the ends.
			if len(lines) > 0 && pi < len(paragraphs) - 1 && len(lines) < max_lines && lines[len(lines) - 1] != "" { append(&lines, "") }
			continue
		}
		for rest != "" {
			if len(lines) == max_lines {
				// Text remains: ellipsise the last line with what follows.
				last := lines[len(lines) - 1]
				joined := strings.concatenate({last, " ", rest}, context.temp_allocator)
				lines[len(lines) - 1] = tx.text_ellipsize(c, f, joined, max_w, allocator)
				if tx.text_width(c, f, joined) <= max_w { lines[len(lines) - 1] = strings.concatenate({last, "…"}, allocator) }
				return lines[:]
			}
			if tx.text_width(c, f, rest) <= max_w {
				append(&lines, rest)
				break
			}
			// Longest prefix ending at a space that fits.
			cut := -1
			for idx := 0; idx < len(rest); idx += 1 {
				if rest[idx] != ' ' { continue }
				if tx.text_width(c, f, rest[:idx]) > max_w { break }
				cut = idx
			}
			if cut <= 0 {
				// One long word: break it at the last rune that fits.
				cut = 0
				for _, ri in rest {
					if ri == 0 { continue }
					if tx.text_width(c, f, rest[:ri]) > max_w { break }
					cut = ri
				}
				if cut == 0 { cut = len(rest) }
				append(&lines, rest[:cut])
				rest = strings.trim_left_space(rest[cut:])
			} else {
				append(&lines, rest[:cut])
				rest = strings.trim_left_space(rest[cut + 1:])
			}
		}
	}
	for len(lines) > 0 && lines[len(lines) - 1] == "" { pop(&lines) }
	return lines[:]
}
