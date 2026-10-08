// `milk doctor`: checks the installation and says how to fix what is wrong —
// the build tools, the programs milk and its widgets run (with the package
// that provides each on this distribution), fonts, the login entry, the
// configuration and programs that would fight milk for its jobs (another
// notification daemon, compositor or tray). Exit status 1 when something
// needed is missing.
package milk

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import config "../config"
import desktop "../desktop"
import tx "../tx"

@(private="file")
Doctor :: struct {
	problems, warnings: int,
	family:             string, // arch, debian, fedora, opensuse, void or ""
	color:              bool,
}

@(private="file")
say :: proc(dr: ^Doctor, mark: string, text: string, hint := "") {
	switch mark {
	case "ok":
		fmt.printfln("  %s %s", dr.color ? "\x1b[1;32m✓\x1b[0m" : "✓", text)
	case "warn":
		dr.warnings += 1
		fmt.printfln("  %s %s", dr.color ? "\x1b[1;33m!\x1b[0m" : "!", text)
	case "fail":
		dr.problems += 1
		fmt.printfln("  %s %s", dr.color ? "\x1b[1;31m✗\x1b[0m" : "✗", text)
	case "info":
		fmt.printfln("  %s %s", dr.color ? "\x1b[2m•\x1b[0m" : "•", text)
	}
	if hint != "" { fmt.printfln("      %s", hint) }
}

@(private="file")
section :: proc(dr: ^Doctor, title: string) {
	fmt.printfln("\n%s%s%s", dr.color ? "\x1b[1m" : "", title, dr.color ? "\x1b[0m" : "")
}

// The distribution family, as the installer recognises it.
@(private="file")
distro_family :: proc() -> string {
	data, err := os.read_entire_file("/etc/os-release", context.temp_allocator)
	if err != nil { return "" }
	ids := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(string(data), context.temp_allocator) {
		for key in ([]string{"ID=", "ID_LIKE="}) {
			if strings.has_prefix(line, key) {
				for id in strings.fields(strings.trim(line[len(key):], "\"'"), context.temp_allocator) { append(&ids, id) }
			}
		}
	}
	for id in ids {
		switch {
		case id == "arch" || id == "archarm" || strings.has_prefix(id, "manjaro") || id == "endeavouros" || id == "cachyos" || id == "garuda" || id == "artix":
			return "arch"
		case id == "debian" || id == "ubuntu" || id == "linuxmint" || id == "pop" || id == "elementary" || id == "zorin" || id == "kali" || id == "raspbian" || id == "neon":
			return "debian"
		case id == "fedora" || id == "nobara" || id == "ultramarine" || id == "rhel" || id == "centos":
			return "fedora"
		case strings.has_prefix(id, "opensuse") || id == "suse":
			return "opensuse"
		case id == "void":
			return "void"
		}
	}
	return ""
}

// What a program is called in the family's packages: arch, debian, fedora, opensuse, void.
@(private="file")
Package_Names :: struct { program: string, names: [5]string }

