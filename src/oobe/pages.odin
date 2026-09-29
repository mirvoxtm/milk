// The pages of the wizard: welcome, theme, keyboard, wallpapers, bar and
// summary. Each draws into the frame canvas, queues its text and registers
// its clickable areas.
package oobe

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import config "../config"
import tx "../tx"

// ---------------------------------------------------------------------------
// Welcome
// ---------------------------------------------------------------------------
@(private)
draw_welcome :: proc(w: ^Wizard, cv: ^tx.Canvas) {
	th := &w.theme
	cd := w.card
	area := tx.Rect{cd.x + PAD, cd.y + 70, cd.w - 2 * PAD, cd.h - 70 - FOOTER_H}

	logo: i32 = 88
	feature_h: i32 = 132
	total := logo + 28 + 44 + 30 + 40 + feature_h
	y := area.y + max((area.h - total) / 2, 0)
	cx := area.x + area.w / 2

	shadow(cv, {cx - logo / 2, y, logo, logo}, f32(logo) / 2, 4, th.dark ? 30 : 16, 3)
	tx.canvas_fill_circle(cv, f32(cx), f32(y + logo / 2), f32(logo) / 2, th.accent)
	if w.f_icon_big != nil {
		icon(w, w.f_icon_big, {cx - logo / 2, y, logo, logo}, .Milk, th.accent_fg)
	} else {
		text_centered(w, w.f_title, {cx - logo / 2, y, logo, logo}, "m", th.accent_fg)
	}
	y += logo + 28
	text_centered(w, w.f_title, {area.x, y, area.w, 44}, tr(w, "Bem-vindo ao milk", "Welcome to milk"), th.fg)
	y += 44
	text_centered(w, w.f_body, {area.x, y, area.w, 30},
	              tr(w, "Vamos deixar a sua área de trabalho do seu jeito em quatro passos rápidos.",
	                    "Let's make your desktop yours in four quick steps."), mix(th.fg, th.muted, 0.55))
	y += 30 + 40

	Feature :: struct { icon: Icon, title, desc: string }
	features := [4]Feature{
		{.Palette, tr(w, "Tema", "Theme"), tr(w, "Claro ou escuro", "Light or dark")},
		{.Keyboard, tr(w, "Teclado", "Keyboard"), tr(w, "Layout e variante", "Layout and variant")},
		{.Photo, tr(w, "Papéis de parede", "Wallpapers"), tr(w, "Um para todas ou um por área", "One for all or one per area")},
		{.Layout_Top, tr(w, "Barra", "Bar"), tr(w, "Posição e estilo", "Position and style")},
	}
	gap: i32 = 16
	fw := min(i32(230), (area.w - 3 * gap) / 4)
	x := cx - (4 * fw + 3 * gap) / 2
	for f in features {
		r := tx.Rect{x, y, fw, feature_h}
		tx.canvas_fill_rounded_rect(cv, r, 20, th.field)
		ic := tx.Rect{r.x + (r.w - 44) / 2, r.y + 18, 44, 44}
		tx.canvas_fill_circle(cv, f32(ic.x + 22), f32(ic.y + 22), 22, mix(th.accent, th.field, 0.82))
		icon(w, w.f_icon, ic, f.icon, th.accent)
		text_centered(w, w.f_h2, {r.x, r.y + 70, r.w, 26}, ellipsize(w, w.f_h2, f.title, r.w - 16), th.fg)
		text_centered(w, w.f_small, {r.x, r.y + 96, r.w, 20}, ellipsize(w, w.f_small, f.desc, r.w - 16), mix(th.fg, th.muted, 0.6))
		x += fw + gap
	}
}

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------
@(private)
draw_theme_page :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	th := &w.theme
	segmented(w, cv, {c.x, c.y, 300, 44}, {tr(w, "Claro", "Light"), tr(w, "Escuro", "Dark")}, {.Sun, .Moon},
	          w.dark ? 1 : 0, .Variant)

	gap: i32 = 24
	n := i32(len(config.THEME_PRESETS))
	card_w := (c.w - (n - 1) * gap) / n
	top := c.y + 44 + 28
	avail := c.y + c.h - top
	label_h: i32 = 58
	preview_h := min(card_w * 7 / 10, avail - label_h - 20)
	card_h := preview_h + 20 + label_h
	top += max((avail - card_h) / 3, 0)
	for preset, i in config.THEME_PRESETS {
		r := tx.Rect{c.x + i32(i) * (card_w + gap), top, card_w, card_h}
		selected := i == w.theme_index
		hot := hovered(w, .Theme, i)
		pt := preset_theme(i, w.dark)
		if selected || hot { shadow(cv, r, 20, 4, th.dark ? 26 : 12, 3) }
		tx.canvas_fill_rounded_rect(cv, r, 20, th.field)
		if selected {
			tx.canvas_stroke_rounded_rect(cv, {r.x - 3, r.y - 3, r.w + 6, r.h + 6}, 23, 2.5, th.accent)
		} else if hot {
			tx.canvas_stroke_rounded_rect(cv, r, 20, 1.5, th.outline)
		}
		p := tx.Rect{r.x + 10, r.y + 10, r.w - 20, preview_h}
		draw_theme_preview(w, cv, p, &pt)
		ly := p.y + p.h + 8
		text(w, w.f_h2, r.x + 18, ly, 26, preset.title, th.fg)
		text(w, w.f_small, r.x + 18, ly + 24, 20, w.dark ? tr(w, "Variante escura", "Dark variant") : tr(w, "Variante clara", "Light variant"),
		     mix(th.fg, th.muted, 0.6))
		// Palette swatches (and the check mark of the chosen theme).
		sx := r.x + r.w - 18 - 7
		if selected {
			check_badge(w, cv, r.x + r.w - 18 - 12, ly + 24, 12)
			sx -= 36
		}
		for col in ([]tx.Color{pt.fg, pt.accent, pt.surface, pt.bg}) {
			tx.canvas_fill_circle(cv, f32(sx), f32(ly + 24), 9, th.field)
			tx.canvas_fill_circle(cv, f32(sx), f32(ly + 24), 7.5, col)
			tx.canvas_stroke_rounded_rect(cv, {sx - 8, ly + 16, 16, 16}, 8, 1, tx.color_with_alpha(th.muted, 90))
			sx -= 14
		}
		add_hit(w, r, .Theme, i)
	}
}

