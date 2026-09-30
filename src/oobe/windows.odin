// Settings → Janelas and → Área de trabalho: the window manager's mode
// (tiling or floating, wm.mode) with the options of each, and the desktop
// icons (linux.desktopIcons and the look shared with the area shortcuts,
// linux.shortcuts). The floating mode's options sit on tabs: general, the
// title bar (wm.titleBar) and behaviour (placement, snapping, focus).
package oobe

import "core:encoding/json"
import "core:fmt"
import tx "../tx"

@(private) PLACEMENT_NAMES :: [4]string{"smart", "center", "mouse", "cascade"}
@(private) SORT_NAMES :: [3]string{"name", "type", "modified"}
@(private) SHORTCUT_MODE_NAMES :: [3]string{"layer", "folder", "none"}

@(private)
windows_load_values :: proc(w: ^Wizard) {
	s := &w.set
	cfg := w.cfg
	tb := &cfg.wm.title_bar
	s.wm_floating = cfg.wm.mode == "floating"
	s.title_circles = tb.button_style == "circles"
	s.title_left = len(tb.layout) > 0 && tb.layout[0] != 'N' && tb.layout[0] != 'L'
	s.title_center = tb.align == "center"
	s.title_height = tb.height
	for name, i in PLACEMENT_NAMES { if name == cfg.wm.placement { s.placement = i } }
	s.snap_layouts = cfg.wm.snap_layouts
	s.snap_distance = cfg.wm.snap_distance
	s.raise_focus = cfg.wm.raise_on_focus
	di := &cfg.linux.desktop_icons
	s.di_enabled = di.enabled
	s.di_thumbs = di.thumbnails
	s.di_hidden = di.show_hidden
	for name, i in SORT_NAMES { if name == di.sort { s.di_sort = i } }
	s.di_size = cfg.linux.shortcuts.icon_size
	s.di_single = cfg.linux.shortcuts.single_click
	for name, i in SHORTCUT_MODE_NAMES { if name == cfg.linux.shortcuts.mode { s.sc_mode = i } }
}

// Settings → Janelas.
@(private)
draw_windows_section :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	s := &w.set
	y := c.y
	row := next_row(w, cv, c, &y, tr(w, "Modo", "Mode"),
	                s.wm_floating ? tr(w, "Janelas com barra de título, que você move e sobrepõe", "Windows with title bars that you move and overlap") :
	                                tr(w, "As janelas dividem a tela entre si", "Windows share the screen between them"))
	cw := min(i32(360), row.w / 2)
	choice_control(w, cv, {row.x + row.w - cw, row.y + 8, cw, 40}, {tr(w, "Lado a lado", "Tiling"), tr(w, "Flutuante", "Floating")},
	               s.wm_floating ? 1 : 0, .Wm_Mode)
	if !s.wm_floating {
		rows_windows(w, cv, c, &y)
		return
	}
	y += 10
	segmented(w, cv, {c.x, y, min(i32(520), c.w), 40},
	          {tr(w, "Geral", "General"), tr(w, "Barra de título", "Title bar"), tr(w, "Comportamento", "Behaviour")},
	          {.App_Window, .Layout_Top, .Sparkles}, s.win_tab, .Win_Tab)
	y += 54
	switch s.win_tab {
	case 1: rows_title_bar(w, cv, c, &y)
	case 2: rows_behaviour(w, cv, c, &y)
	case:   rows_floating_general(w, cv, c, &y)
	}
}

@(private)
rows_floating_general :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect, y: ^i32) {
	s := &w.set
	row := next_row(w, cv, c, y, tr(w, "Margem", "Margin"), tr(w, "Em volta das janelas maximizadas e encaixadas", "Around maximized and snapped windows"))
	stepper(w, cv, row, fmt.tprintf("%d px", s.gaps), .Wm_Gaps)
	row = next_row(w, cv, c, y, tr(w, "Borda das janelas", "Window borders"), tr(w, "Cor da janela em foco: destaque do tema", "Focused window: the theme accent"))
	stepper(w, cv, row, fmt.tprintf("%d px", s.border), .Wm_Border)
	row = next_row(w, cv, c, y, tr(w, "Cantos arredondados", "Rounded corners"), tr(w, "Raio dos cantos das janelas", "Radius of the window corners"))
	stepper(w, cv, row, s.corner_radius == 0 ? tr(w, "Desligado", "Off") : fmt.tprintf("%d px", s.corner_radius), .Wm_Corners)
	row = next_row(w, cv, c, y, tr(w, "Animação das janelas", "Window animation"), tr(w, "Duração ao abrir, mover e redimensionar", "Duration when opening, moving and resizing"))
	stepper(w, cv, row, s.animation_ms == 0 ? tr(w, "Desligada", "Off") : fmt.tprintf("%d ms", s.animation_ms), .Wm_Animation)
}

