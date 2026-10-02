package config

import "core:strconv"
import "core:strings"

// Icons an area may have (workspaces.N.icon): Tabler glyphs of the bar's icon
// font (bar.iconFontFile), by their Tabler names. The area toast shows the
// icon before the name, the bar's area dots turn into it, and Settings →
// Areas offers them. "U+EAC1" names any other glyph of the font.
Area_Icon :: struct {
	name: string,
	cp:   rune,
}

@(rodata)
AREA_ICONS := []Area_Icon{
	{"home", 0xEAC1}, {"briefcase", 0xEA46}, {"code", 0xEA77}, {"terminal-2", 0xEBEF}, {"world", 0xEB54},
	{"mail", 0xEAE5}, {"message-circle", 0xEAED}, {"brand-discord", 0xECE3}, {"music", 0xEAFC}, {"headphones", 0xEABD},
	{"movie", 0xEAFA}, {"device-tv", 0xEA8D}, {"photo", 0xEB0A}, {"camera", 0xEA54}, {"palette", 0xEB01},
	{"brush", 0xEBB8}, {"pencil", 0xEB04}, {"notebook", 0xEB96}, {"book", 0xEA39}, {"school", 0xECF7},
	{"file-text", 0xEAA2}, {"folder", 0xEAAD}, {"chart-bar", 0xEA59}, {"calculator", 0xEB80}, {"calendar", 0xEA53},
	{"clock", 0xEA70}, {"device-gamepad-2", 0xF1D2}, {"brand-steam", 0xED6F}, {"sword", 0xF030}, {"puzzle", 0xEB10},
	{"rocket", 0xEC45}, {"flask", 0xEBD2}, {"bug", 0xEA48}, {"database", 0xEA88}, {"server", 0xEB1F},
	{"cloud", 0xEA76}, {"settings", 0xEB20}, {"tool", 0xEB40}, {"shopping-cart", 0xEB25}, {"coffee", 0xEF0E},
	{"heart", 0xEABE}, {"star", 0xEB2E}, {"flame", 0xEC2C}, {"leaf", 0xED4F}, {"moon", 0xEAF8},
	{"sun", 0xEB30}, {"bolt", 0xEA38}, {"user", 0xEB4D}, {"users", 0xEBF2}, {"lock", 0xEAE2},
	{"download", 0xEA96}, {"device-desktop", 0xEA89}, {"layout-grid", 0xEDBA}, {"brand-youtube", 0xEC90}, {"brand-spotify", 0xED03},
	{"brand-github", 0xEC1C}, {"brand-firefox", 0xECFD}, {"brand-chrome", 0xEC18}, {"ghost", 0xEB8E}, {"paw", 0xEFF9},
	{"plant", 0xED50}, {"pizza", 0xEDBB}, {"run", 0xEC82}, {"barbell", 0xEFF0}, {"car", 0xEBBB},
	{"plane", 0xEB6F}, {"map-pin", 0xEAE8}, {"video", 0xED22}, {"microphone", 0xEAF0}, {"news", 0xEAFD},
}

// The glyph of an area icon name ("" or an unknown name: none).
area_icon_rune :: proc(name: string) -> (rune, bool) {
	n := strings.trim_space(name)
	if n == "" { return 0, false }
	for a in AREA_ICONS { if a.name == n { return a.cp, true } }
	if len(n) > 2 && (strings.has_prefix(n, "U+") || strings.has_prefix(n, "u+")) {
		if v, ok := strconv.parse_uint(n[2:], 16); ok && v > 0 && v < 0x110000 { return rune(v), true }
	}
	return 0, false
}

// The icon of area `index`, if it has one.
workspace_icon :: proc(cfg: ^Config, index: int) -> (rune, bool) {
	ws, known := workspace(cfg, index)
	if !known { return 0, false }
	return area_icon_rune(ws.icon)
}
