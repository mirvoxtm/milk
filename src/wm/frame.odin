// milk addition: frames of the floating mode (wm.mode = "floating").
//
// Every ordinary window is reparented into a frame window that shows its
// border and a title bar with the elements of wm.titleBar.layout, openbox's
// titleLayout letters: N the window icon, L the title, I minimize, M
// maximize, C close, S shade, D on every area, A always on top. Letters
// before L sit on the left, the others on the right. An invisible InputOnly
// "grip" window, stacked right below the frame and wm.resizeMargin pixels
// larger on every side, catches the presses just outside the frame and
// resizes the window from that edge or corner (compositors ignore InputOnly
// windows).
//
// Geometry: c.x/c.y is the frame's top-left corner, c.w/c.h the client's
// size and c.ext the frame around it (left, right, top, bottom), so width()
// and height() are the outer size as in dwm and every layout computation
// keeps working. The client sits at (ext[0], ext[2]) in the frame. Windows
// without decorations (_MOTIF_WM_HINTS, a rule, the user) and fullscreen
// windows keep a frame with zero extents; a shaded window keeps its size but
// its frame shows only the title bar.
//
// The title bar is a child window whose background is a pixmap painted on
// the CPU (tx canvas, Xft text), so the X server repaints it by itself.
package wm

import "core:fmt"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "../tx"

CLIENT_EVENT_MASK :: xlib.EventMask{.EnterWindow, .FocusChange, .PropertyChange, .StructureNotify}
@(private) FRAME_EVENT_MASK :: xlib.EventMask{.SubstructureRedirect, .SubstructureNotify, .ButtonPress, .ButtonRelease,
                                              .PointerMotion, .EnterWindow, .LeaveWindow}
@(private) TITLE_EVENT_MASK :: xlib.EventMask{.ButtonPress, .ButtonRelease, .PointerMotion, .LeaveWindow}
@(private) GRIP_EVENT_MASK :: xlib.EventMask{.ButtonPress, .PointerMotion}

@(private) CORNER_ZONE   :: 20  // along an edge, this close to a corner resizes from the corner
@(private) DOUBLE_CLICK  :: 400 // ms
@(private) TITLE_PAD     :: 6   // title bar edge → first element

// The title bar font, opened for the current settings.
Decor :: struct {
	font:     ^tx.Font,
	font_key: string, // "pattern|px" (owned)
}

// Whether a client lives in a frame: floating mode, ordinary windows.
wants_frame :: proc(m: ^Manager, c: ^Client) -> bool {
	return m.settings.floating && c.kind == .Normal && !c.ispip
}

// Whether a framed client shows its title bar.
has_title :: proc(c: ^Client) -> bool {
	return c.frame != 0 && !c.nodecor && !c.isfullscreen
}

// The frame extents a framed client gets for its current state.
@(private)
decor_extents :: proc(m: ^Manager, c: ^Client) -> [4]i32 {
	if !has_title(c) { return {} }
	b := m.settings.border_width
	return {b, b, b + m.settings.title_height, b}
}

// The frame's size on screen (a shaded frame shows the title bar only).
frame_outer :: proc(c: ^Client) -> (w, h: i32) {
	w = max(c.w + c.ext[0] + c.ext[1], 1)
	h = max(c.h + c.ext[2] + c.ext[3], 1)
	if c.shaded && has_title(c) { h = c.ext[2] + c.ext[3] }
	return
}

// Open (or keep) the title font for the settings.
decor_setup :: proc(m: ^Manager) {
	s := &m.settings
	key := fmt.tprintf("%s|%d", s.title_font, s.title_font_px)
	if m.decor.font != nil && key == m.decor.font_key { return }
	tx.font_close(m.c, m.decor.font)
	ok: bool
	m.decor.font, ok = tx.font_open(m.c, s.title_font, s.title_font_px)
	if !ok { m.decor.font, _ = tx.font_open(m.c, "sans", s.title_font_px) }
	delete(m.decor.font_key)
	m.decor.font_key = strings.clone(key)
}

decor_destroy :: proc(m: ^Manager) {
	tx.font_close(m.c, m.decor.font)
	m.decor.font = nil
	delete(m.decor.font_key)
	m.decor.font_key = ""
}

