// Icons: Tabler glyphs from Noctalia's icon font (name → codepoint through
// tabler.json), falling back to a Nerd Font and finally to plain Unicode
// symbols; plus the launcher: milk's logo (the Tabler "milk" glyph on an
// accent circle, as in the setup wizard) or an image the user configured
// (SVG through rsvg-convert, or PNG).
package bar

import "core:encoding/json"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import tx "../tx"

Icon :: enum {
	Apps,
	Media_Idle,
	Play,
	Pause,
	Bell,
	Clipboard,
	Wifi_0,
	Wifi_1,
	Wifi_2,
	Wifi_3,
	Wifi_Off,
	Ethernet,
	Bluetooth,
	Bluetooth_Off,
	Bluetooth_Connected,
	Volume_High,
	Volume_Low,
	Volume_Zero,
	Volume_Muted,
	Sun,
	Battery_0,
	Battery_1,
	Battery_2,
	Battery_3,
	Battery_4,
	Battery_Charging,
	Power,
	Settings,
	Lock,
	Refresh,
	Headphones,
	Keyboard,
	Mouse,
	Phone,
	Laptop,
	Speaker,
	Gamepad,
	Watch,
	Milk,
}

// Tabler icon names (keys of tabler.json).
TABLER_NAMES := [Icon]string{
	.Apps                = "apps",
	.Media_Idle          = "circle-off",
	.Play                = "player-play",
	.Pause               = "player-pause",
	.Bell                = "bell",
	.Clipboard           = "clipboard",
	.Wifi_0              = "wifi-0",
	.Wifi_1              = "wifi-1",
	.Wifi_2              = "wifi-2",
	.Wifi_3              = "wifi",
	.Wifi_Off            = "wifi-off",
	.Ethernet            = "ethernet",
	.Bluetooth           = "bluetooth",
	.Bluetooth_Off       = "bluetooth-off",
	.Bluetooth_Connected = "bluetooth-connected",
	.Volume_High         = "volume",
	.Volume_Low          = "volume-2",
	.Volume_Zero         = "volume-3",
	.Volume_Muted        = "volume-off",
	.Sun                 = "sun",
	.Battery_0           = "battery",
	.Battery_1           = "battery-1",
	.Battery_2           = "battery-2",
	.Battery_3           = "battery-3",
	.Battery_4           = "battery-4",
	.Battery_Charging    = "battery-charging",
	.Power               = "power",
	.Settings            = "settings",
	.Lock                = "lock",
	.Refresh             = "refresh",
	.Headphones          = "headphones",
	.Keyboard            = "keyboard",
	.Mouse               = "mouse",
	.Phone               = "device-mobile",
	.Laptop              = "device-laptop",
	.Speaker             = "device-speaker",
	.Gamepad             = "device-gamepad-2",
	.Watch               = "device-watch",
	.Milk                = "milk",
}

// Codepoints of the names above in noctalia-tabler.ttf, used when tabler.json is missing.
TABLER_DEFAULTS := [Icon]rune{
	.Apps = 0xEBB6, .Media_Idle = 0xEE40, .Play = 0xED46, .Pause = 0xED45, .Bell = 0xEA35,
	.Clipboard = 0xEA6F, .Wifi_0 = 0xEBA3, .Wifi_1 = 0xEBA4, .Wifi_2 = 0xEBA5,
	.Wifi_3 = 0xEB52, .Wifi_Off = 0xECFA, .Ethernet = 0xECCC, .Bluetooth = 0xEA37,
	.Bluetooth_Off = 0xECEB, .Bluetooth_Connected = 0xECEA, .Volume_High = 0xEB51,
	.Volume_Low = 0xEB4F, .Volume_Zero = 0xEB50, .Volume_Muted = 0xF1C3, .Sun = 0xEB30,
	.Battery_0 = 0xEA34, .Battery_1 = 0xEA2F, .Battery_2 = 0xEA30, .Battery_3 = 0xEA31,
	.Battery_4 = 0xEA32, .Battery_Charging = 0xEA33, .Power = 0xEB0D, .Settings = 0xEB20,
	.Lock = 0xEAE2, .Refresh = 0xEB13, .Headphones = 0xEABD, .Keyboard = 0xEBD6, .Mouse = 0xEAF9,
	.Phone = 0xEA8A, .Laptop = 0xEB64, .Speaker = 0xEA8B, .Gamepad = 0xF1D2, .Watch = 0xEBF9,
	.Milk = 0xEF13,
}

