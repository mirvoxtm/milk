// Settings → Tela (Display): the night light (nightLight: on/off, when, the
// temperature with a live preview on screen, the hours, the place for sunset
// and sunrise, the transition) and the volume/brightness pop-up (osd).
//
// Dragging the temperature asks the running milk to show it at once
// (nightlight.preview: a client message to the root window) even during the
// day or with the night light off; the value is saved like any other.
package oobe

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"
import config "../config"
import nightlight "../nightlight"
import tx "../tx"

@(private) NL_MODE_NAMES :: [3]string{"always", "sunset", "manual"}
@(private) OSD_CHOICES   :: [4]string{"", "bottom", "center", "top"} // "" = off
@(private) NL_SLIDER_MIN :: config.NIGHT_LIGHT_MIN_K
@(private) NL_SLIDER_MAX :: config.NIGHT_LIGHT_MAX_K
@(private) NL_STEP       :: 100 // kelvin
@(private) TRANSITION_STEPS :: [11]int{0, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180} // minutes

// Display_Ui arguments.
@(private) DISPLAY_SLIDER :: 0
@(private) DISPLAY_LOCATE :: 1

@(private)
Display_Settings :: struct {
	nl_enabled:    bool,
	nl_mode:       int, // NL_MODE_NAMES
	nl_temp:       int, // kelvin
	nl_transition: int, // minutes
	nl_from:       [dynamic]u8,
	nl_to:         [dynamic]u8,
	nl_lat:        [dynamic]u8,
	nl_lon:        [dynamic]u8,
	osd_choice:    int, // OSD_CHOICES
	// The temperature slider.
	track:         tx.Rect, // as last drawn (window coordinates)
	dragging:      bool,
	previewed:     int,     // last temperature sent to milk
	locate_failed: bool,    // the time zone gave no place (the row says so)
}

@(private)
display_load_values :: proc(w: ^Wizard) {
	d := &w.set.disp
	nl := &w.cfg.night_light
	d.nl_enabled = nl.enabled
	for name, i in NL_MODE_NAMES { if name == nl.mode { d.nl_mode = i } }
	d.nl_temp = nl.temperature
	d.nl_transition = nl.transition
	append(&d.nl_from, ..transmute([]u8)config.format_clock_time(nl.from))
	append(&d.nl_to, ..transmute([]u8)config.format_clock_time(nl.to))
	if v, ok := nl.latitude.?; ok { append(&d.nl_lat, ..transmute([]u8)format_degrees(v)) }
	if v, ok := nl.longitude.?; ok { append(&d.nl_lon, ..transmute([]u8)format_degrees(v)) }
	d.osd_choice = 0
	if w.cfg.osd.enabled {
		for name, i in OSD_CHOICES { if i > 0 && name == w.cfg.osd.position { d.osd_choice = i } }
		if d.osd_choice == 0 { d.osd_choice = 1 }
	}
}

@(private)
display_destroy :: proc(w: ^Wizard) {
	d := &w.set.disp
	delete(d.nl_from)
	delete(d.nl_to)
	delete(d.nl_lat)
	delete(d.nl_lon)
	d^ = {}
}

// Degrees with up to four decimals, no trailing zeros ("-23.5505", "12.5").
@(private)
format_degrees :: proc(v: f64) -> string {
	s := fmt.tprintf("%.4f", v)
	s = strings.trim_right(s, "0")
	return strings.trim_right(s, ".")
}

// A coordinate typed by the user ("-23,55" too); ok = false when invalid.
@(private)
parse_degrees :: proc(text: string, limit: f64) -> (f64, bool) {
	t, _ := strings.replace_all(strings.trim_space(text), ",", ".", context.temp_allocator)
	v, ok := strconv.parse_f64(t)
	if !ok || math.is_nan(v) || abs(v) > limit { return 0, false }
	return v, true
}

// The place typed in the fields, when both are valid.
@(private)
display_place :: proc(d: ^Display_Settings) -> (lat, lon: f64, ok: bool) {
	la, ok1 := parse_degrees(string(d.nl_lat[:]), 90)
	lo, ok2 := parse_degrees(string(d.nl_lon[:]), 180)
	return la, lo, ok1 && ok2
}

