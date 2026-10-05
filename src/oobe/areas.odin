// Settings → Areas: each area's name and icon (workspaces.N.name / .icon),
// whether the area toast says "AREA N" before the name
// (linux.indicator.showNumber) and whether the bar shows the icons in place
// of the area dots (bar.workspaceIcons). The icons are the Tabler glyphs of
// config.AREA_ICONS, picked from a grid.
package oobe

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import config "../config"
import tx "../tx"

@(private) AREA_ICON_BUTTON :: 40 // the icon button of an area's row
@(private) AREA_ICON_TILE   :: 48 // a choice in the picker

@(private)
Areas_State :: struct {
	icons:     [dynamic]string, // per w.areas: the icon name (owned), "" = none
	picking:   int,             // index into w.areas whose icon is being chosen, -1 = none
	number:    bool,            // linux.indicator.showNumber
	bar_icons: bool,            // bar.workspaceIcons
}

@(private)
areas_load_values :: proc(w: ^Wizard) {
	a := &w.set.areas
	a.picking = -1
	a.number = w.cfg.linux.indicator.show_number
	a.bar_icons = w.cfg.bar.workspace_icons
	for n in w.areas {
		icon := ""
		if ws, ok := w.cfg.workspaces[n]; ok { icon = ws.icon }
		append(&a.icons, strings.clone(icon))
	}
}

@(private)
areas_destroy :: proc(w: ^Wizard) {
	a := &w.set.areas
	for i in a.icons { delete(i) }
	delete(a.icons)
	a^ = {}
}

// An icon name as text in the icon font ("" when it has no glyph there).
@(private)
area_icon_text :: proc(w: ^Wizard, f: ^tx.Font, name: string) -> string {
	r, ok := config.area_icon_rune(name)
	if !ok || f == nil || !tx.font_has_glyph(w.c, f, r) { return "" }
	buf, n := utf8.encode_rune(r)
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

@(private)
areas_set_icon :: proc(w: ^Wizard, index: int, name: string) {
	a := &w.set.areas
	if index < 0 || index >= len(a.icons) { return }
	delete(a.icons[index])
	a.icons[index] = strings.clone(name)
	path := fmt.tprintf("workspaces.%d.icon", w.areas[index])
	set_edit(w, path, name == "" ? json.Value(json.Null(nil)) : json.Value(json.String(name)))
	settings_changed(w, .Values)
}

@(private)
areas_action :: proc(w: ^Wizard, action: Action, arg: int) {
	a := &w.set.areas
	#partial switch action {
	case .Area_Icon:
		a.picking = clamp(arg, 0, len(w.areas) - 1)
		w.focus = .None
	case .Area_Icon_Back:
		a.picking = -1
	case .Area_Icon_Pick:
		if a.picking < 0 { return }
		name := arg >= 0 && arg < len(config.AREA_ICONS) ? config.AREA_ICONS[arg].name : ""
		areas_set_icon(w, a.picking, name)
		a.picking = -1
	}
	w.hover = {}
	w.dirty = true
}

@(private)
areas_toggle :: proc(w: ^Wizard, ctrl: Control) -> bool {
	a := &w.set.areas
	#partial switch ctrl {
	case .Area_Number:
		a.number = !a.number
		set_edit(w, "linux.indicator.showNumber", json.Boolean(a.number))
	case .Area_Bar_Icons:
		a.bar_icons = !a.bar_icons
		set_edit(w, "bar.workspaceIcons", json.Boolean(a.bar_icons))
	case:
		return false
	}
	return true
}