@(private="file", rodata)
PACKAGES := []Package_Names{
	{"feh", {"feh", "feh", "feh", "feh", "feh"}},
	{"rsvg-convert", {"librsvg", "librsvg2-bin", "librsvg2-tools", "rsvg-convert", "librsvg-utils"}},
	{"magick", {"imagemagick", "imagemagick", "ImageMagick", "ImageMagick", "ImageMagick"}},
	{"xdg-user-dirs-update", {"xdg-user-dirs", "xdg-user-dirs", "xdg-user-dirs", "xdg-user-dirs", "xdg-user-dirs"}},
	{"xdg-open", {"xdg-utils", "xdg-utils", "xdg-utils", "xdg-utils", "xdg-utils"}},
	{"notify-send", {"libnotify", "libnotify-bin", "libnotify", "libnotify-tools", "libnotify"}},
	{"gio", {"glib2", "libglib2.0-bin", "glib2", "glib2-tools", "glib"}},
	{"wpctl", {"wireplumber", "wireplumber", "wireplumber", "wireplumber", "wireplumber"}},
	{"nmcli", {"networkmanager", "network-manager", "NetworkManager", "NetworkManager", "NetworkManager"}},
	{"bluetoothctl", {"bluez-utils", "bluez", "bluez", "bluez", "bluez"}},
	{"brightnessctl", {"brightnessctl", "brightnessctl", "brightnessctl", "brightnessctl", "brightnessctl"}},
	{"playerctl", {"playerctl", "playerctl", "playerctl", "playerctl", "playerctl"}},
	{"setxkbmap", {"xorg-setxkbmap", "x11-xkb-utils", "setxkbmap", "setxkbmap", "setxkbmap"}},
	{"fc-match", {"fontconfig", "fontconfig", "fontconfig", "fontconfig", "fontconfig"}},
	{"git", {"git", "git", "git", "git", "git"}},
	{"clang", {"clang", "clang", "clang", "clang", "clang"}},
	{"bsdtar", {"libarchive", "libarchive-tools", "bsdtar", "bsdtar", "bsdtar"}},
	{"mpv", {"mpv", "mpv", "mpv", "mpv", "mpv"}},
	{"ffmpegthumbnailer", {"ffmpegthumbnailer", "ffmpegthumbnailer", "ffmpegthumbnailer", "ffmpegthumbnailer", "ffmpegthumbnailer"}},
	{"matugen", {"matugen", "", "matugen", "", "matugen"}},
	{"alacritty", {"alacritty", "alacritty", "alacritty", "alacritty", "alacritty"}},
	{"rofi", {"rofi", "rofi", "rofi", "rofi", "rofi"}},
	{"fd", {"fd", "fd-find", "fd-find", "fd", "fd"}},
	{"maim", {"maim", "maim", "maim", "maim", "maim"}},
	{"xclip", {"xclip", "xclip", "xclip", "xclip", "xclip"}},
	{"flameshot", {"flameshot", "flameshot", "flameshot", "flameshot", "flameshot"}},
	{"qt5ct", {"qt5ct", "qt5ct", "qt5ct", "qt5ct", "qt5ct"}},
	{"qt6ct", {"qt6ct", "qt6ct", "qt6ct", "qt6ct", "qt6ct"}},
}

// "install it: sudo pacman -S feh", or the installer when there is no package.
@(private="file")
install_hint :: proc(dr: ^Doctor, program: string) -> string {
	names: [5]string
	known := false
	for p in PACKAGES {
		if p.program == program { names, known = p.names, true }
	}
	if !known || dr.family == "" { return "install it with your package manager, or run milk's install.sh" }
	index := 0
	command := ""
	switch dr.family {
	case "arch":     index, command = 0, "sudo pacman -S"
	case "debian":   index, command = 1, "sudo apt install"
	case "fedora":   index, command = 2, "sudo dnf install"
	case "opensuse": index, command = 3, "sudo zypper install"
	case "void":     index, command = 4, "sudo xbps-install -S"
	}
	if names[index] == "" { return "not packaged here: run milk's install.sh, which downloads it" }
	return fmt.tprintf("install it: %s %s", command, names[index])
}

// The first word of a configured command (`alacritty -e ...` → alacritty).
@(private="file")
command_program :: proc(command: string) -> string {
	fields := strings.fields(command, context.temp_allocator)
	for f in fields {
		if strings.contains_rune(f, '=') { continue } // VAR=value prefixes
		return filepath.base(f)
	}
	return ""
}

@(private="file")
check_program :: proc(dr: ^Doctor, program, purpose: string, required: bool) -> bool {
	if path, found := find_in_path(program); found {
		say(dr, "ok", fmt.tprintf("%s — %s (%s)", program, purpose, path))
		return true
	}
	say(dr, required ? "fail" : "warn", fmt.tprintf("%s is missing — %s", program, purpose), install_hint(dr, program))
	return false
}

// Running processes by command name (/proc/*/comm).
@(private="file")
running_commands :: proc() -> map[string]bool {
	out := make(map[string]bool, allocator = context.temp_allocator)
	entries, err := os.read_all_directory_by_path("/proc", context.temp_allocator)
	if err != nil { return out }
	for e in entries {
		if _, ok := strconv.parse_int(os.base(e.fullpath), 10); !ok { continue }
		data, rerr := os.read_entire_file(fmt.tprintf("%s/comm", e.fullpath), context.temp_allocator)
		if rerr == nil { out[strings.trim_space(string(data))] = true }
	}
	return out
}