// The schedule as edited (for "Tonight: 18:02 to 05:41"); a time being typed
// that is not valid yet counts as the saved one.
@(private)
display_schedule :: proc(w: ^Wizard) -> nightlight.Schedule {
	d := &w.set.disp
	s := nightlight.Schedule{transition = f64(d.nl_transition) * 60}
	ok: bool
	if s.from, ok = config.parse_clock_time(string(d.nl_from[:])); !ok { s.from = w.cfg.night_light.from }
	if s.to, ok = config.parse_clock_time(string(d.nl_to[:])); !ok { s.to = w.cfg.night_light.to }
	names := NL_MODE_NAMES
	if lat, lon, placed := display_place(d); placed && names[d.nl_mode] == "sunset" {
		s.sun = true
		s.latitude, s.longitude = lat, lon
	}
	return s
}

@(private)
unix_now :: proc() -> f64 {
	return f64(time.to_unix_nanoseconds(time.now())) / 1e9
}

@(private)
hhmm :: proc(unix: f64) -> string {
	return config.format_clock_time(nightlight.local_minutes(unix))
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------
@(private)
draw_display_section :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	d := &w.set.disp
	th := &w.theme
	y := c.y
	off := !d.nl_enabled
	names := NL_MODE_NAMES
	mode := names[d.nl_mode]
	_, _, has_place := display_place(d)

	row := next_row(w, cv, c, &y, tr(w, "Luz noturna", "Night light"),
	                tr(w, "Cores mais quentes à noite, mais fáceis para os olhos", "Warmer colours at night, easier on the eyes"))
	toggle(w, cv, row, d.nl_enabled, .Nl_Enabled)

	// When: always, from sunset to sunrise, or between two times.
	when_desc: string
	switch {
	case mode == "always":
		when_desc = tr(w, "O tempo todo", "All the time")
	case mode == "sunset" && !has_place:
		when_desc = tr(w, "Sem local: usando o horário abaixo", "No place set: using the hours below")
	case:
		start, end, ok := nightlight.next_night(display_schedule(w), unix_now())
		if ok {
			when_desc = fmt.tprintf(tr(w, "Esta noite: das %s às %s", "Tonight: %s to %s"), hhmm(start), hhmm(end))
		} else {
			when_desc = tr(w, "O sol não se põe ou não nasce nestes dias", "The sun does not set or rise these days")
		}
	}
	row = next_row(w, cv, c, &y, tr(w, "Quando", "When"), when_desc, off)
	cw := min(i32(400), c.w - 280)
	choice_control(w, cv, {row.x + row.w - cw, row.y + 8, cw, 40},
	               {tr(w, "Sempre", "Always"), tr(w, "Pôr do sol", "Sunset"), tr(w, "Horário", "Hours")}, d.nl_mode, .Nl_Mode)

	// Temperature: a slider coloured like the result, with a live preview.
	row = next_row(w, cv, c, &y, tr(w, "Temperatura", "Temperature"),
	               tr(w, "Arraste para ver na tela", "Drag to see it on screen"), off)
	draw_temperature_slider(w, cv, row)

	// Hours (manual, or sunset without a place).
	hours_used: bool = mode == "manual" || (mode == "sunset" && !has_place)
	row = next_row(w, cv, c, &y, tr(w, "Horário", "Hours"), "", off || !hours_used)
	{
		fw: i32 = 104
		to_r := tx.Rect{row.x + row.w - fw, row.y + 8, fw, 40}
		to_label := tr(w, "até", "to")
		lw := text_width(w, w.f_body, to_label)
		from_r := tx.Rect{to_r.x - 12 - lw - 12 - fw, to_r.y, fw, 40}
		time_field(w, cv, from_r, d.nl_from[:], "20:00", .Nl_From)
		text(w, w.f_body, from_r.x + fw + 12, row.y, row.h, to_label, th.fg)
		time_field(w, cv, to_r, d.nl_to[:], "07:00", .Nl_To)
	}

	// Place: latitude and longitude, or the time zone's main city.
	place_desc := tr(w, "Graus; sul e oeste são negativos", "Degrees; south and west are negative")
	if d.locate_failed { place_desc = tr(w, "O fuso horário não indica um local", "The time zone gives no place") }
	row = next_row(w, cv, c, &y, tr(w, "Local", "Place"), place_desc, off || mode != "sunset")
	{
		// A compact pill: the time zone's place (just the icon when space is short).
		locate := tr(w, "Fuso horário", "Time zone")
		bw := text_width(w, w.f_body, locate) + 58
		if row.w < 600 { bw = 40 }
		btn := tx.Rect{row.x + row.w - bw, row.y + 8, bw, 40}
		fw: i32 = 116
		lon_r := tx.Rect{btn.x - 10 - fw, row.y + 8, fw, 40}
		lat_r := tx.Rect{lon_r.x - 8 - fw, row.y + 8, fw, 40}
		degree_field(w, cv, lat_r, d.nl_lat[:], tr(w, "Latitude", "Latitude"), .Nl_Lat, 90)
		degree_field(w, cv, lon_r, d.nl_lon[:], tr(w, "Longitude", "Longitude"), .Nl_Lon, 180)
		fill_rounded(cv, btn, 20, hovered(w, .Display_Ui, DISPLAY_LOCATE) ? th.hover : th.surface)
		if bw == 40 {
			icon(w, w.f_icon_small, btn, .World, th.fg)
		} else {
			icon(w, w.f_icon_small, {btn.x + 12, btn.y, 22, btn.h}, .World, th.fg)
			text(w, w.f_body, btn.x + 40, btn.y, btn.h, locate, th.fg)
		}
		add_hit(w, btn, .Display_Ui, DISPLAY_LOCATE)
	}

	row = next_row(w, cv, c, &y, tr(w, "Transição", "Transition"),
	               tr(w, "Quanto tempo a mudança leva", "How long the change takes"), off || mode == "always")
	stepper(w, cv, row, d.nl_transition == 0 ? tr(w, "Imediata", "Instant") : fmt.tprintf("%d min", d.nl_transition), .Nl_Transition)

	// The volume/brightness pop-up.
	y += 10
	row = next_row(w, cv, c, &y, tr(w, "Aviso de volume e brilho", "Volume and brightness pop-up"),
	               tr(w, "Ao usar as teclas de volume e brilho", "When the volume and brightness keys are used"))
	ow := min(i32(440), c.w - 300)
	choice_control(w, cv, {row.x + row.w - ow, row.y + 8, ow, 40},
	               {tr(w, "Desligado", "Disabled"), tr(w, "Embaixo", "Bottom"), tr(w, "Centro", "Middle"), tr(w, "Em cima", "Top")},
	               d.osd_choice, .Osd_Position)
}

