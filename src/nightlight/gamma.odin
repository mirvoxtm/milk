// The gamma ramps of every CRTC (RandR 1.2). milk keeps a copy of each
// CRTC's ramps as it found them (its "originals", which keep any colour
// calibration) and shows them multiplied by the night light's white point and
// the dim factor; neutral settings put the originals back exactly.
//
// The originals are also stored on the root window (_MILK_GAMMA_SAVED) while
// the screen is altered, with the temperature shown: a property lives as long
// as the X server, like the ramps, so the next instance (after a crash, or a
// restart that kept the ramps: destroy(keep_ramps = true)) takes over the
// screen as it is, fading from there, instead of taking warm ramps for the
// originals or flashing back to neutral.
//
// _MILK_GAMMA_SAVED (CARDINAL/32): 1, CRTC count, kelvin shown, then per CRTC:
// id, ramp size, red[size], green[size], blue[size].
package nightlight

import "core:log"
import "core:math"
import xlib "vendor:x11/xlib"
import tx "../tx"

SAVED_PROPERTY :: "_MILK_GAMMA_SAVED"
@(private) SAVED_VERSION :: 1

// <X11/extensions/randr.h>
@(private) RR_SCREEN_CHANGE_NOTIFY_MASK :: 1 << 0
@(private) RR_CRTC_CHANGE_NOTIFY_MASK   :: 1 << 1
@(private) RR_OUTPUT_CHANGE_NOTIFY_MASK :: 1 << 2
@(private) RR_SCREEN_CHANGE_NOTIFY      :: 0 // event_base + 0
@(private) RR_NOTIFY                    :: 1 // event_base + 1 (CRTC, output, property changes)

@(private)
XRRCrtcGamma :: struct {
	size:  i32,
	red:   [^]u16,
	green: [^]u16,
	blue:  [^]u16,
}

foreign import xrandr_gamma "system:Xrandr"
@(default_calling_convention="c", private)
foreign xrandr_gamma {
	XRRQueryExtension            :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	XRRQueryVersion              :: proc(dpy: ^xlib.Display, major, minor: ^i32) -> xlib.Status ---
	XRRSelectInput               :: proc(dpy: ^xlib.Display, window: xlib.Window, mask: i32) ---
	XRRUpdateConfiguration       :: proc(event: ^xlib.XEvent) -> i32 ---
	XRRGetScreenResourcesCurrent :: proc(dpy: ^xlib.Display, window: xlib.Window) -> ^xlib.XRRScreenResources ---
	XRRGetCrtcGammaSize          :: proc(dpy: ^xlib.Display, crtc: xlib.RRCrtc) -> i32 ---
	XRRGetCrtcGamma              :: proc(dpy: ^xlib.Display, crtc: xlib.RRCrtc) -> ^XRRCrtcGamma ---
	XRRAllocGamma                :: proc(size: i32) -> ^XRRCrtcGamma ---
	XRRSetCrtcGamma              :: proc(dpy: ^xlib.Display, crtc: xlib.RRCrtc, gamma: ^XRRCrtcGamma) ---
	XRRFreeGamma                 :: proc(gamma: ^XRRCrtcGamma) ---
}

@(private)
Crtc :: struct {
	id:    xlib.RRCrtc,
	size:  int,
	orig:  []u16, // red, green, blue (size each); empty until saved
	plain: bool,  // the originals are unusable (not rising, nearly black): multiply a linear ramp instead
	found: bool,  // seen by the last scan
}

@(private)
Gamma :: struct {
	ok:         bool, // RandR 1.2 or newer
	event_base: i32,
	crtcs:      [dynamic]Crtc,
	modified:   bool,   // the ramps on screen are not the originals
	applied:    [3]f64, // multipliers on screen while modified
	stored_k:   f64,    // the temperature _MILK_GAMMA_SAVED says is shown
}

// Find the CRTCs, listen to RandR changes and take over ramps a previous
// instance left behind.
@(private)
gamma_init :: proc(n: ^Night_Light) {
	g := &n.gamma
	dpy := n.c.dpy
	err_base: i32
	if !XRRQueryExtension(dpy, &g.event_base, &err_base) {
		log.warn("Night light: the X server has no RandR extension; the screen colours cannot change")
		return
	}
	major, minor: i32
	if XRRQueryVersion(dpy, &major, &minor) == xlib.Status(0) || major < 1 || (major == 1 && minor < 2) {
		log.warnf("Night light: RandR %d.%d is too old for gamma ramps (1.2 needed)", major, minor)
		return
	}
	g.ok = true
	XRRSelectInput(dpy, n.c.root, RR_SCREEN_CHANGE_NOTIFY_MASK | RR_CRTC_CHANGE_NOTIFY_MASK | RR_OUTPUT_CHANGE_NOTIFY_MASK)
	gamma_scan(n)
	gamma_adopt(n)
}

