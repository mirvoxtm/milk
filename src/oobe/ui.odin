// Drawing: theme, fonts, the card with its backdrop, and the small widget
// set the pages are built from (buttons, segmented controls, rounded
// composites). Shapes are composed on the CPU canvas; text is drawn with Xft
// on the uploaded pixmap, as in the bar's quick-settings card.
package oobe

import "core:math"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

@(private) PAD          :: 40  // card padding
@(private) HEADER_H     :: 150 // brand row, title and subtitle
@(private) FOOTER_H     :: 92
@(private) CARD_RADIUS  :: 28
@(private) BUTTON_H     :: 44
@(private) ROW_H        :: 40  // list rows

@(private)
Theme :: struct {
	bg, fg, muted, accent, accent_fg, surface, warning, border, focus: tx.Color,
	dark:     bool,
	field:    tx.Color, // input fields, list containers, unselected cards
	outline:  tx.Color,
	hover:    tx.Color,
	backdrop: [2]tx.Color, // gradient behind the card
}

@(private)
Icon :: enum {
	None, Sun, Moon, Check, Arrow_Left, Arrow_Right, Palette, Keyboard, Photo, Photo_Off,
	Layout_Top, Layout_Bottom, Search, Sparkles, Rocket, Milk, Desktop, Bell, Clipboard, Layout_Grid, Info, App_Window,
	Plus, Pencil, Trash, Chevron_Down, Chevron_Right, World, Terminal, Apps, Command, Alert,
	Arrow_Up, Arrow_Down, Layout_Dashboard, Player_Play, Space, Wifi, Bluetooth, Volume, Battery, Calendar, Clock,
	Settings, Power,
}

// Tabler codepoints (the font the bar uses; see /usr/share/noctalia/assets/fonts/tabler.json).
@(private, rodata)
ICON_CODES := [Icon]rune{
	.None = 0, .Sun = 0xEB30, .Moon = 0xEAF8, .Check = 0xEA5E, .Arrow_Left = 0xEA19, .Arrow_Right = 0xEA1F,
	.Palette = 0xEB01, .Keyboard = 0xEBD6, .Photo = 0xEB0A, .Photo_Off = 0xECF6, .Layout_Top = 0xEAD7,
	.Layout_Bottom = 0xEAD3, .Search = 0xEB1C, .Sparkles = 0xF6D7, .Rocket = 0xEC45, .Milk = 0xEF13,
	.Desktop = 0xEA89, .Bell = 0xEA35, .Clipboard = 0xEA6F, .Layout_Grid = 0xEDBA, .Info = 0xEAC5, .App_Window = 0xEFE6,
	.Plus = 0xEB0B, .Pencil = 0xEB04, .Trash = 0xEB41, .Chevron_Down = 0xEA5F, .Chevron_Right = 0xEA61, .World = 0xEB54,
	.Terminal = 0xEBEF, .Apps = 0xEBB6, .Command = 0xEA78, .Alert = 0xEA06,
	.Arrow_Up = 0xEA25, .Arrow_Down = 0xEA16, .Layout_Dashboard = 0xF02C, .Player_Play = 0xED46, .Space = 0xEC0C,
	.Wifi = 0xEB52, .Bluetooth = 0xEA37, .Volume = 0xEB51, .Battery = 0xEA31, .Calendar = 0xEA53, .Clock = 0xEA70,
	.Settings = 0xEB20, .Power = 0xEB0D,
}

foreign import xft_clip "system:Xft"
@(default_calling_convention="c")
foreign xft_clip {
	@(private) XftDrawSetClipRectangles :: proc(draw: ^tx.XftDraw, x, y: i32, rects: [^]xlib.XRectangle, n: i32) -> b32 ---
	@(private) XftDrawSetClip :: proc(draw: ^tx.XftDraw, region: rawptr) -> b32 ---
}

@(private)
opaque :: proc(c: tx.Color) -> tx.Color { return {c.r, c.g, c.b, 255} }

@(private)
mix :: proc(a, b: tx.Color, t: f32) -> tx.Color { return opaque(tx.color_mix(a, b, t)) }

