// Text rendering through Xft (fontconfig + FreeType + XRender), the same
// stack every X11 toolkit uses, so bar and desktop text match the rest of
// the session.
package tx

import "base:runtime"
import "core:log"
import "core:strings"
import xlib "vendor:x11/xlib"

foreign import xft "system:Xft"
foreign import fontconfig "system:fontconfig"

XftFont :: struct {
	ascent, descent, height, max_advance_width: i32,
	charset: rawptr,
	pattern: rawptr,
}
XftDraw :: distinct struct {}
XRenderColor :: struct { red, green, blue, alpha: u16 }
XftColor :: struct { pixel: uint, color: XRenderColor }
XGlyphInfo :: struct { width, height: u16, x, y, xOff, yOff: i16 }

@(default_calling_convention="c")
foreign xft {
	XftFontOpenName      :: proc(dpy: ^xlib.Display, screen: i32, name: cstring) -> ^XftFont ---
	XftFontOpenPattern   :: proc(dpy: ^xlib.Display, pattern: rawptr) -> ^XftFont ---
	XftDefaultSubstitute :: proc(dpy: ^xlib.Display, screen: i32, pattern: rawptr) ---
	XftFontClose         :: proc(dpy: ^xlib.Display, font: ^XftFont) ---
	XftDrawCreate        :: proc(dpy: ^xlib.Display, drawable: xlib.Drawable, visual: ^xlib.Visual, colormap: xlib.Colormap) -> ^XftDraw ---
	XftDrawChange        :: proc(draw: ^XftDraw, drawable: xlib.Drawable) ---
	XftDrawDestroy       :: proc(draw: ^XftDraw) ---
	XftColorAllocValue   :: proc(dpy: ^xlib.Display, visual: ^xlib.Visual, cmap: xlib.Colormap, color: ^XRenderColor, result: ^XftColor) -> b32 ---
	XftColorFree         :: proc(dpy: ^xlib.Display, visual: ^xlib.Visual, cmap: xlib.Colormap, color: ^XftColor) ---
	XftDrawStringUtf8    :: proc(draw: ^XftDraw, color: ^XftColor, font: ^XftFont, x, y: i32, str: [^]u8, len: i32) ---
	XftTextExtentsUtf8   :: proc(dpy: ^xlib.Display, font: ^XftFont, str: [^]u8, len: i32, extents: ^XGlyphInfo) ---
	XftCharExists        :: proc(dpy: ^xlib.Display, font: ^XftFont, ucs4: u32) -> b32 ---
}

@(default_calling_convention="c")
foreign fontconfig {
	FcPatternCreate     :: proc() -> rawptr ---
	FcPatternDestroy    :: proc(p: rawptr) ---
	FcPatternAddString  :: proc(p: rawptr, object: cstring, s: cstring) -> b32 ---
	FcPatternAddDouble  :: proc(p: rawptr, object: cstring, d: f64) -> b32 ---
	FcPatternAddInteger :: proc(p: rawptr, object: cstring, i: i32) -> b32 ---
	FcPatternGetString  :: proc(p: rawptr, object: cstring, n: i32, s: ^cstring) -> i32 ---
	FcConfigSubstitute  :: proc(config: rawptr, p: rawptr, kind: i32) -> b32 ---
	FcNameParse         :: proc(name: cstring) -> rawptr ---
	FcCharSetCreate     :: proc() -> rawptr ---
	FcCharSetAddChar    :: proc(cs: rawptr, ucs4: u32) -> b32 ---
	FcCharSetDestroy    :: proc(cs: rawptr) ---
	FcPatternAddCharSet :: proc(p: rawptr, object: cstring, cs: rawptr) -> b32 ---
	FcFontMatch         :: proc(config: rawptr, p: rawptr, result: ^i32) -> rawptr ---
}

