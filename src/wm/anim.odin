// milk addition: smooth window animations without a compositor.
//
// Every placement the window manager makes (new windows, relayouts when
// windows open or close, master size, zoom, gaps, fullscreen, tag moves)
// glides into place over `wm.animation` milliseconds (scaled by
// appearance.animationScale) with an ease-out curve.
//
// Only the position is animated. The size is applied at once when the
// animation starts: resizing a client every frame shows garbage in the newly
// exposed area until the application repaints (there is no compositor to
// hide it), while moving a window never does — the X server copies its
// contents. New windows slide in from slightly below their final place.
// Client.x/y/w/h always hold the final geometry; dx/dy/dw/dh track what the
// X server currently shows. Mouse drags and client requests are immediate.
package wm

import "core:math"
import xlib "vendor:x11/xlib"
import tx "../tx"

ANIM_FRAME :: 1.0 / 60.0
ANIM_SLIDE_IN :: 28 // pixels a new window travels upwards when it appears

// What the X server shows now equals the target geometry.
anim_sync_display :: proc(m: ^Manager, c: ^Client) {
	c.animating = false
	c.dx, c.dy, c.dw, c.dh = c.x, c.y, c.w, c.h
	c.disp_valid = true
	apply_corners(m, c)
}

// Rounded corners (wm.cornerRadius) on the client window itself, border
// included, with the SHAPE extension: no compositor needed, and the corners
// show whatever is really behind the window. Fullscreen windows, docks,
// desktops and popups (tooltips, notifications of other apps) stay square.
// While lactase rounds the corners (anti-aliased) the windows stay rectangular.
apply_corners :: proc(m: ^Manager, c: ^Client) {
	r := m.settings.corner_radius
	want := r > 0 && !m.cm.rounds_corners && !c.isfullscreen && c.kind != .Dock && c.kind != .Desktop && c.kind != .Popup
	if c.frame != 0 && !has_title(c) && c.nodecor { want = false } // client-side decorations shape themselves
	win := top_window(c)
	if !want {
		if c.shaped {
			tx.shape_reset(m.c, win)
			c.shaped = false
			c.shape_key = {}
		}
		return
	}
	if c.frame != 0 {
		// The frame is cut: its title bar and border included.
		ow, oh := frame_outer(c)
		key := [4]i32{ow, oh, -1, r}
		if c.shaped && c.shape_key == key { return }
		if tx.shape_rounded_box(m.c, win, 0, 0, ow, oh, f32(r)) {
			c.shaped = true
			c.shape_key = key
		}
		return
	}
	key := [4]i32{c.w, c.h, c.bw, r}
	if c.shaped && c.shape_key == key { return }
	if tx.shape_rounded_box(m.c, c.win, -c.bw, -c.bw, c.w + 2 * c.bw, c.h + 2 * c.bw, f32(r)) {
		c.shaped = true
		c.shape_key = key
	}
}

// Apply the target geometry at once (and stop any animation).
anim_snap :: proc(m: ^Manager, c: ^Client) {
	if c.frame != 0 {
		frame_apply(m, c, c.x, c.y)
		anim_sync_display(m, c)
		return
	}
	wc: xlib.XWindowChanges
	wc.x = c.x
	wc.y = c.y
	wc.width = max(c.w, 1)
	wc.height = max(c.h, 1)
	wc.border_width = c.bw
	xlib.ConfigureWindow(m.dpy, c.win, {.CWX, .CWY, .CWWidth, .CWHeight, .CWBorderWidth}, &wc)
	anim_sync_display(m, c)
}

// Start gliding from what is on screen to the target; false = apply directly.
// The caller applies the border width; the size is applied here at once.
anim_begin :: proc(m: ^Manager, c: ^Client) -> bool {
	if m.settings.animation <= 0 || !c.disp_valid || !is_visible(c) { return false }
	if c.dx == c.x && c.dy == c.y {
		c.animating = false
		return false // nothing moves: a resize alone is applied directly
	}
	from := [2]i32{c.dx, c.dy}
	if c.frame != 0 {
		frame_apply(m, c, from.x, from.y)
	} else {
		wc: xlib.XWindowChanges
		wc.x = from.x
		wc.y = from.y
		wc.width = max(c.w, 1)
		wc.height = max(c.h, 1)
		xlib.ConfigureWindow(m.dpy, c.win, {.CWX, .CWY, .CWWidth, .CWHeight}, &wc)
	}
	c.dw, c.dh = c.w, c.h
	apply_corners(m, c)
	c.anim_from = {from.x, from.y, c.w, c.h}
	c.anim_start = tx.now()
	c.animating = true
	return true
}

// A newly mapped window slides up into place.
anim_grow_in :: proc(m: ^Manager, c: ^Client) {
	if m.settings.animation <= 0 { return }
	x, y := c.x, c.y + ANIM_SLIDE_IN
	if c.frame != 0 {
		frame_apply(m, c, x, y)
	} else {
		xlib.MoveResizeWindow(m.dpy, c.win, x, y, u32(max(c.w, 1)), u32(max(c.h, 1)))
	}
	c.dx, c.dy, c.dw, c.dh = x, y, c.w, c.h
	c.disp_valid = true
	apply_corners(m, c)
	c.anim_from = {x, y, c.w, c.h}
	c.anim_start = tx.now()
	c.animating = true
}

anim_running :: proc(m: ^Manager) -> bool {
	for mon := m.mons; mon != nil; mon = mon.next {
		for c := mon.clients; c != nil; c = c.next {
			if c.animating { return true }
		}
	}
	return false
}

// Advance every running animation to `now`.
anim_step :: proc(m: ^Manager, now: f64) {
	moved := false
	for mon := m.mons; mon != nil; mon = mon.next {
		for c := mon.clients; c != nil; c = c.next {
			if !c.animating { continue }
			moved = true
			t := (now - c.anim_start) / m.settings.animation
			if t >= 1 || !is_visible(c) {
				anim_snap(m, c)
				configure(m, c)
				continue
			}
			e := f32(1 - math.pow(1 - t, 3)) // ease-out cubic
			lerp :: proc(a, b: i32, e: f32) -> i32 { return a + i32(math.round(f32(b - a) * e)) }
			x := lerp(c.anim_from[0], c.x, e)
			y := lerp(c.anim_from[1], c.y, e)
			if x != c.dx || y != c.dy { frame_move(m, c, x, y) }
			c.dx, c.dy = x, y
		}
	}
	if moved { xlib.Flush(m.dpy) }
}

// Put every animating window at its final geometry and give windows back
// their square shape (shutdown: another window manager may take over).
anim_finish_all :: proc(m: ^Manager) {
	for mon := m.mons; mon != nil; mon = mon.next {
		for c := mon.clients; c != nil; c = c.next {
			if c.animating { anim_snap(m, c) }
			if c.shaped {
				tx.shape_reset(m.c, top_window(c))
				c.shaped = false
			}
		}
	}
}

// Re-apply the corners of every window (reload: radius or border changed).
corners_refresh_all :: proc(m: ^Manager) {
	for mon := m.mons; mon != nil; mon = mon.next {
		for c := mon.clients; c != nil; c = c.next { apply_corners(m, c) }
	}
}
