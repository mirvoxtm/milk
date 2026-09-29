package config

import "core:fmt"
import "core:strconv"
import "core:strings"

// json.marshal writes every float with 16 decimals (0.7000000000000000); the
// settings app and the bar's quick settings pass their output through this so
// milk.json keeps short numbers (0.7, 2.4, 1.0).
tidy_json_numbers :: proc(text: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	in_string, escaped := false, false
	for i := 0; i < len(text); {
		ch := text[i]
		if in_string {
			strings.write_byte(&b, ch)
			if escaped {
				escaped = false
			} else if ch == '\\' {
				escaped = true
			} else if ch == '"' {
				in_string = false
			}
			i += 1
			continue
		}
		if ch == '"' {
			in_string = true
			strings.write_byte(&b, ch)
			i += 1
			continue
		}
		if ch != '-' && (ch < '0' || ch > '9') {
			strings.write_byte(&b, ch)
			i += 1
			continue
		}
		j := i + 1
		for j < len(text) && strings.index_byte("0123456789.eE+-", text[j]) >= 0 { j += 1 }
		token := text[i:j]
		i = j
		if strings.index_byte(token, '.') < 0 {
			strings.write_string(&b, token)
			continue
		}
		v, ok := strconv.parse_f64(token)
		if !ok {
			strings.write_string(&b, token)
			continue
		}
		short := fmt.tprintf("%v", v)
		if strings.index_any(short, ".eE") < 0 { short = fmt.tprintf("%s.0", short) }
		strings.write_string(&b, short)
	}
	return strings.to_string(b)
}
