// The launcher's apps tab (launcher.odin): rofi's script mode, served by
// `milk launcher script [selected text]`. It lists the installed
// applications, milk's own entries and launcher.entries, the most used first,
// and makes sense of text typed with no entry for it (Enter):
//   = 2*(3+4)      a sum: its result, Enter again copies it (also without "=")
//   ? something    a web search (launcher.webSearch)
//   / name         files with that name under launcher.filesFolder
//   ! command      runs it; > command runs it in the terminal
//   an address (milk.dev, https://…) opens in the default browser; a path
//   (~/notes) opens it;
//   a command (pavucontrol, nvim notes.txt) runs it, terminal programs in the
//   terminal; anything else offers a web search and a file search.
package milk

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import config "../config"
import desktop "../desktop"
import tx "../tx"
import wm "../wm"

// Tabler codepoints for milk's entries.
@(private="file") GL_OVERVIEW   :: rune(0xEF95) // layout-board
@(private="file") GL_AREA       :: rune(0xEEE6) // square-number-1 (…-9 follow it)
@(private="file") GL_SETTINGS   :: rune(0xEB20)
@(private="file") GL_PALETTE    :: rune(0xEB01)
@(private="file") GL_PHOTO      :: rune(0xEB0A)
@(private="file") GL_BAR        :: rune(0xEAD7) // layout-navbar
@(private="file") GL_WINDOW     :: rune(0xEFE6) // app-window
@(private="file") GL_DESKTOP    :: rune(0xEA89)
@(private="file") GL_SPARKLES   :: rune(0xF6D7)
@(private="file") GL_SUN        :: rune(0xEB30)
@(private="file") GL_COMMAND    :: rune(0xEA78)
@(private="file") GL_KEYBOARD   :: rune(0xEBD6)
@(private="file") GL_BELL       :: rune(0xEA35)
@(private="file") GL_CLIPBOARD  :: rune(0xEA6F)
@(private="file") GL_LOCK       :: rune(0xEAE2)
@(private="file") GL_GRID       :: rune(0xEDBA)
@(private="file") GL_INFO       :: rune(0xEAC5)
@(private="file") GL_SEARCH     :: rune(0xEB1C)
@(private="file") GL_SCREENSHOT :: rune(0xF201)
@(private="file") GL_MOON       :: rune(0xECE7) // moon-stars
@(private="file") GL_RELOAD     :: rune(0xF3AE)
@(private="file") GL_ZZZ        :: rune(0xF228)
@(private="file") GL_LOGOUT     :: rune(0xEBA8)
@(private="file") GL_REBOOT     :: rune(0xEB13)
@(private="file") GL_POWER      :: rune(0xEB0D)
@(private="file") GL_CALC       :: rune(0xEB80)
@(private="file") GL_WORLD      :: rune(0xEB54)
@(private="file") GL_FOLDER     :: rune(0xEAAD)
@(private="file") GL_TERMINAL   :: rune(0xEBEF) // terminal-2
@(private="file") GL_LAUNCHER   :: rune(0xEC45) // rocket: the launcher's own settings
@(private="file") GL_BACK       :: rune(0xEB77) // arrow-back-up

@(private="file") FILE_RESULTS :: 60

// Programs that need a terminal when typed as a command (launcher.terminalCommands adds more).
@(private="file")
TERMINAL_PROGRAMS :: []string{
	"htop", "btop", "top", "atop", "nvtop", "vim", "nvim", "vi", "nano", "micro", "helix", "hx", "emacs", "less", "more",
	"man", "ssh", "mosh", "mc", "ranger", "nnn", "lf", "yazi", "nmtui", "alsamixer", "pulsemixer", "cmus", "ncmpcpp",
	"ncdu", "tmux", "zellij", "python", "python3", "ipython", "node", "lua", "irb", "ghci", "bash", "zsh", "fish", "sh",
	"watch", "sudo", "pacman", "paru", "yay", "apt", "dnf", "zypper", "journalctl", "dmesg", "ping", "nethogs", "iotop",
}