// A little desktop in the preset's colours: tinted desk, the bar with its
// workspace dots and clock, and a window with text and an accent button.
@(private)
draw_theme_preview :: proc(w: ^Wizard, cv: ^tx.Canvas, p: tx.Rect, pt: ^Theme) {
	desk := mix(pt.surface, pt.accent, 0.28)
	tx.canvas_fill_rounded_rect(cv, p, 14, desk)
	// Bar.
	bar := tx.Rect{p.x + 10, p.y + 10, p.w - 20, 30}
	tx.canvas_fill_rounded_rect(cv, bar, 15, pt.bg)
	tx.canvas_fill_circle(cv, f32(bar.x + 17), f32(bar.y + 15), 6, pt.accent)
	cx := bar.x + bar.w / 2
	dots_w: i32 = 18 + 3 * 12
	dx := cx - dots_w / 2
	tx.canvas_fill_rounded_rect(cv, {dx, bar.y + 12, 18, 6}, 3, pt.accent)
	dx += 18 + 8
	for _ in 0 ..< 3 {
		tx.canvas_fill_circle(cv, f32(dx + 2), f32(bar.y + 15), 3, mix(pt.muted, pt.bg, 0.2))
		dx += 12
	}
	clock := "12:30"
	cw := text_width(w, w.f_small, clock)
	text(w, w.f_small, bar.x + bar.w - 14 - cw, bar.y, bar.h, clock, pt.fg)

	// Window.
	win := tx.Rect{p.x + 22, bar.y + bar.h + 12, p.w - 44, p.y + p.h - 14 - (bar.y + bar.h + 12)}
	if win.h < 40 { return }
	shadow(cv, win, 12, 3, pt.dark ? 40 : 18, 2)
	tx.canvas_fill_rounded_rect(cv, win, 12, pt.focus)
	inner := tx.Rect{win.x + 2, win.y + 2, win.w - 4, win.h - 4}
	tx.canvas_fill_rounded_rect(cv, inner, 10, pt.bg)
	text(w, w.f_h2, inner.x + 14, inner.y + 8, 26, "Aa", pt.fg)
	ay := inner.y + 40
	if ay + 8 < inner.y + inner.h - 38 {
		tx.canvas_fill_rounded_rect(cv, {inner.x + 14, ay, inner.w * 55 / 100, 7}, 3.5, mix(pt.fg, pt.bg, 0.25))
		tx.canvas_fill_rounded_rect(cv, {inner.x + 14, ay + 14, inner.w * 38 / 100, 7}, 3.5, mix(pt.muted, pt.bg, 0.1))
	}
	btn := tx.Rect{inner.x + inner.w - 14 - 58, inner.y + inner.h - 12 - 26, 58, 26}
	if btn.y > inner.y + 8 {
		tx.canvas_fill_rounded_rect(cv, btn, 13, pt.accent)
		text_centered(w, w.f_tiny, btn, "OK", pt.accent_fg)
		chip := tx.Rect{btn.x - 8 - 50, btn.y, 50, 26}
		if chip.x > inner.x + 10 {
			tx.canvas_fill_rounded_rect(cv, chip, 13, pt.surface)
			tx.canvas_fill_circle(cv, f32(chip.x + 25), f32(chip.y + 13), 4, pt.warning)
		}
	}
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------
@(private)
draw_field :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect, lead: Icon, value, placeholder: string, focused: bool, action: Action, arg: int = 0) {
	th := &w.theme
	hot := hovered(w, action, arg)
	tx.canvas_fill_rounded_rect(cv, r, f32(r.h) / 2, focused ? th.bg : (hot ? mix(th.field, th.hover, 0.5) : th.field))
	tx.canvas_stroke_rounded_rect(cv, r, f32(r.h) / 2, focused ? 2 : 1, focused ? th.accent : th.outline)
	x := r.x + 18
	if w.f_icon_small != nil && lead != .None {
		icon(w, w.f_icon_small, {x, r.y, 20, r.h}, lead, focused ? th.accent : th.muted)
		x += 30
	}
	avail := r.x + r.w - 18 - x
	if value == "" && !focused {
		text(w, w.f_body, x, r.y, r.h, ellipsize(w, w.f_body, placeholder, avail), th.muted)
	} else {
		shown := value
		// Keep the end of long input visible.
		for len(shown) > 0 && text_width(w, w.f_body, shown) > avail - 6 {
			_, n := decode_first(shown)
			shown = shown[n:]
		}
		text(w, w.f_body, x, r.y, r.h, shown, th.fg)
		if focused {
			cx := x + text_width(w, w.f_body, shown) + 1
			tx.canvas_fill_rect(cv, {cx, r.y + (r.h - 20) / 2, 2, 20}, th.accent)
		}
	}
	add_hit(w, r, action, arg)
}

