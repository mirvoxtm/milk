// Dimming before the screen locks or turns off.
//
// The screen's gamma belongs to the night-light module (package nightlight),
// which also keeps the original ramps and gives them back. The idle manager
// only computes a brightness factor (`idle_dim_factor`: 1 = normal,
// DIM_LEVEL = dimmed, animated) and hands every change to the hook that
// main.odin installs (nightlight.set_dim), which multiplies it into its own
// ramp: a warm night-light screen is dimmed, not turned back to daylight.
package lock

import tx "../tx"

// Receives a brightness factor (0.05 .. 1).
Dim_Hook :: proc(data: rawptr, factor: f64)

@(private) g_dim_hook: Dim_Hook
@(private) g_dim_data: rawptr

// Who applies the dimming (nil: the screen is never dimmed).
set_dim_hook :: proc(hook: Dim_Hook, data: rawptr) {
	g_dim_hook = hook
	g_dim_data = data
}

// Brightness factor for every monitor: 1.0 is the screen as it was.
apply_dim :: proc(c: ^tx.Connection, factor: f64) {
	if g_dim_hook != nil { g_dim_hook(g_dim_data, clamp(factor, 0.05, 1)) }
}

// milk exits: undim (the night-light module restores its ramps itself).
dim_shutdown :: proc(c: ^tx.Connection) {
	apply_dim(c, 1)
	g_dim_hook, g_dim_data = nil, nil
}
