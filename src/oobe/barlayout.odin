// Settings → Barra: the tabs of the section (style, layout presets, widgets),
// the layout presets with a preview of each bar, and the widget editor that
// rewrites bar.start / bar.center / bar.end.
package oobe

import "core:encoding/json"
import "core:fmt"
import tx "../tx"

// The widgets the bar draws (bar/layout.odin), as the editor lists them.
@(private)
Bar_Widget_Info :: struct {
	id:     string,
	icon:   Icon,
	pt, en: string,
}

@(private, rodata)
BAR_WIDGET_INFO := []Bar_Widget_Info{
	{"launcher", .Milk, "Lançador", "Launcher"},
	{"active_window", .App_Window, "Janela ativa", "Active window"},
	{"workspaces", .Layout_Grid, "Áreas", "Workspaces"},
	{"tasks", .Box_Multiple, "Janelas abertas", "Open windows"},
	{"media", .Player_Play, "Mídia", "Media"},
	{"clipboard", .Clipboard, "Transferência", "Clipboard"},
	{"network", .Wifi, "Rede", "Network"},
	{"bluetooth", .Bluetooth, "Bluetooth", "Bluetooth"},
	{"volume", .Volume, "Volume", "Volume"},
	{"brightness", .Sun, "Brilho", "Brightness"},
	{"battery", .Battery, "Bateria", "Battery"},
	{"date", .Calendar, "Data", "Date"},
	{"clock", .Clock, "Relógio", "Clock"},
	{"notifications", .Bell, "Notificações", "Notifications"},
	{"settings", .Settings, "Ajustes rápidos", "Quick settings"},
	{"session", .Power, "Sessão", "Session"},
	{"spacer", .Space, "Espaço", "Spacer"},
}

@(private) SPACER_WIDGET :: 16 // index of "spacer" in BAR_WIDGET_INFO (may be used any number of times)

// A ready-made arrangement; position/style "" keep the current ones.
@(private)
Bar_Layout_Preset :: struct {
	pt, en:             string,
	desc_pt, desc_en:   string,
	start, center, end: []string,
	position, style:    string,
}

@(private, rodata)
BAR_LAYOUT_PRESETS := []Bar_Layout_Preset{
	{"milk", "milk", "O padrão: título à esquerda, áreas no centro", "The default: title left, areas centred",
	 {"launcher", "active_window"}, {"workspaces", "media"},
	 {"clipboard", "network", "bluetooth", "volume", "brightness", "battery", "date", "clock", "notifications", "settings", "session"}, "", ""},
	{"Mínimo", "Minimal", "Só áreas, relógio e o essencial", "Just areas, the clock and the essentials",
	 {"workspaces"}, {"clock"}, {"network", "volume", "battery", "session"}, "", ""},
	{"Clássico", "Classic", "Como no Windows: embaixo, relógio no canto", "Windows-like: bottom, clock in the corner",
	 {"launcher", "workspaces", "active_window"}, {},
	 {"clipboard", "network", "volume", "battery", "clock", "date", "notifications"}, "bottom", "full"},
	{"Centrado", "Centred", "Embaixo e flutuante, com o essencial no meio", "Floating at the bottom, essentials in the middle",
	 {"workspaces"}, {"launcher", "active_window", "media"},
	 {"network", "volume", "battery", "clock", "notifications", "session"}, "bottom", "floating"},
	{"macOS", "macOS", "No topo, com relógio e ajustes à direita", "At the top, clock and settings on the right",
	 {"launcher", "active_window"}, {},
	 {"workspaces", "media", "network", "bluetooth", "volume", "battery", "notifications", "settings", "date", "clock"}, "top", "full"},
}

@(private)
Layout_Editor :: struct {
	loaded:   bool,
	zones:    [3][dynamic]int, // start, center, end: indexes into BAR_WIDGET_INFO
	sel_zone: int,             // 0..2 a zone, 3 the available widgets
	sel:      int,             // row in that list, -1 = nothing selected
	dirty:    bool,            // write bar.start/center/end on the next save
	scroll:   [4]i32,
}

@(private)
widget_index :: proc(id: string) -> int {
	for info, i in BAR_WIDGET_INFO { if info.id == id { return i } }
	return -1
}

