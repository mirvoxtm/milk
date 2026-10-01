// GTK and Qt applications follow milk's theme (appearance.themeApps, on by
// default). Whenever milk applies a theme (start, reload, settings changes,
// the wallpaper theme's new colours) it writes, from the colours in milk.json:
//
// * GTK 3 and 4: $XDG_CONFIG_HOME/gtk-{3,4}.0/milk-colors.css, the named
//   colours of libadwaita and adw-gtk3 (window_bg_color, accent_bg_color,
//   headerbar_bg_color...). GTK 4 apps, libadwaita ones included, load it
//   through one marked line of gtk-4.0/gtk.css,
//       @import 'milk-colors.css'; /* milk */
//   when they start (GTK reads gtk.css once per process).
// * GTK 3, live: with adw-gtk3 installed and milk as the XSETTINGS manager
//   (xsettings.odin) the GTK theme is "milk", generated in
//   $XDG_DATA_HOME/themes: adw-gtk3 (or adw-gtk3-dark) plus milk-colors.css.
//   GTK reads a theme again only when Net/ThemeName changes, so the same
//   theme also exists as "milk-alt" and every change of colours switches to
//   the other name: running apps restyle at once. The colours are then kept
//   out of gtk-3.0/gtk.css (read once, at a higher priority, they would hide
//   the new ones). Otherwise (another XSETTINGS manager, no adw-gtk3)
//   gtk-3.0/gtk.css gets the marked line as well and apps take the colours
//   when they start (in full with adw-gtk3 as their theme).
// * Light or dark: gtk-application-prefer-dark-theme in gtk-3.0/settings.ini
//   and, where gsettings exists, org.gnome.desktop.interface color-scheme
//   (followed live by libadwaita apps).
// * Qt: a qt5ct / qt6ct colour scheme, $XDG_CONFIG_HOME/qt{5,6}ct/colors/milk.conf,
//   chosen in qt5ct.conf / qt6ct.conf ([Appearance] color_scheme_path and
//   custom_palette=true), for each of qt5ct and qt6ct that is installed. Qt
//   apps use it with QT_QPA_PLATFORMTHEME=qt5ct (contrib/milk-session sets
//   it). qt5ct/qt6ct watch their folder, so the .conf is written again when
//   the colours change: running apps reload the palette (after ~3 s).
//
// Files are written atomically and only when their content changes; the
// rest of gtk.css, settings.ini and the qt*ct.conf files is kept. Nothing is
// written while the option is off: turning it off removes milk's lines and
// files (settings.ini and the GNOME colour scheme keep their last value) and
// gives up the XSETTINGS selection.
package milk

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

GTK_THEMES      :: [2]string{"milk", "milk-alt"}
GTK_IMPORT_LINE :: "@import 'milk-colors.css'; /* milk */"
@(private="file") THEME_MARKER :: "X-Milk-Generated=true" // in the generated themes' index.theme
@(private="file") QT_FAMILIES  :: [2]string{"qt5ct", "qt6ct"}

App_Theme :: struct {
	xs:         XSettings,
	alt:        bool, // "milk-alt" is the published GTK 3 theme
	published:  bool, // Net/ThemeName was published by this instance
	scheme:     int,  // colour scheme last handed to gsettings: 0 none yet, 1 default, 2 prefer-dark
	children:   [dynamic]os.Process, // gsettings runs not reaped yet
	hinted:     bool, // the adw-gtk3 hint was logged
	announced:  bool,
}

