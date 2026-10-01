// Settings → Bloqueio e inatividade: the lock screen and what happens after a
// while without input (milk.json "idle" and "lock"; package lock).
package oobe

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import tx "../tx"

// The delays the steppers walk through (seconds; 0 = never).
@(private, rodata)
IDLE_STEPS := []int{0, 30, 60, 120, 180, 300, 600, 900, 1200, 1800, 2700, 3600, 5400, 7200}

@(private)
lock_load_values :: proc(w: ^Wizard) {
	s := &w.set
	cfg := w.cfg
	s.lock_enabled = cfg.lock.enabled
	s.lock_on_suspend = cfg.lock.on_suspend
	s.inhibit_fullscreen = cfg.idle.inhibit_fullscreen
	s.dim_after = cfg.idle.dim_after
	s.lock_after = cfg.idle.lock_after
	s.screen_off_after = cfg.idle.screen_off_after
	s.suspend_after = cfg.idle.suspend_after
}

// "Nunca", "30 s", "5 min", "1 h", "1 h 30 min".
@(private)
idle_label :: proc(w: ^Wizard, seconds: int) -> string {
	switch {
	case seconds <= 0:          return tr(w, "Nunca", "Never")
	case seconds < 60:          return fmt.tprintf("%d s", seconds)
	case seconds < 3600:        return fmt.tprintf("%d min", seconds / 60)
	case seconds % 3600 == 0:   return fmt.tprintf("%d h", seconds / 3600)
	}
	return fmt.tprintf("%d h %d min", seconds / 3600, seconds % 3600 / 60)
}

// The next (dir = 1) or previous (-1) delay of IDLE_STEPS from `value`.
@(private)
idle_step :: proc(value, dir: int) -> int {
	if dir > 0 {
		for v in IDLE_STEPS { if v > value { return v } }
		return IDLE_STEPS[len(IDLE_STEPS) - 1]
	}
	for i := len(IDLE_STEPS) - 1; i >= 0; i -= 1 {
		if IDLE_STEPS[i] < value { return IDLE_STEPS[i] }
	}
	return 0
}

@(private)
rows_lock :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect, y: ^i32) {
	s := &w.set
	row := next_row(w, cv, c, y, tr(w, "Bloquear automaticamente", "Lock automatically"),
	                tr(w, "Pedir a senha depois de um tempo sem uso", "Ask for the password after a while without use"))
	toggle(w, cv, row, s.lock_enabled, .Lock_Enabled)
	row = next_row(w, cv, c, y, tr(w, "Bloquear após", "Lock after"), tr(w, "Sem usar o teclado nem o mouse", "Without keyboard or mouse input"), !s.lock_enabled)
	stepper(w, cv, row, idle_label(w, s.lock_after), .Lock_After)
	row = next_row(w, cv, c, y, tr(w, "Escurecer a tela após", "Dim the screen after"), tr(w, "Um aviso antes de bloquear ou desligar", "A warning before locking or turning off"))
	stepper(w, cv, row, idle_label(w, s.dim_after), .Dim_After)
	row = next_row(w, cv, c, y, tr(w, "Desligar a tela após", "Turn the screen off after"), "")
	stepper(w, cv, row, idle_label(w, s.screen_off_after), .Screen_Off_After)
	row = next_row(w, cv, c, y, tr(w, "Suspender após", "Suspend after"), tr(w, "O computador entra em repouso", "The computer goes to sleep"))
	stepper(w, cv, row, idle_label(w, s.suspend_after), .Suspend_After)
	row = next_row(w, cv, c, y, tr(w, "Bloquear ao suspender", "Lock when suspending"), tr(w, "Também ao hibernar", "Also when hibernating"))
	toggle(w, cv, row, s.lock_on_suspend, .Lock_On_Suspend)
	row = next_row(w, cv, c, y, tr(w, "Manter ativa em tela cheia", "Stay awake in fullscreen"),
	               tr(w, "Uma janela em tela cheia conta como uso", "A fullscreen window counts as use"))
	toggle(w, cv, row, s.inhibit_fullscreen, .Inhibit_Fullscreen)

	// "Lock now" and how to.
	th := &w.theme
	y^ += 14
	if y^ + BUTTON_H > c.y + c.h { return }
	label := tr(w, "Bloquear agora", "Lock now")
	bw := button_width(w, label, .Lock)
	button(w, cv, {c.x, y^, bw, BUTTON_H}, label, .Tonal, .Lock_Now, 0, .Lock)
	hint := tr(w, "Players de vídeo e navegadores adiam a inatividade enquanto tocam.", "Video players and browsers hold idle off while they play.")
	if keys := builtin_label(w, "lock"); keys != "" {
		hint = fmt.tprintf(tr(w, "Atalho: %s. %s", "Shortcut: %s. %s"), keys, hint)
	}
	hx := c.x + bw + 16
	text(w, w.f_small, hx, y^, BUTTON_H, ellipsize(w, w.f_small, hint, c.x + c.w - hx), mix(th.fg, th.muted, 0.55))
}

@(private)
lock_step :: proc(w: ^Wizard, ctrl: Control, dir: int) -> bool {
	s := &w.set
	#partial switch ctrl {
	case .Lock_After:
		s.lock_after = idle_step(s.lock_after, dir)
		set_edit(w, "idle.lockAfter", json.Integer(s.lock_after))
	case .Dim_After:
		s.dim_after = idle_step(s.dim_after, dir)
		set_edit(w, "idle.dimAfter", json.Integer(s.dim_after))
	case .Screen_Off_After:
		s.screen_off_after = idle_step(s.screen_off_after, dir)
		set_edit(w, "idle.screenOffAfter", json.Integer(s.screen_off_after))
	case .Suspend_After:
		s.suspend_after = idle_step(s.suspend_after, dir)
		set_edit(w, "idle.suspendAfter", json.Integer(s.suspend_after))
	case:
		return false
	}
	return true
}

@(private)
lock_toggle :: proc(w: ^Wizard, ctrl: Control) -> bool {
	s := &w.set
	#partial switch ctrl {
	case .Lock_Enabled:
		s.lock_enabled = !s.lock_enabled
		set_edit(w, "lock.enabled", json.Boolean(s.lock_enabled))
	case .Lock_On_Suspend:
		s.lock_on_suspend = !s.lock_on_suspend
		set_edit(w, "lock.onSuspend", json.Boolean(s.lock_on_suspend))
	case .Inhibit_Fullscreen:
		s.inhibit_fullscreen = !s.inhibit_fullscreen
		set_edit(w, "idle.inhibitFullscreen", json.Boolean(s.inhibit_fullscreen))
	case:
		return false
	}
	return true
}

// "Lock now": `milk lock` (the running milk locks and watches the lock screen).
@(private)
lock_now :: proc(w: ^Wizard) {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil { return }
	desc := os.Process_Desc{command = {exe, "lock", "--config", w.config_path, "--runtime-root", w.runtime_root}}
	if p, perr := os.process_start(desc); perr == nil {
		_ = p
	} else {
		log.warnf("Settings: cannot run milk lock: %v", perr)
	}
}
