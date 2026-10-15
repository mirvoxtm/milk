// Package display reads and changes the monitor layout through XRandR: the
// outputs and their modes, the monitor identities profiles are saved under
// (EDID), applying a layout (resolution, refresh rate, position, rotation,
// primary, on/off) and, in the running milk, re-applying the saved profile
// when monitors are plugged in or out (manager.odin).
package display

import "core:c"
import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "../tx"

Rotation :: enum u8 { Normal, Left, Inverted, Right }

ROTATION_NAMES :: [Rotation]string{.Normal = "normal", .Left = "left", .Inverted = "inverted", .Right = "right"}

Mode :: struct {
	id:        xlib.RRMode,
	w, h:      i32,
	rate:      f64, // Hz
	preferred: bool,
}

Output :: struct {
	id:        xlib.RROutput,
	name:      string,       // "HDMI-1"
	monitor:   string,       // identity: "DEL-A0F3-3132" (EDID), else the output name
	label:     string,       // the model ("DELL U2415"), else the output name
	connected: bool,
	internal:  bool,         // a laptop panel (eDP, LVDS, DSI)
	modes:     []Mode,       // preferred first, then the server's order
	crtcs:     []xlib.RRCrtc, // the CRTCs that can drive it
	mm_w, mm_h: i32,
	// What it shows now (crtc == 0: off).
	crtc:      xlib.RRCrtc,
	mode:      xlib.RRMode,
	x, y:      i32,
	w, h:      i32,          // on screen, after rotation
	rate:      f64,
	rotation:  Rotation,
	primary:   bool,
}

Crtc :: struct {
	id:        xlib.RRCrtc,
	mode:      xlib.RRMode,
	x, y:      i32,
	w, h:      i32,
	rotation:  u16,          // RR_Rotate_* bits as the server has them
	rotations: u16,          // the ones it supports
	outputs:   []xlib.RROutput,
}

State :: struct {
	arena:    virtual.Arena,
	outputs:  []Output,      // every output, connected or not, in the server's order
	crtcs:    []Crtc,
	screen_w, screen_h: i32,
	min_w, min_h, max_w, max_h: i32,
	timestamp, config_timestamp: xlib.Time,
}

@(private) RR_ROTATE_0   :: 1
@(private) RR_ROTATE_90  :: 2
@(private) RR_ROTATE_180 :: 4
@(private) RR_ROTATE_270 :: 8
@(private) RR_INTERLACE  :: 1 << 4
@(private) RR_DOUBLESCAN :: 1 << 5

rotation_bits :: proc(r: Rotation) -> u16 {
	switch r {
	case .Normal:   return RR_ROTATE_0
	case .Left:     return RR_ROTATE_90
	case .Inverted: return RR_ROTATE_180
	case .Right:    return RR_ROTATE_270
	}
	return RR_ROTATE_0
}

rotation_from_bits :: proc(bits: u16) -> Rotation {
	switch bits & 0xf {
	case RR_ROTATE_90:  return .Left
	case RR_ROTATE_180: return .Inverted
	case RR_ROTATE_270: return .Right
	}
	return .Normal
}

rotation_from_name :: proc(name: string) -> Rotation {
	names := ROTATION_NAMES
	for n, r in names { if n == name { return r } }
	return .Normal
}

// The size on screen of a w × h mode turned by r.
rotated :: proc(w, h: i32, r: Rotation) -> (i32, i32) {
	return (r == .Left || r == .Right) ? h : w, (r == .Left || r == .Right) ? w : h
}

// The refresh rate of a mode, like xrandr computes it.
mode_rate :: proc(m: ^xlib.XRRModeInfo) -> f64 {
	if m.hTotal == 0 || m.vTotal == 0 { return 0 }
	v := f64(m.vTotal)
	flags := transmute(u64)m.modeFlags
	if flags & RR_DOUBLESCAN != 0 { v *= 2 }
	if flags & RR_INTERLACE != 0 { v /= 2 }
	return f64(m.dotClock) / (f64(m.hTotal) * v)
}