@(private)
decode_first :: proc(s: string) -> (rune, int) {
	for r, i in s {
		if i > 0 { return r, i }
	}
	return 0, len(s)
}

// A scrolled list: returns the canvas to draw rows into (list coordinates);
// finish with list_end.
@(private)
list_begin :: proc(w: ^Wizard, r: tx.Rect, content_h: i32, scroll: ^i32, id: Scroll_Id) -> tx.Canvas {
	max_scroll := max(content_h - r.h, 0)
	scroll^ = clamp(scroll^, 0, max_scroll)
	append(&w.scrolls, Scroll_Area{r = r, id = id, max = max_scroll})
	sub := tx.canvas_make(r.w, r.h, context.temp_allocator)
	tx.canvas_fill(&sub, w.theme.field)
	return sub
}

@(private)
list_end :: proc(w: ^Wizard, cv: ^tx.Canvas, sub: ^tx.Canvas, r: tx.Rect, content_h, scroll: i32) {
	th := &w.theme
	if content_h > r.h {
		track := r.h - 16
		thumb_h := max(track * r.h / content_h, 28)
		thumb_y := 8 + (track - thumb_h) * scroll / max(content_h - r.h, 1)
		tx.canvas_fill_rounded_rect(sub, {r.w - 9, thumb_y, 4, thumb_h}, 2, tx.color_with_alpha(th.muted, 150))
	}
	composite_rounded(cv, sub^, r.x, r.y, 18)
	tx.canvas_stroke_rounded_rect(cv, r, 18, 1, th.outline)
}

// One row of a list; `y` is in list coordinates.
@(private)
list_row :: proc(w: ^Wizard, sub: ^tx.Canvas, r: tx.Rect, y: i32, label, detail: string, selected: bool, action: Action, arg: int,
                 hint := "", height: i32 = ROW_H) {
	th := &w.theme
	row := tx.Rect{6, y, r.w - 18, height - 4}
	if row.y + row.h < 0 || row.y > r.h { return }
	hot := hovered(w, action, arg)
	if selected {
		tx.canvas_fill_rounded_rect(sub, row, 12, th.accent)
	} else if hot {
		tx.canvas_fill_rounded_rect(sub, row, 12, th.hover)
	}
	fg := selected ? th.accent_fg : th.fg
	win_row := tx.Rect{r.x + row.x, r.y + row.y, row.w, row.h}
	right := win_row.x + win_row.w - 14
	if selected && w.f_icon_small != nil {
		icon(w, w.f_icon_small, {right - 18, win_row.y, 18, win_row.h}, .Check, fg, r)
		right -= 28
	}
	if detail != "" {
		dw := text_width(w, w.f_small, detail)
		text(w, w.f_small, right - dw, win_row.y, win_row.h, detail, selected ? mix(th.accent_fg, th.accent, 0.3) : th.muted, r)
		right -= dw + 12
	}
	if hint != "" {
		// Two lines: the name, and a short explanation under it.
		avail := right - win_row.x - 14
		text(w, w.f_body, win_row.x + 14, win_row.y + 4, 24, ellipsize(w, w.f_body, label, avail), fg, r)
		text(w, w.f_small, win_row.x + 14, win_row.y + 27, 18, ellipsize(w, w.f_small, hint, avail),
		     selected ? mix(th.accent_fg, th.accent, 0.2) : th.warning, r)
	} else {
		text(w, w.f_body, win_row.x + 14, win_row.y, win_row.h, ellipsize(w, w.f_body, label, right - win_row.x - 14), fg, r)
	}
	add_hit(w, win_row, action, arg, r)
}