// Nerd Font (Material Design range) equivalents.
NERD_CODEPOINTS := [Icon]rune{
	.Apps = 0xF003B, .Media_Idle = 0xF075B, .Play = 0xF040A, .Pause = 0xF03E4, .Bell = 0xF009C,
	.Clipboard = 0xF014C, .Wifi_0 = 0xF091F, .Wifi_1 = 0xF0922, .Wifi_2 = 0xF0925,
	.Wifi_3 = 0xF0928, .Wifi_Off = 0xF05AA, .Ethernet = 0xF0200, .Bluetooth = 0xF00AF,
	.Bluetooth_Off = 0xF00B2, .Bluetooth_Connected = 0xF00B1, .Volume_High = 0xF057E,
	.Volume_Low = 0xF0580, .Volume_Zero = 0xF057F, .Volume_Muted = 0xF075F, .Sun = 0xF05A8,
	.Battery_0 = 0xF008E, .Battery_1 = 0xF007C, .Battery_2 = 0xF007E, .Battery_3 = 0xF0080,
	.Battery_4 = 0xF0079, .Battery_Charging = 0xF0084, .Power = 0xF0425, .Settings = 0xF0493,
	.Lock = 0xF033E, .Refresh = 0xF0450, .Headphones = 0xF02CB, .Keyboard = 0xF030C, .Mouse = 0xF037D,
	.Phone = 0xF011C, .Laptop = 0xF0322, .Speaker = 0xF04C3, .Gamepad = 0xF0297, .Watch = 0xF05A9,
	.Milk = 0xF0176,
}

// Last resort: Unicode symbols, alternatives separated by '|'.
UNICODE_SYMBOLS := [Icon]string{
	.Apps = "☰|≡", .Media_Idle = "⊘|○", .Play = "▶|>", .Pause = "⏸|‖", .Bell = "🔔|✉|!",
	.Clipboard = "📋|⎘|❐", .Wifi_0 = "📶|⇅", .Wifi_1 = "📶|⇅", .Wifi_2 = "📶|⇅",
	.Wifi_3 = "📶|⇅", .Wifi_Off = "⨯|×|x", .Ethernet = "⇄|↔|=", .Bluetooth = "ᛒ|B",
	.Bluetooth_Off = "ᛒ|b", .Bluetooth_Connected = "ᛒ|B", .Volume_High = "🔊|♪",
	.Volume_Low = "🔉|♪", .Volume_Zero = "🔈|♪", .Volume_Muted = "🔇|×|x", .Sun = "☀|☼|*",
	.Battery_0 = "🔋|▯", .Battery_1 = "🔋|▮", .Battery_2 = "🔋|▮", .Battery_3 = "🔋|▮",
	.Battery_4 = "🔋|▮", .Battery_Charging = "⚡|+", .Power = "⏻|⏼|○", .Settings = "⚙|☸|*",
	.Lock = "🔒|⚿|#", .Refresh = "⟳|↻|@", .Headphones = "🎧|♫", .Keyboard = "⌨|K", .Mouse = "🖱|M",
	.Phone = "📱|▯", .Laptop = "💻|▭", .Speaker = "🔈|♪", .Gamepad = "🎮|G", .Watch = "⌚|◷",
	.Milk = "🥛|m",
}

SYMBOL_FONTS :: []string{"Noto Sans Symbols 2", "Noto Sans Symbols", "DejaVu Sans"}

// A resolved glyph: the font that has it and its ink box (for centring).
Glyph :: struct {
	font:    ^tx.Font, // owned by Icon_Set.fonts
	text:    string,
	ok:      bool,
	advance: i32, // layout width: the font advance, widened to the ink (Nerd icons overflow their cell)
	dx:      i32, // origin offset inside the box (centres overflowing ink, else 0)
	ink_y:   i32, // distance from the baseline up to the top of the ink
	ink_h:   i32,
	ink_x:   i32, // left edge of the ink relative to the drawing origin
	ink_w:   i32,
}

