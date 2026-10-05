// Settings → Barra → Scripts: the script widgets (bar.scripts), widgets
// whose text is what a command prints. A list, ready-made examples and an
// editor: name, icon, the command (with a Test button that runs it once and
// shows what it printed), how it runs (again after an interval, or always
// running with every line it prints) and what a click does. A new script
// goes on the bar at the start of the end group; the Widgets tab moves it
// like any other widget. Fields milk.json may have that the editor does not
// show (other buttons, the scroll wheel, maxWidth) are kept.
package oobe

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:unicode/utf8"
import config "../config"
import tx "../tx"

// Zone entries of the widget editor (Layout_Editor.zones) from here on are
// scripts: SCRIPT_ENTRY + index into Scripts_State.list.
@(private) SCRIPT_ENTRY :: 10000

@(private) SCRIPT_TEST_TIMEOUT :: 8.0   // seconds a test may run
@(private) SCRIPT_TEST_OUTPUT  :: 16384 // bytes of its output kept

// The interval stepper's values (seconds).
@(private, rodata)
SCRIPT_INTERVALS := []f64{1, 2, 3, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600}

@(private)
User_Script :: struct {
	name, exec, icon, on_click: string, // owned
	on_middle_click, on_right_click, on_scroll_up, on_scroll_down: string, // owned; not in the editor, kept
	interval:  f64,
	tail:      bool,
	max_width: int,
}

@(private)
Script_Example :: struct {
	pt, en:   string,
	icon:     string,
	exec:     string,
	interval: f64,
	tail:     bool,
}

@(private, rodata)
SCRIPT_EXAMPLES := []Script_Example{
	{"Processador", "CPU", "cpu",
	 `while :; do set -- $(head -n1 /proc/stat); t=$(($2+$3+$4+$5+$6+$7+$8+$9)); i=$(($5+$6)); [ -n "$pt" ] && [ "$t" -gt "$pt" ] && echo "$((100 - 100*(i-pi)/(t-pt)))%"; pt=$t; pi=$i; sleep 2; done`,
	 2, true},
	{"Memória", "Memory", "chart-pie",
	 `awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "%d%%\n", (t-a)*100/t}' /proc/meminfo`, 5, false},
	{"Temperatura", "Temperature", "temperature",
	 `for h in /sys/class/hwmon/hwmon*; do case "$(cat "$h/name")" in k10temp|coretemp|zenpower|cpu_thermal|acpitz) awk '{printf "%d°C\n", $1/1000; exit}' "$h/temp1_input"; exit;; esac; done`,
	 5, false},
	{"Disco livre", "Free disk", "database", `df -h --output=avail / | tail -n1 | tr -d ' '`, 60, false},
	{"Clima", "Weather", "cloud", `curl -sf 'https://wttr.in/?format=%t' | tr -d '+'`, 900, false},
}

// A run of the edited command (the Test button).
@(private)
Script_Test :: struct {
	running: bool,
	pid:     posix.pid_t,
	group:   bool,     // the command leads its own process group (setsid)
	file:    ^os.File, // read end of its stdout and stderr; nil once closed
	output:  [dynamic]u8,
	started: f64,
	tail:    bool,     // an always-running command: its first line is enough
	result:  string,   // owned: what it printed, or why there is nothing
	failed:  bool,
}

@(private)
Script_Editor :: struct {
	open:           bool,
	original:       int, // index into the list, -1 = a new script
	name, exec:     [dynamic]u8,
	icon, click:    [dynamic]u8,
	interval:       f64,
	tail:           bool,
	picking:        bool,   // choosing the icon
	error:          string, // literal
	confirm_delete: bool,
	test:           Script_Test,
}

@(private)
Scripts_State :: struct {
	loaded:       bool,
	list:         [dynamic]User_Script, // bar.scripts as edited
	dirty:        bool,                 // write bar.scripts on the next save
	scroll:       i32,
	ed:           Script_Editor,
	names:        map[string]rune, // the whole Tabler map, for icons beyond AREA_ICONS
	names_loaded: bool,
}

@(private)
scripts_load :: proc(w: ^Wizard) {
	s := &w.set.scr
	if s.loaded { return }
	s.loaded = true
	for sc in w.cfg.bar.scripts {
		append(&s.list, User_Script{
			name = strings.clone(sc.name), exec = strings.clone(sc.exec), icon = strings.clone(sc.icon),
			on_click = strings.clone(sc.on_click), on_middle_click = strings.clone(sc.on_middle_click),
			on_right_click = strings.clone(sc.on_right_click), on_scroll_up = strings.clone(sc.on_scroll_up),
			on_scroll_down = strings.clone(sc.on_scroll_down), interval = sc.interval, tail = sc.tail, max_width = sc.max_width,
		})
	}
}

