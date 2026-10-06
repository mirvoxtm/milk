package config

import "core:strings"

// milk's default shortcuts, one per action. The window manager builds its key
// table from them and Settings → Shortcuts lists them; wm.defaultKeys changes
// their keys ("id": "the keys, separated by spaces", "" = off). "mod" is
// wm.modKey; "#" stands for the digits 1..9, one key per area, in the keys and
// in the action ("mod+#" → "view #").
Default_Key :: struct {
	id:     string,
	keys:   string,
	action: string, // a WM action (WM_ACTIONS)
	mode:   u8,     // 0 both modes, 1 the tiling mode only, 2 the floating mode only
	group:  Key_Group,
	pt, en: string, // what it does, for Settings
}

Key_Group :: enum u8 { Apps, Windows, Layout, Areas, System }

@(rodata)
DEFAULT_KEYS := []Default_Key{
	{"terminal", "mod+Return", "terminal", 0, .Apps, "Abrir o terminal", "Open the terminal"},
	{"launcher", "mod+d mod+p", "launcher", 0, .Apps, "Abrir o lançador de aplicativos", "Open the application launcher"},
	{"files", "mod+e", "files", 0, .Apps, "Abrir o gerenciador de arquivos", "Open the file manager"},
	{"screenshot", "mod+shift+s", "screenshot", 0, .Apps, "Capturar uma região da tela", "Screenshot of a region"},
	{"clipboard", "mod+v", "clipboard", 0, .Apps, "Histórico da área de transferência", "Clipboard history"},
	{"notifications", "mod+n", "notifications", 0, .Apps, "Painel de notificações", "Notification panel"},

	// Alt+F4 first: the window menu shows the first key of an action.
	{"close", "alt+F4 mod+q mod+shift+c", "close", 0, .Windows, "Fechar a janela", "Close the window"},
	{"switch-windows", "alt+Tab", "switch-windows", 0, .Windows, "Alternar entre as janelas", "Switch between windows"},
	{"switch-windows-reverse", "alt+shift+Tab", "switch-windows-reverse", 0, .Windows, "Alternar entre as janelas, de trás para frente", "Switch between windows, backwards"},
	{"focus-next", "mod+j", "focus-next", 0, .Windows, "Focar a próxima janela", "Focus the next window"},
	{"focus-prev", "mod+k", "focus-prev", 0, .Windows, "Focar a janela anterior", "Focus the previous window"},
	{"fullscreen", "mod+shift+f", "fullscreen", 0, .Windows, "Tela cheia", "Fullscreen"},
	{"maximize", "mod+Up", "maximize", 2, .Windows, "Maximizar / restaurar", "Maximize / restore"},
	{"restore", "mod+Down", "restore", 2, .Windows, "Restaurar ou minimizar", "Restore or minimize"},
	{"minimize", "mod+h", "minimize", 2, .Windows, "Minimizar", "Minimize"},
	{"snap-left", "mod+Left", "snap-left", 2, .Windows, "Encaixar na metade esquerda", "Snap to the left half"},
	{"snap-right", "mod+Right", "snap-right", 2, .Windows, "Encaixar na metade direita", "Snap to the right half"},
	{"center", "mod+c", "center", 2, .Windows, "Centralizar a janela", "Centre the window"},
	{"window-menu", "alt+space", "window-menu", 2, .Windows, "Menu da janela", "Window menu"},
	{"show-desktop", "mod+shift+d", "show-desktop", 2, .Windows, "Mostrar a área de trabalho", "Show the desktop"},

	{"zoom", "mod+shift+Return", "zoom", 1, .Layout, "Trocar com a janela mestre", "Swap with the master window"},
	{"master-shrink", "mod+h", "master-shrink", 1, .Layout, "Diminuir a área mestre", "Shrink the master area"},
	{"master-grow", "mod+l", "master-grow", 1, .Layout, "Aumentar a área mestre", "Grow the master area"},
	{"master-more", "mod+i", "master-more", 1, .Layout, "Mais janelas na área mestre", "More windows in the master area"},
	{"master-fewer", "mod+shift+d", "master-fewer", 1, .Layout, "Menos janelas na área mestre", "Fewer windows in the master area"},
	{"layout-tile", "mod+t", "layout tile", 1, .Layout, "Layout lado a lado", "Tile layout"},
	{"layout-float", "mod+f", "layout float", 1, .Layout, "Layout flutuante", "Floating layout"},
	{"layout-monocle", "mod+m", "layout monocle", 1, .Layout, "Layout monóculo", "Monocle layout"},
	{"layout-last", "mod+space", "layout-last", 1, .Layout, "Layout anterior", "Previous layout"},
	{"toggle-floating", "mod+shift+space", "toggle-floating", 1, .Layout, "Alternar janela flutuante", "Toggle floating"},

	{"view", "mod+#", "view #", 0, .Areas, "Ir para a área 1…9", "Go to area 1…9"},
	{"send", "mod+shift+#", "send #", 0, .Areas, "Mover a janela para a área 1…9", "Move the window to area 1…9"},
	{"toggle-view", "mod+ctrl+#", "toggle-view #", 0, .Areas, "Mostrar também a área 1…9", "Also show area 1…9"},
	{"toggle-tag", "mod+ctrl+shift+#", "toggle-tag #", 0, .Areas, "Pôr a janela também na área 1…9", "Also put the window on area 1…9"},
	{"view-all", "mod+0", "view-all", 0, .Areas, "Ver todas as áreas", "Show every area"},
	{"send-all", "mod+shift+0", "send-all", 0, .Areas, "Pôr a janela em todas as áreas", "Put the window on every area"},
	{"view-last", "mod+Tab", "view-last", 0, .Areas, "Voltar para a última área", "Back to the last area"},
	{"overview", "mod+shift+Tab", "overview", 0, .Areas, "Visão geral de todas as áreas", "Overview of every area"},
	{"view-prev", "ctrl+alt+Left", "view-prev", 2, .Areas, "Área anterior", "Previous area"},
	{"view-next", "ctrl+alt+Right", "view-next", 2, .Areas, "Próxima área", "Next area"},
	{"send-prev", "ctrl+alt+shift+Left", "send-prev", 2, .Areas, "Levar a janela para a área anterior", "Take the window to the previous area"},
	{"send-next", "ctrl+alt+shift+Right", "send-next", 2, .Areas, "Levar a janela para a próxima área", "Take the window to the next area"},
	{"focus-monitor-prev", "mod+comma", "focus-monitor prev", 0, .Areas, "Focar o monitor anterior", "Focus the previous monitor"},
	{"focus-monitor-next", "mod+period", "focus-monitor next", 0, .Areas, "Focar o próximo monitor", "Focus the next monitor"},
	{"send-monitor-prev", "mod+shift+comma", "send-monitor prev", 0, .Areas, "Mover a janela para o monitor anterior", "Move the window to the previous monitor"},
	{"send-monitor-next", "mod+shift+period", "send-monitor next", 0, .Areas, "Mover a janela para o próximo monitor", "Move the window to the next monitor"},

	{"lock", "mod+shift+l XF86ScreenSaver", "lock", 0, .System, "Bloquear a tela", "Lock the screen"},
	{"reload", "mod+shift+r", "reload", 0, .System, "Recarregar milk.json", "Reload milk.json"},
	{"quit", "mod+shift+q", "quit", 0, .System, "Sair do milk", "Quit milk"},
	{"mute", "XF86AudioMute", "mute", 0, .System, "Mudo", "Mute"},
	{"volume-down", "XF86AudioLowerVolume", "volume-down", 0, .System, "Diminuir o volume", "Volume down"},
	{"volume-up", "XF86AudioRaiseVolume", "volume-up", 0, .System, "Aumentar o volume", "Volume up"},
	{"brightness-down", "XF86MonBrightnessDown", "brightness-down", 0, .System, "Diminuir o brilho", "Brightness down"},
	{"brightness-up", "XF86MonBrightnessUp", "brightness-up", 0, .System, "Aumentar o brilho", "Brightness up"},
}

// The default shortcut called `id` (nil when there is none).
default_key :: proc(id: string) -> ^Default_Key {
	for &d in DEFAULT_KEYS { if d.id == id { return &d } }
	return nil
}

// Whether the shortcut exists in the window manager's mode.
default_key_active :: proc(d: Default_Key, floating: bool) -> bool {
	switch d.mode {
	case 1: return !floating
	case 2: return floating
	}
	return true
}

// The keys of a default shortcut: wm.defaultKeys's, or the default ones.
default_key_specs :: proc(w: ^WM_Options, d: Default_Key) -> string {
	if keys, ok := w.default_keys[d.id]; ok { return keys }
	return d.keys
}

// "mod+#" with the digit `n` (and "view #" with the number).
expand_area :: proc(s: string, n: int, allocator := context.temp_allocator) -> string {
	digit := [1]u8{u8('0' + n)}
	out, _ := strings.replace_all(s, "#", string(digit[:]), allocator)
	return out
}