// Apply appearance.themeApps for the current configuration (see the header).
apptheme_apply :: proc(r: ^Runner) {
	a := &r.apps
	cfg := r.cfg
	if !cfg.appearance.theme_apps {
		if a.xs.win != 0 { xsettings_stop(&a.xs, r.c) }
		a.published = false
		a.announced = false
		apptheme_remove()
		return
	}
	colors := app_colors(cfg)
	ch := config_home()
	gtk3_changed := write_if_changed(join({ch, "gtk-3.0", "milk-colors.css"}), gtk_colors_css(colors, false))
	write_if_changed(join({ch, "gtk-4.0", "milk-colors.css"}), gtk_colors_css(colors, true))
	gtk_css_import(join({ch, "gtk-4.0", "gtk.css"}), true)

	owner := xsettings_start(&a.xs, r.c)
	base, have_adw := find_adw_gtk3()
	if !have_adw && !a.hinted {
		a.hinted = true
		log.info("GTK 3 apps take milk's colours in full with the adw-gtk3 theme (package adw-gtk-theme / adw-gtk3-theme)")
	}
	managed := owner && have_adw
	if managed {
		changed := false
		for name in GTK_THEMES {
			wrote, ok := write_gtk_theme(name, base, colors.dark)
			if !ok { managed = false }
			if wrote { changed = true }
		}
		if managed && a.published && (gtk3_changed || changed) { a.alt = !a.alt }
	}
	if !managed {
		for name in GTK_THEMES { remove_gtk_theme(name) }
	}
	// The colours at app start (gtk.css) only where they cannot come live from the theme.
	gtk_css_import(join({ch, "gtk-3.0", "gtk.css"}), !managed)
	if owner {
		settings := make([dynamic][2]string, context.temp_allocator)
		if managed { append(&settings, [2]string{"Net/ThemeName", a.alt ? GTK_THEMES[1] : GTK_THEMES[0]}) }
		if icons := cfg.linux.shortcuts.icon_theme; icons != "" { append(&settings, [2]string{"Net/IconThemeName", icons}) }
		xsettings_set(&a.xs, r.c, settings[:])
		a.published = managed
	}
	ini_path := join({ch, "gtk-3.0", "settings.ini"})
	ini := read_text(ini_path)
	write_if_changed(ini_path, ini_set(ini, "Settings", "gtk-application-prefer-dark-theme", colors.dark ? "true" : "false"))
	gnome_color_scheme(a, colors.dark)
	qt_apply(colors)
	if !a.announced {
		a.announced = true
		log.infof("GTK and Qt apps follow milk's colours (GTK 3 %s)", managed ? "live, theme \"milk\"" : "at app start")
	}
}

// Another XSETTINGS manager took the selection over: GTK 3 falls back to
// gtk.css. True when the event belonged to the XSETTINGS window.
apptheme_event :: proc(r: ^Runner, ev: ^xlib.XEvent) -> bool {
	lost, ours := xsettings_event(&r.apps.xs, r.c, ev)
	if lost { apptheme_apply(r) }
	return ours
}

// Reap finished gsettings runs (never blocks).
apptheme_reap :: proc(r: ^Runner) {
	a := &r.apps
	for i := len(a.children) - 1; i >= 0; i -= 1 {
		state, err := os.process_wait(a.children[i], 0)
		if err == nil && !state.exited { continue }
		unordered_remove(&a.children, i)
	}
}

// milk stops: give up XSETTINGS (GTK apps fall back to their settings.ini).
apptheme_stop :: proc(r: ^Runner) {
	xsettings_stop(&r.apps.xs, r.c)
	apptheme_reap(r)
	delete(r.apps.children)
	r.apps.children = nil
}

// Everything milk wrote for the option (the option was turned off).
apptheme_remove :: proc() {
	ch := config_home()
	for v in ([]string{"gtk-3.0", "gtk-4.0"}) {
		gtk_css_import(join({ch, v, "gtk.css"}), false)
		remove_file(join({ch, v, "milk-colors.css"}))
	}
	for name in GTK_THEMES { remove_gtk_theme(name) }
	for family in QT_FAMILIES {
		dir := join({ch, family})
		scheme := join({dir, "colors", "milk.conf"})
		conf := join({dir, fmt.tprintf("%s.conf", family)})
		if text, found := read_text_found(conf); found && ini_get(text, "Appearance", "color_scheme_path") == scheme {
			text = ini_set(text, "Appearance", "color_scheme_path", "", remove = true)
			text = ini_set(text, "Appearance", "custom_palette", "false")
			write_if_changed(conf, text)
		}
		remove_file(scheme)
	}
}

