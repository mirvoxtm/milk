// Wi-Fi menu (left click on the network widget): a card with the Wi-Fi
// switch, the wired and current connections, the visible networks (signal
// icon, lock for secured ones) and a rescan button. Clicking a network
// connects to it; a secured network without a saved profile opens an inline
// password field (the card holds the keyboard; Enter connects). Clicking the
// current network offers "Disconnect". Everything goes through nmcli jobs, so
// the event loop never waits for NetworkManager.
package bar

import "core:mem/virtual"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:fmt"
import xlib "vendor:x11/xlib"
import tx "../tx"

@(private) WIFI_REFRESH :: 8.0 // seconds between state/list refreshes while open

@(private)
Wifi_Network :: struct {
	ssid:    string,
	signal:  int,
	secured: bool,
	in_use:  bool,
}

@(private)
Wifi_Op :: enum { Radio, Connect, Connect_Profile, Disconnect }

Wifi_Menu :: struct {
	card:         Card,
	anchor:       i32, // screen x of the widget centre
	hits:         [dynamic]Menu_Hit,
	hover:        Menu_Hit, // action/index under the pointer
	// NetworkManager state (strings in state_arena)
	state_arena:  virtual.Arena,
	list_arena:   virtual.Arena,
	arenas:       bool,
	radio_known:  bool,
	radio_on:     bool,
	device:       string,   // Wi-Fi interface
	current:      string,   // active Wi-Fi connection (profile name)
	wired:        bool,
	wired_name:   string,
	profiles:     [dynamic]string, // saved Wi-Fi profiles
	networks:     [dynamic]Wifi_Network, // deduplicated, strongest first (list_arena)
	listed:       bool,
	// Jobs in flight
	querying:     bool,
	scanning:     bool,
	acting:       bool,
	next_refresh: f64,
	relist_at:    f64, // after switching the radio on
	next_frame:   f64, // spinner
	// Row state (owned strings)
	busy:         string, // SSID being connected / disconnected
	error_ssid:   string,
	error_text:   string,
	expanded:     string, // SSID whose row is open (password field / disconnect)
	password:     [dynamic]u8,
	input:        tx.Input, // input context on the card (dead keys, compose)
	input_focus:  bool,
}

// ---------------------------------------------------------------------------
// Open / close
// ---------------------------------------------------------------------------
@(private)
wifi_toggle :: proc(b: ^Bar, w: ^Widget) {
	m := &b.wifi
	if m.card.open {
		wifi_close(b)
		return
	}
	close_popups(b)
	if !m.arenas {
		_ = virtual.arena_init_growing(&m.state_arena)
		_ = virtual.arena_init_growing(&m.list_arena)
		m.arenas = true
	}
	anchor := widget_screen_rect(b, w)
	m.anchor = anchor.x + anchor.w / 2
	m.hover = {}
	set_owned(&m.expanded, "")
	set_owned(&m.error_ssid, "")
	if b.tools.nmcli {
		wifi_query(b)
		wifi_list(b, "auto")
		m.next_refresh = tx.now() + WIFI_REFRESH
	}
	wifi_draw(b)
	card_map(b, &m.card, true)
}

wifi_close :: proc(b: ^Bar) {
	m := &b.wifi
	if !m.card.open { return }
	wifi_clear_password(m)
	set_owned(&m.expanded, "")
	wifi_sync_input(b)
	card_hide(b, &m.card)
}

// The input context follows the card window; it has the focus while a
// password field is open.
@(private)
wifi_sync_input :: proc(b: ^Bar) {
	m := &b.wifi
	if m.card.win == 0 { return }
	if m.input.win != m.card.win {
		tx.input_close(&m.input)
		m.input = tx.input_open(b.c, m.card.win)
		m.input_focus = false
	}
	want := m.card.open && wifi_password_row(m) >= 0
	if want != m.input_focus {
		tx.input_focus(&m.input, want)
		m.input_focus = want
	}
}

@(private)
wifi_destroy :: proc(b: ^Bar) {
	m := &b.wifi
	tx.input_close(&m.input)
	card_destroy(b, &m.card)
	wifi_clear_password(m)
	delete(m.password)
	delete(m.hits)
	delete(m.busy)
	delete(m.error_ssid)
	delete(m.error_text)
	delete(m.expanded)
	if m.arenas {
		virtual.arena_destroy(&m.state_arena)
		virtual.arena_destroy(&m.list_arena)
	}
	m^ = {}
}