// Reparent a client into a new frame at c.x/c.y (the frame's corner). The
// client's border goes away; its passive grabs stay on the client window.
frame_attach :: proc(m: ^Manager, c: ^Client) {
	if c.frame != 0 { return }
	attrs: xlib.XSetWindowAttributes
	attrs.background_pixel = m.pixel[.Norm]
	attrs.event_mask = FRAME_EVENT_MASK
	c.frame = xlib.CreateWindow(m.dpy, m.root, c.x, c.y, 1, 1, 0, m.c.depth, .InputOutput, m.c.visual,
	                            {.CWBackPixel, .CWEventMask}, &attrs)
	hint := xlib.XClassHint{res_name = "milk-frame", res_class = "Milk"}
	xlib.SetClassHint(m.dpy, c.frame, &hint)
	tattrs: xlib.XSetWindowAttributes
	tattrs.background_pixel = m.pixel[.Norm]
	tattrs.event_mask = TITLE_EVENT_MASK
	tattrs.cursor = m.cursor[.Normal]
	c.title_win = xlib.CreateWindow(m.dpy, c.frame, 0, 0, 1, 1, 0, m.c.depth, .InputOutput, m.c.visual,
	                                {.CWBackPixel, .CWEventMask, .CWCursor}, &tattrs)
	c.hover, c.pressed, c.grip_dir = -1, -1, -1
	if c.shaped {
		// The corners are cut on the frame from now on.
		tx.shape_reset(m.c, c.win)
		c.shaped = false
		c.shape_key = {}
	}
	c.ext = decor_extents(m, c)
	c.bw = 0
	c.title_w = 0
	load_icon(m, c)

	xlib.AddToSaveSet(m.dpy, c.win)
	// No client-directed events while it moves: reparenting a mapped window
	// unmaps it first, and that unmap is not the client withdrawing.
	xlib.SelectInput(m.dpy, c.win, {})
	wc: xlib.XWindowChanges
	wc.border_width = 0
	xlib.ConfigureWindow(m.dpy, c.win, {.CWBorderWidth}, &wc)
	xlib.ReparentWindow(m.dpy, c.win, c.frame, c.ext[0], c.ext[2])
	xlib.SelectInput(m.dpy, c.win, CLIENT_EVENT_MASK)
	frame_apply(m, c, c.x, c.y)
	if has_title(c) { xlib.MapWindow(m.dpy, c.title_win) }
	write_frame_extents(m, c)
	frame_paint(m, c)
}

// Take a client out of its frame, back onto the root window where its
// content was. `keep` = the client stays managed (the mode changed).
frame_detach :: proc(m: ^Manager, c: ^Client, destroyed: bool, keep: bool) {
	if c.frame == 0 { return }
	if !destroyed {
		x, y := c.x + c.ext[0], c.y + c.ext[2]
		if keep { xlib.SelectInput(m.dpy, c.win, {}) }
		xlib.ReparentWindow(m.dpy, c.win, m.root, x, y)
		xlib.RemoveFromSaveSet(m.dpy, c.win)
		if keep {
			xlib.SelectInput(m.dpy, c.win, CLIENT_EVENT_MASK)
			xlib.DeleteProperty(m.dpy, c.win, m.atoms.net_frame_extents)
			c.x, c.y = x, y
		}
	}
	grip_destroy(m, c)
	xlib.DestroyWindow(m.dpy, c.frame)
	tx.pixmap_free(m.c, c.title_pixmap)
	if c.has_icon { tx.image_destroy(&c.icon) }
	c.frame, c.title_win, c.title_pixmap = 0, 0, 0
	c.has_icon = false
	c.ext = {}
	c.shaded = false
	c.nhits = 0
	c.shaped = false
	c.shape_key = {}
}

// The extents changed (decorations toggled, fullscreen, settings): resize the
// frame around the client, keeping the client's content where it is. `apply`
// = put the result on screen now (else the caller does).
frame_refresh :: proc(m: ^Manager, c: ^Client, apply := true) {
	if c.frame == 0 { return }
	old := c.ext
	c.ext = decor_extents(m, c)
	if !has_title(c) { c.shaded = false }
	if c.ext != old {
		c.x += old[0] - c.ext[0]
		c.y += old[2] - c.ext[2]
		write_frame_extents(m, c)
	}
	if has_title(c) { xlib.MapWindow(m.dpy, c.title_win) } else { xlib.UnmapWindow(m.dpy, c.title_win) }
	c.title_w = 0
	if apply && is_visible(c) {
		anim_snap(m, c)
		configure(m, c)
	}
	grip_update(m, c)
	frame_paint(m, c)
}

