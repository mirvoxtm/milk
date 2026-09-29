// lactase, milk's compositor: where it is and whether it runs. It lives next
// to the milk folder (../lactase/lactase, like Spoil) or on $PATH, and the
// running instance owns the _NET_WM_CM_Sn selection.
package desktop

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "../tx"

// The lactase launcher, or "" when lactase is not installed.
lactase_path :: proc(allocator := context.temp_allocator) -> (string, bool) {
	if dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		// bin/milk → ../../lactase/lactase
		path, _ := filepath.join({dir, "..", "..", "lactase", "lactase"}, context.temp_allocator)
		clean, _ := filepath.clean(path, context.temp_allocator)
		if is_executable_file(clean) { return strings.clone(clean, allocator), true }
	}
	return find_executable("lactase", allocator)
}

Compositor_Status :: struct {
	running: bool,   // some compositor owns the selection
	lactase: bool,   // and it is lactase
	backend: string, // lactase's renderer ("glx", "xrender")
	name:    string, // another compositor's name
}

compositor_status :: proc(c: ^tx.Connection, allocator := context.temp_allocator) -> Compositor_Status {
	owner := xlib.GetSelectionOwner(c.dpy, tx.atom(c, fmt.tprintf("_NET_WM_CM_S%d", c.screen)))
	if owner == 0 { return {} }
	st := Compositor_Status{running = true}
	_, class := tx.window_class(c, owner, allocator)
	st.lactase = class == "Lactase"
	if st.lactase {
		st.backend = tx.get_utf8_string(c, owner, "_LACTASE_BACKEND", allocator)
	} else {
		st.name = tx.window_title(c, owner, allocator)
		if st.name == "" { st.name = class }
	}
	return st
}

// Run `lactase <command>` detached (start, stop, settings); the pid must be reaped.
lactase_run :: proc(command: string) -> (pid: int, ok: bool) {
	path, found := lactase_path()
	if !found { return 0, false }
	p, sok := spawn_detached({path, command}, "")
	return int(p), sok
}
