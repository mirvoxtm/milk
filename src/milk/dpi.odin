// Xft.dpi for the applications. milk draws at 96 DPI (font sizes are points
// at 96 DPI, opened as pixel sizes), and so do GTK and Qt 5 apps unless told
// otherwise. Toolkits that find no Xft.dpi in the X resources work a scale out
// of the monitor's physical size instead: winit and egui apps (Alacritty,
// FilmCraft), ONLYOFFICE... A 1920x1080 laptop panel 309 mm wide comes out at
// ~158 DPI, and those apps open 1.5 to 1.7 times too big next to the rest.
// Desktops publish Xft.dpi for this, so milk writes it into the root window's
// RESOURCE_MANAGER (where xrdb keeps the resources) before it starts any
// program: 96 × displays.scale (Settings → Tela → Escala). At scale 1 a DPI
// already there is kept: ~/.Xresources (contrib/milk-session merges it before
// milk starts) can ask for 144 or 192 on a HiDPI screen. Like xrdb's, the
// resource lasts as long as the X server, so a restarted milk finds it.
package milk

import "core:fmt"
import "core:log"
import "core:math"
import "core:strconv"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "../tx"

XFT_DPI :: 96

// The DPI milk wrote last (0: none yet), to tell it from one set by the user,
// and the one the resources hold now (milk's or the user's; XSETTINGS follows it).
@(private="file") g_published_dpi: int
@(private="file") g_effective_dpi: int

// The DPI for a UI scale (1.25 → 120).
scale_dpi :: proc(scale: f64) -> int {
	return int(math.round(XFT_DPI * max(scale, 1)))
}

// Write Xft.dpi for `scale` into the resources (see above). Called at start
// and on every reload.
xft_dpi_apply :: proc(c: ^tx.Connection, scale: f64) {
	root := xlib.RootWindow(c.dpy, 0) // Xlib reads the resources of screen 0's root
	text := ""
	if p, ok := tx.get_property(c, root, "RESOURCE_MANAGER", tx.ATOM_STRING); ok {
		defer tx.property_free(p)
		if p.format == 8 { text = strings.clone(string(([^]u8)(p.data)[:p.count]), context.temp_allocator) }
	}
	want := scale_dpi(scale)
	current, has := resources_dpi(text)
	if want == XFT_DPI && has && current != g_published_dpi {
		log.debugf("Xft.dpi %d is set (not by milk); keeping it", current)
		g_effective_dpi = current
		return
	}
	g_effective_dpi = want
	if has && current == want {
		g_published_dpi = want
		return
	}
	b := strings.builder_make(context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if is_dpi_line(line) || line == "" { continue }
		fmt.sbprintf(&b, "%s\n", line)
	}
	fmt.sbprintf(&b, "Xft.dpi:\t%d\n", want)
	out := strings.to_string(b)
	xlib.ChangeProperty(c.dpy, root, tx.atom(c, "RESOURCE_MANAGER"), tx.ATOM_STRING, 8, xlib.PropModeReplace, raw_data(out), i32(len(out)))
	tx.flush(c)
	g_published_dpi = want
	log.infof("Xft.dpi: %d published, so apps draw at scale %.2f (apps started from now on)", want, f64(want) / XFT_DPI)
}

// The DPI the resources set for Xft (Xft.dpi, or a looser binding like
// Xft*dpi or *dpi that an Xft.dpi would override), if any.
resources_dpi :: proc(text: string) -> (dpi: int, found: bool) {
	text := text
	for line in strings.split_lines_iterator(&text) {
		if !is_dpi_line(line) { continue }
		colon := strings.index_byte(line, ':')
		if v, ok := strconv.parse_f64(strings.trim_space(line[colon + 1:])); ok {
			dpi, found = int(math.round(v)), true
		}
	}
	return
}

@(private="file")
is_dpi_line :: proc(line: string) -> bool {
	colon := strings.index_byte(line, ':')
	if colon < 0 { return false }
	switch strings.trim_space(line[:colon]) {
	case "Xft.dpi", "Xft*dpi", "*dpi", "*.dpi": return true
	}
	return false
}

// For milk's XSETTINGS (apptheme.odin), from the DPI in the resources (after
// xft_dpi_apply): GTK follows these live. Whole scales (2, 3) scale GTK's
// windows too; the rest scales the text.
xsettings_scale :: proc() -> (window_scale: i32, dpi_1024, unscaled_dpi_1024: i32) {
	dpi := g_effective_dpi > 0 ? g_effective_dpi : XFT_DPI
	scale := f64(dpi) / XFT_DPI
	window_scale = scale >= 2 ? i32(math.floor(scale + 0.001)) : 1 // 2.5: windows ×2, text ×1.25
	return window_scale, i32(dpi * 1024), i32(dpi * 1024 / int(window_scale))
}