// "no dead keys" variants: ´ ~ ^ type themselves instead of accenting the next letter.
@(private)
is_nodeadkeys :: proc(code, desc: string) -> bool {
	return strings.contains(code, "nodeadkeys") || strings.contains(strings.to_lower(desc, context.temp_allocator), "no dead keys")
}

@(private)
nodeadkeys_hint :: proc(w: ^Wizard, width: i32) -> string {
	full := tr(w, "Sem teclas mortas: ´ ~ ^ não acentuam a letra seguinte", "No dead keys: ´ ~ ^ do not accent the next letter")
	if text_width(w, w.f_small, full) <= width { return full }
	return tr(w, "Sem teclas mortas: ´ ~ ^ não acentuam", "No dead keys: ´ ~ ^ never accent")
}

@(private)
draw_keyboard_page :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	th := &w.theme
	kb := &w.kb
	gap: i32 = 24
	lw := c.w * 55 / 100
	rx := c.x + lw + gap
	rw := c.w - lw - gap
	test_h: i32 = 46
	list_y := c.y + 44 + 12
	list_h := c.y + c.h - test_h - 18 - list_y

	// Search and layouts.
	draw_field(w, cv, {c.x, c.y, lw, 44}, .Search, string(kb.search[:]), tr(w, "Buscar layout…", "Search layouts…"),
	           w.focus == .Search, .Kb_Search)
	lr := tx.Rect{c.x, list_y, lw, list_h}
	content_h := i32(len(kb.filtered)) * ROW_H + 8
	if kb.reveal {
		for li, i in kb.filtered {
			if kb.layouts[li].code != kb.layout { continue }
			row_top := 4 + i32(i) * ROW_H
			if row_top < kb.scroll_layouts || row_top + ROW_H > kb.scroll_layouts + list_h {
				kb.scroll_layouts = row_top - list_h / 2 + ROW_H / 2
			}
		}
		kb.reveal = false
	}
	sub := list_begin(w, lr, content_h, &kb.scroll_layouts, .Layouts)
	first := max(int((kb.scroll_layouts - 4) / ROW_H), 0)
	for i in first ..< len(kb.filtered) {
		y := 4 + i32(i) * ROW_H - kb.scroll_layouts + 2
		if y > lr.h { break }
		e := kb.layouts[kb.filtered[i]]
		list_row(w, &sub, lr, y, e.desc, e.code, e.code == kb.layout, .Kb_Layout, kb.filtered[i])
	}
	if len(kb.filtered) == 0 {
		text_centered(w, w.f_body, {lr.x, lr.y + 20, lr.w, 30}, tr(w, "Nenhum layout encontrado", "No layout found"), th.muted)
	}
	list_end(w, cv, &sub, lr, content_h, kb.scroll_layouts)

	// Variants of the chosen layout.
	text(w, w.f_tiny, rx + 4, c.y, 18, tr(w, "VARIANTE", "VARIANT"), th.muted)
	text(w, w.f_h2, rx + 4, c.y + 18, 26, ellipsize(w, w.f_h2, layout_desc(w, kb.layout), rw - 8), th.fg)
	vr := tx.Rect{rx, list_y, rw, list_h}
	variants := layout_variants(w)
	TALL :: ROW_H + 18
	vcontent: i32 = ROW_H + 8
	for v in variants { vcontent += is_nodeadkeys(v.code, v.desc) ? TALL : ROW_H }
	vsub := list_begin(w, vr, vcontent, &kb.scroll_variants, .Variants)
	list_row(w, &vsub, vr, 6 - kb.scroll_variants, tr(w, "Padrão", "Default"), "", kb.variant == "", .Kb_Variant, -1)
	hint := nodeadkeys_hint(w, vr.w - 80)
	vy := 6 + ROW_H - kb.scroll_variants
	for v, i in variants {
		if vy > vr.h { break }
		if is_nodeadkeys(v.code, v.desc) {
			list_row(w, &vsub, vr, vy, variant_label(w, v.desc), "", v.code == kb.variant, .Kb_Variant, i, hint, TALL)
			vy += TALL
		} else {
			list_row(w, &vsub, vr, vy, variant_label(w, v.desc), "", v.code == kb.variant, .Kb_Variant, i)
			vy += ROW_H
		}
	}
	list_end(w, cv, &vsub, vr, vcontent, kb.scroll_variants)

	// Test field.
	draw_field(w, cv, {c.x, c.y + c.h - test_h, c.w, test_h}, .Keyboard, string(kb.test[:]),
	           tr(w, "Teste aqui: ç, acentos, @, / …", "Type here to test: symbols, accents, @, / …"), w.focus == .Test, .Kb_Test)
}

// ---------------------------------------------------------------------------
// Wallpapers
// ---------------------------------------------------------------------------
@(private)
candidate_name :: proc(w: ^Wizard, index: int) -> string {
	if index < 0 || index >= len(w.thumbs.items) { return tr(w, "Nenhum (cor da barra)", "None (bar colour)") }
	return filepath.stem(filepath.base(w.thumbs.items[index].path))
}