Icon_Set :: struct {
	fonts:  [dynamic]^tx.Font,
	glyphs: [Icon]Glyph,
}

@(private)
destroy_icons :: proc(b: ^Bar) {
	for &g in b.icons.glyphs {
		delete(g.text)
		g = {}
	}
	for f in b.icons.fonts { tx.font_close(b.c, f) }
	delete(b.icons.fonts)
	b.icons.fonts = nil
}

@(private)
resolve_icons :: proc(b: ^Bar) {
	opts := &b.cfg.bar
	size := i32(opts.icon_size)
	set := &b.icons

	tabler: ^tx.Font
	codepoints := TABLER_DEFAULTS
	if opts.icon_font_file != "" {
		if os.exists(opts.icon_font_file) {
			if f, ok := tx.font_open_file(b.c, opts.icon_font_file, size); ok {
				tabler = f
				append(&set.fonts, f)
				load_tabler_map(opts.icon_font_file, &codepoints)
			}
		} else {
			log.warnf("Bar icon font %q not found; using fallback icons", opts.icon_font_file)
		}
	}

	nerd: ^tx.Font
	nerd_tried := false
	symbols: [dynamic]^tx.Font
	symbols.allocator = context.temp_allocator
	symbols_tried := false
	used_tabler, used_nerd, used_symbols, missing := 0, 0, 0, 0

	for icon in Icon {
		if tabler != nil && tx.font_has_glyph(b.c, tabler, codepoints[icon]) {
			set_glyph(b, icon, tabler, rune_string(codepoints[icon]))
			used_tabler += 1
			continue
		}
		if !nerd_tried {
			nerd_tried = true
			nerd = open_nerd_font(b, size)
			if nerd != nil { append(&set.fonts, nerd) }
		}
		if nerd != nil && tx.font_has_glyph(b.c, nerd, NERD_CODEPOINTS[icon]) {
			set_glyph(b, icon, nerd, rune_string(NERD_CODEPOINTS[icon]))
			used_nerd += 1
			continue
		}
		if !symbols_tried {
			symbols_tried = true
			for family in SYMBOL_FONTS {
				if f, ok := tx.font_open(b.c, family, size); ok {
					append(&set.fonts, f)
					append(&symbols, f)
				}
			}
			append(&symbols, b.font)
		}
		found := false
		candidates: for candidate in strings.split(UNICODE_SYMBOLS[icon], "|", context.temp_allocator) {
			for f in symbols {
				if font_has_text(b, f, candidate) {
					set_glyph(b, icon, f, candidate)
					found = true
					break candidates
				}
			}
		}
		if found { used_symbols += 1 } else { missing += 1 }
	}
	if used_tabler < len(Icon) {
		log.infof("Bar icons: %d Tabler, %d Nerd Font, %d Unicode, %d missing", used_tabler, used_nerd, used_symbols, missing)
	}
}

@(private)
set_glyph :: proc(b: ^Bar, icon: Icon, font: ^tx.Font, text: string) {
	ext := tx.text_extents(b.c, font, text)
	advance, ink_w := i32(ext.xOff), i32(ext.width)
	dx: i32
	if ink_w > advance {
		// Wider than its cell (icons in monospace Nerd Fonts): centre the ink
		// in a box as wide as the ink (XGlyphInfo.x is the negated left bearing).
		dx = i32(ext.x)
		advance = ink_w
	}
	b.icons.glyphs[icon] = Glyph{
		font    = font,
		text    = strings.clone(text),
		ok      = true,
		advance = advance,
		dx      = dx,
		ink_y   = i32(ext.y),
		ink_h   = i32(ext.height),
		ink_x   = -i32(ext.x), // XGlyphInfo.x is the negated left bearing
		ink_w   = ink_w,
	}
}

