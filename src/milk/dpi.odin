// Xft.dpi for the applications. milk draws at 96 DPI (font sizes are points
// at 96 DPI, opened as pixel sizes), and so do GTK and Qt 5 apps unless told
// otherwise. Toolkits that find no Xft.dpi in the X resources work a scale out
// of the monitor's physical size instead: winit and egui apps (Alacritty,
// FilmCraft), ONLYOFFICE... A 1920x1080 laptop panel 309 mm wide comes out at
// ~158 DPI, and those apps open 1.5 to 1.7 times too big next to the rest.
// Desktops publish Xft.dpi for this, so when nothing set a DPI, milk appends
// "Xft.dpi: 96" to the root window's RESOURCE_MANAGER (where xrdb keeps the
// resources) before it starts any program. A DPI already there is kept:
// ~/.Xresources (contrib/milk-session merges it before milk starts) can ask
// for 144 or 192 on a HiDPI screen. Like xrdb's, the resource lasts as long
// as the X server, so a restarted milk finds it and leaves it alone.
package milk

import "core:log"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "../tx"

XFT_DPI :: "96"

// Publish Xft.dpi unless the resources already set a DPI.
xft_dpi_publish :: proc(c: ^tx.Connection) {
	root := xlib.RootWindow(c.dpy, 0) // Xlib reads the resources of screen 0's root
	text := ""
	if p, ok := tx.get_property(c, root, "RESOURCE_MANAGER", tx.ATOM_STRING); ok {
		defer tx.property_free(p)
		if p.format == 8 { text = strings.clone(string(([^]u8)(p.data)[:p.count]), context.temp_allocator) }
	}
	if resources_set_dpi(text) {
		log.debug("Xft.dpi is already set; keeping it")
		return
	}
	line := "Xft.dpi:\t" + XFT_DPI + "\n"
	if text != "" && !strings.has_suffix(text, "\n") { line = strings.concatenate({"\n", line}, context.temp_allocator) }
	xlib.ChangeProperty(c.dpy, root, tx.atom(c, "RESOURCE_MANAGER"), tx.ATOM_STRING, 8, xlib.PropModeAppend, raw_data(line), i32(len(line)))
	tx.flush(c)
	log.infof("Xft.dpi: %s published, so apps draw at milk's scale (set Xft.dpi in ~/.Xresources for another)", XFT_DPI)
}

// Whether the resources set a DPI for Xft: Xft.dpi, or a looser binding
// (Xft*dpi, *dpi) that an Xft.dpi added after it would override.
resources_set_dpi :: proc(text: string) -> bool {
	text := text
	for line in strings.split_lines_iterator(&text) {
		colon := strings.index_byte(line, ':')
		if colon < 0 { continue }
		switch strings.trim_space(line[:colon]) {
		case "Xft.dpi", "Xft*dpi", "*dpi", "*.dpi": return true
		}
	}
	return false
}