@(private)
theme_from_colors :: proc(colors: config.Theme_Colors, dark: bool) -> Theme {
	b := colors.bar
	t: Theme
	t.bg = tx.color_from_hex(b.background, tx.rgb(0xF5, 0xEE, 0xE6))
	t.fg = tx.color_from_hex(b.foreground, tx.rgb(0x3C, 0x3A, 0x38))
	t.muted = tx.color_from_hex(b.muted, tx.rgb(0xA8, 0x9E, 0x94))
	t.accent = tx.color_from_hex(b.accent, tx.rgb(0x4A, 0x3F, 0x35))
	t.accent_fg = tx.color_from_hex(b.accent_foreground, tx.rgb(0xF5, 0xEE, 0xE6))
	t.surface = tx.color_from_hex(b.surface, tx.rgb(0xE9, 0xE0, 0xD6))
	t.warning = tx.color_from_hex(b.warning, tx.rgb(0xB5, 0x47, 0x3A))
	t.border = tx.color_from_hex(colors.border_color, t.surface)
	t.focus = tx.color_from_hex(colors.focus_color, t.accent)
	t.dark = dark
	black := tx.rgb(0, 0, 0)
	if dark {
		t.field = mix(t.bg, t.surface, 0.8)
		t.outline = mix(t.surface, t.muted, 0.28)
		t.hover = mix(t.surface, t.muted, 0.22)
		t.backdrop = {mix(t.bg, black, 0.45), mix(mix(t.bg, t.accent, 0.16), black, 0.3)}
	} else {
		t.field = mix(t.bg, t.surface, 0.7)
		t.outline = mix(t.surface, t.muted, 0.4)
		t.hover = mix(t.surface, t.muted, 0.2)
		t.backdrop = {mix(t.surface, t.muted, 0.18), mix(t.surface, t.accent, 0.22)}
	}
	return t
}

@(private)
preset_theme :: proc(index: int, dark: bool) -> Theme {
	p := config.THEME_PRESETS[clamp(index, 0, len(config.THEME_PRESETS) - 1)]
	return theme_from_colors(dark ? p.dark : p.light, dark)
}

// The wizard wears the theme being chosen.
@(private)
update_theme :: proc(w: ^Wizard) {
	w.theme = current_theme(w)
	w.base_dirty = true
	w.dirty = true
}

// ---------------------------------------------------------------------------
// Fonts
// ---------------------------------------------------------------------------
@(private)
open_fonts :: proc(w: ^Wizard) -> bool {
	c := w.c
	family := w.cfg.bar.font
	open :: proc(c: ^tx.Connection, family, style: string, px: i32) -> ^tx.Font {
		pattern := style == "" ? family : strings.concatenate({family, ":", style}, context.temp_allocator)
		if f, ok := tx.font_open(c, pattern, px); ok { return f }
		fallback := style == "" ? "sans" : strings.concatenate({"sans:", style}, context.temp_allocator)
		f, _ := tx.font_open(c, fallback, px)
		return f
	}
	w.f_title = open(c, family, "bold", 30)
	w.f_h2 = open(c, family, "bold", 17)
	w.f_body = open(c, family, "", 15)
	w.f_small = open(c, family, "", 13)
	w.f_tiny = open(c, family, "bold", 11)
	if w.f_title == nil || w.f_h2 == nil || w.f_body == nil || w.f_small == nil || w.f_tiny == nil { return false }
	if file := w.cfg.bar.icon_font_file; file != "" && os.exists(file) {
		w.f_icon, _ = tx.font_open_file(c, file, 20)
		w.f_icon_small, _ = tx.font_open_file(c, file, 17)
		w.f_icon_big, _ = tx.font_open_file(c, file, 40)
		if w.f_icon != nil && !tx.font_has_glyph(c, w.f_icon, ICON_CODES[.Check]) {
			close_icon_fonts(w)
		}
	}
	return true
}

@(private)
close_icon_fonts :: proc(w: ^Wizard) {
	tx.font_close(w.c, w.f_icon); w.f_icon = nil
	tx.font_close(w.c, w.f_icon_small); w.f_icon_small = nil
	tx.font_close(w.c, w.f_icon_big); w.f_icon_big = nil
}

@(private)
close_fonts :: proc(w: ^Wizard) {
	for f in ([]^tx.Font{w.f_title, w.f_h2, w.f_body, w.f_small, w.f_tiny}) { tx.font_close(w.c, f) }
	w.f_title, w.f_h2, w.f_body, w.f_small, w.f_tiny = nil, nil, nil, nil, nil
	close_icon_fonts(w)
}

