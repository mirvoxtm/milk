// Desktop icons dropped on the bar's area dots: released over the dot of
// area N, the dragged icons are kept to area N (the "Show on" choice of
// areas.odin; with Ctrl, N is added to the areas they show on), go back to
// their places on the grid and leave the screen when N is not the area on
// screen. Dropped on the current area's dot they just go back.
//
// The desktop holds the pointer grab while it drags, so the bar never sees
// the pointer: main.odin hands the desktop a probe (set_drop_probe) that
// asks the bar which dot is under the pointer and highlights it.
package desktop

// `ending` false: the pointer is at root (x, y) during a drag; highlight the
// dot under it and return its area (1-based; 0 = none). `ending` true: the
// drag is over (dropped at x, y, or abandoned with x = y = -1); clear the
// highlight and return the area under (x, y).
Drop_Probe :: #type proc(data: rawptr, x, y: i32, ending: bool) -> int

set_drop_probe :: proc(d: ^Daemon, probe: Drop_Probe, data: rawptr) {
	if d == nil { return }
	d.drop_probe = probe
	d.drop_data = data
}

// During a drag: which area dot the pointer is over (recorded in the pointer state).
@(private)
drop_hover :: proc(d: ^Daemon) {
	p := &d.layer.pointer
	p.drop_area = 0
	if d.drop_probe == nil || p.mode != .Dragging { return }
	p.drop_area = d.drop_probe(d.drop_data, p.pos.x, p.pos.y, false)
}

// The drag is over: the area dot it ended on (0 = none); the bar's highlight goes.
@(private)
drop_end :: proc(d: ^Daemon, x, y: i32) -> int {
	p := &d.layer.pointer
	p.drop_area = 0
	if d.drop_probe == nil { return 0 }
	return d.drop_probe(d.drop_data, x, y, true)
}

// The dragged icons were released on area n's dot (`add`: Ctrl was held).
// Shortcuts of an area's own folder belong to that area and stay as they are.
@(private)
drop_on_area :: proc(d: ^Daemon, n: int, add: bool) {
	l := &d.layer
	p := &l.pointer
	drag_place(d, {0, 0}) // back to their places: dropping never moves them on the grid
	changed := false
	if n != d.area && n >= 1 && n <= 31 {
		for i in p.moving {
			if i < 0 || i >= len(l.cells) { continue }
			it := &l.items[l.cells[i].entry]
			if !item_has_area_choice(d, it) { continue }
			set, kept := item_areas(d, it)
			if add {
				if !kept { continue } // shown on every area: on n already
				set += {n}
			} else {
				set = {n}
			}
			item_set_areas(d, it, set)
			changed = true
		}
	}
	p.mode = .Idle
	clear(&p.moving)
	clear(&p.origin)
	// Icons kept away from the area on screen leave it (the cells are rebuilt).
	if changed { layer_refresh(d, false) }
}
