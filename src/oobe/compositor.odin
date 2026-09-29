// Settings section "Efeitos": lactase, milk's compositor. milk only turns
// it on and off (compositor.enabled); shadows, animations, transparency,
// blur, corners and rules are set in lactase's own settings app, opened
// from here.
package oobe

import "core:log"
import "core:sys/posix"
import desktop "../desktop"
import tx "../tx"

@(private)
draw_effects_page :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	s := &w.set
	th := &w.theme
	_, installed := desktop.lactase_path()
	st := desktop.compositor_status(w.c)
	y := c.y
	row := next_row(w, cv, c, &y, tr(w, "Efeitos visuais", "Visual effects"),
	                tr(w, "Sombras, animações, transparência, desfoque e cantos suaves", "Shadows, animations, transparency, blur and smooth corners"))
	toggle(w, cv, row, s.fx_enabled, .Fx_Enabled)

	row = next_row(w, cv, c, &y, tr(w, "Compositor", "Compositor"), "")
	status: string
	switch {
	case !installed:
		status = tr(w, "lactase não está instalado", "lactase is not installed")
	case st.lactase:
		status = st.backend == "" ? tr(w, "lactase ativo", "lactase running") : (st.backend == "glx" ? tr(w, "lactase ativo (OpenGL)", "lactase running (OpenGL)") : tr(w, "lactase ativo (XRender)", "lactase running (XRender)"))
	case st.running:
		status = tr(w, "Outro compositor está ativo", "Another compositor is running")
	case:
		status = tr(w, "Parado", "Stopped")
	}
	dot := st.lactase ? tx.rgb(0x4C, 0xAF, 0x50) : th.muted
	sw := text_width(w, w.f_body, status)
	tx.canvas_fill_circle(cv, f32(row.x + row.w - sw - 16), f32(row.y + row.h / 2), 5, dot)
	text(w, w.f_body, row.x + row.w - sw, row.y, row.h, status, th.fg)

	y += 20
	if installed {
		label := tr(w, "Configurações do lactase", "lactase settings")
		bw := button_width(w, label, .Sparkles)
		button(w, cv, {c.x, y, bw, BUTTON_H}, label, .Filled, .Fx_Open, 0, .Sparkles)
		y += BUTTON_H + 14
		text(w, w.f_small, c.x, y, 22, ellipsize(w, w.f_small, tr(w,
		     "Sombras, animações, transparência, desfoque e regras por aplicativo ficam nas configurações do lactase.",
		     "Shadows, animations, transparency, blur and per-application rules live in lactase's settings."), c.w), mix(th.fg, th.muted, 0.55))
		y += 24
		text(w, w.f_small, c.x, y, 22, ellipsize(w, w.f_small, tr(w,
		     "Os cantos das janelas seguem o raio de Janelas; com o lactase eles ficam suavizados.",
		     "Window corners follow the radius under Windows; with lactase they are smooth."), c.w), mix(th.fg, th.muted, 0.55))
	} else {
		text(w, w.f_small, c.x, y, 22, ellipsize(w, w.f_small, tr(w,
		     "Instale o lactase com o instalador do milk (./install.sh) para ter sombras, animações e transparência.",
		     "Install lactase with milk's installer (./install.sh) for shadows, animations and transparency."), c.w), mix(th.fg, th.muted, 0.55))
	}
}

// Open lactase's settings app (detached; reaped in effects_tick).
@(private)
open_lactase_settings :: proc(w: ^Wizard) {
	pid, ok := desktop.lactase_run("settings")
	if !ok {
		log.warn("Settings: cannot open lactase's settings")
		return
	}
	append(&w.set.fx_children, posix.pid_t(pid))
}

// While the section is shown the status follows lactase starting and stopping.
@(private)
effects_tick :: proc(w: ^Wizard, now: f64) {
	s := &w.set
	for i := len(s.fx_children) - 1; i >= 0; i -= 1 {
		status: i32
		if posix.waitpid(s.fx_children[i], &status, {.NOHANG}) != 0 { unordered_remove(&s.fx_children, i) }
	}
	if s.section == .Effects && now >= s.fx_poll {
		s.fx_poll = now + 1
		w.dirty = true
	}
}

@(private)
effects_timeout :: proc(w: ^Wizard, now: f64) -> f64 {
	s := &w.set
	if s.section != .Effects { return -1 }
	return max(s.fx_poll - now, 0)
}
