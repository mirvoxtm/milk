// Settings → Lançador: milk's launcher (milk/launcher.odin), the "launcher"
// section of milk.json. Two tabs: what typing finds (milk's entries, sums,
// commands, the web, addresses, files) and how it looks (its tabs, where it
// opens, its size, how names match). The user's own entries
// (launcher.entries) are written in milk.json.
package oobe

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import config "../config"
import tx "../tx"

// Search engines offered, then "off" (the stepper walks them).
@(private) LN_ENGINES :: [?]string{"duckduckgo", "google", "bing", "brave", "startpage", "ecosia", ""}
@(private) LN_ENGINE_NAMES :: [?]string{"DuckDuckGo", "Google", "Bing", "Brave", "Startpage", "Ecosia", ""}

@(private)
Launcher_Settings :: struct {
	tab:          int, // 0 search, 1 look
	milk_entries: bool,
	calculator:   bool,
	commands:     bool,
	engine:       int,  // LN_ENGINES; len-1 = off; -1 = a URL of the user's
	engine_url:   string, // that URL (owned)
	files:        bool,
	folder:       [dynamic]u8,
	tab_windows:  bool,
	tab_files:    bool,
	tab_run:      bool,
	near_button:  bool,
	width:        int,
	lines:        int,
	matching:     int, // config.LAUNCHER_MATCHING
}

@(private)
launcher_load_values :: proc(w: ^Wizard) {
	l := &w.set.lnch
	o := &w.cfg.launcher
	l.milk_entries = o.milk_entries
	l.calculator = o.calculator
	l.commands = o.run_commands
	l.engine = -1
	for e, i in LN_ENGINES { if e == o.web_search { l.engine = i } }
	if l.engine < 0 { l.engine_url = strings.clone(o.web_search) }
	l.files = o.file_search
	append(&l.folder, ..transmute([]u8)o.files_folder)
	for t in o.tabs {
		switch t {
		case "windows": l.tab_windows = true
		case "files":   l.tab_files = true
		case "run":     l.tab_run = true
		}
	}
	l.near_button = o.near_button
	l.width = o.width
	l.lines = o.lines
	for m, i in config.LAUNCHER_MATCHING { if m == o.matching { l.matching = i } }
}

@(private)
launcher_destroy :: proc(w: ^Wizard) {
	l := &w.set.lnch
	delete(l.engine_url)
	delete(l.folder)
	l^ = {}
}

@(private)
draw_launcher_section :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	l := &w.set.lnch
	segmented(w, cv, {c.x, c.y, min(i32(360), c.w), 40}, {tr(w, "Busca", "Search"), tr(w, "Aparência", "Look")},
	          {.Search, .App_Window}, l.tab, .Ln_Tab)
	y := c.y + 56
	if l.tab == 1 {
		rows_launcher_look(w, cv, c, &y)
	} else {
		rows_launcher_search(w, cv, c, &y)
	}
}

@(private)
rows_launcher_search :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect, y: ^i32) {
	l := &w.set.lnch
	row := next_row(w, cv, c, y, tr(w, "Entradas do milk", "milk's entries"),
	                tr(w, "Áreas, visão geral, páginas das configurações e sessão na lista", "Areas, the overview, settings pages and the session in the list"))
	toggle(w, cv, row, l.milk_entries, .Ln_Milk_Entries)
	row = next_row(w, cv, c, y, tr(w, "Calculadora", "Calculator"), tr(w, "Digite 12*3 e Enter: o resultado, para copiar", "Type 12*3 and Enter: the result, to copy"))
	toggle(w, cv, row, l.calculator, .Ln_Calculator)
	row = next_row(w, cv, c, y, tr(w, "Executar comandos", "Run commands"),
	               tr(w, "Um comando digitado roda com Enter; htop e vim no terminal", "A typed command runs with Enter; htop and vim in the terminal"))
	toggle(w, cv, row, l.commands, .Ln_Commands)
	engine := tr(w, "Desligada", "Off")
	names := LN_ENGINE_NAMES
	switch {
	case l.engine < 0:                   engine = tr(w, "Própria", "Your own")
	case l.engine < len(names) - 1:      engine = names[l.engine]
	}
	row = next_row(w, cv, c, y, tr(w, "Pesquisa na web", "Web search"),
	               l.engine < 0 ? ellipsize(w, w.f_small, l.engine_url, row_desc_width(c)) : tr(w, "? e o que procurar, ou quando nada é encontrado", "? and what to look for, or when nothing is found"))
	stepper(w, cv, row, engine, .Ln_Engine)
	row = next_row(w, cv, c, y, tr(w, "Procurar arquivos", "Find files"), tr(w, "/ e o nome, e a aba Arquivos", "/ and the name, and the Files tab"))
	toggle(w, cv, row, l.files, .Ln_Files)
	row = next_row(w, cv, c, y, tr(w, "Pasta dos arquivos", "Files folder"), tr(w, "Onde a busca de arquivos procura", "Where the file search looks"), !l.files && !l.tab_files)
	text_control(w, cv, row, min(i32(300), c.w / 2), l.folder[:], "~", int(Control.Ln_Folder) * 100)
}

@(private)
row_desc_width :: proc(c: tx.Rect) -> i32 { return max(c.w - 320, 120) }

