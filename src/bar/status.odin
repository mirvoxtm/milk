// System status sources: network, bluetooth, battery and brightness from
// sysfs/procfs; volume through wpctl/pactl/amixer jobs; date and clock.
package bar

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

Net_Kind :: enum { None, Wifi, Ethernet }

Network_State :: struct {
	kind:    Net_Kind,
	quality: int, // wifi link quality 0..100
}

Bluetooth_State :: struct {
	present, blocked, connected: bool,
}

Battery_State :: struct {
	present:  bool,
	percent:  int,
	charging: bool,
	full:     bool,
}

Brightness_State :: struct {
	present:     bool,
	device:      string, // /sys/class/backlight entry name
	current:     int,
	maximum:     int,
	percent:     int,
	setting:     bool, // a brightnessctl/logind job is applying a value
	has_pending: bool, // a newer value waits for that job
	pending:     int,
}

Volume_Backend :: enum { None, Wpctl, Pactl, Amixer }

Volume_State :: struct {
	backend:  Volume_Backend,
	known:    bool,
	percent:  int,
	muted:    bool,
	querying: bool,
	requery:  bool,
	setting:  bool, // a slider value is being applied (one set command at a time)
	has_pending: bool, // a newer slider value waits for it
	pending:  int,
}

LOW_BATTERY :: 15

// ---------------------------------------------------------------------------
// Small file helpers
// ---------------------------------------------------------------------------
@(private)
read_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return "", false }
	return strings.trim_space(string(data)), true
}

@(private)
read_int :: proc(path: string) -> (int, bool) {
	s, ok := read_text(path)
	if !ok { return 0, false }
	return strconv.parse_int(s, 10)
}

@(private)
join_path :: proc(parts: ..string) -> string {
	return strings.join(parts, "/", context.temp_allocator)
}

@(private)
list_dir :: proc(path: string) -> []string {
	infos, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil { return nil }
	names := make([]string, len(infos), context.temp_allocator)
	for fi, i in infos { names[i] = fi.name }
	// Stable order so that "the first device" does not change between polls.
	for i in 1 ..< len(names) {
		for j := i; j > 0 && names[j] < names[j - 1]; j -= 1 { names[j], names[j - 1] = names[j - 1], names[j] }
	}
	return names
}

// ---------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------
@(private)
read_network :: proc() -> Network_State {
	st: Network_State
	wifi_up := ""
	ethernet_up := false
	for name in list_dir("/sys/class/net") {
		if name == "lo" { continue }
		base := join_path("/sys/class/net", name)
		wireless := os.exists(join_path(base, "wireless")) || os.exists(join_path(base, "phy80211"))
		physical := os.exists(join_path(base, "device"))
		oper, _ := read_text(join_path(base, "operstate"))
		if oper != "up" { continue }
		if wireless {
			if wifi_up == "" { wifi_up = name }
		} else if physical {
			ethernet_up = true
		}
	}
	if ethernet_up {
		st.kind = .Ethernet
	} else if wifi_up != "" {
		st.kind = .Wifi
		st.quality = wireless_quality(wifi_up)
	}
	return st
}

// Link quality from /proc/net/wireless (scaled from the usual 0..70 range).
@(private)
wireless_quality :: proc(iface: string) -> int {
	text, ok := read_text("/proc/net/wireless")
	if !ok { return 100 }
	for line in strings.split_lines(text, context.temp_allocator) {
		l := strings.trim_space(line)
		if !strings.has_prefix(l, iface) || len(l) <= len(iface) || l[len(iface)] != ':' { continue }
		fields := strings.fields(l[len(iface) + 1:], context.temp_allocator)
		if len(fields) < 2 { break }
		q, qok := strconv.parse_f64(strings.trim_right(fields[1], "."))
		if !qok { break }
		return clamp(int(q * 100 / 70 + 0.5), 0, 100)
	}
	return 100
}

// ---------------------------------------------------------------------------
// Bluetooth
// ---------------------------------------------------------------------------
@(private)
read_bluetooth :: proc() -> Bluetooth_State {
	st: Bluetooth_State
	for name in list_dir("/sys/class/rfkill") {
		base := join_path("/sys/class/rfkill", name)
		kind, _ := read_text(join_path(base, "type"))
		if kind != "bluetooth" { continue }
		soft, _ := read_text(join_path(base, "soft"))
		hard, _ := read_text(join_path(base, "hard"))
		if soft == "1" || hard == "1" { st.blocked = true }
	}
	for name in list_dir("/sys/class/bluetooth") {
		if !strings.has_prefix(name, "hci") { continue }
		if strings.contains(name, ":") {
			st.connected = true // hciN:HANDLE entries are live connections
		} else {
			st.present = true
		}
	}
	return st
}

