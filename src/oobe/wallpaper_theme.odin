// The "Wallpaper" theme of the theme page (appearance.theme = "wallpaper"):
// the colours matugen makes from the wallpaper on screen. The running milk
// generates them (desktop/palette.odin) and publishes them in
// config.wallpaper_palette_path(); this app shows that palette on the card,
// lets the user pick matugen's scheme (appearance.matugenScheme) and, while
// the theme is selected, follows the file, so the window recolours itself a
// moment after the theme, the scheme or a wallpaper changes.
package oobe

import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import config "../config"
import tx "../tx"

// w.theme_index of the wallpaper theme.
@(private) WALLPAPER_INDEX :: -1

// How often the settings app looks at the palette file while it matters.
@(private) PALETTE_CHECK :: 0.5

@(private)
Palette_View :: struct {
	palette:  config.Wallpaper_Palette,
	loaded:   bool, // palette holds the published colours
	stamp:    i64,  // theme_stamp of the file when it was read
	check_at: f64,
	matugen:  bool, // matugen is installed
	scheme:   int,  // config.MATUGEN_SCHEMES index
}

@(private)
wallpaper_selected :: proc(w: ^Wizard) -> bool { return w.theme_index == WALLPAPER_INDEX }

@(private)
palette_view_init :: proc(w: ^Wizard) {
	pv := &w.pal
	for s, i in config.MATUGEN_SCHEMES { if s == w.cfg.appearance.matugen_scheme { pv.scheme = i } }
	pv.matugen = matugen_installed()
	palette_view_reload(w)
}

@(private)
palette_view_destroy :: proc(w: ^Wizard) {
	if w.pal.loaded { config.destroy_wallpaper_palette(&w.pal.palette) }
	w.pal.loaded = false
}

// Read the palette file again when it changed; true when it did.
@(private)
palette_view_reload :: proc(w: ^Wizard) -> bool {
	pv := &w.pal
	path := config.wallpaper_palette_path()
	stamp: i64
	if fi, err := os.stat(path, context.temp_allocator); err == nil { stamp = time.time_to_unix_nano(fi.modification_time) }
	if stamp == pv.stamp && (pv.loaded || stamp == 0) { return false }
	pv.stamp = stamp
	if pv.loaded { config.destroy_wallpaper_palette(&pv.palette) }
	pv.palette, pv.loaded = config.read_wallpaper_palette(path)
	return true
}

// The colours of the wallpaper theme in a variant: the published palette, or
// milk's until there is one.
@(private)
wallpaper_colors :: proc(w: ^Wizard, dark: bool) -> config.Theme_Colors {
	if w.pal.loaded { return dark ? w.pal.palette.dark : w.pal.palette.light }
	return config.theme_preset("milk", dark ? "dark" : "light")
}

@(private)
palette_view_tick :: proc(w: ^Wizard, now: f64) {
	pv := &w.pal
	if !wallpaper_selected(w) || now < pv.check_at { return }
	pv.check_at = now + PALETTE_CHECK
	if palette_view_reload(w) { update_theme(w) }
}

@(private)
palette_view_timeout :: proc(w: ^Wizard, now: f64) -> f64 {
	if !wallpaper_selected(w) { return -1 }
	return max(w.pal.check_at - now, 0)
}

// matugen on $PATH, or where milk's installer puts it.
@(private)
matugen_installed :: proc() -> bool {
	executable :: proc(path: string) -> bool {
		if !os.is_file(path) { return false }
		return posix.access(strings.clone_to_cstring(path, context.temp_allocator), {.X_OK}) == .OK
	}
	path_env, _ := os.lookup_env("PATH", context.temp_allocator)
	for dir in strings.split(path_env, ":", context.temp_allocator) {
		if dir != "" && executable(join_path({dir, "matugen"})) { return true }
	}
	return executable(join_path({home_dir(), ".local", "bin", "matugen"}))
}

@(private)
scheme_title :: proc(w: ^Wizard, index: int) -> string {
	switch config.MATUGEN_SCHEMES[clamp(index, 0, len(config.MATUGEN_SCHEMES) - 1)] {
	case "tonal-spot":  return tr(w, "Tonal", "Tonal")
	case "content":     return tr(w, "Conteúdo", "Content")
	case "expressive":  return tr(w, "Expressivo", "Expressive")
	case "fidelity":    return tr(w, "Fiel", "Faithful")
	case "fruit-salad": return tr(w, "Salada de frutas", "Fruit salad")
	case "monochrome":  return tr(w, "Monocromático", "Monochrome")
	case "neutral":     return tr(w, "Neutro", "Neutral")
	case "rainbow":     return tr(w, "Arco-íris", "Rainbow")
	case "vibrant":     return tr(w, "Vibrante", "Vibrant")
	}
	return ""
}