// ---------------------------------------------------------------------------
// Colours
// ---------------------------------------------------------------------------
@(private="file")
App_Colors :: struct {
	dark:                                         bool,
	bg, fg, muted, accent, accent_fg, surface:    tx.Color,
	warning, border:                              tx.Color,
	view, card, popover, dialog:                  tx.Color,
	headerbar, headerbar_backdrop:                tx.Color,
	sidebar, sidebar_backdrop:                    tx.Color,
	destructive:                                  tx.Color,
}

@(private="file")
app_colors :: proc(cfg: ^config.Config) -> App_Colors {
	_, dark := config.current_theme_colors(cfg)
	t := &cfg.bar.theme
	base := config.theme_preset("milk", dark ? "dark" : "light")
	hex :: proc(s, fallback: string) -> tx.Color { return tx.color_from_hex(s, tx.color_from_hex(fallback)) }
	c: App_Colors
	c.dark = dark
	c.bg = hex(t.background, base.bar.background)
	c.fg = hex(t.foreground, base.bar.foreground)
	c.muted = hex(t.muted, base.bar.muted)
	c.accent = hex(t.accent, base.bar.accent)
	c.accent_fg = hex(t.accent_foreground, base.bar.accent_foreground)
	c.surface = hex(t.surface, base.bar.surface)
	c.warning = hex(t.warning, base.bar.warning)
	c.border = hex(cfg.wm.border_color, base.border_color)
	white, black := tx.rgb(255, 255, 255), tx.rgb(0, 0, 0)
	// milk's surface is darker than the background in light themes and
	// lighter in dark ones; views and cards sit like libadwaita's (lighter
	// in light themes, deeper or raised in dark ones). Title bars as milk's own.
	if dark {
		c.view = tx.color_mix(c.bg, black, 0.18)
		c.card = tx.color_mix(c.bg, c.surface, 0.85)
		c.popover = c.surface
		c.dialog = c.surface
		c.destructive = tx.color_mix(c.warning, black, 0.22)
	} else {
		c.view = tx.color_mix(c.bg, white, 0.6)
		c.card = tx.color_mix(c.bg, white, 0.5)
		c.popover = tx.color_mix(c.bg, white, 0.6)
		c.dialog = c.bg
		c.destructive = c.warning
	}
	c.headerbar = c.bg
	c.headerbar_backdrop = tx.color_mix(c.bg, c.surface, 0.7)
	c.sidebar = tx.color_mix(c.bg, c.surface, 0.6)
	c.sidebar_backdrop = tx.color_mix(c.bg, c.surface, 0.35)
	return c
}

@(private="file")
css_hex :: proc(c: tx.Color) -> string { return fmt.tprintf("#%02x%02x%02x", c.r, c.g, c.b) }

// Text on `c`: white, or near-black when that reads better.
@(private="file")
text_on :: proc(c: tx.Color) -> string {
	lin :: proc(v: u8) -> f32 {
		x := f32(v) / 255
		return x <= 0.04045 ? x / 12.92 : math.pow((x + 0.055) / 1.055, 2.4)
	}
	l := 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
	// Contrast against white (1.05 / (l + 0.05)) vs against black ((l + 0.05) / 0.05).
	return 1.05 / (l + 0.05) >= (l + 0.05) / 0.05 ? "#ffffff" : "rgba(0, 0, 0, 0.8)"
}

