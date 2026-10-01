// The user's own colour themes (appearance.customThemes): the "Seus temas"
// strip under the presets, the editor of the settings app (name, light/dark,
// every colour milk draws with, as hex text or picked with hue / saturation /
// lightness sliders and swatches) and the Alacritty colours generated for
// them. Choosing a custom theme writes its colours into bar.theme and
// wm.borderColor/focusColor exactly like a preset, so everything that follows
// the theme (bar, borders, panels, toast, rofi, Spoil) follows it too.
package oobe

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import config "../config"
import tx "../tx"

// The colours of a theme, in the order the editor lists them.
@(private)
Theme_Slot :: enum { Background, Surface, Foreground, Muted, Accent, Accent_Fg, Warning, Border, Focus }

// milk.json keys (bar.theme's plus the window border colours of wm).
@(private, rodata)
SLOT_KEYS := [Theme_Slot]string{
	.Background = "background", .Surface = "surface", .Foreground = "foreground", .Muted = "muted", .Accent = "accent",
	.Accent_Fg = "accentForeground", .Warning = "warning", .Border = "borderColor", .Focus = "focusColor",
}

@(private)
slot_label :: proc(w: ^Wizard, slot: Theme_Slot) -> string {
	switch slot {
	case .Background: return tr(w, "Fundo da barra", "Bar background")
	case .Surface:    return tr(w, "Superfície", "Surface")
	case .Foreground: return tr(w, "Texto", "Foreground")
	case .Muted:      return tr(w, "Texto suave", "Muted")
	case .Accent:     return tr(w, "Destaque", "Accent")
	case .Accent_Fg:  return tr(w, "Texto no destaque", "Accent foreground")
	case .Warning:    return tr(w, "Alerta", "Warning")
	case .Border:     return tr(w, "Borda das janelas", "Window border")
	case .Focus:      return tr(w, "Janela em foco", "Focused window")
	}
	return ""
}

// Quick picks under the sliders: the presets' colours and a few more.
@(private, rodata)
THEME_SWATCHES := []string{
	"#FFFFFF", "#F5EEE6", "#EEF2E6", "#ECEEF6", "#E9E0D6", "#A89E94", "#3C3A38", "#2E2925", "#211D1A", "#191B24", "#000000",
	"#4A3F35", "#D9C3A5", "#4E6B3A", "#A7C58A", "#3F4F86", "#9FB0F0", "#B5473A", "#E07A6A", "#C98A2E", "#8B4F7E", "#377A72",
}

@(private)
User_Theme :: struct {
	name:   string, // owned
	dark:   bool,
	colors: [Theme_Slot]tx.Color,
}

@(private)
Theme_Editor :: struct {
	open:           bool,
	original:       int, // index into w.customs, -1 = a new theme
	name:           [dynamic]u8,
	dark:           bool,
	colors:         [Theme_Slot]tx.Color,
	hex:            [Theme_Slot][dynamic]u8, // text of the hex fields
	slot:           Theme_Slot,              // the colour the sliders edit
	hsl:            [3]f32,                  // hue, saturation, lightness of that colour (kept apart: grey has no hue)
	sliders:        [3]tx.Rect,              // as last drawn (window coordinates)
	dragging:       int,                     // slider under a drag, -1 = none
	error:          string,                  // literal
	confirm_delete: bool,
}

// ---------------------------------------------------------------------------
// The list
// ---------------------------------------------------------------------------
@(private)
themes_load :: proc(w: ^Wizard) {
	for t in w.cfg.appearance.custom_themes {
		append(&w.customs, User_Theme{name = strings.clone(t.name), dark = t.dark, colors = colors_to_slots(t.colors)})
	}
}

@(private)
themes_destroy :: proc(w: ^Wizard) {
	for t in w.customs { delete(t.name) }
	delete(w.customs)
}

@(private)
ted_destroy :: proc(w: ^Wizard) {
	ed := &w.set.ted
	delete(ed.name)
	for b in ed.hex { delete(b) }
}

@(private)
preset_count :: proc() -> int { return len(config.THEME_PRESETS) }

// The selected custom theme (nil when a preset is selected).
@(private)
selected_custom :: proc(w: ^Wizard) -> ^User_Theme {
	k := w.theme_index - preset_count()
	if k < 0 || k >= len(w.customs) { return nil }
	return &w.customs[k]
}

@(private)
theme_is_custom :: proc(w: ^Wizard) -> bool { return selected_custom(w) != nil }

// The look of the wizard / settings window: the selected theme.
@(private)
current_theme :: proc(w: ^Wizard) -> Theme {
	if t := selected_custom(w); t != nil { return theme_from_colors(slots_to_colors(t.colors), t.dark) }
	if wallpaper_selected(w) { return theme_from_colors(wallpaper_colors(w, w.dark), w.dark) }
	return preset_theme(w.theme_index, w.dark)
}

