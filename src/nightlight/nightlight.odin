// Package nightlight: milk's owner of the screen gamma.
//
// Two things change the colours the monitors show, through the gamma ramps of
// every CRTC (gamma.odin): the night light (warmer white on a schedule:
// always, sunset → sunrise at a place, or between two times; config
// "nightLight") and a dim factor that other modules set (the idle/lock code
// darkens the screen with `set_dim`). Both combine: ramp = original ×
// white point(temperature) × dim. Neutral settings (6500 K, dim 1) give the
// screen its original ramps back, and so do `destroy` and a disabled night
// light; RandR changes (monitors plugged, modes changed) are followed.
//
// Integration (main loop): offer every X event to `handle_event`, call `tick`
// each iteration and sleep at most `next_timeout`; `reload` with each new
// configuration; `destroy` on exit.
//
// The settings app previews a temperature on screen with `preview`
// (a _MILK_NIGHT_LIGHT_PREVIEW client message to the root window).
package nightlight

import "base:runtime"
import "core:encoding/json"
import "core:log"
import "core:math"
import "core:time"
import xlib "vendor:x11/xlib"
import config "../config"
import tx "../tx"

PREVIEW_MESSAGE :: "_MILK_NIGHT_LIGHT_PREVIEW" // data.l[0]: kelvin (0 = end the preview)

@(private) PREVIEW_TIME   :: 3.0  // seconds a preview stays after the last message
@(private) FADE_TIME      :: 1.2  // seconds to reach a new temperature (switching on/off, reloads)
@(private) PREVIEW_FADE   :: 0.15
@(private) FRAME          :: 1.0 / 40
@(private) MAX_SLEEP      :: 60.0 // the schedule is checked at least this often (suspend, clock changes)
@(private) CLOCK_JUMP     :: 5.0  // seconds of difference between wall and monotonic clocks that mean a jump

Mode :: enum { Always, Sunset, Manual }

Night_Light :: struct {
	c:             ^tx.Connection,
	allocator:     runtime.Allocator,
	gamma:         Gamma,
	// Configuration (copied from config.Night_Light_Options).
	enabled:       bool,
	mode:          Mode,
	temperature:   f64,
	schedule:      Schedule,
	has_place:     bool, // latitude and longitude are set
	// State.
	dim:           f64, // set_dim (1 = normal)
	target:        f64, // temperature the schedule asks for now
	night:         f64, // 0 day .. 1 night (the schedule)
	shown:         f64, // temperature on screen
	fade_from:     f64,
	fade_to:       f64,
	fade_start:    f64,
	fade_len:      f64, // 0 = not fading
	preview:       f64, // > 0: the settings app shows this temperature
	preview_until: f64,
	next_eval:     f64, // monotonic time of the next look at the schedule
	clock_offset:  f64, // wall − monotonic seconds at the last look
	rescan:        bool, // RandR changed: re-read the CRTCs
	force:         bool, // write the ramps even if unchanged
}

// Take over the gamma ramps and apply the configuration. Never fails: without
// RandR gamma the night light and the dim factor just do nothing.
create :: proc(c: ^tx.Connection, cfg: ^config.Config) -> ^Night_Light {
	n := new(Night_Light)
	n.c = c
	n.allocator = context.allocator
	n.dim = 1
	n.shown = NEUTRAL_K
	n.target = NEUTRAL_K
	n.fade_to = NEUTRAL_K
	gamma_init(n)
	configure(n, cfg)
	return n
}

// Restore the original ramps and free everything. With `keep_ramps` (a
// restart in place) the screen stays as it is and the next instance takes it
// over without a flash (see gamma.odin).
destroy :: proc(n: ^Night_Light, keep_ramps := false) {
	if n == nil { return }
	context.allocator = n.allocator
	gamma_destroy(n, keep_ramps)
	tx.sync(n.c)
	free(n)
}

// A new configuration: the screen fades to what it asks for.
reload :: proc(n: ^Night_Light, cfg: ^config.Config) {
	if n == nil { return }
	context.allocator = n.allocator
	configure(n, cfg)
}

@(private)
configure :: proc(n: ^Night_Light, cfg: ^config.Config) {
	o := &cfg.night_light
	n.enabled = o.enabled
	switch o.mode {
	case "always": n.mode = .Always
	case "manual": n.mode = .Manual
	case:          n.mode = .Sunset
	}
	n.temperature = f64(clamp(o.temperature, config.NIGHT_LIGHT_MIN_K, config.NIGHT_LIGHT_MAX_K))
	_, has_lat := o.latitude.?
	_, has_lon := o.longitude.?
	n.has_place = has_lat && has_lon
	n.schedule = schedule_from(o)
	n.next_eval = 0 // look at the schedule on the next tick
	log.debugf("Night light: %s, %v, %.0f K%s", n.enabled ? "on" : "off", n.mode, n.temperature,
	           n.mode == .Sunset && !n.has_place ? " (no place set: using the from/to times)" : "")
}

// The schedule of a configuration ("sunset" without a place uses from/to).
schedule_from :: proc(o: ^config.Night_Light_Options) -> Schedule {
	s := Schedule{from = o.from, to = o.to, transition = f64(o.transition) * 60}
	lat, has_lat := o.latitude.?
	lon, has_lon := o.longitude.?
	if o.mode == "sunset" && has_lat && has_lon {
		s.sun = true
		s.latitude, s.longitude = lat, lon
	}
	return s
}