// `keep`: leave the ramps on screen and their originals on the root window
// for the next instance (a restart in place).
@(private)
gamma_destroy :: proc(n: ^Night_Light, keep := false) {
	if keep && n.gamma.modified {
		store_originals(n)
		tx.flush(n.c)
	} else {
		gamma_restore(n)
	}
	for &crtc in n.gamma.crtcs { delete(crtc.orig) }
	delete(n.gamma.crtcs)
	n.gamma = {}
}

// A RandR event (screen size, CRTC or output change)?
@(private)
is_randr_event :: proc(n: ^Night_Light, ev: ^xlib.XEvent) -> bool {
	if !n.gamma.ok { return false }
	t := i32(ev.type)
	if t == n.gamma.event_base + RR_SCREEN_CHANGE_NOTIFY {
		XRRUpdateConfiguration(ev)
		return true
	}
	return t == n.gamma.event_base + RR_NOTIFY
}

// Re-read the CRTC list: new CRTCs are added (their originals are saved
// when the ramps change), vanished ones forgotten.
@(private)
gamma_scan :: proc(n: ^Night_Light) {
	g := &n.gamma
	if !g.ok { return }
	dpy := n.c.dpy
	res := XRRGetScreenResourcesCurrent(dpy, n.c.root)
	if res == nil { return }
	defer xlib.XRRFreeScreenResources(res)
	for &crtc in g.crtcs { crtc.found = false }
	for i in 0 ..< int(res.ncrtc) {
		id := res.crtcs[i]
		size := int(XRRGetCrtcGammaSize(dpy, id))
		if size < 2 { continue }
		known := false
		for &crtc in g.crtcs {
			if crtc.id != id { continue }
			known = true
			crtc.found = true
			if crtc.size != size {
				// A new ramp size (another mode): the old originals do not fit.
				delete(crtc.orig)
				crtc.orig = nil
				crtc.size = size
			}
		}
		if !known { append(&g.crtcs, Crtc{id = id, size = size, found = true}) }
	}
	for i := len(g.crtcs) - 1; i >= 0; i -= 1 {
		if g.crtcs[i].found { continue }
		delete(g.crtcs[i].orig)
		ordered_remove(&g.crtcs, i)
	}
}

// Ramps an earlier instance left on screen (it crashed, was killed, or
// restarted in place): their originals become ours and the screen is taken
// over at the temperature it shows; the next tick fades from there to what
// the configuration asks for (and back to the originals when that is neutral).
@(private)
gamma_adopt :: proc(n: ^Night_Light) {
	c := n.c
	g := &n.gamma
	values := tx.get_cardinals(c, c.root, SAVED_PROPERTY)
	if len(values) == 0 { return }
	if values[0] != SAVED_VERSION || len(values) < 3 {
		xlib.DeleteProperty(c.dpy, c.root, tx.atom(c, SAVED_PROPERTY))
		return
	}
	count := int(values[1])
	kelvin := clamp(f64(values[2]), 1000, NEUTRAL_K)
	pos := 3
	adopted := 0
	for _ in 0 ..< count {
		if pos + 2 > len(values) { break }
		id := xlib.RRCrtc(values[pos])
		size := int(values[pos + 1])
		pos += 2
		if size < 2 || pos + 3 * size > len(values) { break }
		for &crtc in g.crtcs {
			if crtc.id != id || crtc.size != size || len(crtc.orig) > 0 { continue }
			crtc.orig = make([]u16, 3 * size)
			for k in 0 ..< 3 * size { crtc.orig[k] = u16(values[pos + k]) }
			crtc.plain = !ramp_usable(crtc.orig, size)
			adopted += 1
		}
		pos += 3 * size
	}
	if adopted == 0 {
		xlib.DeleteProperty(c.dpy, c.root, tx.atom(c, SAVED_PROPERTY))
		return
	}
	g.modified = true
	g.applied = {-1, -1, -1} // unknown: the next apply writes the ramps
	g.stored_k = kelvin
	n.shown, n.fade_from, n.fade_to = kelvin, kelvin, kelvin
	log.infof("Night light: took over the screen colours a previous milk left (%d CRTC(s), %.0f K)", adopted, kelvin)
}