// Place the frame at (x, y) with the size of c.w/c.h plus the extents, the
// client inside it, the title bar across its top and the grip around it.
frame_apply :: proc(m: ^Manager, c: ^Client, x, y: i32) {
	ow, oh := frame_outer(c)
	xlib.MoveResizeWindow(m.dpy, c.frame, x, y, u32(ow), u32(oh))
	xlib.MoveResizeWindow(m.dpy, c.win, c.ext[0], c.ext[2], u32(max(c.w, 1)), u32(max(c.h, 1)))
	if has_title(c) {
		b := m.settings.border_width
		tw := max(ow - 2 * b, 1)
		xlib.MoveResizeWindow(m.dpy, c.title_win, b, b, u32(tw), u32(m.settings.title_height))
		if tw != c.title_w { frame_paint(m, c) }
	}
	grip_apply(m, c, x, y, ow, oh)
}

// Move the frame (and its grip) without resizing anything.
frame_move :: proc(m: ^Manager, c: ^Client, x, y: i32) {
	xlib.MoveWindow(m.dpy, top_window(c), x, y)
	if c.grip != 0 {
		mg := m.settings.resize_margin
		xlib.MoveWindow(m.dpy, c.grip, x - mg, y - mg)
	}
}

// _NET_FRAME_EXTENTS: left, right, top, bottom.
write_frame_extents :: proc(m: ^Manager, c: ^Client) {
	ext := [4]uint{uint(c.ext[0]), uint(c.ext[1]), uint(c.ext[2]), uint(c.ext[3])}
	xlib.ChangeProperty(m.dpy, c.win, m.atoms.net_frame_extents, tx.ATOM_CARDINAL, 32, xlib.PropModeReplace, &ext[0], 4)
}

// Focus changed: border colour and title bar.
frame_set_active :: proc(m: ^Manager, c: ^Client, active: bool) {
	if c.frame == 0 { return }
	c.focused = active
	xlib.SetWindowBackground(m.dpy, c.frame, m.pixel[active ? .Sel : .Norm])
	xlib.ClearWindow(m.dpy, c.frame)
	frame_paint(m, c)
}

// The window icon at the title bar's size.
load_icon :: proc(m: ^Manager, c: ^Client) {
	if c.has_icon { tx.image_destroy(&c.icon) }
	c.has_icon = false
	size := clamp(m.settings.title_height - 14, 12, 32)
	if img, ok := tx.window_icon(m.c, c.win, size); ok {
		c.icon = img
		c.has_icon = true
	}
}

// ---------------------------------------------------------------------------
// Grip: the invisible resize margin
// ---------------------------------------------------------------------------

// Whether a client gets a grip now.
@(private)
wants_grip :: proc(m: ^Manager, c: ^Client) -> bool {
	return m.settings.resize_margin > 0 && has_title(c) && !c.shaded && !(c.max_horz && c.max_vert) && !c.isfixed
}

// Create or remove the grip as the client's state asks.
grip_update :: proc(m: ^Manager, c: ^Client) {
	if c.frame == 0 { return }
	if !wants_grip(m, c) {
		grip_destroy(m, c)
		return
	}
	if c.grip != 0 { return }
	attrs: xlib.XSetWindowAttributes
	attrs.event_mask = GRIP_EVENT_MASK
	c.grip = xlib.CreateWindow(m.dpy, m.root, 0, 0, 1, 1, 0, 0, .InputOnly, nil, {.CWEventMask}, &attrs)
	c.grip_dir = -1
	ow, oh := frame_outer(c)
	x, y := c.x, c.y
	if !is_visible(c) { x = ow * -2 }
	grip_apply(m, c, x, y, ow, oh)
	xlib.MapWindow(m.dpy, c.grip)
	grip_restack(m, c)
}

@(private)
grip_destroy :: proc(m: ^Manager, c: ^Client) {
	if c.grip == 0 { return }
	xlib.DestroyWindow(m.dpy, c.grip)
	c.grip = 0
}

@(private)
grip_apply :: proc(m: ^Manager, c: ^Client, x, y, ow, oh: i32) {
	if c.grip == 0 { return }
	mg := m.settings.resize_margin
	xlib.MoveResizeWindow(m.dpy, c.grip, x - mg, y - mg, u32(ow + 2 * mg), u32(oh + 2 * mg))
}