@(private)
icon_str :: proc(icon: Icon) -> string {
	if icon == .None { return "" }
	buf, n := utf8.encode_rune(ICON_CODES[icon])
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------
@(private)
text_width :: proc(w: ^Wizard, f: ^tx.Font, s: string) -> i32 { return tx.text_width(w.c, f, s) }

@(private)
text :: proc(w: ^Wizard, f: ^tx.Font, x, y, h: i32, s: string, color: tx.Color, clip := tx.Rect{}) {
	if f == nil || s == "" { return }
	append(&w.texts, Text_Item{x = x, y = y, h = h, s = s, font = f, color = color, clip = clip})
}

@(private)
text_centered :: proc(w: ^Wizard, f: ^tx.Font, r: tx.Rect, s: string, color: tx.Color, clip := tx.Rect{}) {
	if f == nil { return }
	tw := text_width(w, f, s)
	text(w, f, r.x + (r.w - tw) / 2, r.y, r.h, s, color, clip)
}

// An icon glyph centred in `r` (nothing when the icon font is missing).
@(private)
icon :: proc(w: ^Wizard, f: ^tx.Font, r: tx.Rect, which: Icon, color: tx.Color, clip := tx.Rect{}) {
	if f == nil || which == .None { return }
	text_centered(w, f, r, icon_str(which), color, clip)
}

@(private)
ellipsize :: proc(w: ^Wizard, f: ^tx.Font, s: string, max_w: i32) -> string {
	return tx.text_ellipsize(w.c, f, s, max_w)
}

@(private)
add_hit :: proc(w: ^Wizard, r: tx.Rect, action: Action, arg: int = 0, clip := tx.Rect{}) {
	append(&w.hits, Hit{r = r, clip = clip, action = action, arg = arg})
}

@(private)
hovered :: proc(w: ^Wizard, action: Action, arg: int = 0) -> bool {
	return w.hover.action == action && w.hover.arg == arg
}

// Layered soft shadow under a rounded rectangle.
@(private)
shadow :: proc(cv: ^tx.Canvas, r: tx.Rect, radius: f32, layers: int, strength: f32, dy: i32 = 3) {
	for i in 1 ..= layers {
		s := i32(i)
		a := strength * f32(layers + 1 - i) / f32(layers)
		tx.canvas_fill_rounded_rect(cv, {r.x - s + 1, r.y - s + dy, r.w + 2 * s - 2, r.h + 2 * s - 2}, radius + f32(s), tx.rgba(0, 0, 0, u8(clamp(a, 0, 255))))
	}
}

@(private)
blend :: #force_inline proc(dst: u32, src: u32, cov: f32) -> u32 {
	if cov >= 1 { return src }
	dr, dg, db := f32((dst >> 16) & 0xFF), f32((dst >> 8) & 0xFF), f32(dst & 0xFF)
	sr, sg, sb := f32((src >> 16) & 0xFF), f32((src >> 8) & 0xFF), f32(src & 0xFF)
	r := u32(dr + (sr - dr) * cov)
	g := u32(dg + (sg - dg) * cov)
	b := u32(db + (sb - db) * cov)
	return r << 16 | g << 8 | b
}

// Coverage of pixel (px, py) (centre coordinates, relative to the box) inside
// a w×h box with rounded corners.
@(private)
rounded_coverage :: #force_inline proc(px, py, w, h, rad: f32) -> f32 {
	cx := clamp(px, rad, w - rad)
	cy := clamp(py, rad, h - rad)
	dx := px - cx
	dy := py - cy
	if dx == 0 && dy == 0 { return 1 }
	return clamp(rad - math.sqrt(dx * dx + dy * dy) + 0.5, 0, 1)
}

// Copy `src` onto `dst` at (x, y) through a rounded-rectangle mask.
@(private)
composite_rounded :: proc(dst: ^tx.Canvas, src: tx.Canvas, x, y: i32, radius: f32) {
	rad := clamp(radius, 0, f32(min(src.w, src.h)) / 2)
	fw, fh := f32(src.w), f32(src.h)
	for sy in 0 ..< src.h {
		dy := y + sy
		if dy < 0 || dy >= dst.h { continue }
		for sx in 0 ..< src.w {
			dx := x + sx
			if dx < 0 || dx >= dst.w { continue }
			cov := rounded_coverage(f32(sx) + 0.5, f32(sy) + 0.5, fw, fh, rad)
			if cov <= 0 { continue }
			i := int(dy) * int(dst.w) + int(dx)
			dst.px[i] = blend(dst.px[i], src.px[int(sy) * int(src.w) + int(sx)], cov)
		}
	}
}

