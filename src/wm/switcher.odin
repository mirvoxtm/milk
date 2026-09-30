// milk addition: the window switcher (Alt+Tab, openbox's NextWindow with its
// dialog). The first press grabs the keyboard and shows a card with the
// windows of the current area, most recently used first (minimized ones
// included, dimmed); Tab / Shift+Tab / the arrow keys move the selection and
// releasing the modifier that started it (Alt) brings the selected window
// forward. Escape cancels; a click on a row picks it. Works in both modes.
package wm

import "core:fmt"
import xlib "vendor:x11/xlib"
import tx "../tx"

@(private) SW_ROW     :: 44
@(private) SW_PAD     :: 10
@(private) SW_ICON    :: 28
@(private) SW_MAXROWS :: 10
@(private) SW_RADIUS  :: 16

Switcher :: struct {
	active: bool,
	wins:   [dynamic]xlib.Window, // candidates, most recent first
	icons:  [dynamic]tx.Image,    // per candidate (w == 0: none)
	index:  int,
	first:  int, // first visible row
	mods:   xlib.InputMask, // modifiers whose release commits
	win:    xlib.Window,
	pixmap: xlib.Pixmap,
	rect:   tx.Rect,
	font:   ^tx.Font,
}

// Start (or advance) the switcher.
switcher_start :: proc(m: ^Manager, dir: int, ctx: Action_Ctx) {
	sw := &m.switcher
	if sw.active {
		switcher_step(m, dir)
		return
	}
	list := switchable_clients(m, m.selmon)
	if len(list) == 0 { return }
	if len(list) == 1 {
		activate_client(m, list[0])
		return
	}
	sw.mods = cleanmask(m, ctx.state) - {.ShiftMask}
	if xlib.GrabKeyboard(m.dpy, m.root, true, .GrabModeAsync, .GrabModeAsync, xlib.CurrentTime) != GRAB_SUCCESS {
		// Somebody holds the keyboard: just switch to the next window.
		activate_client(m, list[dir > 0 ? 1 : len(list) - 1])
		return
	}
	sw.active = true
	clear(&sw.wins)
	for img in sw.icons { img_free(img) }
	clear(&sw.icons)
	for c in list {
		append(&sw.wins, c.win)
		img, _ := tx.window_icon(m.c, c.win, SW_ICON)
		append(&sw.icons, img)
	}
	sw.index = dir > 0 ? 1 : len(list) - 1
	sw.first = 0
	switcher_show(m)
	// A quick Alt+Tab may be over before the grab: commit at once.
	if sw.mods != {} && !modifiers_held(m, sw.mods) { switcher_finish(m, true) }
}

@(private)
img_free :: proc(img: tx.Image) {
	img := img
	if img.w > 0 { tx.image_destroy(&img) }
}

@(private)
modifiers_held :: proc(m: ^Manager, mods: xlib.InputMask) -> bool {
	dummy: xlib.Window
	x, y, wx, wy: i32
	mask: xlib.KeyMask
	if !bool(xlib.QueryPointer(m.dpy, m.root, &dummy, &dummy, &x, &y, &wx, &wy, &mask)) { return true }
	held := transmute(u32)mask
	return held & transmute(u32)mods != 0
}

@(private)
switcher_step :: proc(m: ^Manager, dir: int) {
	sw := &m.switcher
	n := len(sw.wins)
	if n == 0 { return }
	sw.index = (sw.index + dir + n) % n
	switcher_paint(m)
}

// Key events while the switcher runs; true when consumed.
switcher_key :: proc(m: ^Manager, ev: ^xlib.XEvent) -> bool {
	sw := &m.switcher
	if !sw.active { return false }
	ke := &ev.xkey
	sym := xlib.LookupKeysym(ke, 0)
	if ev.type == .KeyPress {
		shift := .ShiftMask in ke.state
		#partial switch sym {
		case .XK_Tab:                 switcher_step(m, shift ? -1 : 1)
		case .XK_ISO_Left_Tab:        switcher_step(m, -1)
		case .XK_Right, .XK_Down:     switcher_step(m, 1)
		case .XK_Left, .XK_Up:        switcher_step(m, -1)
		case .XK_Escape:              switcher_finish(m, false)
		case .XK_Return, .XK_KP_Enter: switcher_finish(m, true)
		}
		return true
	}
	if ev.type == .KeyRelease {
		released: xlib.InputMask
		#partial switch sym {
		case .XK_Alt_L, .XK_Alt_R, .XK_Meta_L, .XK_Meta_R: released = {.Mod1Mask}
		case .XK_Super_L, .XK_Super_R, .XK_Hyper_L, .XK_Hyper_R: released = {.Mod4Mask}
		case .XK_Control_L, .XK_Control_R: released = {.ControlMask}
		}
		if released != {} && sw.mods & released != {} {
			// The event's state still includes the key being released.
			if cleanmask(m, ke.state) & sw.mods - released == {} { switcher_finish(m, true) }
		}
		return true
	}
	return false
}

// A click on the card picks a row; true when the event was for the card.
switcher_button :: proc(m: ^Manager, be: ^xlib.XButtonEvent) -> bool {
	sw := &m.switcher
	if !sw.active || be.window != sw.win { return false }
	if be.button == .Button4 || be.button == .Button5 {
		switcher_step(m, be.button == .Button4 ? -1 : 1)
		return true
	}
	row := int((be.y - SW_PAD) / SW_ROW) + sw.first
	if row >= 0 && row < len(sw.wins) && be.y >= SW_PAD {
		sw.index = row
		switcher_finish(m, true)
	}
	return true
}

