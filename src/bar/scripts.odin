// Script widgets (bar.scripts, placed as "script:<name>"): widgets whose
// text comes from a command, like polybar's custom/script. The command runs
// with sh -c as the leader of its own process group (killing it stops
// whatever it started too) and its output arrives through the job pipes, so
// the shared event loop never waits for it.
//
// An interval script runs, shows the first line it printed, and runs again
// `interval` seconds after it finished. A tail script keeps running and every
// line it prints replaces the text; when it ends it is started again after
// `interval` seconds (longer while it keeps ending right away). A click or a
// scroll runs the configured command ("%pid%" is the tail command's process,
// for signals) and, once that command is done, an interval script runs again
// so the widget shows the new state.
//
// A line is plain text or a JSON object {"text": "…", "icon": "…", "state":
// "normal|muted|accent|warning"} (waybar's "class" is read as the state). An
// empty line hides the widget; polybar's formatting tags (%{F#f00}…%{F-})
// are dropped.
package bar

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:unicode/utf8"
import config "../config"
import tx "../tx"

SCRIPT_TIMEOUT       :: 60.0  // seconds an interval command may run before it is killed
SCRIPT_OUTPUT_MAX    :: 65536 // bytes of an interval command's output kept
SCRIPT_TEXT_MAX      :: 512   // bytes of a line shown
SCRIPT_RESTART_MAX   :: 60.0  // longest wait before restarting a tail command that keeps ending
SCRIPT_QUICK_EXIT    :: 10.0  // a tail command that ends sooner counts as failing
SCRIPT_START_RETRY   :: 10.0  // seconds before trying again when a command could not start

Script_Look :: enum { Normal, Muted, Accent, Warning }

Script_State :: struct {
	name:        string, // owned; matches the configuration across reloads
	exec:        string, // owned; a changed command starts the script over
	tail:        bool,
	used:        bool,   // placed on the bar, and the bar is on (only those run)
	job:         ^Job,   // the running command, nil between runs
	next_run:    f64,    // when the command starts next (0 = not scheduled)
	rerun:       bool,   // a click's command ended while the script ran: run it again at once
	failures:    int,    // tail command endings in a row that came too soon
	have_output: bool,   // the command printed a line (until then the widget stays hidden)
	text:        string, // owned: the widget's text
	icon:        string, // owned: the icon of the last JSON line, "" = the configured one
	look:        Script_Look,
	glyph:       Glyph,  // the icon shown (text owned)
	glyph_name:  string, // owned: the icon name `glyph` was made for
	glyph_done:  bool,   // `glyph` matches `glyph_name` (false: resolve again)
	warned:      bool,   // the "could not start" warning was logged
}

@(private)
script_index :: proc(b: ^Bar, name: string) -> int {
	for st, i in b.scripts { if st.name == name { return i } }
	return -1
}

// Match the states to bar.scripts (same order). A script whose command and
// mode did not change keeps its process and its text; a new or changed one
// starts right away; one no longer configured or placed is stopped.
@(private)
scripts_configure :: proc(b: ^Bar) {
	old := b.scripts
	b.scripts = make([dynamic]Script_State, 0, len(b.cfg.bar.scripts))
	now := tx.now()
	for &sc in b.cfg.bar.scripts {
		st: Script_State
		kept := false
		for &o in old {
			if o.name != "" && o.name == sc.name && o.exec == sc.exec && o.tail == sc.tail {
				st = o
				o = {} // moved
				kept = true
				break
			}
		}
		if !kept {
			st.name = strings.clone(sc.name)
			st.exec = strings.clone(sc.exec)
			st.tail = sc.tail
		}
		st.used = b.cfg.bar.enabled && script_placed(b, sc.name)
		if !st.used && st.job != nil {
			kill_job(b, st.job)
			st.job = nil
		}
		if st.used && st.job == nil {
			// A new script starts now; a kept one keeps its turn unless the new interval is shorter.
			st.next_run = st.next_run == 0 || !kept ? now : min(st.next_run, now + sc.interval)
		}
		script_forget_glyph(&st) // the fonts were opened again
		append(&b.scripts, st)
	}
	for &o in old { script_state_destroy(b, &o) }
	delete(old)
}