// Name (appearance.theme), colours and variant of the selected theme (strings are literals or temp).
@(private)
chosen_theme :: proc(w: ^Wizard) -> (name: string, colors: config.Theme_Colors, dark: bool) {
	if t := selected_custom(w); t != nil { return t.name, slots_to_colors(t.colors), t.dark }
	if wallpaper_selected(w) { return config.WALLPAPER_THEME, wallpaper_colors(w, w.dark), w.dark }
	p := config.THEME_PRESETS[clamp(w.theme_index, 0, preset_count() - 1)]
	return p.name, w.dark ? p.dark : p.light, w.dark
}

@(private)
theme_title :: proc(w: ^Wizard) -> string {
	if t := selected_custom(w); t != nil { return t.name }
	if wallpaper_selected(w) { return tr(w, "Papel de parede", "Wallpaper") }
	return config.THEME_PRESETS[clamp(w.theme_index, 0, preset_count() - 1)].title
}

@(private)
hex_of :: proc(c: tx.Color) -> string { return fmt.tprintf("#%02X%02X%02X", c.r, c.g, c.b) }

@(private)
colors_to_slots :: proc(c: config.Theme_Colors) -> (s: [Theme_Slot]tx.Color) {
	d := config.THEME_PRESETS[0].light
	s[.Background] = tx.color_from_hex(c.bar.background, tx.color_from_hex(d.bar.background))
	s[.Surface] = tx.color_from_hex(c.bar.surface, tx.color_from_hex(d.bar.surface))
	s[.Foreground] = tx.color_from_hex(c.bar.foreground, tx.color_from_hex(d.bar.foreground))
	s[.Muted] = tx.color_from_hex(c.bar.muted, tx.color_from_hex(d.bar.muted))
	s[.Accent] = tx.color_from_hex(c.bar.accent, tx.color_from_hex(d.bar.accent))
	s[.Accent_Fg] = tx.color_from_hex(c.bar.accent_foreground, tx.color_from_hex(d.bar.accent_foreground))
	s[.Warning] = tx.color_from_hex(c.bar.warning, tx.color_from_hex(d.bar.warning))
	s[.Border] = tx.color_from_hex(c.border_color, tx.color_from_hex(d.border_color))
	s[.Focus] = tx.color_from_hex(c.focus_color, tx.color_from_hex(d.focus_color))
	for &col in s { col.a = 255 }
	return
}

@(private)
slots_to_colors :: proc(s: [Theme_Slot]tx.Color) -> (c: config.Theme_Colors) {
	c.bar = {background = hex_of(s[.Background]), foreground = hex_of(s[.Foreground]), muted = hex_of(s[.Muted]),
	         accent = hex_of(s[.Accent]), accent_foreground = hex_of(s[.Accent_Fg]), surface = hex_of(s[.Surface]),
	         warning = hex_of(s[.Warning])}
	c.border_color = hex_of(s[.Border])
	c.focus_color = hex_of(s[.Focus])
	return
}

// appearance.customThemes as written to milk.json (temp allocations).
@(private)
themes_json :: proc(w: ^Wizard) -> json.Object {
	out := make(json.Object, context.temp_allocator)
	for t in w.customs {
		obj := make(json.Object, context.temp_allocator)
		obj["variant"] = json.String(t.dark ? "dark" : "light")
		for slot in Theme_Slot { obj[SLOT_KEYS[slot]] = json.String(hex_of(t.colors[slot])) }
		out[t.name] = obj
	}
	return out
}

@(private)
sort_customs :: proc(w: ^Wizard) {
	a := w.customs[:]
	for i in 1 ..< len(a) {
		for j := i; j > 0 && a[j].name < a[j - 1].name; j -= 1 { a[j], a[j - 1] = a[j - 1], a[j] }
	}
}

// Height of the "Seus temas" strip under the preset cards (0 = none: the
// wizard shows it only when there are custom themes).
@(private)
custom_strip_height :: proc(w: ^Wizard, area: tx.Rect) -> i32 {
	if w.mode != .Settings && len(w.customs) == 0 { return 0 }
	return clamp(area.h / 3, 120, 170)
}

// Three overlapping dots in a theme's colours.
@(private)
theme_dots :: proc(w: ^Wizard, cv: ^tx.Canvas, x, cy: i32, colors: [Theme_Slot]tx.Color, radius: f32 = 10) {
	th := &w.theme
	step := i32(radius * 1.2)
	for slot, k in ([3]Theme_Slot{.Background, .Surface, .Accent}) {
		cx := f32(x + i32(k) * step) + radius
		tx.canvas_fill_circle(cv, cx, f32(cy), radius + 1.5, th.field)
		tx.canvas_fill_circle(cv, cx, f32(cy), radius, colors[slot])
		tx.canvas_stroke_rounded_rect(cv, {i32(cx - radius), cy - i32(radius), i32(2 * radius), i32(2 * radius)}, radius, 1, tx.color_with_alpha(th.muted, 90))
	}
}

