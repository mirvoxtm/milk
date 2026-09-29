// Widgets: measuring, placement in the three sections, drawing and hit
// testing.
//
// Rhythm: every icon sits in the same square slot (icon_size + 6) with its
// glyph centred on the ink, so narrow and wide glyphs are evenly spaced. An
// item is its icon/image and value text (5 px apart) with the same padding
// on both ends, so hover pills are symmetric (circles for icon-only items).
// Items are one uniform gap apart (spacing / 2); a little extra space
// (spacing * 3/7) only sets off the date/clock pair and the gear/power pair,
// and the date and clock read as one unit.
package bar

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "../tx"

Widget_Kind :: enum {
	Launcher,
	Active_Window,
	Workspaces,
	Media,
	Spacer,
	Notifications,
	Clipboard,
	Network,
	Bluetooth,
	Volume,
	Brightness,
	Battery,
	Date,
	Clock,
	Settings,
	Session,
}

// Widget ids as used in milk.json (bar.start/center/end and bar.commands).
// "recorder" (the old camera button) is no longer a widget: it is skipped with
// the one-time "not supported" warning.
WIDGET_IDS := [Widget_Kind]string{
	.Launcher      = "launcher",
	.Active_Window = "active_window",
	.Workspaces    = "workspaces",
	.Media         = "media",
	.Spacer        = "spacer",
	.Notifications = "notifications",
	.Clipboard     = "clipboard",
	.Network       = "network",
	.Bluetooth     = "bluetooth",
	.Volume        = "volume",
	.Brightness    = "brightness",
	.Battery       = "battery",
	.Date          = "date",
	.Clock         = "clock",
	.Settings      = "settings",
	.Session       = "session",
}

Section :: enum { Start, Center, End }

Widget :: struct {
	kind:       Widget_Kind,
	section:    Section,
	x, w:       i32, // the item box, relative to the bar body
	pad:        i32, // padding inside the box before (and after) the content
	logo:       bool, // the launcher shows milk's logo
	visible:    bool,
	// Content resolved by the last layout pass (text lives in the temp allocator).
	icon:       Icon,
	has_icon:   bool,
	image:      ^tx.Image,
	text:       string,
	text_w:     i32,
	icon_color: tx.Color,
	text_color: tx.Color,
}

EDGE_PAD     :: 12 // bar edge → ink of the first/last item (the same on both ends)
TEXT_INK_GAP :: 5  // icon ink (or image) → its value text
TEXT_PAD     :: 4  // padding of text-only items
PAIR_GAP     :: 3  // date → clock
MIN_FLEX     :: 60 // narrowest width a title or media text is squeezed to

@(private)
widget_kind :: proc(id: string) -> (Widget_Kind, bool) {
	for kind in Widget_Kind {
		if WIDGET_IDS[kind] == id { return kind, true }
	}
	return .Spacer, false
}

@(private)
build_widgets :: proc(b: ^Bar) {
	clear(&b.widgets)
	add :: proc(b: ^Bar, ids: []string, section: Section) {
		for id in ids {
			kind, ok := widget_kind(id)
			if !ok {
				if id not_in b.unsupported {
					log.warnf("Bar widget %q is not supported on Linux; skipping it", id)
					b.unsupported[strings.clone(id)] = {}
				}
				continue
			}
			append(&b.widgets, Widget{kind = kind, section = section})
		}
	}
	add(b, b.cfg.bar.start, .Start)
	add(b, b.cfg.bar.center, .Center)
	add(b, b.cfg.bar.end, .End)
}

// Clusters set off by a little extra space: the date/clock pair and the
// bell/gear/power group. Everything else shares one uniform gap.
@(private)
widget_cluster :: proc(kind: Widget_Kind) -> int {
	#partial switch kind {
	case .Date, .Clock:                      return 1
	case .Notifications, .Settings, .Session: return 2
	}
	return 0
}

@(private)
item_gap :: proc(b: ^Bar) -> i32 { return max(4, i32(b.cfg.bar.spacing) / 2) }

@(private)
cluster_extra :: proc(b: ^Bar) -> i32 { return max(2, i32(b.cfg.bar.spacing) * 3 / 7) }

