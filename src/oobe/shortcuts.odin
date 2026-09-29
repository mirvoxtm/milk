// Settings → Atalhos: the user's key bindings (wm.bindings: "super+w" →
// shell command), an editor that captures a key combination with an active
// keyboard grab and picks what it opens (an installed application, a command
// or a site/folder), and the read-only list of milk's built-in shortcuts.
package oobe

import "core:fmt"
import "core:os"
import "core:strings"
import xlib "vendor:x11/xlib"
import desktop "../desktop"
import tx "../tx"

@(private) Mod_Key :: enum { Super, Ctrl, Alt, Shift }
@(private) Mods :: bit_set[Mod_Key]

@(private)
App :: struct {
	sc:    desktop.Shortcut, // parsed .desktop entry (owned)
	exec:  string,           // Exec without field codes (owned)
	prog:  string,           // program name of exec (slice of exec)
	icon:  ^tx.Image,        // nil until loaded (or when there is none)
	tried: bool,
}

@(private)
Binding_Row :: struct {
	spec, command: string, // owned
}

@(private)
Shortcut_Editor :: struct {
	open:        bool,
	original:    string, // spec being edited ("" = new), owned
	spec:        string, // captured spec, owned
	capturing:   bool,
	grabbed:     bool,
	hint:        string, // literal message under the capture field
	kind:        int,    // 0 application, 1 command, 2 site or folder
	app:         int,    // index into apps, -1 = none
	command:     [dynamic]u8,
	site:        [dynamic]u8,
	search:      [dynamic]u8,
	scroll_apps: i32,
}

@(private)
Shortcuts :: struct {
	loaded:        bool,
	apps:          [dynamic]App,
	icons:         desktop.Icon_Loader,
	icon_budget:   int,  // icons that may still be loaded this frame
	icons_pending: bool, // some visible icon waits for the next frame
	rows:          [dynamic]Binding_Row,
	dirty:         bool, // write wm.bindings on the next save
	scroll:        i32,
	show_builtin:  bool,
	ed:            Shortcut_Editor,
}

// milk's own shortcuts ("mod" = wm.modKey, "#" = the digits 1..9), from the
// window manager's key table.
@(private)
Builtin :: struct {
	keys:   string, // specs separated by spaces
	pt, en: string,
}

