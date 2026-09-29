// Package desktop: the workspace ("area") daemon of milk for Linux/X11.
//
// It ports windows/src/Temenos.ps1 (with DesktopEvents.ps1 and Indicator.ps1):
// the active area is read from the EWMH root property _NET_CURRENT_DESKTOP
// (PropertyNotify, never polled) and every change applies, in order, the
// area's wallpaper (validated, cached, set with feh), its shortcuts (drawn as
// desktop icons, or copied into the XDG Desktop folder like on Windows) and
// the "AREA N - Name" indicator.
//
// The package owns no event loop: the caller selects ROOT_EVENT_MASK on the
// root window, feeds every X event to handle_event, calls tick every loop
// iteration and sleeps at most next_timeout seconds.
package desktop

import "base:runtime"
import "core:log"
import "core:strings"
import "core:sys/posix"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

// Deferral used to coalesce bursts of X events into one action.
@(private)
COALESCE_DELAY :: 0.25

// Our own feh call changes _XROOTPMAP_ID; property changes this close to it are ours.
@(private)
OWN_WALLPAPER_WINDOW :: 1.0

Daemon :: struct {
	c:              ^tx.Connection,
	cfg:            ^config.Config, // owned by the caller; replaced by reload
	allocator:      runtime.Allocator,
	runtime_root:   string,
	area:           int,  // active area (1-based), 0 = unknown
	started:        bool,
	waiting:        bool, // _NET_CURRENT_DESKTOP is not published (yet)
	warned_missing: bool,
	atoms:          Atoms,
	wallpaper:      Wallpaper_State,
	icons:          Icon_Loader,
	layer:          Layer,
	indicator:      Indicator,
	children:       [dynamic]posix.pid_t, // launched applications not reaped yet
	// Deferred work (tx.now() deadlines, 0 = nothing pending).
	screen_change_at: f64, // root ConfigureNotify: re-apply wallpaper + relayout
	area_check_at:    f64, // a bar/dock appeared, moved or vanished
	bg_refresh_at:    f64, // the wallpaper pixmap was replaced by someone else
	quiet:            bool, // re-applying after a reload: no indicator
}

@(private)
Atoms :: struct {
	current_desktop: xlib.Atom,
	workarea:        xlib.Atom,
	active_window:   xlib.Atom,
	xrootpmap:       xlib.Atom,
	esetroot:        xlib.Atom,
	window_type:     xlib.Atom,
	type_dock:       xlib.Atom,
}

// Create the runtime directories and the components; no X windows yet.
create :: proc(c: ^tx.Connection, cfg: ^config.Config, runtime_root: string) -> (^Daemon, bool) {
	if c == nil || cfg == nil || runtime_root == "" { return nil, false }
	d := new(Daemon)
	d.allocator = context.allocator
	d.c = c
	d.cfg = cfg
	d.runtime_root = strings.clone(runtime_root)
	if !ensure_runtime_dirs(d) {
		log.errorf("Could not create the runtime directory %s", runtime_root)
		delete(d.runtime_root)
		free(d)
		return nil, false
	}
	d.atoms = Atoms{
		current_desktop = tx.atom(c, "_NET_CURRENT_DESKTOP"),
		workarea        = tx.atom(c, "_NET_WORKAREA"),
		active_window   = tx.atom(c, "_NET_ACTIVE_WINDOW"),
		xrootpmap       = tx.atom(c, "_XROOTPMAP_ID"),
		esetroot        = tx.atom(c, "ESETROOT_PMAP_ID"),
		window_type     = tx.atom(c, "_NET_WM_WINDOW_TYPE"),
		type_dock       = tx.atom(c, "_NET_WM_WINDOW_TYPE_DOCK"),
	}
	d.children = make([dynamic]posix.pid_t)
	icons_init(&d.icons, cfg)
	layer_init(d)
	indicator_init(d)
	return d, true
}

// Unmap and destroy our windows and free everything. Folder-mode copies and
// launched applications are left alone (like the Windows version).
destroy :: proc(d: ^Daemon) {
	if d == nil { return }
	context.allocator = d.allocator
	layer_destroy(d)
	indicator_destroy(d)
	icons_destroy(&d.icons)
	reap_children(d)
	delete(d.children)
	delete(d.runtime_root)
	tx.flush(d.c)
	free(d)
}

// Apply the active area now, or wait for the window manager to publish it.
start :: proc(d: ^Daemon) {
	context.allocator = d.allocator
	d.started = true
	index, ok := current_desktop_index(d.c)
	if !ok {
		d.waiting = true
		if !d.warned_missing {
			d.warned_missing = true
			log.warn("the window manager does not publish _NET_CURRENT_DESKTOP; dwm needs the ewmhtags patch")
		}
		return
	}
	switch_area(d, index)
}

// Timers: indicator hide, deferred relayouts/refreshes and child reaping.
tick :: proc(d: ^Daemon, now: f64) {
	context.allocator = d.allocator
	reap_children(d)
	indicator_tick(d, now)
	if d.screen_change_at > 0 && now >= d.screen_change_at {
		d.screen_change_at = 0
		d.area_check_at = 0
		on_screen_change(d)
	}
	if d.area_check_at > 0 && now >= d.area_check_at {
		d.area_check_at = 0
		layer_check_area(d)
	}
	if d.bg_refresh_at > 0 && now >= d.bg_refresh_at {
		d.bg_refresh_at = 0
		log.debug("The wallpaper was changed outside milk; refreshing the icon backgrounds")
		layer_refresh_backgrounds(d)
		indicator_refresh(d)
	}
	tx.flush(d.c)
}

