// X extensions the lock screen and the idle manager use and vendor:x11/xlib
// does not bind: SYNC (the server's IDLETIME counter and alarms on it), DPMS
// (monitor power), RandR gamma ramps (dimming) and RandR screen-change events,
// and XFixes (selection-owner events, hiding the pointer).
package lock

import xlib "vendor:x11/xlib"

foreign import xext "system:Xext"
foreign import xrandr "system:Xrandr"
foreign import xfixes "system:Xfixes"

// ---------------------------------------------------------------------------
// SYNC
// ---------------------------------------------------------------------------
XSyncValue :: struct {
	hi: i32,
	lo: u32,
}

XSyncCounter :: xlib.XID
XSyncAlarm   :: xlib.XID

XSyncSystemCounter :: struct {
	name:       cstring,
	counter:    XSyncCounter,
	resolution: XSyncValue,
}

XSyncTrigger :: struct {
	counter:    XSyncCounter,
	value_type: i32, // XSYNC_ABSOLUTE | XSYNC_RELATIVE
	wait_value: XSyncValue,
	test_type:  i32, // XSYNC_POSITIVE_TRANSITION ...
}

XSyncAlarmAttributes :: struct {
	trigger: XSyncTrigger,
	delta:   XSyncValue,
	events:  b32,
	state:   i32,
}

// XSyncAlarmNotifyEvent: only the alarm is read (after type, serial,
// send_event and display, like every Xlib event).
XSyncAlarmNotifyEvent :: struct {
	type:          i32,
	serial:        uint,
	send_event:    b32,
	display:       ^xlib.Display,
	alarm:         XSyncAlarm,
	counter_value: XSyncValue,
	alarm_value:   XSyncValue,
	time:          xlib.Time,
	state:         i32,
}

XSYNC_ALARM_NOTIFY :: 1 // event_base + this

XSYNC_ABSOLUTE :: 0

XSYNC_POSITIVE_TRANSITION :: 0
XSYNC_NEGATIVE_TRANSITION :: 1

XSYNC_CA_COUNTER    :: uint(1 << 0)
XSYNC_CA_VALUE_TYPE :: uint(1 << 1)
XSYNC_CA_VALUE      :: uint(1 << 2)
XSYNC_CA_TEST_TYPE  :: uint(1 << 3)
XSYNC_CA_DELTA      :: uint(1 << 4)
XSYNC_CA_EVENTS     :: uint(1 << 5)

@(default_calling_convention="c")
foreign xext {
	XSyncQueryExtension        :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	XSyncInitialize            :: proc(dpy: ^xlib.Display, major, minor: ^i32) -> i32 ---
	XSyncListSystemCounters    :: proc(dpy: ^xlib.Display, n: ^i32) -> [^]XSyncSystemCounter ---
	XSyncFreeSystemCounterList :: proc(list: [^]XSyncSystemCounter) ---
	XSyncQueryCounter          :: proc(dpy: ^xlib.Display, counter: XSyncCounter, value: ^XSyncValue) -> i32 ---
	XSyncCreateAlarm           :: proc(dpy: ^xlib.Display, mask: uint, attrs: ^XSyncAlarmAttributes) -> XSyncAlarm ---
	XSyncChangeAlarm           :: proc(dpy: ^xlib.Display, alarm: XSyncAlarm, mask: uint, attrs: ^XSyncAlarmAttributes) -> i32 ---
	XSyncDestroyAlarm          :: proc(dpy: ^xlib.Display, alarm: XSyncAlarm) -> i32 ---
}

sync_value :: proc(v: i64) -> XSyncValue {
	return {hi = i32(v >> 32), lo = u32(v & 0xFFFFFFFF)}
}

sync_value_int :: proc(v: XSyncValue) -> i64 {
	return i64(v.hi) << 32 | i64(v.lo)
}

// ---------------------------------------------------------------------------
// DPMS
// ---------------------------------------------------------------------------
DPMS_MODE_ON  :: u16(0)
DPMS_MODE_OFF :: u16(3)