@(private)
user_script_destroy :: proc(u: ^User_Script) {
	delete(u.name); delete(u.exec); delete(u.icon); delete(u.on_click)
	delete(u.on_middle_click); delete(u.on_right_click); delete(u.on_scroll_up); delete(u.on_scroll_down)
	u^ = {}
}

@(private)
scripts_destroy :: proc(w: ^Wizard) {
	s := &w.set.scr
	scr_test_stop(w)
	delete(s.ed.test.output)
	delete(s.ed.test.result)
	delete(s.ed.name); delete(s.ed.exec); delete(s.ed.icon); delete(s.ed.click)
	for &u in s.list { user_script_destroy(&u) }
	delete(s.list)
	for name in s.names { delete(name) }
	delete(s.names)
	s^ = {}
}

@(private)
script_list_index :: proc(w: ^Wizard, name: string) -> int {
	for u, i in w.set.scr.list { if u.name == name { return i } }
	return -1
}

// bar.scripts as JSON (rewritten whole: renamed and deleted scripts must disappear).
@(private)
scripts_json :: proc(w: ^Wizard) -> json.Object {
	obj := make(json.Object, context.temp_allocator)
	for u in w.set.scr.list {
		o := make(json.Object, context.temp_allocator)
		o["exec"] = json.String(u.exec)
		o["interval"] = u.interval == math.floor(u.interval) ? json.Value(json.Integer(i64(u.interval))) : json.Value(json.Float(u.interval))
		if u.tail { o["tail"] = json.Boolean(true) }
		if u.max_width > 0 { o["maxWidth"] = json.Integer(i64(u.max_width)) }
		for kv in ([][2]string{{"icon", u.icon}, {"onClick", u.on_click}, {"onMiddleClick", u.on_middle_click}, {"onRightClick", u.on_right_click},
		                       {"onScrollUp", u.on_scroll_up}, {"onScrollDown", u.on_scroll_down}}) {
			if kv[1] != "" { o[kv[0]] = json.String(kv[1]) }
		}
		obj[u.name] = o
	}
	return obj
}

// ---------------------------------------------------------------------------
// Widget editor entries (barlayout.odin)
// ---------------------------------------------------------------------------
@(private)
lay_entry_id :: proc(w: ^Wizard, v: int) -> string {
	if v < SCRIPT_ENTRY { return BAR_WIDGET_INFO[v].id }
	k := v - SCRIPT_ENTRY
	if k >= len(w.set.scr.list) { return "" }
	return strings.concatenate({config.SCRIPT_WIDGET_PREFIX, w.set.scr.list[k].name}, context.temp_allocator)
}

@(private)
lay_entry_label :: proc(w: ^Wizard, v: int) -> string {
	if v < SCRIPT_ENTRY { return tr(w, BAR_WIDGET_INFO[v].pt, BAR_WIDGET_INFO[v].en) }
	k := v - SCRIPT_ENTRY
	if k >= len(w.set.scr.list) { return "" }
	return w.set.scr.list[k].name
}

// The entry's icon: a built-in widget's, or the script's own (the code icon without one).
@(private)
draw_entry_icon :: proc(w: ^Wizard, r: tx.Rect, v: int, color: tx.Color, clip := tx.Rect{}) {
	if v < SCRIPT_ENTRY {
		icon(w, w.f_icon_small, r, BAR_WIDGET_INFO[v].icon, color, clip)
		return
	}
	k := v - SCRIPT_ENTRY
	draw_script_icon(w, r, k < len(w.set.scr.list) ? w.set.scr.list[k].icon : "", color, clip)
}

// A script was deleted: its entries go, the later scripts' move down by one.
@(private)
lay_script_removed :: proc(w: ^Wizard, k: int) {
	lay := &w.set.lay
	for &z in lay.zones {
		for i := len(z) - 1; i >= 0; i -= 1 {
			switch {
			case z[i] == SCRIPT_ENTRY + k: ordered_remove(&z, i)
			case z[i] > SCRIPT_ENTRY + k:  z[i] -= 1
			}
		}
	}
	lay.sel = -1
}

@(private)
script_on_bar :: proc(w: ^Wizard, k: int) -> bool {
	for z in w.set.lay.zones {
		for v in z { if v == SCRIPT_ENTRY + k { return true } }
	}
	return false
}