// Draw an opaque RGBA image at (x, y) through a rounded mask, clipped to `clip` (canvas coordinates).
@(private)
blit_rounded :: proc(dst: ^tx.Canvas, img: tx.Image, x, y: i32, radius: f32, clip := tx.Rect{}) {
	rad := clamp(radius, 0, f32(min(img.w, img.h)) / 2)
	fw, fh := f32(img.w), f32(img.h)
	area := tx.Rect{0, 0, dst.w, dst.h}
	if clip.w > 0 {
		inter, ok := tx.rect_intersect(area, clip)
		if !ok { return }
		area = inter
	}
	for iy in 0 ..< img.h {
		dy := y + iy
		if dy < area.y || dy >= area.y + area.h { continue }
		for ix in 0 ..< img.w {
			dx := x + ix
			if dx < area.x || dx >= area.x + area.w { continue }
			cov := rounded_coverage(f32(ix) + 0.5, f32(iy) + 0.5, fw, fh, rad)
			if cov <= 0 { continue }
			o := (int(iy) * int(img.w) + int(ix)) * 4
			src := u32(img.rgba[o]) << 16 | u32(img.rgba[o + 1]) << 8 | u32(img.rgba[o + 2])
			a := f32(img.rgba[o + 3]) / 255
			i := int(dy) * int(dst.w) + int(dx)
			dst.px[i] = blend(dst.px[i], src, cov * a)
		}
	}
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------
@(private)
Button_Kind :: enum { Filled, Tonal, Text }

@(private)
button_width :: proc(w: ^Wizard, label: string, lead: Icon = .None, trail: Icon = .None) -> i32 {
	width := text_width(w, w.f_h2, label) + 2 * 24
	if w.f_icon_small != nil {
		if lead != .None { width += 26 }
		if trail != .None { width += 26 }
	}
	return width
}

@(private)
button :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect, label: string, kind: Button_Kind, action: Action, arg: int = 0,
               lead: Icon = .None, trail: Icon = .None) {
	th := &w.theme
	hot := hovered(w, action, arg)
	fill, fg: tx.Color
	switch kind {
	case .Filled:
		fill = hot ? mix(th.accent, th.accent_fg, 0.14) : th.accent
		fg = th.accent_fg
	case .Tonal:
		fill = hot ? th.hover : th.surface
		fg = th.fg
	case .Text:
		fill = hot ? th.surface : tx.Color{}
		fg = hot ? th.fg : mix(th.fg, th.muted, 0.45)
	}
	if kind == .Filled && !th.dark { shadow(cv, r, f32(r.h) / 2, 3, hot ? 22 : 14, 2) }
	if fill.a > 0 { tx.canvas_fill_rounded_rect(cv, r, f32(r.h) / 2, fill) }
	has_icons := w.f_icon_small != nil
	tw := text_width(w, w.f_h2, label)
	inner := tw
	if has_icons && lead != .None { inner += 26 }
	if has_icons && trail != .None { inner += 26 }
	x := r.x + (r.w - inner) / 2
	if has_icons && lead != .None {
		icon(w, w.f_icon_small, {x, r.y, 18, r.h}, lead, fg)
		x += 26
	}
	text(w, w.f_h2, x, r.y, r.h, label, fg)
	x += tw + 8
	if has_icons && trail != .None { icon(w, w.f_icon_small, {x, r.y, 18, r.h}, trail, fg) }
	add_hit(w, r, action, arg)
}

// A pill-shaped segmented control; `selected` gets the accent.
@(private)
segmented :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect, labels: []string, icons: []Icon, selected: int, action: Action) {
	th := &w.theme
	tx.canvas_fill_rounded_rect(cv, r, f32(r.h) / 2, th.field)
	tx.canvas_stroke_rounded_rect(cv, r, f32(r.h) / 2, 1, th.outline)
	n := i32(len(labels))
	if n == 0 { return }
	inset: i32 = 4
	seg_w := (r.w - 2 * inset) / n
	for full_label, i in labels {
		seg := tx.Rect{r.x + inset + i32(i) * seg_w, r.y + inset, seg_w, r.h - 2 * inset}
		sel := i == selected
		hot := hovered(w, action, i)
		if sel {
			tx.canvas_fill_rounded_rect(cv, seg, f32(seg.h) / 2, th.accent)
		} else if hot {
			tx.canvas_fill_rounded_rect(cv, seg, f32(seg.h) / 2, th.hover)
		}
		fg := sel ? th.accent_fg : th.fg
		ic := i < len(icons) ? icons[i] : Icon.None
		label := ellipsize(w, w.f_body, full_label, seg.w - 24 - (ic != .None && w.f_icon_small != nil ? 26 : 0))
		tw := text_width(w, w.f_body, label)
		inner := tw
		if ic != .None && w.f_icon_small != nil { inner += 26 }
		x := seg.x + (seg.w - inner) / 2
		if ic != .None && w.f_icon_small != nil {
			icon(w, w.f_icon_small, {x, seg.y, 18, seg.h}, ic, fg)
			x += 26
		}
		text(w, w.f_body, x, seg.y, seg.h, label, fg)
		add_hit(w, seg, action, i)
	}
}

// A round check badge (accent circle with a check mark). (cx, cy) are canvas
// coordinates; (ox, oy) convert them to window coordinates for the glyph.
@(private)
check_badge :: proc(w: ^Wizard, cv: ^tx.Canvas, cx, cy: i32, radius: i32, clip := tx.Rect{}, ox: i32 = 0, oy: i32 = 0) {
	th := &w.theme
	tx.canvas_fill_circle(cv, f32(cx), f32(cy), f32(radius) + 2, th.bg)
	tx.canvas_fill_circle(cv, f32(cx), f32(cy), f32(radius), th.accent)
	if w.f_icon_small != nil {
		icon(w, w.f_icon_small, {ox + cx - radius, oy + cy - radius, 2 * radius, 2 * radius}, .Check, th.accent_fg, clip)
	} else {
		tx.canvas_fill_circle(cv, f32(cx), f32(cy), f32(radius) / 3, th.accent_fg)
	}
}