// Common top-level domains: "milk.dev" is an address, "milk.json" a file.
@(private="file")
TLDS :: []string{
	"com", "org", "net", "io", "dev", "app", "ai", "gov", "edu", "co", "me", "tv", "info", "xyz", "br", "pt", "es",
	"uk", "de", "fr", "it", "nl", "jp", "ru", "us", "ca", "au", "eu", "gg", "ly", "to", "fm", "tech", "site",
	"online", "blog", "wiki", "page", "news", "store", "cloud", "social", "chat", "game", "games",
}

@(private="file")
Entry :: struct {
	label:   string,
	info:    string, // what selecting it does (launcher_run)
	glyph:   rune,   // milk's entries: a Tabler icon
	icon:    string, // an icon theme name or a path
	meta:    string, // more words it is found by
	display: string, // markup shown instead of the label (file results)
	group:   int,    // the order without history: 0 the user's, 1 apps, 2 milk's
	score:   f64,    // how much it was used lately
}

@(private="file")
Script :: struct {
	cfg:     ^config.Config,
	lo:      config.Launcher_Options,
	lang:    config.Language,
	c:       ^tx.Connection,
	out:     strings.Builder,
	milk_wm: bool, // milk's window manager runs (areas, the overview, the session)
	icons:   Icon_Painter,
}

// `args`: what follows "launcher script" (the entry rofi passes back).
cmd_launcher_script :: proc(args: []string) -> int {
	s := Script{lo = config.default_launcher()}
	cfg, err := config.load(default_config_path())
	if err == "" {
		s.cfg = cfg
		s.lo = cfg.launcher
		s.lang = cfg.bar.language
	}
	defer if s.cfg != nil { config.destroy(s.cfg) }
	s.out = strings.builder_make(context.temp_allocator)
	retv := os.get_env("ROFI_RETV", context.temp_allocator)
	info := os.get_env("ROFI_INFO", context.temp_allocator)
	typed := strings.trim_space(strings.join(args, " ", context.temp_allocator))
	if retv == "1" && info != "" && info != "back" && !strings.has_prefix(info, "files:") {
		launcher_run(info, s.cfg) // returns at once to rofi, which closes
		return 0
	}
	if c, ok := tx.connect(); ok {
		s.c = c
		s.milk_wm = tx.wm_name(c) == wm.WM_NAME
	}
	defer if s.c != nil { tx.disconnect(s.c) }
	icons_init(&s.icons, s.c, s.cfg)
	defer icons_destroy(&s.icons)
	switch {
	case retv == "1" && strings.has_prefix(info, "files:"):
		list_files(&s, info[len("files:"):])
	case retv == "2" && typed != "":
		if run := typed_text(&s, typed); run != "" {
			launcher_run(run, s.cfg) // returns at once to rofi, which closes
			return 0
		}
	case:
		list_all(&s, "")
	}
	os.write_string(os.stdout, strings.to_string(s.out))
	return 0
}

@(private="file")
tr :: proc(s: ^Script, pt, en: string) -> string { return config.tr(s.lang, pt, en) }

// rofi shows messages as Pango markup: `text` must be escaped already.
@(private="file")
message :: proc(s: ^Script, text: string) {
	fmt.sbprintf(&s.out, "\x00message\x1f%s\n", text)
}

@(private="file")
write_entry :: proc(s: ^Script, e: Entry) {
	icon := e.icon
	if e.glyph != 0 {
		if path := icon_path(&s.icons, e.glyph); path != "" { icon = path }
	}
	label, _ := strings.replace_all(e.label, "\n", " ", context.temp_allocator)
	fmt.sbprintf(&s.out, "%s\x00info\x1f%s", label, e.info)
	if icon != "" { fmt.sbprintf(&s.out, "\x1ficon\x1f%s", icon) }
	if meta := words_only(e.meta); meta != "" { fmt.sbprintf(&s.out, "\x1fmeta\x1f%s", meta) }
	if e.display != "" { fmt.sbprintf(&s.out, "\x1fdisplay\x1f%s", e.display) }
	strings.write_byte(&s.out, '\n')
}

