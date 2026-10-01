// The night light's maths, free of X: the colour of a black body at a
// temperature, sunrise and sunset (NOAA's solar calculator), and the
// schedule (how far into the night a moment is). The settings app uses the
// same procedures to show today's times.
package nightlight

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

NEUTRAL_K :: 6500.0 // the screen as it is (sRGB's white point, D65)

// ---------------------------------------------------------------------------
// Colour temperature
// ---------------------------------------------------------------------------

// Linear sRGB of the Planckian locus at `kelvin` (Krystek's rational
// approximation in CIE 1960 UCS, good to 1e-4 between 1000 K and 15000 K).
@(private)
planckian_srgb :: proc(kelvin: f64) -> [3]f64 {
	t := kelvin
	u := (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t * t) / (1 + 8.42420235e-4 * t + 7.08145163e-7 * t * t)
	v := (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t * t) / (1 - 2.89741816e-5 * t + 1.61456053e-7 * t * t)
	x := 3 * u / (2 * u - 8 * v + 4)
	y := 2 * v / (2 * u - 8 * v + 4)
	X, Z := x / y, (1 - x - y) / y
	return {
		 3.2404542 * X - 1.5371385 - 0.4985314 * Z,
		-0.9692660 * X + 1.8760108 + 0.0415560 * Z,
		 0.0556434 * X - 0.2040259 + 1.0572252 * Z,
	}
}

// Gamma ramp multipliers (red, green, blue; the strongest is 1) that turn
// the screen's white into the colour of a black body at `kelvin`, relative to
// 6500 K = {1, 1, 1}. They act on the encoded values the ramps hold, so the
// linear-light white point is encoded with the usual 2.2 power.
whitepoint :: proc(kelvin: f64) -> [3]f64 {
	k := clamp(kelvin, 1000, NEUTRAL_K)
	if k >= NEUTRAL_K - 0.5 { return {1, 1, 1} }
	@(static) ref: [3]f64
	if ref == {} { ref = planckian_srgb(NEUTRAL_K) }
	lin := planckian_srgb(k)
	out: [3]f64
	strongest := 0.0
	for i in 0 ..< 3 {
		out[i] = max(lin[i] / ref[i], 0)
		strongest = max(strongest, out[i])
	}
	if strongest <= 0 { return {1, 0, 0} }
	for i in 0 ..< 3 { out[i] = math.pow(out[i] / strongest, 1 / 2.2) }
	return out
}

// Between two temperatures in mireds (1e6/K), where equal steps look equal.
mired_lerp :: proc(from_k, to_k, t: f64) -> f64 {
	a, b := 1e6 / max(from_k, 1), 1e6 / max(to_k, 1)
	return 1e6 / (a + (b - a) * clamp(t, 0, 1))
}

// ---------------------------------------------------------------------------
// Sunrise and sunset (NOAA, https://gml.noaa.gov/grad/solcalc/)
// ---------------------------------------------------------------------------
Sun_Kind :: enum { Normal, Polar_Day, Polar_Night }

@(private) rad :: #force_inline proc(d: f64) -> f64 { return d * math.PI / 180 }
@(private) deg :: #force_inline proc(r: f64) -> f64 { return r * 180 / math.PI }

// Julian day at 0h UTC of a Gregorian date.
julian_day :: proc(year, month, day: int) -> f64 {
	y, m := year, month
	if m <= 2 {
		y -= 1
		m += 12
	}
	a := int(math.floor(f64(y) / 100))
	b := 2 - a + int(math.floor(f64(a) / 4))
	return math.floor(365.25 * f64(y + 4716)) + math.floor(30.6001 * f64(m + 1)) + f64(day) + f64(b) - 1524.5
}