@(private)
lay_load :: proc(w: ^Wizard) {
	lay := &w.set.lay
	if lay.loaded { return }
	lay.loaded = true
	lay.sel = -1
	for ids, z in ([3][]string{w.cfg.bar.start, w.cfg.bar.center, w.cfg.bar.end}) {
		for id in ids {
			// Ids the bar does not draw ("recorder") are dropped.
			if i := widget_index(id); i >= 0 { append(&lay.zones[z], i) }
		}
	}
}

@(private)
lay_destroy :: proc(w: ^Wizard) {
	for &z in w.set.lay.zones { delete(z) }
}

// Widgets not on the bar yet (the spacer always).
@(private)
lay_available :: proc(w: ^Wizard) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for _, i in BAR_WIDGET_INFO {
		used := false
		if i != SPACER_WIDGET {
			for z in w.set.lay.zones {
				for v in z { if v == i { used = true } }
			}
		}
		if !used { append(&out, i) }
	}
	return out[:]
}

@(private)
lay_json :: proc(w: ^Wizard, zone: int) -> json.Array {
	arr := make(json.Array, 0, len(w.set.lay.zones[zone]), context.temp_allocator)
	for i in w.set.lay.zones[zone] { append(&arr, json.String(BAR_WIDGET_INFO[i].id)) }
	return arr
}

@(private)
preset_matches :: proc(w: ^Wizard, p: Bar_Layout_Preset) -> bool {
	for ids, z in ([3][]string{p.start, p.center, p.end}) {
		zone := w.set.lay.zones[z]
		if len(ids) != len(zone) { return false }
		for id, k in ids { if BAR_WIDGET_INFO[zone[k]].id != id { return false } }
	}
	if p.position != "" && (p.position == "top") != w.bar_top { return false }
	if p.style != "" && (p.style == "floating") != w.bar_floating { return false }
	return true
}

@(private)
lay_changed :: proc(w: ^Wizard) {
	w.set.lay.dirty = true
	settings_changed(w, .Values)
}

@(private)
lay_apply_preset :: proc(w: ^Wizard, index: int) {
	if index < 0 || index >= len(BAR_LAYOUT_PRESETS) { return }
	lay := &w.set.lay
	p := BAR_LAYOUT_PRESETS[index]
	for ids, z in ([3][]string{p.start, p.center, p.end}) {
		clear(&lay.zones[z])
		for id in ids { if i := widget_index(id); i >= 0 { append(&lay.zones[z], i) } }
	}
	lay.sel = -1
	lay.scroll = {}
	if p.position != "" || p.style != "" {
		if p.position != "" { w.bar_top = p.position == "top" }
		if p.style != "" { w.bar_floating = p.style == "floating" }
		settings_changed(w, .Bar_Layout)
	}
	lay_changed(w)
}

@(private)
layout_action :: proc(w: ^Wizard, action: Action, arg: int) {
	s := &w.set
	lay := &s.lay
	#partial switch action {
	case .Bar_Tab:
		s.bar_tab = clamp(arg, 0, 2)
		w.hover = {}
	case .Bar_Preset:
		lay_apply_preset(w, arg)
	case .Lw_Select:
		zone, row := arg / 1000, arg % 1000
		if lay.sel_zone == zone && lay.sel == row {
			lay.sel = -1 // a second click deselects
		} else {
			lay.sel_zone, lay.sel = zone, row
		}
	case .Lw_Move:
		if lay.sel_zone > 2 || lay.sel < 0 || lay.sel >= len(lay.zones[lay.sel_zone]) { return }
		z := &lay.zones[lay.sel_zone]
		switch arg {
		case 0, 1: // up / down within the zone
			to := lay.sel + (arg == 0 ? -1 : 1)
			if to < 0 || to >= len(z) { return }
			z[lay.sel], z[to] = z[to], z[lay.sel]
			lay.sel = to
		case 2, 3: // to the zone on the left (its end) / on the right (its start)
			dest := lay.sel_zone + (arg == 2 ? -1 : 1)
			if dest < 0 || dest > 2 { return }
			v := z[lay.sel]
			ordered_remove(z, lay.sel)
			if arg == 2 {
				append(&lay.zones[dest], v)
				lay.sel = len(lay.zones[dest]) - 1
			} else {
				inject_at(&lay.zones[dest], 0, v)
				lay.sel = 0
			}
			lay.sel_zone = dest
		case:
			return
		}
		lay_changed(w)
	case .Lw_Remove:
		if lay.sel_zone > 2 || lay.sel < 0 || lay.sel >= len(lay.zones[lay.sel_zone]) { return }
		ordered_remove(&lay.zones[lay.sel_zone], lay.sel)
		lay.sel = -1
		lay_changed(w)
	case .Lw_Add:
		avail := lay_available(w)
		if lay.sel_zone != 3 || lay.sel < 0 || lay.sel >= len(avail) || arg < 0 || arg > 2 { return }
		append(&lay.zones[arg], avail[lay.sel])
		lay.sel_zone, lay.sel = arg, len(lay.zones[arg]) - 1
		lay_changed(w)
	}
	w.dirty = true
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------
// The tab strip of the section; returns the area under it.
@(private)
draw_bar_tabs :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) -> tx.Rect {
	lay_load(w)
	segmented(w, cv, {c.x, c.y, min(i32(460), c.w), 40}, {tr(w, "Estilo", "Style"), tr(w, "Modelos", "Layouts"), tr(w, "Widgets", "Widgets")},
	          {.Layout_Top, .Layout_Dashboard, .Apps}, w.set.bar_tab, .Bar_Tab)
	return {c.x, c.y + 54, c.w, c.h - 54}
}