// Brightness multiplier for the whole screen (1 = normal, 0 = black),
// combined with the night light and applied at once. The caller animates it
// (calls this every frame of a fade); it works with the night light off too.
set_dim :: proc(n: ^Night_Light, factor: f64) {
	if n == nil { return }
	context.allocator = n.allocator
	f := clamp(factor, 0, 1)
	if math.is_nan(f) { f = 1 }
	if f == n.dim { return }
	n.dim = f
	apply(n)
}

// The current dim factor.
get_dim :: proc(n: ^Night_Light) -> f64 {
	return n == nil ? 1 : n.dim
}

// Whether the night light warms the screen right now (scheduled or always).
active :: proc(n: ^Night_Light) -> bool {
	return n != nil && n.enabled && n.target < NEUTRAL_K - 1
}

// The "night-light" action: switch nightLight.enabled in milk.json. Returns
// true when the file changed (the caller reloads the configuration, which
// applies it).
toggle :: proc(n: ^Night_Light, config_path: string) -> bool {
	if n == nil { return false }
	enabled := !n.enabled
	if !config.write_value(config_path, {"nightLight", "enabled"}, json.Boolean(enabled)) { return false }
	log.infof("Night light switched %s", enabled ? "on" : "off")
	return true
}

// Ask the running milk (on the display of `c`) to show `kelvin` for a few
// seconds; 0 ends the preview. Used by the settings app.
preview :: proc(c: ^tx.Connection, kelvin: int) {
	tx.send_client_message(c, PREVIEW_MESSAGE, {kelvin, 0, 0, 0, 0})
}

// RandR changes and previews. Returns true when the event was ours alone.
handle_event :: proc(n: ^Night_Light, ev: ^xlib.XEvent) -> bool {
	if n == nil || ev == nil { return false }
	if is_randr_event(n, ev) {
		n.rescan = true
		return false // others may want to know about RandR too
	}
	if ev.type == .ClientMessage && ev.xclient.window == n.c.root && ev.xclient.message_type == tx.atom(n.c, PREVIEW_MESSAGE) {
		k := f64(ev.xclient.data.l[0])
		now := tx.now()
		if k <= 0 {
			n.preview_until = now // ends on the next tick
		} else {
			n.preview = clamp(k, f64(config.NIGHT_LIGHT_MIN_K), NEUTRAL_K)
			n.preview_until = now + PREVIEW_TIME
		}
		return true
	}
	return false
}

tick :: proc(n: ^Night_Light, now: f64) {
	if n == nil { return }
	context.allocator = n.allocator
	if n.rescan {
		n.rescan = false
		gamma_scan(n)
		log.debugf("Night light: the screens changed (RandR); %d CRTC(s) with gamma ramps", len(n.gamma.crtcs))
		n.force = true
	}
	wall := wall_clock()
	if abs((wall - now) - n.clock_offset) > CLOCK_JUMP {
		// Resumed from sleep, or the clock was set: look at the schedule now,
		// and write the ramps again (some drivers reset them on resume).
		n.next_eval = 0
		n.force = n.force || n.clock_offset != 0
	}
	if now >= n.next_eval { evaluate(n, now, wall) }

	desired := n.target
	quick := false
	if n.preview > 0 {
		if now < n.preview_until {
			desired = n.preview
			quick = true
		} else {
			n.preview = 0
		}
	}
	if abs(desired - n.fade_to) > 0.5 {
		// Large jumps fade; the schedule's small steps are applied as they come.
		big := abs(1e6 / desired - 1e6 / n.shown) > 15 // mireds
		n.fade_from = n.shown
		n.fade_to = desired
		n.fade_start = now
		n.fade_len = big ? (quick ? PREVIEW_FADE : FADE_TIME) : 0
	}
	if n.fade_len > 0 {
		t := (now - n.fade_start) / n.fade_len
		if t >= 1 {
			n.fade_len = 0
			n.shown = n.fade_to
		} else {
			n.shown = mired_lerp(n.fade_from, n.fade_to, 1 - (1 - t) * (1 - t))
		}
	} else {
		n.shown = n.fade_to
	}
	apply(n)
}

next_timeout :: proc(n: ^Night_Light, now: f64) -> f64 {
	if n == nil { return -1 }
	if n.rescan { return 0 }
	if n.fade_len > 0 { return FRAME }
	t := max(n.next_eval - now, 0)
	if n.preview > 0 { t = min(t, max(n.preview_until - now, 0)) }
	return t
}

// Where the schedule is now.
@(private)
evaluate :: proc(n: ^Night_Light, now, wall: f64) {
	n.clock_offset = wall - now
	wait := MAX_SLEEP
	switch {
	case !n.enabled:
		n.night = 0
	case n.mode == .Always:
		n.night = 1
	case:
		factor, recheck := night_factor(n.schedule, wall)
		n.night = factor
		wait = clamp(recheck, 1, MAX_SLEEP)
	}
	target := mired_lerp(NEUTRAL_K, n.temperature, n.night)
	if abs(target - n.target) > 0.5 { log.debugf("Night light: %.0f K (night %.2f)", target, n.night) }
	n.target = target
	n.next_eval = now + wait
}

// Put the shown temperature and the dim factor on screen (only when they
// changed). Once a fade is over, the saved state on the root window learns
// the new temperature (for whoever takes over after a crash).
@(private)
apply :: proc(n: ^Night_Light) {
	wp := whitepoint(n.shown)
	mult := [3]f64{wp[0] * n.dim, wp[1] * n.dim, wp[2] * n.dim}
	gamma_apply(n, mult, n.force)
	n.force = false
	if n.gamma.modified && n.fade_len == 0 && abs(n.shown - n.gamma.stored_k) > 1 { store_originals(n) }
}

@(private)
wall_clock :: proc() -> f64 {
	return f64(time.to_unix_nanoseconds(time.now())) / 1e9
}
