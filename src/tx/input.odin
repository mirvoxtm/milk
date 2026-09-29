// Text input with dead keys and compose (´ + a = á, ~ + a = ã, ^ + e = ê).
//
// XLookupString returns raw keysyms, so a dead key followed by a letter never
// becomes an accented character. An X input method does the composition:
// every text field opens an input context on its window, the event loop hands
// each event to `input_filter` first (it swallows the dead key), and key
// presses are decoded with `input_lookup`, which returns the composed UTF-8.
// With no input-method server running, Xlib's built-in method reads the
// locale's Compose table, which is all dead keys need.
package tx

import "core:c/libc"
import "core:log"
import xlib "vendor:x11/xlib"

foreign import x11_im "system:X11"

@(default_calling_convention="c")
foreign x11_im {
	XFilterEvent    :: proc(ev: ^xlib.XEvent, w: xlib.Window) -> b32 ---
	XCloseIM        :: proc(im: xlib.XIM) -> i32 ---
	XDestroyIC      :: proc(ic: xlib.XIC) ---
	XSupportsLocale :: proc() -> b32 ---
}

@(private) XIM_PREEDIT_NOTHING :: 0x0008
@(private) XIM_STATUS_NOTHING  :: 0x0400

@(private) g_im: xlib.XIM
@(private) g_im_tried: bool

Input :: struct {
	ic:  xlib.XIC,
	win: xlib.Window,
}

// The process-wide input method (opened on first use).
@(private)
input_method :: proc(c: ^Connection) -> xlib.XIM {
	if g_im_tried { return g_im }
	g_im_tried = true
	// Only the character type follows the user's locale: numbers must keep
	// parsing with a dot in fontconfig and friends.
	libc.setlocale(.CTYPE, "")
	if !XSupportsLocale() {
		log.warn("Xlib does not support this locale; dead keys will not compose in milk's text fields")
		return nil
	}
	xlib.SetLocaleModifiers("")
	g_im = xlib.OpenIM(c.dpy, nil, nil, nil)
	if g_im == nil {
		xlib.SetLocaleModifiers("@im=none") // Xlib's built-in Compose method
		g_im = xlib.OpenIM(c.dpy, nil, nil, nil)
	}
	if g_im == nil { log.warn("No X input method; dead keys will not compose in milk's text fields") }
	return g_im
}

// An input context for text typed into `win` (call once per window).
input_open :: proc(c: ^Connection, win: xlib.Window) -> Input {
	in_: Input
	in_.win = win
	im := input_method(c)
	if im == nil { return in_ }
	style := uint(XIM_PREEDIT_NOTHING | XIM_STATUS_NOTHING)
	in_.ic = xlib.CreateIC(im, cstring("inputStyle"), style, cstring("clientWindow"), uint(win),
	                       cstring("focusWindow"), uint(win), rawptr(nil))
	return in_
}

input_close :: proc(in_: ^Input) {
	if in_.ic != nil { XDestroyIC(in_.ic) }
	in_.ic = nil
}

// Tell the input method whether this field has the keyboard focus.
input_focus :: proc(in_: ^Input, focused: bool) {
	if in_.ic == nil { return }
	if focused { xlib.SetICFocus(in_.ic) } else { xlib.UnsetICFocus(in_.ic) }
}

// Call for every event before handling it; true means the input method
// consumed it (e.g. a dead key) and it must be ignored.
input_filter :: proc(ev: ^xlib.XEvent) -> bool {
	if !g_im_tried || g_im == nil { return false }
	return bool(XFilterEvent(ev, 0))
}

// Decode a KeyPress: the composed text (UTF-8, may be empty for keys such as
// arrows) and the keysym. Falls back to XLookupString without an input context.
input_lookup :: proc(in_: ^Input, ev: ^xlib.XKeyEvent, allocator := context.temp_allocator) -> (text: string, keysym: xlib.KeySym) {
	buf: [64]u8
	n: i32
	if in_ != nil && in_.ic != nil {
		status: xlib.LookupStringStatus
		n = xlib.Xutf8LookupString(in_.ic, ev, cstring(&buf[0]), i32(len(buf) - 1), &keysym, &status)
		if status == .BufferOverflow || status == .LookupNone { n = 0 }
		if status == .LookupChars { keysym = xlib.KeySym(0) }
	} else {
		n = xlib.LookupString(ev, &buf[0], i32(len(buf) - 1), &keysym, nil)
	}
	if n <= 0 { return "", keysym }
	out := make([]u8, int(n), allocator)
	copy(out, buf[:n])
	return string(out), keysym
}
