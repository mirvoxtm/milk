// XRandR calls that vendor:x11/xlib does not bind (it has the getters only).
package display

import "core:c"
import xlib "vendor:x11/xlib"

foreign import xrandr "system:Xrandr"

@(private) RR_SCREEN_CHANGE_NOTIFY      :: 0 // event_base + this
@(private) RR_NOTIFY                    :: 1
@(private) RR_SCREEN_CHANGE_NOTIFY_MASK :: 1 << 0
@(private) RR_CRTC_CHANGE_NOTIFY_MASK   :: 1 << 1
@(private) RR_OUTPUT_CHANGE_NOTIFY_MASK :: 1 << 2
@(private) RR_SET_CONFIG_SUCCESS        :: 0

@(private, default_calling_convention = "c")
foreign xrandr {
	XRRQueryExtension            :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	XRRSelectInput               :: proc(dpy: ^xlib.Display, window: xlib.Window, mask: i32) ---
	XRRGetScreenResourcesCurrent :: proc(dpy: ^xlib.Display, window: xlib.Window) -> ^xlib.XRRScreenResources ---
	XRRGetScreenSizeRange        :: proc(dpy: ^xlib.Display, window: xlib.Window, min_w, min_h, max_w, max_h: ^i32) -> i32 ---
	XRRSetScreenSize             :: proc(dpy: ^xlib.Display, window: xlib.Window, width, height, mm_width, mm_height: i32) ---
	XRRSetCrtcConfig             :: proc(dpy: ^xlib.Display, resources: ^xlib.XRRScreenResources, crtc: xlib.RRCrtc, timestamp: xlib.Time,
	                                     x, y: i32, mode: xlib.RRMode, rotation: u16, outputs: [^]xlib.RROutput, noutputs: i32) -> i32 ---
	XRRSetOutputPrimary          :: proc(dpy: ^xlib.Display, window: xlib.Window, output: xlib.RROutput) ---
	XRRGetOutputPrimary          :: proc(dpy: ^xlib.Display, window: xlib.Window) -> xlib.RROutput ---
	XRRGetOutputProperty         :: proc(dpy: ^xlib.Display, output: xlib.RROutput, property: xlib.Atom, offset, length: c.long,
	                                     delete, pending: b32, req_type: xlib.Atom, actual_type: ^xlib.Atom, actual_format: ^i32,
	                                     nitems, bytes_after: ^c.ulong, prop: ^[^]u8) -> i32 ---
	XRRUpdateConfiguration       :: proc(event: ^xlib.XEvent) -> i32 ---
}