// Workspace-style step indicator: the current step is a pill, the others dots.
@(private)
step_dots :: proc(w: ^Wizard, cv: ^tx.Canvas, right, cy: i32) {
	th := &w.theme
	pill_w: i32 = 24
	dot: i32 = 8
	gap: i32 = 10
	count := len(Page)
	total := pill_w + i32(count - 1) * (dot + gap) + 0
	x := right - total
	for p in Page {
		active := p == w.page
		width := active ? pill_w : dot
		r := tx.Rect{x, cy - dot / 2, width, dot}
		color := active ? th.accent : (int(p) < int(w.page) ? mix(th.accent, th.bg, 0.45) : mix(th.muted, th.bg, 0.35))
		if hovered(w, .Goto_Page, int(p)) && !active { color = th.muted }
		tx.canvas_fill_rounded_rect(cv, r, f32(dot) / 2, color)
		add_hit(w, {x - gap / 2, cy - 12, width + gap, 24}, .Goto_Page, int(p))
		x += width + gap
	}
}

// ---------------------------------------------------------------------------
// Backdrop and card
// ---------------------------------------------------------------------------
@(private)
content_rect :: proc(w: ^Wizard) -> tx.Rect {
	if w.mode == .Settings { return settings_content_rect(w) }
	cd := w.card
	return {cd.x + PAD, cd.y + HEADER_H, cd.w - 2 * PAD, cd.h - HEADER_H - FOOTER_H}
}

// A soft diagonal gradient between the two backdrop tones (a lookup table
// keeps it cheap on large screens).
@(private)
fill_gradient :: proc(cv: ^tx.Canvas, a, b: tx.Color) {
	lut: [256]u32
	for i in 0 ..< 256 {
		c := tx.color_mix(a, b, f32(i) / 255)
		lut[i] = u32(c.r) << 16 | u32(c.g) << 8 | u32(c.b)
	}
	fx := 0.55 * 255 / f32(max(cv.w, 1))
	fy := 0.45 * 255 / f32(max(cv.h, 1))
	for y in 0 ..< cv.h {
		row := int(y) * int(cv.w)
		ty := f32(y) * fy
		for x in 0 ..< cv.w {
			cv.px[row + int(x)] = lut[clamp(int(f32(x) * fx + ty), 0, 255)]
		}
	}
}

// Rounded rectangle fill that only does coverage maths in the corners.
@(private)
fill_rounded :: proc(cv: ^tx.Canvas, r: tx.Rect, radius: f32, c: tx.Color) {
	if r.w <= 0 || r.h <= 0 || c.a == 0 { return }
	rad := clamp(radius, 0, f32(min(r.w, r.h)) / 2)
	ir := i32(math.ceil(rad))
	src := u32(c.r) << 16 | u32(c.g) << 8 | u32(c.b)
	alpha := f32(c.a) / 255
	x0, x1 := max(r.x, 0), min(r.x + r.w, cv.w)
	y0, y1 := max(r.y, 0), min(r.y + r.h, cv.h)
	fw, fh := f32(r.w), f32(r.h)
	for y in y0 ..< y1 {
		row := int(y) * int(cv.w)
		ly := y - r.y
		corner_row := ly < ir || ly >= r.h - ir
		for x in x0 ..< x1 {
			lx := x - r.x
			cov := alpha
			if corner_row && (lx < ir || lx >= r.w - ir) {
				cov *= rounded_coverage(f32(lx) + 0.5, f32(ly) + 0.5, fw, fh, rad)
				if cov <= 0 { continue }
			}
			i := row + int(x)
			cv.px[i] = blend(cv.px[i], src, cov)
		}
	}
}

// A soft drop shadow around rounded rectangle `r` (drawn before `r` itself):
// darkness falls off quadratically over `spread` pixels; pixels the card will
// cover are skipped.
@(private)
soft_shadow :: proc(cv: ^tx.Canvas, r: tx.Rect, radius: f32, spread: i32, strength: f32, dy: i32) {
	sr := tx.Rect{r.x, r.y + dy, r.w, r.h}
	hw, hh := f32(sr.w) / 2, f32(sr.h) / 2
	cx, cy := f32(sr.x) + hw, f32(sr.y) + hh
	rad := clamp(radius, 0, min(hw, hh))
	ir := i32(math.ceil(radius))
	x0, x1 := max(sr.x - spread, 0), min(sr.x + sr.w + spread, cv.w)
	y0, y1 := max(sr.y - spread, 0), min(sr.y + sr.h + spread, cv.h)
	fs := f32(spread)
	for y in y0 ..< y1 {
		row := int(y) * int(cv.w)
		in_rows := y >= r.y && y < r.y + r.h
		in_mid_rows := y >= r.y + ir && y < r.y + r.h - ir
		for x in x0 ..< x1 {
			if in_rows && x >= r.x + ir && x < r.x + r.w - ir { continue }
			if in_mid_rows && x >= r.x && x < r.x + r.w { continue }
			px := abs(f32(x) + 0.5 - cx) - (hw - rad)
			py := abs(f32(y) + 0.5 - cy) - (hh - rad)
			outside := math.sqrt(max(px, 0) * max(px, 0) + max(py, 0) * max(py, 0)) + min(max(px, py), 0) - rad
			if outside >= fs { continue }
			t: f32 = 1
			if outside > 0 { t = 1 - outside / fs }
			a := strength * t * t
			i := row + int(x)
			d := cv.px[i]
			k := 1 - a
			cv.px[i] = u32(f32((d >> 16) & 0xFF) * k) << 16 | u32(f32((d >> 8) & 0xFF) * k) << 8 | u32(f32(d & 0xFF) * k)
		}
	}
}