// Whether "script:<name>" is in bar.start, bar.center or bar.end.
@(private)
script_placed :: proc(b: ^Bar, name: string) -> bool {
	for ids in ([3][]string{b.cfg.bar.start, b.cfg.bar.center, b.cfg.bar.end}) {
		for id in ids {
			if n, is_script := config.script_widget_name(id); is_script && n == name { return true }
		}
	}
	return false
}

@(private)
script_state_destroy :: proc(b: ^Bar, st: ^Script_State) {
	if st.job != nil { kill_job(b, st.job) }
	delete(st.name)
	delete(st.exec)
	delete(st.text)
	delete(st.icon)
	script_forget_glyph(st)
	st^ = {}
}

@(private)
scripts_destroy :: proc(b: ^Bar) {
	for &st in b.scripts { script_state_destroy(b, &st) }
	delete(b.scripts)
	b.scripts = nil
}

@(private)
script_forget_glyph :: proc(st: ^Script_State) {
	delete(st.glyph.text)
	st.glyph = {}
	delete(st.glyph_name)
	st.glyph_name = ""
	st.glyph_done = false
}

// Before the icon fonts close: the glyphs are made again on the next layout.
@(private)
scripts_forget_glyphs :: proc(b: ^Bar) {
	for &st in b.scripts { script_forget_glyph(&st) }
}

// Start the commands whose turn came.
@(private)
scripts_tick :: proc(b: ^Bar, now: f64) {
	if !b.cfg.bar.enabled { return }
	for &st, i in b.scripts {
		if !st.used || st.job != nil || st.next_run == 0 || now < st.next_run { continue }
		script_start(b, i, now)
	}
}

// When the next command starts (-1 = none is waiting).
@(private)
scripts_deadline :: proc(b: ^Bar) -> f64 {
	if !b.cfg.bar.enabled { return -1 }
	deadline := -1.0
	for st in b.scripts {
		if !st.used || st.job != nil || st.next_run == 0 { continue }
		if deadline < 0 || st.next_run < deadline { deadline = st.next_run }
	}
	return deadline
}

@(private)
script_start :: proc(b: ^Bar, index: int, now: f64) {
	st := &b.scripts[index]
	sc := &b.cfg.bar.scripts[index]
	st.next_run = 0
	st.rerun = false
	kind: Job_Kind = sc.tail ? .Script_Tail : .Script_Run
	st.job = start_job(b, kind, group_argv(b, sc.exec), true, sc.tail ? 0 : SCRIPT_TIMEOUT, tag = st.name)
	if st.job == nil {
		if !st.warned { log.warnf("Bar script %q: the command could not start", st.name) }
		st.warned = true
		st.next_run = now + max(sc.interval, SCRIPT_START_RETRY)
		return
	}
	st.job.group = b.tools.setsid
	log.debugf("Bar script %q started (pid %d)", st.name, st.job.pid)
}

// A script's command or a click's command ended.
@(private)
script_job_done :: proc(b: ^Bar, job: ^Job, now: f64) {
	if job.kind == .Script_Action {
		// Show what the click changed: an interval script runs again now
		// (right after the run in progress, if there is one).
		if i := script_index(b, job.tag); i >= 0 {
			st := &b.scripts[i]
			if !st.tail && st.used {
				if st.job != nil { st.rerun = true } else { st.next_run = now }
			}
		}
		return
	}
	for &st, i in b.scripts {
		if st.job != job { continue }
		st.job = nil
		sc := &b.cfg.bar.scripts[i]
		if job.kind == .Script_Run {
			if job.killed {
				log.warnf("Bar script %q ran for more than %.0f s and was stopped", st.name, SCRIPT_TIMEOUT)
			} else {
				script_take_output(b, &st, string(job.output[:]), job_succeeded(job))
			}
			st.next_run = st.rerun ? now : now + sc.interval
		} else {
			// A tail command ended: what it printed last without a newline still counts.
			if len(job.output) > 0 { script_take_line(b, &st, string(job.output[:])) }
			if now - job.started >= SCRIPT_QUICK_EXIT { st.failures = 0 } else { st.failures += 1 }
			delay := max(sc.interval, 1)
			for _ in 1 ..< min(st.failures, 8) { delay *= 2 }
			st.next_run = now + min(delay, max(SCRIPT_RESTART_MAX, sc.interval))
			if st.failures == 3 { log.warnf("Bar script %q keeps ending; it is started again less often", st.name) }
		}
		if !st.used { st.next_run = 0 }
		return
	}
}