@(private)
draw_wallpaper_page :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	th := &w.theme
	segmented(w, cv, {c.x, c.y, min(i32(460), c.w * 3 / 5), 44},
	          {tr(w, "Um para todas as áreas", "One for every area"), tr(w, "Um por área", "One per area")}, {.Desktop, .Photo},
	          w.wp_per_area ? 1 : 0, .Wp_Mode)

	total := len(w.thumbs.items)
	loading := !w.started || w.thumbs.pending > 0
	phase := anim_phase(w, 1.4)
	status: string
	if !w.started {
		status = tr(w, "Carregando papéis de parede…", "Loading wallpapers…")
	} else if w.thumbs.pending > 0 {
		status = fmt.tprintf(tr(w, "Carregando papéis de parede… %d de %d", "Loading wallpapers… %d of %d"), total - w.thumbs.pending, total)
	} else {
		status = fmt.tprintf(tr(w, "%d imagens encontradas", "%d pictures found"), len(visible_candidates(w)))
	}
	sw := text_width(w, w.f_small, status)
	text(w, w.f_small, c.x + c.w - sw, c.y, 44, status, th.muted)
	if loading {
		draw_spinner(cv, f32(c.x + c.w - sw - 16), f32(c.y + 22), 7, 2.5, anim_phase(w, 0.9), th.accent, tx.color_with_alpha(th.muted, 60))
	}

	y := c.y + 44 + 16
	if w.wp_per_area {
		chip_w: i32 = 104
		chip_h: i32 = 52
		x := c.x
		for n, i in w.areas {
			r := tx.Rect{x, y, chip_w, chip_h}
			if r.x + r.w > c.x + c.w { break }
			sel := i == w.wp_tab
			hot := hovered(w, .Wp_Area, i)
			tx.canvas_fill_rounded_rect(cv, r, 16, sel ? mix(th.accent, th.bg, 0.85) : (hot ? th.hover : th.field))
			if sel { tx.canvas_stroke_rounded_rect(cv, r, 16, 2, th.accent) }
			thumb := tx.Rect{r.x + 8, r.y + 8, 64, 36}
			choice := w.wp_choice[i]
			if img, ok := candidate_scaled(w, choice, thumb.w, thumb.h); ok {
				blit_rounded(cv, img, thumb.x, thumb.y, 8)
			} else {
				tx.canvas_fill_rounded_rect(cv, thumb, 8, choice < 0 ? th.bg : th.surface)
				tx.canvas_stroke_rounded_rect(cv, thumb, 8, 1, th.outline)
				if choice < 0 { icon(w, w.f_icon_small, thumb, .Photo_Off, th.muted) }
			}
			text_centered(w, w.f_h2, {thumb.x + thumb.w, r.y, r.x + r.w - thumb.x - thumb.w, r.h}, fmt.tprintf("%d", n), sel ? th.accent : th.fg)
			add_hit(w, r, .Wp_Area, i)
			x += chip_w + 10
		}
		y += chip_h + 14
	}

	// Grid.
	vp := tx.Rect{c.x - 6, y, c.w + 12, c.y + c.h - y}
	visible := visible_candidates(w)
	count := len(visible) + 1 // + "no wallpaper"
	if !w.started { count = 9 } // placeholders until the list is ready
	gap: i32 = 16
	gutter: i32 = 14
	inner_w := vp.w - 12 - gutter
	cols := max(i32(3), (inner_w + gap) / (230 + gap))
	tile_w := (inner_w - (cols - 1) * gap) / cols
	tile_h := tile_w * 9 / 16
	rows := (i32(count) + cols - 1) / cols
	content_h := rows * (tile_h + gap) - gap + 12
	max_scroll := max(content_h - vp.h, 0)
	w.scroll_wp = clamp(w.scroll_wp, 0, max_scroll)
	append(&w.scrolls, Scroll_Area{r = vp, id = .Wallpapers, max = max_scroll})
	sub := tx.canvas_make(vp.w, vp.h, context.temp_allocator)
	tx.canvas_fill(&sub, th.bg)

	current := area_choice(w, w.wp_tab)
	for k in 0 ..< count {
		index := k == 0 ? -1 : (k - 1 < len(visible) ? visible[k - 1] : -2)
		col := i32(k) % cols
		row := i32(k) / cols
		t := tx.Rect{6 + col * (tile_w + gap), 6 + row * (tile_h + gap) - w.scroll_wp, tile_w, tile_h}
		if t.y + t.h + 6 < 0 { continue }
		if t.y - 6 > vp.h { break }
		win_t := tx.Rect{vp.x + t.x, vp.y + t.y, t.w, t.h}
		selected := index == current
		hot := hovered(w, .Wp_Tile, index)
		if index < 0 {
			tx.canvas_fill_rounded_rect(&sub, t, 14, th.surface)
			tx.canvas_stroke_rounded_rect(&sub, t, 14, 1, th.outline)
			icon(w, w.f_icon, {win_t.x, win_t.y + t.h / 2 - 34, t.w, 36}, .Photo_Off, th.muted, vp)
			text_centered(w, w.f_body, {win_t.x, win_t.y + t.h / 2, t.w, 24}, tr(w, "Sem papel de parede", "No wallpaper"), th.fg, vp)
			text_centered(w, w.f_small, {win_t.x, win_t.y + t.h / 2 + 22, t.w, 20}, tr(w, "cor sólida da barra", "solid bar colour"), th.muted, vp)
		} else if img, ok := candidate_scaled(w, index, t.w, t.h); ok {
			blit_rounded(&sub, img, t.x, t.y, 14)
		} else {
			// Still decoding: a shimmering placeholder.
			fill_shimmer(&sub, t, 14, th.field, mix(th.field, th.fg, th.dark ? 0.1 : 0.06), phase)
			if index == -2 { continue }
		}
		if selected {
			tx.canvas_stroke_rounded_rect(&sub, {t.x - 5, t.y - 5, t.w + 10, t.h + 10}, 19, 3, th.accent)
			check_badge(w, &sub, t.x + t.w - 18, t.y + 18, 12, vp, vp.x, vp.y)
		} else if hot {
			tx.canvas_stroke_rounded_rect(&sub, {t.x - 4, t.y - 4, t.w + 8, t.h + 8}, 18, 2, th.muted)
		}
		// Other areas using this picture.
		if w.wp_per_area {
			bx := t.x + 10
			for j in 0 ..< len(w.areas) {
				if j == w.wp_tab || w.wp_choice[j] != index { continue }
				tx.canvas_fill_circle(&sub, f32(bx + 11), f32(t.y + t.h - 21), 12, tx.color_with_alpha(th.bg, 235))
				text_centered(w, w.f_tiny, {vp.x + bx, vp.y + t.y + t.h - 33, 22, 24}, fmt.tprintf("%d", w.areas[j]), th.fg, vp)
				bx += 28
			}
		}
		add_hit(w, win_t, .Wp_Tile, index, vp)
	}
	if max_scroll > 0 {
		track := vp.h - 16
		thumb_h := max(track * vp.h / content_h, 32)
		thumb_y := 8 + (track - thumb_h) * w.scroll_wp / max_scroll
		tx.canvas_fill_rounded_rect(&sub, {vp.w - 8, thumb_y, 4, thumb_h}, 2, tx.color_with_alpha(th.muted, 150))
	}
	composite_rounded(cv, sub, vp.x, vp.y, 0)
}

