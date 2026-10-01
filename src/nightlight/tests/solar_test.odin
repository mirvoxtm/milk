// Tests of the night light's maths: `odin test src/nightlight/tests`.
// The schedule tests read local time: the time zone is the system's for the
// time-zone test, then UTC for the rest (set before the others run).
package nightlight_tests

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:sys/posix"
import "core:testing"
import nl "../"

@(private)
system_zone: string

@(init, private)
use_utc :: proc "contextless" () {
	context = runtime.default_context()
	_, _, zone, _ := nl.timezone_location(context.allocator)
	system_zone = zone
	os.set_env("TZ", "UTC")
	posix.tzset()
}

// Unix seconds of a UTC date and time.
@(private)
utc :: proc(y, mo, d, h, mi: int) -> f64 {
	return f64(nl.days_from_civil(y, mo, d)) * 86400 + f64(h * 3600 + mi * 60)
}

@(private)
clock :: proc(unix: f64, offset_hours: f64) -> string {
	s := int(math.round(unix + offset_hours * 3600)) %% 86400
	return fmt.tprintf("%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
}

// Reference times from the astral library (python, 3.2), local clock time.
@(private)
City :: struct {
	name:                    string,
	lat, lon:                f64,
	y, mo, d:                int,
	offset:                  f64, // hours east of UTC on that date
	sunrise, sunset:         string,
}

@(test)
sunrise_sunset_cities :: proc(t: ^testing.T) {
	cities := []City{
		{"London",    51.5074,  -0.1278,  2024, 6, 21,  1, "04:43:33", "21:21:17"},
		{"São Paulo", -23.5505, -46.6333, 2024, 12, 21, -3, "05:17:22", "18:52:27"},
		{"New York",  40.7128,  -74.0060, 2024, 3, 20,  -4, "06:58:42", "19:08:28"},
		{"Tokyo",     35.6762,  139.6503, 2026, 10, 1,  9, "05:36:10", "17:25:40"},
		{"Reykjavík", 64.1466,  -21.9426, 2026, 1, 15,  0, "10:55:32", "16:19:27"},
	}
	for c in cities {
		rise, set, kind := nl.sun_times(c.y, c.mo, c.d, c.lat, c.lon)
		testing.expectf(t, kind == .Normal, "%s: %v", c.name, kind)
		got_rise, got_set := clock(rise, c.offset), clock(set, c.offset)
		fmt.printfln("%-10s %04d-%02d-%02d  sunrise %s (astral %s)  sunset %s (astral %s)", c.name, c.y, c.mo, c.d,
		             got_rise, c.sunrise, got_set, c.sunset)
		testing.expectf(t, close_to(got_rise, c.sunrise, 120), "%s sunrise %s, expected %s", c.name, got_rise, c.sunrise)
		testing.expectf(t, close_to(got_set, c.sunset, 120), "%s sunset %s, expected %s", c.name, got_set, c.sunset)
	}
}

// Within `seconds` of each other ("HH:MM:SS").
@(private)
close_to :: proc(a, b: string, seconds: int) -> bool {
	secs :: proc(s: string) -> int {
		return (int(s[0] - '0') * 10 + int(s[1] - '0')) * 3600 + (int(s[3] - '0') * 10 + int(s[4] - '0')) * 60 + int(s[6] - '0') * 10 + int(s[7] - '0')
	}
	d := abs(secs(a) - secs(b))
	return min(d, 86400 - d) <= seconds
}

@(test)
polar_day_and_night :: proc(t: ^testing.T) {
	_, _, winter := nl.sun_times(2024, 12, 21, 69.6492, 18.9553) // Tromsø
	_, _, summer := nl.sun_times(2024, 6, 21, 69.6492, 18.9553)
	testing.expect_value(t, winter, nl.Sun_Kind.Polar_Night)
	testing.expect_value(t, summer, nl.Sun_Kind.Polar_Day)
	_, _, south := nl.sun_times(2024, 6, 21, -77.85, 166.67) // McMurdo in June
	testing.expect_value(t, south, nl.Sun_Kind.Polar_Night)
}

@(test)
whitepoint_values :: proc(t: ^testing.T) {
	testing.expect_value(t, nl.whitepoint(6500), [3]f64{1, 1, 1})
	testing.expect_value(t, nl.whitepoint(9000), [3]f64{1, 1, 1})
	w := nl.whitepoint(3500)
	testing.expectf(t, w[0] == 1 && abs(w[1] - 0.796) < 0.01 && abs(w[2] - 0.543) < 0.01, "3500 K: %v", w)
	prev := nl.whitepoint(1000)
	testing.expectf(t, prev[0] == 1 && prev[2] == 0 && prev[1] > 0.05 && prev[1] < 0.25, "1000 K: %v", prev)
	// Warmer is never bluer.
	for k := 1100.0; k <= 6500; k += 100 {
		cur := nl.whitepoint(k)
		testing.expectf(t, cur[1] >= prev[1] - 1e-9 && cur[2] >= prev[2] - 1e-9, "%v K not monotonic: %v after %v", k, cur, prev)
		prev = cur
	}
	testing.expect(t, abs(nl.mired_lerp(6500, 3500, 0) - 6500) < 1e-6)
	testing.expect(t, abs(nl.mired_lerp(6500, 3500, 1) - 3500) < 1e-6)
	mid := nl.mired_lerp(6500, 3500, 0.5) // 1e6 / ((153.8 + 285.7) / 2) = 4550 K
	testing.expectf(t, abs(mid - 4550) < 5, "mired midpoint %v", mid)
}

@(test)
manual_schedule :: proc(t: ^testing.T) {
	s := nl.Schedule{from = 20 * 60, to = 7 * 60, transition = 30 * 60}
	check :: proc(t: ^testing.T, s: nl.Schedule, at: f64, want: f64, label: string, loc := #caller_location) {
		f, recheck := nl.night_factor(s, at)
		testing.expectf(t, abs(f - want) < 1e-6 && recheck > 0, "%s: factor %v (want %v), recheck %v", label, f, want, recheck, loc = loc)
	}
	check(t, s, utc(2026, 10, 1, 12, 0), 0, "noon")
	check(t, s, utc(2026, 10, 1, 20, 15), 0.5, "halfway into dusk")
	check(t, s, utc(2026, 10, 1, 20, 30), 1, "dusk over")
	check(t, s, utc(2026, 10, 1, 23, 0), 1, "late evening")
	check(t, s, utc(2026, 10, 2, 3, 0), 1, "after midnight")
	check(t, s, utc(2026, 10, 2, 6, 45), 0.5, "halfway into dawn")
	check(t, s, utc(2026, 10, 2, 7, 30), 0, "morning")
	_, recheck := nl.night_factor(s, utc(2026, 10, 1, 12, 0))
	testing.expectf(t, abs(recheck - 8 * 3600) < 1, "noon: next change in %v s (8 h expected)", recheck)
	_, recheck = nl.night_factor(s, utc(2026, 10, 1, 23, 0))
	testing.expectf(t, abs(recheck - (7 * 3600 + 30 * 60)) < 1, "23:00: next change in %v s (06:30 expected)", recheck)

	// A night that does not cross midnight.
	early := nl.Schedule{from = 1 * 60, to = 6 * 60, transition = 0}
	check(t, early, utc(2026, 10, 1, 3, 0), 1, "01:00-06:00 at 03:00")
	check(t, early, utc(2026, 10, 1, 12, 0), 0, "01:00-06:00 at noon")
	check(t, early, utc(2026, 10, 1, 23, 0), 0, "01:00-06:00 at 23:00")
	// No night at all.
	check(t, nl.Schedule{from = 600, to = 600}, utc(2026, 10, 1, 3, 0), 0, "from = to")
}

@(test)
sun_schedule :: proc(t: ^testing.T) {
	// London on 2024-06-21: sunset 20:21 UTC, sunrise 03:43 UTC the next morning.
	s := nl.Schedule{sun = true, latitude = 51.5074, longitude = -0.1278, transition = 30 * 60}
	f, _ := nl.night_factor(s, utc(2024, 6, 21, 15, 0))
	testing.expectf(t, f == 0, "afternoon: %v", f)
	f, _ = nl.night_factor(s, utc(2024, 6, 21, 20, 36))
	testing.expectf(t, abs(f - 0.5) < 0.05, "15 min after sunset: %v", f)
	f, _ = nl.night_factor(s, utc(2024, 6, 22, 0, 0))
	testing.expectf(t, f == 1, "midnight: %v", f)
	start, end, ok := nl.next_night(s, utc(2024, 6, 21, 12, 0))
	testing.expect(t, ok)
	testing.expectf(t, close_to(clock(start, 0), "20:21:17", 120) && close_to(clock(end, 0), "03:43:47", 180),
	                "next night %s → %s", clock(start, 0), clock(end, 0))
	// Tromsø in December: night all day; in June: never.
	polar := nl.Schedule{sun = true, latitude = 69.6492, longitude = 18.9553, transition = 30 * 60}
	f, _ = nl.night_factor(polar, utc(2024, 12, 21, 12, 0))
	testing.expectf(t, f == 1, "polar night: %v", f)
	f, _ = nl.night_factor(polar, utc(2024, 6, 21, 0, 0))
	testing.expectf(t, f == 0, "midnight sun: %v", f)
}

@(test)
timezone_place :: proc(t: ^testing.T) {
	// Read before TZ was set to UTC (use_utc).
	fmt.printfln("system time zone: %q", system_zone)
	lat, lon, ok := nl.parse_iso6709("-2332-04637")
	testing.expectf(t, ok && abs(lat + 23.5333) < 1e-3 && abs(lon + 46.6167) < 1e-3, "São Paulo: %v %v", lat, lon)
	lat, lon, ok = nl.parse_iso6709("+404251-0740023")
	testing.expectf(t, ok && abs(lat - 40.7142) < 1e-3 && abs(lon + 74.0064) < 1e-3, "New York: %v %v", lat, lon)
}
