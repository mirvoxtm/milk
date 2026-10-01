// The area dots as drop targets: desktop icons and windows dragged onto a
// dot go to that area. The component that drags (the desktop or the window
// manager) holds the pointer grab, so the bar sees no motion of its own:
// main.odin asks `area_at` where the pointer is and `set_drop_target`
// highlights that dot. While a drag lasts every area's dot shows, even with
// bar.showEmptyWorkspaces off, so empty areas can be dropped on too.
package bar

import tx "../tx"

// The area (1-based) whose dot is at the root point (x, y); 0 = none. The
// whole height of the bar's strip counts (a floating bar's margin and the
// screen edge too), and each dot reaches halfway to its neighbours.
area_at :: proc(b: ^Bar, x, y: i32) -> int {
	if b == nil || !b.started || b.win == 0 || !b.mapped { return 0 }
	r := b.rect
	if x < r.x || x >= r.x + r.w || y < r.y || y >= r.y + r.h { return 0 }
	lx := x - r.x - b.body.x
	half := dot_metrics(b).gap / 2 + 1
	for &w in b.widgets {
		if w.kind != .Workspaces || !w.visible { continue }
		for it in workspace_items(b, w.x + w.pad) {
			if lx >= it.x - half && lx < it.x + it.w + half { return it.index + 1 }
		}
	}
	return 0
}

// Highlight area n's dot (0 = none) while `dragging`; false ends the drag
// look. Repaints at once: the caller may be inside a modal drag loop that
// keeps the main loop (and the bar's tick) waiting.
set_drop_target :: proc(b: ^Bar, n: int, dragging: bool) {
	if b == nil { return }
	target := dragging ? max(n, 0) : 0
	if target == b.drop_target && dragging == b.dropping { return }
	context.allocator = b.allocator
	// A window being moved was raised when the move started: the dots must
	// stay visible above it (a bottom bar would be under the window otherwise).
	raise := dragging && !b.dropping
	b.drop_target = target
	b.dropping = dragging
	if b.started && b.mapped && b.win != 0 {
		if raise { tx.raise_window(b.c, b.win) }
		render(b)
	} else {
		b.dirty = true
	}
}

// A soft ring (a pill around the current area's) with an accent outline
// behind the dot under the pointer, clear of the neighbouring dots.
@(private)
draw_drop_target :: proc(b: ^Bar, cv: ^tx.Canvas, it: Workspace_Item, cx: f32) {
	m := dot_metrics(b)
	ph := m.slot + m.gap + 2
	pw := it.w + m.gap + 2
	r := tx.Rect{i32(cx + 0.5) - pw / 2, b.body.y + (b.body.h - ph) / 2, pw, ph}
	tx.canvas_fill_rounded_rect(cv, r, f32(ph) / 2, b.theme.surface)
	tx.canvas_stroke_rounded_rect(cv, r, f32(ph) / 2, 1.5, tx.color_with_alpha(b.theme.accent, 170))
}