// Close the switcher; `commit` brings the selected window forward.
switcher_finish :: proc(m: ^Manager, commit: bool) {
	sw := &m.switcher
	if !sw.active { return }
	sw.active = false
	xlib.UngrabKeyboard(m.dpy, xlib.CurrentTime)
	if sw.win != 0 {
		xlib.DestroyWindow(m.dpy, sw.win)
		sw.win = 0
	}
	tx.pixmap_free(m.c, sw.pixmap)
	sw.pixmap = 0
	target: xlib.Window
	if commit && sw.index >= 0 && sw.index < len(sw.wins) { target = sw.wins[sw.index] }
	for img in sw.icons { img_free(img) }
	clear(&sw.icons)
	clear(&sw.wins)
	if target != 0 {
		if c := wintoclient(m, target); c != nil { activate_client(m, c) }
	}
	xlib.Flush(m.dpy)
}

switcher_destroy :: proc(m: ^Manager) {
	switcher_finish(m, false)
	delete(m.switcher.wins)
	delete(m.switcher.icons)
	tx.font_close(m.c, m.switcher.font)
	m.switcher = {}
}

@(private)
switcher_show :: proc(m: ^Manager) {
	sw := &m.switcher
	if sw.font == nil {
		st := &m.settings.menu_style
		sw.font, _ = tx.font_open(m.c, st.font, st.font_px + 1)
		if sw.font == nil { sw.font, _ = tx.font_open(m.c, "sans", st.font_px + 1) }
	}
	mon := m.selmon
	rows := min(len(sw.wins), SW_MAXROWS)
	w := min(i32(620), mon.mw - 80)
	h := i32(rows) * SW_ROW + 2 * SW_PAD
	sw.rect = {mon.mx + (mon.mw - w) / 2, mon.my + (mon.mh - h) / 2, w, h}
	sw.win = tx.create_overlay(m.c, sw.rect, {.ButtonPress}, "_NET_WM_WINDOW_TYPE_DIALOG", "milk window switcher")
	tx.shape_rounded(m.c, sw.win, w, h, SW_RADIUS)
	switcher_paint(m)
	xlib.MapRaised(m.dpy, sw.win)
	xlib.Flush(m.dpy)
}

@(private)
switcher_paint :: proc(m: ^Manager) {
	sw := &m.switcher
	if sw.win == 0 { return }
	st := &m.settings.menu_style
	w, h := sw.rect.w, sw.rect.h
	rows := min(len(sw.wins), SW_MAXROWS)
	if sw.index < sw.first { sw.first = sw.index }
	if sw.index >= sw.first + rows { sw.first = sw.index - rows + 1 }
	cv := tx.canvas_make(w, h, context.temp_allocator)
	tx.canvas_fill(&cv, st.bg)
	tx.canvas_stroke_rounded_rect(&cv, {0, 0, w, h}, SW_RADIUS, 1, tx.color_mix(st.bg, st.muted, 0.45))
	Label :: struct { x, y: i32, text: string, color: tx.Color }
	labels := make([dynamic]Label, context.temp_allocator)
	for r in 0 ..< rows {
		i := sw.first + r
		c := wintoclient(m, sw.wins[i])
		row := tx.Rect{SW_PAD, SW_PAD + i32(r) * SW_ROW, w - 2 * SW_PAD, SW_ROW}
		selected := i == sw.index
		if selected { tx.canvas_fill_rounded_rect(&cv, row, 10, st.accent) }
		fg := selected ? st.accent_fg : st.fg
		if c != nil && c.minimized && !selected { fg = st.muted }
		ix := row.x + 10
		iy := row.y + (SW_ROW - SW_ICON) / 2
		if sw.icons[i].w > 0 {
			tx.canvas_blit_image(&cv, sw.icons[i], ix, iy, c != nil && c.minimized ? 0.55 : 1)
		} else {
			tx.canvas_stroke_rounded_rect(&cv, {ix + 2, iy + 2, SW_ICON - 4, SW_ICON - 4}, 5, 1.5, fg)
			tx.canvas_fill_rect(&cv, {ix + 2, iy + 8, SW_ICON - 4, 1}, fg)
		}
		name := c != nil ? c.name : ""
		if c != nil && c.minimized { name = fmt.tprintf("%s  ·  %s", name, tr(m, "minimizada", "minimized")) }
		tx0 := ix + SW_ICON + 14
		if sw.font != nil {
			append(&labels, Label{tx0, row.y, tx.text_ellipsize(m.c, sw.font, name, row.x + row.w - tx0 - 12), fg})
		}
	}
	pm := tx.canvas_to_pixmap(m.c, cv)
	if sw.font != nil {
		ts := tx.text_surface_make(m.c, xlib.Drawable(pm))
		for l in labels { tx.draw_text_centered_v(&ts, sw.font, l.x, l.y, SW_ROW, l.text, l.color) }
		tx.text_surface_destroy(&ts)
	}
	tx.set_background(m.c, sw.win, pm)
	tx.pixmap_free(m.c, sw.pixmap)
	sw.pixmap = pm
	xlib.Flush(m.dpy)
}