Font :: struct {
	xft:     ^XftFont,
	ascent:  i32,
	descent: i32,
	height:  i32,
	// Per-character fallback (CJK, Cyrillic, symbols...): Xft draws with one
	// font only, so text is split into runs and each character missing from
	// the primary font is drawn with the installed font fontconfig picks for
	// it. `spec` is the fontconfig name the font was opened with ("" for
	// fonts opened from a file, which get no fallback).
	spec:      string,
	fallbacks: [dynamic]^XftFont,
	choice:    map[rune]int, // 0 = primary, k = fallbacks[k-1], -1 = no font has it
	allocator: runtime.Allocator,
}

@(private) MAX_FALLBACKS :: 12

// Open a font by fontconfig pattern ("sans:bold") at a pixel size.
font_open :: proc(c: ^Connection, pattern: string, pixel_size: i32) -> (^Font, bool) {
	spec := strings.clone_to_cstring(strings.concatenate({pattern, ":pixelsize=", int_to_string(int(pixel_size))}, context.temp_allocator), context.temp_allocator)
	xf := XftFontOpenName(c.dpy, c.screen, spec)
	if xf == nil {
		log.warnf("Could not open font %q", pattern)
		return nil, false
	}
	f := wrap_font(xf)
	f.spec = strings.clone(string(spec), f.allocator)
	return f, true
}

// Open a font from a file (used for icon fonts that are not installed system-wide).
font_open_file :: proc(c: ^Connection, file: string, pixel_size: i32) -> (^Font, bool) {
	pat := FcPatternCreate()
	FcPatternAddString(pat, "file", strings.clone_to_cstring(file, context.temp_allocator))
	FcPatternAddInteger(pat, "index", 0)
	FcPatternAddDouble(pat, "pixelsize", f64(pixel_size))
	FcConfigSubstitute(nil, pat, 0) // FcMatchPattern
	XftDefaultSubstitute(c.dpy, c.screen, pat)
	xf := XftFontOpenPattern(c.dpy, pat) // takes ownership of the pattern
	if xf == nil {
		log.warnf("Could not open font file %q", file)
		return nil, false
	}
	return wrap_font(xf), true
}

@(private)
wrap_font :: proc(xf: ^XftFont) -> ^Font {
	f := new(Font)
	f.xft = xf
	f.ascent = xf.ascent
	f.descent = xf.descent
	f.height = xf.height
	f.allocator = context.allocator
	f.fallbacks = make([dynamic]^XftFont, f.allocator)
	f.choice = make(map[rune]int, f.allocator)
	return f
}

font_close :: proc(c: ^Connection, f: ^Font) {
	if f == nil { return }
	XftFontClose(c.dpy, f.xft)
	for fb in f.fallbacks { XftFontClose(c.dpy, fb) }
	delete(f.fallbacks)
	delete(f.choice)
	delete(f.spec, f.allocator)
	free(f, f.allocator)
}

// Which font draws `r`: 0 = the primary font, k = fallbacks[k-1].
@(private)
font_index_for :: proc(c: ^Connection, f: ^Font, r: rune) -> int {
	if r < 0x80 || bool(XftCharExists(c.dpy, f.xft, u32(r))) { return 0 }
	if idx, known := f.choice[r]; known { return max(idx, 0) }
	for fb, i in f.fallbacks {
		if XftCharExists(c.dpy, fb, u32(r)) {
			f.choice[r] = i + 1
			return i + 1
		}
	}
	idx := -1
	if f.spec != "" && len(f.fallbacks) < MAX_FALLBACKS {
		// Ask fontconfig for the best installed font that has this character,
		// keeping the family, weight and size of the primary font.
		pat := FcNameParse(strings.clone_to_cstring(f.spec, context.temp_allocator))
		if pat != nil {
			cs := FcCharSetCreate()
			FcCharSetAddChar(cs, u32(r))
			FcPatternAddCharSet(pat, "charset", cs)
			FcConfigSubstitute(nil, pat, 0) // FcMatchPattern
			XftDefaultSubstitute(c.dpy, c.screen, pat)
			result: i32
			match := FcFontMatch(nil, pat, &result)
			FcPatternDestroy(pat)
			FcCharSetDestroy(cs)
			if match != nil {
				if xf := XftFontOpenPattern(c.dpy, match); xf != nil { // takes ownership of match
					if XftCharExists(c.dpy, xf, u32(r)) {
						append(&f.fallbacks, xf)
						idx = len(f.fallbacks)
					} else {
						XftFontClose(c.dpy, xf)
					}
				} else {
					FcPatternDestroy(match)
				}
			}
		}
	}
	f.choice[r] = idx
	return max(idx, 0)
}