// Keep the grip right below its frame.
grip_restack :: proc(m: ^Manager, c: ^Client) {
	if c.grip == 0 || c.frame == 0 { return }
	wc: xlib.XWindowChanges
	wc.sibling = c.frame
	wc.stack_mode = .Below
	xlib.ConfigureWindow(m.dpy, c.grip, {.CWSibling, .CWStackMode}, &wc)
}

grips_restack :: proc(m: ^Manager) {
	for mon := m.mons; mon != nil; mon = mon.next {
		for c := mon.clients; c != nil; c = c.next { grip_restack(m, c) }
	}
}

// The _NET_WM_MOVERESIZE direction for a point (x, y) relative to a
// rectangle of size w x h whose edges lie `inner` pixels inside it (the
// grip) or at its borders (the frame), or -1 in the middle.
@(private)
edge_direction :: proc(x, y, w, h, inner: i32) -> int {
	left, right := x < inner, x >= w - inner
	top, bottom := y < inner, y >= h - inner
	near_left, near_right := x < inner + CORNER_ZONE, x >= w - inner - CORNER_ZONE
	near_top, near_bottom := y < inner + CORNER_ZONE, y >= h - inner - CORNER_ZONE
	switch {
	case (top && near_left) || (left && near_top):         return MR_SIZE_TOPLEFT
	case (top && near_right) || (right && near_top):       return MR_SIZE_TOPRIGHT
	case (bottom && near_right) || (right && near_bottom): return MR_SIZE_BOTTOMRIGHT
	case (bottom && near_left) || (left && near_bottom):   return MR_SIZE_BOTTOMLEFT
	case top:    return MR_SIZE_TOP
	case bottom: return MR_SIZE_BOTTOM
	case left:   return MR_SIZE_LEFT
	case right:  return MR_SIZE_RIGHT
	}
	return -1
}

// ---------------------------------------------------------------------------
// Title bar
// ---------------------------------------------------------------------------

@(private)
is_button_letter :: proc(l: u8) -> bool {
	switch l {
	case 'I', 'M', 'C', 'S', 'D', 'A': return true
	}
	return false
}

// Paint the title bar of a framed client.
frame_paint :: proc(m: ^Manager, c: ^Client) {
	if c.title_win == 0 || !has_title(c) { return }
	s := &m.settings
	col := &s.colors
	ow, _ := frame_outer(c)
	tw := max(ow - 2 * s.border_width, 1)
	th := s.title_height
	c.title_w = tw
	active := c.focused
	bg := active ? col.active_bg : col.inactive_bg
	fg := active ? col.active_fg : col.inactive_fg
	if c.isurgent && !active { bg = tx.color_mix(bg, col.warning, 0.3) }
	cv := tx.canvas_make(tw, th, context.temp_allocator)
	tx.canvas_fill(&cv, bg)

	// Elements: before L on the left, after L on the right.
	layout := s.title_layout
	label := strings.index_byte(layout, 'L')
	bsz := s.title_circles ? max(th * 3 / 4, 20) : th
	isz := th // the icon's box
	c.nhits = 0
	add :: proc(c: ^Client, r: tx.Rect, letter: u8) {
		if c.nhits < len(c.title_hits) {
			c.title_hits[c.nhits] = Title_Hit{r, letter}
			c.nhits += 1
		}
	}
	x := i32(TITLE_PAD)
	left_end := len(layout) if label < 0 else label
	for i in 0 ..< left_end {
		l := layout[i]
		w := l == 'N' ? isz : bsz
		add(c, {x, 0, w, th}, l)
		x += w
	}
	label_x0 := x
	xr := tw - TITLE_PAD
	if label >= 0 {
		for i := len(layout) - 1; i > label; i -= 1 {
			l := layout[i]
			w := l == 'N' ? isz : bsz
			xr -= w
			add(c, {xr, 0, w, th}, l)
		}
	}
	label_x1 := xr
	if label >= 0 { add(c, {label_x0, 0, max(label_x1 - label_x0, 0), th}, 'L') }

	text_x: i32
	text_str: string
	for i in 0 ..< c.nhits {
		h := c.title_hits[i]
		hot := i == c.hover
		down := i == c.pressed
		switch h.letter {
		case 'N':
			paint_icon(m, c, &cv, h.r, fg)
		case 'L':
			font := m.decor.font
			if font == nil || h.r.w < 16 { break }
			title := tx.text_ellipsize(m.c, font, c.name, h.r.w - 12)
			tw_text := tx.text_width(m.c, font, title)
			tx0 := h.r.x + 6
			switch s.title_align {
			case 1: tx0 = clamp((tw - tw_text) / 2, h.r.x + 6, max(h.r.x + 6, h.r.x + h.r.w - 6 - tw_text))
			case 2: tx0 = h.r.x + h.r.w - 6 - tw_text
			}
			text_x, text_str = tx0, title
		case:
			paint_button(m, c, &cv, h.r, h.letter, active, hot, down, bg, fg)
		}
	}

	pm := tx.canvas_to_pixmap(m.c, cv)
	if text_str != "" && m.decor.font != nil {
		ts := tx.text_surface_make(m.c, xlib.Drawable(pm))
		tx.draw_text_centered_v(&ts, m.decor.font, text_x, 0, th, text_str, fg)
		tx.text_surface_destroy(&ts)
	}
	tx.set_background(m.c, c.title_win, pm)
	tx.pixmap_free(m.c, c.title_pixmap)
	c.title_pixmap = pm
}

