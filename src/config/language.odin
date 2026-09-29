package config

import "base:runtime"
import "core:os"
import "core:strings"

// The language of milk's own text (bar menus, panels, the settings app, the
// setup wizard, dates). Portuguese and English are written next to each other
// where the text is used; Spanish comes from SPANISH (spanish.odin), keyed by
// the English text, and falls back to English for anything not translated.
Language :: enum u8 { English, Portuguese, Spanish }

// The bar.locale values the settings app offers, in LANGUAGE_CHOICES order.
LANGUAGE_CODES := [4]string{"auto", "pt-BR", "en", "es"}

// bar.locale: "auto" follows LC_ALL / LC_MESSAGES / LANG; otherwise the first
// two letters pick the language ("pt-BR", "pt_PT", "es-MX", "en-GB"...).
resolve_language :: proc(locale: string) -> Language {
	code := strings.to_lower(strings.trim_space(locale), context.temp_allocator)
	if code == "" || code == "auto" {
		code = "en"
		for name in ([]string{"LC_ALL", "LC_MESSAGES", "LANG"}) {
			if v, found := os.lookup_env(name, context.temp_allocator); found && v != "" && v != "C" && v != "POSIX" {
				code = strings.to_lower(v, context.temp_allocator)
				break
			}
		}
	}
	switch {
	case strings.has_prefix(code, "pt"): return .Portuguese
	case strings.has_prefix(code, "es"): return .Spanish
	}
	return .English
}

// The text in `lang`: pt for Portuguese, en for English, the Spanish
// translation of en for Spanish.
tr :: proc(lang: Language, pt, en: string) -> string {
	switch lang {
	case .Portuguese:
		return pt
	case .Spanish:
		if es, found := spanish_index[en]; found { return es }
	case .English:
	}
	return en
}

// The locale code for desktop entries and similar (Name[pt_BR], Name[es]).
language_code :: proc(lang: Language) -> string {
	switch lang {
	case .Portuguese: return "pt_BR"
	case .Spanish:    return "es"
	case .English:
	}
	return "en"
}

@(private)
spanish_index: map[string]string

@(init, private)
init_spanish_index :: proc "contextless" () {
	context = runtime.default_context()
	spanish_index = make(map[string]string, len(SPANISH))
	for pair in SPANISH { spanish_index[pair[0]] = pair[1] }
}

// Day and month names for the bar's clock/date and the calendar.
@(rodata)
WEEKDAYS := [Language][7]string{
	.English    = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"},
	.Portuguese = {"dom", "seg", "ter", "qua", "qui", "sex", "sáb"},
	.Spanish    = {"dom", "lun", "mar", "mié", "jue", "vie", "sáb"},
}
@(rodata)
WEEKDAYS_FULL := [Language][7]string{
	.English    = {"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"},
	.Portuguese = {"domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado"},
	.Spanish    = {"domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"},
}
@(rodata)
WEEKDAY_INITIALS := [Language][7]string{
	.English    = {"Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"},
	.Portuguese = {"D", "S", "T", "Q", "Q", "S", "S"},
	.Spanish    = {"D", "L", "M", "X", "J", "V", "S"},
}
@(rodata)
MONTHS := [Language][12]string{
	.English    = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"},
	.Portuguese = {"jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"},
	.Spanish    = {"ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"},
}
@(rodata)
MONTHS_FULL := [Language][12]string{
	.English    = {"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"},
	.Portuguese = {"janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"},
	.Spanish    = {"enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"},
}
