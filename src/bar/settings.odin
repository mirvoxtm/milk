// Quick settings: the gear widget opens a small Material-style card with the
// options people tweak most (bar position/style/height/opacity, the window
// mode, window gaps/borders, master size (tiling only), animations, the area toast). Each change is written straight
// into milk.json and applied by reloading the configuration, so the file
// stays the single source of truth. Keys are rewritten in sorted order.
package bar

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import xlib "vendor:x11/xlib"
import config "../config"
import nightlight "../nightlight"
import tx "../tx"

@(private) SET_WIDTH   :: 330 // minimum; widened to fit the animation row
@(private) SET_PAD     :: 16
@(private) SET_ROW     :: 38
@(private) SET_TITLE   :: 40
@(private) SET_FOOTER  :: 52
@(private) SET_BUTTON  :: 26

@(private)
Settings_Action :: enum {
	None, Position_Top, Position_Bottom, Style_Full, Style_Floating, Height, Opacity, Mode_Tiling, Mode_Floating, Gaps, Border, Master,
	Anim_Off, Anim_Fast, Anim_Normal, Indicator, Night_Light, All_Settings, Edit,
}

@(private)
Settings_Hit :: struct {
	r:      tx.Rect,
	action: Settings_Action,
	dir:    int, // -1 / +1 for steppers
}

Settings_Popup :: struct {
	card:   Card,
	anchor: i32, // screen x of the gear's right edge
	hits:   [dynamic]Settings_Hit,
	hover:  int,
}

// Animation speeds offered by the card (appearance.animationScale).
@(private) ANIM_SCALES := [3]f64{0, 0.7, 1}

reload_requested :: proc(b: ^Bar) -> bool {
	if b == nil { return false }
	requested := b.reload_flag
	b.reload_flag = false
	return requested
}

// Where the popup writes its changes.
set_config_path :: proc(b: ^Bar, path: string) {
	if b == nil { return }
	delete(b.config_path, b.allocator)
	b.config_path = strings.clone(path, b.allocator)
}

@(private)
settings_toggle :: proc(b: ^Bar, w: ^Widget) {
	if b.settings.card.open {
		settings_close(b)
		return
	}
	close_popups(b) // one popup at a time
	b.settings.anchor = widget_screen_rect(b, w).x + w.w
	b.settings.hover = -1
	card_prepare(b, &b.settings.card, settings_rect(b), "milk settings")
	settings_draw(b)
	card_map(b, &b.settings.card, true)
}

// The text in milk's language (bar.locale): Portuguese, English, or the Spanish of `en`.
@(private)
tr :: proc(b: ^Bar, pt, en: string) -> string { return config.tr(b.cfg.bar.language, pt, en) }

// The master area only means something in the tiling mode.
@(private)
settings_rows :: proc(b: ^Bar) -> int { return b.cfg.wm.mode == "floating" ? 10 : 11 }

@(private)
anim_labels :: proc(b: ^Bar) -> [3]string {
	return {tr(b, "Desligadas", "Off"), tr(b, "Rápidas", "Fast"), tr(b, "Normais", "Normal")}
}

// Segment width for a label.
@(private)
segment_width :: proc(b: ^Bar, label: string) -> i32 {
	return max(56, tx.text_width(b.c, b.font, label) + 20)
}

@(private)
settings_rect :: proc(b: ^Bar) -> tx.Rect {
	w := i32(SET_WIDTH)
	// The animation row: label + three segments must fit.
	need := tx.text_width(b.c, b.font, tr(b, "Animações", "Animations")) + 16 + 2 * SET_PAD + 12
	for l in anim_labels(b) { need += segment_width(b, l) }
	w = max(w, need)
	h := i32(SET_TITLE + settings_rows(b) * SET_ROW + SET_FOOTER + 6)
	return card_place(b, b.settings.anchor, .Right, w, h)
}

settings_close :: proc(b: ^Bar) {
	card_hide(b, &b.settings.card)
}