@(private="file")
odin_month :: proc(version: string) -> int {
	// "odin version dev-2026-09:a2fb372b7" → 202609
	i := strings.index(version, "dev-")
	if i < 0 || len(version) < i + 11 { return 0 }
	year, ok1 := strconv.parse_int(version[i + 4:i + 8], 10)
	month, ok2 := strconv.parse_int(version[i + 9:i + 11], 10)
	if !ok1 || !ok2 { return 0 }
	return year * 100 + month
}

cmd_doctor :: proc(opts: ^Options) -> int {
	dr := Doctor{family = distro_family()}
	if term, found := os.lookup_env("TERM", context.temp_allocator); found && term != "dumb" && os.is_tty(os.stdout) { dr.color = true }
	fmt.printfln("milk doctor — milk %s", VERSION)

	// --- milk itself --------------------------------------------------------------
	section(&dr, "milk")
	clone := clone_dir()
	if clone == "" {
		say(&dr, "warn", "cannot tell which clone this binary comes from (milk update and the launcher need it)")
	} else {
		say(&dr, "ok", fmt.tprintf("clone: %s", clone))
		if recorded, err := os.read_entire_file(join({filepath.dir(opts.config_path), "location"}), context.temp_allocator); err == nil {
			if strings.trim_space(string(recorded)) != clone {
				say(&dr, "warn", fmt.tprintf("the login session starts another clone: %s", strings.trim_space(string(recorded))),
				    "run ./install.sh from the clone you want to use")
			}
		}
	}
	if odin, found := find_in_path("odin"); found {
		version := run_output({odin, "version"})
		if i := strings.index(version, "dev-"); i >= 0 { version = version[i:] }
		if odin_month(version) >= 202609 {
			say(&dr, "ok", fmt.tprintf("Odin: %s (%s)", version, odin))
		} else {
			say(&dr, "fail", fmt.tprintf("Odin is too old to build milk: %s", version), "run ./install.sh: it installs a recent Odin")
		}
	} else {
		say(&dr, "fail", "Odin is not installed — milk cannot be rebuilt after an update", "run ./install.sh: it installs Odin")
	}
	check_program(&dr, "clang", "links the builds", true)
	check_program(&dr, "git", "milk update", false)

	// --- configuration --------------------------------------------------------------
	section(&dr, "Configuration")
	cfg, err := config.load(opts.config_path)
	if err != "" {
		say(&dr, "fail", fmt.tprintf("%s: %s", opts.config_path, err), "fix it, or move it away and run milk setup")
	} else {
		say(&dr, "ok", fmt.tprintf("%s is valid", opts.config_path))
		if len(cfg.unknown_keys) > 0 {
			say(&dr, "warn", fmt.tprintf("milk.json has keys no option reads (ignored): %s", strings.join(cfg.unknown_keys, ", ", context.temp_allocator)),
			    "an older or newer milk wrote them; they can be deleted")
		}
	}
	if os.is_directory(opts.runtime_root) {
		say(&dr, "ok", fmt.tprintf("runtime folder: %s", opts.runtime_root))
	} else {
		say(&dr, "warn", fmt.tprintf("the runtime folder %s does not exist yet (milk creates it)", opts.runtime_root))
	}
	if cfg != nil {
		missing := 0
		for index, ws in cfg.workspaces {
			if ws.wallpaper == "" { continue }
			if _, found := desktop.wallpaper_source(cfg, opts.runtime_root, index); !found {
				say(&dr, "warn", fmt.tprintf("area %d: wallpaper %s is missing", index, ws.wallpaper), "pick it again in milk settings → Wallpapers")
				missing += 1
			}
		}
		if missing == 0 { say(&dr, "ok", "every configured wallpaper exists") }
		if cfg.bar.icon_font_file != "" && !os.is_file(cfg.bar.icon_font_file) {
			say(&dr, "fail", fmt.tprintf("the bar's icon font %s is missing", cfg.bar.icon_font_file), "run ./install.sh: it installs the Tabler icon font")
		} else if cfg.bar.icon_font_file != "" {
			say(&dr, "ok", fmt.tprintf("icon font: %s", cfg.bar.icon_font_file))
		}
	}

	// --- programs ----------------------------------------------------------------------
	section(&dr, "Programs")
	check_program(&dr, "feh", "wallpapers", true)
	check_program(&dr, "rsvg-convert", "SVG icons", true)
	check_program(&dr, "xdg-user-dirs-update", "the Desktop and other user folders", false)
	check_program(&dr, "xdg-open", "opening files and links", true)
	if _, found := find_in_path("magick"); found {
		check_program(&dr, "magick", "thumbnails and pictures core:image cannot read", false)
	} else if _, found2 := find_in_path("convert"); found2 {
		check_program(&dr, "convert", "thumbnails and pictures core:image cannot read", false)
	} else {
		check_program(&dr, "magick", "thumbnails and pictures core:image cannot read", false)
	}
	volume := false
	for p in ([]string{"wpctl", "pactl", "amixer"}) {
		if _, found := find_in_path(p); found {
			say(&dr, "ok", fmt.tprintf("%s — the volume widget", p))
			volume = true
			break
		}
	}
	if !volume { say(&dr, "warn", "no wpctl, pactl or amixer — the volume widget cannot work", install_hint(&dr, "wpctl")) }
	check_program(&dr, "nmcli", "the Wi-Fi menu", false)
	check_program(&dr, "bluetoothctl", "the Bluetooth menu", false)
	check_program(&dr, "brightnessctl", "brightness keys (else through systemd-logind)", false)
	check_program(&dr, "playerctl", "the media widget", false)
	check_program(&dr, "notify-send", "notifications from scripts", false)
	check_program(&dr, "setxkbmap", "the keyboard layout", cfg != nil && cfg.keyboard.layout != "")
	check_program(&dr, "fc-match", "font checks", false)
	if cfg != nil {
		wallpaper_theme := cfg.appearance.theme == config.WALLPAPER_THEME
		if _, found := find_in_path("matugen"); !found && os.is_file(join({home_dir(), ".local", "bin", "matugen"})) {
			say(&dr, "ok", "matugen — the Wallpaper theme (~/.local/bin/matugen)")
		} else {
			check_program(&dr, "matugen", "the Wallpaper theme", wallpaper_theme)
		}
		for entry in ([][2]string{{cfg.wm.terminal, "the terminal (wm.terminal)"}, {cfg.wm.launcher, "the launcher (wm.launcher)"},
		                          {cfg.wm.screenshot, "screenshots (wm.screenshot)"}}) {
			program := command_program(entry[0])
			if program == "" || program == "sh" || program == "milk" { continue } // "milk …": this milk
			check_program(&dr, program, entry[1], false)
		}
		// milk's launcher (milk/launcher.odin) is drawn by rofi.
		check_program(&dr, "rofi", "milk's launcher", true)
		if _, found := find_in_path("fdfind"); !found { check_program(&dr, "fd", "quick file search in the launcher (else find)", false) }
		if cfg.compositor.enabled {
			if path, found := desktop.lactase_path(); found {
				say(&dr, "ok", fmt.tprintf("lactase — the compositor (%s)", path))
			} else {
				say(&dr, "warn", "lactase is not installed but compositor.enabled is on", "run ./install.sh to add it, or turn Effects off in milk settings")
			}
		}
	}
	if spoil, found := find_in_path("spoil"); found {
		say(&dr, "ok", fmt.tprintf("spoil — the file manager (%s)", spoil))
	} else {
		say(&dr, "warn", "Spoil is not installed — Super+E opens another file manager", "run ./install.sh to add it")
	}
	// contrib/milk-screenshot finds snippy on the PATH or next to the clone.
	snippy, have_snippy := find_in_path("snippy")
	if !have_snippy && clone != "" {
		snippy = join({filepath.dir(clone), "snippy", "snippy"})
		have_snippy = is_executable(snippy)
	}
	if have_snippy {
		say(&dr, "ok", fmt.tprintf("snippy — screenshots and screen recording (%s)", snippy))
	} else {
		say(&dr, "warn", "snippy is not installed — Super+Shift+S uses flameshot, maim or scrot", "run ./install.sh to add it")
	}

	// --- fonts -------------------------------------------------------------------------
	section(&dr, "Fonts")
	if fc, found := find_in_path("fc-match"); found && cfg != nil {
		want := strings.trim_space(strings.split(cfg.bar.font, ":", context.temp_allocator)[0])
		got := run_output({fc, "-f", "%{family}", cfg.bar.font})
		if want == "" || strings.contains(strings.to_lower(got), strings.to_lower(want)) {
			say(&dr, "ok", fmt.tprintf("bar font: %s", got))
		} else {
			say(&dr, "warn", fmt.tprintf("the bar font \"%s\" is not installed (fontconfig uses %s)", want, got), "install it or pick another in milk settings → Bar")
		}
		emoji := run_output({fc, "-f", "%{family}", "emoji"})
		if strings.contains(strings.to_lower(emoji), "emoji") {
			say(&dr, "ok", fmt.tprintf("emoji: %s", emoji))
		} else {
			say(&dr, "warn", "no colour emoji font", "install Noto Color Emoji (noto-fonts-emoji / fonts-noto-color-emoji)")
		}
	}

	// --- apps in milk's colours ----------------------------------------------------------
	if cfg != nil && cfg.appearance.theme_apps {
		section(&dr, "GTK and Qt apps (appearance.themeApps)")
		data_home := os.get_env("XDG_DATA_HOME", context.temp_allocator)
		if data_home == "" { data_home = join({home_dir(), ".local", "share"}) }
		if os.is_dir("/usr/share/themes/adw-gtk3") || os.is_dir(join({data_home, "themes", "adw-gtk3"})) {
			say(&dr, "ok", "adw-gtk3 — GTK 3 apps take milk's colours and follow changes live")
		} else {
			hint := "run ./install.sh: it installs adw-gtk3"
			switch dr.family {
			case "arch":   hint = "install it: sudo pacman -S adw-gtk-theme"
			case "fedora": hint = "install it: sudo dnf install adw-gtk3-theme"
			}
			say(&dr, "warn", "adw-gtk3 is not installed — GTK 3 apps take only part of the colours, when they start", hint)
		}
		qt := false
		for p in ([]string{"qt5ct", "qt6ct"}) {
			if _, found := find_in_path(p); found {
				say(&dr, "ok", fmt.tprintf("%s — Qt %s apps take milk's colours", p, p == "qt5ct" ? "5" : "6"))
				qt = true
			}
		}
		if !qt { say(&dr, "warn", "neither qt5ct nor qt6ct is installed — Qt apps keep their own colours", install_hint(&dr, "qt6ct")) }
		if theme, found := os.lookup_env("QT_QPA_PLATFORMTHEME", context.temp_allocator); qt && (!found || theme == "") {
			say(&dr, "warn", "QT_QPA_PLATFORMTHEME is not set in this session", "log out and back in: the milk session sets it to qt5ct/qt6ct")
		} else if qt && theme != "qt5ct" && theme != "qt6ct" {
			say(&dr, "warn", fmt.tprintf("QT_QPA_PLATFORMTHEME is %s, so Qt apps ignore milk's colours", theme), "unset it in your profile to let the milk session choose qt5ct")
		}
	}

	// --- lock screen ----------------------------------------------------------------------
	section(&dr, "Lock screen")
	pam_dirs := []string{"/etc/pam.d", "/usr/lib/pam.d", "/usr/etc/pam.d"}
	pam_file :: proc(dirs: []string, name: string) -> bool {
		for d in dirs { if os.is_file(join({d, name})) { return true } }
		return false
	}
	if pam_file(pam_dirs, "milk") {
		say(&dr, "ok", "PAM service milk (/etc/pam.d/milk)")
	} else {
		found := ""
		for service in ([]string{"system-auth", "common-auth", "login"}) {
			if pam_file(pam_dirs, service) { found = service; break }
		}
		if found != "" {
			say(&dr, "warn", fmt.tprintf("no /etc/pam.d/milk: the lock screen checks passwords with PAM service %s", found), "run ./install.sh to install milk's own service")
		} else {
			say(&dr, "fail", "no PAM service the lock screen can use: it could never unlock", "run ./install.sh")
		}
	}
	if cfg != nil {
		if cfg.lock.enabled && cfg.idle.lock_after > 0 {
			say(&dr, "info", fmt.tprintf("locks after %d min without use%s", cfg.idle.lock_after / 60, cfg.lock.on_suspend ? ", and before suspending" : ""))
		} else {
			say(&dr, "info", "automatic locking is off (Super+Shift+L or `milk lock` still lock)")
		}
	}

	// --- session -------------------------------------------------------------------------
	section(&dr, "Session")
	entry := ""
	for dir in ([]string{"/usr/share/xsessions", "/usr/local/share/xsessions"}) {
		if os.is_file(join({dir, "milk.desktop"})) { entry = join({dir, "milk.desktop"}); break }
	}
	if entry != "" {
		say(&dr, "ok", fmt.tprintf("login entry: %s", entry))
	} else {
		say(&dr, "warn", "milk is not in the login screen's session list", "run ./install.sh (or sudo contrib/install-sddm-session.sh)")
	}
	if os.is_file("/usr/local/bin/milk-session") {
		say(&dr, "ok", "launcher: /usr/local/bin/milk-session")
	} else if entry != "" {
		say(&dr, "fail", "/usr/local/bin/milk-session is missing: the login entry cannot start milk", "run ./install.sh again")
	}
	local_bin := join({home_dir(), ".local", "bin"})
	path_env, _ := os.lookup_env("PATH", context.temp_allocator)
	if strings.contains(fmt.tprintf(":%s:", path_env), fmt.tprintf(":%s:", local_bin)) {
		say(&dr, "ok", "~/.local/bin is in PATH")
	} else {
		say(&dr, "warn", "~/.local/bin is not in PATH: the milk, spoil, lactase and snippy commands are not found in terminals",
		    "add it in your shell's profile (the milk session adds it for itself)")
	}
	if bus, found := os.lookup_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator); found && bus != "" {
		say(&dr, "ok", "D-Bus session bus")
	} else {
		say(&dr, "warn", "no D-Bus session bus: notifications and the media widget cannot work", "start milk through the login screen, or with dbus-run-session")
	}
	pid_file := join({opts.runtime_root, PID_NAME})
	if pid, running := running_pid(pid_file); running {
		say(&dr, "ok", fmt.tprintf("milk is running (pid %d)", pid))
	} else {
		say(&dr, "info", "milk is not running")
	}
	if c, connected := tx.connect(); connected {
		defer tx.disconnect(c)
		wm := tx.wm_name(c)
		say(&dr, "ok", fmt.tprintf("X display reachable (window manager: %s)", wm == "" ? "none" : wm))
	} else {
		say(&dr, "info", "no X display here (run milk doctor inside the session for the display checks)")
	}

	// Programs that would do one of milk's jobs at the same time.
	procs := running_commands()
	Rival :: struct { names: []string, job: string }
	rivals := []Rival{
		{{"dunst", "mako", "xfce4-notifyd", "notification-daemon", "notify-osd", "swaync", "deadd-notificatio"}, "notifications (milk shows them itself)"},
		{{"picom", "compton", "xcompmgr", "compiz"}, "compositing (lactase does it)"},
		{{"stalonetray", "trayer", "polybar", "tint2"}, "the tray / a panel (milk's bar has them)"},
		{{"xsettingsd"}, "XSETTINGS (milk manages them for GTK themes)"},
		{{"xss-lock", "light-locker", "xscreensaver", "xautolock", "i3lock", "betterlockscreen"}, "screen locking (milk locks the screen itself)"},
		{{"redshift", "gammastep", "sct"}, "the screen colour (milk's night light does it)"},
		{{"greenclip", "clipmenud", "copyq", "parcellite", "clipit"}, "clipboard history (milk keeps one)"},
	}
	clean := true
	for rival in rivals {
		for name in rival.names {
			if name in procs {
				say(&dr, "warn", fmt.tprintf("%s is running and also handles %s", name, rival.job), "stop it in your autostart to avoid two of them")
				clean = false
			}
		}
	}
	if clean { say(&dr, "ok", "nothing else is doing milk's jobs (notifications, compositor, tray, clipboard, locking, night light)") }

	// --- summary -------------------------------------------------------------------------
	fmt.println()
	switch {
	case dr.problems > 0:
		fmt.printfln("%d problem(s) and %d warning(s).", dr.problems, dr.warnings)
		return 1
	case dr.warnings > 0:
		fmt.printfln("No problems; %d warning(s).", dr.warnings)
	case:
		fmt.println("Everything looks fine.")
	}
	return 0
}