// ---------------------------------------------------------------------------
// Icons
// ---------------------------------------------------------------------------
// An icon name as text, and the font to draw it with ("" when there is none):
// a Tabler name in the icon font `f`; one character or U+XXXX in `f` or the text font.
@(private)
script_icon_text :: proc(w: ^Wizard, f: ^tx.Font, name: string) -> (glyph: string, font: ^tx.Font) {
	r, any_font, ok := config.icon_rune(name)
	if !ok {
		n := strings.trim_space(name)
		if n == "" { return }
		s := &w.set.scr
		if !s.names_loaded {
			s.names_loaded = true
			config.load_tabler_names(w.cfg.bar.icon_font_file, &s.names)
		}
		r, ok = s.names[n]
		if !ok { return }
	}
	buf, n := utf8.encode_rune(r)
	text := strings.clone(string(buf[:n]), context.temp_allocator)
	if f != nil && tx.font_has_glyph(w.c, f, r) { return text, f }
	if any_font && w.f_body != nil && tx.font_has_glyph(w.c, w.f_body, r) { return text, w.f_body }
	return
}

@(private)
draw_script_icon :: proc(w: ^Wizard, r: tx.Rect, name: string, color: tx.Color, clip := tx.Rect{}) {
	if glyph, font := script_icon_text(w, w.f_icon_small, name); glyph != "" {
		text_centered(w, font, r, glyph, color, clip)
	} else {
		icon(w, w.f_icon_small, r, .Code, color, clip)
	}
}

// ---------------------------------------------------------------------------
// The editor
// ---------------------------------------------------------------------------
@(private)
unique_script_name :: proc(w: ^Wizard, base: string) -> string {
	taken :: proc(w: ^Wizard, name: string) -> bool {
		for u in w.set.scr.list { if strings.equal_fold(u.name, name) { return true } }
		return false
	}
	if !taken(w, base) { return base }
	for n in 2 ..< 1000 {
		name := fmt.tprintf("%s %d", base, n)
		if !taken(w, name) { return name }
	}
	return base
}

@(private)
set_buffer :: proc(buf: ^[dynamic]u8, s: string) {
	clear(buf)
	append(buf, ..transmute([]u8)s)
}

// Open the editor on script `index`, on example `example`, or on a new script.
@(private)
scr_open :: proc(w: ^Wizard, index: int, example := -1) {
	s := &w.set.scr
	ed := &s.ed
	scr_test_stop(w)
	scr_test_clear(ed)
	ed.open = true
	ed.original = -1
	ed.picking = false
	ed.error = ""
	ed.confirm_delete = false
	ed.interval = config.SCRIPT_INTERVAL_DEFAULT
	ed.tail = false
	set_buffer(&ed.icon, "")
	set_buffer(&ed.click, "")
	set_buffer(&ed.exec, "")
	switch {
	case index >= 0 && index < len(s.list):
		u := s.list[index]
		ed.original = index
		set_buffer(&ed.name, u.name)
		set_buffer(&ed.exec, u.exec)
		set_buffer(&ed.icon, u.icon)
		set_buffer(&ed.click, u.on_click)
		ed.interval = u.interval
		ed.tail = u.tail
	case example >= 0 && example < len(SCRIPT_EXAMPLES):
		e := SCRIPT_EXAMPLES[example]
		set_buffer(&ed.name, unique_script_name(w, tr(w, e.pt, e.en)))
		set_buffer(&ed.exec, e.exec)
		set_buffer(&ed.icon, e.icon)
		ed.interval = e.interval
		ed.tail = e.tail
	case:
		set_buffer(&ed.name, unique_script_name(w, tr(w, "Meu widget", "My widget")))
	}
	w.focus = .None
	w.hover = {}
}

@(private)
scr_close :: proc(w: ^Wizard) {
	ed := &w.set.scr.ed
	scr_test_stop(w)
	ed.open = false
	ed.picking = false
	w.focus = .None
	w.hover = {}
}

@(private)
replace_string :: proc(dst: ^string, value: string) {
	delete(dst^)
	dst^ = strings.clone(value)
}

@(private)
scr_save :: proc(w: ^Wizard) {
	lay_load(w)
	s := &w.set.scr
	ed := &s.ed
	name := strings.trim_space(string(ed.name[:]))
	exec := strings.trim_space(string(ed.exec[:]))
	icon := strings.trim_space(string(ed.icon[:]))
	click := strings.trim_space(string(ed.click[:]))
	switch {
	case !config.valid_script_name(name):
		ed.error = tr(w, "Dê um nome ao widget (até 40 letras).", "Give the widget a name (up to 40 letters).")
		return
	case exec == "":
		ed.error = tr(w, "Escreva o comando cuja saída aparece na barra.", "Write the command whose output shows on the bar.")
		return
	}
	for u, i in s.list {
		if i != ed.original && strings.equal_fold(u.name, name) {
			ed.error = tr(w, "Já existe um widget com esse nome.", "There is already a widget with that name.")
			return
		}
	}
	if ed.original >= 0 && ed.original < len(s.list) {
		u := &s.list[ed.original]
		if u.name != name { w.set.lay.dirty = true } // its id in bar.start/center/end changes
		replace_string(&u.name, name)
		replace_string(&u.exec, exec)
		replace_string(&u.icon, icon)
		replace_string(&u.on_click, click)
		u.interval = ed.interval
		u.tail = ed.tail
	} else {
		append(&s.list, User_Script{name = strings.clone(name), exec = strings.clone(exec), icon = strings.clone(icon),
		                            on_click = strings.clone(click), interval = ed.interval, tail = ed.tail})
		// On the bar right away, before the end group's other widgets.
		inject_at(&w.set.lay.zones[2], 0, SCRIPT_ENTRY + len(s.list) - 1)
		w.set.lay.dirty = true
		s.scroll = max(i32) // the list shows it (list_begin clamps)
	}
	s.dirty = true
	scr_close(w)
	settings_changed(w, .Values)
}

