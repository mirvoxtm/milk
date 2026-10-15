package display

import "base:runtime"
import "core:fmt"
import "core:log"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

@(private="file")
Plan :: struct {
	output:   ^Output,
	mode:     Mode,
	x, y:     i32,
	w, h:     i32, // on screen
	rotation: u16,
	crtc:     xlib.RRCrtc,
	kept:     bool, // its CRTC already shows exactly this
}

// X errors while applying (a temporary handler counts them).
@(private="file") apply_errors: int

@(private="file")
count_error :: proc "c" (dpy: ^xlib.Display, ev: ^xlib.XErrorEvent) -> i32 {
	context = runtime.default_context()
	apply_errors += 1
	log.warnf("Display: X error %d (request %d.%d)", ev.error_code, ev.request_code, ev.minor_code)
	return 0
}

// Show `layout` on the monitors of `s` (read just before): each entry on its
// output, at its mode (the closest rate; the preferred mode when the size is
// gone), position, rotation; the primary set. Connected monitors the layout
// does not mention and outputs still on after their monitor was unplugged are
// turned off. Positions are moved so the layout starts at 0, 0. On failure
// the screen goes back to what `s` describes; `reason` says why (for the log).
apply :: proc(c: ^tx.Connection, s: ^State, layout_in: []config.Display_Output) -> (ok: bool, reason: string) {
	layout := clone_layout(layout_in, context.temp_allocator)
	normalize(layout)
	plans := make([dynamic]Plan, 0, len(layout), context.temp_allocator)
	primary: xlib.RROutput
	for e in layout {
		if !e.enabled { continue }
		o := find_output(s, e)
		if o == nil { continue } // not connected now
		m, found := pick_mode(o, e.w, e.h, e.rate)
		if !found { m, found = preferred_mode(o) }
		if !found { return false, fmt.tprintf("%s has no modes", o.name) }
		rot := rotation_from_name(e.rotation)
		w, h := rotated(m.w, m.h, rot)
		append(&plans, Plan{output = o, mode = m, x = e.x, y = e.y, w = w, h = h, rotation = rotation_bits(rot)})
		if e.primary { primary = o.id }
	}
	if len(plans) == 0 { return false, "no monitor would be on" }

	sw, sh: i32
	for p in plans { sw, sh = max(sw, p.x + p.w), max(sh, p.y + p.h) }
	if (s.max_w > 0 && sw > s.max_w) || (s.max_h > 0 && sh > s.max_h) {
		return false, fmt.tprintf("%dx%d is larger than this screen can be (%dx%d)", sw, sh, s.max_w, s.max_h)
	}
	sw, sh = max(sw, s.min_w), max(sh, s.min_h)

	// CRTCs: each output keeps its own when it can, else takes a free one it can use.
	used := make(map[xlib.RRCrtc]bool, context.temp_allocator)
	for &p in plans {
		if p.output.crtc != 0 && !used[p.output.crtc] {
			p.crtc = p.output.crtc
			used[p.crtc] = true
		}
	}
	for &p in plans {
		if p.crtc != 0 { continue }
		for cr in p.output.crtcs {
			if used[cr] { continue }
			p.crtc = cr
			used[cr] = true
			break
		}
		if p.crtc == 0 { return false, fmt.tprintf("no CRTC is left for %s", p.output.name) }
	}
	for &p in plans {
		cr := find_crtc(s, p.crtc)
		if cr != nil && cr.rotations != 0 && cr.rotations & p.rotation == 0 {
			return false, fmt.tprintf("%s cannot be rotated that way", p.output.name)
		}
		p.kept = cr != nil && cr.mode == p.mode.id && cr.x == p.x && cr.y == p.y && cr.rotation & 0xf == p.rotation &&
		         len(cr.outputs) == 1 && cr.outputs[0] == p.output.id && p.x + p.w <= sw && p.y + p.h <= sh
	}

	res := XRRGetScreenResourcesCurrent(c.dpy, c.root)
	if res == nil { return false, "the screen resources cannot be read" }
	defer xlib.XRRFreeScreenResources(res)
	apply_errors = 0
	old_handler := xlib.SetErrorHandler(count_error)
	xlib.GrabServer(c.dpy)
	failed := ""
	// 1. Every CRTC that does not stay exactly as it is goes off first: the
	//    screen can then take its new size whatever the old layout was.
	for &cr in s.crtcs {
		if cr.mode == 0 { continue }
		keep := false
		for p in plans { if p.crtc == cr.id && p.kept { keep = true } }
		if keep { continue }
		if XRRSetCrtcConfig(c.dpy, res, cr.id, xlib.CurrentTime, 0, 0, 0, RR_ROTATE_0, nil, 0) != RR_SET_CONFIG_SUCCESS {
			failed = fmt.tprintf("cannot turn off CRTC 0x%x", cr.id)
			break
		}
	}
	// 2. The screen size (millimetres for 96 DPI, the DPI milk draws at).
	if failed == "" && (sw != s.screen_w || sh != s.screen_h) {
		XRRSetScreenSize(c.dpy, c.root, sw, sh, mm_at_96(sw), mm_at_96(sh))
	}
	// 3. The monitors.
	if failed == "" {
		for &p in plans {
			if p.kept { continue }
			outputs := [1]xlib.RROutput{p.output.id}
			if XRRSetCrtcConfig(c.dpy, res, p.crtc, xlib.CurrentTime, p.x, p.y, p.mode.id, p.rotation, &outputs[0], 1) != RR_SET_CONFIG_SUCCESS {
				failed = fmt.tprintf("%s refused %dx%d at %.2f Hz", p.output.name, p.mode.w, p.mode.h, p.mode.rate)
				break
			}
		}
	}
	// 4. The primary.
	if failed == "" { XRRSetOutputPrimary(c.dpy, c.root, primary) }
	xlib.Sync(c.dpy, false)
	if failed == "" && apply_errors > 0 { failed = "the X server refused the layout" }
	if failed != "" { restore(c, s) }
	xlib.UngrabServer(c.dpy)
	xlib.Sync(c.dpy, false)
	xlib.SetErrorHandler(old_handler)
	if failed != "" { return false, failed }
	for p in plans {
		log.infof("Display: %s %dx%d at %.2f Hz, +%d+%d%s", p.output.name, p.mode.w, p.mode.h, p.mode.rate, p.x, p.y, p.output.id == primary ? " (primary)" : "")
	}
	return true, ""
}

