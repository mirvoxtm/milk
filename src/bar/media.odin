// Media widget source: a `playerctl --follow` line stream when playerctl is
// installed, otherwise a busctl snapshot of the MPRIS players every few
// seconds, otherwise the idle text.
package bar

import "core:encoding/json"
import "core:log"
import "core:mem/virtual"
import "core:strings"
import tx "../tx"

MEDIA_POLL_INTERVAL   :: 3.0
STREAM_RESTART_DELAY  :: 5.0
STREAM_MAX_FAILURES   :: 3

Media_Status :: enum { Idle, Playing, Paused }
Media_Source :: enum { None, Stream, Poll }

Media_State :: struct {
	source:     Media_Source,
	status:     Media_Status,
	text:       string, // "Artist - Title"
	player:     string, // MPRIS bus name of the shown player (poll mode)
	stream:     ^Job,
	failures:   int,
	restart_at: f64, // 0 = no restart pending
	next_poll:  f64,
	polling:    bool,
}

// Busctl snapshot: "@player NAME" followed by the PlaybackStatus and Metadata
// properties as JSON lines.
MEDIA_POLL_SCRIPT :: `busctl --user list --no-legend --no-pager --acquired 2>/dev/null | while read -r n _; do
case "$n" in org.mpris.MediaPlayer2.*)
echo "@player $n"
busctl --user --json=short get-property "$n" /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player PlaybackStatus Metadata 2>/dev/null;;
esac
done`

PLAYERCTL_FORMAT :: "{{status}}\t{{artist}}\t{{title}}\t{{playerName}}"

@(private)
has_widget :: proc(b: ^Bar, kind: Widget_Kind) -> bool {
	for w in b.widgets {
		if w.kind == kind { return true }
	}
	return false
}

@(private)
start_media :: proc(b: ^Bar, now: f64) {
	m := &b.media
	m.failures = 0
	m.restart_at = 0
	if !has_widget(b, .Media) {
		m.source = .None
		return
	}
	switch {
	case b.tools.playerctl:
		m.source = .Stream
		start_media_stream(b)
	case b.tools.busctl:
		m.source = .Poll
		m.next_poll = now
	case:
		m.source = .None
		log.info("Media widget: neither playerctl nor busctl is installed; showing the idle text")
	}
}

@(private)
stop_media :: proc(b: ^Bar) {
	m := &b.media
	if m.stream != nil {
		kill_job(b, m.stream)
		m.stream = nil
	}
	m.source = .None
	m.restart_at = 0
	set_media(b, .Idle, "", "")
}

@(private)
start_media_stream :: proc(b: ^Bar) {
	m := &b.media
	m.stream = start_job(b, .Media_Stream, {"playerctl", "--follow", "metadata", "--format", PLAYERCTL_FORMAT}, true, 0)
	if m.stream == nil { media_stream_failed(b, 0) }
}

// New bytes on the playerctl stream: handle every complete line.
@(private)
media_stream_input :: proc(b: ^Bar, job: ^Job) {
	for {
		nl := -1
		for ch, i in job.output {
			if ch == '\n' { nl = i; break }
		}
		if nl < 0 { break }
		line := strings.clone(string(job.output[:nl]), context.temp_allocator)
		remove_range(&job.output, 0, nl + 1)
		parse_stream_line(b, line)
	}
	if len(job.output) > 1 << 16 { clear(&job.output) } // no newline in sight: drop garbage
}

@(private)
parse_stream_line :: proc(b: ^Bar, line: string) {
	fields := strings.split(strings.trim_right(line, "\r"), "\t", context.temp_allocator)
	status := len(fields) > 0 ? strings.trim_space(fields[0]) : ""
	artist := len(fields) > 1 ? strings.trim_space(fields[1]) : ""
	title := len(fields) > 2 ? strings.trim_space(fields[2]) : ""
	player := len(fields) > 3 ? strings.trim_space(fields[3]) : ""
	switch status {
	case "Playing": set_media(b, .Playing, media_text(artist, title, player), player)
	case "Paused":  set_media(b, .Paused, media_text(artist, title, player), player)
	case:           set_media(b, .Idle, "", "")
	}
}

@(private)
media_stream_ended :: proc(b: ^Bar, job: ^Job, now: f64) {
	m := &b.media
	if m.stream != job { return }
	m.stream = nil
	media_stream_failed(b, now - job.started)
}

// The stream died: restart it a few times, then fall back to polling.
@(private)
media_stream_failed :: proc(b: ^Bar, ran_for: f64) {
	m := &b.media
	set_media(b, .Idle, "", "")
	if ran_for > 60 { m.failures = 0 }
	m.failures += 1
	if m.failures < STREAM_MAX_FAILURES {
		m.restart_at = tx.now() + STREAM_RESTART_DELAY
		return
	}
	m.restart_at = 0
	if b.tools.busctl {
		log.warn("playerctl keeps exiting; polling MPRIS players with busctl instead")
		m.source = .Poll
		m.next_poll = tx.now()
	} else {
		log.warn("playerctl keeps exiting; media widget disabled")
		m.source = .None
	}
}

