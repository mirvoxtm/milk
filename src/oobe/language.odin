// The language choice (bar.locale) on the wizard's welcome page and in the
// settings app: Automatic (the system language), Português, English, Español.
package oobe

import "core:encoding/json"
import "core:strings"
import config "../config"
import tx "../tx"

// The index in config.LANGUAGE_CODES for a bar.locale value.
@(private)
locale_choice :: proc(locale: string) -> int {
	code := strings.to_lower(strings.trim_space(locale), context.temp_allocator)
	switch {
	case code == "" || code == "auto":   return 0
	case strings.has_prefix(code, "pt"): return 1
	case strings.has_prefix(code, "es"): return 3
	}
	return 2
}

// Each language is named in itself, so it can be found whatever the current one is.
@(private)
draw_language_control :: proc(w: ^Wizard, cv: ^tx.Canvas, r: tx.Rect) {
	labels := [4]string{tr(w, "Automático", "Automatic"), "Português", "English", "Español"}
	segmented(w, cv, r, labels[:], {.World, .None, .None, .None}, w.locale_index, .Language)
}

// Switch the labels at once; the settings app also saves bar.locale (and milk
// reloads), the wizard writes it with its other choices.
@(private)
language_pick :: proc(w: ^Wizard, index: int) {
	i := clamp(index, 0, len(config.LANGUAGE_CODES) - 1)
	if i == w.locale_index { return }
	w.locale_index = i
	w.lang = config.resolve_language(config.LANGUAGE_CODES[i])
	w.base_dirty = true
	w.dirty = true
	if w.mode == .Settings {
		set_edit(w, "bar.locale", json.String(config.LANGUAGE_CODES[i]))
		settings_changed(w, .Values)
	}
}