@(private)
rows_title_bar :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect, y: ^i32) {
	s := &w.set
	cw := min(i32(360), c.w / 2)
	row := next_row(w, cv, c, y, tr(w, "Botões", "Buttons"), "")
	choice_control(w, cv, {row.x + row.w - cw, row.y + 8, cw, 40}, {tr(w, "Ícones", "Icons"), tr(w, "Círculos", "Circles")},
	               s.title_circles ? 1 : 0, .Wm_Title_Style)
	row = next_row(w, cv, c, y, tr(w, "Lado dos botões", "Button side"), "")
	choice_control(w, cv, {row.x + row.w - cw, row.y + 8, cw, 40}, {tr(w, "Direita", "Right"), tr(w, "Esquerda", "Left")},
	               s.title_left ? 1 : 0, .Wm_Title_Side)
	row = next_row(w, cv, c, y, tr(w, "Título", "Title"), "")
	choice_control(w, cv, {row.x + row.w - cw, row.y + 8, cw, 40}, {tr(w, "À esquerda", "Left"), tr(w, "Centralizado", "Centred")},
	               s.title_center ? 1 : 0, .Wm_Title_Align)
	row = next_row(w, cv, c, y, tr(w, "Altura", "Height"), "")
	stepper(w, cv, row, fmt.tprintf("%d px", s.title_height), .Wm_Title_Height)
	if y^ + 60 <= c.y + c.h { draw_title_preview(w, cv, {c.x, y^ + 14, min(c.w, 460), i32(s.title_height) + 44}) }
}

// A small window with the title bar as configured.
@(private)
draw_title_preview :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect) {
	th := &w.theme
	s := &w.set
	bar_h := i32(s.title_height)
	fill_rounded(cv, r, 10, th.surface)
	fill_rounded(cv, {r.x, r.y, r.w, bar_h + 10}, 10, th.bg)
	tx.canvas_fill_rect(cv, {r.x, r.y + bar_h, r.w, 10}, th.surface) // square lower edge
	tx.canvas_fill_rect(cv, {r.x, r.y + bar_h, r.w, 1}, th.outline)
	cy := f32(r.y) + f32(bar_h) / 2
	bw := s.title_circles ? f32(22) : f32(bar_h)
	xs: [3]f32
	for i in 0 ..< 3 {
		if s.title_left {
			xs[i] = f32(r.x) + 8 + bw * (f32(i) + 0.5)
		} else {
			xs[i] = f32(r.x + r.w) - 8 - bw * (f32(2 - i) + 0.5)
		}
	}
	// Order: close, minimize, maximize on the left (like macOS); minimize, maximize, close on the right.
	letters := s.title_left ? [3]u8{'C', 'I', 'M'} : [3]u8{'I', 'M', 'C'}
	for l, i in letters {
		x := xs[i]
		if s.title_circles {
			col := tx.rgb(0xFF, 0x5F, 0x57)
			if l == 'I' { col = tx.rgb(0xFE, 0xBC, 0x2E) }
			if l == 'M' { col = tx.rgb(0x28, 0xC8, 0x40) }
			tx.canvas_fill_circle(cv, x, cy, 6.5, col)
			continue
		}
		g: f32 = 5
		switch l {
		case 'C':
			tx.canvas_stroke_line(cv, x - g, cy - g, x + g, cy + g, 1.5, th.fg)
			tx.canvas_stroke_line(cv, x - g, cy + g, x + g, cy - g, 1.5, th.fg)
		case 'I':
			tx.canvas_stroke_line(cv, x - g, cy, x + g, cy, 1.5, th.fg)
		case 'M':
			tx.canvas_stroke_rounded_rect(cv, {i32(x - g), i32(cy - g), i32(2 * g), i32(2 * g)}, 1.5, 1.5, th.fg)
		}
	}
	title := tr(w, "Documento — Editor", "Document — Editor")
	tw := text_width(w, w.f_small, title)
	tx0 := s.title_left ? r.x + 8 + i32(3 * bw) + 10 : r.x + 14
	if s.title_center { tx0 = r.x + (r.w - tw) / 2 }
	text(w, w.f_small, tx0, r.y, bar_h, title, th.fg)
}