@(private)
paint_icon :: proc(m: ^Manager, c: ^Client, cv: ^tx.Canvas, r: tx.Rect, fg: tx.Color) {
	if c.has_icon {
		tx.canvas_blit_image(cv, c.icon, r.x + (r.w - c.icon.w) / 2, r.y + (r.h - c.icon.h) / 2)
		return
	}
	// No icon: a small window outline.
	sz := clamp(r.h - 16, 10, 20)
	box := tx.Rect{r.x + (r.w - sz) / 2, r.y + (r.h - sz) / 2, sz, sz}
	tx.canvas_stroke_rounded_rect(cv, box, 3, 1.4, fg)
	tx.canvas_fill_rect(cv, {box.x, box.y + 4, box.w, 1}, fg)
}

// One title button: a glyph (icons) or a coloured dot (circles).
@(private)
paint_button :: proc(m: ^Manager, c: ^Client, cv: ^tx.Canvas, r: tx.Rect, letter: u8, active, hot, down: bool, bg, fg: tx.Color) {
	s := &m.settings
	col := &s.colors
	cx := f32(r.x) + f32(r.w) / 2
	cy := f32(r.y) + f32(r.h) / 2
	on := false
	switch letter {
	case 'M': on = c.max_horz && c.max_vert
	case 'S': on = c.shaded
	case 'D': on = c.sticky
	case 'A': on = c.layer == .Above
	}
	if s.title_circles {
		dot: tx.Color
		switch letter {
		case 'C': dot = tx.rgb(0xFF, 0x5F, 0x57)
		case 'I': dot = tx.rgb(0xFE, 0xBC, 0x2E)
		case 'M': dot = tx.rgb(0x28, 0xC8, 0x40)
		case:     dot = on ? col.accent : tx.color_mix(col.muted, bg, 0.2)
		}
		if !active && !hot { dot = tx.color_mix(col.muted, bg, 0.45) }
		if down { dot = tx.color_mix(dot, tx.rgb(0, 0, 0), 0.2) }
		rad := f32(clamp(r.h / 5, 5, 8))
		tx.canvas_fill_circle(cv, cx, cy, rad, dot)
		if hot { draw_glyph(cv, letter, cx, cy, rad * 0.5, 1.3, tx.rgba(0, 0, 0, 150), on) }
		return
	}
	glyph := fg
	if hot || down || on {
		pad := max(r.h / 6, 3)
		back := tx.Rect{r.x + 2, r.y + pad, r.w - 4, r.h - 2 * pad}
		fill := tx.color_mix(bg, fg, down ? 0.22 : 0.12)
		if on && !hot && !down { fill = tx.color_mix(bg, col.accent, 0.18) }
		if letter == 'C' && (hot || down) {
			fill = down ? tx.color_mix(col.warning, tx.rgb(0, 0, 0), 0.15) : col.warning
			glyph = tx.rgb(255, 255, 255)
		}
		tx.canvas_fill_rounded_rect(cv, back, f32(back.h) / 2, fill)
	}
	g := f32(clamp(r.h * 5 / 32, 4, 8))
	draw_glyph(cv, letter, cx, cy, g, 1.5, glyph, on)
}