// ---------------------------------------------------------------------------
// Battery
// ---------------------------------------------------------------------------
@(private)
read_battery :: proc() -> Battery_State {
	st: Battery_State
	total, count := 0, 0
	any_charging, all_full := false, true
	for name in list_dir("/sys/class/power_supply") {
		base := join_path("/sys/class/power_supply", name)
		kind, _ := read_text(join_path(base, "type"))
		if kind != "Battery" { continue }
		if scope, ok := read_text(join_path(base, "scope")); ok && scope == "Device" { continue } // mice, headsets
		if present, ok := read_text(join_path(base, "present")); ok && present == "0" { continue }
		capacity, ok := read_int(join_path(base, "capacity"))
		if !ok {
			now, ok1 := read_int(join_path(base, "energy_now"))
			full, ok2 := read_int(join_path(base, "energy_full"))
			if !(ok1 && ok2) {
				now, ok1 = read_int(join_path(base, "charge_now"))
				full, ok2 = read_int(join_path(base, "charge_full"))
			}
			if !(ok1 && ok2) || full <= 0 { continue }
			capacity = now * 100 / full
		}
		total += clamp(capacity, 0, 100)
		count += 1
		status, _ := read_text(join_path(base, "status"))
		if status == "Charging" { any_charging = true }
		if status != "Full" { all_full = false }
	}
	if count == 0 { return st }
	st.present = true
	st.percent = total / count
	st.charging = any_charging
	st.full = all_full
	return st
}

// ---------------------------------------------------------------------------
// Brightness
// ---------------------------------------------------------------------------
// The backlight class directory; MILK_BACKLIGHT_DIR overrides it (tests use a
// fake, writable device so that the real panel is never touched).
@(private)
backlight_dir :: proc() -> string {
	if dir, found := os.lookup_env("MILK_BACKLIGHT_DIR", context.temp_allocator); found && dir != "" { return dir }
	return "/sys/class/backlight"
}

// Re-read the backlight; returns true when the displayed state changed.
@(private)
refresh_brightness :: proc(b: ^Bar) -> bool {
	old := b.bright
	st := Brightness_State{setting = old.setting, has_pending = old.has_pending, pending = old.pending}
	root := backlight_dir()
	for name in list_dir(root) {
		base := join_path(root, name)
		maximum, ok1 := read_int(join_path(base, "max_brightness"))
		current, ok2 := read_int(join_path(base, "brightness"))
		if !(ok1 && ok2) || maximum <= 0 { continue }
		st.present = true
		st.maximum = maximum
		st.current = clamp(current, 0, maximum)
		st.percent = int(f64(st.current) * 100 / f64(maximum) + 0.5)
		if name != old.device {
			delete(old.device)
			st.device = strings.clone(name)
		} else {
			st.device = old.device
		}
		break
	}
	if !st.present { delete(old.device) }
	b.bright = st
	changed := st.present != old.present || st.percent != old.percent
	if changed { b.dirty = true }
	return changed
}

// Scroll on the brightness widget: ±delta percent of the maximum.
@(private)
change_brightness :: proc(b: ^Bar, delta: int) {
	st := &b.bright
	if !st.present || st.maximum <= 0 { return }
	step := max(1, st.maximum * abs(delta) / 100)
	write_brightness(b, st.current + (delta > 0 ? step : -step))
}

// Absolute brightness from the slider (0..100 %).
@(private)
set_brightness_percent :: proc(b: ^Bar, percent: int) {
	st := &b.bright
	if !st.present || st.maximum <= 0 { return }
	write_brightness(b, int(f64(st.maximum) * f64(clamp(percent, 0, 100)) / 100 + 0.5))
}

