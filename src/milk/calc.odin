// The launcher's calculator (launcher.odin): an arithmetic expression typed
// into the milk tab ("2*(3+4)", "sqrt 2", "15% * 80", "2^10", "pi/4") is
// worked out and the result offered to copy. Numbers take "." or "," as the
// decimal point; % after a number is a percentage, between two numbers the
// remainder; the functions take radians.
package milk

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

@(private="file")
Calc :: struct {
	s:   string,
	i:   int,
	ops: int, // operators and functions seen: a lone number is no calculation
	err: bool,
}

// The value of `expr`, when it is a calculation.
calculate :: proc(expr: string) -> (value: f64, ok: bool) {
	text := strings.trim_space(expr)
	if strings.has_prefix(text, "=") { text = strings.trim_space(text[1:]) }
	if text == "" || len(text) > 512 { return 0, false }
	// "1,5" is 1.5; with both, "1.234,5" (Portuguese) and "1,234.5" (English).
	dot, comma := strings.last_index_byte(text, '.'), strings.last_index_byte(text, ',')
	if comma >= 0 {
		if dot >= 0 && dot > comma {
			text, _ = strings.remove_all(text, ",", context.temp_allocator)
		} else {
			if dot >= 0 { text, _ = strings.remove_all(text, ".", context.temp_allocator) }
			text, _ = strings.replace_all(text, ",", ".", context.temp_allocator)
		}
	}
	p := Calc{s = text}
	value = sum(&p)
	skip_space(&p)
	if p.err || p.i != len(p.s) || p.ops == 0 || math.is_nan(value) || math.is_inf(value) { return 0, false }
	return value, true
}

// The result as the language writes it: up to 12 significant digits.
format_number :: proc(v: f64, decimal_comma: bool, allocator := context.temp_allocator) -> string {
	if v == math.trunc(v) && abs(v) < 1e15 { return fmt.aprintf("%d", i64(v), allocator = allocator) }
	s := fmt.tprintf("%.12g", v)
	if strings.contains_any(s, "eE") {
		// Keep the exponent, trim the mantissa.
		return strings.clone(decimal_comma ? replace_dot(s) : s, allocator)
	}
	if strings.index_byte(s, '.') >= 0 { s = strings.trim_right(s, "0"); s = strings.trim_right(s, ".") }
	return strings.clone(decimal_comma ? replace_dot(s) : s, allocator)
}

@(private="file")
replace_dot :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, ".", ",", context.temp_allocator)
	return out
}

@(private="file")
skip_space :: proc(p: ^Calc) {
	for p.i < len(p.s) && (p.s[p.i] == ' ' || p.s[p.i] == '\t') { p.i += 1 }
}

// The next character (a rune: ×, ÷, √, π), without taking it.
@(private="file")
peek :: proc(p: ^Calc) -> (r: rune, size: int) {
	skip_space(p)
	if p.i >= len(p.s) { return 0, 0 }
	return utf8.decode_rune_in_string(p.s[p.i:])
}

@(private="file")
sum :: proc(p: ^Calc) -> f64 {
	v := product(p)
	for !p.err {
		r, n := peek(p)
		switch r {
		case '+':
			p.i += n; p.ops += 1
			v += product(p)
		case '-', '−':
			p.i += n; p.ops += 1
			v -= product(p)
		case:
			return v
		}
	}
	return v
}

@(private="file")
product :: proc(p: ^Calc) -> f64 {
	v := power(p)
	for !p.err {
		r, n := peek(p)
		switch r {
		case '*', '×', '·':
			p.i += n; p.ops += 1
			v *= power(p)
		case '/', '÷', ':':
			p.i += n; p.ops += 1
			v /= power(p)
		case '%':
			// Between two values the remainder (a percentage was taken by postfix).
			p.i += n; p.ops += 1
			d := power(p)
			v = math.mod(v, d)
		case '(', 'a' ..= 'z', 'A' ..= 'Z', 'π', '√':
			// "2pi", "3(4+1)": multiplication.
			p.ops += 1
			v *= power(p)
		case:
			return v
		}
	}
	return v
}