@(private)
rows_behaviour :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect, y: ^i32) {
	s := &w.set
	row := next_row(w, cv, c, y, tr(w, "Novas janelas", "New windows"), tr(w, "Onde as janelas aparecem", "Where windows appear"))
	cw := min(i32(470), c.w - 220)
	choice_control(w, cv, {row.x + row.w - cw, row.y + 8, cw, 40},
	               {tr(w, "Livre", "Free space"), tr(w, "Centro", "Centre"), tr(w, "Mouse", "Pointer"), tr(w, "Cascata", "Cascade")},
	               s.placement, .Wm_Placement)
	row = next_row(w, cv, c, y, tr(w, "Encaixar nas bordas", "Snap to edges"), tr(w, "Arrastar até a borda: metade, quarto ou maximizada", "Drag to an edge: half, quarter or maximized"))
	toggle(w, cv, row, s.snap_layouts, .Wm_Snap_Layouts)
	row = next_row(w, cv, c, y, tr(w, "Resistência", "Resistance"), tr(w, "Janelas grudam nas bordas e umas nas outras", "Windows stick to the edges and to each other"))
	stepper(w, cv, row, s.snap_distance == 0 ? tr(w, "Desligada", "Off") : fmt.tprintf("%d px", s.snap_distance), .Wm_Snap_Distance)
	row = next_row(w, cv, c, y, tr(w, "Foco segue o mouse", "Focus follows mouse"), tr(w, "Focar a janela sob o ponteiro", "Focus the window under the pointer"))
	toggle(w, cv, row, s.focus_follows, .Wm_Focus_Follows)
	row = next_row(w, cv, c, y, tr(w, "Trazer para frente ao focar", "Raise on focus"), tr(w, "Com o foco seguindo o mouse", "With focus following the mouse"), !s.focus_follows)
	toggle(w, cv, row, s.raise_focus, .Wm_Raise_Focus)
}

// Settings → Área de trabalho.
@(private)
rows_desktop :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect, y: ^i32) {
	s := &w.set
	row := next_row(w, cv, c, y, tr(w, "Arquivos na área de trabalho", "Files on the desktop"), tr(w, "O conteúdo da pasta Área de trabalho, como ícones", "What the Desktop folder holds, as icons"))
	toggle(w, cv, row, s.di_enabled, .Di_Enabled)
	cw := min(i32(420), c.w - 260)
	row = next_row(w, cv, c, y, tr(w, "Atalhos das áreas", "Area shortcuts"), tr(w, "Os atalhos de cada área", "The shortcuts of each area"))
	choice_control(w, cv, {row.x + row.w - cw, row.y + 8, cw, 40}, {tr(w, "Ícones", "Icons"), tr(w, "Na pasta", "In the folder"), tr(w, "Ocultos", "Hidden")},
	               s.sc_mode, .Di_Shortcut_Mode)
	row = next_row(w, cv, c, y, tr(w, "Tamanho dos ícones", "Icon size"), "")
	stepper(w, cv, row, fmt.tprintf("%d px", s.di_size), .Di_Size)
	row = next_row(w, cv, c, y, tr(w, "Abrir com um clique", "Open with one click"), "")
	toggle(w, cv, row, s.di_single, .Di_Single)
	off := !s.di_enabled
	row = next_row(w, cv, c, y, tr(w, "Miniaturas de imagens", "Image thumbnails"), "", off)
	toggle(w, cv, row, s.di_thumbs, .Di_Thumbs)
	row = next_row(w, cv, c, y, tr(w, "Arquivos ocultos", "Hidden files"), "", off)
	toggle(w, cv, row, s.di_hidden, .Di_Hidden)
	row = next_row(w, cv, c, y, tr(w, "Organizar por", "Arrange by"), tr(w, "Para ícones que ainda não têm lugar", "For icons without a place yet"), off)
	choice_control(w, cv, {row.x + row.w - cw, row.y + 8, cw, 40}, {tr(w, "Nome", "Name"), tr(w, "Tipo", "Type"), tr(w, "Data", "Date")},
	               s.di_sort, .Di_Sort)
}