// Apply a raw backlight value: a writable sysfs file directly, else
// brightnessctl, else systemd-logind (which lets the session owner set the
// backlight without root). Only one helper runs at a time; while it runs the
// newest value waits (a slider drag produces many).
@(private)
write_brightness :: proc(b: ^Bar, value: int) {
	st := &b.bright
	lowest := max(1, st.maximum / 100) // never switch the panel off from the bar
	target := clamp(value, lowest, st.maximum)
	if target == st.current { return }
	path := join_path(backlight_dir(), st.device, "brightness")
	switch {
	case posix.access(strings.clone_to_cstring(path, context.temp_allocator), {.W_OK}) == .OK:
		text := fmt.tprintf("%d", target)
		if err := os.write_entire_file(path, transmute([]u8)text); err != nil {
			log.warnf("Could not write %s: %v", path, err)
			return
		}
	case b.tools.brightnessctl || b.tools.busctl:
		if st.setting {
			st.has_pending = true
			st.pending = target
		} else if !start_brightness_job(b, target) {
			return
		}
	case:
		if .Brightness not_in b.warned {
			b.warned += {.Brightness}
			log.warn("Cannot change the brightness: install brightnessctl or make the backlight writable")
		}
		return
	}
	// Show the new value right away; the next read confirms it.
	st.current = target
	st.percent = int(f64(target) * 100 / f64(st.maximum) + 0.5)
	b.dirty = true
}

@(private)
start_brightness_job :: proc(b: ^Bar, target: int) -> bool {
	st := &b.bright
	value := fmt.tprintf("%d", target)
	job: ^Job
	if b.tools.brightnessctl {
		job = start_job(b, .Brightness_Change, {"brightnessctl", "-q", "-d", st.device, "set", value}, false)
	} else {
		job = start_job(b, .Brightness_Change, {"busctl", "call", "org.freedesktop.login1", "/org/freedesktop/login1/session/auto",
		                                        "org.freedesktop.login1.Session", "SetBrightness", "ssu", "backlight", st.device, value}, false)
	}
	st.setting = job != nil
	return job != nil
}

@(private)
brightness_set_done :: proc(b: ^Bar) {
	st := &b.bright
	st.setting = false
	if st.has_pending {
		st.has_pending = false
		if start_brightness_job(b, st.pending) { return }
	}
	refresh_brightness(b)
}

// ---------------------------------------------------------------------------
// Volume
// ---------------------------------------------------------------------------
@(private)
pick_volume_backend :: proc(b: ^Bar) -> Volume_Backend {
	switch {
	case b.tools.wpctl:  return .Wpctl
	case b.tools.pactl:  return .Pactl
	case b.tools.amixer: return .Amixer
	}
	return .None
}

@(private)
request_volume_refresh :: proc(b: ^Bar) {
	v := &b.vol
	if v.backend == .None { return }
	if v.querying {
		v.requery = true
		return
	}
	argv: []string
	switch v.backend {
	case .Wpctl:  argv = {"wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"}
	case .Pactl:  argv = {"sh", "-c", "LC_ALL=C pactl get-sink-volume @DEFAULT_SINK@ && LC_ALL=C pactl get-sink-mute @DEFAULT_SINK@"}
	case .Amixer: argv = {"sh", "-c", "LC_ALL=C amixer get Master"}
	case .None:   return
	}
	if start_job(b, .Volume_Query, argv, true) != nil { v.querying = true }
}

@(private)
volume_query_done :: proc(b: ^Bar, output: string, ok: bool) {
	v := &b.vol
	v.querying = false
	percent, muted, parsed := parse_volume(v.backend, output)
	if v.setting {
		// A slider value is being applied: this reading may predate it.
		// volume_set_done asks again once the value is in place.
	} else if ok && parsed {
		if !v.known || percent != v.percent || muted != v.muted { b.dirty = true }
		v.known, v.percent, v.muted = true, percent, muted
	} else if v.known {
		v.known = false
		b.dirty = true
	}
	if v.requery {
		v.requery = false
		request_volume_refresh(b)
	}
}