// Right-associative: 2^3^2 = 2^9.
@(private="file")
power :: proc(p: ^Calc) -> f64 {
	v := unary(p)
	r, n := peek(p)
	if r == '^' {
		p.i += n; p.ops += 1
		return math.pow(v, power(p))
	}
	if r == '*' && p.i + 1 < len(p.s) && p.s[p.i + 1] == '*' {
		p.i += 2; p.ops += 1
		return math.pow(v, power(p))
	}
	return v
}

@(private="file")
unary :: proc(p: ^Calc) -> f64 {
	r, n := peek(p)
	switch r {
	case '-', '−':
		p.i += n
		return -unary(p)
	case '+':
		p.i += n
		return unary(p)
	}
	return postfix(p)
}

@(private="file")
postfix :: proc(p: ^Calc) -> f64 {
	v := primary(p)
	for !p.err {
		r, n := peek(p)
		switch r {
		case '%':
			// A percentage when no value follows ("15%", "15% * 80").
			save := p.i
			p.i += n
			next, _ := peek(p)
			if next == 0 || next == ')' || strings.contains_rune("+-−*×·/÷^", next) {
				p.ops += 1
				v /= 100
				continue
			}
			p.i = save
			return v
		case '!':
			p.i += n; p.ops += 1
			if v < 0 || v > 170 || v != math.trunc(v) { p.err = true; return 0 }
			f: f64 = 1
			for k in 2 ..= int(v) { f *= f64(k) }
			v = f
		case:
			return v
		}
	}
	return v
}

@(private="file")
primary :: proc(p: ^Calc) -> f64 {
	r, n := peek(p)
	switch {
	case r == '(':
		p.i += n
		v := sum(p)
		close, cn := peek(p)
		if close == ')' { p.i += cn } // an unclosed one closes at the end
		return v
	case r >= '0' && r <= '9' || r == '.':
		start := p.i
		for p.i < len(p.s) && (p.s[p.i] >= '0' && p.s[p.i] <= '9' || p.s[p.i] == '.') { p.i += 1 }
		// An exponent: 1e3, 2.5E-4.
		if p.i < len(p.s) && (p.s[p.i] == 'e' || p.s[p.i] == 'E') {
			j := p.i + 1
			if j < len(p.s) && (p.s[j] == '+' || p.s[j] == '-') { j += 1 }
			if j < len(p.s) && p.s[j] >= '0' && p.s[j] <= '9' {
				p.i = j
				for p.i < len(p.s) && p.s[p.i] >= '0' && p.s[p.i] <= '9' { p.i += 1 }
			}
		}
		v, ok := strconv.parse_f64(p.s[start:p.i])
		if !ok { p.err = true }
		return v
	case r == 'π':
		p.i += n
		return math.PI
	case r == '√':
		p.i += n; p.ops += 1
		return math.sqrt(postfix(p))
	case unicode.is_letter(r):
		start := p.i
		for p.i < len(p.s) {
			c := p.s[p.i]
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') { break }
			p.i += 1
		}
		name := strings.to_lower(p.s[start:p.i], context.temp_allocator)
		switch name {
		case "pi":  return math.PI
		case "tau": return math.TAU
		case "e":   return math.E
		}
		arg := unary(p) // "sqrt 2", "sin(pi/2)"
		p.ops += 1
		switch name {
		case "sqrt", "raiz":     return math.sqrt(arg)
		case "cbrt":             return math.cbrt(arg)
		case "abs":              return abs(arg)
		case "round":            return math.round(arg)
		case "floor":            return math.floor(arg)
		case "ceil":             return math.ceil(arg)
		case "sin", "sen":       return math.sin(arg)
		case "cos":              return math.cos(arg)
		case "tan", "tg":        return math.tan(arg)
		case "asin":             return math.asin(arg)
		case "acos":             return math.acos(arg)
		case "atan":             return math.atan(arg)
		case "ln":               return math.ln(arg)
		case "log":              return math.log10(arg)
		case "log2":             return math.log2(arg)
		case "exp":              return math.exp(arg)
		}
		p.err = true
		return 0
	}
	p.err = true
	return 0
}