// The wallpaper card of the theme page, next to the presets.
@(private)
draw_wallpaper_card :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect, preview_h: i32) {
	th := &w.theme
	usable := w.pal.matugen
	selected := wallpaper_selected(w)
	hot := usable && hovered(w, .Theme, WALLPAPER_INDEX)
	pt := theme_from_colors(wallpaper_colors(w, w.dark), w.dark)
	if selected || hot { shadow(cv, r, 20, 4, th.dark ? 26 : 12, 3) }
	tx.canvas_fill_rounded_rect(cv, r, 20, th.field)
	if selected {
		tx.canvas_stroke_rounded_rect(cv, {r.x - 3, r.y - 3, r.w + 6, r.h + 6}, 23, 2.5, th.accent)
	} else if hot {
		tx.canvas_stroke_rounded_rect(cv, r, 20, 1.5, th.outline)
	}
	p := tx.Rect{r.x + 10, r.y + 10, r.w - 20, preview_h}
	draw_theme_preview(w, cv, p, &pt)
	if !w.pal.loaded {
		// No colours yet: a photo badge says where they will come from.
		b := tx.Rect{p.x + p.w - 44, p.y + p.h - 44, 32, 32}
		tx.canvas_fill_circle(cv, f32(b.x + 16), f32(b.y + 16), 16, tx.color_with_alpha(pt.bg, 230))
		if w.f_icon_small != nil { icon(w, w.f_icon_small, b, .Photo, pt.accent) }
	}
	if !usable {
		tx.canvas_fill_rounded_rect(cv, p, 14, tx.color_with_alpha(th.field, 150))
	}
	ly := p.y + p.h + 8
	title := tr(w, "Papel de parede", "Wallpaper")
	title_font := text_width(w, w.f_h2, title) <= r.w - 36 ? w.f_h2 : w.f_body // a narrow card: the smaller font, not "Papel de pa…"
	text(w, title_font, r.x + 18, ly, 26, ellipsize(w, title_font, title, r.w - 36), usable ? th.fg : th.muted)
	sub := tr(w, "Cores do papel de parede", "Colours of the wallpaper")
	if !usable {
		sub = tr(w, "Instale o matugen", "Install matugen")
	} else if selected {
		sub = scheme_title(w, w.pal.scheme)
	}
	sub_w := r.w - 36
	text(w, w.f_small, r.x + 18, ly + 24, 20, ellipsize(w, w.f_small, sub, sub_w), mix(th.fg, th.muted, 0.6))
	// On the picture's corner: the title below needs the whole width.
	if selected { check_badge(w, cv, p.x + p.w - 16, p.y + p.h - 16, 12) }
	if usable { add_hit(w, r, .Theme, WALLPAPER_INDEX) }
}

@(private) PILL_H :: 34
@(private) PILL_GAP :: 8

// Where each scheme pill goes in a block `width` wide (relative to its top
// left corner): after the label, wrapping under it.
@(private)
scheme_pill_rects :: proc(w: ^Wizard, width: i32) -> []tx.Rect {
	out := make([]tx.Rect, len(config.MATUGEN_SCHEMES), context.temp_allocator)
	left := text_width(w, w.f_small, tr(w, "Estilo das cores", "Colour style")) + 16
	x, y := left, i32(0)
	for _, i in config.MATUGEN_SCHEMES {
		pw := text_width(w, w.f_small, scheme_title(w, i)) + 28
		if x > left && x + pw > width {
			x = left
			y += PILL_H + PILL_GAP
		}
		out[i] = {x, y, pw, PILL_H}
		x += pw + PILL_GAP
	}
	return out
}

@(private)
scheme_pills_height :: proc(w: ^Wizard, width: i32) -> i32 {
	rects := scheme_pill_rects(w, width)
	return rects[len(rects) - 1].y + PILL_H
}

// matugen's schemes as pills (under the cards while the theme is chosen).
@(private)
draw_scheme_pills :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect) {
	th := &w.theme
	text(w, w.f_small, r.x, r.y, PILL_H, tr(w, "Estilo das cores", "Colour style"), th.muted)
	for rel, i in scheme_pill_rects(w, r.w) {
		title := scheme_title(w, i)
		pill := tx.Rect{r.x + rel.x, r.y + rel.y, rel.w, rel.h}
		sel := i == w.pal.scheme
		hot := hovered(w, .Th_Scheme, i)
		bg := sel ? th.accent : (hot ? th.hover : th.field)
		tx.canvas_fill_rounded_rect(cv, pill, f32(pill.h) / 2, bg)
		if !sel { tx.canvas_stroke_rounded_rect(cv, pill, f32(pill.h) / 2, 1, th.outline) }
		text_centered(w, w.f_small, pill, title, sel ? th.accent_fg : th.fg)
		add_hit(w, pill, .Th_Scheme, i)
	}
}

// milk itself, when it publishes new wallpaper colours: the terminal colours
// follow (milk.toml imports this file while the theme is chosen).
refresh_wallpaper_theme_files :: proc(cfg: ^config.Config) {
	if cfg == nil || cfg.appearance.theme != config.WALLPAPER_THEME { return }
	colors := config.Theme_Colors{bar = cfg.bar.theme, border_color = cfg.wm.border_color, focus_color = cfg.wm.focus_color}
	write_custom_alacritty(config.WALLPAPER_THEME, colors, cfg.appearance.variant == "dark")
}