// "Volume: 0.80 [MUTED]" (wpctl), "... / 80% / ..." + "Mute: yes" (pactl),
// "[80%] [off]" (amixer).
@(private)
parse_volume :: proc(backend: Volume_Backend, output: string) -> (percent: int, muted: bool, ok: bool) {
	switch backend {
	case .Wpctl:
		i := strings.index(output, "Volume:")
		if i < 0 { return }
		rest := strings.trim_left_space(output[i + len("Volume:"):])
		end := 0
		for end < len(rest) && (rest[end] >= '0' && rest[end] <= '9' || rest[end] == '.' || rest[end] == ',') { end += 1 }
		num, _ := strings.replace_all(rest[:end], ",", ".", context.temp_allocator)
		value, vok := strconv.parse_f64(num)
		if !vok { return }
		return int(value * 100 + 0.5), strings.contains(output, "[MUTED]"), true
	case .Pactl, .Amixer:
		pct := strings.index_byte(output, '%')
		if pct <= 0 { return }
		start := pct
		for start > 0 && output[start - 1] >= '0' && output[start - 1] <= '9' { start -= 1 }
		value, vok := strconv.parse_int(output[start:pct], 10)
		if !vok { return }
		if backend == .Pactl {
			muted = strings.contains(output, "Mute: yes")
		} else {
			muted = strings.contains(output, "[off]")
		}
		return value, muted, true
	case .None:
	}
	return
}

// Scroll on the volume widget: ±delta percent, capped at 100 %.
@(private)
change_volume :: proc(b: ^Bar, delta: int) {
	v := &b.vol
	step := fmt.tprintf("%d%%", abs(delta))
	target := clamp((v.known ? v.percent : 50) + delta, 0, 100)
	argv: []string
	switch v.backend {
	case .Wpctl:
		argv = {"wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", strings.concatenate({step, delta > 0 ? "+" : "-"}, context.temp_allocator)}
	case .Pactl:
		argv = {"pactl", "set-sink-volume", "@DEFAULT_SINK@", fmt.tprintf("%d%%", target)}
	case .Amixer:
		argv = {"amixer", "-q", "set", "Master", strings.concatenate({step, delta > 0 ? "+" : "-"}, context.temp_allocator)}
	case .None:
		return
	}
	start_job(b, .Volume_Change, argv, false)
	if v.known && target != v.percent {
		v.percent = target
		b.dirty = true
	}
}

// Absolute volume from the slider (0..100 %).
@(private)
set_volume_percent :: proc(b: ^Bar, percent: int) {
	v := &b.vol
	if v.backend == .None { return }
	target := clamp(percent, 0, 100)
	if v.known && target != v.percent {
		v.percent = target
		b.dirty = true
	}
	if v.setting {
		v.has_pending = true
		v.pending = target
		return
	}
	start_volume_set(b, target)
}

@(private)
start_volume_set :: proc(b: ^Bar, target: int) -> bool {
	v := &b.vol
	value := fmt.tprintf("%d%%", target)
	argv: []string
	switch v.backend {
	case .Wpctl:  argv = {"wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", value}
	case .Pactl:  argv = {"pactl", "set-sink-volume", "@DEFAULT_SINK@", value}
	case .Amixer: argv = {"amixer", "-q", "set", "Master", value}
	case .None:   return false
	}
	v.setting = start_job(b, .Volume_Set, argv, false) != nil
	return v.setting
}

@(private)
volume_set_done :: proc(b: ^Bar) {
	v := &b.vol
	v.setting = false
	if v.has_pending {
		v.has_pending = false
		if start_volume_set(b, v.pending) { return }
	}
	request_volume_refresh(b)
}

@(private)
toggle_mute :: proc(b: ^Bar) {
	v := &b.vol
	argv: []string
	switch v.backend {
	case .Wpctl:  argv = {"wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"}
	case .Pactl:  argv = {"pactl", "set-sink-mute", "@DEFAULT_SINK@", "toggle"}
	case .Amixer: argv = {"amixer", "-q", "set", "Master", "toggle"}
	case .None:   return
	}
	start_job(b, .Volume_Change, argv, false)
	if v.known {
		v.muted = !v.muted
		b.dirty = true
	}
}

// ---------------------------------------------------------------------------
// Date and clock
// ---------------------------------------------------------------------------
WEEKDAYS_PT     := [7]string{"dom", "seg", "ter", "qua", "qui", "sex", "sáb"}
WEEKDAYS_PT_FULL := [7]string{"domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado"}
MONTHS_PT       := [12]string{"jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"}
MONTHS_PT_FULL  := [12]string{"janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"}
WEEKDAYS_EN     := [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
WEEKDAYS_EN_FULL := [7]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
MONTHS_EN       := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
MONTHS_EN_FULL  := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}