// Timers of the media source (called from tick).
@(private)
media_tick :: proc(b: ^Bar, now: f64) {
	m := &b.media
	switch m.source {
	case .Stream:
		if m.stream == nil && m.restart_at > 0 && now >= m.restart_at {
			m.restart_at = 0
			start_media_stream(b)
		}
	case .Poll:
		if !m.polling && now >= m.next_poll {
			if start_job(b, .Media_Poll, {"sh", "-c", MEDIA_POLL_SCRIPT}, true) != nil {
				m.polling = true
			} else {
				m.next_poll = now + MEDIA_POLL_INTERVAL
			}
		}
	case .None:
	}
}

@(private)
media_deadline :: proc(b: ^Bar) -> f64 {
	m := &b.media
	switch m.source {
	case .Stream: if m.stream == nil && m.restart_at > 0 { return m.restart_at }
	case .Poll:   if !m.polling { return m.next_poll }
	case .None:
	}
	return -1
}

Mpris_Player :: struct {
	name, status, artist, title: string,
}

@(private)
media_poll_done :: proc(b: ^Bar, output: string, now: f64) {
	m := &b.media
	m.polling = false
	m.next_poll = now + MEDIA_POLL_INTERVAL
	if m.source != .Poll { return }

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { return }
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)

	players := make([dynamic]Mpris_Player, scratch)
	current: ^Mpris_Player
	for raw in strings.split_lines(output, scratch) {
		line := strings.trim_space(raw)
		if strings.has_prefix(line, "@player ") {
			append(&players, Mpris_Player{name = strings.trim_space(line[len("@player "):])})
			current = &players[len(players) - 1]
			continue
		}
		if current == nil || !strings.has_prefix(line, "{") { continue }
		value, err := json.parse_string(line, .JSON, false, scratch)
		if err != .None { continue }
		obj, is_obj := value.(json.Object)
		if !is_obj { continue }
		kind, _ := obj["type"].(json.String)
		switch kind {
		case "s":
			current.status, _ = obj["data"].(json.String)
		case "a{sv}":
			meta, _ := obj["data"].(json.Object)
			current.title = variant_string(meta, "xesam:title", scratch)
			current.artist = variant_string(meta, "xesam:artist", scratch)
		}
	}

	// Keep showing the same player while it plays; otherwise the first playing
	// one; otherwise a paused one.
	chosen: ^Mpris_Player
	for &p in players {
		if p.status == "Playing" && p.name == m.player { chosen = &p; break }
	}
	if chosen == nil {
		for &p in players {
			if p.status == "Playing" { chosen = &p; break }
		}
	}
	if chosen == nil {
		for &p in players {
			if p.status == "Paused" && p.name == m.player { chosen = &p; break }
		}
	}
	if chosen == nil {
		for &p in players {
			if p.status == "Paused" { chosen = &p; break }
		}
	}
	if chosen == nil {
		set_media(b, .Idle, "", "")
		return
	}
	status: Media_Status = chosen.status == "Playing" ? .Playing : .Paused
	set_media(b, status, media_text(chosen.artist, chosen.title, player_label(chosen.name)), chosen.name)
}

// A string or string-array variant inside an a{sv} dictionary.
@(private)
variant_string :: proc(dict: json.Object, key: string, allocator := context.temp_allocator) -> string {
	entry, ok := dict[key].(json.Object)
	if !ok { return "" }
	#partial switch v in entry["data"] {
	case json.String:
		return v
	case json.Array:
		parts := make([dynamic]string, allocator)
		for item in v {
			if s, is_str := item.(json.String); is_str && s != "" { append(&parts, s) }
		}
		return strings.join(parts[:], ", ", allocator)
	}
	return ""
}

// "org.mpris.MediaPlayer2.brave.instance1267" -> "Brave"
@(private)
player_label :: proc(bus_name: string) -> string {
	name := strings.trim_prefix(bus_name, "org.mpris.MediaPlayer2.")
	if dot := strings.index_byte(name, '.'); dot > 0 { name = name[:dot] }
	if name == "" { return "" }
	return strings.concatenate({strings.to_upper(name[:1], context.temp_allocator), name[1:]}, context.temp_allocator)
}

@(private)
media_text :: proc(artist, title, player: string) -> string {
	switch {
	case artist != "" && title != "": return strings.concatenate({artist, " - ", title}, context.temp_allocator)
	case title != "":                 return title
	case artist != "":                return artist
	}
	return player
}

@(private)
set_media :: proc(b: ^Bar, status: Media_Status, text: string, player: string) {
	m := &b.media
	if status != m.status || text != m.text { b.dirty = true }
	m.status = status
	if text != m.text {
		delete(m.text)
		m.text = sanitize_line(text)
	}
	if player != m.player {
		delete(m.player)
		m.player = strings.clone(player)
	}
}

// Click on the media widget: play/pause the shown player.
@(private)
media_toggle :: proc(b: ^Bar) {
	m := &b.media
	switch {
	case b.tools.playerctl:
		start_job(b, .Media_Control, {"playerctl", "play-pause"}, false)
	case b.tools.busctl && strings.has_prefix(m.player, "org.mpris.MediaPlayer2."):
		start_job(b, .Media_Control, {"busctl", "--user", "call", m.player, "/org/mpris/MediaPlayer2",
		                              "org.mpris.MediaPlayer2.Player", "PlayPause"}, false)
	}
}

@(private)
media_control_done :: proc(b: ^Bar, now: f64) {
	m := &b.media
	if m.source == .Poll && !m.polling { m.next_poll = min(m.next_poll, now + 0.2) }
}