@(private)
settings_destroy :: proc(b: ^Bar) {
	p := &b.settings
	card_destroy(b, &p.card)
	delete(p.hits)
	p^ = {}
}

// The configuration was reloaded (possibly by us): follow the bar and redraw.
@(private)
settings_after_reload :: proc(b: ^Bar) {
	p := &b.settings
	if !p.card.open { return }
	card_resize(b, &p.card, settings_rect(b))
	settings_draw(b)
	tx.raise_window(b.c, p.card.win) // above a recreated bar window
}

@(private)
settings_event :: proc(b: ^Bar, ev: ^xlib.XEvent) {
	p := &b.settings
	#partial switch ev.type {
	case .ButtonPress:
		x, y := card_local(&p.card, ev.xbutton.x_root, ev.xbutton.y_root)
		if !card_contains(&p.card, x, y) {
			settings_close(b)
			return
		}
		if i32(ev.xbutton.button) != 1 { return }
		for hit in p.hits {
			if tx.rect_contains(hit.r, x, y) {
				settings_apply(b, hit.action, hit.dir)
				return
			}
		}
	case .KeyPress:
		if xlib.LookupKeysym(&ev.xkey, 0) == .XK_Escape { settings_close(b) }
	case .MotionNotify:
		x, y := card_local(&p.card, ev.xmotion.x_root, ev.xmotion.y_root)
		hover := -1
		for hit, i in p.hits {
			if tx.rect_contains(hit.r, x, y) { hover = i }
		}
		if hover != p.hover {
			p.hover = hover
			settings_draw(b)
		}
	case .LeaveNotify:
		if p.hover != -1 {
			p.hover = -1
			settings_draw(b)
		}
	}
}

// ---------------------------------------------------------------------------
// Changing milk.json
// ---------------------------------------------------------------------------
@(private)
settings_apply :: proc(b: ^Bar, action: Settings_Action, dir: int) {
	cfg := b.cfg
	switch action {
	case .None:
	case .Position_Top:    settings_write(b, {"bar", "position"}, json.String("top"))
	case .Position_Bottom: settings_write(b, {"bar", "position"}, json.String("bottom"))
	case .Style_Full:      settings_write(b, {"bar", "style"}, json.String("full"))
	case .Style_Floating:  settings_write(b, {"bar", "style"}, json.String("floating"))
	case .Height:
		settings_write(b, {"bar", "height"}, json.Integer(clamp(cfg.bar.height + 2 * dir, 24, 80)))
	case .Opacity:
		v := clamp(math.round((cfg.bar.opacity + 0.05 * f64(dir)) * 100) / 100, 0.3, 1)
		settings_write(b, {"bar", "opacity"}, json.Float(v))
	case .Mode_Tiling:   settings_write(b, {"wm", "mode"}, json.String("tiling"))
	case .Mode_Floating: settings_write(b, {"wm", "mode"}, json.String("floating"))
	case .Gaps:
		settings_write(b, {"wm", "gaps"}, json.Integer(clamp(cfg.wm.gaps + 2 * dir, 0, 60)))
	case .Border:
		settings_write(b, {"wm", "borderWidth"}, json.Integer(clamp(cfg.wm.border_width + dir, 0, 10)))
	case .Master:
		v := clamp(math.round((cfg.wm.master_factor + 0.05 * f64(dir)) * 100) / 100, 0.2, 0.8)
		settings_write(b, {"wm", "masterFactor"}, json.Float(v))
	case .Anim_Off:        settings_write(b, {"appearance", "animationScale"}, json.Float(ANIM_SCALES[0]))
	case .Anim_Fast:       settings_write(b, {"appearance", "animationScale"}, json.Float(ANIM_SCALES[1]))
	case .Anim_Normal:     settings_write(b, {"appearance", "animationScale"}, json.Float(ANIM_SCALES[2]))
	case .Indicator:
		settings_write(b, {"linux", "indicator", "enabled"}, json.Boolean(!cfg.linux.indicator.enabled))
	case .Night_Light:
		settings_write(b, {"nightLight", "enabled"}, json.Boolean(!cfg.night_light.enabled))
	case .All_Settings:
		settings_close(b)
		exe, err := os.get_executable_path(context.temp_allocator)
		if err != nil {
			log.warnf("Bar settings: cannot find the milk executable: %v", err)
			return
		}
		cmd := fmt.tprintf("%s settings", shell_quote(strings.trim_suffix(exe, " (deleted)")))
		if b.config_path != "" { cmd = fmt.tprintf("%s --config %s", cmd, shell_quote(b.config_path)) }
		run_detached(b, cmd)
	case .Edit:
		settings_close(b)
		if b.config_path != "" { run_detached(b, fmt.tprintf("xdg-open %s", shell_quote(b.config_path))) }
	}
}