// The hidden words an entry is found by, letters and digits only: typed
// prefixes ("/ notes", "? weather") must find no entry, to reach typed_text.
@(private="file")
words_only :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		ok := r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r > 0x7F
		strings.write_rune(&b, ok ? r : ' ')
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// The list
// ---------------------------------------------------------------------------
@(private="file")
list_all :: proc(s: ^Script, note: string) {
	if note != "" { message(s, note) }
	entries := make([dynamic]Entry, context.temp_allocator)
	for e, i in s.lo.entries {
		append(&entries, Entry{label = e.name, info = fmt.tprintf("cmd:%d", i), icon = e.icon, meta = e.keywords, group = 0})
	}
	scan_apps(&entries)
	if s.lo.milk_entries { milk_entries(s, &entries) }
	history := history_load()
	for &e in entries { e.score = history[e.info] or_else 0 }
	slice.stable_sort_by(entries[:], proc(a, b: Entry) -> bool {
		if a.score != b.score { return a.score > b.score }
		return a.group < b.group
	})
	for e in entries { write_entry(s, e) }
}

// Installed applications: desktop entries from $XDG_DATA_HOME and
// $XDG_DATA_DIRS (and Flatpak's), the first of each file id winning, by name.
@(private="file")
scan_apps :: proc(out: ^[dynamic]Entry) {
	dirs := make([dynamic]string, context.temp_allocator)
	data_home := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if data_home == "" { data_home = join({home_dir(), ".local", "share"}) }
	append(&dirs, join({data_home, "applications"}))
	append(&dirs, join({home_dir(), ".local/share/flatpak/exports/share/applications"}))
	data_dirs := os.get_env("XDG_DATA_DIRS", context.temp_allocator)
	if data_dirs == "" { data_dirs = "/usr/local/share:/usr/share" }
	for d in strings.split(data_dirs, ":", context.temp_allocator) {
		if d != "" { append(&dirs, join({d, "applications"})) }
	}
	append(&dirs, "/var/lib/flatpak/exports/share/applications")
	desktops := strings.split(os.get_env("XDG_CURRENT_DESKTOP", context.temp_allocator), ":", context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	apps := make([dynamic]Entry, context.temp_allocator)
	for dir in dirs { scan_app_dir(dir, "", &seen, &apps, desktops) }
	slice.sort_by(apps[:], proc(a, b: Entry) -> bool {
		return strings.to_lower(a.label, context.temp_allocator) < strings.to_lower(b.label, context.temp_allocator)
	})
	append(out, ..apps[:])
}

@(private="file")
scan_app_dir :: proc(dir, prefix: string, seen: ^map[string]bool, out: ^[dynamic]Entry, desktops: []string) {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for fi in infos {
		path := join({dir, fi.name})
		if fi.type == .Directory {
			scan_app_dir(path, fmt.tprintf("%s%s-", prefix, fi.name), seen, out, desktops)
			continue
		}
		if !strings.has_suffix(fi.name, ".desktop") { continue }
		id := fmt.tprintf("%s%s", prefix, fi.name)
		if seen[id] { continue }
		seen[id] = true // hidden or not, it hides the same id further down
		text, ok := desktop.read_text_file(path)
		if !ok { continue }
		ini := desktop.parse_ini(text)
		e, has := ini["Desktop Entry"]
		if !has || (e["Type"] or_else "Application") != "Application" { continue }
		if truthy(e["NoDisplay"] or_else "") || truthy(e["Hidden"] or_else "") { continue }
		if !shown_in(e["OnlyShowIn"] or_else "", e["NotShowIn"] or_else "", desktops) { continue }
		exec := desktop.unescape_value(e["Exec"] or_else "")
		if strings.trim_space(exec) == "" { continue }
		if try_exec := desktop.unescape_value(e["TryExec"] or_else ""); try_exec != "" {
			if _, found := desktop.find_executable(try_exec); !found { continue }
		}
		name := desktop.unescape_value(desktop.localized(e, "Name"))
		if name == "" { continue }
		meta := strings.join({desktop.localized(e, "GenericName"), desktop.localized(e, "Keywords"), desktop.localized(e, "Comment"),
		                      e["Categories"] or_else "", program_name(exec), strings.trim_suffix(id, ".desktop")}, " ", context.temp_allocator)
		meta, _ = strings.replace_all(meta, ";", " ", context.temp_allocator)
		append(out, Entry{label = name, info = fmt.tprintf("app:%s", path), icon = desktop.unescape_value(desktop.localized(e, "Icon")),
		                  meta = meta, group = 1})
	}
}

@(private="file")
truthy :: proc(v: string) -> bool { return strings.equal_fold(strings.trim_space(v), "true") }

// OnlyShowIn / NotShowIn against $XDG_CURRENT_DESKTOP ("milk" in milk's session).
@(private="file")
shown_in :: proc(only, not: string, desktops: []string) -> bool {
	listed :: proc(list: string, desktops: []string) -> bool {
		for d in strings.split(list, ";", context.temp_allocator) {
			if d == "" { continue }
			for cur in desktops { if strings.equal_fold(d, cur) { return true } }
		}
		return false
	}
	if strings.trim_space(only) != "" && !listed(only, desktops) { return false }
	return !listed(not, desktops)
}

// The program an Exec line starts ("env A=b /usr/bin/foo %U" → "foo").
@(private="file")
program_name :: proc(exec: string) -> string {
	for tok in strings.fields(exec, context.temp_allocator) {
		t := strings.trim(tok, "\"'")
		if t == "env" || strings.index_byte(t, '=') > 0 || strings.has_prefix(t, "%") { continue }
		return os.base(t)
	}
	return ""
}

@(private="file")
milk_entries :: proc(s: ^Script, out: ^[dynamic]Entry) {
	add :: proc(out: ^[dynamic]Entry, label, info: string, glyph: rune, icon, meta: string) {
		append(out, Entry{label = label, info = info, glyph = glyph, icon = icon, meta = meta, group = 2})
	}
	if s.milk_wm {
		add(out, tr(s, "Visão geral de todas as áreas", "Overview of every area"), "wm:overview", GL_OVERVIEW, "view-grid",
		    "milk overview areas workspaces visão geral áreas expose")
		count := s.cfg != nil ? clamp(s.cfg.wm.tag_count, 1, 32) : 9
		for n in 1 ..= count {
			name := ""
			glyph := n <= 9 ? GL_AREA + rune(n - 1) : GL_GRID
			if s.cfg != nil {
				if ws, known := config.workspace(s.cfg, n); known { name = strings.trim_space(ws.name) }
				if r, has := config.workspace_icon(s.cfg, n); has { glyph = r }
			}
			label := fmt.tprintf(tr(s, "Ir para a área %d", "Go to area %d"), n)
			if name != "" { label = fmt.tprintf("%s · %s", label, name) }
			add(out, label, fmt.tprintf("wm:view %d", n), glyph, "user-desktop", fmt.tprintf("milk area workspace área desktop %d", n))
		}
	}
	add(out, tr(s, "Configurações do milk", "milk settings"), "settings:", GL_SETTINGS, "preferences-system",
	    "milk settings preferences configurações preferências ajustes")
	Page :: struct { section: string, glyph: rune, pt, en, pt_more, en_more: string }
	pages := []Page{
		{"appearance", GL_PALETTE, "Aparência", "Appearance", "Tema de cores, foto de perfil e animações.", "Colour theme, profile picture and animations."},
		{"wallpapers", GL_PHOTO, "Papéis de parede", "Wallpapers", "Uma imagem para todas as áreas ou uma para cada área.", "One image for every area or one per area."},
		{"bar", GL_BAR, "Barra", "Bar", "Posição, estilo, tamanho, widgets e formatos de data e hora.", "Position, style, size, widgets and date/time formats."},
		{"windows", GL_WINDOW, "Janelas", "Windows", "Lado a lado ou flutuantes, bordas, barra de título e animações.", "Tiling or floating, borders, title bars and animations."},
		{"desktop", GL_DESKTOP, "Área de trabalho", "Desktop", "Ícones de arquivos e atalhos sobre o papel de parede.", "File and shortcut icons over the wallpaper."},
		{"effects", GL_SPARKLES, "Efeitos", "Effects", "Sombras, animações e transparência com o lactase, o compositor do milk.", "Shadows, animations and transparency with lactase, milk's compositor."},
		{"display", GL_SUN, "Tela", "Display", "Luz noturna e o aviso de volume e brilho.", "Night light and the volume and brightness pop-up."},
		{"shortcuts", GL_COMMAND, "Atalhos", "Shortcuts", "Combinações de teclas para aplicativos, comandos, sites e ações das janelas.", "Key combinations for applications, commands, sites and window actions."},
		{"launcher", GL_LAUNCHER, "Lançador", "Launcher", "Abas, busca na web, arquivos, comandos e entradas próprias.", "Tabs, web search, files, commands and entries of your own."},
		{"keyboard", GL_KEYBOARD, "Idioma e teclado", "Language and keyboard", "Idioma do milk, layout e variante do teclado, aplicados na hora.", "milk's language and the keyboard layout and variant, applied at once."},
		{"notifications", GL_BELL, "Notificações", "Notifications", "Avisos que aparecem no canto da tela.", "Pop-ups shown in a corner of the screen."},
		{"clipboard", GL_CLIPBOARD, "Área de transferência", "Clipboard", "Histórico de textos e imagens copiados.", "History of copied text and images."},
		{"lock", GL_LOCK, "Bloqueio e inatividade", "Lock & idle", "Tela de bloqueio e o que acontece quando o computador fica sem uso.", "The lock screen and what happens when the computer is not in use."},
		{"areas", GL_GRID, "Áreas", "Areas", "Nomes e ícones das áreas, mostrados no aviso de área e na barra.", "Area names and icons, shown by the area toast and on the bar."},
		{"about", GL_INFO, "Sobre", "About", "Versão, arquivos e assistente inicial.", "Version, files and the setup wizard."},
	}
	settings := tr(s, "Configurações", "Settings")
	for p in pages {
		add(out, fmt.tprintf("%s › %s", settings, tr(s, p.pt, p.en)), fmt.tprintf("settings:%s", p.section), p.glyph, "preferences-system",
		    fmt.tprintf("milk settings configurações %s %s %s", p.en, p.section, tr(s, p.pt_more, p.en_more)))
	}
	if s.milk_wm {
		add(out, tr(s, "Histórico da área de transferência", "Clipboard history"), "wm:clipboard", GL_CLIPBOARD, "edit-paste",
		    "milk clipboard history copy paste área de transferência colar copiar")
		add(out, tr(s, "Notificações", "Notifications"), "wm:notifications", GL_BELL, "preferences-desktop-notification", "milk notifications notificações avisos")
		add(out, tr(s, "Capturar uma região da tela", "Screenshot of a region"), "wm:screenshot", GL_SCREENSHOT, "applets-screenshooter",
		    "milk screenshot capture print captura tela snippy")
		add(out, tr(s, "Ligar ou desligar a luz noturna", "Turn the night light on or off"), "wm:night-light", GL_MOON, "weather-clear-night",
		    "milk night light luz noturna redshift")
		add(out, tr(s, "Recarregar milk.json", "Reload milk.json"), "wm:reload", GL_RELOAD, "view-refresh", "milk reload recarregar config")
	}
	add(out, tr(s, "Bloquear a tela", "Lock the screen"), "lock", GL_LOCK, "system-lock-screen", "milk lock bloquear sessão session")
	if s.milk_wm {
		add(out, tr(s, "Suspender", "Suspend"), "wm:suspend", GL_ZZZ, "system-suspend", "milk suspend sleep suspender dormir sessão session")
		add(out, tr(s, "Sair da sessão", "Log out"), "ask:quit", GL_LOGOUT, "system-log-out", "milk log out logout exit sair sessão session")
		add(out, tr(s, "Reiniciar o computador", "Restart the computer"), "ask:reboot", GL_REBOOT, "system-reboot", "milk restart reboot reiniciar sessão session")
		add(out, tr(s, "Desligar o computador", "Power off the computer"), "ask:poweroff", GL_POWER, "system-shutdown", "milk power off shutdown desligar sessão session")
	}
}

// ---------------------------------------------------------------------------
// Typed text (Enter with no entry for it)
// ---------------------------------------------------------------------------
// What to run at once (an entry's info), or "" when it listed something.
@(private="file")
typed_text :: proc(s: ^Script, text: string) -> string {
	lo := &s.lo
	web := config.web_search_url(lo) != ""
	rest := strings.trim_space(text[1:]) if len(text) > 0 else ""
	switch text[0] {
	case '=':
		if v, ok := calculate(rest); ok {
			result_list(s, rest, v)
			return ""
		}
		list_all(s, fmt.tprintf(tr(s, "“%s” não é uma conta.", "“%s” is no sum."), markup_escape(rest)))
		return ""
	case '?':
		if web && rest != "" { return fmt.tprintf("web:%s", rest) }
	case '!':
		if rest != "" { return fmt.tprintf("run:%s", rest) }
	case '>':
		if rest != "" { return fmt.tprintf("term:%s", rest) }
	case '/', '~':
		path := expand_home(text)
		if os.exists(path) { return fmt.tprintf("open:%s", path) }
		if text[0] == '/' && lo.file_search && rest != "" {
			list_files(s, rest)
			return ""
		}
	}
	if lo.calculator {
		if v, ok := calculate(text); ok {
			result_list(s, text, v)
			return ""
		}
	}
	if url, ok := address(text); ok { return fmt.tprintf("open:%s", url) }
	if lo.run_commands {
		if program, ok := command_program(text); ok {
			if in_terminal(program, lo) { return fmt.tprintf("term:%s", text) }
			return fmt.tprintf("run:%s", text)
		}
	}
	// Nothing for it: offer what can be done with it.
	if web || lo.file_search {
		message(s, fmt.tprintf(tr(s, "Nada encontrado para “%s”.", "Nothing found for “%s”."), markup_escape(text)))
		if web {
			write_entry(s, {label = fmt.tprintf(tr(s, "Pesquisar “%s” na web", "Search the web for “%s”"), text), info = fmt.tprintf("web:%s", text),
			                glyph = GL_WORLD, icon = "web-browser"})
		}
		if lo.file_search {
			write_entry(s, {label = fmt.tprintf(tr(s, "Procurar arquivos com “%s”", "Find files named “%s”"), text), info = fmt.tprintf("files:%s", text),
			                glyph = GL_SEARCH, icon = "system-search"})
		}
		write_entry(s, {label = fmt.tprintf(tr(s, "Executar “%s” no terminal", "Run “%s” in the terminal"), text), info = fmt.tprintf("term:%s", text),
		                glyph = GL_TERMINAL, icon = "utilities-terminal"})
		write_entry(s, {label = tr(s, "Voltar", "Back"), info = "back", glyph = GL_BACK, icon = "go-previous"})
		return ""
	}
	list_all(s, fmt.tprintf(tr(s, "Nada encontrado para “%s”.", "Nothing found for “%s”."), markup_escape(text)))
	return ""
}

@(private="file")
result_list :: proc(s: ^Script, expr: string, v: f64) {
	comma := s.lang != .English
	result := format_number(v, comma)
	message(s, markup_escape(fmt.tprintf("%s = %s", expr, result)))
	write_entry(s, {label = result, info = fmt.tprintf("copy:%s", result), glyph = GL_CALC, icon = "accessories-calculator",
	                display = fmt.tprintf("%s   (%s)", result, tr(s, "Enter copia", "Enter copies"))})
	if comma && result != format_number(v, false) {
		plain := format_number(v, false)
		write_entry(s, {label = plain, info = fmt.tprintf("copy:%s", plain), glyph = GL_CALC, icon = "accessories-calculator"})
	}
	write_entry(s, {label = tr(s, "Voltar", "Back"), info = "back", glyph = GL_BACK, icon = "go-previous"})
}

// An address to open: with a scheme, "www.…", or a name ending in a known domain.
@(private="file")
address :: proc(text: string) -> (string, bool) {
	if strings.contains_any(text, " \t") { return "", false }
	for scheme in ([]string{"http://", "https://", "ftp://", "file://", "mailto:"}) {
		if strings.has_prefix(strings.to_lower(text, context.temp_allocator), scheme) { return text, true }
	}
	if strings.has_prefix(text, "www.") { return fmt.tprintf("https://%s", text), true }
	host := text
	if slash := strings.index_byte(host, '/'); slash >= 0 { host = host[:slash] }
	if colon := strings.index_byte(host, ':'); colon >= 0 { host = host[:colon] }
	dot := strings.last_index_byte(host, '.')
	if dot <= 0 || dot == len(host) - 1 { return "", false }
	for ch in host {
		if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-' || ch == '.') { return "", false }
	}
	tld := strings.to_lower(host[dot + 1:], context.temp_allocator)
	for t in TLDS { if t == tld { return fmt.tprintf("https://%s", text), true } }
	return "", false
}

// The program a typed command runs, when it is one ("nvim notes.txt" → nvim).
@(private="file")
command_program :: proc(text: string) -> (string, bool) {
	words := strings.fields(text, context.temp_allocator)
	if len(words) == 0 { return "", false }
	first := words[0]
	if strings.index_byte(first, '/') >= 0 {
		p := expand_home(first)
		if os.is_file(p) && is_executable(p) { return os.base(p), true }
		return "", false
	}
	if path, found := desktop.find_executable(first); found && is_executable(path) { return first, true }
	return "", false
}

@(private="file")
is_executable :: proc(path: string) -> bool {
	fi, err := os.stat(path, context.temp_allocator)
	return err == nil && fi.type == .Regular && .Execute_User in fi.mode
}

@(private="file")
in_terminal :: proc(program: string, lo: ^config.Launcher_Options) -> bool {
	for p in TERMINAL_PROGRAMS { if p == program { return true } }
	for p in lo.terminal_commands { if p == program { return true } }
	return false
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------
@(private="file")
list_files :: proc(s: ^Script, query: string) {
	folder := expand_home(s.lo.files_folder)
	if !os.is_directory(folder) { folder = home_dir() }
	found := find_files(query, folder)
	where_ := pretty_path(folder)
	if len(found) == 0 {
		message(s, markup_escape(fmt.tprintf(tr(s, "Nenhum arquivo com “%s” em %s.", "No file named “%s” in %s."), query, where_)))
	} else {
		message(s, markup_escape(fmt.tprintf(tr(s, "Arquivos com “%s” em %s", "Files named “%s” in %s"), query, where_)))
		strings.write_string(&s.out, "\x00markup-rows\x1ftrue\n")
	}
	for path in found {
		dir := pretty_path(os.dir(path))
		name := os.base(path)
		is_dir := os.is_directory(path)
		write_entry(s, {label = fmt.tprintf("%s %s", name, dir), info = fmt.tprintf("open:%s", path), icon = is_dir ? "folder" : file_icon(name),
		                display = fmt.tprintf("%s  <span alpha=\"55%%\" size=\"small\">%s</span>", markup_escape(name), markup_escape(dir))})
	}
	write_entry(s, {label = fmt.tprintf(tr(s, "Abrir %s", "Open %s"), where_), info = fmt.tprintf("open:%s", folder), glyph = GL_FOLDER, icon = "folder",
	                display = markup_escape(fmt.tprintf(tr(s, "Abrir %s", "Open %s"), where_))})
	write_entry(s, {label = tr(s, "Voltar", "Back"), info = "back", glyph = GL_BACK, icon = "go-previous", display = markup_escape(tr(s, "Voltar", "Back"))})
}

// Files and folders whose name has `query` in it, under `folder` (hidden ones
// and caches left out): fd when it is installed, else locate, else find.
@(private="file")
find_files :: proc(query, folder: string) -> []string {
	argv: []string
	switch {
	case have("fd") || have("fdfind"): // Debian calls it fdfind
		argv = {have("fd") ? "fd" : "fdfind", "--absolute-path", "--ignore-case", "--fixed-strings", "--max-results", fmt.tprintf("%d", FILE_RESULTS), "--", query, folder}
	case have("plocate") || have("locate"):
		argv = {have("plocate") ? "plocate" : "locate", "--ignore-case", "--limit", "400", "--", query}
	case:
		argv = {"timeout", "4", "find", folder, "-xdev", "(", "-name", ".*", "-o", "-name", "node_modules", ")", "-prune", "-o",
		        "-iname", fmt.tprintf("*%s*", query), "-print"}
	}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = argv}, context.temp_allocator)
	_ = state
	if err != nil { return nil }
	out := make([dynamic]string, context.temp_allocator)
	base := strings.trim_right(folder, "/")
	for line in strings.split_lines(string(stdout), context.temp_allocator) {
		p := strings.trim_right(line, "/")
		if p == "" || !strings.has_prefix(p, base) { continue }
		if strings.contains(p[len(base):], "/.") { continue } // hidden (locate)
		append(&out, p)
		if len(out) >= FILE_RESULTS { break }
	}
	return out[:]
}