// A little bar: the widgets of `zones` placed like the real bar does (start
// on the left, end on the right, center in the middle), on `desk`.
@(private)
draw_bar_strip :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect, zones: [3][]int, floating: bool, desk: tx.Color, corner: f32 = 0) {
	th := &w.theme
	if r.w < 40 || r.h < 12 { return }
	sub := tx.canvas_make(r.w, r.h, context.temp_allocator)
	tx.canvas_fill(&sub, desk)
	fill_rounded(&sub, {0, 0, r.w, r.h}, floating ? f32(r.h) / 2 : 0, th.bg)
	// Mode 0: titles and date as text; 1: no titles; 2: compact (narrow slots, date as an icon).
	Strip_Mode :: struct { slot, gap: i32, titles, date_text: bool }
	full_slot := min(r.h - 6, i32(24))
	modes := [3]Strip_Mode{{full_slot, 5, true, true}, {full_slot, 5, false, true}, {min(full_slot, 18), 1, false, false}}
	title := tr(w, "Terminal", "Terminal")
	song := tr(w, "Música", "Music")
	width_of :: proc(w: ^Wizard, id: string, m: Strip_Mode, title, song: string) -> i32 {
		switch id {
		case "spacer":        return m.gap == 1 ? 4 : 8
		case "workspaces":    return m.gap == 1 ? 34 : 44
		case "active_window": return m.titles ? m.slot + 2 + text_width(w, w.f_small, title) : m.slot
		case "tasks":         return task_pill_width(w, m.slot, m.titles, title) + 2 + m.slot
		case "media":         return m.titles ? m.slot + 2 + text_width(w, w.f_small, song) : m.slot
		case "date":          return m.date_text ? text_width(w, w.f_small, "seg 29") + 4 : m.slot
		case "clock":         return text_width(w, w.f_small, "12:30") + 4
		}
		return m.slot
	}
	m: Strip_Mode
	widths: [3]i32
	for mode in modes {
		m = mode
		widths = {}
		for z, k in zones {
			for i, n in z {
				if n > 0 { widths[k] += m.gap }
				widths[k] += width_of(w, BAR_WIDGET_INFO[i].id, m, title, song)
			}
		}
		if widths[0] + widths[1] + widths[2] + 4 * 5 + 20 <= r.w { break }
	}
	slot := m.slot
	cy := r.h / 2
	for z, k in zones {
		x: i32
		switch k {
		case 0: x = 10
		case 1: x = clamp((r.w - widths[1]) / 2, 10 + widths[0] + 10, max(r.w - 10 - widths[2] - 10 - widths[1], 10))
		case:   x = r.w - 10 - widths[2]
		}
		for i, n in z {
			if n > 0 { x += m.gap }
			info := BAR_WIDGET_INFO[i]
			ww := width_of(w, info.id, m, title, song)
			win := tx.Rect{r.x + x, r.y, ww, r.h}
			switch {
			case info.id == "spacer":
			case info.id == "launcher":
				tx.canvas_fill_circle(&sub, f32(x) + f32(slot) / 2, f32(cy), f32(slot) / 2 - 1, th.accent)
				icon(w, w.f_icon_small, {win.x, win.y, slot, win.h}, .Milk, th.accent_fg, r)
			case info.id == "tasks":
				// Two windows: the active one (with its title) and another.
				pw := task_pill_width(w, slot, m.titles, title)
				fill_rounded(&sub, {x, cy - slot / 2, pw, slot}, f32(slot) / 2, th.accent)
				icon(w, w.f_icon_small, {win.x, win.y, slot, win.h}, .App_Window, th.accent_fg, r)
				if m.titles { text(w, w.f_small, win.x + slot, win.y, win.h, title, th.accent_fg, r) }
				fill_rounded(&sub, {x + pw + 2, cy - slot / 2, slot, slot}, f32(slot) / 2, th.surface)
				icon(w, w.f_icon_small, {win.x + pw + 2, win.y, slot, win.h}, .App_Window, mix(th.fg, th.muted, 0.15), r)
			case info.id == "workspaces":
				fill_rounded(&sub, {x + 2, cy - 3, 14, 6}, 3, th.accent)
				step: i32 = m.gap == 1 ? 6 : 8
				for d in 0 ..< 3 { tx.canvas_fill_circle(&sub, f32(x + 21 + i32(d) * step), f32(cy), 2.5, mix(th.muted, th.bg, 0.2)) }
			case info.id == "clock" || (info.id == "date" && m.date_text):
				text(w, w.f_small, win.x + 2, win.y, win.h, info.id == "date" ? "seg 29" : "12:30", th.fg, r)
			case:
				icon(w, w.f_icon_small, {win.x, win.y, slot, win.h}, info.icon, mix(th.fg, th.muted, 0.15), r)
				if m.titles && (info.id == "active_window" || info.id == "media") {
					text(w, w.f_small, win.x + slot + 2, win.y, win.h, info.id == "media" ? song : title, th.fg, r)
				}
			}
			x += ww
		}
	}
	composite_rounded(cv, sub, r.x, r.y, corner)
}