@(private, rodata)
BUILTINS := []Builtin{
	{"mod+Return", "Abrir o terminal", "Open the terminal"},
	{"mod+d mod+p", "Abrir o lançador de aplicativos", "Open the application launcher"},
	{"mod+q mod+shift+c", "Fechar a janela", "Close the window"},
	{"mod+j mod+k", "Focar a próxima / anterior janela", "Focus the next / previous window"},
	{"mod+shift+Return", "Trocar com a janela mestre", "Swap with the master window"},
	{"mod+h mod+l", "Diminuir / aumentar a área mestre", "Shrink / grow the master area"},
	{"mod+i mod+shift+d", "Mais / menos janelas na área mestre", "More / fewer windows in the master area"},
	{"mod+t mod+f mod+m", "Lado a lado / flutuante / monóculo", "Tile / floating / monocle layout"},
	{"mod+space", "Layout anterior", "Previous layout"},
	{"mod+shift+space", "Alternar janela flutuante", "Toggle floating"},
	{"mod+shift+f", "Tela cheia", "Fullscreen"},
	{"mod+#", "Ir para a área 1…9", "Go to area 1…9"},
	{"mod+shift+#", "Mover a janela para a área 1…9", "Move the window to area 1…9"},
	{"mod+ctrl+#", "Mostrar também a área 1…9", "Also show area 1…9"},
	{"mod+ctrl+shift+#", "Pôr a janela também na área 1…9", "Also put the window on area 1…9"},
	{"mod+0 mod+shift+0", "Todas as áreas / janela em todas", "All areas / window on all areas"},
	{"mod+Tab", "Área anterior", "Previous area"},
	{"mod+comma mod+period", "Focar o monitor anterior / próximo", "Focus the previous / next monitor"},
	{"mod+shift+comma mod+shift+period", "Mover a janela de monitor", "Move the window to another monitor"},
	{"mod+v", "Histórico da área de transferência", "Clipboard history"},
	{"mod+n", "Painel de notificações", "Notification panel"},
	{"mod+shift+s", "Capturar uma região da tela", "Screenshot of a region"},
	{"mod+shift+r", "Recarregar milk.json", "Reload milk.json"},
	{"mod+shift+q", "Sair do milk", "Quit milk"},
	{"XF86AudioMute XF86AudioLowerVolume XF86AudioRaiseVolume", "Mudo / volume − / volume +", "Mute / volume − / volume +"},
	{"XF86MonBrightnessDown XF86MonBrightnessUp", "Brilho − / +", "Brightness − / +"},
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------
@(private)
shortcuts_load :: proc(w: ^Wizard) {
	sc := &w.set.sc
	if sc.loaded { return }
	sc.loaded = true
	for spec, command in w.cfg.wm.bindings {
		append(&sc.rows, Binding_Row{strings.clone(spec), strings.clone(command)})
	}
	sort_rows(sc.rows[:])
	load_apps(w)
	desktop.icons_init(&sc.icons, w.cfg)
	sc.icons.size = 24
	sc.ed.app = -1
}

@(private)
sort_rows :: proc(rows: []Binding_Row) {
	for i in 1 ..< len(rows) {
		for j := i; j > 0 && rows[j].spec < rows[j - 1].spec; j -= 1 { rows[j], rows[j - 1] = rows[j - 1], rows[j] }
	}
}

// Installed applications: desktop entries from the XDG data dirs (the user's
// first; a file id seen once hides the same id further down).
@(private)
load_apps :: proc(w: ^Wizard) {
	sc := &w.set.sc
	home := home_dir()
	dirs := [?]string{
		join_path({home, ".local/share/applications"}),
		join_path({home, ".local/share/flatpak/exports/share/applications"}),
		"/var/lib/flatpak/exports/share/applications",
		"/usr/local/share/applications",
		"/usr/share/applications",
	}
	seen := make(map[string]bool, context.temp_allocator)
	for dir in dirs {
		infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil { continue }
		for fi in infos {
			if !strings.has_suffix(fi.name, ".desktop") || seen[fi.name] { continue }
			seen[strings.clone(fi.name, context.temp_allocator)] = true
			s, ok := desktop.load_shortcut(join_path({dir, fi.name}))
			if !ok { continue }
			if s.kind != .Application {
				desktop.shortcut_destroy(&s)
				continue
			}
			exec := strip_field_codes(s.exec)
			append(&sc.apps, App{sc = s, exec = exec, prog = program_of(exec)})
		}
	}
	// By name, case-insensitively.
	for i in 1 ..< len(sc.apps) {
		for j := i; j > 0 && strings.to_lower(sc.apps[j].sc.name, context.temp_allocator) < strings.to_lower(sc.apps[j - 1].sc.name, context.temp_allocator); j -= 1 {
			sc.apps[j], sc.apps[j - 1] = sc.apps[j - 1], sc.apps[j]
		}
	}
}

// Exec line without the Desktop Entry field codes (%f %U …); "%%" becomes "%".
@(private)
strip_field_codes :: proc(exec: string) -> string {
	b := strings.builder_make()
	first := true
	for tok in strings.fields(exec, context.temp_allocator) {
		if len(tok) == 2 && tok[0] == '%' && strings.index_byte("fFuUickdDnNvm", tok[1]) >= 0 { continue }
		t, _ := strings.replace_all(tok, "%%", "%", context.temp_allocator)
		if !first { strings.write_byte(&b, ' ') }
		strings.write_string(&b, t)
		first = false
	}
	return strings.to_string(b)
}

// The program a command runs ("env A=b /usr/bin/foo --x" → "foo").
@(private)
program_of :: proc(cmd: string) -> string {
	rest := strings.trim_space(cmd)
	for rest != "" {
		end := strings.index_any(rest, " \t")
		tok := end < 0 ? rest : rest[:end]
		rest = end < 0 ? "" : strings.trim_left_space(rest[end:])
		tok = strings.trim(tok, "\"'")
		if tok == "env" || strings.index_byte(tok, '=') > 0 { continue }
		if slash := strings.last_index_byte(tok, '/'); slash >= 0 { tok = tok[slash + 1:] }
		return tok
	}
	return ""
}

@(private)
match_app :: proc(w: ^Wizard, command: string) -> int {
	sc := &w.set.sc
	cmd := strings.trim_space(command)
	for app, i in sc.apps { if app.exec == cmd { return i } }
	prog := program_of(cmd)
	if prog == "" || prog == "flatpak" || prog == "sh" || prog == "bash" || prog == "xdg-open" { return -1 }
	for app, i in sc.apps { if app.prog == prog { return i } }
	return -1
}

// The app's icon, loaded on demand (a couple per frame: SVGs go through rsvg-convert).
@(private)
app_icon :: proc(w: ^Wizard, index: int) -> ^tx.Image {
	sc := &w.set.sc
	if index < 0 || index >= len(sc.apps) { return nil }
	app := &sc.apps[index]
	if app.tried { return app.icon }
	if sc.icon_budget <= 0 {
		sc.icons_pending = true
		return nil
	}
	sc.icon_budget -= 1
	app.tried = true
	app.icon = desktop.icon_for(&sc.icons, &app.sc)
	return app.icon
}

@(private)
shortcuts_destroy :: proc(w: ^Wizard) {
	sc := &w.set.sc
	capture_stop(w)
	for &app in sc.apps {
		desktop.shortcut_destroy(&app.sc)
		delete(app.exec)
	}
	delete(sc.apps)
	if sc.loaded { desktop.icons_destroy(&sc.icons) }
	for r in sc.rows { delete(r.spec); delete(r.command) }
	delete(sc.rows)
	ed := &sc.ed
	delete(ed.original)
	delete(ed.spec)
	delete(ed.command)
	delete(ed.site)
	delete(ed.search)
	sc^ = {}
}

// ---------------------------------------------------------------------------
// Key specs
// ---------------------------------------------------------------------------
// "super+shift+w" → modifiers and key ("mod" is wm.modKey); key compared case-insensitively.
@(private)
parse_spec :: proc(w: ^Wizard, spec: string) -> (mods: Mods, key: string, ok: bool) {
	parts := strings.split(spec, "+", context.temp_allocator)
	if len(parts) == 0 { return }
	for part, i in parts {
		name := strings.to_lower(strings.trim_space(part), context.temp_allocator)
		if i == len(parts) - 1 {
			key = name
			break
		}
		switch name {
		case "super", "win", "mod4":  mods += {.Super}
		case "alt", "mod1":           mods += {.Alt}
		case "ctrl", "control":       mods += {.Ctrl}
		case "shift":                 mods += {.Shift}
		case "mod":                   mods += {w.cfg.wm.mod_key == "alt" ? .Alt : .Super}
		case:                         return {}, "", false
		}
	}
	return mods, key, key != ""
}

@(private)
format_spec :: proc(mods: Mods, key: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	if .Super in mods { strings.write_string(&b, "super+") }
	if .Ctrl in mods { strings.write_string(&b, "ctrl+") }
	if .Alt in mods { strings.write_string(&b, "alt+") }
	if .Shift in mods { strings.write_string(&b, "shift+") }
	strings.write_string(&b, key)
	return strings.to_string(b)
}

@(private)
same_keys :: proc(w: ^Wizard, a, b: string) -> bool {
	ma, ka, oka := parse_spec(w, a)
	mb, kb, okb := parse_spec(w, b)
	return oka && okb && ma == mb && ka == kb
}

// The built-in action a spec overrides, if any.
@(private)
builtin_conflict :: proc(w: ^Wizard, spec: string) -> (action: string, found: bool) {
	for b in BUILTINS {
		for pattern in strings.fields(b.keys, context.temp_allocator) {
			if strings.index_byte(pattern, '#') >= 0 {
				for d in 1 ..= 9 {
					digit := fmt.tprintf("%d", d)
					candidate, _ := strings.replace_all(pattern, "#", digit, context.temp_allocator)
					if same_keys(w, candidate, spec) { return tr(w, b.pt, b.en), true }
				}
			} else if same_keys(w, pattern, spec) {
				return tr(w, b.pt, b.en), true
			}
		}
	}
	return "", false
}

// Chip text for a modifier or key name.
@(private)
key_label :: proc(w: ^Wizard, name: string) -> string {
	lower := strings.to_lower(name, context.temp_allocator)
	switch lower {
	case "mod":                  return w.cfg.wm.mod_key == "alt" ? "Alt" : "Super"
	case "super", "win", "mod4": return "Super"
	case "ctrl", "control":      return "Ctrl"
	case "alt", "mod1":          return "Alt"
	case "shift":                return "Shift"
	case "return":               return "Enter"
	case "space":                return tr(w, "Espaço", "Space")
	case "tab":                  return "Tab"
	case "escape":               return "Esc"
	case "backspace":            return "Backspace"
	case "delete":               return "Delete"
	case "comma":                return ","
	case "period":               return "."
	case "minus":                return "-"
	case "equal":                return "="
	case "slash":                return "/"
	case "backslash":            return "\\"
	case "semicolon":            return ";"
	case "apostrophe":           return "'"
	case "grave":                return "`"
	case "bracketleft":          return "["
	case "bracketright":         return "]"
	case "left":                 return "←"
	case "right":                return "→"
	case "up":                   return "↑"
	case "down":                 return "↓"
	case "print":                return "Print Screen"
	case "prior":                return "Page Up"
	case "next":                 return "Page Down"
	case "#":                    return "1…9"
	case "xf86audiomute":        return tr(w, "Mudo", "Mute")
	case "xf86audiolowervolume": return "Volume −"
	case "xf86audioraisevolume": return "Volume +"
	case "xf86monbrightnessup":  return tr(w, "Brilho +", "Brightness +")
	case "xf86monbrightnessdown": return tr(w, "Brilho −", "Brightness −")
	case "xf86audioplay":        return "Play"
	case "xf86audionext":        return tr(w, "Próxima", "Next")
	case "xf86audioprev":        return tr(w, "Anterior", "Previous")
	}
	if strings.has_prefix(name, "XF86") { return name[4:] }
	if len(name) == 1 || (len(name) <= 3 && (name[0] == 'f' || name[0] == 'F')) {
		return strings.to_upper(name, context.temp_allocator)
	}
	return name
}

// Key caps for one spec at (x, centre y); returns the x after the last cap.
@(private)
draw_chips :: proc(w: ^Wizard, cv: ^tx.Canvas, x, cy: i32, spec: string, clip := tx.Rect{}) -> i32 {
	th := &w.theme
	x := x
	for part in strings.split(spec, "+", context.temp_allocator) {
		label := key_label(w, strings.trim_space(part))
		tw := text_width(w, w.f_small, label)
		r := tx.Rect{x, cy - 14, max(tw + 18, 28), 27}
		fill_rounded(cv, {r.x, r.y + 2, r.w, r.h}, 8, mix(th.outline, th.bg, th.dark ? 0.2 : 0))
		fill_rounded(cv, r, 8, th.dark ? mix(th.surface, th.fg, 0.08) : th.bg)
		tx.canvas_stroke_rounded_rect(cv, r, 8, 1, th.outline)
		text_centered(w, w.f_small, {r.x, r.y, r.w, r.h}, label, th.fg, clip)
		x += r.w + 5
	}
	return x
}

// ---------------------------------------------------------------------------
// Capture
// ---------------------------------------------------------------------------
@(private)
capture_start :: proc(w: ^Wizard) {
	ed := &w.set.sc.ed
	ed.capturing = true
	ed.hint = ""
	w.focus = .None
	// An active grab: the window manager's passive Super+… grabs cannot fire.
	status := xlib.GrabKeyboard(w.c.dpy, w.win, false, .GrabModeAsync, .GrabModeAsync, xlib.CurrentTime)
	ed.grabbed = status == 0
	w.dirty = true
}

@(private)
capture_stop :: proc(w: ^Wizard) {
	ed := &w.set.sc.ed
	if ed.grabbed { xlib.UngrabKeyboard(w.c.dpy, xlib.CurrentTime) }
	ed.grabbed = false
	ed.capturing = false
	w.dirty = true
}

@(private)
is_modifier_key :: proc(name: string) -> bool {
	for m in ([]string{"Shift_L", "Shift_R", "Control_L", "Control_R", "Alt_L", "Alt_R", "Super_L", "Super_R", "Meta_L", "Meta_R",
	                   "Hyper_L", "Hyper_R", "ISO_Level3_Shift", "ISO_Level5_Shift", "Caps_Lock", "Num_Lock", "Mode_switch"}) {
		if name == m { return true }
	}
	return false
}

@(private)
capture_key :: proc(w: ^Wizard, ev: ^xlib.XKeyEvent) {
	ed := &w.set.sc.ed
	sym := xlib.LookupKeysym(ev, 0)
	cname := xlib.KeysymToString(sym)
	if cname == nil { return }
	name := string(cname)
	if is_modifier_key(name) { return }
	mods: Mods
	if .Mod4Mask in ev.state { mods += {.Super} }
	if .ControlMask in ev.state { mods += {.Ctrl} }
	if .Mod1Mask in ev.state { mods += {.Alt} }
	if .ShiftMask in ev.state { mods += {.Shift} }
	if name == "Escape" && mods == {} {
		capture_stop(w)
		return
	}
	fkey := len(name) >= 2 && name[0] == 'F' && name[1] >= '0' && name[1] <= '9'
	if mods == {} && !fkey && !strings.has_prefix(name, "XF86") {
		ed.hint = tr(w, "Use uma tecla modificadora (Super, Ctrl, Alt ou Shift) junto com a tecla.",
		             "Hold a modifier (Super, Ctrl, Alt or Shift) with the key.")
		w.dirty = true
		return
	}
	delete(ed.spec)
	ed.spec = format_spec(mods, name)
	ed.hint = ""
	capture_stop(w)
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------
@(private)
editor_open :: proc(w: ^Wizard, row: int) {
	sc := &w.set.sc
	ed := &sc.ed
	delete(ed.original)
	delete(ed.spec)
	ed^ = {command = ed.command, site = ed.site, search = ed.search}
	clear(&ed.command)
	clear(&ed.site)
	clear(&ed.search)
	ed.open = true
	ed.app = -1
	ed.original = strings.clone("")
	ed.spec = strings.clone("")
	if row >= 0 && row < len(sc.rows) {
		r := sc.rows[row]
		delete(ed.original)
		delete(ed.spec)
		ed.original = strings.clone(r.spec)
		ed.spec = strings.clone(r.spec)
		cmd := strings.trim_space(r.command)
		if strings.has_prefix(cmd, "xdg-open ") {
			ed.kind = 2
			target := strings.trim_space(cmd[len("xdg-open "):])
			target = strings.trim(target, "'\"")
			append(&ed.site, ..transmute([]u8)target)
		} else if app := match_app(w, cmd); app >= 0 {
			ed.kind = 0
			ed.app = app
		} else {
			ed.kind = 1
			append(&ed.command, ..transmute([]u8)cmd)
		}
	}
	w.focus = .None
	w.hover = {}
	w.dirty = true
}

@(private)
editor_close :: proc(w: ^Wizard) {
	capture_stop(w)
	w.set.sc.ed.open = false
	w.focus = .None
	w.hover = {}
	w.dirty = true
}

// The shell command the editor would save ("" when incomplete).
@(private)
editor_command :: proc(w: ^Wizard) -> string {
	sc := &w.set.sc
	ed := &sc.ed
	switch ed.kind {
	case 0:
		if ed.app >= 0 && ed.app < len(sc.apps) { return sc.apps[ed.app].exec }
	case 1:
		return strings.trim_space(string(ed.command[:]))
	case 2:
		target := strings.trim_space(string(ed.site[:]))
		if target == "" { return "" }
		if strings.has_prefix(target, "~/") { target = join_path({home_dir(), target[2:]}) }
		quoted, _ := strings.replace_all(target, "'", "'\\''", context.temp_allocator)
		return fmt.tprintf("xdg-open '%s'", quoted)
	}
	return ""
}

// Another user shortcut with the same keys (not the one being edited).
@(private)
duplicate_row :: proc(w: ^Wizard, spec: string) -> int {
	sc := &w.set.sc
	for r, i in sc.rows {
		if r.spec == sc.ed.original { continue }
		if same_keys(w, r.spec, spec) { return i }
	}
	return -1
}

@(private)
editor_save :: proc(w: ^Wizard) {
	sc := &w.set.sc
	ed := &sc.ed
	command := editor_command(w)
	if ed.spec == "" || command == "" { return }
	// Drop the edited binding and any other binding with the same keys.
	for i := len(sc.rows) - 1; i >= 0; i -= 1 {
		r := sc.rows[i]
		if (ed.original != "" && r.spec == ed.original) || same_keys(w, r.spec, ed.spec) {
			delete(r.spec)
			delete(r.command)
			ordered_remove(&sc.rows, i)
		}
	}
	append(&sc.rows, Binding_Row{strings.clone(ed.spec), strings.clone(command)})
	sort_rows(sc.rows[:])
	sc.dirty = true
	editor_close(w)
	settings_changed(w, .Values)
}

@(private)
delete_row :: proc(w: ^Wizard, row: int) {
	sc := &w.set.sc
	if row < 0 || row >= len(sc.rows) { return }
	delete(sc.rows[row].spec)
	delete(sc.rows[row].command)
	ordered_remove(&sc.rows, row)
	sc.dirty = true
	settings_changed(w, .Values)
}

@(private)
shortcuts_action :: proc(w: ^Wizard, action: Action, arg: int) {
	sc := &w.set.sc
	#partial switch action {
	case .Sc_Add:     editor_open(w, -1)
	case .Sc_Edit:    editor_open(w, arg)
	case .Sc_Delete:  delete_row(w, arg)
	case .Sc_Capture:
		if sc.ed.capturing { capture_stop(w) } else { capture_start(w) }
	case .Sc_Kind:
		sc.ed.kind = clamp(arg, 0, 2)
		w.focus = .None
	case .Sc_App:     sc.ed.app = arg
	case .Sc_Save:    editor_save(w)
	case .Sc_Cancel:  editor_close(w)
	case .Sc_Builtin: sc.show_builtin = !sc.show_builtin
	}
	w.dirty = true
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------
@(private)
draw_shortcuts :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	shortcuts_load(w)
	w.set.sc.icon_budget = 2
	if w.set.sc.ed.open {
		draw_shortcut_editor(w, cv, c)
	} else {
		draw_shortcut_list(w, cv, c)
	}
}

// What a binding opens: icon glyph or app icon, and a label.
@(private)
draw_target :: proc(w: ^Wizard, cv: ^tx.Canvas, x, cy: i32, max_w: i32, command: string, clip: tx.Rect) {
	th := &w.theme
	cmd := strings.trim_space(command)
	label := cmd
	glyph := Icon.Terminal
	app := -1
	if strings.has_prefix(cmd, "xdg-open ") {
		glyph = .World
		label = strings.trim(strings.trim_space(cmd[len("xdg-open "):]), "'\"")
	} else if app = match_app(w, cmd); app >= 0 {
		label = w.set.sc.apps[app].sc.name
	}
	img := app_icon(w, app)
	if img != nil {
		tx.canvas_blit_image(cv, img^, x, cy - img.h / 2)
	} else {
		fill_rounded(cv, {x, cy - 13, 26, 26}, 8, mix(th.accent, th.bg, 0.84))
		icon(w, w.f_icon_small, {x, cy - 13, 26, 26}, app >= 0 ? .Apps : glyph, th.accent, clip)
	}
	text(w, w.f_body, x + 36, cy - 14, 28, ellipsize(w, w.f_body, label, max_w - 36), th.fg, clip)
}

@(private)
draw_shortcut_list :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	th := &w.theme
	sc := &w.set.sc
	y := c.y - sc.scroll

	text(w, w.f_h2, c.x, y, 40, tr(w, "Seus atalhos", "Your shortcuts"), th.fg, c)
	add_label := tr(w, "Adicionar atalho", "Add shortcut")
	bw := button_width(w, add_label, .Plus)
	if y + 40 > c.y { button_clipped(w, cv, {c.x + c.w - bw, y, bw, 40}, add_label, .Filled, .Sc_Add, 0, .Plus, c) }
	y += 54
	if len(sc.rows) == 0 {
		text(w, w.f_body, c.x, y, 30, tr(w, "Nenhum atalho ainda: crie um para abrir seus aplicativos e sites favoritos.",
		                               "No shortcuts yet: add one to open your favourite apps and sites."), th.muted, c)
		y += 44
	}
	for r, i in sc.rows {
		row := tx.Rect{c.x, y, c.w, 58}
		fill_rounded(cv, row, 16, th.field)
		cy := row.y + row.h / 2
		x := draw_chips(w, cv, row.x + 14, cy, r.spec, c)
		icon(w, w.f_icon_small, {x + 4, row.y, 22, row.h}, .Arrow_Right, th.muted, c)
		// Edit and delete.
		bx := row.x + row.w - 12 - 34
		for kind in 0 ..< 2 {
			b := tx.Rect{bx, cy - 17, 34, 34}
			action := kind == 0 ? Action.Sc_Delete : Action.Sc_Edit
			if hovered(w, action, i) { fill_rounded(cv, b, 17, kind == 0 ? mix(th.warning, th.bg, 0.8) : th.hover) }
			icon(w, w.f_icon_small, b, kind == 0 ? .Trash : .Pencil, kind == 0 && hovered(w, action, i) ? th.warning : mix(th.fg, th.muted, 0.3), c)
			add_hit(w, b, action, i, c)
			bx -= 40
		}
		draw_target(w, cv, x + 36, cy, bx + 34 - (x + 36) - 12, r.command, c)
		y += 66
	}

	// Built-in shortcuts (collapsible).
	y += 12
	head := tx.Rect{c.x, y, c.w, 44}
	if hovered(w, .Sc_Builtin) { fill_rounded(cv, head, 14, th.hover) }
	icon(w, w.f_icon_small, {head.x + 8, head.y, 22, head.h}, sc.show_builtin ? .Chevron_Down : .Chevron_Right, th.fg, c)
	text(w, w.f_h2, head.x + 38, head.y, head.h, tr(w, "Atalhos do milk", "milk's shortcuts"), th.fg, c)
	hint := tr(w, "Um atalho seu com as mesmas teclas substitui o do milk", "A shortcut of yours with the same keys replaces milk's")
	hw := text_width(w, w.f_small, hint)
	if hw < head.w - 260 { text(w, w.f_small, head.x + head.w - 12 - hw, head.y, head.h, hint, th.muted, c) }
	add_hit(w, head, .Sc_Builtin, 0, c)
	y += 52
	if sc.show_builtin {
		for b in BUILTINS {
			row := tx.Rect{c.x, y, c.w, 42}
			x := row.x + 8
			for spec, k in strings.fields(b.keys, context.temp_allocator) {
				if k > 0 {
					text(w, w.f_small, x, row.y, row.h, "/", th.muted, c)
					x += 12
				}
				x = draw_chips(w, cv, x, row.y + row.h / 2, spec, c)
			}
			desc := tr(w, b.pt, b.en)
			dx := max(x + 16, row.x + row.w * 52 / 100)
			text(w, w.f_body, dx, row.y, row.h, ellipsize(w, w.f_body, desc, row.x + row.w - dx), mix(th.fg, th.muted, 0.3), c)
			tx.canvas_fill_rect(cv, {row.x, row.y + row.h, row.w, 1}, mix(th.bg, th.muted, 0.15))
			y += 44
		}
	}
	content_h := y + sc.scroll - c.y
	max_scroll := max(content_h - c.h, 0)
	sc.scroll = clamp(sc.scroll, 0, max_scroll)
	append(&w.scrolls, Scroll_Area{r = c, id = .Shortcuts, max = max_scroll})
	if max_scroll > 0 {
		track := c.h - 8
		thumb_h := max(track * c.h / content_h, 32)
		thumb_y := c.y + 4 + (track - thumb_h) * sc.scroll / max_scroll
		fill_rounded(cv, {c.x + c.w + 14, thumb_y, 4, thumb_h}, 2, tx.color_with_alpha(th.muted, 150))
	}
}