@(private)
draw_custom_themes :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect) {
	th := &w.theme
	text(w, w.f_tiny, r.x, r.y, 32, tr(w, "SEUS TEMAS", "YOUR THEMES"), th.muted)
	if w.mode == .Settings {
		label := tr(w, "Novo tema", "New theme")
		bw := button_width(w, label, .Plus) - 12
		button(w, cv, {r.x + r.w - bw, r.y - 2, bw, 36}, label, .Tonal, .Th_New, 0, .Plus)
	}
	list := tx.Rect{r.x, r.y + 42, r.w, r.h - 42}
	if len(w.customs) == 0 {
		text(w, w.f_body, list.x, list.y, 30, ellipsize(w, w.f_body, tr(w, "Crie um tema com as suas cores: ele vale para a barra, as janelas, os painéis e o terminal.",
		                                                              "Make a theme with your own colours: it applies to the bar, windows, panels and terminal."), list.w), th.muted)
		return
	}
	cols: i32 = list.w >= 900 ? 4 : 3
	gap: i32 = 12
	chip_w := (list.w - (cols - 1) * gap) / cols
	chip_h: i32 = 52
	rows := (i32(len(w.customs)) + cols - 1) / cols
	content_h := rows * (chip_h + gap) - gap
	max_scroll := max(content_h - list.h, 0)
	w.scroll_themes = clamp(w.scroll_themes, 0, max_scroll)
	append(&w.scrolls, Scroll_Area{r = list, id = .Themes, max = max_scroll})
	// A margin of 4 px around the list keeps the selection ring inside the sub-canvas.
	vp := tx.Rect{list.x - 4, list.y - 4, list.w + 8, list.h + 8}
	sub := tx.canvas_make(vp.w, vp.h, context.temp_allocator)
	tx.canvas_fill(&sub, th.bg)
	for t, k in w.customs {
		col, row := i32(k) % cols, i32(k) / cols
		cr := tx.Rect{4 + col * (chip_w + gap), 4 + row * (chip_h + gap) - w.scroll_themes, chip_w, chip_h}
		if cr.y + cr.h < 0 || cr.y > vp.h { continue }
		win := tx.Rect{vp.x + cr.x, vp.y + cr.y, cr.w, cr.h}
		idx := preset_count() + k
		selected := w.theme_index == idx
		hot := hovered(w, .Theme, idx) || hovered(w, .Th_Edit, k)
		fill_rounded(&sub, cr, 16, hot && !selected ? th.hover : th.field)
		if selected { tx.canvas_stroke_rounded_rect(&sub, {cr.x - 2, cr.y - 2, cr.w + 4, cr.h + 4}, 18, 2.5, th.accent) }
		theme_dots(w, &sub, cr.x + 12, cr.y + cr.h / 2, t.colors)
		tx0 := win.x + 12 + 2 * 12 + 20 + 12
		right := win.x + win.w - 12
		edit := tx.Rect{right - 32, win.y + (win.h - 32) / 2, 32, 32}
		if w.mode == .Settings {
			if hovered(w, .Th_Edit, k) { fill_rounded(&sub, {edit.x - vp.x, edit.y - vp.y, edit.w, edit.h}, 16, th.surface) }
			icon(w, w.f_icon_small, edit, .Pencil, mix(th.fg, th.muted, 0.3), list)
			right = edit.x - 4
		}
		if selected {
			icon(w, w.f_icon_small, {right - 22, win.y, 22, win.h}, .Check, th.accent, list)
			right -= 26
		}
		text(w, w.f_body, tx0, win.y + 6, 22, ellipsize(w, w.f_body, t.name, right - tx0), th.fg, list)
		text(w, w.f_small, tx0, win.y + 27, 18, t.dark ? tr(w, "Escuro", "Dark") : tr(w, "Claro", "Light"), mix(th.fg, th.muted, 0.6), list)
		add_hit(w, win, .Theme, idx, list)
		if w.mode == .Settings { add_hit(w, edit, .Th_Edit, k, list) }
	}
	if max_scroll > 0 {
		track := list.h - 8
		thumb_h := max(track * list.h / content_h, 24)
		thumb_y := 4 + 4 + (track - thumb_h) * w.scroll_themes / max_scroll
		fill_rounded(&sub, {vp.w - 4, thumb_y, 3, thumb_h}, 1.5, tx.color_with_alpha(th.muted, 150))
	}
	composite_rounded(cv, sub, vp.x, vp.y, 0)
}