@(private)
gap_between :: proc(b: ^Bar, a, c: Widget_Kind) -> i32 {
	if (a == .Date && c == .Clock) || (a == .Clock && c == .Date) { return PAIR_GAP }
	g := item_gap(b)
	if widget_cluster(a) != widget_cluster(c) { g += cluster_extra(b) }
	return g
}

// Minimum space between two sections.
@(private)
group_gap :: proc(b: ^Bar) -> i32 { return item_gap(b) + cluster_extra(b) }

// Width of the square slot every icon occupies.
@(private)
icon_slot :: proc(b: ^Bar) -> i32 { return i32(b.cfg.bar.icon_size) + 6 }

// Hover pills are all the same height; this padding makes icon-only pills round.
@(private)
hover_height :: proc(b: ^Bar) -> i32 {
	return min(b.body.h - 8, max(i32(b.cfg.bar.icon_size) + 9, i32(b.cfg.bar.font_size) + 14))
}

@(private)
hover_pad :: proc(b: ^Bar) -> i32 { return max(1, (hover_height(b) - icon_slot(b) + 1) / 2) }

// Horizontal extent of an image's visible pixels (alpha > 10%), so images
// line up with glyphs by what is drawn rather than by their transparent margins.
@(private)
image_ink :: proc(img: tx.Image) -> (x, w: i32) {
	x0, x1 := img.w, i32(-1)
	for y in 0 ..< img.h {
		row := int(y) * int(img.w) * 4
		for px in 0 ..< img.w {
			if img.rgba[row + int(px) * 4 + 3] > 25 {
				x0 = min(x0, px)
				x1 = max(x1, px)
			}
		}
	}
	if x1 < x0 { return 0, img.w }
	return x0, x1 - x0 + 1
}

// Width of a glyph's ink (its advance when the font reports no ink box).
@(private)
glyph_ink_w :: proc(g: ^Glyph) -> i32 { return g.ink_w > 0 ? g.ink_w : g.advance }

// Edge padding: equal at both ends; a floating bar keeps clear of its rounded ends.
@(private)
edge_pad :: proc(b: ^Bar) -> i32 {
	if is_floating(b) { return EDGE_PAD + clamp(i32(b.cfg.bar.radius), 0, b.body.h / 2) / 4 }
	return EDGE_PAD
}

@(private)
command_for :: proc(b: ^Bar, id: string) -> string {
	cmd, ok := b.cfg.bar.commands[id]
	if !ok { return "" }
	return strings.trim_space(cmd)
}

// ---------------------------------------------------------------------------
// Icon choice per state
// ---------------------------------------------------------------------------
@(private)
network_icon :: proc(st: Network_State) -> Icon {
	switch st.kind {
	case .Ethernet:
		return .Ethernet
	case .Wifi:
		switch {
		case st.quality >= 75: return .Wifi_3
		case st.quality >= 50: return .Wifi_2
		case st.quality >= 25: return .Wifi_1
		}
		return .Wifi_0
	case .None:
	}
	return .Wifi_Off
}

@(private)
bluetooth_icon :: proc(st: Bluetooth_State) -> Icon {
	if !st.present || st.blocked { return .Bluetooth_Off }
	if st.connected { return .Bluetooth_Connected }
	return .Bluetooth
}

@(private)
volume_icon :: proc(v: Volume_State) -> Icon {
	switch {
	case !v.known:       return .Volume_High
	case v.muted:        return .Volume_Muted
	case v.percent <= 0: return .Volume_Zero
	case v.percent < 50: return .Volume_Low
	}
	return .Volume_High
}

@(private)
battery_icon :: proc(st: Battery_State) -> Icon {
	if st.charging { return .Battery_Charging }
	switch {
	case st.percent >= 88: return .Battery_4
	case st.percent >= 63: return .Battery_3
	case st.percent >= 38: return .Battery_2
	case st.percent >= 13: return .Battery_1
	}
	return .Battery_0
}

// ---------------------------------------------------------------------------
// Measuring and placement
// ---------------------------------------------------------------------------
@(private)
set_icon :: proc(b: ^Bar, w: ^Widget, icon: Icon) {
	if b.icons.glyphs[icon].ok {
		w.icon = icon
		w.has_icon = true
	}
}

