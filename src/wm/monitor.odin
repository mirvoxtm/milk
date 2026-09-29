// Monitors: dwm's updategeom over RandR monitors (tx.monitors), the reserved
// bar strip, and the monitor lookups (recttomon, wintomon, dirtomon).
package wm

import "core:log"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "../tx"

createmon :: proc(m: ^Manager) -> ^Monitor {
	mon := new(Monitor)
	mon.tagset = {1, 1}
	mon.mfact = m.settings.mfact
	mon.nmaster = m.settings.nmaster
	mon.lt = {.Tile, .Float}
	return mon
}

cleanupmon :: proc(m: ^Manager, mon: ^Monitor) {
	if mon == m.mons {
		m.mons = m.mons.next
	} else {
		prev := m.mons
		for prev != nil && prev.next != mon { prev = prev.next }
		if prev != nil { prev.next = mon.next }
	}
	if m.motion_mon == mon { m.motion_mon = nil }
	if m.selmon == mon { m.selmon = m.mons }
	delete(mon.name)
	free(mon)
}

count_monitors :: proc(m: ^Manager) -> int {
	n := 0
	for mon := m.mons; mon != nil; mon = mon.next { n += 1 }
	return n
}

// dwm's updategeom with RandR monitors instead of Xinerama screens: one
// Monitor per unique geometry, new ones appended, clients of removed ones moved
// to the first monitor. Returns true when the geometry changed.
updategeom :: proc(m: ^Manager) -> bool {
	dirty := false
	infos := tx.monitors(m.c)
	unique := make([dynamic]tx.Monitor, context.temp_allocator)
	outer: for info in infos {
		for u in unique {
			if u.rect == info.rect { continue outer }
		}
		append(&unique, info)
	}
	nn := len(unique)
	n := count_monitors(m)

	// New monitors if nn > n.
	for _ in n ..< nn {
		last := m.mons
		for last != nil && last.next != nil { last = last.next }
		if last != nil { last.next = createmon(m) } else { m.mons = createmon(m) }
	}
	i := 0
	for mon := m.mons; i < nn && mon != nil; mon = mon.next {
		u := unique[i]
		if i >= n || u.rect.x != mon.mx || u.rect.y != mon.my || u.rect.w != mon.mw || u.rect.h != mon.mh {
			dirty = true
			mon.num = i
			mon.mx = u.rect.x; mon.wx = u.rect.x
			mon.my = u.rect.y; mon.wy = u.rect.y
			mon.mw = u.rect.w; mon.ww = u.rect.w
			mon.mh = u.rect.h; mon.wh = u.rect.h
		}
		if mon.name != u.name {
			delete(mon.name)
			mon.name = strings.clone(u.name)
		}
		mon.primary = u.primary
		i += 1
	}
	// Removed monitors if n > nn.
	for _ in nn ..< n {
		last := m.mons
		for last.next != nil { last = last.next }
		for last.clients != nil {
			dirty = true
			c := last.clients
			last.clients = c.next
			detachstack(c)
			c.mon = m.mons
			attach(c)
			attachstack(c)
		}
		if last == m.selmon { m.selmon = m.mons }
		cleanupmon(m, last)
	}
	if update_workareas(m) { dirty = true }
	if dirty {
		m.selmon = m.mons
		m.selmon = wintomon(m, m.root)
		for mon := m.mons; mon != nil; mon = mon.next {
			log.debugf("wm: monitor %d %q %dx%d%+d%+d, window area %dx%d%+d%+d", mon.num, mon.name,
			           mon.mw, mon.mh, mon.mx, mon.my, mon.ww, mon.wh, mon.wx, mon.wy)
		}
	}
	return dirty
}

// The monitor whose strip is reserved: by RandR name, else the primary one,
// else the top-left one (like tx.monitor_rect).
reserved_monitor :: proc(m: ^Manager) -> ^Monitor {
	if m.reserved.monitor != "primary" {
		for mon := m.mons; mon != nil; mon = mon.next {
			if mon.name == m.reserved.monitor { return mon }
		}
	}
	for mon := m.mons; mon != nil; mon = mon.next {
		if mon.primary { return mon }
	}
	best := m.mons
	for mon := m.mons; mon != nil; mon = mon.next {
		if mon.my < best.my || (mon.my == best.my && mon.mx < best.mx) { best = mon }
	}
	return best
}

// dwm's updatebarpos for every monitor: the window area is the monitor minus
// the reserved strip. Returns true when any window area changed.
update_workareas :: proc(m: ^Manager) -> bool {
	if m.mons == nil { return false }
	target := reserved_monitor(m)
	changed := false
	for mon := m.mons; mon != nil; mon = mon.next {
		wx, wy, ww, wh := mon.mx, mon.my, mon.mw, mon.mh
		if mon == target {
			top := min(m.reserved.top, mon.mh / 2)
			bottom := min(m.reserved.bottom, mon.mh / 2)
			wy += top
			wh -= top + bottom
		}
		if wx != mon.wx || wy != mon.wy || ww != mon.ww || wh != mon.wh {
			mon.wx, mon.wy, mon.ww, mon.wh = wx, wy, ww, wh
			changed = true
		}
	}
	return changed
}

// The pointer position on the root window.
getrootptr :: proc(m: ^Manager) -> (x, y: i32, ok: bool) {
	dummy: xlib.Window
	di: i32
	mask: xlib.KeyMask
	ok = bool(xlib.QueryPointer(m.dpy, m.root, &dummy, &dummy, &x, &y, &di, &di, &mask))
	return
}

// Area of the intersection of a rectangle with a monitor's window area.
@(private)
intersect :: proc(x, y, w, h: i32, mon: ^Monitor) -> i32 {
	return max(0, min(x + w, mon.wx + mon.ww) - max(x, mon.wx)) *
	       max(0, min(y + h, mon.wy + mon.wh) - max(y, mon.wy))
}

// The monitor a rectangle overlaps most (the selected one when none).
recttomon :: proc(m: ^Manager, x, y, w, h: i32) -> ^Monitor {
	r := m.selmon
	area: i32 = 0
	for mon := m.mons; mon != nil; mon = mon.next {
		a := intersect(x, y, w, h, mon)
		if a > area {
			area = a
			r = mon
		}
	}
	return r
}

wintomon :: proc(m: ^Manager, w: xlib.Window) -> ^Monitor {
	if w == m.root {
		if x, y, ok := getrootptr(m); ok { return recttomon(m, x, y, 1, 1) }
	}
	if c := wintoclient(m, w); c != nil { return c.mon }
	return m.selmon
}

// The next (dir > 0) or previous monitor, wrapping around.
dirtomon :: proc(m: ^Manager, dir: int) -> ^Monitor {
	mon: ^Monitor
	if dir > 0 {
		mon = m.selmon.next
		if mon == nil { mon = m.mons }
	} else if m.selmon == m.mons {
		mon = m.mons
		for mon.next != nil { mon = mon.next }
	} else {
		mon = m.mons
		for mon.next != m.selmon { mon = mon.next }
	}
	return mon
}