// ---------------------------------------------------------------------------
// Bar
// ---------------------------------------------------------------------------
@(private)
draw_bar_page :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	th := &w.theme
	gap: i32 = 20
	cols: i32 = 4
	card_w := (c.w - (cols - 1) * gap) / cols
	pw := card_w - 20
	ph := pw * w.monitor.h / max(w.monitor.w, 1)
	label_h: i32 = 62
	card_h := ph + 20 + label_h
	if card_h > c.h {
		cols = 2
		card_w = (c.w - gap) / 2
		ph = min((c.h - gap) / 2 - 20 - label_h, (card_w - 20) * w.monitor.h / max(w.monitor.w, 1))
		pw = ph * w.monitor.w / max(w.monitor.h, 1)
		card_h = ph + 20 + label_h
	}
	rows := 4 / cols
	grid_h := i32(rows) * card_h + i32(rows - 1) * gap
	top := c.y + max((c.h - grid_h) / 2, 0) / 2
	Option :: struct { title, desc: string }
	options := [4]Option{
		{tr(w, "Topo", "Top"), tr(w, "De ponta a ponta", "Edge to edge")},
		{tr(w, "Topo flutuante", "Floating top"), tr(w, "Margens e cantos arredondados", "Margins and rounded corners")},
		{tr(w, "Base", "Bottom"), tr(w, "De ponta a ponta", "Edge to edge")},
		{tr(w, "Base flutuante", "Floating bottom"), tr(w, "Margens e cantos arredondados", "Margins and rounded corners")},
	}
	current := (w.bar_top ? 0 : 2) + (w.bar_floating ? 1 : 0)
	for opt, i in options {
		col := i32(i) % cols
		row := i32(i) / cols
		r := tx.Rect{c.x + col * (card_w + gap), top + row * (card_h + gap), card_w, card_h}
		selected := i == current
		hot := hovered(w, .Bar_Choice, i)
		if selected || hot { shadow(cv, r, 20, 4, th.dark ? 26 : 12, 3) }
		tx.canvas_fill_rounded_rect(cv, r, 20, th.field)
		if selected {
			tx.canvas_stroke_rounded_rect(cv, {r.x - 3, r.y - 3, r.w + 6, r.h + 6}, 23, 2.5, th.accent)
		} else if hot {
			tx.canvas_stroke_rounded_rect(cv, r, 20, 1.5, th.outline)
		}
		p := tx.Rect{r.x + (r.w - pw) / 2, r.y + 10, pw, ph}
		draw_mock(w, cv, p, &w.theme, area_choice(w, 0), i < 2, i % 2 == 1, 12)
		if selected { check_badge(w, cv, p.x + p.w - 16, p.y + 16, 11) }
		text(w, w.f_h2, r.x + 16, p.y + p.h + 10, 26, ellipsize(w, w.f_h2, opt.title, r.w - 32), th.fg)
		text(w, w.f_small, r.x + 16, p.y + p.h + 34, 20, ellipsize(w, w.f_small, opt.desc, r.w - 32), mix(th.fg, th.muted, 0.6))
		add_hit(w, r, .Bar_Choice, i)
	}
}