@(private)
set_text :: proc(b: ^Bar, w: ^Widget, s: string, limit: i32) {
	if s == "" || b.font == nil { return }
	text := s
	if limit > 0 { text = tx.text_ellipsize(b.c, b.font, s, limit) }
	w.text = text
	w.text_w = tx.text_width(b.c, b.font, text)
}

@(private)
percent_text :: proc(v: int) -> string {
	return fmt.tprintf("%d%%", v)
}

@(private)
measure :: proc(b: ^Bar, w: ^Widget, title_limit, media_limit: i32) {
	th := &b.theme
	w.has_icon = false
	w.image = nil
	w.logo = false
	w.text = ""
	w.text_w = 0
	w.icon_color = th.foreground
	w.text_color = th.foreground
	w.visible = false
	w.w = 0
	w.pad = 0
	switch w.kind {
	case .Spacer:
		w.w = i32(b.cfg.bar.spacer_width)
		w.visible = true
		return
	case .Workspaces:
		dots := workspaces_width(b)
		w.pad = TEXT_PAD
		w.w = dots + 2 * TEXT_PAD
		w.visible = dots > 0
		return
	case .Launcher:
		if b.has_launcher { w.image = &b.launcher } else { w.logo = true }
	case .Active_Window:
		if b.active.win == 0 { return }
		if b.active.has_icon { w.image = &b.active.icon }
		set_text(b, w, b.active.title, title_limit)
	case .Media:
		switch b.media.status {
		case .Idle:
			set_icon(b, w, .Media_Idle)
			set_text(b, w, b.cfg.bar.media_idle_text, media_limit)
			w.icon_color = th.muted
			w.text_color = th.muted
		case .Playing:
			set_icon(b, w, .Play)
			set_text(b, w, b.media.text, media_limit)
		case .Paused:
			set_icon(b, w, .Pause)
			set_text(b, w, b.media.text, media_limit)
		}
	case .Notifications: set_icon(b, w, .Bell)
	case .Clipboard:     set_icon(b, w, .Clipboard)
	case .Session:       set_icon(b, w, .Power)
	case .Settings:      set_icon(b, w, .Settings)
	case .Network:       set_icon(b, w, network_icon(b.net))
	case .Bluetooth:     set_icon(b, w, bluetooth_icon(b.bt))
	case .Volume:
		set_icon(b, w, volume_icon(b.vol))
		if b.vol.known {
			set_text(b, w, percent_text(b.vol.percent), 0)
			if b.vol.muted { w.text_color = th.muted }
		}
	case .Brightness:
		if !b.bright.present { return }
		set_icon(b, w, .Sun)
		set_text(b, w, percent_text(b.bright.percent), 0)
	case .Battery:
		if !b.bat.present { return }
		set_icon(b, w, battery_icon(b.bat))
		set_text(b, w, percent_text(b.bat.percent), 0)
		if b.bat.percent <= LOW_BATTERY && !b.bat.charging {
			w.icon_color = th.warning
			w.text_color = th.warning
		}
	case .Date:  set_text(b, w, b.date_text, 0)
	case .Clock: set_text(b, w, b.clock_text, 0)
	}
	// The box: [pad][icon ink or image][5 px][text][pad]; icon-only items are
	// exactly one slot wide with the ink centred.
	slot := icon_slot(b)
	lead: i32
	switch {
	case w.logo:
		lead = launcher_size(b)
	case w.image != nil:
		_, lead = image_ink(w.image^)
	case w.has_icon:
		lead = glyph_ink_w(&b.icons.glyphs[w.icon])
	}
	switch {
	case lead > 0 && w.text_w == 0:
		w.pad = max(3, (slot - lead) / 2)
		w.w = max(slot, lead + 2 * w.pad)
	case lead > 0:
		w.pad = max(3, (slot - lead) / 2)
		w.w = w.pad + lead + TEXT_INK_GAP + w.text_w + w.pad
	case w.text_w > 0:
		w.pad = TEXT_PAD
		w.w = w.text_w + 2 * TEXT_PAD
	}
	w.visible = w.w > 0
}