@(private="file")
have :: proc(program: string) -> bool {
	_, found := find_in_path(program)
	return found
}

// ~/Documents/notes for /home/me/Documents/notes.
@(private="file")
pretty_path :: proc(path: string) -> string {
	home := home_dir()
	if path == home { return "~" }
	if strings.has_prefix(path, home) && len(path) > len(home) && path[len(home)] == '/' { return fmt.tprintf("~%s", path[len(home):]) }
	return path
}

@(private="file")
markup_escape :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	out, _ = strings.replace_all(out, "<", "&lt;", context.temp_allocator)
	out, _ = strings.replace_all(out, ">", "&gt;", context.temp_allocator)
	return out
}

// An icon theme name for a file, by its extension.
@(private="file")
file_icon :: proc(name: string) -> string {
	dot := strings.last_index_byte(name, '.')
	if dot < 0 { return "text-x-generic" }
	switch strings.to_lower(name[dot + 1:], context.temp_allocator) {
	case "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "avif", "heic": return "image-x-generic"
	case "mp4", "mkv", "webm", "avi", "mov", "m4v": return "video-x-generic"
	case "mp3", "flac", "ogg", "opus", "wav", "m4a", "aac": return "audio-x-generic"
	case "pdf": return "application-pdf"
	case "zip", "tar", "gz", "xz", "zst", "bz2", "7z", "rar", "tgz": return "package-x-generic"
	case "odt", "doc", "docx", "rtf": return "x-office-document"
	case "ods", "xls", "xlsx", "csv": return "x-office-spreadsheet"
	case "odp", "ppt", "pptx": return "x-office-presentation"
	case "sh", "py", "odin", "c", "h", "cpp", "rs", "go", "js", "ts", "lua", "rb": return "text-x-script"
	case "html", "htm": return "text-html"
	}
	return "text-x-generic"
}