// A text field for "HH:MM" (outlined in the warning colour while invalid).
@(private)
time_field :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect, buf: []u8, placeholder: string, ctrl: Control) {
	focused := w.focus == .Text && w.set.text_target == int(ctrl) * 100
	draw_field(w, cv, r, .None, string(buf), placeholder, focused, .Text_Field, int(ctrl) * 100)
	if _, ok := config.parse_clock_time(string(buf)); !ok && len(buf) > 0 && !focused {
		tx.canvas_stroke_rounded_rect(cv, r, f32(r.h) / 2, 2, w.theme.warning)
	}
}

@(private)
degree_field :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect, buf: []u8, placeholder: string, ctrl: Control, limit: f64) {
	focused := w.focus == .Text && w.set.text_target == int(ctrl) * 100
	draw_field(w, cv, r, .None, string(buf), placeholder, focused, .Text_Field, int(ctrl) * 100)
	if _, ok := parse_degrees(string(buf), limit); !ok && len(buf) > 0 && !focused {
		tx.canvas_stroke_rounded_rect(cv, r, f32(r.h) / 2, 2, w.theme.warning)
	}
}

// Track painted with the colour white takes at each temperature, a thumb at
// the chosen one and its value on the right.
@(private)
draw_temperature_slider :: proc(w: ^Wizard, cv: ^tx.Canvas, row: tx.Rect) {
	d := &w.set.disp
	th := &w.theme
	label := fmt.tprintf("%d K", d.nl_temp)
	value_w := text_width(w, w.f_body, "6500 K") + 8
	track_w := min(i32(320), row.w - 300)
	track := tx.Rect{row.x + row.w - value_w - 16 - track_w, row.y + (row.h - 12) / 2, track_w, 12}
	d.track = track
	// The gradient: one column per pixel.
	strip := tx.canvas_make(track.w, track.h, context.temp_allocator)
	for x in 0 ..< track.w {
		k := f64(NL_SLIDER_MIN) + f64(NL_SLIDER_MAX - NL_SLIDER_MIN) * f64(x) / f64(max(track.w - 1, 1))
		m := nightlight.whitepoint(k)
		col := tx.rgb(u8(255 * m[0]), u8(255 * m[1]), u8(255 * m[2]))
		tx.canvas_fill_rect(&strip, {x, 0, 1, track.h}, col)
	}
	composite_rounded(cv, strip, track.x, track.y, f32(track.h) / 2)
	tx.canvas_stroke_rounded_rect(cv, track, f32(track.h) / 2, 1, th.outline)
	t := f32(d.nl_temp - NL_SLIDER_MIN) / f32(NL_SLIDER_MAX - NL_SLIDER_MIN)
	cx := f32(track.x) + f32(track.w) * clamp(t, 0, 1)
	cy := f32(track.y) + f32(track.h) / 2
	m := nightlight.whitepoint(f64(d.nl_temp))
	hot := d.dragging || hovered(w, .Display_Ui, DISPLAY_SLIDER)
	if hot { tx.canvas_fill_circle(cv, cx, cy, 17, tx.color_with_alpha(th.accent, 40)) }
	tx.canvas_fill_circle(cv, cx, cy + 1, 12, tx.rgba(0, 0, 0, 50))
	tx.canvas_fill_circle(cv, cx, cy, 11, th.accent)
	tx.canvas_fill_circle(cv, cx, cy, 8, tx.rgb(u8(255 * m[0]), u8(255 * m[1]), u8(255 * m[2])))
	text(w, w.f_body, row.x + row.w - value_w, row.y, row.h, label, th.fg)
	add_hit(w, {track.x - 14, row.y, track.w + 28, row.h}, .Display_Ui, DISPLAY_SLIDER)
}