// ---------------------------------------------------------------------------
// The editor
// ---------------------------------------------------------------------------
@(private)
unique_theme_name :: proc(w: ^Wizard, base: string) -> string {
	taken :: proc(w: ^Wizard, name: string) -> bool {
		if !config.valid_custom_theme_name(name) { return true }
		for t in w.customs { if strings.equal_fold(t.name, name) { return true } }
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
ted_sync_hex :: proc(ed: ^Theme_Editor) {
	for slot in Theme_Slot {
		clear(&ed.hex[slot])
		append(&ed.hex[slot], ..transmute([]u8)hex_of(ed.colors[slot]))
	}
}

@(private)
ted_select_slot :: proc(w: ^Wizard, slot: Theme_Slot) {
	ed := &w.set.ted
	if ed.slot != slot {
		ed.slot = slot
		ted_sync_hex(ed) // drop half-typed text in the other fields
	}
	ed.hsl = rgb_to_hsl(ed.colors[slot])
}

// Open the editor on custom theme `index`, or on a new theme made from the
// current colours when index < 0.
@(private)
ted_open :: proc(w: ^Wizard, index: int) {
	ed := &w.set.ted
	ed.open = true
	ed.original = index
	ed.error = ""
	ed.confirm_delete = false
	ed.dragging = -1
	clear(&ed.name)
	if index >= 0 && index < len(w.customs) {
		t := w.customs[index]
		append(&ed.name, ..transmute([]u8)t.name)
		ed.dark = t.dark
		ed.colors = t.colors
	} else {
		ed.original = -1
		_, colors, dark := chosen_theme(w)
		ed.colors = colors_to_slots(colors)
		ed.dark = dark
		append(&ed.name, ..transmute([]u8)unique_theme_name(w, tr(w, "Meu tema", "My theme")))
	}
	ed.slot = .Accent
	ted_sync_hex(ed)
	ed.hsl = rgb_to_hsl(ed.colors[ed.slot])
	w.focus = .None
	w.hover = {}
}

@(private)
ted_close :: proc(w: ^Wizard) {
	ed := &w.set.ted
	ed.open = false
	ed.dragging = -1
	w.focus = .None
	w.hover = {}
}

@(private)
ted_save :: proc(w: ^Wizard) {
	ed := &w.set.ted
	name := strings.trim_space(string(ed.name[:]))
	if name == "" {
		ed.error = tr(w, "Dê um nome ao tema.", "Give the theme a name.")
		return
	}
	if !config.valid_custom_theme_name(name) {
		ed.error = tr(w, "Este nome é de um tema do milk.", "That is the name of a milk theme.")
		return
	}
	for t, i in w.customs {
		if i != ed.original && strings.equal_fold(t.name, name) {
			ed.error = tr(w, "Já existe um tema com esse nome.", "There is already a theme with that name.")
			return
		}
	}
	saved := strings.clone(name, context.temp_allocator)
	if ed.original >= 0 && ed.original < len(w.customs) {
		t := &w.customs[ed.original]
		delete(t.name)
		t^ = {name = strings.clone(saved), dark = ed.dark, colors = ed.colors}
	} else {
		append(&w.customs, User_Theme{name = strings.clone(saved), dark = ed.dark, colors = ed.colors})
	}
	sort_customs(w)
	for t, i in w.customs {
		if t.name == saved { w.theme_index = preset_count() + i }
	}
	w.dark = ed.dark
	w.set.themes_dirty = true
	ted_close(w)
	update_theme(w)
	settings_changed(w, .Theme) // saving a theme also puts it to use
}

@(private)
ted_delete :: proc(w: ^Wizard) {
	ed := &w.set.ted
	index := ed.original
	if index < 0 || index >= len(w.customs) {
		ted_close(w)
		return
	}
	if !ed.confirm_delete {
		ed.confirm_delete = true
		return
	}
	custom_index := preset_count() + index
	active := w.theme_index == custom_index
	delete(w.customs[index].name)
	ordered_remove(&w.customs, index)
	if active {
		w.theme_index = 0 // milk, in the variant the deleted theme had
	} else if w.theme_index > custom_index {
		w.theme_index -= 1
	}
	w.set.themes_dirty = true
	ted_close(w)
	update_theme(w)
	settings_changed(w, active ? .Theme : .Values)
}

// Set the edited colour from slider `k` at window x.
@(private)
ted_slider_at :: proc(w: ^Wizard, k: int, x: i32) {
	ed := &w.set.ted
	r := ed.sliders[k]
	if r.w <= 0 { return }
	ed.hsl[k] = clamp(f32(x - r.x) / f32(max(r.w - 1, 1)), 0, 1)
	ed.colors[ed.slot] = hsl_to_rgb(ed.hsl)
	clear(&ed.hex[ed.slot])
	append(&ed.hex[ed.slot], ..transmute([]u8)hex_of(ed.colors[ed.slot]))
	w.dirty = true
}

// Pointer motion: keeps dragging a slider while the first button is held.
@(private)
theme_drag :: proc(w: ^Wizard, x: i32, held: bool) {
	ed := &w.set.ted
	if !held || !ed.open {
		ed.dragging = -1
		return
	}
	if ed.dragging >= 0 { ted_slider_at(w, ed.dragging, x) }
}

// A hex field was edited: take the colour once it is complete (#RGB or #RRGGBB, '#' optional).
@(private)
ted_hex_edited :: proc(w: ^Wizard, slot: Theme_Slot) {
	ed := &w.set.ted
	s := strings.trim_space(string(ed.hex[slot][:]))
	s = strings.trim_prefix(s, "#")
	if len(s) == 3 {
		s = fmt.tprintf("%c%c%c%c%c%c", s[0], s[0], s[1], s[1], s[2], s[2])
	}
	if len(s) != 6 { return }
	c := tx.color_from_hex(s, {0, 0, 0, 0})
	if c.a == 0 { return }
	ed.colors[slot] = c
	if slot == ed.slot { ed.hsl = rgb_to_hsl(c) }
	w.dirty = true
}

@(private)
themes_action :: proc(w: ^Wizard, action: Action, arg: int) {
	ed := &w.set.ted
	#partial switch action {
	case .Th_New:     ted_open(w, -1)
	case .Th_Edit:    ted_open(w, arg)
	case .Th_Cancel:  ted_close(w)
	case .Th_Save:    ted_save(w)
	case .Th_Delete:  ted_delete(w)
	case .Th_Variant: ed.dark = arg == 1
	case .Th_Slot:
		ted_select_slot(w, Theme_Slot(clamp(arg, 0, len(Theme_Slot) - 1)))
		w.focus = .None
	case .Th_Slider:
		ed.dragging = clamp(arg, 0, 2)
		ted_slider_at(w, ed.dragging, w.pointer.x)
	case .Th_Swatch:
		if arg < 0 || arg >= len(THEME_SWATCHES) { return }
		ed.colors[ed.slot] = tx.color_from_hex(THEME_SWATCHES[arg])
		ed.hsl = rgb_to_hsl(ed.colors[ed.slot])
		ted_sync_hex(ed)
	}
	if action != .Th_Delete { ed.confirm_delete = false }
	if action != .Th_Save && action != .Th_Delete { ed.error = "" }
	w.dirty = true
}

@(private)
draw_theme_editor :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	th := &w.theme
	ed := &w.set.ted
	y := c.y
	text(w, w.f_h2, c.x, y, 34, ed.original < 0 ? tr(w, "Novo tema", "New theme") : tr(w, "Editar tema", "Edit theme"), th.fg)
	y += 42

	// Name and variant.
	seg_w := min(i32(260), c.w / 3)
	name_target := int(Control.Th_Name) * 100
	draw_field(w, cv, {c.x, y, c.w - seg_w - 16, 44}, .Pencil, string(ed.name[:]), tr(w, "Nome do tema", "Theme name"),
	           w.focus == .Text && w.set.text_target == name_target, .Text_Field, name_target)
	segmented(w, cv, {c.x + c.w - seg_w, y, seg_w, 44}, {tr(w, "Claro", "Light"), tr(w, "Escuro", "Dark")}, {.Sun, .Moon},
	          ed.dark ? 1 : 0, .Th_Variant)
	y += 58

	footer_y := c.y + c.h - BUTTON_H
	body_h := footer_y - 14 - y

	// Colours: swatch, name and hex field; the selected one is edited by the sliders.
	lw := c.w / 2
	row_h := clamp(body_h / len(Theme_Slot), 26, 38)
	for slot, i in Theme_Slot {
		r := tx.Rect{c.x, y + i32(i) * row_h, lw, row_h - 4}
		if slot == ed.slot {
			fill_rounded(cv, r, 12, mix(th.accent, th.bg, 0.86))
		} else if hovered(w, .Th_Slot, int(slot)) {
			fill_rounded(cv, r, 12, th.hover)
		}
		add_hit(w, r, .Th_Slot, int(slot))
		cy := r.y + r.h / 2
		tx.canvas_fill_circle(cv, f32(r.x + 20), f32(cy), 11, ed.colors[slot])
		tx.canvas_stroke_rounded_rect(cv, {r.x + 9, cy - 11, 22, 22}, 11, 1, tx.color_with_alpha(th.fg, 70))
		fw: i32 = 118
		fh := min(i32(30), r.h - 2)
		text(w, w.f_body, r.x + 40, r.y, r.h, ellipsize(w, w.f_body, slot_label(w, slot), r.w - 40 - fw - 12), slot == ed.slot ? th.accent : th.fg)
		target := int(Control.Th_Hex) * 100 + int(slot)
		draw_field(w, cv, {r.x + r.w - fw - 4, cy - fh / 2, fw, fh}, .None, string(ed.hex[slot][:]), "#RRGGBB",
		           w.focus == .Text && w.set.text_target == target, .Text_Field, target)
	}

	// Preview and picker.
	rx := c.x + lw + 20
	rw := c.x + c.w - rx
	swatch: i32 = 20
	per_row := max((rw + 6) / (swatch + 6), 1)
	swatch_rows := (i32(len(THEME_SWATCHES)) + per_row - 1) / per_row
	picker_h := 22 + 3 * 30 + 8 + swatch_rows * (swatch + 6)
	ph := clamp(body_h - picker_h - 14, 70, 170)
	pt := theme_from_colors(slots_to_colors(ed.colors), ed.dark)
	draw_theme_preview(w, cv, {rx, y, rw, ph}, &pt)
	py := y + ph + 14
	text(w, w.f_tiny, rx, py, 18, strings.to_upper(slot_label(w, ed.slot), context.temp_allocator), th.muted)
	py += 22
	names := [3]string{tr(w, "Matiz", "Hue"), tr(w, "Saturação", "Saturation"), tr(w, "Luz", "Lightness")}
	label_w: i32 = 0
	for n in names { label_w = max(label_w, text_width(w, w.f_small, n)) }
	label_w += 12
	for k in 0 ..< 3 {
		row := tx.Rect{rx, py + i32(k) * 30, rw, 30}
		text(w, w.f_small, row.x, row.y, row.h, names[k], mix(th.fg, th.muted, 0.4))
		bar := tx.Rect{row.x + label_w + 8, row.y + 7, row.w - label_w - 16, 16}
		draw_hsl_slider(w, cv, bar, k, ed.hsl)
		ed.sliders[k] = bar
		add_hit(w, {bar.x - 8, row.y, bar.w + 16, row.h}, .Th_Slider, k)
	}
	py += 3 * 30 + 8
	for hex, i in THEME_SWATCHES {
		col, row := i32(i) % per_row, i32(i) / per_row
		r := tx.Rect{rx + col * (swatch + 6), py + row * (swatch + 6), swatch, swatch}
		sc := tx.color_from_hex(hex)
		if hovered(w, .Th_Swatch, i) { tx.canvas_fill_circle(cv, f32(r.x) + 10, f32(r.y) + 10, 12, th.accent) }
		tx.canvas_fill_circle(cv, f32(r.x) + 10, f32(r.y) + 10, 9, sc)
		tx.canvas_stroke_rounded_rect(cv, {r.x + 1, r.y + 1, 18, 18}, 9, 1, tx.color_with_alpha(th.fg, 60))
		add_hit(w, {r.x - 2, r.y - 2, r.w + 4, r.h + 4}, .Th_Swatch, i)
	}

	// Footer.
	save := tr(w, "Salvar e usar", "Save and use")
	sw := max(button_width(w, save, .Check), 150)
	save_r := tx.Rect{c.x + c.w - sw, footer_y, sw, BUTTON_H}
	button(w, cv, save_r, save, .Filled, .Th_Save, 0, .Check)
	cancel := tr(w, "Cancelar", "Cancel")
	cw := button_width(w, cancel)
	button(w, cv, {save_r.x - 10 - cw, footer_y, cw, BUTTON_H}, cancel, .Text, .Th_Cancel)
	left := c.x
	if ed.original >= 0 {
		del := ed.confirm_delete ? tr(w, "Confirmar exclusão", "Confirm delete") : tr(w, "Excluir", "Delete")
		dw := button_width(w, del, .Trash)
		button(w, cv, {c.x - 12, footer_y, dw, BUTTON_H}, del, ed.confirm_delete ? .Tonal : .Text, .Th_Delete, 0, .Trash)
		left = c.x - 12 + dw + 12
	}
	if ed.error != "" {
		avail := save_r.x - 10 - cw - 12 - left
		icon(w, w.f_icon_small, {left, footer_y, 20, BUTTON_H}, .Alert, th.warning)
		text(w, w.f_small, left + 24, footer_y, BUTTON_H, ellipsize(w, w.f_small, ed.error, avail - 24), th.warning)
	}
}