@(private)
scr_delete :: proc(w: ^Wizard) {
	lay_load(w)
	s := &w.set.scr
	ed := &s.ed
	k := ed.original
	if k < 0 || k >= len(s.list) {
		scr_close(w)
		return
	}
	if !ed.confirm_delete {
		ed.confirm_delete = true
		return
	}
	user_script_destroy(&s.list[k])
	ordered_remove(&s.list, k)
	lay_script_removed(w, k)
	s.dirty = true
	w.set.lay.dirty = true
	scr_close(w)
	settings_changed(w, .Values)
}

// The interval stepper: the next value of SCRIPT_INTERVALS up or down.
@(private)
scr_step_interval :: proc(w: ^Wizard, dir: int) {
	ed := &w.set.scr.ed
	if dir > 0 {
		for v in SCRIPT_INTERVALS {
			if v > ed.interval + 0.001 {
				ed.interval = v
				return
			}
		}
	} else {
		#reverse for v in SCRIPT_INTERVALS {
			if v < ed.interval - 0.001 {
				ed.interval = v
				return
			}
		}
	}
}

@(private)
interval_text :: proc(w: ^Wizard, seconds: f64) -> string {
	switch {
	case seconds != math.floor(seconds): return fmt.tprintf("%.1f s", seconds)
	case seconds < 60:                   return fmt.tprintf("%d s", int(seconds))
	case seconds < 3600 && int(seconds) % 60 == 0: return fmt.tprintf("%d min", int(seconds) / 60)
	case int(seconds) % 3600 == 0:       return fmt.tprintf("%d h", int(seconds) / 3600)
	}
	return fmt.tprintf("%d s", int(seconds))
}

@(private)
scripts_action :: proc(w: ^Wizard, action: Action, arg: int) {
	ed := &w.set.scr.ed
	#partial switch action {
	case .Scr_New:     scr_open(w, -1)
	case .Scr_Edit:    scr_open(w, arg)
	case .Scr_Example: scr_open(w, -1, arg)
	case .Scr_Cancel:  scr_close(w)
	case .Scr_Save:    scr_save(w)
	case .Scr_Delete:  scr_delete(w)
	case .Scr_Test:    scr_test_start(w)
	case .Scr_Mode:    ed.tail = arg == 1
	case .Scr_Icon:
		ed.picking = true
		w.focus = .None
	case .Scr_Icon_Back:
		ed.picking = false
		w.focus = .None
	case .Scr_Icon_Pick:
		set_buffer(&ed.icon, arg >= 0 && arg < len(config.AREA_ICONS) ? config.AREA_ICONS[arg].name : "")
		ed.picking = false
		w.focus = .None
	}
	if action != .Scr_Delete { ed.confirm_delete = false }
	if action != .Scr_Save && action != .Scr_Delete { ed.error = "" }
	w.hover = {}
	w.dirty = true
}

// ---------------------------------------------------------------------------
// Test: run the command once, show its first line (or why there is none)
// ---------------------------------------------------------------------------
@(private)
have_program :: proc(name: string) -> bool {
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split(path, ":", context.temp_allocator) {
		if dir == "" { continue }
		full := strings.concatenate({dir, "/", name}, context.temp_allocator)
		if posix.access(strings.clone_to_cstring(full, context.temp_allocator), {.X_OK}) == .OK { return true }
	}
	return false
}

@(private)
scr_test_clear :: proc(ed: ^Script_Editor) {
	delete(ed.test.result)
	ed.test.result = ""
	ed.test.failed = false
	clear(&ed.test.output)
}