// ---------------------------------------------------------------------------
// Changes
// ---------------------------------------------------------------------------
@(private)
windows_choice :: proc(w: ^Wizard, ctrl: Control, opt: int) -> bool {
	s := &w.set
	#partial switch ctrl {
	case .Wm_Mode:
		s.wm_floating = opt == 1
		set_edit(w, "wm.mode", json.String(s.wm_floating ? "floating" : "tiling"))
	case .Wm_Title_Style:
		s.title_circles = opt == 1
		set_edit(w, "wm.titleBar.buttonStyle", json.String(s.title_circles ? "circles" : "icons"))
	case .Wm_Title_Side:
		s.title_left = opt == 1
		set_edit(w, "wm.titleBar.layout", json.String(s.title_left ? "CIMLN" : "NLIMC"))
	case .Wm_Title_Align:
		s.title_center = opt == 1
		set_edit(w, "wm.titleBar.align", json.String(s.title_center ? "center" : "left"))
	case .Wm_Placement:
		names := PLACEMENT_NAMES
		s.placement = clamp(opt, 0, len(names) - 1)
		set_edit(w, "wm.placement", json.String(names[s.placement]))
	case .Di_Sort:
		names := SORT_NAMES
		s.di_sort = clamp(opt, 0, len(names) - 1)
		set_edit(w, "linux.desktopIcons.sort", json.String(names[s.di_sort]))
	case .Di_Shortcut_Mode:
		names := SHORTCUT_MODE_NAMES
		s.sc_mode = clamp(opt, 0, len(names) - 1)
		set_edit(w, "linux.shortcuts.mode", json.String(names[s.sc_mode]))
	case:
		return false
	}
	return true
}

@(private)
windows_toggle :: proc(w: ^Wizard, ctrl: Control) -> bool {
	s := &w.set
	#partial switch ctrl {
	case .Wm_Snap_Layouts:
		s.snap_layouts = !s.snap_layouts
		set_edit(w, "wm.snapLayouts", json.Boolean(s.snap_layouts))
	case .Wm_Raise_Focus:
		s.raise_focus = !s.raise_focus
		set_edit(w, "wm.raiseOnFocus", json.Boolean(s.raise_focus))
	case .Di_Enabled:
		s.di_enabled = !s.di_enabled
		set_edit(w, "linux.desktopIcons.enabled", json.Boolean(s.di_enabled))
	case .Di_Single:
		s.di_single = !s.di_single
		set_edit(w, "linux.shortcuts.singleClick", json.Boolean(s.di_single))
	case .Di_Thumbs:
		s.di_thumbs = !s.di_thumbs
		set_edit(w, "linux.desktopIcons.thumbnails", json.Boolean(s.di_thumbs))
	case .Di_Hidden:
		s.di_hidden = !s.di_hidden
		set_edit(w, "linux.desktopIcons.showHidden", json.Boolean(s.di_hidden))
	case:
		return false
	}
	return true
}