// The active task's pill in the preview: its icon, and its title in the roomier modes.
@(private)
task_pill_width :: proc(w: ^Wizard, slot: i32, titles: bool, title: string) -> i32 {
	return titles ? slot + text_width(w, w.f_small, title) + 6 : slot
}

@(private)
zone_slices :: proc(w: ^Wizard) -> [3][]int {
	z := &w.set.lay.zones
	return {z[0][:], z[1][:], z[2][:]}
}

@(private)
draw_layout_presets :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	th := &w.theme
	n := i32(len(BAR_LAYOUT_PRESETS))
	gap: i32 = 10
	row_h := min(i32(84), (c.h - (n - 1) * gap) / n)
	desk := mix(th.surface, th.accent, 0.28)
	for p, i in BAR_LAYOUT_PRESETS {
		r := tx.Rect{c.x, c.y + i32(i) * (row_h + gap), c.w, row_h}
		selected := preset_matches(w, p)
		hot := hovered(w, .Bar_Preset, i)
		fill_rounded(cv, r, 18, hot && !selected ? th.hover : th.field)
		if selected { tx.canvas_stroke_rounded_rect(cv, {r.x + 1, r.y + 1, r.w - 2, r.h - 2}, 17, 2, th.accent) }
		info_w := min(i32(200), r.w / 3)
		text(w, w.f_h2, r.x + 18, r.y + r.h / 2 - 24, 26, tr(w, p.pt, p.en), selected ? th.accent : th.fg)
		text(w, w.f_small, r.x + 18, r.y + r.h / 2 + 2, 20, ellipsize(w, w.f_small, tr(w, p.desc_pt, p.desc_en), info_w - 24), mix(th.fg, th.muted, 0.55))
		// The preview: a strip of desktop with the bar where the preset puts it.
		top := p.position == "" ? w.bar_top : p.position == "top"
		floating := p.style == "" ? w.bar_floating : p.style == "floating"
		pv := tx.Rect{r.x + info_w, r.y + 10, r.w - info_w - (selected ? 52 : 16), r.h - 20}
		fill_rounded(cv, pv, floating ? 12 : 5, desk)
		bh := min(i32(30), pv.h - 12)
		inset: i32 = floating ? 6 : 0
		bar := tx.Rect{pv.x + inset, top ? pv.y + inset : pv.y + pv.h - inset - bh, pv.w - 2 * inset, bh}
		zones: [3][]int
		for ids, z in ([3][]string{p.start, p.center, p.end}) {
			list := make([dynamic]int, context.temp_allocator)
			for id in ids { if k := widget_index(id); k >= 0 { append(&list, k) } }
			zones[z] = list[:]
		}
		draw_bar_strip(w, cv, bar, zones, floating, desk, floating ? 0 : 5)
		if selected { check_badge(w, cv, r.x + r.w - 26, r.y + r.h / 2, 12) }
		add_hit(w, r, .Bar_Preset, i)
	}
}