@(private)
scr_test_start :: proc(w: ^Wizard) {
	ed := &w.set.scr.ed
	t := &ed.test
	scr_test_stop(w)
	scr_test_clear(ed)
	cmd := strings.trim_space(string(ed.exec[:]))
	if cmd == "" {
		t.result = strings.clone(tr(w, "Escreva o comando primeiro.", "Write the command first."))
		t.failed = true
		return
	}
	r, wr, err := os.pipe()
	if err != nil {
		t.result = strings.clone(tr(w, "Não foi possível rodar o comando.", "Could not run the command."))
		t.failed = true
		return
	}
	argv := make([dynamic]string, context.temp_allocator)
	group := have_program("setsid")
	if group { append(&argv, "setsid") }
	append(&argv, "sh", "-c", cmd)
	p, perr := os.process_start(os.Process_Desc{command = argv[:], stdout = wr, stderr = wr})
	os.close(wr) // the child holds the write end now
	if perr != nil {
		os.close(r)
		t.result = strings.clone(tr(w, "Não foi possível rodar o comando.", "Could not run the command."))
		t.failed = true
		return
	}
	// Reaped with waitpid; the pidfd handle is not needed.
	if p.handle != 0 && p.handle != ~uintptr(0) { posix.close(posix.FD(p.handle)) }
	t.running = true
	t.pid = posix.pid_t(p.pid)
	t.group = group
	t.file = r
	t.started = tx.now()
	t.tail = ed.tail
}

// Kill a running test (its whole group) and reap it.
@(private)
scr_test_stop :: proc(w: ^Wizard) {
	t := &w.set.scr.ed.test
	if !t.running { return }
	if t.group { posix.kill(-t.pid, .SIGKILL) }
	posix.kill(t.pid, .SIGKILL)
	status: i32
	posix.waitpid(t.pid, &status, {})
	if t.file != nil { os.close(t.file) }
	t.file = nil
	t.running = false
}

@(private)
scr_tick :: proc(w: ^Wizard, now: f64) {
	t := &w.set.scr.ed.test
	if !t.running { return }
	drain :: proc(t: ^Script_Test) {
		for t.file != nil {
			fd := posix.FD(os.fd(t.file))
			pfd := posix.pollfd{fd = fd, events = {.IN}}
			if posix.poll(&pfd, 1, 0) <= 0 { return }
			buf: [4096]u8
			n := posix.read(fd, raw_data(buf[:]), len(buf))
			if n <= 0 {
				os.close(t.file) // end of the output (the command may still run)
				t.file = nil
				return
			}
			if len(t.output) < SCRIPT_TEST_OUTPUT { append(&t.output, ..buf[:min(int(n), SCRIPT_TEST_OUTPUT - len(t.output))]) }
		}
	}
	drain(t)
	status: i32
	exited := posix.waitpid(t.pid, &status, {.NOHANG}) == t.pid
	if exited { drain(t) } // what it wrote just before it ended
	line := test_first_line(string(t.output[:]))
	got_line := t.tail && line != "" && strings.index_byte(string(t.output[:]), '\n') >= 0
	timed_out := now - t.started > SCRIPT_TEST_TIMEOUT
	if !exited && !got_line && !timed_out { return }
	if exited {
		t.running = false // already reaped
		if t.file != nil { os.close(t.file) }
		t.file = nil
	} else {
		scr_test_stop(w)
	}
	code := exited && posix.WIFEXITED(status) ? int(posix.WEXITSTATUS(status)) : 0
	failed := exited && (!posix.WIFEXITED(status) || code != 0)
	result: string
	switch {
	case got_line || (line != "" && !failed):
		result = line
	case failed && line != "":
		result = fmt.tprintf(tr(w, "Falhou (código %d): %s", "Failed (code %d): %s"), code, line)
	case failed:
		result = fmt.tprintf(tr(w, "Falhou (código %d), sem saída.", "Failed (code %d), with no output."), code)
	case timed_out:
		result = fmt.tprintf(tr(w, "Nada em %d s: o comando ainda estava rodando.", "Nothing within %d s: the command was still running."), int(SCRIPT_TEST_TIMEOUT))
	case:
		result = tr(w, "Não escreveu nada: o widget fica escondido.", "It printed nothing: the widget stays hidden.")
	}
	delete(t.result)
	t.result = strings.clone(result)
	t.failed = failed || line == ""
	w.dirty = true
}

@(private)
scr_timeout :: proc(w: ^Wizard) -> f64 {
	return w.set.scr.ed.test.running ? 0.05 : -1
}

// What the bar would show: the first line, or the text of a JSON line.
@(private)
test_first_line :: proc(output: string) -> string {
	out := strings.trim_space(output)
	line := out
	if nl := strings.index_byte(out, '\n'); nl >= 0 { line = strings.trim_space(out[:nl]) }
	for candidate in ([]string{out, line}) {
		if !strings.has_prefix(candidate, "{") { continue }
		if v, err := json.parse(transmute([]u8)candidate, .JSON, false, context.temp_allocator); err == .None {
			if obj, is_obj := v.(json.Object); is_obj {
				if text, has := obj["text"].(json.String); has { return strings.trim_space(text) }
			}
		}
	}
	return line
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------
@(private)
draw_scripts_tab :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	scripts_load(w)
	ed := &w.set.scr.ed
	switch {
	case ed.open && ed.picking: draw_script_icon_picker(w, cv, c)
	case ed.open:               draw_script_editor(w, cv, c)
	case:                       draw_script_list(w, cv, c)
	}
}