@(private)
windows_step :: proc(w: ^Wizard, ctrl: Control, dir: int) -> bool {
	s := &w.set
	#partial switch ctrl {
	case .Wm_Title_Height:
		s.title_height = clamp(s.title_height + 2 * dir, 24, 48)
		set_edit(w, "wm.titleBar.height", json.Integer(s.title_height))
	case .Wm_Snap_Distance:
		s.snap_distance = clamp(s.snap_distance + 4 * dir, 0, 48)
		set_edit(w, "wm.snapDistance", json.Integer(s.snap_distance))
	case .Di_Size:
		s.di_size = clamp(s.di_size + 8 * dir, 32, 96)
		set_edit(w, "linux.shortcuts.iconSize", json.Integer(s.di_size))
	case:
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Setup wizard: the Windows page
// ---------------------------------------------------------------------------

// Two cards (tiling, floating) with a miniature desktop each, and the switch
// for the files of the Desktop folder under them.
@(private)
draw_windows_page :: proc(w: ^Wizard, cv: ^tx.Canvas, area: tx.Rect) {
	th := &w.theme
	switch_h: i32 = 64
	gap: i32 = 28
	card_w := min((area.w - gap) / 2, i32(460))
	label_h: i32 = 66
	pw := card_w - 24
	ph := pw * w.monitor.h / max(w.monitor.w, 1)
	if ph + 24 + label_h > area.h - switch_h - 24 {
		ph = max(area.h - switch_h - 24 - 24 - label_h, 60)
		pw = ph * w.monitor.w / max(w.monitor.h, 1)
		card_w = pw + 24
	}
	card_h := ph + 24 + label_h
	total_w := 2 * card_w + gap
	x0 := area.x + (area.w - total_w) / 2
	y0 := area.y + max((area.h - card_h - switch_h - 24) / 2, 0) / 2
	Option :: struct { title, desc: string }
	options := [2]Option{
		{tr(w, "Lado a lado", "Tiling"), tr(w, "As janelas dividem a tela, sem se sobrepor", "Windows share the screen without overlapping")},
		{tr(w, "Flutuantes", "Floating"), tr(w, "Barra de título, arrastar, maximizar e encaixar", "Title bars, dragging, maximizing and snapping")},
	}
	for opt, i in options {
		r := tx.Rect{x0 + i32(i) * (card_w + gap), y0, card_w, card_h}
		selected := (i == 1) == w.wm_floating
		hot := hovered(w, .Wm_Choice, i)
		if selected || hot { shadow(cv, r, 20, 4, th.dark ? 26 : 12, 3) }
		tx.canvas_fill_rounded_rect(cv, r, 20, th.field)
		if selected {
			tx.canvas_stroke_rounded_rect(cv, {r.x - 3, r.y - 3, r.w + 6, r.h + 6}, 23, 2.5, th.accent)
		} else if hot {
			tx.canvas_stroke_rounded_rect(cv, r, 20, 1.5, th.outline)
		}
		p := tx.Rect{r.x + (r.w - pw) / 2, r.y + 12, pw, ph}
		if i == 0 {
			draw_mock(w, cv, p, &w.theme, area_choice(w, 0), w.bar_top, w.bar_floating, 12)
		} else {
			draw_float_mock(w, cv, p, area_choice(w, 0), w.desktop_icons)
		}
		if selected { check_badge(w, cv, p.x + p.w - 16, p.y + 16, 11) }
		text(w, w.f_h2, r.x + 18, p.y + p.h + 12, 26, ellipsize(w, w.f_h2, opt.title, r.w - 36), th.fg)
		text(w, w.f_small, r.x + 18, p.y + p.h + 38, 20, ellipsize(w, w.f_small, opt.desc, r.w - 36), mix(th.fg, th.muted, 0.6))
		add_hit(w, r, .Wm_Choice, i)
	}

	// The Desktop folder's files as icons.
	row := tx.Rect{x0, y0 + card_h + 28, total_w, switch_h}
	fill_rounded(cv, row, 18, th.field)
	icon(w, w.f_icon, {row.x + 16, row.y, 30, row.h}, .Desktop, th.accent)
	text(w, w.f_body, row.x + 58, row.y + 11, 22, tr(w, "Arquivos na área de trabalho", "Files on the desktop"), th.fg)
	text(w, w.f_small, row.x + 58, row.y + 33, 18,
	     ellipsize(w, w.f_small, tr(w, "Mostrar a pasta Área de trabalho como ícones sobre o papel de parede",
	                                   "Show the Desktop folder as icons over the wallpaper"), row.w - 150), mix(th.fg, th.muted, 0.55))
	on := w.desktop_icons
	track := tx.Rect{row.x + row.w - 66, row.y + (row.h - 28) / 2, 50, 28}
	hot := hovered(w, .Di_Choice, 0)
	fill_rounded(cv, track, 14, on ? th.accent : (hot ? th.hover : mix(th.surface, th.muted, 0.2)))
	if !on { tx.canvas_stroke_rounded_rect(cv, track, 14, 1.5, th.muted) }
	kx := on ? f32(track.x + track.w - 14) : f32(track.x + 14)
	tx.canvas_fill_circle(cv, kx, f32(track.y) + 14, on ? 10 : 7, on ? th.accent_fg : th.muted)
	add_hit(w, row, .Di_Choice, 0)
}

// A miniature of the floating mode: the wallpaper, the bar, desktop icons
// when enabled, and two overlapping windows with title bars.
@(private)
draw_float_mock :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect, wallpaper: int, icons: bool) {
	th := &w.theme
	sub := tx.canvas_make(r.w, r.h, context.temp_allocator)
	if img, ok := candidate_scaled(w, wallpaper, r.w, r.h); ok {
		tx.canvas_blit_image(&sub, img, 0, 0)
	} else if wallpaper >= 0 {
		tx.canvas_fill(&sub, th.field)
	} else {
		tx.canvas_fill(&sub, mix(th.bg, th.surface, 0.6))
	}
	s := f32(r.w) / f32(max(w.monitor.w, 1)) * 2
	bar_h := max(i32(f32(w.cfg.bar.height) * s), 9)
	margin: i32 = w.bar_floating ? max(i32(f32(w.cfg.bar.margin) * s), 4) : 0
	bar := tx.Rect{margin, w.bar_top ? margin : r.h - margin - bar_h, r.w - 2 * margin, bar_h}
	tx.canvas_fill_rounded_rect(&sub, bar, w.bar_floating ? f32(bar_h) / 2 : 0, tx.color_with_alpha(th.bg, 238))
	unit := max(f32(bar_h) / 9, 1)
	cy := f32(bar.y) + f32(bar_h) / 2
	tx.canvas_fill_circle(&sub, f32(bar.x) + 4 * unit + 2, cy, 1.6 * unit, th.accent)
	top := w.bar_top ? bar.y + bar.h : 0
	bottom := w.bar_top ? r.h : bar.y
	if icons {
		// A column of icons at the top-left.
		size := max(r.w / 22, 6)
		for k in 0 ..< 3 {
			y := top + size / 2 + i32(k) * (size + size * 3 / 4)
			tx.canvas_fill_rounded_rect(&sub, {size / 2, y, size, size}, f32(size) / 4, tx.color_with_alpha(th.bg, 225))
			tx.canvas_fill_rect(&sub, {size / 2 - 1, y + size + 2, size + 2, max(size / 6, 1)}, tx.color_with_alpha(th.bg, 200))
		}
	}
	title_h := max(i32(9 * unit), 7)
	rad := f32(max(r.w / 60, 3))
	wins := [2]tx.Rect{
		{r.w * 22 / 100, top + (bottom - top) * 14 / 100, r.w * 46 / 100, (bottom - top) * 56 / 100},
		{r.w * 44 / 100, top + (bottom - top) * 32 / 100, r.w * 44 / 100, (bottom - top) * 52 / 100},
	}
	for win, k in wins {
		active := k == 1
		if active { tx.canvas_fill_rounded_rect(&sub, {win.x + 2, win.y + 3, win.w, win.h}, rad, tx.rgba(0, 0, 0, 40)) }
		tx.canvas_fill_rounded_rect(&sub, win, rad, active ? th.bg : mix(th.bg, th.surface, 0.7))
		tx.canvas_fill_rect(&sub, {win.x, win.y + title_h, win.w, win.h - title_h - i32(rad)}, active ? mix(th.bg, th.surface, 0.35) : mix(th.bg, th.surface, 0.8))
		tx.canvas_fill_rounded_rect(&sub, {win.x, win.y + win.h - i32(2 * rad), win.w, i32(2 * rad)}, rad, active ? mix(th.bg, th.surface, 0.35) : mix(th.bg, th.surface, 0.8))
		tx.canvas_stroke_rounded_rect(&sub, win, rad, 1, mix(th.muted, th.bg, active ? 0.2 : 0.45))
		// Title and buttons.
		line := max(i32(unit), 1)
		tx.canvas_fill_rounded_rect(&sub, {win.x + 3 * line, win.y + title_h / 2 - line, win.w / 3, 2 * line}, f32(line), mix(th.fg, th.bg, active ? 0.3 : 0.6))
		for b in 0 ..< 3 {
			bx := f32(win.x + win.w) - f32(4 + 5 * b) * f32(line) - 2
			tx.canvas_fill_circle(&sub, bx, f32(win.y) + f32(title_h) / 2, 1.3 * f32(line), mix(th.fg, th.bg, active ? 0.35 : 0.6))
		}
		if active {
			ly := win.y + title_h + 3 * line
			for lw in ([3]i32{60, 45, 70}) {
				if ly + line > win.y + win.h - 3 * line { break }
				tx.canvas_fill_rect(&sub, {win.x + 3 * line, ly, win.w * lw / 100, line}, mix(th.fg, th.bg, 0.4))
				ly += 3 * line
			}
		}
	}
	composite_rounded(cv, sub, r.x, r.y, 12)
	tx.canvas_stroke_rounded_rect(cv, r, 12, 1, tx.color_with_alpha(th.muted, 80))
}