@(private)
rows_launcher_look :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect, y: ^i32) {
	l := &w.set.lnch
	row := next_row(w, cv, c, y, tr(w, "Aba Janelas", "Windows tab"), tr(w, "As janelas de todas as áreas", "The windows of every area"))
	toggle(w, cv, row, l.tab_windows, .Ln_Tab_Windows)
	row = next_row(w, cv, c, y, tr(w, "Aba Arquivos", "Files tab"), tr(w, "Os arquivos da pasta, encontrados enquanto você digita", "The folder's files, found as you type"))
	toggle(w, cv, row, l.tab_files, .Ln_Tab_Files)
	row = next_row(w, cv, c, y, tr(w, "Aba Executar", "Run tab"), tr(w, "Um comando, com o que já foi digitado antes", "A command, with what was typed before"))
	toggle(w, cv, row, l.tab_run, .Ln_Tab_Run)
	cw := min(i32(360), c.w / 2)
	row = next_row(w, cv, c, y, tr(w, "Pelo botão da barra", "From the bar's button"), "")
	choice_control(w, cv, {row.x + row.w - cw, row.y + 8, cw, 40}, {tr(w, "Ao lado dele", "Beside it"), tr(w, "No centro", "Centred")},
	               l.near_button ? 0 : 1, .Ln_Near)
	row = next_row(w, cv, c, y, tr(w, "Largura", "Width"), "")
	stepper(w, cv, row, fmt.tprintf("%d px", l.width), .Ln_Width)
	row = next_row(w, cv, c, y, tr(w, "Linhas", "Rows"), tr(w, "Quantas entradas aparecem de uma vez", "How many entries show at once"))
	stepper(w, cv, row, fmt.tprintf("%d", l.lines), .Ln_Lines)
	row = next_row(w, cv, c, y, tr(w, "Busca por nome", "Name matching"), "")
	choice_control(w, cv, {row.x + row.w - cw, row.y + 8, cw, 40}, {tr(w, "Normal", "Normal"), tr(w, "Aproximada", "Fuzzy"), tr(w, "Início", "Start")},
	               l.matching, .Ln_Matching)
	if y^ + 30 <= c.y + c.h {
		text(w, w.f_small, c.x, y^ + 6, 22, ellipsize(w, w.f_small, tr(w, "Entradas próprias (um nome e um comando): launcher.entries no milk.json.",
		                                                           "Entries of your own (a name and a command): launcher.entries in milk.json."), c.w), w.theme.muted)
	}
}

@(private)
launcher_toggle :: proc(w: ^Wizard, ctrl: Control) -> bool {
	l := &w.set.lnch
	#partial switch ctrl {
	case .Ln_Milk_Entries:
		l.milk_entries = !l.milk_entries
		set_edit(w, "launcher.milkEntries", json.Boolean(l.milk_entries))
	case .Ln_Calculator:
		l.calculator = !l.calculator
		set_edit(w, "launcher.calculator", json.Boolean(l.calculator))
	case .Ln_Commands:
		l.commands = !l.commands
		set_edit(w, "launcher.runCommands", json.Boolean(l.commands))
	case .Ln_Files:
		l.files = !l.files
		set_edit(w, "launcher.fileSearch", json.Boolean(l.files))
	case .Ln_Tab_Windows, .Ln_Tab_Files, .Ln_Tab_Run:
		#partial switch ctrl {
		case .Ln_Tab_Windows: l.tab_windows = !l.tab_windows
		case .Ln_Tab_Files:   l.tab_files = !l.tab_files
		case:                 l.tab_run = !l.tab_run
		}
		// Kept by the pending edit (set_edit copies only strings).
		tabs := make(json.Array)
		append(&tabs, json.Value(json.String("apps")))
		if l.tab_windows { append(&tabs, json.Value(json.String("windows"))) }
		if l.tab_files { append(&tabs, json.Value(json.String("files"))) }
		if l.tab_run { append(&tabs, json.Value(json.String("run"))) }
		set_edit(w, "launcher.tabs", tabs)
	case:
		return false
	}
	return true
}

@(private)
launcher_step :: proc(w: ^Wizard, ctrl: Control, dir: int) -> bool {
	l := &w.set.lnch
	#partial switch ctrl {
	case .Ln_Engine:
		engines := LN_ENGINES
		n := len(engines)
		cur := l.engine < 0 ? n - 1 : l.engine
		l.engine = (cur + dir + n) % n
		value := engines[l.engine]
		set_edit(w, "launcher.webSearch", value == "" ? json.Value(json.Null(nil)) : json.Value(json.String(value)))
	case .Ln_Width:
		l.width = clamp(l.width + 40 * dir, 400, 1200)
		set_edit(w, "launcher.width", json.Integer(l.width))
	case .Ln_Lines:
		l.lines = clamp(l.lines + dir, 4, 16)
		set_edit(w, "launcher.lines", json.Integer(l.lines))
	case:
		return false
	}
	return true
}

@(private)
launcher_choice :: proc(w: ^Wizard, ctrl: Control, opt: int) -> bool {
	l := &w.set.lnch
	#partial switch ctrl {
	case .Ln_Near:
		l.near_button = opt == 0
		set_edit(w, "launcher.nearButton", json.Boolean(l.near_button))
	case .Ln_Matching:
		names := config.LAUNCHER_MATCHING
		l.matching = clamp(opt, 0, len(names) - 1)
		set_edit(w, "launcher.matching", json.String(names[l.matching]))
	case:
		return false
	}
	return true
}

// The folder field; saved once it is not empty.
@(private)
launcher_text_edited :: proc(w: ^Wizard) -> bool {
	value := strings.trim_space(string(w.set.lnch.folder[:]))
	if value == "" { return false }
	set_edit(w, "launcher.filesFolder", json.String(value))
	return true
}