// A gradient bar for hue (k = 0), saturation (1) or lightness (2) with a knob at the current value.
@(private)
draw_hsl_slider :: proc(w: ^Wizard, cv: ^tx.Canvas, bar: tx.Rect, k: int, hsl: [3]f32) {
	th := &w.theme
	if bar.w <= 2 { return }
	sub := tx.canvas_make(bar.w, bar.h, context.temp_allocator)
	for x in 0 ..< bar.w {
		t := f32(x) / f32(bar.w - 1)
		v := hsl
		if k == 0 {
			v = {t, max(hsl[1], 0.55), clamp(hsl[2], 0.35, 0.65)} // the hue bar stays colourful for greys
		} else {
			v[k] = t
		}
		c := hsl_to_rgb(v)
		px := u32(c.r) << 16 | u32(c.g) << 8 | u32(c.b)
		for y in 0 ..< bar.h { sub.px[int(y) * int(bar.w) + int(x)] = px }
	}
	composite_rounded(cv, sub, bar.x, bar.y, f32(bar.h) / 2)
	tx.canvas_stroke_rounded_rect(cv, bar, f32(bar.h) / 2, 1, tx.color_with_alpha(th.fg, 50))
	kx := f32(bar.x) + hsl[k] * f32(bar.w - 1)
	ky := f32(bar.y) + f32(bar.h) / 2
	knob := hsl
	if k == 0 { knob = {hsl[0], max(hsl[1], 0.55), clamp(hsl[2], 0.35, 0.65)} }
	tx.canvas_fill_circle(cv, kx, ky, 10, th.fg)
	tx.canvas_fill_circle(cv, kx, ky, 8, th.bg)
	tx.canvas_fill_circle(cv, kx, ky, 6, hsl_to_rgb(knob))
}