// New bytes from a tail command: the last complete line is what shows.
@(private)
script_tail_input :: proc(b: ^Bar, job: ^Job) {
	last := -1
	for ch, i in job.output { if ch == '\n' { last = i } }
	if last < 0 {
		if len(job.output) > SCRIPT_OUTPUT_MAX { clear(&job.output) } // no newline in sight
		return
	}
	start := 0
	for i := last - 1; i >= 0; i -= 1 {
		if job.output[i] == '\n' { start = i + 1; break }
	}
	line := strings.clone(string(job.output[start:last]), context.temp_allocator)
	remove_range(&job.output, 0, last + 1)
	for &st in b.scripts {
		if st.job == job {
			script_take_line(b, &st, line)
			return
		}
	}
}

// What an interval command printed: JSON (possibly over several lines) or
// the first line. A failing command that printed nothing hides the widget.
@(private)
script_take_output :: proc(b: ^Bar, st: ^Script_State, output: string, succeeded: bool) {
	out := strings.trim_space(output)
	if strings.has_prefix(out, "{") && strings.contains(out, "\n") {
		if _, _, _, ok := parse_script_json(out); ok {
			script_take_line(b, st, out)
			return
		}
	}
	line := out
	if nl := strings.index_byte(out, '\n'); nl >= 0 { line = out[:nl] }
	if line == "" && !succeeded { log.debugf("Bar script %q failed without output", st.name) }
	script_take_line(b, st, line)
}

@(private)
script_take_line :: proc(b: ^Bar, st: ^Script_State, raw: string) {
	line := strings.trim_space(raw)
	text, icon := line, ""
	look := Script_Look.Normal
	if strings.has_prefix(line, "{") {
		if t, ic, lk, ok := parse_script_json(line); ok { text, icon, look = t, ic, lk }
	}
	text = clean_script_text(text)
	if st.have_output && text == st.text && icon == st.icon && look == st.look { return }
	st.have_output = true
	delete(st.text)
	st.text = strings.clone(text)
	if icon != st.icon {
		delete(st.icon)
		st.icon = strings.clone(icon)
	}
	st.look = look
	b.dirty = true
}

// {"text", "icon", "state"} (or waybar's "class": a string or a list).
@(private)
parse_script_json :: proc(s: string) -> (text, icon: string, look: Script_Look, ok: bool) {
	value, err := json.parse(transmute([]u8)s, .JSON, false, context.temp_allocator)
	if err != .None { return }
	obj, is_obj := value.(json.Object)
	if !is_obj { return }
	if t, has := obj["text"].(json.String); has { text = t }
	if ic, has := obj["icon"].(json.String); has { icon = strings.trim_space(ic) }
	states := make([dynamic]string, context.temp_allocator)
	for key in ([]string{"state", "class"}) {
		#partial switch v in obj[key] {
		case json.String: append(&states, v)
		case json.Array:
			for item in v { if str, is_str := item.(json.String); is_str { append(&states, str) } }
		}
	}
	for st in states {
		switch strings.to_lower(strings.trim_space(st), context.temp_allocator) {
		case "warning", "critical", "urgent", "error", "bad", "alert": look = .Warning
		case "muted", "inactive", "idle", "disabled", "off":           if look == .Normal { look = .Muted }
		case "accent", "active", "on", "good", "highlight":            if look == .Normal { look = .Accent }
		}
	}
	return text, icon, look, true
}

// One line for the bar: polybar's %{…} tags dropped, control characters
// turned into spaces, at most SCRIPT_TEXT_MAX bytes.
@(private)
clean_script_text :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	rest := s
	for len(rest) > 0 {
		if strings.has_prefix(rest, "%{") {
			if end := strings.index_byte(rest, '}'); end >= 0 {
				rest = rest[end + 1:]
				continue
			}
		}
		r, n := utf8.decode_rune_in_string(rest)
		rest = rest[n:]
		if r == utf8.RUNE_ERROR && n <= 1 { continue }
		if strings.builder_len(sb) + n > SCRIPT_TEXT_MAX { break }
		if r < 0x20 || r == 0x7f { r = ' ' }
		strings.write_rune(&sb, r)
	}
	return strings.trim_space(strings.to_string(sb))
}