@(private)
local_time :: proc() -> (tm: posix.tm, unix_nanos: i64) {
	unix_nanos = time.to_unix_nanoseconds(time.now())
	t := posix.time_t(unix_nanos / 1_000_000_000)
	posix.localtime_r(&t, &tm)
	return
}

// strftime subset: %a %A %d %e %b %B %m %y %Y %H %I %M %S %p %%.
@(private)
format_time :: proc(format: string, tm: posix.tm, locale: string, allocator := context.temp_allocator) -> string {
	pt := strings.has_prefix(strings.to_lower(locale, context.temp_allocator), "pt")
	wday := clamp(int(tm.tm_wday), 0, 6)
	mon := clamp(int(tm.tm_mon), 0, 11)
	sb := strings.builder_make(allocator)
	for i := 0; i < len(format); i += 1 {
		ch := format[i]
		if ch != '%' || i + 1 >= len(format) {
			strings.write_byte(&sb, ch)
			continue
		}
		i += 1
		switch format[i] {
		case 'a': strings.write_string(&sb, pt ? WEEKDAYS_PT[wday] : WEEKDAYS_EN[wday])
		case 'A': strings.write_string(&sb, pt ? WEEKDAYS_PT_FULL[wday] : WEEKDAYS_EN_FULL[wday])
		case 'b', 'h': strings.write_string(&sb, pt ? MONTHS_PT[mon] : MONTHS_EN[mon])
		case 'B': strings.write_string(&sb, pt ? MONTHS_PT_FULL[mon] : MONTHS_EN_FULL[mon])
		case 'd': fmt.sbprintf(&sb, "%02d", tm.tm_mday)
		case 'e': fmt.sbprintf(&sb, "%2d", tm.tm_mday)
		case 'm': fmt.sbprintf(&sb, "%02d", tm.tm_mon + 1)
		case 'y': fmt.sbprintf(&sb, "%02d", (tm.tm_year + 1900) % 100)
		case 'Y': fmt.sbprintf(&sb, "%d", tm.tm_year + 1900)
		case 'H': fmt.sbprintf(&sb, "%02d", tm.tm_hour)
		case 'I': fmt.sbprintf(&sb, "%02d", (tm.tm_hour + 11) % 12 + 1)
		case 'M': fmt.sbprintf(&sb, "%02d", tm.tm_min)
		case 'S': fmt.sbprintf(&sb, "%02d", tm.tm_sec)
		case 'p': strings.write_string(&sb, tm.tm_hour < 12 ? "AM" : "PM")
		case '%': strings.write_byte(&sb, '%')
		case:
			strings.write_byte(&sb, '%')
			strings.write_byte(&sb, format[i])
		}
	}
	return strings.to_string(sb)
}

// Recompute the date and clock texts; returns true when either changed.
@(private)
update_time_texts :: proc(b: ^Bar) -> bool {
	tm, _ := local_time()
	date := format_time(b.cfg.bar.date_format, tm, b.cfg.bar.locale)
	clock := format_time(b.cfg.bar.clock_format, tm, b.cfg.bar.locale)
	changed := false
	if date != b.date_text {
		delete(b.date_text)
		b.date_text = strings.clone(date)
		changed = true
	}
	if clock != b.clock_text {
		log.debugf("Bar clock: %s", clock)
		delete(b.clock_text)
		b.clock_text = strings.clone(clock)
		changed = true
	}
	if changed { b.dirty = true }
	return changed
}

// Monotonic time of the next minute boundary (or second, for %S formats).
@(private)
next_clock_deadline :: proc(b: ^Bar, now: f64) -> f64 {
	_, nanos := local_time()
	period: i64 = 60
	if strings.contains(b.cfg.bar.clock_format, "%S") || strings.contains(b.cfg.bar.date_format, "%S") { period = 1 }
	period_ns := period * 1_000_000_000
	remaining := period_ns - nanos %% period_ns
	return now + f64(remaining) / 1e9 + 0.005
}

// Titles may contain control characters; keep them on one line.
@(private)
sanitize_line :: proc(s: string, allocator := context.allocator) -> string {
	out, _ := strings.replace_all(s, "\n", " ", context.temp_allocator)
	out, _ = strings.replace_all(out, "\t", " ", context.temp_allocator)
	out, _ = strings.replace_all(out, "\r", "", context.temp_allocator)
	return strings.clone(strings.trim_space(out), allocator)
}