// Set one value in milk.json (creating missing objects) and ask for a reload.
@(private)
settings_write :: proc(b: ^Bar, path: []string, value: json.Value) {
	if b.config_path == "" {
		log.warn("Bar settings: the configuration path is unknown")
		return
	}
	data, rerr := os.read_entire_file(b.config_path, context.temp_allocator)
	if rerr != nil {
		log.errorf("Bar settings: cannot read %s: %v", b.config_path, rerr)
		return
	}
	root_value, perr := json.parse(data, .JSON5, true, context.temp_allocator)
	root, is_obj := root_value.(json.Object)
	if perr != .None || !is_obj {
		log.errorf("Bar settings: cannot parse %s (%v); not changing it", b.config_path, perr)
		return
	}
	obj := root
	for key in path[:len(path) - 1] {
		child, found := obj[key]
		child_obj, ok := child.(json.Object)
		if !found || !ok {
			child_obj = make(json.Object, context.temp_allocator)
			obj[key] = child_obj
		}
		obj = child_obj
	}
	obj[path[len(path) - 1]] = value
	out, merr := json.marshal(root, {spec = .JSON, pretty = true, use_spaces = true, spaces = 2, sort_maps_by_key = true}, context.temp_allocator)
	if merr != nil {
		log.errorf("Bar settings: cannot encode the configuration: %v", merr)
		return
	}
	tmp := fmt.tprintf("%s.tmp", b.config_path)
	text := strings.concatenate({config.tidy_json_numbers(string(out)), "\n"}, context.temp_allocator)
	if werr := os.write_entire_file(tmp, text); werr != nil {
		log.errorf("Bar settings: cannot write %s: %v", tmp, werr)
		return
	}
	if err := os.rename(tmp, b.config_path); err != nil {
		log.errorf("Bar settings: cannot replace %s: %v", b.config_path, err)
		return
	}
	log.infof("Bar settings: %s = %v", strings.join(path, ".", context.temp_allocator), value)
	b.reload_flag = true
}