// ---------------------------------------------------------------------------
// The widget
// ---------------------------------------------------------------------------
@(private)
script_measure :: proc(b: ^Bar, w: ^Widget) {
	if w.script < 0 || w.script >= len(b.scripts) { return }
	st := &b.scripts[w.script]
	sc := &b.cfg.bar.scripts[w.script]
	if !st.have_output || (st.text == "" && st.icon == "") { return } // an empty line hides it
	if g := script_glyph(b, st, sc); g != nil {
		w.glyph = g
		w.has_icon = true
	}
	limit := sc.max_width > 0 ? sc.max_width : b.cfg.bar.title_max_width
	set_text(b, w, st.text, i32(limit))
	th := &b.theme
	switch st.look {
	case .Normal:
	case .Muted:
		w.icon_color = th.muted
		w.text_color = th.muted
	case .Accent:
		w.icon_color = th.accent
		w.text_color = th.accent
	case .Warning:
		w.icon_color = th.warning
		w.text_color = th.warning
	}
}

// The icon of the last JSON line, else the configured one (nil: none, or
// not in the icon fonts).
@(private)
script_glyph :: proc(b: ^Bar, st: ^Script_State, sc: ^config.Bar_Script) -> ^Glyph {
	name := st.icon != "" ? st.icon : sc.icon
	if !st.glyph_done || name != st.glyph_name {
		script_forget_glyph(st)
		st.glyph_name = strings.clone(name)
		st.glyph_done = true
		if r, any_font, ok := script_icon_rune(b, name); ok {
			if !any_font {
				// A Tabler name: only the Tabler font has the right glyph at that codepoint.
				if b.icons.tabler != nil && tx.font_has_glyph(b.c, b.icons.tabler, r) {
					st.glyph = make_glyph(b, b.icons.tabler, rune_string(r))
				}
			} else {
				for f in b.icons.fonts {
					if tx.font_has_glyph(b.c, f, r) {
						st.glyph = make_glyph(b, f, rune_string(r))
						break
					}
				}
				if !st.glyph.ok && b.font != nil && tx.font_has_glyph(b.c, b.font, r) { st.glyph = make_glyph(b, b.font, rune_string(r)) }
			}
		}
	}
	return st.glyph.ok ? &st.glyph : nil
}

// The character of an icon name (any_font: not a Tabler glyph, any font may draw it).
@(private)
script_icon_rune :: proc(b: ^Bar, name: string) -> (r: rune, any_font: bool, ok: bool) {
	if r, any_font, ok = config.icon_rune(name); ok { return }
	if c, found := tabler_codepoint(b, strings.trim_space(name)); found { return c, false, true }
	return
}

@(private)
script_interactive :: proc(b: ^Bar, w: ^Widget) -> bool {
	if w.script < 0 || w.script >= len(b.cfg.bar.scripts) { return false }
	sc := &b.cfg.bar.scripts[w.script]
	return sc.on_click != "" || sc.on_middle_click != "" || sc.on_right_click != ""
}

// Buttons 1-3 click, 4-5 scroll (up, down).
@(private)
script_button :: proc(b: ^Bar, w: ^Widget, button: i32) {
	if w.script < 0 || w.script >= len(b.cfg.bar.scripts) { return }
	sc := &b.cfg.bar.scripts[w.script]
	st := &b.scripts[w.script]
	command: string
	switch button {
	case 1: command = sc.on_click
	case 2: command = sc.on_middle_click
	case 3: command = sc.on_right_click
	case 4: command = sc.on_scroll_up
	case 5: command = sc.on_scroll_down
	}
	if button <= 3 { close_popups(b) }
	if command == "" { return }
	pid := st.job != nil ? fmt.tprintf("%d", st.job.pid) : ""
	command, _ = strings.replace_all(command, "%pid%", pid, context.temp_allocator)
	job := start_job(b, .Script_Action, group_argv(b, command), false, 0, tag = st.name)
	if job == nil {
		log.warnf("Bar script %q: could not run %s", st.name, command)
		return
	}
	job.group = b.tools.setsid
	log.debugf("Bar script %q: button %d runs %s", st.name, button, command)
}