@(private)
set_ramp :: proc(n: ^Night_Light, id: xlib.RRCrtc, ramp: []u16) {
	size := len(ramp) / 3
	gm := XRRAllocGamma(i32(size))
	if gm == nil { return }
	defer XRRFreeGamma(gm)
	copy(gm.red[:size], ramp[:size])
	copy(gm.green[:size], ramp[size:2 * size])
	copy(gm.blue[:size], ramp[2 * size:])
	XRRSetCrtcGamma(n.c.dpy, id, gm)
}

@(private)
read_ramp :: proc(n: ^Night_Light, id: xlib.RRCrtc, size: int) -> []u16 {
	gm := XRRGetCrtcGamma(n.c.dpy, id)
	if gm == nil { return nil }
	defer XRRFreeGamma(gm)
	if int(gm.size) != size { return nil }
	out := make([]u16, 3 * size)
	copy(out[:size], gm.red[:size])
	copy(out[size:2 * size], gm.green[:size])
	copy(out[2 * size:], gm.blue[:size])
	return out
}

// Whether saved ramps can be multiplied: every channel rises and reaches a
// visible level. Servers that never set the ramps (some Xwayland and virtual
// drivers) report zeros or junk; restoring gives them back as found, but the
// night light then works from a plain linear ramp.
@(private)
ramp_usable :: proc(ramp: []u16, size: int) -> bool {
	for ch in 0 ..< 3 {
		r := ramp[ch * size:(ch + 1) * size]
		if r[size - 1] < 4096 { return false }
		for i in 1 ..< size {
			if r[i] < r[i - 1] { return false }
		}
	}
	return true
}

// Publish the originals and the temperature shown on the root window (see
// the package comment).
@(private)
store_originals :: proc(n: ^Night_Light) {
	c := n.c
	values := make([dynamic]uint, context.temp_allocator)
	append(&values, SAVED_VERSION, 0, uint(math.round(clamp(n.shown, 1000, NEUTRAL_K))))
	n.gamma.stored_k = n.shown
	count := 0
	for crtc in n.gamma.crtcs {
		if len(crtc.orig) == 0 { continue }
		append(&values, uint(crtc.id), uint(crtc.size))
		for v in crtc.orig { append(&values, uint(v)) }
		count += 1
	}
	values[1] = uint(count)
	tx.set_cardinals(c, c.root, SAVED_PROPERTY, values[:])
}

// Show the originals multiplied by `mult` (red, green, blue). With `force`
// the ramps are written even if `mult` is what is already shown (after a
// mode change the driver may have reset them).
@(private)
gamma_apply :: proc(n: ^Night_Light, mult: [3]f64, force := false) {
	g := &n.gamma
	if !g.ok { return }
	neutral := abs(mult[0] - 1) < 1e-4 && abs(mult[1] - 1) < 1e-4 && abs(mult[2] - 1) < 1e-4
	if neutral {
		gamma_restore(n)
		return
	}
	if g.modified && !force && abs(mult[0] - g.applied[0]) < 1e-5 && abs(mult[1] - g.applied[1]) < 1e-5 && abs(mult[2] - g.applied[2]) < 1e-5 { return }
	saved_new := false
	for &crtc in g.crtcs {
		if len(crtc.orig) == 0 {
			crtc.orig = read_ramp(n, crtc.id, crtc.size)
			if len(crtc.orig) == 0 { continue }
			crtc.plain = !ramp_usable(crtc.orig, crtc.size)
			if crtc.plain { log.debugf("Night light: CRTC %d has no usable gamma ramp; using a linear one", crtc.id) }
			saved_new = true
		}
		size := crtc.size
		ramp := make([]u16, 3 * size, context.temp_allocator)
		for ch in 0 ..< 3 {
			m := clamp(mult[ch], 0, 1)
			for i in 0 ..< size {
				base := crtc.plain ? f64(i) * 65535 / f64(size - 1) : f64(crtc.orig[ch * size + i])
				ramp[ch * size + i] = u16(clamp(math.round(base * m), 0, 65535))
			}
		}
		set_ramp(n, crtc.id, ramp)
	}
	if saved_new { store_originals(n) }
	g.modified = true
	g.applied = mult
	tx.flush(n.c)
}

// Put the originals back and forget them (the next change saves fresh ones:
// a calibration loaded meanwhile is kept).
@(private)
gamma_restore :: proc(n: ^Night_Light) {
	g := &n.gamma
	if !g.ok || !g.modified { return }
	for &crtc in g.crtcs {
		if len(crtc.orig) == crtc.size * 3 { set_ramp(n, crtc.id, crtc.orig) }
		delete(crtc.orig)
		crtc.orig = nil
	}
	xlib.DeleteProperty(n.c.dpy, n.c.root, tx.atom(n.c, SAVED_PROPERTY))
	g.modified = false
	g.applied = {1, 1, 1}
	tx.flush(n.c)
}