// ---------------------------------------------------------------------------
// Changes
// ---------------------------------------------------------------------------

// The slider and the time zone button (Action.Display_Ui).
@(private)
display_action :: proc(w: ^Wizard, arg: int) {
	d := &w.set.disp
	switch arg {
	case DISPLAY_SLIDER:
		d.dragging = true
		temperature_at(w, w.pointer.x)
	case DISPLAY_LOCATE:
		lat, lon, _, ok := nightlight.timezone_location()
		d.locate_failed = !ok
		if !ok { break }
		clear(&d.nl_lat)
		clear(&d.nl_lon)
		append(&d.nl_lat, ..transmute([]u8)format_degrees(math.round(lat * 100) / 100))
		append(&d.nl_lon, ..transmute([]u8)format_degrees(math.round(lon * 100) / 100))
		set_edit(w, "nightLight.latitude", json.Float(math.round(lat * 100) / 100))
		set_edit(w, "nightLight.longitude", json.Float(math.round(lon * 100) / 100))
		settings_changed(w, .Values)
	}
	w.dirty = true
}

// Pointer motion with the first button held keeps dragging the slider.
@(private)
display_drag :: proc(w: ^Wizard, x: i32, held: bool) {
	d := &w.set.disp
	if !d.dragging { return }
	if !held {
		d.dragging = false
		w.dirty = true
		return
	}
	temperature_at(w, x)
}

