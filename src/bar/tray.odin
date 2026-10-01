// The system tray ("tray"): the icons of package tray in one row of icon
// slots, in the order they registered. StatusNotifierItem pictures are drawn
// on the bar's canvas; XEmbed icons are child windows of the bar that the
// tray moves over their slots once the frame is on screen (tray.commit),
// with the bar's pixels behind them (ParentRelative backgrounds).
//
// Input: SNI icons take their clicks here — left: Activate (or the menu of
// an ItemIsMenu item), middle: SecondaryActivate, right: the item's menu
// (milk's popup menu, opened from the bar's inner edge like the window menu
// of the task list), wheel: Scroll. XEmbed icons get their clicks from the
// X server directly. The slot under the pointer, and the one whose menu is
// open, get the hover pill; NeedsAttention items a warning tint.
//
// The tray (D-Bus watcher/host, XEmbed selection) runs while a "tray" widget
// is on the bar; only the first one shows icons.
package bar

import xlib "vendor:x11/xlib"
import tx "../tx"
import tray "../tray"

@(private) TRAY_GAP :: 2 // between two icon slots

@(private)
Tray_Slot :: struct {
	item: ^tray.Item, // valid during one render
	id:   int,        // tray.Item.id (clicks find the item again by it)
	x:    i32,        // relative to the widget box
}

Tray_State :: struct {
	t:         ^tray.Tray,
	slots:     [dynamic]Tray_Slot,
	pointer_x: i32, // pointer over the bar (window x), -1 = outside
	hover:     int, // slot under the pointer (-1 = none)
}

// Slot width and icon size (the task list's icon size: it fits the hover pill).
@(private)
tray_metrics :: proc(b: ^Bar) -> (slot, icon: i32) {
	h := b.body.h > 0 ? b.body.h : i32(b.cfg.bar.height)
	ph := min(h - 8, max(i32(b.cfg.bar.icon_size) + 9, i32(b.cfg.bar.font_size) + 14))
	icon = clamp(i32(b.cfg.bar.icon_size), 8, max(8, ph - 6))
	return icon_slot(b), icon
}

// Follow the widget list: the tray runs while a "tray" widget is on the bar.
@(private)
tray_configure :: proc(b: ^Bar) {
	st := &b.tray
	st.hover = -1
	wanted := false
	for w in b.widgets {
		if w.kind == .Tray { wanted = true }
	}
	if !wanted {
		tray_destroy(b)
		return
	}
	_, icon := tray_metrics(b)
	if st.t == nil {
		st.t = tray.create(b.c, b.cfg, icon)
		st.pointer_x = -1
		tray.attach(st.t, b.win)
	} else {
		tray.configure(st.t, b.cfg, icon) // the configuration it borrows was replaced
	}
}

@(private)
tray_destroy :: proc(b: ^Bar) {
	st := &b.tray
	if st.t != nil {
		tray.destroy(st.t)
		st.t = nil
	}
	delete(st.slots)
	st.slots = nil
	st.hover = -1
}

@(private)
first_tray_widget :: proc(b: ^Bar) -> ^Widget {
	for &w in b.widgets {
		if w.kind == .Tray { return &w }
	}
	return nil
}

@(private)
measure_tray :: proc(b: ^Bar, w: ^Widget) {
	st := &b.tray
	if st.t == nil || first_tray_widget(b) != w { return }
	clear(&st.slots)
	slot, icon := tray_metrics(b)
	if icon != st.t.size { tray.configure(st.t, b.cfg, icon) }
	x: i32
	for item in tray.visible(st.t) {
		append(&st.slots, Tray_Slot{item = item, id = item.id, x = x})
		x += slot + TRAY_GAP
	}
	if len(st.slots) == 0 { return }
	w.w = x - TRAY_GAP
	w.pad = max(3, (slot - icon) / 2)
	w.visible = true
}

// The slot under window x `x` (the gaps split between neighbours; -1 = none).
@(private)
tray_slot_at :: proc(b: ^Bar, w: ^Widget, x: i32) -> int {
	st := &b.tray
	if x < 0 || len(st.slots) == 0 { return -1 }
	slot, _ := tray_metrics(b)
	rx := x - b.body.x - w.x
	for s, i in st.slots {
		if rx < s.x + slot + TRAY_GAP / 2 { return i }
	}
	return len(st.slots) - 1
}