// An indeterminate spinner: a bright arc turning over a faint ring.
@(private)
draw_spinner :: proc(cv: ^tx.Canvas, cx, cy, radius, thickness: f32, phase: f32, color, track: tx.Color) {
	x0 := max(i32(cx - radius - thickness), 0)
	x1 := min(i32(cx + radius + thickness) + 1, cv.w)
	y0 := max(i32(cy - radius - thickness), 0)
	y1 := min(i32(cy + radius + thickness) + 1, cv.h)
	start := phase * 2 * math.PI
	span: f32 = 1.7 // radians of the moving arc
	fg := u32(color.r) << 16 | u32(color.g) << 8 | u32(color.b)
	bg := u32(track.r) << 16 | u32(track.g) << 8 | u32(track.b)
	for y in y0 ..< y1 {
		row := int(y) * int(cv.w)
		for x in x0 ..< x1 {
			dx := f32(x) + 0.5 - cx
			dy := f32(y) + 0.5 - cy
			d := math.sqrt(dx * dx + dy * dy)
			cov := clamp(thickness / 2 - abs(d - radius) + 0.5, 0, 1)
			if cov <= 0 { continue }
			ang := math.atan2(dy, dx) - start
			for ang < 0 { ang += 2 * math.PI }
			for ang >= 2 * math.PI { ang -= 2 * math.PI }
			i := row + int(x)
			if ang < span {
				cv.px[i] = blend(cv.px[i], fg, cov * f32(color.a) / 255)
			} else {
				cv.px[i] = blend(cv.px[i], bg, cov * f32(track.a) / 255)
			}
		}
	}
}

// Loading placeholder: a rounded tile with a light band sweeping across.
@(private)
fill_shimmer :: proc(cv: ^tx.Canvas, r: tx.Rect, radius: f32, base, highlight: tx.Color, phase: f32) {
	if r.w <= 0 || r.h <= 0 { return }
	rad := clamp(radius, 0, f32(min(r.w, r.h)) / 2)
	lut: [65]u32
	for i in 0 ..= 64 {
		c := tx.color_mix(base, highlight, f32(i) / 64)
		lut[i] = u32(c.r) << 16 | u32(c.g) << 8 | u32(c.b)
	}
	x0, x1 := max(r.x, 0), min(r.x + r.w, cv.w)
	y0, y1 := max(r.y, 0), min(r.y + r.h, cv.h)
	fw, fh := f32(r.w), f32(r.h)
	centre := phase * 1.8 - 0.4 // the band enters at the left and leaves at the right
	for y in y0 ..< y1 {
		row := int(y) * int(cv.w)
		ly := f32(y - r.y) + 0.5
		for x in x0 ..< x1 {
			lx := f32(x - r.x) + 0.5
			cov := rounded_coverage(lx, ly, fw, fh, rad)
			if cov <= 0 { continue }
			u := (lx + ly * 0.5) / (fw + fh * 0.5)
			band := clamp(1 - abs(u - centre) / 0.22, 0, 1)
			i := row + int(x)
			cv.px[i] = blend(cv.px[i], lut[int(band * band * 64)], cov)
		}
	}
}

// The first thing on screen, before the fonts are open: backdrop, the card
// and the milk mark with a spinner.
@(private)
show_splash :: proc(w: ^Wizard) {
	c := w.c
	th := &w.theme
	cv := tx.canvas_make(w.screen.w, w.screen.h, context.temp_allocator)
	fill_gradient(&cv, th.backdrop[0], th.backdrop[1])
	soft_shadow(&cv, w.card, CARD_RADIUS, 28, th.dark ? 0.45 : 0.16, 8)
	fill_rounded(&cv, w.card, CARD_RADIUS, th.bg)
	cx := f32(w.card.x + w.card.w / 2)
	cy := f32(w.card.y + w.card.h / 2)
	tx.canvas_fill_circle(&cv, cx, cy - 20, 44, th.accent)
	// A small milk bottle drawn with shapes (no icon font yet).
	fill_rounded(&cv, {i32(cx) - 11, i32(cy) - 42, 22, 8}, 3, th.accent_fg)
	fill_rounded(&cv, {i32(cx) - 14, i32(cy) - 32, 28, 34}, 7, th.accent_fg)
	tx.canvas_fill_circle(&cv, cx, cy - 13, 5, th.accent)
	draw_spinner(&cv, cx, cy + 58, 13, 3.5, 0.1, th.accent, tx.color_with_alpha(th.muted, 70))
	pm := tx.canvas_to_pixmap(c, cv)
	tx.set_background(c, w.win, pm)
	tx.pixmap_free(c, w.pixmap)
	w.pixmap = pm
}