// The symbol of a title button, centred on (cx, cy), `g` pixels from the centre to its edges.
@(private)
draw_glyph :: proc(cv: ^tx.Canvas, letter: u8, cx, cy, g, stroke: f32, color: tx.Color, on: bool) {
	line :: proc(cv: ^tx.Canvas, x0, y0, x1, y1, w: f32, c: tx.Color) { tx.canvas_stroke_line(cv, x0, y0, x1, y1, w, c) }
	switch letter {
	case 'C':
		line(cv, cx - g, cy - g, cx + g, cy + g, stroke, color)
		line(cv, cx - g, cy + g, cx + g, cy - g, stroke, color)
	case 'I':
		line(cv, cx - g, cy, cx + g, cy, stroke, color)
	case 'M':
		if on { // restore: two overlapping squares
			o := g * 0.45
			tx.canvas_stroke_rounded_rect(cv, {i32(cx - g), i32(cy - g + o), i32(2 * g - o), i32(2 * g - o)}, 1.5, stroke, color)
			line(cv, cx - g + o, cy - g, cx + g, cy - g, stroke, color)
			line(cv, cx + g, cy - g, cx + g, cy + g - o, stroke, color)
		} else {
			tx.canvas_stroke_rounded_rect(cv, {i32(cx - g), i32(cy - g), i32(2 * g), i32(2 * g)}, 1.5, stroke, color)
		}
	case 'S':
		d := g * 0.55
		if on {
			line(cv, cx - g, cy - d, cx, cy + d, stroke, color)
			line(cv, cx, cy + d, cx + g, cy - d, stroke, color)
		} else {
			line(cv, cx - g, cy + d, cx, cy - d, stroke, color)
			line(cv, cx, cy - d, cx + g, cy + d, stroke, color)
		}
	case 'D':
		if on {
			tx.canvas_fill_circle(cv, cx, cy, g * 0.8, color)
		} else {
			tx.canvas_stroke_rounded_rect(cv, {i32(cx - g * 0.8), i32(cy - g * 0.8), i32(g * 1.6) + 1, i32(g * 1.6) + 1}, g, stroke, color)
		}
	case 'A':
		line(cv, cx - g, cy - g, cx + g, cy - g, stroke, color)
		line(cv, cx, cy - g * 0.4, cx, cy + g, stroke, color)
		line(cv, cx - g * 0.6, cy + g * 0.2, cx, cy - g * 0.4, stroke, color)
		line(cv, cx, cy - g * 0.4, cx + g * 0.6, cy + g * 0.2, stroke, color)
	}
}

// Index of the title element at (x, y) in title bar coordinates, -1 = none.
@(private)
title_hit_at :: proc(c: ^Client, x, y: i32) -> int {
	for i in 0 ..< c.nhits {
		if tx.rect_contains(c.title_hits[i].r, x, y) { return i }
	}
	return -1
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

// Events on frames, title bars and grips; true when handled.
frame_event :: proc(m: ^Manager, ev: ^xlib.XEvent) -> bool {
	#partial switch ev.type {
	case .ButtonPress:
		c, part := frame_part(m, ev.xbutton.window)
		if c == nil { return false }
		frame_press(m, c, part, &ev.xbutton)
		return true
	case .ButtonRelease:
		c, part := frame_part(m, ev.xbutton.window)
		if c == nil { return false }
		if part == .Title { title_release(m, c, &ev.xbutton) }
		return true
	case .MotionNotify:
		c, part := frame_part(m, ev.xmotion.window)
		if c == nil { return false }
		me := &ev.xmotion
		switch part {
		case .Title:
			hover := title_hit_at(c, me.x, me.y)
			if hover >= 0 && !is_button_letter(c.title_hits[hover].letter) { hover = -1 }
			if hover != c.hover {
				c.hover = hover
				frame_paint(m, c)
			}
		case .Grip:
			ow, oh := frame_outer(c)
			mg := m.settings.resize_margin
			set_edge_cursor(m, c, c.grip, edge_direction(me.x, me.y, ow + 2 * mg, oh + 2 * mg, mg))
		case .Frame:
			if me.subwindow != 0 { return true }
			ow, oh := frame_outer(c)
			set_edge_cursor(m, c, c.frame, edge_direction(me.x, me.y, ow, oh, max(m.settings.border_width, 1)))
		case .None:
		}
		return true
	case .LeaveNotify:
		c, part := frame_part(m, ev.xcrossing.window)
		if c == nil || part != .Title { return false }
		if c.hover >= 0 || c.pressed >= 0 {
			c.hover = -1
			frame_paint(m, c)
		}
		return true
	}
	return false
}