@(private)
draw_script_list :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	th := &w.theme
	s := &w.set.scr
	y := c.y
	new_label := tr(w, "Novo widget", "New widget")
	nw := button_width(w, new_label, .Plus)
	button(w, cv, {c.x + c.w - nw, y, nw, BUTTON_H}, new_label, .Filled, .Scr_New, 0, .Plus)
	intro_w := c.w - nw - 20
	text(w, w.f_body, c.x, y, 22, ellipsize(w, w.f_body, tr(w, "Widgets feitos por um comando", "Widgets made by a command"), intro_w), th.fg)
	text(w, w.f_small, c.x, y + 22, 22, ellipsize(w, w.f_small, tr(w, "O que o comando escreve aparece na barra, como os scripts do polybar.",
	                                                               "What the command prints shows on the bar, like polybar's scripts."), intro_w), mix(th.fg, th.muted, 0.55))
	y += BUTTON_H + 18

	// The examples go at the bottom; the list takes the room between.
	ex_y := c.y + c.h - (24 + 40)
	lr := tx.Rect{c.x, y, c.w, ex_y - 18 - y}
	row_h: i32 = 66
	if len(s.list) == 0 {
		box := tx.Rect{lr.x, lr.y, lr.w, min(lr.h, 96)}
		fill_rounded(cv, box, 16, th.field)
		text_centered(w, w.f_body, box, ellipsize(w, w.f_body, tr(w, "Nenhum widget ainda: crie um ou comece por um exemplo.",
		                                                          "No widgets yet: make one or start from an example."), box.w - 32), th.muted)
	} else if lr.h > 40 {
		content_h := i32(len(s.list)) * row_h
		sub := list_begin(w, lr, content_h, &s.scroll, .Scripts)
		for u, i in s.list {
			ry := i32(i) * row_h - s.scroll
			if ry + row_h < 0 { continue }
			if ry > lr.h { break }
			row := tx.Rect{0, ry + 3, lr.w - 10, row_h - 6}
			win := tx.Rect{lr.x + row.x, lr.y + row.y, row.w, row.h}
			if hovered(w, .Scr_Edit, i) {
				fill_rounded(&sub, row, 16, th.hover)
			} else if i > 0 {
				tx.canvas_fill_rect(&sub, {row.x + 14, ry, row.w - 28, 1}, mix(th.field, th.muted, 0.25))
			}
			tx.canvas_fill_circle(&sub, f32(row.x + 14 + 20), f32(row.y + row.h / 2), 20, th.surface)
			draw_script_icon(w, {win.x + 14, win.y, 40, win.h}, u.icon, th.fg, lr)
			how := u.tail ? tr(w, "Sempre rodando", "Always running") : fmt.tprintf(tr(w, "A cada %s", "Every %s"), interval_text(w, u.interval))
			if !script_on_bar(w, i) { how = fmt.tprintf("%s · %s", tr(w, "Fora da barra", "Not on the bar"), how) }
			hw := text_width(w, w.f_small, how)
			text(w, w.f_small, win.x + win.w - 40 - hw, win.y, win.h, how, th.muted, lr)
			icon(w, w.f_icon_small, {win.x + win.w - 32, win.y, 20, win.h}, .Chevron_Right, th.muted, lr)
			tx0 := win.x + 14 + 40 + 14
			avail := win.x + win.w - 56 - hw - tx0
			text(w, w.f_h2, tx0, win.y + 9, 24, ellipsize(w, w.f_h2, u.name, avail), th.fg, lr)
			text(w, w.f_small, tx0, win.y + 33, 20, ellipsize(w, w.f_small, u.exec, avail), mix(th.fg, th.muted, 0.55), lr)
			add_hit(w, win, .Scr_Edit, i, lr)
		}
		list_end(w, cv, &sub, lr, content_h, s.scroll)
	}

	// Examples: each opens the editor filled in.
	text(w, w.f_tiny, c.x, ex_y, 18, tr(w, "EXEMPLOS", "EXAMPLES"), th.muted)
	x := c.x
	for e, i in SCRIPT_EXAMPLES {
		label := tr(w, e.pt, e.en)
		r := tx.Rect{x, ex_y + 24, 12 + 22 + 8 + text_width(w, w.f_body, label) + 16, 40}
		if r.x + r.w > c.x + c.w { break }
		fill_rounded(cv, r, 20, hovered(w, .Scr_Example, i) ? th.hover : th.field)
		tx.canvas_stroke_rounded_rect(cv, r, 20, 1, th.outline)
		draw_script_icon(w, {r.x + 12, r.y, 22, r.h}, e.icon, th.fg)
		text(w, w.f_body, r.x + 42, r.y, r.h, label, th.fg)
		add_hit(w, r, .Scr_Example, i)
		x += r.w + 10
	}
}

