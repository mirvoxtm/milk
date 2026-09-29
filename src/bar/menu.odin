// Pieces shared by the Wi-Fi and Bluetooth menus: hit regions, list rows,
// section headers, inline messages and the text helpers for tool output.
package bar

import "core:strings"
import tx "../tx"

@(private) MENU_WIDTH    :: 340
@(private) MENU_PAD      :: 16
@(private) MENU_HEADER   :: 52
@(private) MENU_ROW      :: 46
@(private) MENU_SECTION  :: 34
@(private) MENU_FIELD    :: 46
@(private) MENU_MESSAGE  :: 44
@(private) MENU_FOOTER   :: 50
@(private) MENU_MAX_ROWS :: 7

@(private)
Menu_Action :: enum {
	None,
	Wifi_Radio, Wifi_Rescan, Wifi_Network, Wifi_Current, Wifi_Disconnect, Wifi_Connect, Wifi_Editor,
	Bt_Power, Bt_Scan, Bt_Device, Bt_Disconnect, Bt_New,
}

@(private)
Menu_Hit :: struct {
	r:      tx.Rect,
	action: Menu_Action,
	index:  int,
}

@(private)
menu_hit_at :: proc(hits: []Menu_Hit, x, y: i32) -> int {
	// Later hits sit on top of earlier ones (a button inside a row).
	for i := len(hits) - 1; i >= 0; i -= 1 {
		if tx.rect_contains(hits[i].r, x, y) { return i }
	}
	return -1
}

// The largest card height that fits between the bar and the far screen edge.
@(private)
menu_max_height :: proc(b: ^Bar) -> i32 {
	mon := tx.monitor_rect(b.c, b.cfg.bar.monitor)
	return max(200, mon.h - bar_rect(b).h - 2 * POPUP_GAP - 16)
}

// Title row with an optional switch on the right; returns the switch rect.
@(private)
paint_menu_header :: proc(pa: ^Card_Painter, title: string, has_switch, on: bool) -> tx.Rect {
	b := pa.b
	paint_text(pa, b.font, MENU_PAD, 2, MENU_HEADER, title, b.theme.foreground)
	sw: tx.Rect
	if has_switch { sw = paint_switch(pa, pa.cv.w - MENU_PAD, 2, MENU_HEADER, on) }
	paint_divider(pa, MENU_PAD, MENU_HEADER, pa.cv.w - 2 * MENU_PAD)
	return sw
}

// Small muted section title with room for a button on the right.
@(private)
paint_menu_section :: proc(pa: ^Card_Painter, y: i32, title: string) {
	paint_text(pa, pa.b.small_font, MENU_PAD, y + 4, MENU_SECTION - 4, title, pa.b.theme.muted)
}

@(private)
paint_menu_message :: proc(pa: ^Card_Painter, y: i32, text: string) {
	b := pa.b
	paint_text_fit(pa, b.font, MENU_PAD, y, MENU_MESSAGE, pa.cv.w - 2 * MENU_PAD, text, b.theme.muted)
}

// A list row: hover highlight, icon, title and an optional second line;
// `right_reserve` pixels on the right stay free for a lock, spinner or button.
@(private)
paint_menu_row :: proc(pa: ^Card_Painter, y: i32, icon: Icon, icon_color: tx.Color, title, subtitle: string, subtitle_color: tx.Color, hovered: bool, right_reserve: i32 = 0) {
	b := pa.b
	th := &b.theme
	row := tx.Rect{8, y + 2, pa.cv.w - 16, MENU_ROW - 4}
	if hovered { tx.canvas_fill_rounded_rect(&pa.cv, row, 12, th.surface) }
	paint_icon(pa, icon, {MENU_PAD, y, 28, MENU_ROW}, icon_color)
	tx0 := i32(MENU_PAD + 38)
	max_w := pa.cv.w - MENU_PAD - tx0 - right_reserve
	if subtitle == "" {
		paint_text_fit(pa, b.font, tx0, y, MENU_ROW, max_w, title, th.foreground)
	} else {
		paint_text_fit(pa, b.font, tx0, y + 4, 22, max_w, title, th.foreground)
		paint_text_fit(pa, b.small_font, tx0, y + 24, 18, max_w, subtitle, subtitle_color)
	}
}

// A small round icon button (rescan) or a spinner while busy.
@(private)
paint_icon_button :: proc(pa: ^Card_Painter, r: tx.Rect, icon: Icon, busy, hovered: bool) {
	th := &pa.b.theme
	if hovered && !busy { tx.canvas_fill_circle(&pa.cv, f32(r.x) + f32(r.w) / 2, f32(r.y) + f32(r.h) / 2, f32(r.w) / 2, th.surface) }
	if busy {
		paint_spinner(pa, f32(r.x) + f32(r.w) / 2, f32(r.y) + f32(r.h) / 2, 7, th.foreground)
	} else {
		paint_icon(pa, icon, r, th.foreground)
	}
}

// ---------------------------------------------------------------------------
// Tool output
// ---------------------------------------------------------------------------

// One `nmcli -t` line: fields separated by ':', with '\:' and '\\' escapes.
@(private)
nm_fields :: proc(line: string, allocator := context.temp_allocator) -> []string {
	fields := make([dynamic]string, allocator)
	sb := strings.builder_make(allocator)
	for i := 0; i < len(line); i += 1 {
		ch := line[i]
		if ch == '\\' && i + 1 < len(line) {
			i += 1
			strings.write_byte(&sb, line[i])
		} else if ch == ':' {
			append(&fields, strings.clone(strings.to_string(sb), allocator))
			strings.builder_reset(&sb)
		} else {
			strings.write_byte(&sb, ch)
		}
	}
	append(&fields, strings.clone(strings.to_string(sb), allocator))
	return fields[:]
}

// Sections of a helper script's output, introduced by "@name" lines.
@(private)
output_section :: proc(output, name: string) -> string {
	marker := strings.concatenate({"@@", name, "\n"}, context.temp_allocator)
	start := strings.index(output, marker)
	if start < 0 { return "" }
	rest := output[start + len(marker):]
	if end := strings.index(rest, "\n@@"); end >= 0 { return rest[:end + 1] }
	return rest
}

// The message worth showing from a failed command: its last meaningful line.
@(private)
error_line :: proc(output: string, fallback: string) -> string {
	lines := strings.split_lines(strings.trim_space(output), context.temp_allocator)
	for i := len(lines) - 1; i >= 0; i -= 1 {
		l := strings.trim_space(lines[i])
		if l == "" { continue }
		l = strings.trim_prefix(l, "Error: ")
		return l
	}
	return fallback
}