// Put back the CRTCs, screen size and primary `s` describes (after a failed apply).
@(private="file")
restore :: proc(c: ^tx.Connection, s: ^State) {
	res := XRRGetScreenResourcesCurrent(c.dpy, c.root)
	if res == nil { return }
	defer xlib.XRRFreeScreenResources(res)
	for &cr in s.crtcs { XRRSetCrtcConfig(c.dpy, res, cr.id, xlib.CurrentTime, 0, 0, 0, RR_ROTATE_0, nil, 0) }
	XRRSetScreenSize(c.dpy, c.root, s.screen_w, s.screen_h, mm_at_96(s.screen_w), mm_at_96(s.screen_h))
	for &cr in s.crtcs {
		if cr.mode == 0 || len(cr.outputs) == 0 { continue }
		XRRSetCrtcConfig(c.dpy, res, cr.id, xlib.CurrentTime, cr.x, cr.y, cr.mode, cr.rotation, raw_data(cr.outputs), i32(len(cr.outputs)))
	}
	for o in s.outputs { if o.primary { XRRSetOutputPrimary(c.dpy, c.root, o.id) } }
	xlib.Sync(c.dpy, false)
	log.warn("Display: the previous layout was put back")
}

@(private="file")
find_crtc :: proc(s: ^State, id: xlib.RRCrtc) -> ^Crtc {
	for &cr in s.crtcs { if cr.id == id { return &cr } }
	return nil
}

@(private="file")
mm_at_96 :: proc(px: i32) -> i32 {
	return i32(f64(px) * 25.4 / 96 + 0.5)
}