// milk-colors.css: libadwaita's named colours (GTK 4) and adw-gtk3's, with
// GTK 3's theme_* names for apps that read those.
@(private="file")
gtk_colors_css :: proc(c: App_Colors, gtk4: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "/* milk colours for GTK %s (%s): generated by milk from milk.json\n", gtk4 ? "4" : "3", c.dark ? "dark" : "light")
	strings.write_string(&b, " * (appearance.themeApps); edits are overwritten. Loaded by the \"milk\" theme\n")
	strings.write_string(&b, " * or by the marked @import line of gtk.css. */\n\n")
	def :: proc(b: ^strings.Builder, name, value: string) { fmt.sbprintf(b, "@define-color %s %s;\n", name, value) }
	shade := c.dark ? "rgba(0, 0, 0, 0.36)" : "rgba(0, 0, 0, 0.07)"
	def(&b, "accent_color", css_hex(c.accent))
	def(&b, "accent_bg_color", css_hex(c.accent))
	def(&b, "accent_fg_color", css_hex(c.accent_fg))
	def(&b, "destructive_color", css_hex(c.warning))
	def(&b, "destructive_bg_color", css_hex(c.destructive))
	def(&b, "destructive_fg_color", text_on(c.destructive))
	def(&b, "error_color", css_hex(c.warning))
	def(&b, "error_bg_color", css_hex(c.destructive))
	def(&b, "error_fg_color", text_on(c.destructive))
	// milk has no green or yellow of its own: libadwaita's, for the variant.
	if c.dark {
		def(&b, "success_color", "#78e9ab")
		def(&b, "success_bg_color", "#26a269")
		def(&b, "warning_color", "#ffc252")
		def(&b, "warning_bg_color", "#cd9309")
	} else {
		def(&b, "success_color", "#1b8553")
		def(&b, "success_bg_color", "#2ec27e")
		def(&b, "warning_color", "#9c6e03")
		def(&b, "warning_bg_color", "#e5a50a")
	}
	def(&b, "success_fg_color", "#ffffff")
	def(&b, "warning_fg_color", "rgba(0, 0, 0, 0.8)")
	strings.write_byte(&b, '\n')
	def(&b, "window_bg_color", css_hex(c.bg))
	def(&b, "window_fg_color", css_hex(c.fg))
	def(&b, "view_bg_color", css_hex(c.view))
	def(&b, "view_fg_color", css_hex(c.fg))
	def(&b, "headerbar_bg_color", css_hex(c.headerbar))
	def(&b, "headerbar_fg_color", css_hex(c.fg))
	def(&b, "headerbar_border_color", css_hex(c.fg))
	def(&b, "headerbar_backdrop_color", css_hex(c.headerbar_backdrop))
	def(&b, "headerbar_shade_color", shade)
	def(&b, "headerbar_darker_shade_color", c.dark ? "rgba(0, 0, 0, 0.9)" : "rgba(0, 0, 0, 0.12)")
	def(&b, "sidebar_bg_color", css_hex(c.sidebar))
	def(&b, "sidebar_fg_color", css_hex(c.fg))
	def(&b, "sidebar_backdrop_color", css_hex(c.sidebar_backdrop))
	def(&b, "sidebar_border_color", shade)
	def(&b, "sidebar_shade_color", shade)
	def(&b, "secondary_sidebar_bg_color", css_hex(tx.color_mix(c.sidebar, c.bg, 0.5)))
	def(&b, "secondary_sidebar_fg_color", css_hex(c.fg))
	def(&b, "secondary_sidebar_backdrop_color", css_hex(c.sidebar_backdrop))
	def(&b, "secondary_sidebar_border_color", shade)
	def(&b, "secondary_sidebar_shade_color", shade)
	def(&b, "card_bg_color", css_hex(c.card))
	def(&b, "card_fg_color", css_hex(c.fg))
	def(&b, "card_shade_color", shade)
	def(&b, "thumbnail_bg_color", css_hex(c.card))
	def(&b, "thumbnail_fg_color", css_hex(c.fg))
	def(&b, "dialog_bg_color", css_hex(c.dialog))
	def(&b, "dialog_fg_color", css_hex(c.fg))
	def(&b, "popover_bg_color", css_hex(c.popover))
	def(&b, "popover_fg_color", css_hex(c.fg))
	def(&b, "popover_shade_color", shade)
	def(&b, "shade_color", shade)
	def(&b, "scrollbar_outline_color", c.dark ? "rgba(0, 0, 0, 0.5)" : "#ffffff")
	if !gtk4 {
		// GTK 3's names (adw-gtk3 derives them from the ones above; other
		// themes and apps' own CSS read them directly).
		strings.write_byte(&b, '\n')
		def(&b, "theme_bg_color", css_hex(c.bg))
		def(&b, "theme_fg_color", css_hex(c.fg))
		def(&b, "theme_base_color", css_hex(c.view))
		def(&b, "theme_text_color", css_hex(c.fg))
		def(&b, "theme_selected_bg_color", css_hex(c.accent))
		def(&b, "theme_selected_fg_color", css_hex(c.accent_fg))
		def(&b, "theme_unfocused_bg_color", css_hex(c.bg))
		def(&b, "theme_unfocused_fg_color", css_hex(c.fg))
		def(&b, "theme_unfocused_base_color", css_hex(c.view))
		def(&b, "theme_unfocused_text_color", css_hex(c.fg))
		def(&b, "theme_unfocused_selected_bg_color", css_hex(c.accent))
		def(&b, "theme_unfocused_selected_fg_color", css_hex(c.accent_fg))
		def(&b, "insensitive_fg_color", css_hex(tx.color_mix(c.fg, c.bg, 0.5)))
		def(&b, "borders", css_hex(tx.color_mix(c.bg, c.fg, 0.15)))
		def(&b, "unfocused_borders", css_hex(tx.color_mix(c.bg, c.fg, 0.12)))
		// adw-gtk3 writes white on the accent colour; milk's dark themes have light accents.
		strings.write_string(&b, "\nbutton.suggested-action,\nbutton.suggested-action:hover,\nbutton.suggested-action:active,\nbutton.suggested-action:checked {\n  color: @accent_fg_color;\n}\n")
	}
	return strings.to_string(b)
}