@(private)
font_has_text :: proc(b: ^Bar, f: ^tx.Font, s: string) -> bool {
	if f == nil || s == "" { return false }
	for r in s {
		if !tx.font_has_glyph(b.c, f, r) { return false }
	}
	return true
}

@(private)
rune_string :: proc(r: rune) -> string {
	bytes, n := utf8.encode_rune(r)
	return strings.clone(string(bytes[:n]), context.temp_allocator)
}

// The configured Nerd Font pattern may be a ':'-separated family list (not a
// valid fontconfig pattern); try it as-is, then each family on its own.
@(private)
open_nerd_font :: proc(b: ^Bar, size: i32) -> ^tx.Font {
	probe := NERD_CODEPOINTS[.Bell]
	candidates := make([dynamic]string, context.temp_allocator)
	pattern := b.cfg.bar.icon_font
	if pattern != "" {
		append(&candidates, pattern)
		for part in strings.split(pattern, ":", context.temp_allocator) {
			family := strings.trim_space(part)
			if family != "" && family != pattern && !strings.contains(family, "=") { append(&candidates, family) }
		}
	}
	append(&candidates, "Symbols Nerd Font", "Symbols Nerd Font Mono")
	for candidate in candidates {
		f, ok := tx.font_open(b.c, candidate, size)
		if !ok { continue }
		if tx.font_has_glyph(b.c, f, probe) { return f }
		tx.font_close(b.c, f)
	}
	return nil
}

// Read "name": {"codepoint": "U+XXXX"} entries for the icons we use.
@(private)
load_tabler_map :: proc(font_file: string, out: ^[Icon]rune) {
	path := strings.concatenate({os.dir(font_file), "/tabler.json"}, context.temp_allocator)
	if !os.exists(path) { return }
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { return }
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)
	data, err := os.read_entire_file(path, scratch)
	if err != nil { return }
	value, perr := json.parse(data, .JSON, false, scratch)
	if perr != .None {
		log.warnf("Could not parse %s: %v", path, perr)
		return
	}
	root, is_obj := value.(json.Object)
	if !is_obj { return }
	for icon in Icon {
		entry, found := root[TABLER_NAMES[icon]].(json.Object)
		if !found { continue }
		cp, is_str := entry["codepoint"].(json.String)
		if !is_str || !strings.has_prefix(cp, "U+") { continue }
		if v, ok := strconv.parse_uint(cp[2:], 16); ok && v > 0 && v < 0x110000 { out[icon] = rune(v) }
	}
}

// The launcher: milk's logo when bar.launcherIcon is empty (null) or "milk";
// otherwise the configured image (the logo again if it cannot be loaded).
@(private)
load_launcher :: proc(b: ^Bar) {
	if b.has_launcher { tx.image_destroy(&b.launcher) }
	b.has_launcher = false
	path := strings.trim_space(b.cfg.bar.launcher_icon)
	if path != "" && path != "milk" { load_launcher_image(b, path) }
	if !b.has_launcher { load_logo(b) }
}

// milk's logo: the Tabler "milk" glyph at ~60 % of the circle, from the icon
// font file; without it the circle shows an "m" in the text font.
@(private)
load_logo :: proc(b: ^Bar) {
	d := launcher_size(b)
	glyph := &b.icons.glyphs[.Milk]
	file := b.cfg.bar.icon_font_file
	if glyph.ok && file != "" && os.exists(file) {
		if f, ok := tx.font_open_file(b.c, file, max(8, i32(f32(d) * 0.6 + 0.5))); ok {
			r, _ := utf8.decode_rune_in_string(glyph.text)
			if tx.font_has_glyph(b.c, f, r) {
				b.logo_font = f
				b.logo_text = glyph.text
				return
			}
			tx.font_close(b.c, f)
		}
	}
	b.logo_text = "m"
}