// Walk one section left to right; with `assign` the widgets get their x.
// Returns the section width.
@(private)
walk_section :: proc(b: ^Bar, section: Section, x0: i32, assign: bool) -> i32 {
	x := x0
	pending: i32 // spacer widths since the previous widget
	prev: Maybe(Widget_Kind)
	for &w in b.widgets {
		if w.section != section || !w.visible { continue }
		if w.kind == .Spacer {
			if assign { w.x = x + pending }
			pending += w.w
			continue
		}
		if p, ok := prev.?; ok { x += gap_between(b, p, w.kind) }
		x += pending
		pending = 0
		if assign { w.x = x }
		x += w.w
		prev = w.kind
	}
	return x + pending - x0
}

// Width of the text of the first widget of `kind` (for squeezing).
@(private)
text_width_of :: proc(b: ^Bar, kind: Widget_Kind) -> i32 {
	for w in b.widgets {
		if w.kind == kind && w.visible { return w.text_w }
	}
	return 0
}

@(private)
layout :: proc(b: ^Bar) {
	total := b.body.w
	title_limit := i32(b.cfg.bar.title_max_width)
	media_limit := i32(b.cfg.bar.title_max_width)
	start_w, center_w, end_w: i32
	gap := group_gap(b)
	for attempt in 0 ..< 3 {
		for &w in b.widgets { measure(b, &w, title_limit, media_limit) }
		start_w = walk_section(b, .Start, 0, false)
		center_w = walk_section(b, .Center, 0, false)
		end_w = walk_section(b, .End, 0, false)
		needed := start_w + end_w + (center_w > 0 ? center_w + 2 * gap : gap)
		overflow := needed - (total - 2 * edge_pad(b))
		if overflow <= 0 || attempt == 2 { break }
		// Too wide: squeeze the window title and the media text, each in
		// proportion to how much it can give up.
		title_w := text_width_of(b, .Active_Window)
		media_w := text_width_of(b, .Media)
		title_slack := max(title_w - MIN_FLEX, 0)
		media_slack := max(media_w - MIN_FLEX, 0)
		slack := title_slack + media_slack
		if slack <= 0 { break }
		cut := min(overflow, slack)
		title_cut := i32(i64(cut) * i64(title_slack) / i64(slack))
		media_cut := cut - title_cut
		if title_cut > 0 { title_limit = title_w - title_cut }
		if media_cut > 0 { media_limit = media_w - media_cut }
	}
	// The outermost items are placed by their ink, so both ends look alike
	// whatever the glyph or image.
	edge := edge_pad(b)
	first_pad, last_pad: i32
	have_first := false
	for w in b.widgets {
		if !w.visible || w.kind == .Spacer { continue }
		if w.section == .Start && !have_first {
			first_pad = w.pad
			have_first = true
		}
		if w.section == .End { last_pad = w.pad }
	}
	walk_section(b, .Start, edge - first_pad, true)
	walk_section(b, .End, total - edge + last_pad - end_w, true)
	// The centre group is centred on the bar, but never overlaps its neighbours.
	cx := (total - center_w) / 2
	hi := total - edge - end_w - gap - center_w
	lo := edge + start_w + gap
	if cx > hi { cx = hi }
	if cx < lo { cx = lo }
	walk_section(b, .Center, cx, true)
}

// ---------------------------------------------------------------------------
// Workspaces
// ---------------------------------------------------------------------------
Dot_Kind :: enum { Empty, Occupied, Active }

Workspace_Item :: struct {
	index: int,
	x, w:  i32,
	kind:  Dot_Kind,
}

Dot_Metrics :: struct {
	pill_w, pill_h, slot, gap: i32,
	occupied_r, empty_r:       f32,
}

// Reference look at 40px: active pill 22x8, occupied dot 7px, empty dot 5px,
// dots 14px apart.
@(private)
dot_metrics :: proc(b: ^Bar) -> Dot_Metrics {
	s := f32(b.body.h) / 40
	return Dot_Metrics{
		pill_w     = max(8, i32(22 * s + 0.5)),
		pill_h     = max(4, i32(8 * s + 0.5)),
		slot       = max(3, i32(7 * s + 0.5)),
		gap        = max(3, i32(7 * s + 0.5)),
		occupied_r = 3.5 * s,
		empty_r    = 2.5 * s,
	}
}