@(private)
draw_script_editor :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	th := &w.theme
	ed := &w.set.scr.ed
	focused :: proc(w: ^Wizard, target: int) -> bool { return w.focus == .Text && w.set.text_target == target }
	// Side by side: the interval next to the mode; otherwise below it.
	interval_beside := c.w >= 360 + 24 + 230
	needed: i32 = 42 + 60 + 22 + 52 + 50 + 22 + 50 + 30 + 22 + 44 + 12 + BUTTON_H
	if !interval_beside && !ed.tail { needed += 52 }
	y := c.y
	if c.h >= needed {
		text(w, w.f_h2, c.x, y, 34, ed.original < 0 ? tr(w, "Novo widget", "New widget") : tr(w, "Editar widget", "Edit widget"), th.fg)
		y += 42
	} // a short window keeps the room for the fields

	// Icon and name.
	ib := tx.Rect{c.x, y, 44, 44}
	fill_rounded(cv, ib, 22, hovered(w, .Scr_Icon) ? mix(th.field, th.hover, 0.6) : th.field)
	tx.canvas_stroke_rounded_rect(cv, ib, 22, 1, th.outline)
	if strings.trim_space(string(ed.icon[:])) != "" {
		draw_script_icon(w, ib, string(ed.icon[:]), th.fg)
	} else {
		icon(w, w.f_icon_small, ib, .Plus, th.muted)
	}
	add_hit(w, ib, .Scr_Icon)
	name_target := int(Control.Scr_Name) * 100
	draw_field(w, cv, {ib.x + ib.w + 10, y, c.w - ib.w - 10, 44}, .Pencil, string(ed.name[:]), tr(w, "Nome do widget", "Widget name"),
	           focused(w, name_target), .Text_Field, name_target)
	y += 60

	// The command and its test.
	text(w, w.f_tiny, c.x, y, 18, tr(w, "COMANDO", "COMMAND"), th.muted)
	y += 22
	exec_target := int(Control.Scr_Exec) * 100
	draw_field(w, cv, {c.x, y, c.w, 44}, .Terminal, string(ed.exec[:]), tr(w, "Ex.: date +%H:%M", "E.g. date +%H:%M"),
	           focused(w, exec_target), .Text_Field, exec_target)
	y += 52
	test := tr(w, "Testar", "Test")
	tw := button_width(w, test, .Player_Play) - 8
	button(w, cv, {c.x, y, tw, 40}, test, .Tonal, .Scr_Test, 0, .Player_Play)
	rx := c.x + tw + 14
	t := &ed.test
	switch {
	case t.running:
		text(w, w.f_small, rx, y, 40, tr(w, "Rodando…", "Running…"), th.muted)
	case t.result != "":
		color := t.failed ? th.warning : th.fg
		icon(w, w.f_icon_small, {rx, y, 20, 40}, t.failed ? .Alert : .Check, t.failed ? th.warning : th.accent)
		label := t.failed ? t.result : fmt.tprintf(tr(w, "Na barra: %s", "On the bar: %s"), t.result)
		text(w, w.f_body, rx + 26, y, 40, ellipsize(w, w.f_body, label, c.x + c.w - rx - 26), color)
	case:
		text(w, w.f_small, rx, y, 40, ellipsize(w, w.f_small, tr(w, "Roda o comando uma vez e mostra o que apareceria na barra.",
		                                                         "Runs the command once and shows what the bar would show."), c.x + c.w - rx), th.muted)
	}
	y += 50

	// How it runs.
	text(w, w.f_tiny, c.x, y, 18, tr(w, "ATUALIZAÇÃO", "UPDATES"), th.muted)
	y += 22
	seg_w := interval_beside ? clamp(c.w - 24 - 230, 360, 420) : min(i32(440), c.w)
	segmented(w, cv, {c.x, y, seg_w, 42}, {tr(w, "A cada intervalo", "On an interval"), tr(w, "Sempre rodando", "Always running")},
	          {.Clock, .Terminal}, ed.tail ? 1 : 0, .Scr_Mode)
	if !ed.tail {
		row := tx.Rect{c.x + seg_w + 24, y - 7, c.w - seg_w - 24, 56}
		if !interval_beside {
			y += 52
			row = {c.x + 4, y - 7, min(c.w - 4, 300), 56}
		}
		text(w, w.f_body, row.x, row.y, row.h, tr(w, "Intervalo", "Interval"), th.fg)
		stepper(w, cv, row, interval_text(w, ed.interval), .Scr_Interval)
	}
	y += 50
	hint := tr(w, "A primeira linha que o comando escreve aparece; ele roda de novo depois do intervalo.",
	           "The first line the command prints shows; it runs again after the interval.")
	if ed.tail {
		hint = tr(w, "O comando fica rodando, e cada linha que ele escreve atualiza o widget.",
		          "The command keeps running, and every line it prints updates the widget.")
	}
	text(w, w.f_small, c.x + 4, y, 20, ellipsize(w, w.f_small, hint, c.w - 4), mix(th.fg, th.muted, 0.55))
	y += 30

	footer_y := c.y + c.h - BUTTON_H
	// What a click does (when there is room).
	if y + 22 + 44 <= footer_y - 12 {
		text(w, w.f_tiny, c.x, y, 18, tr(w, "AO CLICAR (OPCIONAL)", "ON CLICK (OPTIONAL)"), th.muted)
		y += 22
		click_target := int(Control.Scr_Click) * 100
		draw_field(w, cv, {c.x, y, c.w, 44}, .Command, string(ed.click[:]), tr(w, "Ex.: alacritty -e htop", "E.g. alacritty -e htop"),
		           focused(w, click_target), .Text_Field, click_target)
	}

	// Footer.
	save := tr(w, "Salvar", "Save")
	sw := max(button_width(w, save, .Check), 130)
	save_r := tx.Rect{c.x + c.w - sw, footer_y, sw, BUTTON_H}
	button(w, cv, save_r, save, .Filled, .Scr_Save, 0, .Check)
	cancel := tr(w, "Cancelar", "Cancel")
	cw := button_width(w, cancel)
	button(w, cv, {save_r.x - 10 - cw, footer_y, cw, BUTTON_H}, cancel, .Text, .Scr_Cancel)
	left := c.x
	if ed.original >= 0 {
		del := ed.confirm_delete ? tr(w, "Confirmar exclusão", "Confirm delete") : tr(w, "Excluir", "Delete")
		dw := button_width(w, del, .Trash)
		button(w, cv, {c.x - 12, footer_y, dw, BUTTON_H}, del, ed.confirm_delete ? .Tonal : .Text, .Scr_Delete, 0, .Trash)
		left = c.x - 12 + dw + 12
	}
	if ed.error != "" {
		avail := save_r.x - 10 - cw - 12 - left
		icon(w, w.f_icon_small, {left, footer_y, 20, BUTTON_H}, .Alert, th.warning)
		text(w, w.f_small, left + 24, footer_y, BUTTON_H, ellipsize(w, w.f_small, ed.error, avail - 24), th.warning)
	}
}