@(private)
load_launcher_image :: proc(b: ^Bar, path: string) {
	size := launcher_size(b)
	if !os.exists(path) {
		log.warnf("Bar launcher icon %q not found; using milk's logo", path)
		return
	}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { return }
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)

	data: []u8
	ext := strings.to_lower(os.ext(path), context.temp_allocator)
	switch ext {
	case ".svg", ".svgz":
		if !b.tools.rsvg_convert {
			log.warnf("rsvg-convert is not installed; cannot render %q", path)
			return
		}
		n := fmt.tprintf("%d", size)
		state, stdout, _, err := os.process_exec(os.Process_Desc{command = {"rsvg-convert", "-a", "-w", n, "-h", n, path}}, scratch)
		if err != nil || !state.success || len(stdout) == 0 {
			log.warnf("rsvg-convert failed for %q", path)
			return
		}
		data = stdout
	case ".png":
		bytes, err := os.read_entire_file(path, scratch)
		if err != nil { return }
		data = bytes
	case:
		log.warnf("Unsupported launcher icon format %q (use SVG or PNG)", path)
		return
	}
	img, err := png.load_from_bytes(data, {.alpha_add_if_missing}, scratch)
	if err != nil || img == nil {
		log.warnf("Could not decode launcher icon %q: %v", path, err)
		return
	}
	src, ok := image_to_rgba(img, scratch)
	if !ok { return }
	b.launcher = fit_image(src, size)
	b.has_launcher = true
}

@(private)
launcher_size :: proc(b: ^Bar) -> i32 {
	return clamp(i32(b.cfg.bar.icon_size) + 5, 8, i32(b.cfg.bar.height) - 4)
}

// core:image result (1-4 channels, 8 or 16 bits) → straight-alpha RGBA8.
@(private)
image_to_rgba :: proc(img: ^image.Image, allocator := context.allocator) -> (tx.Image, bool) {
	if img.width <= 0 || img.height <= 0 || img.channels < 1 || img.channels > 4 { return {}, false }
	if img.depth != 8 && img.depth != 16 { return {}, false }
	out := tx.image_make(i32(img.width), i32(img.height), allocator)
	px := img.pixels.buf[:]
	bpc := img.depth / 8
	n := img.width * img.height
	if len(px) < n * img.channels * bpc { return out, false }
	// 16-bit samples are stored in native (little-endian) order: keep the high byte.
	sample :: proc(px: []u8, index, bpc: int) -> u8 {
		return px[index] if bpc == 1 else px[index * 2 + 1]
	}
	for i in 0 ..< n {
		base := i * img.channels
		r, g, bl, a: u8
		switch img.channels {
		case 1: r = sample(px, base, bpc); g = r; bl = r; a = 255
		case 2: r = sample(px, base, bpc); g = r; bl = r; a = sample(px, base + 1, bpc)
		case 3: r = sample(px, base, bpc); g = sample(px, base + 1, bpc); bl = sample(px, base + 2, bpc); a = 255
		case 4: r = sample(px, base, bpc); g = sample(px, base + 1, bpc); bl = sample(px, base + 2, bpc); a = sample(px, base + 3, bpc)
		}
		out.rgba[i * 4] = r
		out.rgba[i * 4 + 1] = g
		out.rgba[i * 4 + 2] = bl
		out.rgba[i * 4 + 3] = a
	}
	return out, true
}

// Scale an image to fit a size×size box (aspect ratio kept, centred).
@(private)
fit_image :: proc(src: tx.Image, size: i32, allocator := context.allocator) -> tx.Image {
	if src.w == size && src.h == size {
		out := tx.image_make(size, size, allocator)
		copy(out.rgba, src.rgba)
		return out
	}
	w, h := size, size
	if src.w > src.h { h = max(1, i32(f32(size) * f32(src.h) / f32(src.w) + 0.5)) }
	if src.h > src.w { w = max(1, i32(f32(size) * f32(src.w) / f32(src.h) + 0.5)) }
	scaled := tx.image_resize(src, w, h, context.temp_allocator)
	out := tx.image_make(size, size, allocator)
	ox, oy := (size - w) / 2, (size - h) / 2
	for y in 0 ..< h {
		row_src := int(y) * int(w) * 4
		row_dst := (int(y + oy) * int(size) + int(ox)) * 4
		copy(out.rgba[row_dst:row_dst + int(w) * 4], scaled.rgba[row_src:row_src + int(w) * 4])
	}
	return out
}