@(private)
wifi_busy :: proc(b: ^Bar) -> bool {
	m := &b.wifi
	return m.card.open && (m.scanning || m.acting)
}

// Periodic refresh, delayed relist and spinner frames; returns seconds to the next deadline.
@(private)
wifi_tick :: proc(b: ^Bar, now: f64) -> f64 {
	m := &b.wifi
	if !m.card.open || !b.tools.nmcli { return -1 }
	if m.relist_at > 0 && now >= m.relist_at {
		m.relist_at = 0
		wifi_list(b, "yes")
	}
	if now >= m.next_refresh {
		m.next_refresh = now + WIFI_REFRESH
		wifi_query(b)
		if m.radio_on { wifi_list(b, "no") }
	}
	if wifi_busy(b) && now >= m.next_frame {
		m.next_frame = now + 1.0 / 12
		wifi_draw(b)
	}
	next := m.next_refresh
	if m.relist_at > 0 { next = min(next, m.relist_at) }
	if wifi_busy(b) { next = min(next, m.next_frame) }
	return max(next - now, 0)
}

// ---------------------------------------------------------------------------
// nmcli jobs
// ---------------------------------------------------------------------------
@(private)
WIFI_STATE_SCRIPT :: `echo @@radio; nmcli -t -f WIFI radio 2>&1
echo @@devices; nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device 2>&1
echo @@profiles; nmcli -t -f NAME,TYPE connection show 2>&1`

@(private)
wifi_query :: proc(b: ^Bar) {
	m := &b.wifi
	if m.querying { return }
	m.querying = start_job(b, .Wifi_State, {"sh", "-c", WIFI_STATE_SCRIPT}, true, 8) != nil
}

// `rescan`: nmcli's --rescan value (auto, yes, no).
@(private)
wifi_list :: proc(b: ^Bar, rescan: string) {
	m := &b.wifi
	if m.scanning { return }
	argv := []string{"nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY,BARS", "dev", "wifi", "list", "--rescan", rescan}
	m.scanning = start_job(b, .Wifi_List, argv, true, 30) != nil
}

@(private)
wifi_action :: proc(b: ^Bar, argv: []string, ssid: string, op: Wifi_Op) {
	m := &b.wifi
	if m.acting { return }
	if start_job(b, .Wifi_Action, argv, true, 45, merge_stderr = true, tag = ssid, step = int(op)) == nil { return }
	m.acting = true
	set_owned(&m.busy, ssid)
	if m.error_ssid == ssid { set_owned(&m.error_ssid, "") }
}

@(private)
wifi_job_done :: proc(b: ^Bar, job: ^Job) {
	m := &b.wifi
	output := string(job.output[:])
	#partial switch job.kind {
	case .Wifi_State:
		m.querying = false
		wifi_parse_state(b, output)
	case .Wifi_List:
		m.scanning = false
		if job_succeeded(job) || len(output) > 0 { wifi_parse_list(b, output) }
	case .Wifi_Action:
		m.acting = false
		set_owned(&m.busy, "")
		op := Wifi_Op(job.step)
		ok := job_succeeded(job)
		switch op {
		case .Radio:
			if ok && m.radio_on { m.relist_at = tx.now() + 3 }
			if !ok { m.radio_on = !m.radio_on }
		case .Connect, .Connect_Profile:
			if ok {
				wifi_clear_password(m)
				set_owned(&m.expanded, "")
			} else {
				set_owned(&m.error_ssid, job.tag)
				set_owned(&m.error_text, wifi_error_text(b, output))
				// A saved profile without its secrets: ask for the password.
				if op == .Connect_Profile && strings.contains(strings.to_lower(output, context.temp_allocator), "secrets") {
					set_owned(&m.expanded, job.tag)
				}
			}
		case .Disconnect:
			set_owned(&m.expanded, "")
			if !ok {
				set_owned(&m.error_ssid, job.tag)
				set_owned(&m.error_text, error_line(output, tr(b, "Não foi possível desconectar", "Could not disconnect")))
			}
		}
		wifi_query(b)
		if m.radio_on { wifi_list(b, "no") }
	}
	if m.card.open { wifi_draw(b) }
}

