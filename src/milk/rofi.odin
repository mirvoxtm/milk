// rofi follows the milk theme: on every start and reload milk writes a rofi
// theme generated from the current colours (appearance preset or custom
// bar.theme), font and language to $XDG_CACHE_HOME/milk/rofi.rasi and exports
// its path as $MILK_ROFI_THEME, which the default launcher command uses:
//     rofi -show drun -theme "$MILK_ROFI_THEME"
package milk

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import config "../config"

rofi_theme_path :: proc() -> string {
	cache, found := os.lookup_env("XDG_CACHE_HOME", context.temp_allocator)
	if !found || cache == "" { cache = join({home_dir(), ".cache"}) }
	return join({cache, "milk", "rofi.rasi"})
}

write_rofi_theme :: proc(cfg: ^config.Config) {
	path := rofi_theme_path()
	dir := join({path, ".."})
	if !os.is_directory(dir) { os.make_directory_all(dir) }
	t := &cfg.bar.theme
	lang := cfg.bar.language
	font := cfg.bar.font == "" ? "sans" : cfg.bar.font
	// rofi takes a Pango font description: "Family Size" (fontconfig ":style" suffixes dropped).
	if i := strings.index_byte(font, ':'); i >= 0 { font = font[:i] }
	// Token replacement (rasi is full of braces, which fmt would interpret).
	text := ROFI_TEMPLATE
	pairs := [][2]string{
		{"@BG@", t.background}, {"@FG@", t.foreground}, {"@MUTED@", t.muted}, {"@ACCENT@", t.accent},
		{"@ACCENT_FG@", t.accent_foreground}, {"@SURFACE@", t.surface}, {"@WARNING@", t.warning},
		{"@FONT@", fmt.tprintf("%s %d", font, max(cfg.bar.font_size * 3 / 4, 9))},
		{"@APPS@", config.tr(lang, "Aplicativos", "Apps")}, {"@RUN@", config.tr(lang, "Executar", "Run")},
		{"@WINDOWS@", config.tr(lang, "Janelas", "Windows")}, {"@SEARCH@", config.tr(lang, "Buscar…", "Search…")},
	}
	for pr in pairs { text, _ = strings.replace_all(text, pr[0], pr[1], context.temp_allocator) }
	if err := os.write_entire_file(path, text); err != nil {
		log.warnf("Could not write the rofi theme %s: %v", path, err)
		return
	}
	os.set_env("MILK_ROFI_THEME", path)
}

@(private)
ROFI_TEMPLATE :: `/* milk theme for rofi — generated from milk.json on every start and reload; edits are overwritten. */
configuration {
    show-icons: true;
    display-drun: "@APPS@";
    display-run: "@RUN@";
    display-window: "@WINDOWS@";
    drun-display-format: "{name}";
}

* {
    milk-bg: @BG@;
    milk-fg: @FG@;
    milk-muted: @MUTED@;
    milk-accent: @ACCENT@;
    milk-accent-fg: @ACCENT_FG@;
    milk-surface: @SURFACE@;
    milk-warning: @WARNING@;
    background-color: transparent;
    text-color: @milk-fg;
    font: "@FONT@";
}

window {
    /* No compositor: rofi paints a copy of the screen behind its rounded corners. */
    transparency: "screenshot";
    location: center;
    anchor: center;
    width: 560px;
    background-color: @milk-bg;
    border: 1px;
    border-color: @milk-muted;
    border-radius: 18px;
    padding: 14px;
}

mainbox {
    spacing: 10px;
    children: [ inputbar, message, listview ];
}

inputbar {
    background-color: @milk-surface;
    border-radius: 12px;
    padding: 10px 14px;
    spacing: 10px;
    children: [ prompt, entry ];
}

prompt {
    text-color: @milk-accent;
}

entry {
    placeholder: "@SEARCH@";
    placeholder-color: @milk-muted;
    cursor: text;
}

message {
    background-color: @milk-surface;
    border-radius: 10px;
    padding: 8px 12px;
}

listview {
    lines: 8;
    columns: 1;
    fixed-height: false;
    spacing: 4px;
    scrollbar: false;
}

element {
    padding: 8px 12px;
    border-radius: 10px;
    spacing: 12px;
    cursor: pointer;
}

element normal.normal, element alternate.normal, element normal.active, element alternate.active {
    background-color: transparent;
    text-color: @milk-fg;
}

element normal.urgent, element alternate.urgent {
    background-color: transparent;
    text-color: @milk-warning;
}

element selected.normal, element selected.active, element selected.urgent {
    background-color: @milk-accent;
    text-color: @milk-accent-fg;
}

element-icon {
    size: 24px;
    background-color: transparent;
}

element-text {
    background-color: transparent;
    text-color: inherit;
    vertical-align: 0.5;
}
`
