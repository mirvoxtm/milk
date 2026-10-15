package display

import "core:fmt"
import "core:strings"

// What an EDID says about a monitor: who made it ("DEL"), the product code,
// the serial (the text descriptor when there is one, else the number) and
// the model name ("DELL U2415").
Edid :: struct {
	maker:   string,
	product: u16,
	serial:  string,
	name:    string,
}

// Parse the base EDID block; ok = false when it is not one.
parse_edid :: proc(data: []u8, allocator := context.allocator) -> (e: Edid, ok: bool) {
	HEADER :: [8]u8{0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00}
	if len(data) < 128 { return }
	header := HEADER
	for b, i in header { if data[i] != b { return } }
	v := u16(data[8]) << 8 | u16(data[9])
	letters := [3]u8{u8((v >> 10) & 31) + '@', u8((v >> 5) & 31) + '@', u8(v & 31) + '@'}
	for l in letters { if l < 'A' || l > 'Z' { return } }
	e.maker = strings.clone(string(letters[:]), allocator)
	e.product = u16(data[10]) | u16(data[11]) << 8
	number := u32(data[12]) | u32(data[13]) << 8 | u32(data[14]) << 16 | u32(data[15]) << 24
	// The four 18-byte descriptors: 0xFC is the name, 0xFF the serial as text.
	for d := 54; d + 18 <= 126; d += 18 {
		if data[d] != 0 || data[d + 1] != 0 || data[d + 2] != 0 { continue } // a timing, not a descriptor
		text := descriptor_text(data[d + 5:d + 18])
		switch data[d + 3] {
		case 0xfc: if text != "" && e.name == "" { e.name = strings.clone(text, allocator) }
		case 0xff: if text != "" && e.serial == "" { e.serial = strings.clone(text, allocator) }
		}
	}
	if e.serial == "" && number != 0 { e.serial = fmt.aprintf("%08X", number, allocator = allocator) }
	return e, true
}

// A descriptor's text: up to 13 bytes ended by a line feed, padded with spaces.
@(private="file")
descriptor_text :: proc(b: []u8) -> string {
	n := 0
	for n < len(b) && b[n] != 0x0a && b[n] != 0 { n += 1 }
	s := strings.trim_space(string(b[:n]))
	for ch in s { if ch < 0x20 || ch > 0x7e { return "" } }
	return s
}

// The monitor's identity in profiles: "DEL-A0F3-3132" (serial left out when
// it has none).
edid_identity :: proc(e: Edid, allocator := context.allocator) -> string {
	if e.serial == "" { return fmt.aprintf("%s-%04X", e.maker, e.product, allocator = allocator) }
	return fmt.aprintf("%s-%04X-%s", e.maker, e.product, e.serial, allocator = allocator)
}

destroy_edid :: proc(e: ^Edid) {
	delete(e.maker)
	delete(e.serial)
	delete(e.name)
	e^ = {}
}