@(private)
wifi_parse_state :: proc(b: ^Bar, output: string) {
	m := &b.wifi
	virtual.arena_free_all(&m.state_arena)
	alloc := virtual.arena_allocator(&m.state_arena)
	radio := strings.trim_space(output_section(output, "radio"))
	m.radio_known = radio == "enabled" || radio == "disabled"
	m.radio_on = radio == "enabled"
	m.device, m.current, m.wired, m.wired_name = "", "", false, ""
	for line in strings.split_lines(output_section(output, "devices"), context.temp_allocator) {
		f := nm_fields(line)
		if len(f) < 4 { continue }
		connected := strings.has_prefix(f[2], "connected")
		switch f[1] {
		case "wifi":
			if m.device == "" || connected { m.device = strings.clone(f[0], alloc) }
			if connected { m.current = strings.clone(f[3], alloc) }
		case "ethernet":
			if connected && !m.wired {
				m.wired = true
				m.wired_name = strings.clone(f[3], alloc)
			}
		}
	}
	m.profiles = make([dynamic]string, alloc)
	for line in strings.split_lines(output_section(output, "profiles"), context.temp_allocator) {
		f := nm_fields(line)
		if len(f) >= 2 && f[1] == "802-11-wireless" { append(&m.profiles, strings.clone(f[0], alloc)) }
	}
}

@(private)
wifi_parse_list :: proc(b: ^Bar, output: string) {
	m := &b.wifi
	virtual.arena_free_all(&m.list_arena)
	alloc := virtual.arena_allocator(&m.list_arena)
	nets := make([dynamic]Wifi_Network, alloc)
	outer: for line in strings.split_lines(output, context.temp_allocator) {
		f := nm_fields(line)
		if len(f) < 4 || f[1] == "" { continue }
		signal, _ := strconv.parse_int(strings.trim_space(f[2]), 10)
		security := strings.trim_space(f[3])
		net := Wifi_Network{signal = clamp(signal, 0, 100), secured = security != "" && security != "--", in_use = strings.trim_space(f[0]) == "*"}
		for &n in nets {
			if n.ssid == f[1] {
				n.signal = max(n.signal, net.signal)
				n.secured ||= net.secured
				n.in_use ||= net.in_use
				continue outer
			}
		}
		net.ssid = strings.clone(f[1], alloc)
		append(&nets, net)
	}
	slice.sort_by(nets[:], proc(a, c: Wifi_Network) -> bool { return a.signal > c.signal })
	m.networks = nets
	m.listed = true
}

// nmcli's failure, in words people understand when it is a common one.
@(private)
wifi_error_text :: proc(b: ^Bar, output: string) -> string {
	lower := strings.to_lower(output, context.temp_allocator)
	switch {
	case strings.contains(lower, "secrets were required"), strings.contains(lower, "802-1x"), strings.contains(lower, "psk"):
		return tr(b, "Senha incorreta ou necessária", "Wrong or missing password")
	case strings.contains(lower, "timeout"), strings.contains(lower, "timed out"):
		return tr(b, "Tempo esgotado ao conectar", "Timed out while connecting")
	case strings.contains(lower, "no network with ssid"):
		return tr(b, "Rede fora de alcance", "Network out of range")
	}
	msg := error_line(output, tr(b, "Não foi possível conectar", "Could not connect"))
	return strings.trim_prefix(msg, "Connection activation failed: ")
}

@(private)
wifi_has_profile :: proc(m: ^Wifi_Menu, ssid: string) -> bool {
	return slice.contains(m.profiles[:], ssid)
}

// The connected network: the list's in-use entry, else the active profile.
@(private)
wifi_current :: proc(m: ^Wifi_Menu) -> (ssid: string, signal: int, ok: bool) {
	for n in m.networks {
		if n.in_use { return n.ssid, n.signal, true }
	}
	if m.current != "" { return m.current, -1, true }
	return "", 0, false
}

// Index of the network whose password field is open.
@(private)
wifi_password_row :: proc(m: ^Wifi_Menu) -> int {
	if m.expanded == "" { return -1 }
	for n, i in m.networks {
		if n.ssid == m.expanded && !n.in_use && n.secured { return i }
	}
	return -1
}

@(private)
wifi_clear_password :: proc(m: ^Wifi_Menu) {
	for &ch in m.password { ch = 0 }
	clear(&m.password)
}

