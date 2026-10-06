// milk addition: the X extensions the overview draws with (overview.odin):
// Composite keeps every window's contents in a pixmap of its own, Damage
// says when they change, Render scales them into thumbnails, and SHAPE gives
// the shape of the bar the overview leaves uncovered.
package wm

import xlib "vendor:x11/xlib"

@(private) Picture    :: xlib.XID
@(private) PictFormat :: xlib.XID
@(private) Damage     :: xlib.XID

// ---------------------------------------------------------------------------
// Composite
// ---------------------------------------------------------------------------
@(private) COMPOSITE_REDIRECT_AUTOMATIC :: 0

foreign import xcomposite "system:Xcomposite"
@(default_calling_convention="c", private)
foreign xcomposite {
	XCompositeQueryExtension       :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	XCompositeRedirectSubwindows   :: proc(dpy: ^xlib.Display, window: xlib.Window, update: i32) ---
	XCompositeUnredirectSubwindows :: proc(dpy: ^xlib.Display, window: xlib.Window, update: i32) ---
}

// ---------------------------------------------------------------------------
// Damage
// ---------------------------------------------------------------------------
@(private) DAMAGE_REPORT_NON_EMPTY :: 3
@(private) DAMAGE_NOTIFY           :: 0 // event offset from the extension's event base

@(private)
XDamageNotifyEvent :: struct {
	type:       i32,
	serial:     uint,
	send_event: b32,
	display:    ^xlib.Display,
	drawable:   xlib.Drawable,
	damage:     Damage,
	level:      i32,
	more:       b32,
	timestamp:  xlib.Time,
	area:       xlib.XRectangle,
	geometry:   xlib.XRectangle,
}

foreign import xdamage "system:Xdamage"
@(default_calling_convention="c", private)
foreign xdamage {
	XDamageQueryExtension :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	XDamageCreate         :: proc(dpy: ^xlib.Display, drawable: xlib.Drawable, level: i32) -> Damage ---
	XDamageDestroy        :: proc(dpy: ^xlib.Display, damage: Damage) ---
	XDamageSubtract       :: proc(dpy: ^xlib.Display, damage: Damage, repair, parts: xlib.XID) ---
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------
@(private) PICT_OP_SRC  :: 1
@(private) PICT_OP_OVER :: 3

@(private) PICT_STANDARD_ARGB32 :: 0
@(private) PICT_STANDARD_A8     :: 2

@(private) CP_REPEAT         :: 1 << 0
@(private) CP_SUBWINDOW_MODE :: 1 << 8
@(private) INCLUDE_INFERIORS :: 1
@(private) REPEAT_PAD        :: 2

@(private)
XRenderDirectFormat :: struct {
	red, red_mask:     i16,
	green, green_mask: i16,
	blue, blue_mask:   i16,
	alpha, alpha_mask: i16,
}

@(private)
XRenderPictFormat :: struct {
	id:       PictFormat,
	type:     i32,
	depth:    i32,
	direct:   XRenderDirectFormat,
	colormap: xlib.Colormap,
}

@(private)
XRenderPictureAttributes :: struct {
	repeat:             i32,
	alpha_map:          Picture,
	alpha_x_origin:     i32,
	alpha_y_origin:     i32,
	clip_x_origin:      i32,
	clip_y_origin:      i32,
	clip_mask:          xlib.Pixmap,
	graphics_exposures: b32,
	subwindow_mode:     i32,
	poly_edge:          i32,
	poly_mode:          i32,
	dither:             xlib.Atom,
	component_alpha:    b32,
}

// Premultiplied, 16 bits per channel.
@(private) XRenderColor :: struct { red, green, blue, alpha: u16 }

@(private) XFixed :: i32
@(private) XTransform :: struct { m: [3][3]XFixed }

foreign import xrender "system:Xrender"
@(default_calling_convention="c", private)
foreign xrender {
	XRenderQueryExtension      :: proc(dpy: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---
	XRenderFindVisualFormat    :: proc(dpy: ^xlib.Display, visual: ^xlib.Visual) -> ^XRenderPictFormat ---
	XRenderFindStandardFormat  :: proc(dpy: ^xlib.Display, format: i32) -> ^XRenderPictFormat ---
	XRenderCreatePicture       :: proc(dpy: ^xlib.Display, drawable: xlib.Drawable, format: ^XRenderPictFormat, valuemask: uint, attributes: ^XRenderPictureAttributes) -> Picture ---
	XRenderChangePicture       :: proc(dpy: ^xlib.Display, picture: Picture, valuemask: uint, attributes: ^XRenderPictureAttributes) ---
	XRenderFreePicture         :: proc(dpy: ^xlib.Display, picture: Picture) ---
	XRenderComposite           :: proc(dpy: ^xlib.Display, op: i32, src, mask, dst: Picture, src_x, src_y, mask_x, mask_y, dst_x, dst_y: i32, width, height: u32) ---
	XRenderCreateSolidFill     :: proc(dpy: ^xlib.Display, color: ^XRenderColor) -> Picture ---
	XRenderFillRectangle       :: proc(dpy: ^xlib.Display, op: i32, dst: Picture, color: ^XRenderColor, x, y: i32, width, height: u32) ---
	XRenderSetPictureTransform :: proc(dpy: ^xlib.Display, picture: Picture, transform: ^XTransform) ---
	XRenderSetPictureFilter    :: proc(dpy: ^xlib.Display, picture: Picture, filter: cstring, params: [^]XFixed, nparams: i32) ---
}

// ---------------------------------------------------------------------------
// SHAPE (tx binds the calls that set shapes)
// ---------------------------------------------------------------------------
@(private) SHAPE_BOUNDING :: 0
@(private) SHAPE_INPUT    :: 2
@(private) SHAPE_SET      :: 0
@(private) SHAPE_SUBTRACT :: 3

foreign import xext_shape "system:Xext"
@(default_calling_convention="c", private)
foreign xext_shape {
	XShapeGetRectangles :: proc(dpy: ^xlib.Display, window: xlib.Window, kind: i32, count: ^i32, ordering: ^i32) -> [^]xlib.XRectangle ---
}