// Seconds-based animation phase in [0, 1) at the configured speed.
@(private)
anim_phase :: proc(w: ^Wizard, period: f64) -> f32 {
	d := config.anim_duration(w.cfg, period)
	if d <= 0 { return 0.3 }
	t := (tx.now() - w.anim_start) / d
	return f32(t - math.floor(t))
}

@(private)
build_base :: proc(w: ^Wizard) {
	th := &w.theme
	tx.canvas_destroy(&w.base)
	w.base = tx.canvas_make(w.screen.w, w.screen.h, w.allocator)
	cv := &w.base
	w.base_dirty = false
	if w.mode == .Settings {
		settings_build_base(w)
		return
	}
	w.base_image = -1
	if idx := backdrop_candidate(w); idx >= 0 {
		if img, ok := candidate_thumb(w, idx); ok {
			draw_blurred(cv, img)
			tx.canvas_fill(cv, tx.color_with_alpha(th.bg, th.dark ? 120 : 70))
			w.base_image = idx
		}
	}
	if w.base_image < 0 { fill_gradient(cv, th.backdrop[0], th.backdrop[1]) }
	soft_shadow(cv, w.card, CARD_RADIUS, 28, th.dark ? 0.45 : 0.16, 8)
	fill_rounded(cv, w.card, CARD_RADIUS, th.bg)
	if th.dark { tx.canvas_stroke_rounded_rect(cv, w.card, CARD_RADIUS, 1, mix(th.bg, th.fg, 0.1)) }
}