@(private)
wifi_signal_icon :: proc(signal: int) -> Icon {
	switch {
	case signal < 0:   return .Wifi_3
	case signal >= 75: return .Wifi_3
	case signal >= 50: return .Wifi_2
	case signal >= 25: return .Wifi_1
	}
	return .Wifi_0
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------
@(private)
wifi_event :: proc(b: ^Bar, ev: ^xlib.XEvent) {
	m := &b.wifi
	if !m.card.open { return }
	#partial switch ev.type {
	case .ButtonPress:
		x, y := card_local(&m.card, ev.xbutton.x_root, ev.xbutton.y_root)
		if !card_contains(&m.card, x, y) {
			wifi_close(b)
			return
		}
		if i32(ev.xbutton.button) != 1 { return }
		if i := menu_hit_at(m.hits[:], x, y); i >= 0 { wifi_activate(b, m.hits[i]) }
	case .MotionNotify:
		x, y := card_local(&m.card, ev.xmotion.x_root, ev.xmotion.y_root)
		hover: Menu_Hit
		if i := menu_hit_at(m.hits[:], x, y); i >= 0 { hover = m.hits[i] }
		if hover.action != m.hover.action || hover.index != m.hover.index {
			m.hover = hover
			wifi_draw(b)
		}
	case .LeaveNotify:
		if m.hover.action != .None {
			m.hover = {}
			wifi_draw(b)
		}
	case .KeyPress:
		// Composed text (dead keys: ´ + a = á) through the input method.
		text, sym := tx.input_lookup(&m.input, &ev.xkey)
		row := wifi_password_row(m)
		if row < 0 {
			if sym == .XK_Escape { wifi_close(b) }
			return
		}
		#partial switch sym {
		case .XK_Escape:
			wifi_clear_password(m)
			set_owned(&m.expanded, "")
		case .XK_BackSpace:
			// Drop the last UTF-8 sequence.
			n := len(m.password)
			for n > 0 {
				n -= 1
				if m.password[n] & 0xC0 != 0x80 { break }
			}
			resize(&m.password, n)
		case .XK_Return, xlib.KeySym(0xFF8D): // Return, KP_Enter
			wifi_connect_password(b, row)
		case:
			printable := text != ""
			for r in text {
				if r < 0x20 || r == 0x7F { printable = false }
			}
			if printable && len(m.password) + len(text) <= 128 { append(&m.password, ..transmute([]u8)text) }
		}
		wifi_draw(b)
	}
}

@(private)
wifi_activate :: proc(b: ^Bar, hit: Menu_Hit) {
	m := &b.wifi
	#partial switch hit.action {
	case .Wifi_Radio:
		if m.acting { return }
		m.radio_on = !m.radio_on
		wifi_action(b, {"nmcli", "radio", "wifi", m.radio_on ? "on" : "off"}, "", .Radio)
		if !m.radio_on { m.networks = nil }
	case .Wifi_Rescan:
		wifi_list(b, "yes")
	case .Wifi_Network:
		if hit.index >= len(m.networks) || m.acting { return }
		net := m.networks[hit.index]
		if m.expanded == net.ssid {
			// A second click folds the password field.
			wifi_clear_password(m)
			set_owned(&m.expanded, "")
		} else if wifi_has_profile(m, net.ssid) {
			wifi_action(b, {"nmcli", "--wait", "30", "connection", "up", "id", net.ssid}, net.ssid, .Connect_Profile)
		} else if net.secured {
			wifi_clear_password(m)
			set_owned(&m.expanded, net.ssid)
			if m.error_ssid == net.ssid { set_owned(&m.error_ssid, "") }
		} else {
			wifi_action(b, {"nmcli", "--wait", "30", "dev", "wifi", "connect", net.ssid}, net.ssid, .Connect)
		}
	case .Wifi_Current:
		ssid, _, ok := wifi_current(m)
		if !ok { return }
		set_owned(&m.expanded, m.expanded == ssid ? "" : ssid)
	case .Wifi_Disconnect:
		ssid, _, _ := wifi_current(m)
		if m.device != "" {
			wifi_action(b, {"nmcli", "device", "disconnect", m.device}, ssid, .Disconnect)
		} else {
			wifi_action(b, {"nmcli", "connection", "down", "id", m.current}, ssid, .Disconnect)
		}
	case .Wifi_Connect:
		wifi_connect_password(b, hit.index)
	case .Wifi_Editor:
		wifi_close(b)
		run_detached(b, "nm-connection-editor")
		return
	}
	if m.card.open { wifi_draw(b) }
}