// ---------------------------------------------------------------------------
// Colour maths
// ---------------------------------------------------------------------------
@(private)
rgb_to_hsl :: proc(c: tx.Color) -> [3]f32 {
	r, g, b := f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255
	hi := max(r, g, b)
	lo := min(r, g, b)
	l := (hi + lo) / 2
	if hi - lo < 1e-6 { return {0, 0, l} }
	d := hi - lo
	s := l > 0.5 ? d / (2 - hi - lo) : d / (hi + lo)
	h: f32
	if hi == r {
		h = (g - b) / d + (g < b ? 6 : 0)
	} else if hi == g {
		h = (b - r) / d + 2
	} else {
		h = (r - g) / d + 4
	}
	return {h / 6, s, l}
}

@(private)
hsl_to_rgb :: proc(hsl: [3]f32) -> tx.Color {
	h, s, l := hsl[0], clamp(hsl[1], 0, 1), clamp(hsl[2], 0, 1)
	to_u8 :: proc(v: f32) -> u8 { return u8(clamp(math.round(v * 255), 0, 255)) }
	if s <= 0 {
		v := to_u8(l)
		return {v, v, v, 255}
	}
	q := l < 0.5 ? l * (1 + s) : l + s - l * s
	p := 2 * l - q
	channel :: proc(p, q, t: f32) -> f32 {
		t := t
		if t < 0 { t += 1 }
		if t > 1 { t -= 1 }
		if t < 1.0 / 6 { return p + (q - p) * 6 * t }
		if t < 0.5 { return q }
		if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
		return p
	}
	return {to_u8(channel(p, q, h + 1.0 / 3)), to_u8(channel(p, q, h)), to_u8(channel(p, q, h - 1.0 / 3)), 255}
}