// Days from 1970-01-01 to a Gregorian date (Howard Hinnant's days_from_civil).
days_from_civil :: proc(year, month, day: int) -> i64 {
	y := i64(year) - (month <= 2 ? 1 : 0)
	era := (y >= 0 ? y : y - 399) / 400
	yoe := y - era * 400
	mp := i64((month + 9) % 12)
	doy := (153 * mp + 2) / 5 + i64(day) - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

// The sun's declination (degrees) and the equation of time (minutes) at a Julian day.
@(private)
sun_position :: proc(jd: f64) -> (declination, eq_time: f64) {
	t := (jd - 2451545.0) / 36525.0
	l0 := math.mod(280.46646 + t * (36000.76983 + t * 0.0003032), 360)
	if l0 < 0 { l0 += 360 }
	m := 357.52911 + t * (35999.05029 - 0.0001537 * t)
	e := 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
	mr := rad(m)
	center := math.sin(mr) * (1.914602 - t * (0.004817 + 0.000014 * t)) + math.sin(2 * mr) * (0.019993 - 0.000101 * t) + math.sin(3 * mr) * 0.000289
	omega := 125.04 - 1934.136 * t
	lambda := l0 + center - 0.00569 - 0.00478 * math.sin(rad(omega))
	seconds := 21.448 - t * (46.8150 + t * (0.00059 - t * 0.001813))
	epsilon := 23 + (26 + seconds / 60) / 60 + 0.00256 * math.cos(rad(omega))
	declination = deg(math.asin(math.sin(rad(epsilon)) * math.sin(rad(lambda))))
	y := math.tan(rad(epsilon) / 2)
	y *= y
	l0r := rad(l0)
	et := y * math.sin(2 * l0r) - 2 * e * math.sin(mr) + 4 * e * y * math.sin(mr) * math.cos(2 * l0r) -
	      0.5 * y * y * math.sin(4 * l0r) - 1.25 * e * e * math.sin(2 * mr)
	return declination, deg(et) * 4
}

// Minutes after 0h UTC of sunrise (`rise`) or sunset, computed with the sun's
// position at `guess` minutes; ok = false when the sun stays above
// (polar_day) or below the horizon.
@(private)
sun_event :: proc(jd, latitude, longitude: f64, rise: bool, guess: f64) -> (minutes: f64, ok: bool, polar_day: bool) {
	decl, eqt := sun_position(jd + guess / 1440)
	lat := clamp(latitude, -89.99, 89.99)
	// 90.833°: the centre of the sun 50' below the horizon (refraction and its radius).
	cos_ha := math.cos(rad(90.833)) / (math.cos(rad(lat)) * math.cos(rad(decl))) - math.tan(rad(lat)) * math.tan(rad(decl))
	if cos_ha > 1 { return 0, false, false }
	if cos_ha < -1 { return 0, false, true }
	ha := deg(math.acos(cos_ha))
	if !rise { ha = -ha }
	return 720 - 4 * (longitude + ha) - eqt, true, false
}

// Sunrise and sunset (unix seconds) of a calendar day at a place (degrees,
// north and east positive). With a polar day or night both are 0.
sun_times :: proc(year, month, day: int, latitude, longitude: f64) -> (sunrise, sunset: f64, kind: Sun_Kind) {
	jd := julian_day(year, month, day)
	noon := 720 - 4 * longitude
	midnight := f64(days_from_civil(year, month, day)) * 86400
	times: [2]f64
	for rise, i in ([2]bool{true, false}) {
		m, ok, polar_day := sun_event(jd, latitude, longitude, rise, noon)
		if ok { m, ok, polar_day = sun_event(jd, latitude, longitude, rise, m) } // again, with the sun where it is then
		if !ok { return 0, 0, polar_day ? .Polar_Day : .Polar_Night }
		times[i] = midnight + m * 60
	}
	return times[0], times[1], .Normal
}

// ---------------------------------------------------------------------------
// Local time
// ---------------------------------------------------------------------------
Local_Date :: struct { year, month, day: int }

// The local calendar date of a unix time.
local_date :: proc(unix: f64) -> Local_Date {
	t := posix.time_t(math.floor(unix))
	tm: posix.tm
	posix.localtime_r(&t, &tm)
	return {int(tm.tm_year) + 1900, int(tm.tm_mon) + 1, int(tm.tm_mday)}
}

// Unix time of `minutes` after local midnight, `days` after date `d` (both
// may run over: mktime normalises them, and follows daylight saving time).
local_time :: proc(d: Local_Date, days: int, minutes: int) -> (unix: f64, date: Local_Date) {
	tm: posix.tm
	tm.tm_year = i32(d.year - 1900)
	tm.tm_mon = i32(d.month - 1)
	tm.tm_mday = i32(d.day + days)
	tm.tm_hour = i32(minutes / 60)
	tm.tm_min = i32(minutes % 60)
	tm.tm_isdst = -1
	t := posix.mktime(&tm)
	return f64(t), {int(tm.tm_year) + 1900, int(tm.tm_mon) + 1, int(tm.tm_mday)}
}

// Minutes after local midnight of a unix time.
local_minutes :: proc(unix: f64) -> int {
	t := posix.time_t(math.floor(unix))
	tm: posix.tm
	posix.localtime_r(&t, &tm)
	return int(tm.tm_hour) * 60 + int(tm.tm_min)
}

// ---------------------------------------------------------------------------
// Schedule
// ---------------------------------------------------------------------------
Schedule :: struct {
	sun:        bool, // sunset → sunrise at latitude/longitude; otherwise from → to
	latitude:   f64,
	longitude:  f64,
	from, to:   int,  // minutes after local midnight
	transition: f64,  // seconds the change takes, inside the night
}

@(private)
Span :: struct { start, end: f64 }

// The daylight of one local date (empty during a polar night).
@(private)
day_span :: proc(s: Schedule, today: Local_Date, offset: int) -> (Span, bool) {
	midnight, date := local_time(today, offset, 0)
	if s.sun {
		rise, set, kind := sun_times(date.year, date.month, date.day, s.latitude, s.longitude)
		switch kind {
		case .Normal:      return {rise, set}, set > rise
		case .Polar_Night: return {}, false
		case .Polar_Day:
			next, _ := local_time(today, offset + 1, 0)
			return {midnight, next}, true
		}
	}
	day_start, _ := local_time(today, offset, s.to)
	switch {
	case s.from == s.to:
		next, _ := local_time(today, offset + 1, 0)
		return {midnight, next}, true // no night at all
	case s.from > s.to:
		day_end, _ := local_time(today, offset, s.from) // 07:00 → 20:00
		return {day_start, day_end}, true
	case:
		day_end, _ := local_time(today, offset + 1, s.from) // 06:00 → 01:00 the next day
		return {day_start, day_end}, true
	}
}

// How far into the night `now` (unix seconds) is: 0 = day, 1 = night, in
// between while the screen warms up after the night starts or cools down
// before it ends. `recheck`: seconds after which the answer may change.
night_factor :: proc(s: Schedule, now: f64) -> (factor: f64, recheck: f64) {
	today := local_date(now)
	spans: [dynamic]Span
	spans.allocator = context.temp_allocator
	for offset in -2 ..= 2 {
		sp, ok := day_span(s, today, offset)
		if !ok { continue }
		if n := len(spans); n > 0 && sp.start <= spans[n - 1].end + 1 {
			spans[n - 1].end = max(spans[n - 1].end, sp.end) // touching days (midnight sun)
			continue
		}
		append(&spans, sp)
	}
	if len(spans) == 0 { return 1, 3600 } // a long polar night
	for sp, i in spans {
		if now >= sp.start && now < sp.end { return 0, sp.end - now }
		if i + 1 < len(spans) && now >= sp.end && now < spans[i + 1].start {
			a, b := sp.end, spans[i + 1].start
			ramp := min(s.transition, (b - a) / 2)
			switch {
			case ramp > 0 && now < a + ramp:
				return smoothstep((now - a) / ramp), min(10, a + ramp - now)
			case ramp > 0 && now > b - ramp:
				return smoothstep((b - now) / ramp), min(10, b - now)
			}
			return 1, (b - ramp) - now
		}
	}
	return now < spans[0].start ? 1 : 0, 3600
}

@(private)
smoothstep :: proc(x: f64) -> f64 {
	t := clamp(x, 0, 1)
	return t * t * (3 - 2 * t)
}

// Today's night as shown by the settings: start and end (unix seconds) of the
// night that is under way or comes next, and whether the sun ever sets.
next_night :: proc(s: Schedule, now: f64) -> (start, end: f64, ok: bool) {
	today := local_date(now)
	prev: Span
	have_prev := false
	for offset in -1 ..= 3 {
		sp, has := day_span(s, today, offset)
		if !has { continue }
		if have_prev && sp.start > prev.end + 1 && sp.start > now { return prev.end, sp.start, true }
		prev = sp
		have_prev = true
	}
	return 0, 0, false
}

// ---------------------------------------------------------------------------
// A place from the time zone
// ---------------------------------------------------------------------------

// The coordinates of the time zone's main city (zone1970.tab), a fair guess
// of where the user is for sunset and sunrise. `zone` is e.g. "America/Sao_Paulo".
timezone_location :: proc(allocator := context.temp_allocator) -> (latitude, longitude: f64, zone: string, ok: bool) {
	name := ""
	if tz, found := os.lookup_env("TZ", context.temp_allocator); found && tz != "" {
		name = strings.trim_prefix(tz, ":")
	} else if target, err := os.read_link("/etc/localtime", context.temp_allocator); err == nil {
		if i := strings.index(target, "zoneinfo/"); i >= 0 { name = target[i + len("zoneinfo/"):] }
	}
	if name == "" {
		if data, err := os.read_entire_file("/etc/timezone", context.temp_allocator); err == nil { name = strings.trim_space(string(data)) }
	}
	name = strings.trim_prefix(strings.trim_prefix(name, "posix/"), "right/")
	if name == "" || filepath.is_abs(name) { return }
	for table in ([]string{"/usr/share/zoneinfo/zone1970.tab", "/usr/share/zoneinfo/zone.tab"}) {
		data, err := os.read_entire_file(table, context.temp_allocator)
		if err != nil { continue }
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			if strings.has_prefix(line, "#") { continue }
			fields := strings.split(line, "\t", context.temp_allocator)
			if len(fields) < 3 || fields[2] != name { continue }
			lat, lon, cok := parse_iso6709(fields[1])
			if !cok { return }
			return lat, lon, strings.clone(name, allocator), true
		}
	}
	return
}

// "+DDMM+DDDMM" or "+DDMMSS+DDDMMSS" → degrees.
parse_iso6709 :: proc(s: string) -> (latitude, longitude: f64, ok: bool) {
	split := strings.index_any(s[1:], "+-") + 1
	if split <= 0 { return }
	part :: proc(p: string, deg_digits: int) -> (f64, bool) {
		if len(p) < 1 + deg_digits + 2 { return 0, false }
		sign := p[0] == '-' ? -1.0 : 1.0
		digits := p[1:]
		d, dok := strconv.parse_int(digits[:deg_digits], 10)
		m, mok := strconv.parse_int(digits[deg_digits:deg_digits + 2], 10)
		sec := 0
		sok := true
		if len(digits) >= deg_digits + 4 { sec, sok = strconv.parse_int(digits[deg_digits + 2:deg_digits + 4], 10) }
		if !dok || !mok || !sok { return 0, false }
		return sign * (f64(d) + f64(m) / 60 + f64(sec) / 3600), true
	}
	lat, ok1 := part(s[:split], 2)
	lon, ok2 := part(s[split:], 3)
	return lat, lon, ok1 && ok2
}