@(private)
workspace_items :: proc(b: ^Bar, x0: i32) -> []Workspace_Item {
	m := dot_metrics(b)
	items := make([dynamic]Workspace_Item, context.temp_allocator)
	x := x0
	for i in 0 ..< b.ws.count {
		occupied := i < len(b.ws.occupied) && b.ws.occupied[i]
		active := i == b.ws.current
		if !active && !occupied && !b.cfg.bar.show_empty_workspaces { continue }
		kind: Dot_Kind = active ? .Active : (occupied ? .Occupied : .Empty)
		w := active ? m.pill_w : m.slot
		if len(items) > 0 { x += m.gap }
		append(&items, Workspace_Item{index = i, x = x, w = w, kind = kind})
		x += w
	}
	return items[:]
}

@(private)
workspaces_width :: proc(b: ^Bar) -> i32 {
	items := workspace_items(b, 0)
	if len(items) == 0 { return 0 }
	last := items[len(items) - 1]
	return last.x + last.w
}

@(private)
draw_workspaces :: proc(b: ^Bar, cv: ^tx.Canvas, w: ^Widget) {
	m := dot_metrics(b)
	h := b.body.h
	ox, oy := b.body.x, b.body.y
	cy := f32(oy + h / 2) - 0.5 // odd-sized dots land on whole pixels
	for it in workspace_items(b, w.x + w.pad) {
		cx := f32(ox + it.x) + f32(it.w) / 2
		switch it.kind {
		case .Active:
			tx.canvas_fill_rounded_rect(cv, tx.Rect{ox + it.x, oy + h / 2 - m.pill_h / 2, it.w, m.pill_h}, f32(m.pill_h) / 2, b.theme.accent)
		case .Occupied:
			tx.canvas_fill_circle(cv, cx, cy, m.occupied_r, b.theme.accent)
		case .Empty:
			tx.canvas_fill_circle(cv, cx, cy, m.empty_r, b.theme.dot_empty)
		}
	}
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------
@(private)
is_interactive :: proc(b: ^Bar, w: ^Widget) -> bool {
	#partial switch w.kind {
	case .Spacer, .Workspaces: return false
	case .Volume:              return b.vol.backend != .None || command_for(b, "volume") != ""
	case .Brightness:          return true
	case .Network, .Bluetooth: return true
	case .Notifications, .Clipboard: return b.click_handler != nil || command_for(b, WIDGET_IDS[w.kind]) != ""
	case .Settings:            return true
	case .Media:               return b.media.status != .Idle || command_for(b, "media") != ""
	}
	return command_for(b, WIDGET_IDS[w.kind]) != ""
}

@(private)
draw_widget_shapes :: proc(b: ^Bar, cv: ^tx.Canvas, w: ^Widget, hovered: bool) {
	h := b.body.h
	ox, oy := b.body.x, b.body.y
	if hovered {
		ph := hover_height(b)
		hp := hover_pad(b)
		r := tx.Rect{ox + w.x - hp, oy + (h - ph) / 2, w.w + 2 * hp, ph}
		tx.canvas_fill_rounded_rect(cv, r, f32(ph) / 2, b.theme.surface)
	}
	if w.kind == .Workspaces {
		draw_workspaces(b, cv, w)
		return
	}
	if w.image != nil {
		ink_x, _ := image_ink(w.image^)
		tx.canvas_blit_image(cv, w.image^, ox + w.x + w.pad - ink_x, oy + (h - w.image.h) / 2)
	}
	if w.logo {
		d := launcher_size(b)
		tx.canvas_fill_circle(cv, f32(ox + w.x + w.pad) + f32(d) / 2, f32(oy + (h - d) / 2) + f32(d) / 2, f32(d) / 2, b.theme.accent)
	}
}