// A qt5ct / qt6ct colour scheme: the 21 colour roles of QPalette (WindowText
// to PlaceholderText, in enum order) for the active, inactive and disabled groups.
@(private="file")
qt_scheme :: proc(c: App_Colors) -> string {
	white, black := tx.rgb(255, 255, 255), tx.rgb(0, 0, 0)
	button := c.dark ? tx.color_mix(c.bg, c.surface, 0.8) : tx.color_mix(c.bg, c.surface, 0.5)
	light := tx.color_mix(button, white, c.dark ? 0.12 : 0.6)
	argb :: proc(col: tx.Color, alpha: u8 = 255) -> string { return fmt.tprintf("#%02x%02x%02x%02x", alpha, col.r, col.g, col.b) }
	roles :: proc(c: App_Colors, button, light: tx.Color, text, highlight, highlighted_text: tx.Color, white, black: tx.Color) -> [21]string {
		return {
			argb(text),                                              // WindowText
			argb(button),                                            // Button
			argb(light),                                             // Light
			argb(tx.color_mix(button, light, 0.5)),                  // Midlight
			argb(tx.color_mix(button, black, c.dark ? 0.45 : 0.35)), // Dark
			argb(tx.color_mix(button, black, c.dark ? 0.25 : 0.18)), // Mid
			argb(text),                                              // Text
			argb(white),                                             // BrightText
			argb(text),                                              // ButtonText
			argb(c.view),                                            // Base
			argb(c.bg),                                              // Window
			argb(black),                                             // Shadow
			argb(highlight),                                         // Highlight
			argb(highlighted_text),                                  // HighlightedText
			argb(c.accent),                                          // Link
			argb(tx.color_mix(c.accent, c.fg, 0.4)),                 // LinkVisited
			argb(tx.color_mix(c.view, c.surface, 0.5)),              // AlternateBase
			argb(black),                                             // NoRole
			argb(c.popover),                                         // ToolTipBase
			argb(c.fg),                                              // ToolTipText
			argb(c.muted),                                           // PlaceholderText
		}
	}
	active := roles(c, button, light, c.fg, c.accent, c.accent_fg, white, black)
	disabled := roles(c, button, light, tx.color_mix(c.fg, c.bg, 0.5), tx.color_mix(c.accent, c.bg, 0.5), tx.color_mix(c.accent_fg, c.bg, 0.3), white, black)
	list :: proc(r: [21]string) -> string {
		r := r
		return strings.join(r[:], ", ", context.temp_allocator)
	}
	return fmt.tprintf("; milk colours for Qt (%s): generated by milk from milk.json (appearance.themeApps);\n; edits are overwritten.\n[ColorScheme]\nactive_colors=%s\ndisabled_colors=%s\ninactive_colors=%s\n",
	                   c.dark ? "dark" : "light", list(active), list(disabled), list(active))
}