// Heavily blurred, screen-filling version of a thumbnail: shrink it to a few
// dozen pixels, then stretch it back with bilinear filtering.
@(private)
draw_blurred :: proc(cv: ^tx.Canvas, img: tx.Image) {
	sw: i32 = 40
	sh := max(1, sw * cv.h / max(cv.w, 1))
	small := cover_resize(img, sw, sh, context.temp_allocator)
	fx := f32(sw) / f32(cv.w)
	fy := f32(sh) / f32(cv.h)
	for y in 0 ..< cv.h {
		sy := clamp((f32(y) + 0.5) * fy - 0.5, 0, f32(sh - 1))
		y0 := i32(sy)
		y1 := min(y0 + 1, sh - 1)
		ty := sy - f32(y0)
		row := int(y) * int(cv.w)
		for x in 0 ..< cv.w {
			sx := clamp((f32(x) + 0.5) * fx - 0.5, 0, f32(sw - 1))
			x0 := i32(sx)
			x1 := min(x0 + 1, sw - 1)
			t := sx - f32(x0)
			out: [3]f32
			for ch in 0 ..< 3 {
				p00 := f32(small.rgba[(int(y0) * int(sw) + int(x0)) * 4 + ch])
				p01 := f32(small.rgba[(int(y0) * int(sw) + int(x1)) * 4 + ch])
				p10 := f32(small.rgba[(int(y1) * int(sw) + int(x0)) * 4 + ch])
				p11 := f32(small.rgba[(int(y1) * int(sw) + int(x1)) * 4 + ch])
				top := p00 + (p01 - p00) * t
				bottom := p10 + (p11 - p10) * t
				out[ch] = top + (bottom - top) * ty
			}
			cv.px[row + int(x)] = u32(out[0]) << 16 | u32(out[1]) << 8 | u32(out[2])
		}
	}
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------
@(private)
render :: proc(w: ^Wizard) {
	c := w.c
	// The backdrop follows the wallpaper of the area being edited.
	if w.mode == .Wizard {
		if want := backdrop_candidate(w); want != w.base_image && (want < 0 || candidate_ready(w, want)) { w.base_dirty = true }
	}
	if w.base_dirty || w.base.w != w.screen.w { build_base(w) }
	cv := tx.canvas_clone(w.base, context.temp_allocator)
	clear(&w.hits)
	clear(&w.scrolls)
	w.texts = make([dynamic]Text_Item, context.temp_allocator)

	if w.mode == .Settings {
		draw_settings(w, &cv)
	} else {
		draw_chrome(w, &cv)
		c := content_rect(w)
		switch w.page {
		case .Welcome:   draw_welcome(w, &cv)
		case .Theme:     draw_theme_page(w, &cv, c)
		case .Keyboard:  draw_keyboard_page(w, &cv, c)
		case .Wallpaper: draw_wallpaper_page(w, &cv, c)
		case .Bar:       draw_bar_page(w, &cv, c)
		case .Summary:   draw_summary_page(w, &cv)
		}
	}

	pm := tx.canvas_to_pixmap(c, cv)
	ts := tx.text_surface_make(c, xlib.Drawable(pm))
	clipped := false
	for t in w.texts {
		if t.clip.w > 0 {
			rect := xlib.XRectangle{i16(t.clip.x), i16(t.clip.y), u16(t.clip.w), u16(max(t.clip.h, 0))}
			XftDrawSetClipRectangles(ts.draw, 0, 0, &rect, 1)
			clipped = true
		} else if clipped {
			XftDrawSetClip(ts.draw, nil)
			clipped = false
		}
		tx.draw_text_centered_v(&ts, t.font, t.x, t.y, t.h, t.s, t.color)
	}
	tx.text_surface_destroy(&ts)
	tx.set_background(c, w.win, pm)
	tx.pixmap_free(c, w.pixmap)
	w.pixmap = pm
	w.dirty = false
	tx.flush(c)

	// The layout may have moved under the pointer.
	h := hit_at(w, w.pointer.x, w.pointer.y)
	if h.action != w.hover.action || h.arg != w.hover.arg {
		w.hover = h
		w.dirty = true
	}
}

@(private)
tr :: proc(w: ^Wizard, pt, en: string) -> string { return config.tr(w.lang, pt, en) }

@(private)
draw_chrome :: proc(w: ^Wizard, cv: ^tx.Canvas) {
	th := &w.theme
	cd := w.card
	left := cd.x + PAD
	right := cd.x + cd.w - PAD

	// Brand and progress.
	brand_y := cd.y + 26
	x := left
	if w.f_icon != nil {
		tx.canvas_fill_circle(cv, f32(x + 15), f32(brand_y + 15), 15, th.accent)
		icon(w, w.f_icon_small, {x, brand_y, 30, 30}, .Milk, th.accent_fg)
		x += 40
	}
	text(w, w.f_h2, x, brand_y, 30, "milk", th.fg)
	step_dots(w, cv, right, brand_y + 15)

	if w.page != .Welcome {
		title, sub := page_heading(w)
		text(w, w.f_title, left, cd.y + 68, 40, title, th.fg)
		text(w, w.f_body, left, cd.y + 106, 24, ellipsize(w, w.f_body, sub, cd.w - 2 * PAD), mix(th.fg, th.muted, 0.55))
	}

	// Footer.
	by := cd.y + cd.h - PAD + 6 - BUTTON_H
	skip := tr(w, "Pular configuração", "Skip setup")
	sw := button_width(w, skip)
	button(w, cv, {left - 12, by, sw, BUTTON_H}, skip, .Text, .Skip)

	next := tr(w, "Próximo", "Next")
	next_icon := Icon.Arrow_Right
	switch w.page {
	case .Welcome: next = tr(w, "Vamos lá", "Let's go")
	case .Summary:
		next = tr(w, "Começar", "Start")
		next_icon = .Check
	case .Theme, .Keyboard, .Wallpaper, .Bar:
	}
	nw := max(button_width(w, next, .None, next_icon), 150)
	next_r := tx.Rect{right - nw, by, nw, BUTTON_H}
	button(w, cv, next_r, next, .Filled, .Next, 0, .None, next_icon)
	if w.page != .Welcome {
		back := tr(w, "Voltar", "Back")
		bw := max(button_width(w, back, .Arrow_Left), 120)
		button(w, cv, {next_r.x - 12 - bw, by, bw, BUTTON_H}, back, .Tonal, .Back, 0, .Arrow_Left)
	}
}

@(private)
page_heading :: proc(w: ^Wizard) -> (title, sub: string) {
	switch w.page {
	case .Welcome:
		return "", ""
	case .Theme:
		return tr(w, "Escolha seu tema", "Choose your theme"),
		       tr(w, "Cores da barra, dos painéis, das bordas das janelas e do terminal.",
		             "Colours for the bar, the panels, window borders and the terminal.")
	case .Keyboard:
		return tr(w, "Teclado", "Keyboard"),
		       tr(w, "Escolha o layout e a variante do seu teclado. Experimente digitando no campo de teste.",
		             "Pick your keyboard layout and variant, then try it in the test field.")
	case .Wallpaper:
		return tr(w, "Papéis de parede", "Wallpapers"),
		       tr(w, "Uma imagem para todas as áreas de trabalho, ou uma diferente para cada área.",
		             "One image for every workspace, or a different one for each area.")
	case .Bar:
		return tr(w, "Estilo da barra", "Bar style"),
		       tr(w, "Onde a barra fica e como ela se apoia na tela.",
		             "Where the bar sits and how it meets the screen edges.")
	case .Summary:
		return tr(w, "Tudo pronto", "All set"),
		       tr(w, "Confira suas escolhas. Dá para mudar tudo depois nos ajustes rápidos da barra ou em milk.json.",
		             "Review your choices. Everything can be changed later in the bar's quick settings or in milk.json.")
	}
	return "", ""
}