@(private)
draw_widget_text :: proc(b: ^Bar, ts: ^tx.Text_Surface, w: ^Widget) {
	x := b.body.x + w.x + w.pad
	if w.logo {
		// The glyph centred on its ink inside the accent circle.
		d := launcher_size(b)
		font := b.logo_font != nil ? b.logo_font : b.font
		ext := tx.text_extents(b.c, font, b.logo_text)
		cx := x + d / 2
		cy := b.body.y + b.body.h / 2
		gx := cx - i32(ext.width) / 2 + i32(ext.x)
		baseline := cy - i32(ext.height) / 2 + i32(ext.y)
		tx.draw_text(ts, font, gx, baseline, b.logo_text, b.theme.accent_foreground)
		x += d + TEXT_INK_GAP
	} else if w.image != nil {
		_, ink_w := image_ink(w.image^)
		x += ink_w + TEXT_INK_GAP
	} else if w.has_icon {
		// Icons are placed by their ink: horizontally in the slot, vertically in the bar.
		g := &b.icons.glyphs[w.icon]
		baseline := b.body.y + (b.body.h - g.ink_h) / 2 + g.ink_y
		tx.draw_text(ts, g.font, x - g.ink_x, baseline, g.text, w.icon_color)
		x += glyph_ink_w(g) + TEXT_INK_GAP
	}
	if w.text != "" {
		tx.draw_text(ts, b.font, x, b.body.y + b.text_baseline, w.text, w.text_color)
	}
}

// Unread marker (set_badge): a small accent dot on the top-right corner of the
// icon, cut out of the glyph by a ring of the bar background. Drawn after the
// text (Xft renders straight into the pixmap), so the pixels under the dot are
// read back, composed on the CPU and uploaded again.
@(private)
draw_badge :: proc(b: ^Bar, pm: xlib.Pixmap, w: ^Widget) {
	if !w.has_icon { return }
	g := &b.icons.glyphs[w.icon]
	ink_right := b.body.x + w.x + w.pad + glyph_ink_w(g)
	ink_top := b.body.y + (b.body.h - g.ink_h) / 2
	R    :: f32(3.5)
	RING :: f32(1.75)
	cx := f32(ink_right) - 2
	cy := f32(ink_top) + 2
	outer := R + RING
	patch := tx.Rect{i32(cx - outer) - 1, i32(cy - outer) - 1, i32(2 * outer) + 3, i32(2 * outer) + 3}
	cur, ok := tx.canvas_grab(b.c, xlib.Drawable(pm), patch, context.temp_allocator)
	if !ok { return }
	for y in 0 ..< patch.h {
		for x in 0 ..< patch.w {
			fx, fy := patch.x + x, patch.y + y
			if fx < 0 || fy < 0 || fx >= b.frame.w || fy >= b.frame.h { continue }
			dx, dy := f32(fx) + 0.5 - cx, f32(fy) + 0.5 - cy
			coverage := clamp(outer - math.sqrt(dx * dx + dy * dy) + 0.5, 0, 1)
			if coverage <= 0 { continue }
			i := int(y) * int(patch.w) + int(x)
			cur.px[i] = mix_px(cur.px[i], b.frame.px[int(fy) * int(b.frame.w) + int(fx)], coverage)
		}
	}
	tx.canvas_fill_circle(&cur, cx - f32(patch.x), cy - f32(patch.y), R, b.theme.accent)
	tx.canvas_upload(b.c, cur, xlib.Drawable(pm), patch.x, patch.y)
}

@(private)
mix_px :: proc(a, c: u32, t: f32) -> u32 {
	ch :: proc(a, c: u32, shift: u32, t: f32) -> u32 {
		x, y := f32((a >> shift) & 0xFF), f32((c >> shift) & 0xFF)
		return u32(x + (y - x) * t + 0.5) << shift
	}
	return ch(a, c, 16, t) | ch(a, c, 8, t) | ch(a, c, 0, t)
}