@(private)
draw_areas_section :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	if w.set.areas.picking >= 0 {
		draw_area_icon_picker(w, cv, c)
		return
	}
	th := &w.theme
	s := &w.set
	a := &s.areas
	// The areas in two columns: number, icon button, name.
	gap: i32 = 24
	col_w := (c.w - gap) / 2
	y := c.y
	for n, i in w.areas {
		col := i32(i % 2)
		if col == 0 && i > 0 { y += SET_ROW_H }
		if y + SET_ROW_H > c.y + c.h { break }
		cell := tx.Rect{c.x + col * (col_w + gap), y, col_w, SET_ROW_H}
		cy := cell.y + cell.h / 2
		num := fmt.tprintf("%d", n)
		text(w, w.f_h2, cell.x, cell.y, cell.h, num, mix(th.fg, th.muted, 0.45))
		b := tx.Rect{cell.x + 30, cy - AREA_ICON_BUTTON / 2, AREA_ICON_BUTTON, AREA_ICON_BUTTON}
		hot := hovered(w, .Area_Icon, i)
		glyph := area_icon_text(w, w.f_icon, a.icons[i])
		fill_rounded(cv, b, f32(b.h) / 2, hot ? mix(th.field, th.hover, 0.6) : th.field)
		tx.canvas_stroke_rounded_rect(cv, b, f32(b.h) / 2, 1, glyph != "" ? th.outline : mix(th.outline, th.bg, 0.3))
		if glyph != "" {
			text_centered(w, w.f_icon, b, glyph, th.fg)
		} else {
			icon(w, w.f_icon_small, b, .Plus, th.muted)
		}
		add_hit(w, b, .Area_Icon, i)
		field := tx.Rect{b.x + b.w + 10, cy - 20, cell.x + cell.w - (b.x + b.w + 10), 40}
		target := int(Control.Area_Name) * 100 + i
		draw_field(w, cv, field, .None, string(s.names[i][:]), fmt.tprintf(tr(w, "Área %d", "Area %d"), n),
		           w.focus == .Text && s.text_target == target, .Text_Field, target)
	}
	y += SET_ROW_H + 18

	// The toast and the bar.
	text(w, w.f_tiny, c.x, y, 18, tr(w, "AVISO DE ÁREA E BARRA", "AREA TOAST AND BAR"), th.muted)
	y += 22
	if y + SET_ROW_H > c.y + c.h + 8 { return }
	row := next_row(w, cv, c, &y, fmt.tprintf(tr(w, "Mostrar “%s” antes do nome", "Show “%s” before the name"), tr(w, "ÁREA N", "AREA N")),
	                tr(w, "No aviso ao trocar de área. Uma área sem nome sempre mostra o número.", "In the toast when the area changes. An area without a name always shows its number."))
	toggle(w, cv, row, a.number, .Area_Number)
	if y + SET_ROW_H > c.y + c.h + 8 { return }
	row = next_row(w, cv, c, &y, tr(w, "Ícones na barra", "Icons on the bar"),
	               tr(w, "As áreas com ícone o mostram no lugar do ponto", "Areas with an icon show it instead of their dot"))
	toggle(w, cv, row, a.bar_icons, .Area_Bar_Icons)
}

// The icon grid for one area: "none" first, then config.AREA_ICONS.
@(private)
draw_area_icon_picker :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	th := &w.theme
	a := &w.set.areas
	back := tr(w, "Voltar", "Back")
	bw := button_width(w, back, .Arrow_Left)
	button(w, cv, {c.x, c.y, bw, BUTTON_H}, back, .Text, .Area_Icon_Back, 0, .Arrow_Left)
	n := w.areas[a.picking]
	title := fmt.tprintf(tr(w, "Ícone da área %d", "Icon of area %d"), n)
	if name := strings.trim_space(string(w.set.names[a.picking][:])); name != "" { title = fmt.tprintf("%s · %s", title, name) }
	text(w, w.f_h2, c.x + bw + 16, c.y, BUTTON_H, ellipsize(w, w.f_h2, title, c.w - bw - 16), th.fg)

	top := c.y + BUTTON_H + 20
	draw_icon_grid(w, cv, {c.x, top, c.w, c.y + c.h - top}, a.icons[a.picking], .Area_Icon_Pick)
}

// The icon choices in a grid: "none" (arg -1), then config.AREA_ICONS (arg =
// their index); `current` is highlighted. Shared with the script widgets' editor.
@(private)
draw_icon_grid :: proc(w: ^Wizard, cv: ^tx.Canvas, area: tx.Rect, current: string, action: Action) {
	th := &w.theme
	gap: i32 = 10
	cols := max(i32(4), (area.w + gap) / (AREA_ICON_TILE + gap))
	left := area.x + (area.w - (cols * AREA_ICON_TILE + (cols - 1) * gap)) / 2
	for k in -1 ..< len(config.AREA_ICONS) {
		slot := i32(k + 1)
		t := tx.Rect{left + (slot % cols) * (AREA_ICON_TILE + gap), area.y + (slot / cols) * (AREA_ICON_TILE + gap), AREA_ICON_TILE, AREA_ICON_TILE}
		if t.y + t.h > area.y + area.h + 8 { break }
		glyph := ""
		if k >= 0 {
			glyph = area_icon_text(w, w.f_icon, config.AREA_ICONS[k].name)
			if glyph == "" { continue } // not in this font
		}
		sel := k >= 0 ? config.AREA_ICONS[k].name == current : current == ""
		hot := hovered(w, action, k)
		fill := th.field
		if sel { fill = th.accent } else if hot { fill = th.hover }
		fill_rounded(cv, t, 14, fill)
		fg := sel ? th.accent_fg : th.fg
		if k < 0 {
			icon(w, w.f_icon_small, t, .X, sel ? th.accent_fg : th.muted)
		} else {
			text_centered(w, w.f_icon, t, glyph, fg)
		}
		add_hit(w, t, action, k)
	}
}