// Pointer motion over the bar (window x; -1 = it left).
@(private)
tray_pointer :: proc(b: ^Bar, x: i32) {
	st := &b.tray
	if st.t == nil { return }
	st.pointer_x = x
	hot := -1
	if x >= 0 && b.hover >= 0 && b.widgets[b.hover].kind == .Tray { hot = tray_slot_at(b, &b.widgets[b.hover], x) }
	if hot != st.hover {
		st.hover = hot
		b.dirty = true
	}
}

// Hover pills, attention tints and SNI pictures (canvas pass); XEmbed
// sockets are told where they go.
@(private)
draw_tray :: proc(b: ^Bar, cv: ^tx.Canvas, w: ^Widget, hovered: bool) {
	st := &b.tray
	if st.t == nil || first_tray_widget(b) != w { return }
	slot, _ := tray_metrics(b)
	ph, hp := hover_height(b), hover_pad(b)
	hot := hovered ? tray_slot_at(b, w, st.pointer_x) : -1
	st.hover = hot
	x0, y0, h := b.body.x + w.x, b.body.y, b.body.h
	pointer_on, menu_of := tray.hovered(st.t), tray.menu_owner(st.t)
	for s, i in st.slots {
		pill := tx.Rect{x0 + s.x - hp, y0 + (h - ph) / 2, slot + 2 * hp, ph}
		if s.item.status == .Needs_Attention {
			tx.canvas_fill_rounded_rect(cv, pill, f32(ph) / 2, tx.color_mix(b.theme.background, b.theme.warning, 0.22))
		}
		if i == hot || s.id == pointer_on || s.id == menu_of {
			tx.canvas_fill_rounded_rect(cv, pill, f32(ph) / 2, b.theme.surface)
		}
		switch s.item.kind {
		case .SNI:
			pic := &s.item.picture
			if pic.rgba != nil {
				tx.canvas_blit_image(cv, pic^, x0 + s.x + (slot - pic.w) / 2, y0 + (h - pic.h) / 2)
			}
		case .XEmbed:
			size := tray.socket_extent(st.t)
			r := tx.Rect{x0 + s.x + (slot - size) / 2, y0 + (h - size) / 2, size, size}
			tray.place_socket(st.t, s.item, r, canvas_sum(cv, r))
		}
	}
}

// SNI items without a picture show the generic window glyph (Xft pass).
@(private)
draw_tray_text :: proc(b: ^Bar, ts: ^tx.Text_Surface, w: ^Widget) {
	st := &b.tray
	if st.t == nil || first_tray_widget(b) != w { return }
	g := &b.icons.glyphs[.App_Window]
	if !g.ok { return }
	slot, _ := tray_metrics(b)
	for s in st.slots {
		if s.item.kind != .SNI || s.item.picture.rgba != nil { continue }
		gx := b.body.x + w.x + s.x + (slot - glyph_ink_w(g)) / 2 - g.ink_x
		tx.draw_text(ts, g.font, gx, b.body.y + (b.body.h - g.ink_h) / 2 + g.ink_y, g.text, b.theme.foreground)
	}
}

// FNV-1a of the canvas pixels in `r`: did the bar change behind an icon?
@(private)
canvas_sum :: proc(cv: ^tx.Canvas, r: tx.Rect) -> u64 {
	h := u64(0xcbf29ce484222325)
	area, ok := tx.rect_intersect(r, {0, 0, cv.w, cv.h})
	if !ok { return h }
	for y in area.y ..< area.y + area.h {
		row := int(y) * int(cv.w)
		for x in area.x ..< area.x + area.w {
			h = (h ~ u64(cv.px[row + int(x)])) * 0x100000001b3
		}
	}
	return h
}

// Every button acts on the SNI icon under the pointer.
@(private)
tray_button :: proc(b: ^Bar, w: ^Widget, ev: ^xlib.XButtonEvent) {
	st := &b.tray
	i := tray_slot_at(b, w, ev.x)
	if st.t == nil || i < 0 { return }
	s := st.slots[i]
	button := int(i32(ev.button))
	if button <= 3 { close_popups(b) }
	// The menu hangs from the slot's left edge on the bar's inner edge (it
	// opens upwards from a bottom bar).
	bar := bar_rect(b)
	mx := bar.x + w.x + s.x
	my := b.cfg.bar.position == "bottom" ? bar.y : bar.y + bar.h
	tray.click(st.t, s.id, button, ev.x_root, ev.y_root, mx, my, ev.time)
}