// A widget's rectangle in screen coordinates (x/w: the widget, y/h: the visible bar).
@(private)
widget_screen_rect :: proc(b: ^Bar, w: ^Widget) -> tx.Rect {
	return {b.rect.x + b.body.x + w.x, b.rect.y + b.body.y, w.w, b.body.h}
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------
@(private)
hit_widget :: proc(b: ^Bar, window_x: i32) -> int {
	x := window_x - b.body.x
	slop := item_gap(b) / 2 // no dead zones between items
	for w, i in b.widgets {
		if !w.visible || w.kind == .Spacer { continue }
		if x >= w.x - slop && x < w.x + w.w + slop { return i }
	}
	return -1
}

@(private)
set_hover :: proc(b: ^Bar, index: int) {
	target := index
	if target >= 0 && !is_interactive(b, &b.widgets[target]) { target = -1 }
	if target != b.hover {
		b.hover = target
		b.dirty = true
	}
}

@(private)
on_button :: proc(b: ^Bar, ev: ^xlib.XButtonEvent) {
	index := hit_widget(b, ev.x)
	if index < 0 {
		if i32(ev.button) == 1 { close_popups(b) }
		return
	}
	w := &b.widgets[index]
	log.debugf("Bar: button %d at x=%d on %v", i32(ev.button), ev.x, w.kind)
	switch i32(ev.button) {
	case 1:
		activate(b, w, ev.x - b.body.x, ev.time)
	case 2:
		#partial switch w.kind {
		case .Volume: toggle_mute(b)
		case .Media:  media_toggle(b)
		}
	case 3:
		// Volume, brightness, network and bluetooth open their popup on a left
		// click; a configured command (a mixer, nm-connection-editor) runs on a
		// right click.
		#partial switch w.kind {
		case .Volume, .Brightness, .Network, .Bluetooth:
			if cmd := command_for(b, WIDGET_IDS[w.kind]); cmd != "" {
				close_popups(b)
				run_detached(b, cmd)
			}
		}
	case 4:
		scroll_widget(b, w, 1)
	case 5:
		scroll_widget(b, w, -1)
	}
}

// Left click. `x` is relative to the bar body. Settings, volume, brightness,
// network and bluetooth toggle their popups; other widgets close any open popup, then go to the
// click handler (set_click_handler) and, when it declines, run their command.
@(private)
activate :: proc(b: ^Bar, w: ^Widget, x: i32, t: xlib.Time) {
	#partial switch w.kind {
	case .Settings:
		settings_toggle(b, w)
		return
	case .Volume:
		slider_toggle(b, .Volume, w)
		return
	case .Brightness:
		slider_toggle(b, .Brightness, w)
		return
	case .Network:
		wifi_toggle(b, w)
		return
	case .Bluetooth:
		bt_toggle(b, w)
		return
	}
	close_popups(b)
	id := WIDGET_IDS[w.kind]
	if b.click_handler != nil && w.kind != .Workspaces && w.kind != .Spacer {
		if b.click_handler(b.click_data, id, widget_screen_rect(b, w)) { return }
	}
	cmd := command_for(b, id)
	#partial switch w.kind {
	case .Workspaces:
		half := dot_metrics(b).gap / 2 + 1
		for it in workspace_items(b, w.x + w.pad) {
			if x >= it.x - half && x < it.x + it.w + half {
				switch_desktop(b, it.index, t)
				return
			}
		}
		return
	case .Media:
		if cmd != "" { run_detached(b, cmd) } else { media_toggle(b) }
		return
	}
	if cmd != "" { run_detached(b, cmd) }
}

// EWMH desktop switch request. WMs that ignore it (dwm) can be driven through
// commands["workspaces"], where {n} is the 1-based and {index} the 0-based desktop.
@(private)
switch_desktop :: proc(b: ^Bar, index: int, t: xlib.Time) {
	if index < 0 || index >= b.ws.count { return }
	if cmd := command_for(b, "workspaces"); cmd != "" {
		s, _ := strings.replace_all(cmd, "{n}", fmt.tprintf("%d", index + 1), context.temp_allocator)
		s, _ = strings.replace_all(s, "{index}", fmt.tprintf("%d", index), context.temp_allocator)
		run_detached(b, s)
		return
	}
	tx.send_client_message(b.c, "_NET_CURRENT_DESKTOP", {index, int(t), 0, 0, 0})
}

@(private)
scroll_widget :: proc(b: ^Bar, w: ^Widget, direction: int) {
	#partial switch w.kind {
	case .Volume:
		change_volume(b, 5 * direction)
	case .Brightness:
		change_brightness(b, 5 * direction)
	case .Workspaces:
		if b.ws.count > 1 && b.ws.current >= 0 {
			// Scrolling up goes to the previous desktop.
			switch_desktop(b, (b.ws.current - direction + b.ws.count) % b.ws.count, xlib.CurrentTime)
		}
	}
}