// Read the outputs, CRTCs and modes the server knows now (the "current"
// resources: no slow re-probe of the monitors). nil when RandR 1.2 is missing.
read_state :: proc(c: ^tx.Connection) -> ^State {
	res := XRRGetScreenResourcesCurrent(c.dpy, c.root)
	if res == nil { return nil }
	defer xlib.XRRFreeScreenResources(res)

	s := new(State)
	if virtual.arena_init_growing(&s.arena) != nil {
		free(s)
		return nil
	}
	context.allocator = virtual.arena_allocator(&s.arena)
	s.timestamp, s.config_timestamp = res.timestamp, res.configTimestamp
	XRRGetScreenSizeRange(c.dpy, c.root, &s.min_w, &s.min_h, &s.max_w, &s.max_h)
	attrs: xlib.XWindowAttributes
	xlib.GetWindowAttributes(c.dpy, c.root, &attrs)
	s.screen_w, s.screen_h = attrs.width, attrs.height
	primary := XRRGetOutputPrimary(c.dpy, c.root)

	crtcs := make([dynamic]Crtc, 0, int(res.ncrtc))
	for i in 0 ..< int(res.ncrtc) {
		info := xlib.XRRGetCrtcInfo(c.dpy, res, res.crtcs[i])
		if info == nil { continue }
		append(&crtcs, Crtc{
			id = res.crtcs[i], mode = info.mode, x = info.x, y = info.y, w = i32(info.width), h = i32(info.height),
			rotation = u16(info.rotation), rotations = u16(info.rotations),
			outputs = slice.clone(info.outputs[:info.noutput]),
		})
		xlib.XRRFreeCrtcInfo(info)
	}
	s.crtcs = crtcs[:]

	edid_atom := xlib.InternAtom(c.dpy, "EDID", true)
	outputs := make([dynamic]Output, 0, int(res.noutput))
	for i in 0 ..< int(res.noutput) {
		info := xlib.XRRGetOutputInfo(c.dpy, res, res.outputs[i])
		if info == nil { continue }
		o := Output{id = res.outputs[i], primary = res.outputs[i] == primary}
		o.name = strings.clone(strings.string_from_ptr((^u8)(info.name), int(info.nameLen)))
		o.connected = info.connection == .RR_Connected
		o.internal = is_internal(o.name)
		o.mm_w, o.mm_h = i32(info.mm_width), i32(info.mm_height)
		o.crtcs = slice.clone(info.crtcs[:info.ncrtc])
		modes := make([dynamic]Mode, 0, int(info.nmode))
		for k in 0 ..< int(info.nmode) {
			for j in 0 ..< int(res.nmode) {
				m := &res.modes[j]
				if m.id != info.modes[k] { continue }
				append(&modes, Mode{id = m.id, w = i32(m.width), h = i32(m.height), rate = mode_rate(m), preferred = k < int(info.npreferred)})
				break
			}
		}
		o.modes = modes[:]
		o.crtc = info.crtc
		for &cr in s.crtcs {
			if cr.id != o.crtc || cr.mode == 0 { continue }
			o.mode = cr.mode
			o.x, o.y, o.w, o.h = cr.x, cr.y, cr.w, cr.h
			o.rotation = rotation_from_bits(cr.rotation)
			for m in o.modes { if m.id == cr.mode { o.rate = m.rate } }
			if o.rate == 0 { // a mode of another output (clones): look it up in the screen's list
				for j in 0 ..< int(res.nmode) { if res.modes[j].id == cr.mode { o.rate = mode_rate(&res.modes[j]) } }
			}
		}
		if o.mode == 0 { o.crtc = 0 }
		if o.connected && edid_atom != 0 {
			if e, ok := read_edid(c, o.id, edid_atom); ok {
				o.monitor = edid_identity(e)
				o.label = e.name != "" ? e.name : fmt.aprintf("%s %04X", e.maker, e.product) // no model name: "LEN 40A9"
			}
		}
		if o.monitor == "" { o.monitor = o.name }
		if o.label == "" { o.label = o.name }
		append(&outputs, o)
		xlib.XRRFreeOutputInfo(info)
	}
	s.outputs = outputs[:]
	// Two identical monitors (same EDID, often without a serial) are told apart by their output.
	counts := make(map[string]int, context.temp_allocator)
	for o in s.outputs { if o.connected { counts[o.monitor] += 1 } }
	for &o in s.outputs {
		if o.connected && o.monitor != o.name && counts[o.monitor] > 1 { o.monitor = strings.concatenate({o.monitor, "@", o.name}) }
	}
	return s
}

destroy_state :: proc(s: ^State) {
	if s == nil { return }
	virtual.arena_destroy(&s.arena)
	free(s)
}

@(private="file")
read_edid :: proc(conn: ^tx.Connection, output: xlib.RROutput, atom: xlib.Atom) -> (Edid, bool) {
	actual: xlib.Atom
	format: i32
	nitems, after: c.ulong
	data: [^]u8
	if XRRGetOutputProperty(conn.dpy, output, atom, 0, 128, false, false, xlib.Atom(0), &actual, &format, &nitems, &after, &data) != 0 { return {}, false }
	if data == nil { return {}, false }
	defer xlib.Free(data)
	if format != 8 || nitems < 128 { return {}, false }
	return parse_edid(data[:nitems])
}

// eDP, LVDS and DSI are built-in panels.
is_internal :: proc(name: string) -> bool {
	n := strings.to_lower(name, context.temp_allocator)
	return strings.has_prefix(n, "edp") || strings.has_prefix(n, "lvds") || strings.has_prefix(n, "dsi")
}

// The connected outputs, in the server's order.
connected_outputs :: proc(s: ^State, allocator := context.temp_allocator) -> []^Output {
	out := make([dynamic]^Output, 0, len(s.outputs), allocator)
	for &o in s.outputs { if o.connected { append(&out, &o) } }
	return out[:]
}

// The key of the set of monitors connected: their identities, sorted, joined by "+".
setup_key :: proc(s: ^State, allocator := context.allocator) -> string {
	ids := make([dynamic]string, 0, len(s.outputs), context.temp_allocator)
	for o in s.outputs { if o.connected { append(&ids, o.monitor) } }
	slice.sort(ids[:])
	return strings.join(ids[:], "+", allocator)
}