@(private)
temperature_at :: proc(w: ^Wizard, x: i32) {
	d := &w.set.disp
	r := d.track
	if r.w <= 0 { return }
	t := clamp(f64(x - r.x) / f64(r.w), 0, 1)
	k := int(math.round((f64(NL_SLIDER_MIN) + t * f64(NL_SLIDER_MAX - NL_SLIDER_MIN)) / NL_STEP)) * NL_STEP
	k = clamp(k, NL_SLIDER_MIN, NL_SLIDER_MAX)
	if k != d.previewed {
		d.previewed = k
		nightlight.preview(w.c, k) // milk shows it for a few seconds
	}
	if k == d.nl_temp { return }
	d.nl_temp = k
	set_edit(w, "nightLight.temperature", json.Integer(k))
	settings_changed(w, .Values)
}

@(private)
display_choice :: proc(w: ^Wizard, ctrl: Control, opt: int) -> bool {
	d := &w.set.disp
	#partial switch ctrl {
	case .Nl_Mode:
		names := NL_MODE_NAMES
		d.nl_mode = clamp(opt, 0, len(names) - 1)
		set_edit(w, "nightLight.mode", json.String(names[d.nl_mode]))
	case .Osd_Position:
		names := OSD_CHOICES
		d.osd_choice = clamp(opt, 0, len(names) - 1)
		set_edit(w, "osd.enabled", json.Boolean(d.osd_choice > 0))
		if d.osd_choice > 0 { set_edit(w, "osd.position", json.String(names[d.osd_choice])) }
	case:
		return false
	}
	return true
}

@(private)
display_toggle :: proc(w: ^Wizard, ctrl: Control) -> bool {
	d := &w.set.disp
	#partial switch ctrl {
	case .Nl_Enabled:
		d.nl_enabled = !d.nl_enabled
		set_edit(w, "nightLight.enabled", json.Boolean(d.nl_enabled))
	case:
		return false
	}
	return true
}

@(private)
display_step :: proc(w: ^Wizard, ctrl: Control, dir: int) -> bool {
	d := &w.set.disp
	#partial switch ctrl {
	case .Nl_Transition:
		steps := TRANSITION_STEPS
		i := 0
		for v, k in steps { if abs(v - d.nl_transition) < abs(steps[i] - d.nl_transition) { i = k } }
		d.nl_transition = steps[clamp(i + dir, 0, len(steps) - 1)]
		set_edit(w, "nightLight.transition", json.Integer(d.nl_transition))
	case:
		return false
	}
	return true
}

@(private)
display_text_buffer :: proc(w: ^Wizard, ctrl: Control) -> ^[dynamic]u8 {
	d := &w.set.disp
	#partial switch ctrl {
	case .Nl_From: return &d.nl_from
	case .Nl_To:   return &d.nl_to
	case .Nl_Lat:  return &d.nl_lat
	case .Nl_Lon:  return &d.nl_lon
	}
	return nil
}

// A field changed: saved when valid (an empty place clears it).
@(private)
display_text_edited :: proc(w: ^Wizard, ctrl: Control) -> bool {
	d := &w.set.disp
	#partial switch ctrl {
	case .Nl_From, .Nl_To:
		buf := ctrl == .Nl_From ? d.nl_from[:] : d.nl_to[:]
		m, ok := config.parse_clock_time(string(buf))
		if !ok { return false }
		set_edit(w, ctrl == .Nl_From ? "nightLight.from" : "nightLight.to", json.String(config.format_clock_time(m)))
	case .Nl_Lat, .Nl_Lon:
		buf := ctrl == .Nl_Lat ? d.nl_lat[:] : d.nl_lon[:]
		key := ctrl == .Nl_Lat ? "nightLight.latitude" : "nightLight.longitude"
		if strings.trim_space(string(buf)) == "" {
			set_edit(w, key, json.Value(json.Null(nil)))
		} else {
			v, ok := parse_degrees(string(buf), ctrl == .Nl_Lat ? 90 : 180)
			if !ok { return false }
			set_edit(w, key, json.Float(v))
		}
		d.locate_failed = false
	case:
		return false
	}
	return true
}