// ---------------------------------------------------------------------------
// Alacritty
// ---------------------------------------------------------------------------
// Terminal colours of custom themes live in $XDG_CONFIG_HOME/milk/alacritty
// (~/.config/milk/alacritty), one milk-custom-<name>.toml per theme.
@(private) CUSTOM_ALACRITTY_PREFIX :: "milk-custom-"

@(private)
custom_alacritty_dir :: proc() -> string {
	base, found := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
	if !found || base == "" { base = join_path({home_dir(), ".config"}) }
	return join_path({base, "milk", "alacritty"})
}

// File name for a custom theme: its name in lower-case ASCII, other characters as '-'.
@(private)
custom_alacritty_file :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, CUSTOM_ALACRITTY_PREFIX)
	dash := false
	n := 0
	for r in strings.to_lower(name, context.temp_allocator) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			if dash && n > 0 { strings.write_byte(&b, '-') }
			strings.write_rune(&b, r)
			dash = false
			n += 1
		} else {
			dash = true
		}
	}
	if n == 0 { strings.write_string(&b, "theme") }
	strings.write_string(&b, ".toml")
	return strings.to_string(b)
}

@(private)
is_custom_alacritty_file :: proc(base: string) -> bool {
	return strings.has_prefix(base, CUSTOM_ALACRITTY_PREFIX) && strings.has_suffix(base, ".toml")
}