// ---------------------------------------------------------------------------
// What is used most: $XDG_CACHE_HOME/milk/launcher/history, one line per
// entry ("count<TAB>last use<TAB>info"); the score fades over a few weeks.
// ---------------------------------------------------------------------------
@(private="file")
history_file :: proc() -> string {
	return join({launcher_cache_dir(), "history"})
}

@(private="file")
History_Line :: struct { count: int, last: i64, info: string }

@(private="file")
history_read :: proc() -> [dynamic]History_Line {
	out := make([dynamic]History_Line, context.temp_allocator)
	data, err := os.read_entire_file(history_file(), context.temp_allocator)
	if err != nil { return out }
	for line in strings.split_lines(string(data), context.temp_allocator) {
		f := strings.split_n(line, "\t", 3, context.temp_allocator)
		if len(f) != 3 { continue }
		count, ok1 := strconv.parse_int(f[0], 10)
		last, ok2 := strconv.parse_i64(f[1], 10)
		if !ok1 || !ok2 || f[2] == "" { continue }
		append(&out, History_Line{count, last, f[2]})
	}
	return out
}

@(private="file")
history_load :: proc() -> map[string]f64 {
	out := make(map[string]f64, context.temp_allocator)
	now := time.time_to_unix(time.now())
	for h in history_read() {
		days := f64(max(now - h.last, 0)) / 86400
		out[h.info] = f64(h.count) / (1 + days / 14)
	}
	return out
}

// One more use of `info` (results of a search are not kept).
history_add :: proc(info: string) {
	for skip in ([]string{"copy:", "open:", "web:", "run:", "term:", "files:", "back"}) {
		if strings.has_prefix(info, skip) { return }
	}
	lines := history_read()
	now := time.time_to_unix(time.now())
	found := false
	for &h in lines {
		if h.info == info {
			h.count += 1
			h.last = now
			found = true
		}
	}
	if !found { append(&lines, History_Line{1, now, info}) }
	// The 300 most recent are kept.
	slice.sort_by(lines[:], proc(a, b: History_Line) -> bool { return a.last > b.last })
	b := strings.builder_make(context.temp_allocator)
	for h, i in lines {
		if i >= 300 { break }
		fmt.sbprintf(&b, "%d\t%d\t%s\n", h.count, h.last, h.info)
	}
	dir := launcher_cache_dir()
	if !os.is_directory(dir) { os.make_directory_all(dir) }
	path := history_file()
	tmp := fmt.tprintf("%s.%d.tmp", path, os.get_pid())
	if os.write_entire_file(tmp, transmute([]u8)strings.to_string(b)) == nil { os.rename(tmp, path) }
}