@(private)
wifi_connect_password :: proc(b: ^Bar, index: int) {
	m := &b.wifi
	if index < 0 || index >= len(m.networks) || len(m.password) == 0 || m.acting { return }
	ssid := m.networks[index].ssid
	// nmcli receives the password as an argument (as with `nmcli dev wifi connect`).
	password := strings.clone(string(m.password[:]), context.temp_allocator)
	wifi_action(b, {"nmcli", "--wait", "30", "dev", "wifi", "connect", ssid, "password", password}, ssid, .Connect)
	wifi_clear_password(m)
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------
@(private)
wifi_draw :: proc(b: ^Bar) {
	m := &b.wifi
	th := &b.theme
	clear(&m.hits)
	W := i32(MENU_WIDTH)
	painter := painter_begin(b, W, menu_max_height(b), false)
	pa := &painter
	hovered :: proc(m: ^Wifi_Menu, action: Menu_Action, index := 0) -> bool {
		return m.hover.action == action && m.hover.index == index
	}
	hit :: proc(m: ^Wifi_Menu, r: tx.Rect, action: Menu_Action, index := 0) {
		append(&m.hits, Menu_Hit{r, action, index})
	}

	has_switch := b.tools.nmcli && m.radio_known
	sw := paint_menu_header(pa, "Wi-Fi", has_switch, m.radio_on)
	if has_switch { hit(m, sw, .Wifi_Radio) }
	y := i32(MENU_HEADER) + 4
	if !b.tools.nmcli {
		paint_menu_message(pa, y, tr(b, "O NetworkManager (nmcli) não está instalado.", "NetworkManager (nmcli) is not installed."))
		y += MENU_MESSAGE
	} else {
		if m.wired {
			sub := tr(b, "Conectado", "Connected")
			if m.wired_name != "" { sub = fmt.tprintf("%s · %s", sub, m.wired_name) }
			paint_menu_row(pa, y, .Ethernet, th.accent, tr(b, "Rede cabeada", "Wired network"), sub, th.muted, false)
			y += MENU_ROW
		}
		if m.radio_known && !m.radio_on {
			paint_menu_message(pa, y, tr(b, "O Wi-Fi está desligado.", "Wi-Fi is off."))
			y += MENU_MESSAGE
		} else {
			y = wifi_paint_current(b, pa, y)
			paint_menu_section(pa, y, tr(b, "Redes disponíveis", "Available networks"))
			rescan := tx.Rect{W - MENU_PAD - 30, y + 3, 30, 30}
			paint_icon_button(pa, rescan, .Refresh, m.scanning, hovered(m, .Wifi_Rescan))
			hit(m, rescan, .Wifi_Rescan)
			y += MENU_SECTION
			shown := 0
			for net, i in m.networks {
				if net.in_use { continue }
				if shown >= MENU_MAX_ROWS { break }
				shown += 1
				y = wifi_paint_network(b, pa, y, net, i)
			}
			if shown == 0 {
				msg: string
				switch {
				case m.scanning || !m.listed: msg = tr(b, "Procurando redes…", "Looking for networks…")
				case: msg = tr(b, "Nenhuma outra rede encontrada.", "No other networks found.")
				}
				paint_menu_message(pa, y, msg)
				y += MENU_MESSAGE
			}
		}
	}
	if b.tools.nm_connection_editor {
		paint_divider(pa, MENU_PAD, y + 4, W - 2 * MENU_PAD)
		r := tx.Rect{8, y + 10, W - 16, 36}
		if hovered(m, .Wifi_Editor) { tx.canvas_fill_rounded_rect(&pa.cv, r, 12, th.surface) }
		paint_icon(pa, .Settings, {MENU_PAD, r.y, 28, r.h}, th.foreground)
		paint_text(pa, b.font, MENU_PAD + 38, r.y, r.h, tr(b, "Configurações de rede", "Network settings"), th.foreground)
		hit(m, r, .Wifi_Editor)
		y += MENU_FOOTER
	} else {
		y += 8
	}
	painter_crop(pa, y)
	card_fit(b, &m.card, card_place(b, m.anchor, .Center, W, y), "milk wifi")
	painter_present(pa, &m.card)
	wifi_sync_input(b)
}

@(private)
wifi_paint_current :: proc(b: ^Bar, pa: ^Card_Painter, y0: i32) -> i32 {
	m := &b.wifi
	th := &b.theme
	ssid, signal, ok := wifi_current(m)
	if !ok { return y0 }
	y := y0
	W := pa.cv.w
	expanded := m.expanded == ssid
	sub := tr(b, "Conectado", "Connected")
	if signal >= 0 { sub = fmt.tprintf("%s · %d%%", sub, signal) }
	color := th.muted
	if m.acting && m.busy == ssid {
		sub = tr(b, "Desconectando…", "Disconnecting…")
	} else if m.error_ssid == ssid && m.error_text != "" {
		sub, color = m.error_text, th.warning
	}
	label := tr(b, "Desconectar", "Disconnect")
	button_w := tx.text_width(b.c, b.font, label) + 28
	reserve := expanded ? button_w + 8 : 0
	row_hover := m.hover.action == .Wifi_Current && !expanded
	paint_menu_row(pa, y, wifi_signal_icon(signal), th.accent, ssid, sub, color, row_hover, reserve)
	append(&m.hits, Menu_Hit{{8, y, W - 16, MENU_ROW}, .Wifi_Current, 0})
	if expanded {
		r := tx.Rect{W - MENU_PAD - button_w, y + (MENU_ROW - 30) / 2, button_w, 30}
		paint_button(pa, r, label, false, m.hover.action == .Wifi_Disconnect)
		append(&m.hits, Menu_Hit{r, .Wifi_Disconnect, 0})
	}
	y += MENU_ROW
	paint_divider(pa, MENU_PAD, y + 2, W - 2 * MENU_PAD)
	return y + 6
}

@(private)
wifi_paint_network :: proc(b: ^Bar, pa: ^Card_Painter, y0: i32, net: Wifi_Network, index: int) -> i32 {
	m := &b.wifi
	th := &b.theme
	y := y0
	W := pa.cv.w
	busy := m.acting && m.busy == net.ssid
	failed := m.error_ssid == net.ssid && m.error_text != ""
	saved := wifi_has_profile(m, net.ssid)
	sub := ""
	color := th.muted
	switch {
	case busy:   sub = tr(b, "Conectando…", "Connecting…")
	case failed: sub, color = m.error_text, th.warning
	case saved:  sub = tr(b, "Salva", "Saved")
	}
	open := m.expanded == net.ssid && net.secured
	row_hover := m.hover.action == .Wifi_Network && m.hover.index == index
	paint_menu_row(pa, y, wifi_signal_icon(net.signal), th.foreground, net.ssid, sub, color, row_hover || open, 28)
	if busy {
		paint_spinner(pa, f32(W - MENU_PAD - 11), f32(y) + f32(MENU_ROW) / 2, 7, th.foreground)
	} else if net.secured {
		paint_icon(pa, .Lock, {W - MENU_PAD - 22, y, 22, MENU_ROW}, th.muted)
	}
	append(&m.hits, Menu_Hit{{8, y, W - 16, MENU_ROW}, .Wifi_Network, index})
	y += MENU_ROW
	if !open || saved && !failed { return y }

	// Inline password field and the connect button.
	label := tr(b, "Conectar", "Connect")
	button_w := tx.text_width(b.c, b.font, label) + 28
	field := tx.Rect{MENU_PAD + 38, y + 4, W - 2 * MENU_PAD - 38 - button_w - 8, 34}
	tx.canvas_fill_rounded_rect(&pa.cv, field, 10, th.surface)
	tx.canvas_stroke_rounded_rect(&pa.cv, field, 10, 1.5, th.accent)
	inner := field.w - 24
	text_x := field.x + 12
	if len(m.password) == 0 {
		paint_text(pa, b.font, text_x + 5, field.y, field.h, tr(b, "Senha", "Password"), th.muted)
	} else {
		dots := strings.repeat("•", strings.rune_count(string(m.password[:])), context.temp_allocator)
		for len(dots) > 0 && tx.text_width(b.c, b.font, dots) > inner - 4 { dots = dots[len("•"):] } // show the tail
		paint_text(pa, b.font, text_x, field.y, field.h, dots, th.foreground)
		text_x += tx.text_width(b.c, b.font, dots) + 1
	}
	tx.canvas_fill_rect(&pa.cv, {text_x, field.y + 9, 2, field.h - 18}, th.accent) // caret
	r := tx.Rect{field.x + field.w + 8, field.y, button_w, field.h}
	paint_button(pa, r, label, true, m.hover.action == .Wifi_Connect)
	append(&m.hits, Menu_Hit{r, .Wifi_Connect, index})
	return y + MENU_FIELD
}

// Replace an owned string.
@(private)
set_owned :: proc(dst: ^string, value: string) {
	if dst^ == value { return }
	delete(dst^)
	dst^ = value == "" ? "" : strings.clone(value)
}
