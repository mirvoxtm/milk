// The task list ("tasks"): a classic taskbar of the windows on the current
// area, one pill per window with its icon and title.
//
// State: every client of _NET_CLIENT_LIST (all areas, in that order) keeps a
// record of what decides whether and how it is listed: its area
// (_NET_WM_DESKTOP), state (hidden = minimized, skip-taskbar, demands
// attention), window type, class and the WM_HINTS urgency flag. They are read
// when the client appears and again when a PropertyNotify says one changed,
// so drawing never waits on the server for them. Titles and icons are fetched
// when a task is first shown and refetched on change (icons are cached per
// window and freed with it). A task is shown when it is eligible (a normal
// window, dialog or utility that does not skip the taskbar and is not one of
// milk's own) and on the current area; the bar repaints when the shown set
// or something drawn for a shown task changes.
//
// Layout: a pill is as wide as its icon and whole title, up to TASK_MAX_W.
// Short of room, the layout squeezes the titles together with the window
// title and the media text (down to MIN_FLEX each), then hands the list what
// is left: the widest pills shrink first, below TASK_MIN_TEXT of title all of
// them turn into icons, and the tasks that still do not fit go behind a "+N"
// pill (the active task always keeps its place). The list never pushes other
// widgets off the bar.
//
// Input: a left click activates a task (_NET_ACTIVE_WINDOW with source 2, a
// taskbar) or minimizes the active one (ICCCM WM_CHANGE_STATE → IconicState);
// a middle click closes it (_NET_CLOSE_WINDOW); a right click asks milk's
// window manager for the window menu (_MILK_WINDOW_MENU); the wheel walks
// through the tasks; "+N" activates the next task behind it.
//
// Event masks: milk's window manager shares this X connection and already
// selects PropertyChange on its clients. Under another window manager the
// bar adds PropertyChange to the mask the connection has (XSelectInput
// replaces the whole mask) and later removes only what it added.
package bar

import "core:fmt"
import "core:slice"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "../tx"

@(private) TASK_MAX_W    :: 216 // widest pill
@(private) TASK_GAP      :: 4   // between two pills
@(private) TASK_MIN_TEXT :: 48  // with less room for their titles the pills show only icons
@(private) TASK_TAIL     :: 2   // a title's end gets a little more room than the icon's start
@(private) ALL_DESKTOPS  :: u32(0xFFFF_FFFF)
@(private) SOURCE_PAGER  :: 2   // EWMH source indication of taskbars and pagers
@(private) ICONIC_STATE  :: 3   // ICCCM WM_CHANGE_STATE: minimize
@(private) MILK_CLASS    :: "Milk"

Task :: struct {
	win:         xlib.Window,
	title:       string, // owned; valid once title_ready
	class:       string, // owned; WM_CLASS class, shown for untitled windows
	desktop:     u32,    // _NET_WM_DESKTOP (ALL_DESKTOPS: sticky) when has_desktop
	has_desktop: bool,
	excluded:    bool,   // a dock, desktop, splash, menu... or one of milk's windows
	skip:        bool,   // _NET_WM_STATE_SKIP_TASKBAR
	hidden:      bool,   // _NET_WM_STATE_HIDDEN (minimized)
	attention:   bool,   // _NET_WM_STATE_DEMANDS_ATTENTION
	urgent:      bool,   // WM_HINTS urgency flag
	title_ready: bool,
	icon:        tx.Image,
	has_icon:    bool,
	icon_ready:  bool,   // _NET_WM_ICON was read (has_icon: it had an image)
	watching:    bool,   // the bar added PropertyChange to its event mask
	shown:       bool,   // listed: eligible and on the current area
}

// A pill placed by the last layout (x relative to the widget box).
Task_Slot :: struct {
	win:       xlib.Window, // 0 = the "+N" pill
	index:     int,         // into Tasks_State.clients; -1 = "+N" (valid for one render)
	x, w:      i32,
	icon_only: bool,
	label:     string,      // title or "+N", drawn during the same render only
	room:      i32,         // width available to the title
}