// ---------------------------------------------------------------------------
// GTK
// ---------------------------------------------------------------------------
@(private="file")
Adw_Base :: struct {
	light3, dark3, light4, dark4: string, // CSS files of adw-gtk3 ("" = missing)
}

// adw-gtk3 (and adw-gtk3-dark) where GTK looks for themes.
@(private="file")
find_adw_gtk3 :: proc() -> (base: Adw_Base, found: bool) {
	dirs := make([dynamic]string, context.temp_allocator)
	append(&dirs, join({data_home(), "themes"}), join({home_dir(), ".themes"}))
	data_dirs := os.get_env("XDG_DATA_DIRS", context.temp_allocator)
	if data_dirs == "" { data_dirs = "/usr/local/share:/usr/share" }
	for d in strings.split(data_dirs, ":", context.temp_allocator) {
		if d != "" { append(&dirs, join({d, "themes"})) }
	}
	file :: proc(parts: []string) -> string {
		p := join(parts)
		return os.is_file(p) ? p : ""
	}
	for d in dirs {
		light3 := file({d, "adw-gtk3", "gtk-3.0", "gtk.css"})
		if light3 == "" { continue }
		base.light3 = light3
		base.dark3 = file({d, "adw-gtk3-dark", "gtk-3.0", "gtk.css"})
		if base.dark3 == "" { base.dark3 = file({d, "adw-gtk3", "gtk-3.0", "gtk-dark.css"}) }
		if base.dark3 == "" { base.dark3 = light3 }
		base.light4 = file({d, "adw-gtk3", "gtk-4.0", "gtk.css"})
		base.dark4 = file({d, "adw-gtk3-dark", "gtk-4.0", "gtk.css"})
		if base.dark4 == "" { base.dark4 = file({d, "adw-gtk3", "gtk-4.0", "gtk-dark.css"}) }
		if base.dark4 == "" { base.dark4 = base.light4 }
		return base, true
	}
	return {}, false
}

// file:// URL of an absolute path (for @import).
@(private="file")
file_url :: proc(path: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "file://")
	for ch in transmute([]u8)path {
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '/', '-', '.', '_', '~':
			strings.write_byte(&b, ch)
		case:
			fmt.sbprintf(&b, "%%%02X", ch)
		}
	}
	return strings.to_string(b)
}

// One of the generated themes: adw-gtk3 in milk's variant plus the colours.
// Its gtk-dark.css is the same (milk has one variant at a time, so an app
// asking for the dark variant keeps milk's look). Returns (written, usable):
// a theme of that name made by someone else is left alone (not usable).
@(private="file")
write_gtk_theme :: proc(name: string, base: Adw_Base, dark: bool) -> (wrote: bool, ok: bool) {
	dir := join({data_home(), "themes", name})
	index := join({dir, "index.theme"})
	if os.exists(dir) && !strings.contains(read_text(index), THEME_MARKER) {
		log.warnf("%s is not milk's; GTK 3 apps take milk's colours at start only", dir)
		return false, false
	}
	colors := file_url(join({config_home(), "gtk-3.0", "milk-colors.css"}))
	header :: "/* milk: adw-gtk3 in milk's colours. Generated by milk (appearance.themeApps); edits are overwritten. */\n"
	css3 := fmt.tprintf("%s@import url(\"%s\");\n@import url(\"%s\");\n", header, file_url(dark ? base.dark3 : base.light3), colors)
	wrote = write_if_changed(index, fmt.tprintf(
		"[Desktop Entry]\nType=X-GNOME-Metatheme\nName=%s\nComment=adw-gtk3 in milk's colours (generated by milk; edits are overwritten)\nEncoding=UTF-8\n%s\n",
		name, THEME_MARKER)) || wrote
	wrote = write_if_changed(join({dir, "gtk-3.0", "gtk.css"}), css3) || wrote
	wrote = write_if_changed(join({dir, "gtk-3.0", "gtk-dark.css"}), css3) || wrote
	// GTK 4 apps without libadwaita: adw-gtk3's GTK 4 look (their colours come from gtk-4.0/gtk.css).
	if css4 := dark ? base.dark4 : base.light4; css4 != "" {
		text := fmt.tprintf("%s@import url(\"%s\");\n", header, file_url(css4))
		wrote = write_if_changed(join({dir, "gtk-4.0", "gtk.css"}), text) || wrote
		wrote = write_if_changed(join({dir, "gtk-4.0", "gtk-dark.css"}), text) || wrote
	}
	return wrote, true
}