// When the night light warms the screen: "Always", or tonight's hours
// ("18:02–05:41" from the sun at the configured place, else from → to).
@(private)
night_light_status :: proc(b: ^Bar) -> string {
	o := &b.cfg.night_light
	if o.mode == "always" { return tr(b, "Sempre", "Always") }
	s := nightlight.schedule_from(o)
	if !s.sun { return fmt.tprintf("%s–%s", config.format_clock_time(o.from), config.format_clock_time(o.to)) }
	_, nanos := local_time()
	start, end, ok := nightlight.next_night(s, f64(nanos) / 1e9)
	if !ok { return "" }
	return fmt.tprintf("%s–%s", config.format_clock_time(nightlight.local_minutes(start)), config.format_clock_time(nightlight.local_minutes(end)))
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------
@(private)
settings_draw :: proc(b: ^Bar) {
	p := &b.settings
	c := b.c
	th := &b.theme
	cfg := b.cfg
	clear(&p.hits)
	W, H := p.card.rect.w, p.card.rect.h
	painter := painter_begin(b, W, H)
	pa := &painter

	left := i32(SET_PAD)
	right := W - SET_PAD
	paint_text(pa, b.font, left, 4, SET_TITLE, tr(b, "Ajustes rápidos", "Quick settings"), th.foreground)
	row_y := i32(SET_TITLE)

	button :: proc(pa: ^Card_Painter, r: tx.Rect, label: string, action: Settings_Action, dir: int, selected: bool) {
		p := &pa.b.settings
		hovered := !selected && p.hover == len(p.hits)
		if selected {
			paint_button(pa, r, label, true, false)
		} else {
			paint_button(pa, r, label, false, hovered)
		}
		append(&p.hits, Settings_Hit{r = r, action = action, dir = dir})
	}
	stepper :: proc(pa: ^Card_Painter, right, y: i32, value: string, action: Settings_Action) {
		b := pa.b
		bw :: SET_BUTTON
		plus := tx.Rect{right - bw, y + (SET_ROW - bw) / 2, bw, bw}
		value_w :: 58
		minus := tx.Rect{plus.x - value_w - bw, plus.y, bw, bw}
		button(pa, minus, "−", action, -1, false)
		tw := tx.text_width(b.c, b.font, value)
		paint_text(pa, b.font, minus.x + bw + (value_w - tw) / 2, y, SET_ROW, value, b.theme.foreground)
		button(pa, plus, "+", action, +1, false)
	}
	toggle :: proc(pa: ^Card_Painter, right, y: i32, on: bool, action: Settings_Action) {
		track := paint_switch(pa, right, y, SET_ROW, on)
		append(&pa.b.settings.hits, Settings_Hit{r = track, action = action})
	}
	// Segmented choice: buttons right-aligned, the selected one filled.
	segments :: proc(pa: ^Card_Painter, right, y: i32, labels: []string, widths: []i32, actions: []Settings_Action, selected: int) {
		x := right
		for i := len(labels) - 1; i >= 0; i -= 1 {
			x -= widths[i]
			button(pa, {x, y + (SET_ROW - SET_BUTTON) / 2, widths[i], SET_BUTTON}, labels[i], actions[i], 0, i == selected)
			x -= 6
		}
	}
	label :: proc(pa: ^Card_Painter, x, y: i32, s: string) {
		paint_text(pa, pa.b.font, x, y, SET_ROW, s, pa.b.theme.foreground)
	}

	// Position and style share one segment width, wide enough for every label.
	top_l, bottom_l := tr(b, "Topo", "Top"), tr(b, "Base", "Bottom")
	full_l, float_l := tr(b, "Inteira", "Full"), tr(b, "Flutuante", "Floating")
	seg_w := i32(68)
	for l in ([]string{top_l, bottom_l, full_l, float_l}) { seg_w = max(seg_w, segment_width(b, l)) }
	label(pa, left, row_y, tr(b, "Posição da barra", "Bar position"))
	segments(pa, right, row_y, {top_l, bottom_l}, {seg_w, seg_w}, {.Position_Top, .Position_Bottom}, cfg.bar.position == "bottom" ? 1 : 0)
	row_y += SET_ROW
	label(pa, left, row_y, tr(b, "Estilo da barra", "Bar style"))
	segments(pa, right, row_y, {full_l, float_l}, {seg_w, seg_w}, {.Style_Full, .Style_Floating}, cfg.bar.style == "floating" ? 1 : 0)
	row_y += SET_ROW

	label(pa, left, row_y, tr(b, "Altura da barra", "Bar height"))
	stepper(pa, right, row_y, fmt.tprintf("%d px", cfg.bar.height), .Height)
	row_y += SET_ROW
	label(pa, left, row_y, tr(b, "Opacidade da barra", "Bar opacity"))
	stepper(pa, right, row_y, fmt.tprintf("%d%%", int(math.round(cfg.bar.opacity * 100))), .Opacity)
	row_y += SET_ROW
	tiling_l, floating_l := tr(b, "Lado a lado", "Tiling"), tr(b, "Flutuantes", "Floating")
	mode_w := max(segment_width(b, tiling_l), segment_width(b, floating_l))
	floating := cfg.wm.mode == "floating"
	label(pa, left, row_y, tr(b, "Janelas", "Windows"))
	segments(pa, right, row_y, {tiling_l, floating_l}, {mode_w, mode_w}, {.Mode_Tiling, .Mode_Floating}, floating ? 1 : 0)
	row_y += SET_ROW
	label(pa, left, row_y, tr(b, "Espaçamento (gaps)", "Gaps"))
	stepper(pa, right, row_y, fmt.tprintf("%d px", cfg.wm.gaps), .Gaps)
	row_y += SET_ROW
	label(pa, left, row_y, tr(b, "Borda das janelas", "Window borders"))
	stepper(pa, right, row_y, fmt.tprintf("%d px", cfg.wm.border_width), .Border)
	row_y += SET_ROW
	if !floating {
		label(pa, left, row_y, tr(b, "Área mestre", "Master size"))
		stepper(pa, right, row_y, fmt.tprintf("%d%%", int(math.round(cfg.wm.master_factor * 100))), .Master)
		row_y += SET_ROW
	}

	// Animation speed: the closest preset is selected.
	label(pa, left, row_y, tr(b, "Animações", "Animations"))
	labels := anim_labels(b)
	widths: [3]i32
	for l, i in labels { widths[i] = segment_width(b, l) }
	selected := 0
	scale := cfg.appearance.animation_scale
	for v, i in ANIM_SCALES {
		if abs(v - scale) < abs(ANIM_SCALES[selected] - scale) { selected = i }
	}
	segments(pa, right, row_y, labels[:], widths[:], {.Anim_Off, .Anim_Fast, .Anim_Normal}, selected)
	row_y += SET_ROW
	label(pa, left, row_y, tr(b, "Aviso de área", "Area toast"))
	toggle(pa, right, row_y, cfg.linux.indicator.enabled, .Indicator)
	row_y += SET_ROW
	// Night light: its hours (or "Always") in grey before the switch.
	label(pa, left, row_y, tr(b, "Luz noturna", "Night light"))
	if status := night_light_status(b); status != "" {
		paint_text(pa, b.font, right - 44 - 12 - tx.text_width(c, b.font, status), row_y, SET_ROW, status, th.muted)
	}
	toggle(pa, right, row_y, cfg.night_light.enabled, .Night_Light)
	row_y += SET_ROW

	// Footer: the full settings app; the raw file as a small text button when it fits.
	paint_divider(pa, left, row_y + 6, right - left)
	all_label := tr(b, "Todas as configurações", "All settings")
	all_w := tx.text_width(c, b.font, all_label) + 32
	all := tx.Rect{right - all_w, row_y + 16, all_w, 30}
	paint_button(pa, all, all_label, true, p.hover == len(p.hits))
	append(&p.hits, Settings_Hit{r = all, action = .All_Settings})
	config_name := filepath.base(b.config_path) if b.config_path != "" else "milk.json"
	edit_label := fmt.tprintf(tr(b, "Editar %s", "Edit %s"), config_name)
	edit_w := tx.text_width(c, b.font, edit_label) + 20
	if b.config_path != "" && left - 10 + edit_w + 8 <= all.x {
		edit := tx.Rect{left - 10, all.y, edit_w, all.h}
		if p.hover == len(p.hits) { tx.canvas_fill_rounded_rect(&pa.cv, edit, f32(edit.h) / 2, th.surface) }
		paint_text(pa, b.font, edit.x + 10, edit.y, edit.h, edit_label, th.muted)
		append(&p.hits, Settings_Hit{r = edit, action = .Edit})
	}

	painter_present(pa, &p.card)
}