@(private)
set_edge_cursor :: proc(m: ^Manager, c: ^Client, win: xlib.Window, dir: int) {
	if dir == c.grip_dir { return }
	c.grip_dir = dir
	cursor := dir >= 0 ? m.dir_cursor[dir] : m.cursor[.Normal]
	xlib.DefineCursor(m.dpy, win, cursor)
}

@(private)
frame_press :: proc(m: ^Manager, c: ^Client, part: Frame_Part, be: ^xlib.XButtonEvent) {
	button := u32(be.button)
	if is_focusable(c) && c != m.selmon.sel { focus(m, c) }
	switch part {
	case .Grip, .Frame:
		if button != 1 && button != 3 { return }
		ow, oh := frame_outer(c)
		dir: int
		if part == .Grip {
			mg := m.settings.resize_margin
			dir = edge_direction(be.x, be.y, ow + 2 * mg, oh + 2 * mg, mg)
		} else {
			dir = edge_direction(be.x, be.y, ow, oh, max(m.settings.border_width, 1))
		}
		restack(m, c.mon)
		if dir >= 0 { moveresize(m, c, dir, be.x_root, be.y_root, button) }
	case .Title:
		restack(m, c.mon)
		hit := title_hit_at(c, be.x, be.y)
		letter := hit >= 0 ? c.title_hits[hit].letter : u8('L')
		double := is_double_click(m, be)
		if is_button_letter(letter) {
			if button == 1 {
				c.pressed = hit
				frame_paint(m, c)
			}
			return
		}
		icon := letter == 'N'
		if double {
			if action, found := title_binding(m, icon, 0); found {
				m.last_click_time = 0
				run_action(m, action, c, {x = be.x_root, y = be.y_root, time = be.time, button = button})
				return
			}
		}
		if button == 1 && !icon {
			moveresize(m, c, MR_MOVE, be.x_root, be.y_root, 1)
			return
		}
		if action, found := title_binding(m, icon, button); found {
			x, y := be.x_root, be.y_root
			if icon {
				// The window menu opens under the icon.
				r := c.title_hits[hit].r
				x = c.x + m.settings.border_width + r.x
				y = c.y + c.ext[2]
			}
			run_action(m, action, c, {x = x, y = y, time = be.time, button = button})
		}
	case .None:
	}
}

@(private)
title_release :: proc(m: ^Manager, c: ^Client, be: ^xlib.XButtonEvent) {
	if c.pressed < 0 || u32(be.button) != 1 { return }
	pressed := c.pressed
	c.pressed = -1
	hit := title_hit_at(c, be.x, be.y)
	letter := c.title_hits[pressed].letter
	frame_paint(m, c)
	if hit != pressed { return }
	switch letter {
	case 'I': set_minimized(m, c, true)
	case 'M': toggle_maximize(m, c)
	case 'C': kill_client(m, c)
	case 'S': set_shaded(m, c, !c.shaded)
	case 'D': set_sticky(m, c, !c.sticky)
	case 'A': set_layer(m, c, c.layer == .Above ? .Normal : .Above)
	}
}

// The wm.mouse action for the title bar or its icon; button 0 = double click.
@(private)
title_binding :: proc(m: ^Manager, icon: bool, button: u32) -> (string, bool) {
	ctx := icon ? "icon" : "title"
	for b in m.settings.mouse {
		if b.ctx == ctx && b.button == button && b.mod == {} { return b.action, true }
	}
	if icon { return title_binding(m, false, button) } // the icon behaves like the title otherwise
	return "", false
}

// A second press of the same button on the same window, soon and close enough.
@(private)
is_double_click :: proc(m: ^Manager, be: ^xlib.XButtonEvent) -> bool {
	elapsed := u32(be.time) - u32(m.last_click_time)
	double := m.last_click_window == be.window && m.last_click_button == u32(be.button) && m.last_click_time != 0 &&
	          elapsed < DOUBLE_CLICK && abs(be.x_root - m.last_click_x) < 6 && abs(be.y_root - m.last_click_y) < 6
	if double {
		m.last_click_time = 0
	} else {
		m.last_click_window = be.window
		m.last_click_button = u32(be.button)
		m.last_click_time = be.time
		m.last_click_x, m.last_click_y = be.x_root, be.y_root
	}
	return double
}