// A button whose hit area is limited to `clip` (scrolled content).
@(private)
button_clipped :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect, label: string, kind: Button_Kind, action: Action, arg: int, lead: Icon, clip: tx.Rect) {
	first_text := len(w.texts)
	first_hit := len(w.hits)
	button(w, cv, r, label, kind, action, arg, lead)
	for i in first_text ..< len(w.texts) { w.texts[i].clip = clip }
	for i in first_hit ..< len(w.hits) { w.hits[i].clip = clip }
}

@(private)
draw_shortcut_editor :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	th := &w.theme
	sc := &w.set.sc
	ed := &sc.ed
	y := c.y
	text(w, w.f_h2, c.x, y, 34, ed.original == "" ? tr(w, "Novo atalho", "New shortcut") : tr(w, "Editar atalho", "Edit shortcut"), th.fg)
	y += 42

	// Key combination.
	text(w, w.f_tiny, c.x, y, 18, tr(w, "COMBINAÇÃO DE TECLAS", "KEY COMBINATION"), th.muted)
	y += 22
	field := tx.Rect{c.x, y, c.w, 56}
	hot := hovered(w, .Sc_Capture)
	fill_rounded(cv, field, 16, ed.capturing ? th.bg : (hot ? mix(th.field, th.hover, 0.5) : th.field))
	tx.canvas_stroke_rounded_rect(cv, field, 16, ed.capturing ? 2 : 1, ed.capturing ? th.accent : th.outline)
	icon(w, w.f_icon, {field.x + 14, field.y, 26, field.h}, .Keyboard, ed.capturing ? th.accent : th.muted)
	if ed.capturing {
		text(w, w.f_body, field.x + 52, field.y, field.h, tr(w, "Pressione a combinação…  (Esc cancela)", "Press the combination…  (Esc cancels)"), th.accent)
	} else if ed.spec != "" {
		draw_chips(w, cv, field.x + 52, field.y + field.h / 2, ed.spec)
		change := tr(w, "Clique para trocar", "Click to change")
		cw := text_width(w, w.f_small, change)
		text(w, w.f_small, field.x + field.w - 16 - cw, field.y, field.h, change, th.muted)
	} else {
		text(w, w.f_body, field.x + 52, field.y, field.h, tr(w, "Clique aqui e pressione a combinação de teclas", "Click here and press the key combination"), th.muted)
	}
	add_hit(w, field, .Sc_Capture)
	y += 62

	// Conflicts and hints.
	note := ""
	note_color := th.warning
	if ed.hint != "" {
		note = ed.hint
	} else if ed.spec != "" {
		if dup := duplicate_row(w, ed.spec); dup >= 0 {
			note = tr(w, "Já é um atalho seu: ele será substituído ao salvar.", "Already one of your shortcuts: it is replaced when you save.")
		} else if action, found := builtin_conflict(w, ed.spec); found {
			note = fmt.tprintf(tr(w, "Substitui: %s (atalho do milk)", "Replaces: %s (milk shortcut)"), action)
		}
	}
	if note != "" {
		icon(w, w.f_icon_small, {c.x, y, 20, 24}, .Alert, note_color)
		text(w, w.f_small, c.x + 26, y, 24, ellipsize(w, w.f_small, note, c.w - 26), note_color)
	}
	y += 30

	// What it opens.
	text(w, w.f_tiny, c.x, y, 18, tr(w, "ABRIR", "OPEN"), th.muted)
	y += 22
	segmented(w, cv, {c.x, y, min(i32(480), c.w), 42}, {tr(w, "Aplicativo", "Application"), tr(w, "Comando", "Command"), tr(w, "Site ou pasta", "Site or folder")},
	          {.Apps, .Terminal, .World}, ed.kind, .Sc_Kind)
	y += 54

	footer_y := c.y + c.h - 44
	body := tx.Rect{c.x, y, c.w, footer_y - 14 - y}
	switch ed.kind {
	case 0:
		search_target := int(Control.Sc_Search) * 100
		draw_field(w, cv, {body.x, body.y, body.w, 40}, .Search, string(ed.search[:]), tr(w, "Buscar aplicativo…", "Search applications…"),
		           w.focus == .Text && w.set.text_target == search_target, .Text_Field, search_target)
		lr := tx.Rect{body.x, body.y + 48, body.w, body.h - 48}
		if lr.h > 40 { draw_app_list(w, cv, lr) }
	case 1:
		target := int(Control.Sc_Command) * 100
		draw_field(w, cv, {body.x, body.y, body.w, 44}, .Terminal, string(ed.command[:]), tr(w, "Ex.: alacritty -e htop", "E.g. alacritty -e htop"),
		           w.focus == .Text && w.set.text_target == target, .Text_Field, target)
		text(w, w.f_small, body.x + 4, body.y + 52, 22, tr(w, "Executado com /bin/sh -c, como os outros atalhos do milk.", "Run with /bin/sh -c, like milk's other shortcuts."), th.muted)
	case 2:
		target := int(Control.Sc_Site) * 100
		draw_field(w, cv, {body.x, body.y, body.w, 44}, .World, string(ed.site[:]), tr(w, "Ex.: https://milk.dev ou ~/Documentos", "E.g. https://example.com or ~/Documents"),
		           w.focus == .Text && w.set.text_target == target, .Text_Field, target)
		text(w, w.f_small, body.x + 4, body.y + 52, 22, tr(w, "Aberto com xdg-open no aplicativo padrão.", "Opened with xdg-open in the default application."), th.muted)
	}

	// Footer.
	save := tr(w, "Salvar", "Save")
	sw := max(button_width(w, save, .Check), 130)
	ready := ed.spec != "" && editor_command(w) != "" && !ed.capturing
	save_r := tx.Rect{c.x + c.w - sw, footer_y, sw, BUTTON_H}
	if ready {
		button(w, cv, save_r, save, .Filled, .Sc_Save, 0, .Check)
	} else {
		fill_rounded(cv, save_r, f32(BUTTON_H) / 2, mix(th.surface, th.bg, 0.3))
		text_centered(w, w.f_h2, save_r, save, th.muted)
	}
	cancel := tr(w, "Cancelar", "Cancel")
	cw := button_width(w, cancel)
	button(w, cv, {save_r.x - 10 - cw, footer_y, cw, BUTTON_H}, cancel, .Text, .Sc_Cancel)
}