@(private)
font_by_index :: proc(f: ^Font, idx: int) -> ^XftFont {
	return idx == 0 ? f.xft : f.fallbacks[idx - 1]
}

// Split `s` into runs drawn with one font each and call `visit` for every run.
@(private)
Text_Run :: struct { font: ^XftFont, text: string }

@(private)
text_runs :: proc(c: ^Connection, f: ^Font, s: string, allocator := context.temp_allocator) -> []Text_Run {
	runs := make([dynamic]Text_Run, allocator)
	start := 0
	current := -1
	for r, i in s {
		idx := font_index_for(c, f, r)
		if idx != current {
			if current >= 0 && i > start { append(&runs, Text_Run{font_by_index(f, current), s[start:i]}) }
			start = i
			current = idx
		}
	}
	if current >= 0 && len(s) > start { append(&runs, Text_Run{font_by_index(f, current), s[start:]}) }
	return runs[:]
}

// Fast path: pure ASCII (and anything the primary font covers) is one run.
@(private)
single_run :: proc(c: ^Connection, f: ^Font, s: string) -> bool {
	for i in 0 ..< len(s) {
		if s[i] >= 0x80 { break }
		if i == len(s) - 1 { return true }
	}
	for r in s {
		if font_index_for(c, f, r) != 0 { return false }
	}
	return true
}

font_has_glyph :: proc(c: ^Connection, f: ^Font, r: rune) -> bool {
	return f != nil && bool(XftCharExists(c.dpy, f.xft, u32(r)))
}

// Advance width of a UTF-8 string in pixels.
text_width :: proc(c: ^Connection, f: ^Font, s: string) -> i32 {
	if f == nil || len(s) == 0 { return 0 }
	ext: XGlyphInfo
	if single_run(c, f, s) {
		XftTextExtentsUtf8(c.dpy, f.xft, raw_data(s), i32(len(s)), &ext)
		return i32(ext.xOff)
	}
	total: i32
	for run in text_runs(c, f, s) {
		XftTextExtentsUtf8(c.dpy, run.font, raw_data(run.text), i32(len(run.text)), &ext)
		total += i32(ext.xOff)
	}
	return total
}

// Ink bounding box of a UTF-8 string: (x offset, y offset above baseline, width, height).
text_extents :: proc(c: ^Connection, f: ^Font, s: string) -> XGlyphInfo {
	ext: XGlyphInfo
	if f == nil || len(s) == 0 { return ext }
	if single_run(c, f, s) {
		XftTextExtentsUtf8(c.dpy, f.xft, raw_data(s), i32(len(s)), &ext)
		return ext
	}
	// Several fonts: the ink box of the whole string, run by run.
	pen: i32
	left, right, top, bottom: i32 = max(i32), min(i32), max(i32), min(i32)
	for run in text_runs(c, f, s) {
		re: XGlyphInfo
		XftTextExtentsUtf8(c.dpy, run.font, raw_data(run.text), i32(len(run.text)), &re)
		x0 := pen - i32(re.x)
		y0 := -i32(re.y)
		left = min(left, x0)
		right = max(right, x0 + i32(re.width))
		top = min(top, y0)
		bottom = max(bottom, y0 + i32(re.height))
		pen += i32(re.xOff)
	}
	ext.x = i16(-left)
	ext.y = i16(-top)
	ext.width = u16(max(right - left, 0))
	ext.height = u16(max(bottom - top, 0))
	ext.xOff = i16(pen)
	return ext
}