// A miniature of the desktop: wallpaper (or the bar colour), the bar in the
// chosen position and style, and a master/stack pair of windows.
@(private)
draw_mock :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect, th: ^Theme, wallpaper: int, top, floating: bool, radius: f32) {
	sub := tx.canvas_make(r.w, r.h, context.temp_allocator)
	if img, ok := candidate_scaled(w, wallpaper, r.w, r.h); ok {
		tx.canvas_blit_image(&sub, img, 0, 0)
	} else if wallpaper >= 0 {
		tx.canvas_fill(&sub, th.field)
	} else {
		tx.canvas_fill(&sub, mix(th.bg, th.surface, 0.6))
	}
	s := f32(r.w) / f32(max(w.monitor.w, 1)) * 2 // exaggerate the bar a little
	bar_h := max(i32(f32(w.cfg.bar.height) * s), 9)
	margin: i32 = floating ? max(i32(f32(w.cfg.bar.margin) * s), 4) : 0
	bar := tx.Rect{margin, top ? margin : r.h - margin - bar_h, r.w - 2 * margin, bar_h}
	tx.canvas_fill_rounded_rect(&sub, bar, floating ? f32(bar_h) / 2 : 0, tx.color_with_alpha(th.bg, 238))
	cy := f32(bar.y) + f32(bar_h) / 2
	unit := max(f32(bar_h) / 9, 1)
	tx.canvas_fill_circle(&sub, f32(bar.x) + 4 * unit + 2, cy, 1.6 * unit, th.accent)
	// Workspace dots.
	cx := f32(bar.x + bar.w / 2)
	pill := 5 * unit
	tx.canvas_fill_rounded_rect(&sub, {i32(cx - pill - 2 * unit), i32(cy - unit), i32(pill), i32(2 * unit)}, unit, th.accent)
	for k in 0 ..< 3 {
		tx.canvas_fill_circle(&sub, cx + f32(k) * 3.2 * unit, cy, 0.8 * unit, mix(th.muted, th.bg, 0.2))
	}
	// Clock.
	tx.canvas_fill_rounded_rect(&sub, {bar.x + bar.w - i32(12 * unit), i32(cy - unit), i32(7 * unit), i32(2 * unit)}, unit, mix(th.fg, th.bg, 0.2))

	// Windows.
	gap := max(r.w / 26, 4)
	work := tx.Rect{gap, gap, r.w - 2 * gap, r.h - 2 * gap}
	if top {
		work.y = bar.y + bar.h + gap
		work.h = r.h - work.y - gap
	} else {
		work.h = bar.y - 2 * gap
	}
	if work.h > 12 {
		bw := max(i32(2 * s / 1.5), 1)
		mw := work.w * 55 / 100 - gap / 2
		master := tx.Rect{work.x, work.y, mw, work.h}
		sx := work.x + mw + gap
		stack_w := work.w - mw - gap
		sh := (work.h - gap) / 2
		wins := [3]tx.Rect{master, {sx, work.y, stack_w, sh}, {sx, work.y + sh + gap, stack_w, work.h - sh - gap}}
		for win, k in wins {
			rad := f32(max(gap, 3))
			tx.canvas_fill_rounded_rect(&sub, win, rad, k == 0 ? th.focus : th.border)
			inner := tx.Rect{win.x + bw, win.y + bw, win.w - 2 * bw, win.h - 2 * bw}
			tx.canvas_fill_rounded_rect(&sub, inner, max(rad - f32(bw), 1), k == 0 ? th.bg : mix(th.bg, th.surface, 0.5))
			line := max(i32(unit * 1.1), 1)
			ly := inner.y + 3 * line
			if k == 0 {
				widths := [5]i32{55, 70, 40, 62, 30}
				for lw, li in widths {
					if ly + line > inner.y + inner.h - 2 * line { break }
					tx.canvas_fill_rect(&sub, {inner.x + 3 * line, ly, inner.w * lw / 100, line}, li == 0 ? th.accent : mix(th.fg, th.bg, 0.35))
					ly += 3 * line
				}
			} else if inner.h > 6 * line {
				tx.canvas_fill_rounded_rect(&sub, {inner.x + 3 * line, ly, inner.w / 2, line * 2}, f32(line), mix(th.muted, th.bg, 0.3))
			}
		}
	}
	composite_rounded(cv, sub, r.x, r.y, radius)
	tx.canvas_stroke_rounded_rect(cv, r, radius, 1, tx.color_with_alpha(th.muted, 80))
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------
@(private)
draw_summary_page :: proc(w: ^Wizard, cv: ^tx.Canvas) {
	th := &w.theme
	c := content_rect(w)
	strip_h: i32 = w.wp_per_area ? 62 : 0
	mw := min(c.w * 52 / 100, (c.h - strip_h) * w.monitor.w / max(w.monitor.h, 1))
	mh := mw * w.monitor.h / max(w.monitor.w, 1)
	my := c.y + max((c.h - strip_h - mh) / 2, 0) / 2
	mock := tx.Rect{c.x, my, mw, mh}
	shadow(cv, mock, 16, 5, th.dark ? 30 : 14, 4)
	draw_mock(w, cv, mock, &w.theme, area_choice(w, 0), w.bar_top, w.bar_floating, 16)
	if w.wp_per_area {
		x := c.x
		y := mock.y + mock.h + 14
		for n, i in w.areas {
			t := tx.Rect{x, y, 72, 41}
			if t.x + t.w > c.x + mw { break }
			if img, ok := candidate_scaled(w, w.wp_choice[i], t.w, t.h); ok {
				blit_rounded(cv, img, t.x, t.y, 8)
			} else {
				tx.canvas_fill_rounded_rect(cv, t, 8, th.surface)
			}
			tx.canvas_fill_circle(cv, f32(t.x + 14), f32(t.y + t.h - 13), 10, tx.color_with_alpha(th.bg, 235))
			text_centered(w, w.f_tiny, {t.x + 4, t.y + t.h - 25, 20, 24}, fmt.tprintf("%d", n), th.fg)
			x += t.w + 8
		}
	}

	rx := c.x + mw + 40
	rw := c.x + c.w - rx
	Row :: struct { icon: Icon, label, value: string, page: Page }
	theme_value := fmt.tprintf("%s · %s", config.THEME_PRESETS[w.theme_index].title, w.dark ? tr(w, "Escuro", "Dark") : tr(w, "Claro", "Light"))
	kb_value := fmt.tprintf("%s · %s", layout_desc(w, w.kb.layout), variant_desc(w))
	wp_value: string
	if w.wp_per_area {
		wp_value = fmt.tprintf(tr(w, "Um por área · %d áreas", "One per area · %d areas"), len(w.areas))
	} else {
		wp_value = w.wp_single < 0 ? tr(w, "Nenhum (cor sólida da barra)", "None (solid bar colour)") :
		           fmt.tprintf(tr(w, "%s · todas as áreas", "%s · every area"), candidate_name(w, w.wp_single))
	}
	bar_value := fmt.tprintf("%s · %s", w.bar_top ? tr(w, "Topo", "Top") : tr(w, "Base", "Bottom"),
	                         w.bar_floating ? tr(w, "flutuante", "floating") : tr(w, "de ponta a ponta", "edge to edge"))
	rows := [4]Row{
		{.Palette, tr(w, "TEMA", "THEME"), theme_value, .Theme},
		{.Keyboard, tr(w, "TECLADO", "KEYBOARD"), kb_value, .Keyboard},
		{.Photo, tr(w, "PAPÉIS DE PAREDE", "WALLPAPERS"), wp_value, .Wallpaper},
		{w.bar_top ? .Layout_Top : .Layout_Bottom, tr(w, "BARRA", "BAR"), bar_value, .Bar},
	}
	row_h: i32 = 72
	y := mock.y + max((mock.h - 4 * row_h) / 2, 0)
	for row in rows {
		r := tx.Rect{rx, y, rw, row_h - 8}
		hot := hovered(w, .Goto_Page, int(row.page) + 100)
		if hot { tx.canvas_fill_rounded_rect(cv, r, 18, th.field) }
		ic := tx.Rect{r.x + 10, r.y + (r.h - 44) / 2, 44, 44}
		tx.canvas_fill_circle(cv, f32(ic.x + 22), f32(ic.y + 22), 22, mix(th.accent, th.bg, 0.84))
		icon(w, w.f_icon, ic, row.icon, th.accent)
		tx_x := ic.x + ic.w + 16
		text(w, w.f_tiny, tx_x, r.y + 10, 18, row.label, th.muted)
		text(w, w.f_h2, tx_x, r.y + 28, 26, ellipsize(w, w.f_h2, row.value, r.x + r.w - tx_x - 16), th.fg)
		if hot {
			edit := tr(w, "Alterar", "Change")
			ew := text_width(w, w.f_small, edit)
			text(w, w.f_small, r.x + r.w - 16 - ew, r.y, r.h, edit, th.accent)
		}
		append(&w.hits, Hit{r = r, action = .Goto_Page, arg = int(row.page) + 100})
		y += row_h
	}
}