// A round icon button (disabled: drawn faint, no hit).
@(private)
icon_button :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect, ic: Icon, action: Action, arg: int, enabled: bool) {
	th := &w.theme
	if enabled && hovered(w, action, arg) {
		fill_rounded(cv, r, f32(r.h) / 2, th.hover)
	} else {
		fill_rounded(cv, r, f32(r.h) / 2, th.field)
	}
	icon(w, w.f_icon_small, r, ic, enabled ? th.fg : mix(th.muted, th.bg, 0.4))
	if enabled { add_hit(w, r, action, arg) }
}

@(private)
draw_widget_editor :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	th := &w.theme
	lay := &w.set.lay
	// Live preview of the bar being edited.
	desk := mix(th.surface, th.accent, 0.28)
	pv := tx.Rect{c.x, c.y, c.w, 46}
	fill_rounded(cv, pv, 14, desk)
	draw_bar_strip(w, cv, {pv.x + 8, pv.y + 7, pv.w - 16, 32}, zone_slices(w), w.bar_floating, desk)
	y := c.y + 46 + 16

	avail := lay_available(w)
	if lay.sel_zone == 3 && lay.sel >= len(avail) { lay.sel = -1 }
	if lay.sel_zone < 3 && lay.sel >= len(lay.zones[lay.sel_zone]) { lay.sel = -1 }
	gap: i32 = 12
	col_w := (c.w - 3 * gap) / 4
	toolbar_h: i32 = 40
	list_h := c.y + c.h - toolbar_h - 14 - (y + 24)
	titles := [4]string{tr(w, "INÍCIO", "START"), tr(w, "CENTRO", "CENTER"), tr(w, "FIM", "END"), tr(w, "DISPONÍVEIS", "AVAILABLE")}
	ids := [4]Scroll_Id{.Zone_Start, .Zone_Center, .Zone_End, .Zone_Avail}
	for k in 0 ..< 4 {
		x := c.x + i32(k) * (col_w + gap)
		items := k < 3 ? lay.zones[k][:] : avail
		text(w, w.f_tiny, x + 4, y, 20, titles[k], th.muted)
		count := fmt.tprintf("%d", len(items))
		text(w, w.f_tiny, x + col_w - 4 - text_width(w, w.f_tiny, count), y, 20, count, th.muted)
		lr := tx.Rect{x, y + 24, col_w, list_h}
		row_h: i32 = 36
		content_h := i32(len(items)) * row_h + 8
		sub := list_begin(w, lr, content_h, &lay.scroll[k], ids[k])
		for v, i in items {
			ry := 4 + i32(i) * row_h - lay.scroll[k]
			if ry + row_h < 0 { continue }
			if ry > lr.h { break }
			row := tx.Rect{5, ry, lr.w - 14, row_h - 4}
			arg := k * 1000 + i
			sel := lay.sel_zone == k && lay.sel == i
			if sel {
				fill_rounded(&sub, row, 11, th.accent)
			} else if hovered(w, .Lw_Select, arg) {
				fill_rounded(&sub, row, 11, th.hover)
			}
			fg := sel ? th.accent_fg : th.fg
			win := tx.Rect{lr.x + row.x, lr.y + row.y, row.w, row.h}
			info := BAR_WIDGET_INFO[v]
			icon(w, w.f_icon_small, {win.x + 6, win.y, 22, win.h}, info.icon, sel ? th.accent_fg : mix(th.fg, th.muted, 0.3), lr)
			text(w, w.f_body, win.x + 34, win.y, win.h, ellipsize(w, w.f_body, tr(w, info.pt, info.en), win.w - 40), fg, lr)
			add_hit(w, win, .Lw_Select, arg, lr)
		}
		if len(items) == 0 {
			text_centered(w, w.f_small, {lr.x, lr.y + 12, lr.w, 24}, k < 3 ? tr(w, "Vazio", "Empty") : tr(w, "Todos na barra", "All on the bar"), th.muted)
		}
		list_end(w, cv, &sub, lr, content_h, lay.scroll[k])
	}

	// Toolbar: what can be done with the selection.
	ty := c.y + c.h - toolbar_h
	x := c.x
	if lay.sel < 0 {
		text(w, w.f_small, x, ty, toolbar_h, ellipsize(w, w.f_small, tr(w, "Escolha um widget da barra para movê-lo ou removê-lo, ou um disponível para adicioná-lo.",
		                                                                   "Pick a widget on the bar to move or remove it, or an available one to add it."), c.w), th.muted)
	} else if lay.sel_zone == 3 {
		info := BAR_WIDGET_INFO[avail[lay.sel]]
		label := fmt.tprintf(tr(w, "Adicionar %s a:", "Add %s to:"), tr(w, info.pt, info.en))
		text(w, w.f_body, x, ty, toolbar_h, label, th.fg)
		x += text_width(w, w.f_body, label) + 14
		zone_names := [3]string{tr(w, "Início", "Start"), tr(w, "Centro", "Center"), tr(w, "Fim", "End")}
		for name, z in zone_names {
			bw := button_width(w, name, .Plus) - 16
			button(w, cv, {x, ty, bw, toolbar_h}, name, .Tonal, .Lw_Add, z, .Plus)
			x += bw + 8
		}
	} else {
		zone := lay.zones[lay.sel_zone]
		info := BAR_WIDGET_INFO[zone[lay.sel]]
		icon(w, w.f_icon_small, {x, ty, 22, toolbar_h}, info.icon, th.accent)
		name := ellipsize(w, w.f_h2, tr(w, info.pt, info.en), 180)
		text(w, w.f_h2, x + 28, ty, toolbar_h, name, th.fg)
		x += 28 + text_width(w, w.f_h2, name) + 16
		b: i32 = toolbar_h
		moves := [4]struct { ic: Icon, ok: bool }{
			{.Arrow_Up, lay.sel > 0}, {.Arrow_Down, lay.sel < len(zone) - 1},
			{.Arrow_Left, lay.sel_zone > 0}, {.Arrow_Right, lay.sel_zone < 2},
		}
		for m, k in moves {
			icon_button(w, cv, {x, ty, b, b}, m.ic, .Lw_Move, k, m.ok)
			x += b + 6
		}
		remove := tr(w, "Remover", "Remove")
		rw := button_width(w, remove, .Trash) - 16
		button(w, cv, {x + 6, ty, rw, toolbar_h}, remove, .Tonal, .Lw_Remove, 0, .Trash)
	}
}

// The wizard's bar page: the layouts as a segmented control under the
// position cards, with the chosen bar below.
@(private)
draw_wizard_layouts :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect) {
	lay_load(w)
	th := &w.theme
	text(w, w.f_tiny, r.x, r.y, 20, tr(w, "WIDGETS DA BARRA", "BAR WIDGETS"), th.muted)
	labels := make([dynamic]string, context.temp_allocator)
	current := -1
	for p, i in BAR_LAYOUT_PRESETS {
		append(&labels, tr(w, p.pt, p.en))
		if current < 0 && preset_matches(w, p) { current = i }
	}
	segmented(w, cv, {r.x, r.y + 24, min(r.w, 680), 40}, labels[:], {}, current, .Bar_Preset)
	desk := mix(th.surface, th.accent, 0.28)
	pv := tx.Rect{r.x, r.y + 24 + 40 + 12, r.w, 46}
	fill_rounded(cv, pv, 14, desk)
	draw_bar_strip(w, cv, {pv.x + 8, pv.y + 7, pv.w - 16, 32}, zone_slices(w), w.bar_floating, desk)
}