// The icon: a name of any Tabler icon, or one from the grid.
@(private)
draw_script_icon_picker :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	th := &w.theme
	ed := &w.set.scr.ed
	back := tr(w, "Voltar", "Back")
	bw := button_width(w, back, .Arrow_Left)
	button(w, cv, {c.x, c.y, bw, BUTTON_H}, back, .Text, .Scr_Icon_Back, 0, .Arrow_Left)
	name := strings.trim_space(string(ed.name[:]))
	title := name != "" ? fmt.tprintf(tr(w, "Ícone de %s", "Icon of %s"), name) : tr(w, "Ícone do widget", "Widget icon")
	text(w, w.f_h2, c.x + bw + 16, c.y, BUTTON_H, ellipsize(w, w.f_h2, title, c.w - bw - 16), th.fg)

	y := c.y + BUTTON_H + 16
	target := int(Control.Scr_Icon_Name) * 100
	fw := min(i32(460), c.w - 60)
	draw_field(w, cv, {c.x, y, fw, 44}, .Search, string(ed.icon[:]), tr(w, "Ou o nome de um ícone do Tabler (tabler.io/icons)", "Or the name of a Tabler icon (tabler.io/icons)"),
	           w.focus == .Text && w.set.text_target == target, .Text_Field, target)
	preview := tx.Rect{c.x + fw + 12, y, 44, 44}
	fill_rounded(cv, preview, 22, th.field)
	if strings.trim_space(string(ed.icon[:])) != "" {
		if glyph, font := script_icon_text(w, w.f_icon, string(ed.icon[:])); glyph != "" {
			text_centered(w, font, preview, glyph, th.fg)
		} else {
			icon(w, w.f_icon_small, preview, .Alert, th.warning)
		}
	}
	y += 44 + 20
	draw_icon_grid(w, cv, {c.x, y, c.w, c.y + c.h - y}, strings.trim_space(string(ed.icon[:])), .Scr_Icon_Pick)
}