@(private)
draw_app_list :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect) {
	th := &w.theme
	sc := &w.set.sc
	ed := &sc.ed
	query := strings.to_lower(strings.trim_space(string(ed.search[:])), context.temp_allocator)
	shown := make([dynamic]int, context.temp_allocator)
	for app, i in sc.apps {
		if query != "" && !strings.contains(strings.to_lower(app.sc.name, context.temp_allocator), query) && !strings.contains(app.prog, query) { continue }
		append(&shown, i)
	}
	content_h := i32(len(shown)) * ROW_H + 8
	sub := list_begin(w, r, content_h, &ed.scroll_apps, .Apps)
	for idx, k in shown {
		y := 4 + i32(k) * ROW_H - ed.scroll_apps + 2
		if y + ROW_H < 0 { continue }
		if y > r.h { break }
		app := &sc.apps[idx]
		row := tx.Rect{6, y, r.w - 18, ROW_H - 4}
		sel := idx == ed.app
		if sel {
			fill_rounded(&sub, row, 12, th.accent)
		} else if hovered(w, .Sc_App, idx) {
			fill_rounded(&sub, row, 12, th.hover)
		}
		if img := app_icon(w, idx); img != nil {
			tx.canvas_blit_image(&sub, img^, row.x + 10, row.y + (row.h - img.h) / 2)
		} else {
			fill_rounded(&sub, {row.x + 10, row.y + 6, 24, 24}, 7, mix(th.muted, th.field, 0.6))
		}
		win_row := tx.Rect{r.x + row.x, r.y + row.y, row.w, row.h}
		fg := sel ? th.accent_fg : th.fg
		text(w, w.f_body, win_row.x + 44, win_row.y, win_row.h, ellipsize(w, w.f_body, app.sc.name, win_row.w - 180), fg, r)
		pw := text_width(w, w.f_small, app.prog)
		if pw < 140 { text(w, w.f_small, win_row.x + win_row.w - 14 - pw, win_row.y, win_row.h, app.prog, sel ? mix(th.accent_fg, th.accent, 0.3) : th.muted, r) }
		add_hit(w, win_row, .Sc_App, idx, r)
	}
	if len(shown) == 0 {
		text_centered(w, w.f_body, {r.x, r.y + 16, r.w, 30}, tr(w, "Nenhum aplicativo encontrado", "No application found"), th.muted)
	}
	list_end(w, cv, &sub, r, content_h, ed.scroll_apps)
}