@(default_calling_convention="c")
foreign xext {
	DPMSQueryExtension :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	DPMSCapable        :: proc(dpy: ^xlib.Display) -> b32 ---
	DPMSInfo           :: proc(dpy: ^xlib.Display, power_level: ^u16, state: ^u8) -> i32 ---
	DPMSEnable         :: proc(dpy: ^xlib.Display) -> i32 ---
	DPMSDisable        :: proc(dpy: ^xlib.Display) -> i32 ---
	DPMSForceLevel     :: proc(dpy: ^xlib.Display, level: u16) -> i32 ---
	DPMSGetTimeouts    :: proc(dpy: ^xlib.Display, standby, suspend, off: ^u16) -> i32 ---
	DPMSSetTimeouts    :: proc(dpy: ^xlib.Display, standby, suspend, off: u16) -> i32 ---
}

// ---------------------------------------------------------------------------
// RandR gamma and events
// ---------------------------------------------------------------------------
XRRCrtcGamma :: struct {
	size:  i32,
	red:   [^]u16,
	green: [^]u16,
	blue:  [^]u16,
}

RR_SCREEN_CHANGE_NOTIFY      :: 0 // event_base + this
RR_SCREEN_CHANGE_NOTIFY_MASK :: i32(1 << 0)
RR_CRTC_CHANGE_NOTIFY_MASK   :: i32(1 << 1)
RR_NOTIFY                    :: 1 // event_base + this (crtc/output changes)

@(default_calling_convention="c")
foreign xrandr {
	XRRQueryExtension             :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	XRRSelectInput                :: proc(dpy: ^xlib.Display, window: xlib.Window, mask: i32) ---
	XRRGetScreenResourcesCurrent  :: proc(dpy: ^xlib.Display, window: xlib.Window) -> ^xlib.XRRScreenResources ---
	XRRFreeScreenResources        :: proc(res: ^xlib.XRRScreenResources) ---
	XRRGetCrtcGammaSize           :: proc(dpy: ^xlib.Display, crtc: xlib.RRCrtc) -> i32 ---
	XRRGetCrtcGamma               :: proc(dpy: ^xlib.Display, crtc: xlib.RRCrtc) -> ^XRRCrtcGamma ---
	XRRAllocGamma                 :: proc(size: i32) -> ^XRRCrtcGamma ---
	XRRSetCrtcGamma               :: proc(dpy: ^xlib.Display, crtc: xlib.RRCrtc, gamma: ^XRRCrtcGamma) ---
	XRRFreeGamma                  :: proc(gamma: ^XRRCrtcGamma) ---
	XRRUpdateConfiguration        :: proc(ev: ^xlib.XEvent) -> i32 ---
}

// ---------------------------------------------------------------------------
// XFixes: selection-owner events (is a locker running?) and hiding the pointer
// ---------------------------------------------------------------------------
XFIXES_SELECTION_NOTIFY     :: 0 // event_base + this
XFIXES_SELECTION_ANY_MASK   :: uint(1 << 0 | 1 << 1 | 1 << 2) // owner set, window destroyed, client closed

XFixesSelectionNotifyEvent :: struct {
	type:                i32,
	serial:              uint,
	send_event:          b32,
	display:             ^xlib.Display,
	window:              xlib.Window,
	subtype:             i32,
	owner:               xlib.Window,
	selection:           xlib.Atom,
	timestamp:           xlib.Time,
	selection_timestamp: xlib.Time,
}

@(default_calling_convention="c")
foreign xfixes {
	XFixesQueryExtension       :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	XFixesSelectSelectionInput :: proc(dpy: ^xlib.Display, win: xlib.Window, selection: xlib.Atom, event_mask: uint) ---
	XFixesHideCursor           :: proc(dpy: ^xlib.Display, win: xlib.Window) ---
	XFixesShowCursor           :: proc(dpy: ^xlib.Display, win: xlib.Window) ---
}