@(private="file")
remove_gtk_theme :: proc(name: string) {
	dir := join({data_home(), "themes", name})
	if !os.exists(dir) || !strings.contains(read_text(join({dir, "index.theme"})), THEME_MARKER) { return }
	for f in ([]string{"gtk-3.0/gtk.css", "gtk-3.0/gtk-dark.css", "gtk-4.0/gtk.css", "gtk-4.0/gtk-dark.css", "index.theme"}) {
		remove_file(join({dir, f}))
	}
	// Folders only when empty (os.remove does not remove anything else).
	os.remove(join({dir, "gtk-3.0"}))
	os.remove(join({dir, "gtk-4.0"}))
	os.remove(dir)
}

// Add (want) or remove the marked @import line of a gtk.css, keeping the
// rest. The line goes first (@import must precede the rules; only @charset
// may come before it), so the user's own definitions further down still win.
@(private="file")
gtk_css_import :: proc(path: string, want: bool) {
	text, exists := read_text_found(path)
	if !want && !exists { return }
	lines := strings.split(text, "\n", context.temp_allocator)
	kept := make([dynamic]string, context.temp_allocator)
	for l in lines {
		t := strings.trim_space(l)
		if t == GTK_IMPORT_LINE || (strings.contains(t, "milk-colors.css") && strings.has_suffix(t, "/* milk */")) { continue }
		append(&kept, l)
	}
	if want {
		at := 0
		if len(kept) > 0 && strings.has_prefix(strings.trim_space(kept[0]), "@charset") { at = 1 }
		inject_at(&kept, at, GTK_IMPORT_LINE)
		if !exists { append(&kept, "") } // a new file ends with a newline
	}
	out := strings.join(kept[:], "\n", context.temp_allocator)
	if !want && strings.trim_space(out) == "" {
		remove_file(path) // only our line was left: the file was ours
		return
	}
	write_if_changed(path, out)
}

// org.gnome.desktop.interface color-scheme for libadwaita apps, when it changes.
@(private="file")
gnome_color_scheme :: proc(a: ^App_Theme, dark: bool) {
	want := dark ? 2 : 1
	if a.scheme == want { return }
	a.scheme = want
	exe, found := find_in_path("gsettings")
	if !found { return }
	cmd := []string{exe, "set", "org.gnome.desktop.interface", "color-scheme", dark ? "prefer-dark" : "default"}
	p, err := os.process_start({command = cmd})
	if err != nil {
		log.debugf("Could not run gsettings: %v", err)
		return
	}
	append(&a.children, p)
}

// ---------------------------------------------------------------------------
// Qt
// ---------------------------------------------------------------------------
@(private="file")
qt_apply :: proc(c: App_Colors) {
	scheme_text := qt_scheme(c)
	for family in QT_FAMILIES {
		dir := join({config_home(), family})
		if _, installed := find_in_path(family); !installed && !os.is_directory(dir) { continue }
		scheme := join({dir, "colors", "milk.conf"})
		changed := write_if_changed(scheme, scheme_text)
		conf := join({dir, fmt.tprintf("%s.conf", family)})
		text := read_text(conf)
		text = ini_set(text, "Appearance", "color_scheme_path", scheme)
		text = ini_set(text, "Appearance", "custom_palette", "true")
		// Written again when only the colours changed: qt5ct/qt6ct reload on a change in their folder.
		write_if_changed(conf, text, force = changed)
	}
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------
@(private="file")
config_home :: proc() -> string {
	if v := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); v != "" { return v }
	return join({home_dir(), ".config"})
}

@(private="file")
data_home :: proc() -> string {
	if v := os.get_env("XDG_DATA_HOME", context.temp_allocator); v != "" { return v }
	return join({home_dir(), ".local", "share"})
}

@(private="file")
read_text_found :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return "", false }
	return string(data), true
}