// Write the Alacritty colours of a custom theme; returns the file's path.
@(private)
write_custom_alacritty :: proc(name: string, colors: config.Theme_Colors, dark: bool) -> (string, bool) {
	dir := custom_alacritty_dir()
	if err := os.make_directory_all(dir); err != nil && !os.is_directory(dir) {
		log.warnf("Setup: cannot create %s: %v", dir, err)
		return "", false
	}
	path := join_path({dir, custom_alacritty_file(name)})
	s := colors_to_slots(colors)
	bg, fg, muted, accent := s[.Background], s[.Foreground], s[.Muted], s[.Accent]
	white := tx.rgb(255, 255, 255)
	black := tx.rgb(0, 0, 0)
	// ANSI colours of milk's own light / dark terminal themes (tuned for readability).
	light_ansi := [10]string{"#5F7A3E", "#9C6A12", "#3E6C8C", "#8B4F7E", "#377A72", "#6E8C48", "#B07C1E", "#4C7FA2", "#9D6190", "#468D84"}
	dark_ansi := [10]string{"#A5B97A", "#E0B36A", "#8AA9C9", "#C79BBE", "#86BDB2", "#B7CB8C", "#EEC47E", "#9DBBD9", "#D6ADCD", "#98CFC4"}
	ansi := dark ? dark_ansi : light_ansi
	pairs := [][2]string{
		{"@NAME@", name}, {"@VARIANT@", dark ? "dark" : "light"},
		{"@BG@", hex_of(bg)}, {"@FG@", hex_of(fg)},
		{"@DIM_FG@", hex_of(mix(fg, bg, 0.35))}, {"@BRIGHT_FG@", hex_of(mix(fg, dark ? white : black, 0.4))},
		{"@ACCENT@", hex_of(accent)}, {"@ACCENT_SOFT@", hex_of(mix(accent, bg, 0.3))},
		{"@SELECTION@", hex_of(mix(s[.Surface], fg, dark ? 0.12 : 0.08))},
		{"@SURFACE@", hex_of(s[.Surface])}, {"@WARNING@", hex_of(s[.Warning])},
		{"@WARNING_BRIGHT@", hex_of(mix(s[.Warning], dark ? white : black, 0.12))},
		{"@BLACK@", hex_of(dark ? s[.Border] : fg)}, {"@WHITE@", hex_of(dark ? mix(fg, muted, 0.3) : muted)},
		{"@BRIGHT_BLACK@", hex_of(dark ? muted : mix(fg, bg, 0.35))}, {"@BRIGHT_WHITE@", hex_of(dark ? fg : s[.Border])},
		{"@GREEN@", ansi[0]}, {"@YELLOW@", ansi[1]}, {"@BLUE@", ansi[2]}, {"@MAGENTA@", ansi[3]}, {"@CYAN@", ansi[4]},
		{"@BRIGHT_GREEN@", ansi[5]}, {"@BRIGHT_YELLOW@", ansi[6]}, {"@BRIGHT_BLUE@", ansi[7]}, {"@BRIGHT_MAGENTA@", ansi[8]}, {"@BRIGHT_CYAN@", ansi[9]},
	}
	text := ALACRITTY_TEMPLATE
	for pr in pairs { text, _ = strings.replace_all(text, pr[0], pr[1], context.temp_allocator) }
	tmp := fmt.tprintf("%s.tmp", path)
	if err := os.write_entire_file(tmp, text); err != nil {
		log.warnf("Setup: cannot write %s: %v", tmp, err)
		return "", false
	}
	if err := os.rename(tmp, path); err != nil {
		log.warnf("Setup: cannot write %s: %v", path, err)
		return "", false
	}
	return path, true
}

// Remove the terminal colours of custom themes that no longer exist.
@(private)
remove_stale_alacritty :: proc(w: ^Wizard) {
	dir := custom_alacritty_dir()
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for fi in infos {
		base := os.base(fi.fullpath)
		if !is_custom_alacritty_file(base) { continue }
		used := base == custom_alacritty_file(config.WALLPAPER_THEME) // the wallpaper theme's (milk rewrites it)
		for t in w.customs { if custom_alacritty_file(t.name) == base { used = true; break } }
		if !used { os.remove(fi.fullpath) }
	}
}

@(private)
ALACRITTY_TEMPLATE :: `# milk colours for Alacritty (custom theme "@NAME@", @VARIANT@): generated by the
# milk settings app from appearance.customThemes in milk.json; edits are
# overwritten. Imported by ~/.config/alacritty/milk.toml.

[window]
padding = { x = 12, y = 10 }
dynamic_padding = true
opacity = 1.0

[colors]
draw_bold_text_with_bright_colors = false

[colors.primary]
background = "@BG@"
foreground = "@FG@"
dim_foreground = "@DIM_FG@"
bright_foreground = "@BRIGHT_FG@"

[colors.cursor]
text = "@BG@"
cursor = "@ACCENT@"

[colors.vi_mode_cursor]
text = "@BG@"
cursor = "@ACCENT_SOFT@"

[colors.selection]
text = "CellForeground"
background = "@SELECTION@"

[colors.search.matches]
foreground = "@BG@"
background = "@ACCENT_SOFT@"

[colors.search.focused_match]
foreground = "@BG@"
background = "@ACCENT@"

[colors.footer_bar]
foreground = "@BG@"
background = "@ACCENT@"

[colors.hints.start]
foreground = "@BG@"
background = "@WARNING@"

[colors.hints.end]
foreground = "@ACCENT@"
background = "@SURFACE@"

[colors.normal]
black   = "@BLACK@"
red     = "@WARNING@"
green   = "@GREEN@"
yellow  = "@YELLOW@"
blue    = "@BLUE@"
magenta = "@MAGENTA@"
cyan    = "@CYAN@"
white   = "@WHITE@"

[colors.bright]
black   = "@BRIGHT_BLACK@"
red     = "@WARNING_BRIGHT@"
green   = "@BRIGHT_GREEN@"
yellow  = "@BRIGHT_YELLOW@"
blue    = "@BRIGHT_BLUE@"
magenta = "@BRIGHT_MAGENTA@"
cyan    = "@BRIGHT_CYAN@"
white   = "@BRIGHT_WHITE@"
`