Tasks_State :: struct {
	enabled:   bool, // a "tasks" widget is on the bar
	stale:     bool, // _NET_CLIENT_LIST changed: sync on the next tick
	recheck:   bool, // an area, state or type changed: decide again which tasks are shown
	clients:   [dynamic]Task,
	slots:     [dynamic]Task_Slot,
	more:      int, // tasks behind the "+N" pill
	compact_w: i32, // list width with every title cut to MIN_FLEX (the layout's squeeze)
	icon_size: i32, // size of the cached icons
	pointer_x: i32, // pointer over the bar (window coordinates), -1 = outside
	hover:     int, // slot under the pointer, -1 = none
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

// Follow the widget list: clients are tracked while a "tasks" widget is on the bar.
@(private)
tasks_configure :: proc(b: ^Bar) {
	wanted := false
	for w in b.widgets {
		if w.kind == .Tasks { wanted = true }
	}
	tasks := &b.tasks
	tasks.hover = -1
	if wanted == tasks.enabled { return }
	tasks.enabled = wanted
	if wanted {
		tasks.stale = true // read by start or the next tick
	} else {
		tasks_release(b)
	}
}

@(private)
tasks_release :: proc(b: ^Bar) {
	tasks := &b.tasks
	for &t in tasks.clients { release_task(b, &t) }
	clear(&tasks.clients)
	clear(&tasks.slots)
	tasks.more = 0
	tasks.hover = -1
	tasks.stale = false
	tasks.recheck = false
}

@(private)
tasks_destroy :: proc(b: ^Bar) {
	tasks_release(b)
	delete(b.tasks.clients)
	delete(b.tasks.slots)
	b.tasks.enabled = false
}

// Apply what the events asked for: re-read the client list, or only decide
// again which tasks are shown. Returns true when the shown tasks changed.
@(private)
tasks_update :: proc(b: ^Bar) -> bool {
	tasks := &b.tasks
	stale, recheck := tasks.stale, tasks.recheck
	tasks.stale, tasks.recheck = false, false
	if !tasks.enabled { return false }
	if stale { return sync_tasks(b) }
	return recheck && refilter_tasks(b)
}

// Follow _NET_CLIENT_LIST: known clients keep their records (in the new
// order), new ones are read, the ones that left are released.
@(private)
sync_tasks :: proc(b: ^Bar) -> bool {
	tasks := &b.tasks
	c := b.c
	before := shown_windows(b)
	wins := tx.get_windows(c, c.root, "_NET_CLIENT_LIST")
	if len(wins) == 0 { wins = tx.get_windows(c, c.root, "_NET_CLIENT_LIST_STACKING") }
	next := make([dynamic]Task, 0, len(wins))
	for win in wins {
		if win == 0 || win == b.win || task_index(next[:], win) >= 0 { continue }
		if i := task_index(tasks.clients[:], win); i >= 0 {
			append(&next, tasks.clients[i])
			tasks.clients[i].win = 0 // moved, not released below
			continue
		}
		t := Task{win = win}
		read_task(b, &t)
		append(&next, t)
	}
	for &t in tasks.clients {
		if t.win != 0 { release_task(b, &t) }
	}
	delete(tasks.clients)
	tasks.clients = next
	refilter_tasks(b)
	return !slice.equal(before, shown_windows(b))
}

// Decide which tasks are shown. Returns true when any changed.
@(private)
refilter_tasks :: proc(b: ^Bar) -> bool {
	changed := false
	for &t in b.tasks.clients {
		shown := task_on_area(b, &t)
		if shown != t.shown {
			t.shown = shown
			changed = true
		}
	}
	return changed
}

@(private)
task_on_area :: proc(b: ^Bar, t: ^Task) -> bool {
	if t.excluded || t.skip { return false }
	current := b.ws.current
	if current < 0 { return true } // no areas
	if t.has_desktop { return t.desktop == ALL_DESKTOPS || int(t.desktop) == current }
	// No _NET_WM_DESKTOP (dwm): the area it was last seen on, when known.
	if d, known := b.ws.learned[t.win]; known { return d == current }
	return true
}

@(private)
shown_windows :: proc(b: ^Bar) -> []xlib.Window {
	out := make([dynamic]xlib.Window, context.temp_allocator)
	for t in b.tasks.clients {
		if t.shown { append(&out, t.win) }
	}
	return out[:]
}

@(private)
task_index :: proc(list: []Task, win: xlib.Window) -> int {
	for t, i in list {
		if t.win == win { return i }
	}
	return -1
}

@(private)
find_task :: proc(b: ^Bar, win: xlib.Window) -> ^Task {
	if win == 0 { return nil }
	if i := task_index(b.tasks.clients[:], win); i >= 0 { return &b.tasks.clients[i] }
	return nil
}

// ---------------------------------------------------------------------------
// Client properties
// ---------------------------------------------------------------------------

// A new client: watch it first (no change slips in between), then read what
// decides its listing. The title and icon wait until it is shown.
@(private)
read_task :: proc(b: ^Bar, t: ^Task) {
	watch_task(b, t)
	_, class := tx.window_class(b.c, t.win)
	t.class = sanitize_line(class)
	t.excluded = t.class == MILK_CLASS || !listed_type(b, t.win)
	load_task_state(b, t)
	load_task_desktop(b, t)
	load_task_hints(b, t)
}

@(private)
release_task :: proc(b: ^Bar, t: ^Task) {
	unwatch_task(b, t)
	delete(t.title)
	delete(t.class)
	drop_task_icon(t)
	t^ = {}
}

// PropertyNotify on any window: update the task it belongs to (the event is
// never claimed: the window manager reads the same ones).
@(private)
tasks_property :: proc(b: ^Bar, win: xlib.Window, atom: xlib.Atom) {
	t := find_task(b, win)
	if t == nil { return }
	a := &b.atoms
	switch atom {
	case a.net_wm_name, a.wm_name:
		if !t.shown {
			t.title_ready = false // read when it is shown
		} else if load_task_title(b, t) {
			b.dirty = true
		}
	case a.net_wm_icon:
		drop_task_icon(t) // refetched by the next layout that shows it
		if t.shown { b.dirty = true }
	case a.net_wm_state:
		if load_task_state(b, t) {
			b.tasks.recheck = true
			if t.shown { b.dirty = true }
		}
	case a.net_wm_desktop:
		if load_task_desktop(b, t) { b.tasks.recheck = true }
	case a.wm_hints:
		if load_task_hints(b, t) && t.shown { b.dirty = true }
	case a.net_wm_window_type:
		excluded := t.class == MILK_CLASS || !listed_type(b, t.win)
		if excluded != t.excluded {
			t.excluded = excluded
			b.tasks.recheck = true
		}
	}
}

// _NET_WM_NAME (else WM_NAME) on one line. Returns true when it changed.
@(private)
load_task_title :: proc(b: ^Bar, t: ^Task) -> bool {
	title := sanitize_line(tx.window_title(b.c, t.win), context.temp_allocator)
	t.title_ready = true
	if title == t.title { return false }
	delete(t.title)
	t.title = strings.clone(title)
	return true
}

@(private)
load_task_state :: proc(b: ^Bar, t: ^Task) -> bool {
	a := &b.atoms
	states := tx.get_atoms(b.c, t.win, "_NET_WM_STATE")
	hidden := slice.contains(states, a.state_hidden)
	skip := slice.contains(states, a.state_skip_taskbar)
	attention := slice.contains(states, a.state_attention)
	if hidden == t.hidden && skip == t.skip && attention == t.attention { return false }
	t.hidden, t.skip, t.attention = hidden, skip, attention
	return true
}

@(private)
load_task_desktop :: proc(b: ^Bar, t: ^Task) -> bool {
	d, ok := tx.get_cardinal(b.c, t.win, "_NET_WM_DESKTOP")
	desktop := ok ? card32(d) : 0
	if ok == t.has_desktop && desktop == t.desktop { return false }
	t.has_desktop, t.desktop = ok, desktop
	return true
}

// The ICCCM urgency flag.
@(private)
load_task_hints :: proc(b: ^Bar, t: ^Task) -> bool {
	urgent := false
	if hints := xlib.GetWMHints(b.c.dpy, t.win); hints != nil {
		urgent = .XUrgencyHint in hints.flags
		xlib.Free(hints)
	}
	if urgent == t.urgent { return false }
	t.urgent = urgent
	return true
}

// EWMH: the first window type we know decides; none at all means normal.
@(private)
listed_type :: proc(b: ^Bar, win: xlib.Window) -> bool {
	for a in tx.get_atoms(b.c, win, "_NET_WM_WINDOW_TYPE") {
		name := tx.atom_name(b.c, a)
		switch name {
		case "_NET_WM_WINDOW_TYPE_NORMAL", "_NET_WM_WINDOW_TYPE_DIALOG", "_NET_WM_WINDOW_TYPE_UTILITY":
			return true
		}
		// Docks, desktops, toolbars, splash screens, menus, tooltips, notifications...
		if strings.has_prefix(name, "_NET_WM_WINDOW_TYPE_") { return false }
	}
	return true
}

@(private)
drop_task_icon :: proc(t: ^Task) {
	if t.has_icon { tx.image_destroy(&t.icon) }
	t.has_icon = false
	t.icon_ready = false
}

@(private)
ensure_task_icon :: proc(b: ^Bar, t: ^Task) {
	if t.icon_ready { return }
	t.icon, t.has_icon = tx.window_icon(b.c, t.win, b.tasks.icon_size)
	t.icon_ready = true
}

// The title; untitled windows show their class.
@(private)
task_label :: proc(b: ^Bar, t: ^Task) -> string {
	if t.title != "" { return t.title }
	if t.class != "" { return t.class }
	return tr(b, "Janela", "Window")
}

// ---------------------------------------------------------------------------
// Event masks
// ---------------------------------------------------------------------------

// Add PropertyChange to the client's event mask for this connection, keeping
// the bits milk's window manager (same connection) selected.
@(private)
watch_task :: proc(b: ^Bar, t: ^Task) {
	attrs: xlib.XWindowAttributes
	if xlib.GetWindowAttributes(b.c.dpy, t.win, &attrs) == 0 { return }
	if .PropertyChange not_in attrs.your_event_mask {
		xlib.SelectInput(b.c.dpy, t.win, attrs.your_event_mask + {.PropertyChange})
		t.watching = true
	}
}

// Undo watch_task; while the window is active, the active-window title takes
// the mask over (unwatch_active removes it later).
@(private)
unwatch_task :: proc(b: ^Bar, t: ^Task) {
	if !t.watching { return }
	t.watching = false
	if t.win == b.active.win && !b.active.watching {
		b.active.watching = true
		return
	}
	attrs: xlib.XWindowAttributes
	if xlib.GetWindowAttributes(b.c.dpy, t.win, &attrs) != 0 {
		xlib.SelectInput(b.c.dpy, t.win, attrs.your_event_mask - {.PropertyChange})
	}
}

// unwatch_active hands the mask over while the window is listed.
@(private)
tasks_adopt_watch :: proc(b: ^Bar, win: xlib.Window) -> bool {
	t := find_task(b, win)
	if t == nil { return false }
	t.watching = true
	return true
}

// A client window was destroyed: its event mask went with it.
@(private)
tasks_window_destroyed :: proc(b: ^Bar, win: xlib.Window) {
	if t := find_task(b, win); t != nil { t.watching = false }
}

// ---------------------------------------------------------------------------
// Layout and drawing
// ---------------------------------------------------------------------------

// Pills are as tall as the hover pills; `pad` centres the icon in a round
// icon-only pill; `side`, roomier, is the space at both ends of a titled
// pill and of "+N".
@(private)
task_metrics :: proc(b: ^Bar) -> (ph, icon, pad, side: i32) {
	ph = hover_height(b)
	icon = clamp(i32(b.cfg.bar.icon_size), 8, max(8, ph - 6))
	pad = max(2, (ph - icon) / 2)
	side = pad + max(4, ph / 4)
	return
}

// Place the pills in at most `limit` pixels (-1: no limit) and size the widget.
@(private)
measure_tasks :: proc(b: ^Bar, w: ^Widget, limit: i32) {
	tasks := &b.tasks
	clear(&tasks.slots)
	tasks.more = 0
	tasks.compact_w = 0
	if !tasks.enabled || b.font == nil { return }
	ph, icon, pad, side := task_metrics(b)
	if icon != tasks.icon_size {
		for &t in tasks.clients { drop_task_icon(&t) }
		tasks.icon_size = icon
	}
	listed := make([dynamic]int, context.temp_allocator)
	for t, i in tasks.clients {
		if t.shown { append(&listed, i) }
	}
	n := len(listed)
	if n == 0 { return }

	// Natural widths: the whole title, up to TASK_MAX_W.
	frame := 2 * side + TASK_TAIL + icon + TEXT_INK_GAP // a pill without its title
	labels := make([]string, n, context.temp_allocator)
	pills := make([]i32, n, context.temp_allocator)
	gaps := i32(n - 1) * TASK_GAP
	natural, compact := gaps, gaps
	for index, k in listed {
		t := &tasks.clients[index]
		if !t.title_ready { load_task_title(b, t) }
		labels[k] = task_label(b, t)
		pills[k] = min(frame + tx.text_width(b.c, b.font, labels[k]), TASK_MAX_W)
		natural += pills[k]
		compact += min(pills[k], frame + MIN_FLEX)
	}
	tasks.compact_w = compact

	icons_only := false
	placed := n
	if limit >= 0 && natural > limit {
		level := water_level(pills, limit - gaps)
		if level - frame >= TASK_MIN_TEXT {
			for &p in pills { p = min(p, level) }
		} else {
			icons_only = true
			if i32(n) * (ph + TASK_GAP) - TASK_GAP > limit {
				// As many icons as fit next to a "+N" pill for the rest.
				placed = n - 1
				for placed > 0 && i32(placed) * (ph + TASK_GAP) + more_width(b, n - placed, ph, side) > limit { placed -= 1 }
				if placed == 0 && more_width(b, n, ph, side) > limit { return } // no room at all
			}
		}
	}
	tasks.more = n - placed
	if tasks.more > 0 && placed > 0 {
		// The active task keeps a pill: it takes the last place.
		for k in placed ..< n {
			if tasks.clients[listed[k]].win == b.active.win {
				listed[placed - 1], listed[k] = listed[k], listed[placed - 1]
				break
			}
		}
	}

	x: i32
	for k in 0 ..< placed {
		t := &tasks.clients[listed[k]]
		ensure_task_icon(b, t)
		s := Task_Slot{win = t.win, index = listed[k], x = x, w = ph, icon_only = icons_only}
		if !icons_only {
			s.w = pills[k]
			s.label = labels[k]
			s.room = pills[k] - frame
		}
		append(&tasks.slots, s)
		x += s.w + TASK_GAP
	}
	if tasks.more > 0 {
		more := Task_Slot{index = -1, x = x, w = more_width(b, tasks.more, ph, side), label = fmt.tprintf("+%d", tasks.more)}
		append(&tasks.slots, more)
		x += more.w + TASK_GAP
	}
	w.w = x - TASK_GAP
	w.pad = pad
	w.visible = w.w > 0
}

// The largest width the pills can be cut down to and still fit in `budget`
// (the widest shrink first; the narrow ones keep theirs).
@(private)
water_level :: proc(pills: []i32, budget: i32) -> i32 {
	sorted := slice.clone(pills, context.temp_allocator)
	slice.sort(sorted)
	rest := budget
	for v, k in sorted {
		left := i32(len(sorted) - k)
		if v * left > rest { return rest / left }
		rest -= v
	}
	return sorted[len(sorted) - 1]
}

@(private)
more_width :: proc(b: ^Bar, count: int, ph, side: i32) -> i32 {
	return max(ph, tx.text_width(b.c, b.font, fmt.tprintf("+%d", count)) + 2 * side)
}

// Width of the (first) task list as last measured.
@(private)
tasks_widget_width :: proc(b: ^Bar) -> i32 {
	for w in b.widgets {
		if w.kind == .Tasks && w.visible { return w.w }
	}
	return 0
}

// The pill's fill (alpha 0 = none; `hot`: under the pointer), the ink of its
// title and glyph, and the icon opacity: accent for the active task, the
// warning tint for one that wants attention, dimmed when minimized, the
// surface colour otherwise.
@(private)
task_look :: proc(b: ^Bar, t: ^Task, hot: bool) -> (fill, ink: tx.Color, opacity: f32) {
	th := &b.theme
	opacity = 1
	switch {
	case t.win == b.active.win && !t.hidden:
		fill = hot ? tx.color_mix(th.accent, th.background, 0.15) : th.accent
		ink = th.accent_foreground
	case t.attention || t.urgent:
		fill = tx.color_mix(th.background, th.warning, hot ? 0.34 : 0.22)
		ink = th.warning
	case t.hidden:
		if hot { fill = th.surface }
		ink = th.muted
		opacity = 0.45
	case:
		fill = surface_fill(b, hot)
		ink = th.foreground
	}
	return
}

// Other tasks and "+N".
@(private)
surface_fill :: proc(b: ^Bar, hot: bool) -> tx.Color {
	return hot ? tx.color_mix(b.theme.surface, b.theme.muted, 0.3) : b.theme.surface
}

@(private)
task_icon_x :: proc(s: Task_Slot, icon, side: i32) -> i32 {
	return s.icon_only ? (s.w - icon) / 2 : side
}

// Pills and window icons (canvas pass).
@(private)
draw_tasks :: proc(b: ^Bar, cv: ^tx.Canvas, w: ^Widget, hovered: bool) {
	tasks := &b.tasks
	ph, icon, _, side := task_metrics(b)
	hot_slot := -1
	if hovered {
		// The slots may have moved under a still pointer since the last motion.
		hot_slot = tasks_slot_at(b, w, tasks.pointer_x)
		tasks.hover = hot_slot
	}
	x0 := b.body.x + w.x
	y := b.body.y + (b.body.h - ph) / 2
	for s, i in tasks.slots {
		r := tx.Rect{x0 + s.x, y, s.w, ph}
		hot := i == hot_slot
		if s.index < 0 {
			tx.canvas_fill_rounded_rect(cv, r, f32(ph) / 2, surface_fill(b, hot))
			continue
		}
		t := &tasks.clients[s.index]
		fill, _, opacity := task_look(b, t, hot)
		if fill.a > 0 { tx.canvas_fill_rounded_rect(cv, r, f32(ph) / 2, fill) }
		if t.has_icon {
			tx.canvas_blit_image(cv, t.icon, r.x + task_icon_x(s, icon, side), b.body.y + (b.body.h - t.icon.h) / 2, opacity)
		}
	}
}

// Titles, "+N" and the glyph of windows without an icon (Xft pass).
@(private)
draw_tasks_text :: proc(b: ^Bar, ts: ^tx.Text_Surface, w: ^Widget) {
	tasks := &b.tasks
	_, icon, _, side := task_metrics(b)
	x0 := b.body.x + w.x
	baseline := b.body.y + b.text_baseline
	for s in tasks.slots {
		if s.index < 0 {
			tw := tx.text_width(b.c, b.font, s.label)
			tx.draw_text(ts, b.font, x0 + s.x + (s.w - tw) / 2, baseline, s.label, b.theme.foreground)
			continue
		}
		t := &tasks.clients[s.index]
		_, ink, _ := task_look(b, t, false)
		ix := x0 + s.x + task_icon_x(s, icon, side)
		if g := &b.icons.glyphs[.App_Window]; !t.has_icon && g.ok {
			gx := ix + (icon - glyph_ink_w(g)) / 2 - g.ink_x
			tx.draw_text(ts, g.font, gx, b.body.y + (b.body.h - g.ink_h) / 2 + g.ink_y, g.text, ink)
		}
		if !s.icon_only {
			tx.draw_text(ts, b.font, ix + icon + TEXT_INK_GAP, baseline, tx.text_ellipsize(b.c, b.font, s.label, s.room), ink)
		}
	}
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

// The slot under window x `x`, the gaps split between neighbours (-1 = none).
@(private)
tasks_slot_at :: proc(b: ^Bar, w: ^Widget, x: i32) -> int {
	rx := x - b.body.x - w.x
	for s, i in b.tasks.slots {
		if rx < s.x + s.w + TASK_GAP / 2 { return i }
	}
	return len(b.tasks.slots) - 1
}

// Pointer motion over the bar (window x; -1 = it left): highlight the pill under it.
@(private)
tasks_pointer :: proc(b: ^Bar, x: i32) {
	tasks := &b.tasks
	if !tasks.enabled { return }
	tasks.pointer_x = x
	hot := -1
	if x >= 0 && b.hover >= 0 && b.widgets[b.hover].kind == .Tasks { hot = tasks_slot_at(b, &b.widgets[b.hover], x) }
	if hot != tasks.hover {
		tasks.hover = hot
		b.dirty = true
	}
}

@(private)
tasks_button :: proc(b: ^Bar, w: ^Widget, ev: ^xlib.XButtonEvent) {
	i := tasks_slot_at(b, w, ev.x)
	if i < 0 { return }
	s := b.tasks.slots[i]
	switch i32(ev.button) {
	case 1:
		close_popups(b)
		t := find_task(b, s.win)
		switch {
		case s.index < 0:
			if win := next_hidden_task(b); win != 0 { activate_task(b, win, ev.time) }
		case t == nil: // gone since the last frame
		case t.win == b.active.win && !t.hidden:
			minimize_task(b, t.win)
		case:
			activate_task(b, t.win, ev.time)
		}
	case 2:
		if s.win != 0 { close_task(b, s.win, ev.time) }
	case 3:
		if s.win != 0 {
			close_popups(b)
			window_menu(b, w, s, ev.time)
		}
	case 4:
		cycle_tasks(b, -1, ev.time)
	case 5:
		cycle_tasks(b, 1, ev.time)
	}
}

// The wheel: activate the next (1) or previous (-1) task, skipping minimized ones.
@(private)
cycle_tasks :: proc(b: ^Bar, direction: int, t: xlib.Time) {
	wins := make([dynamic]xlib.Window, context.temp_allocator)
	current := -1
	for task in b.tasks.clients {
		if !task.shown || task.hidden { continue }
		if task.win == b.active.win { current = len(wins) }
		append(&wins, task.win)
	}
	n := len(wins)
	if n == 0 { return }
	next := direction > 0 ? 0 : n - 1
	if current >= 0 { next = (current + direction + n) % n }
	if wins[next] != b.active.win { activate_task(b, wins[next], t) }
}

// "+N": the first task behind it after the active one, so that repeated
// clicks walk through them all (the active task always has a pill).
@(private)
next_hidden_task :: proc(b: ^Bar) -> xlib.Window {
	listed := shown_windows(b)
	n := len(listed)
	start := -1
	for win, i in listed {
		if win == b.active.win { start = i }
	}
	next: for k in 1 ..= n {
		win := listed[(start + k + n) % n]
		for s in b.tasks.slots {
			if s.win == win { continue next }
		}
		return win
	}
	return 0
}

// A client message about `win`, sent to the root window for the window manager.
@(private)
send_window_message :: proc(b: ^Bar, win: xlib.Window, name: string, data: [5]int) {
	ev: xlib.XEvent
	ev.xclient.type = .ClientMessage
	ev.xclient.window = win
	ev.xclient.message_type = tx.atom(b.c, name)
	ev.xclient.format = 32
	ev.xclient.data.l = data
	xlib.SendEvent(b.c.dpy, b.c.root, false, {.SubstructureRedirect, .SubstructureNotify}, &ev)
	b.need_flush = true
}

// Switch to the task's area, un-minimize, focus and raise it.
@(private)
activate_task :: proc(b: ^Bar, win: xlib.Window, t: xlib.Time) {
	send_window_message(b, win, "_NET_ACTIVE_WINDOW", {SOURCE_PAGER, int(t), int(b.active.win), 0, 0})
}

@(private)
minimize_task :: proc(b: ^Bar, win: xlib.Window) {
	send_window_message(b, win, "WM_CHANGE_STATE", {ICONIC_STATE, 0, 0, 0, 0})
}

@(private)
close_task :: proc(b: ^Bar, win: xlib.Window, t: xlib.Time) {
	send_window_message(b, win, "_NET_CLOSE_WINDOW", {int(t), SOURCE_PAGER, 0, 0, 0})
}

// milk's window menu, from the pill's left edge on the bar's inner edge: the
// bottom of a top bar, the top of a bottom one (the menu then opens upwards).
@(private)
window_menu :: proc(b: ^Bar, w: ^Widget, s: Task_Slot, t: xlib.Time) {
	bar := bar_rect(b)
	x := bar.x + w.x + s.x
	y := b.cfg.bar.position == "bottom" ? bar.y : bar.y + bar.h
	send_window_message(b, b.c.root, "_MILK_WINDOW_MENU", {int(s.win), int(x), int(y), int(t), 0})
}