// Seconds until tick is needed; -1 when idle. Children are reaped on the
// wake-up caused by SIGCHLD, so they need no timer.
next_timeout :: proc(d: ^Daemon, now: f64) -> f64 {
	best := -1.0
	consider :: proc(best: ^f64, deadline, now: f64) {
		if deadline <= 0 { return }
		t := max(deadline - now, 0)
		if best^ < 0 || t < best^ { best^ = t }
	}
	if d.indicator.visible { consider(&best, d.indicator.deadline, now) }
	consider(&best, d.screen_change_at, now)
	consider(&best, d.area_check_at, now)
	consider(&best, d.bg_refresh_at, now)
	return best
}

// Switch to a new configuration. The caller owns `cfg`; the previous config
// is only used during this call (it is destroyed by the caller afterwards).
reload :: proc(d: ^Daemon, cfg: ^config.Config) {
	context.allocator = d.allocator
	if cfg == nil { return }
	old := d.cfg
	if old.linux.shortcuts.mode == "folder" {
		// Take the copies made under the old configuration back out of the
		// Desktop folder (its folders may have been renamed or removed); the
		// new configuration copies its own set below if it is still in folder mode.
		folder_remove_managed(d, old)
	}
	layer_clear(d)
	indicator_hide(d)
	d.cfg = cfg
	ensure_runtime_dirs(d)
	icons_destroy(&d.icons)
	icons_init(&d.icons, cfg)
	layer_reconfigure(d)
	indicator_reconfigure(d)
	if !d.started { return }
	if d.area > 0 {
		d.quiet = true
		switch_area(d, d.area)
		d.quiet = false
	} else {
		start(d)
	}
}

// Every X window the daemon owns (icon cells and the indicator).
window_ids :: proc(d: ^Daemon, allocator := context.temp_allocator) -> []xlib.Window {
	out := make([dynamic]xlib.Window, 0, len(d.layer.cells) + 1, allocator)
	for &cell in d.layer.cells { append(&out, cell.window) }
	if d.indicator.window != 0 { append(&out, d.indicator.window) }
	return out[:]
}

// The active area (1-based), 0 when unknown.
current_area :: proc(d: ^Daemon) -> int {
	return d.area
}

// ---------------------------------------------------------------------------
// Applying an area (Set-DesktopState + Show-WorkspaceIndicator)
// ---------------------------------------------------------------------------

// Apply everything for area `index`: wallpaper, then shortcuts, then the indicator.
@(private)
switch_area :: proc(d: ^Daemon, index: int) {
	started := tx.now()
	d.area = index
	d.waiting = false
	ws, known := config.workspace(d.cfg, index)
	if known && ws.name != "" {
		log.infof("Area %d - %s", index, ws.name)
	} else {
		log.infof("Area %d%s", index, known ? "" : " (not in milk.json)")
	}
	// Hide a visible indicator first so that windows under it repaint before
	// the new one copies the screen.
	indicator_hide(d)
	tx.flush(d.c)

	apply_wallpaper(d, index)
	apply_shortcuts(d, index)
	if d.cfg.linux.indicator.enabled && !d.quiet {
		indicator_show(d, index, ws.name if known else "")
	}
	tx.flush(d.c)
	log.debugf("Area %d applied in %.0f ms", index, (tx.now() - started) * 1000)
}

@(private)
apply_shortcuts :: proc(d: ^Daemon, index: int) {
	common := join_path({d.runtime_root, d.cfg.paths.common})
	area_dir := ""
	if ws, known := config.workspace(d.cfg, index); known {
		area_dir = join_path({d.runtime_root, ws.folder})
		ensure_dir(area_dir)
	}
	switch d.cfg.linux.shortcuts.mode {
	case "layer":
		entries := collect_entries(common, area_dir, d.allocator)
		layer_show(d, &entries)
	case "folder":
		layer_clear(d)
		folder_sync(d, common, area_dir)
	case:
		layer_clear(d)
	}
}

// The screen size changed (RandR): the old wallpaper pixmap has the old size,
// so re-apply the wallpaper, then lay the icons out again.
@(private)
on_screen_change :: proc(d: ^Daemon) {
	if d.area <= 0 { return }
	log.debug("Screen geometry changed; re-applying the wallpaper and the icon layout")
	apply_wallpaper(d, d.area)
	if d.cfg.linux.shortcuts.mode == "layer" { layer_relayout(d) }
	indicator_refresh(d)
}

@(private)
ensure_runtime_dirs :: proc(d: ^Daemon) -> bool {
	if !ensure_dir(d.runtime_root) { return false }
	ensure_dir(join_path({d.runtime_root, d.cfg.paths.common}))
	ensure_dir(join_path({d.runtime_root, d.cfg.paths.wallpapers}))
	ensure_dir(join_path({d.runtime_root, d.cfg.paths.wallpaper_cache}))
	for _, ws in d.cfg.workspaces {
		ensure_dir(join_path({d.runtime_root, ws.folder}))
	}
	return true
}

// Reap launched applications that have exited (never blocks).
@(private)
reap_children :: proc(d: ^Daemon) {
	for i := len(d.children) - 1; i >= 0; i -= 1 {
		status: i32
		r := posix.waitpid(d.children[i], &status, {.NOHANG})
		if r == 0 { continue } // still running
		if r > 0 {
			if posix.WIFEXITED(status) && posix.WEXITSTATUS(status) != 0 {
				log.debugf("Launched process %d exited with status %d", r, posix.WEXITSTATUS(status))
			}
		} else if posix.errno() == .EINTR {
			continue
		}
		// Exited, or not our child any more (ECHILD): forget it.
		unordered_remove(&d.children, i)
	}
}