@(private="file")
read_text :: proc(path: string) -> string {
	text, _ := read_text_found(path)
	return text
}

@(private="file")
remove_file :: proc(path: string) {
	if os.exists(path) {
		if err := os.remove(path); err != nil { log.warnf("Could not remove %s: %v", path, err) }
	}
}

// Write `text` to `path` (written aside, then moved into place) unless the
// file holds exactly that already (`force`: write anyway). True when written.
@(private="file")
write_if_changed :: proc(file, text: string, force := false) -> bool {
	if old, found := read_text_found(file); found && old == text && !force { return false }
	path := resolve_links(file) // a dotfile symlink stays one: its target is written
	dir := os.dir(path)
	if !os.is_directory(dir) {
		if err := os.make_directory_all(dir); err != nil && !os.is_directory(dir) {
			log.warnf("Could not create %s: %v", dir, err)
			return false
		}
	}
	tmp := fmt.tprintf("%s.milk-tmp", path)
	if err := os.write_entire_file(tmp, text); err != nil {
		log.warnf("Could not write %s: %v", path, err)
		os.remove(tmp)
		return false
	}
	if err := os.rename(tmp, path); err != nil {
		log.warnf("Could not write %s: %v", path, err)
		os.remove(tmp)
		return false
	}
	log.debugf("Theme for apps: wrote %s", path)
	return true
}

// The file a path leads to through symbolic links (relative targets
// resolved from the link's folder); the path itself when it is no link.
@(private="file")
resolve_links :: proc(path: string) -> string {
	p := path
	for _ in 0 ..< 16 {
		fi, err := os.lstat(p, context.temp_allocator)
		if err != nil || fi.type != .Symlink { return p }
		target, rerr := os.read_link(p, context.temp_allocator)
		if rerr != nil || target == "" { return p }
		p = os.is_absolute_path(target) ? target : join({os.dir(p), target})
	}
	return p
}

// The value of `key` in [section] of an INI text ("" when missing).
@(private="file")
ini_get :: proc(text, section, key: string) -> string {
	current := ""
	for line in strings.split(text, "\n", context.temp_allocator) {
		t := strings.trim_space(line)
		if strings.has_prefix(t, "[") && strings.has_suffix(t, "]") {
			current = t[1:len(t) - 1]
			continue
		}
		if current != section { continue }
		if eq := strings.index_byte(t, '='); eq > 0 && strings.trim_space(t[:eq]) == key {
			return strings.trim_space(t[eq + 1:])
		}
	}
	return ""
}

// `text` with key=value in [section]: the key's line replaced (or removed
// with `remove`), added at the end of the section, or the section added at
// the end. Every other line stays as it is.
@(private="file")
ini_set :: proc(text, section, key, value: string, remove := false) -> string {
	lines := strings.split(text, "\n", context.temp_allocator)
	out := make([dynamic]string, 0, len(lines) + 3, context.temp_allocator)
	entry := fmt.tprintf("%s=%s", key, value)
	current := ""
	found, has_section := false, false
	insert_at := -1 // after the last non-blank line of the section
	for line in lines {
		t := strings.trim_space(line)
		if strings.has_prefix(t, "[") && strings.has_suffix(t, "]") {
			current = t[1:len(t) - 1]
			if current == section {
				has_section = true
				insert_at = len(out) + 1
			}
			append(&out, line)
			continue
		}
		if current == section {
			if eq := strings.index_byte(t, '='); eq > 0 && strings.trim_space(t[:eq]) == key {
				if !remove && !found { append(&out, entry) }
				found = true
				continue
			}
			if t != "" { insert_at = len(out) + 1 }
		}
		append(&out, line)
	}
	if !found && !remove {
		if has_section {
			inject_at(&out, insert_at, entry)
		} else {
			// A new section at the end (after a blank line when the text has content).
			for len(out) > 0 && strings.trim_space(out[len(out) - 1]) == "" { pop(&out) }
			if len(out) > 0 { append(&out, "") }
			append(&out, fmt.tprintf("[%s]", section), entry, "")
		}
	}
	return strings.join(out[:], "\n", context.temp_allocator)
}