// Truncate `s` with an ellipsis so that it fits in `max_width` pixels.
text_ellipsize :: proc(c: ^Connection, f: ^Font, s: string, max_width: i32, allocator := context.temp_allocator) -> string {
	if text_width(c, f, s) <= max_width { return s }
	ellipsis := "…"
	ew := text_width(c, f, ellipsis)
	runes := strings.rune_count(s)
	for n := runes - 1; n > 0; n -= 1 {
		prefix := rune_prefix(s, n)
		if text_width(c, f, prefix) + ew <= max_width {
			return strings.concatenate({strings.trim_right_space(prefix), ellipsis}, allocator)
		}
	}
	return ellipsis
}

@(private)
rune_prefix :: proc(s: string, n: int) -> string {
	count := 0
	for _, i in s {
		if count == n { return s[:i] }
		count += 1
	}
	return s
}

// A drawing target for text (one per pixmap/window you draw into).
Text_Surface :: struct {
	c:    ^Connection,
	draw: ^XftDraw,
}

text_surface_make :: proc(c: ^Connection, d: xlib.Drawable) -> Text_Surface {
	return {c = c, draw = XftDrawCreate(c.dpy, d, c.visual, c.colormap)}
}

text_surface_destroy :: proc(ts: ^Text_Surface) {
	if ts.draw != nil { XftDrawDestroy(ts.draw) }
	ts.draw = nil
}

// Draw `s` with its baseline at `baseline_y`.
draw_text :: proc(ts: ^Text_Surface, f: ^Font, x, baseline_y: i32, s: string, color: Color) {
	if f == nil || len(s) == 0 || ts.draw == nil { return }
	xc: XftColor
	rc := XRenderColor{u16(color.r) * 257, u16(color.g) * 257, u16(color.b) * 257, u16(color.a) * 257}
	if !XftColorAllocValue(ts.c.dpy, ts.c.visual, ts.c.colormap, &rc, &xc) { return }
	if single_run(ts.c, f, s) {
		XftDrawStringUtf8(ts.draw, &xc, f.xft, x, baseline_y, raw_data(s), i32(len(s)))
	} else {
		pen := x
		for run in text_runs(ts.c, f, s) {
			XftDrawStringUtf8(ts.draw, &xc, run.font, pen, baseline_y, raw_data(run.text), i32(len(run.text)))
			ext: XGlyphInfo
			XftTextExtentsUtf8(ts.c.dpy, run.font, raw_data(run.text), i32(len(run.text)), &ext)
			pen += i32(ext.xOff)
		}
	}
	XftColorFree(ts.c.dpy, ts.c.visual, ts.c.colormap, &xc)
}

// Draw `s` vertically centred in a box of height `box_h` starting at `box_y`.
draw_text_centered_v :: proc(ts: ^Text_Surface, f: ^Font, x, box_y, box_h: i32, s: string, color: Color) {
	baseline := box_y + (box_h - f.height) / 2 + f.ascent
	draw_text(ts, f, x, baseline, s, color)
}

@(private)
int_to_string :: proc(v: int, allocator := context.temp_allocator) -> string {
	buf: [24]u8
	return strings.clone(strconv_itoa(buf[:], v), allocator)
}

@(private)
strconv_itoa :: proc(buf: []u8, v: int) -> string {
	if v == 0 { buf[0] = '0'; return string(buf[:1]) }
	n := v
	neg := n < 0
	if neg { n = -n }
	i := len(buf)
	for n > 0 {
		i -= 1
		buf[i] = u8('0' + n % 10)
		n /= 10
	}
	if neg { i -= 1; buf[i] = '-' }
	return string(buf[i:])
}
