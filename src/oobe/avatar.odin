// The profile picture (Settings → Appearance → General). The user picks one
// of the pictures the wallpaper page lists (the Pictures folder, the
// wallpapers, the system's backgrounds); its middle square, AVATAR_SIZE
// pixels wide, is saved as ~/.face, the file lock and login screens look
// for, with ~/.face.icon (SDDM's name for it) pointing there. milk's lock
// screen shows it. AccountsService, where GDM, LightDM and SDDM themes read
// the picture from, is told too when it runs (busctl, in the background).
package oobe

import "core:fmt"
import "core:log"
import "core:os"
import "core:sys/posix"
import tx "../tx"

@(private) AVATAR_SIZE :: 256 // pixels of ~/.face
@(private) AVATAR_ROW  :: 44   // the picture in its settings row
@(private) AVATAR_TILE :: 128  // a choice in the picker

@(private)
Avatar_State :: struct {
	picking: bool,     // the picker is open
	img:     tx.Image, // the current picture, round, AVATAR_ROW wide (w.allocator); w == 0: none
	loaded:  bool,     // img reflects ~/.face
	scroll:  i32,
}

@(private)
avatar_destroy :: proc(w: ^Wizard) {
	a := &w.set.avatar
	if a.img.w > 0 { delete(a.img.rgba, w.allocator) }
	a^ = {}
}

// The current picture for the settings row, read on first use.
@(private)
avatar_image :: proc(w: ^Wizard) -> (tx.Image, bool) {
	a := &w.set.avatar
	if !a.loaded {
		a.loaded = true
		if a.img.w > 0 { delete(a.img.rgba, w.allocator) }
		a.img = {}
		for name in ([]string{".face", ".face.icon"}) {
			if src, ok := tx.image_load(join_path({home_dir(), name}), context.temp_allocator); ok {
				a.img = tx.image_circle(src, AVATAR_ROW, w.allocator)
				break
			}
		}
	}
	return a.img, a.img.w > 0
}

// Save candidate `index` as the profile picture.
@(private)
avatar_choose :: proc(w: ^Wizard, index: int) {
	a := &w.set.avatar
	if index < 0 || index >= len(w.thumbs.items) { return }
	path := w.thumbs.items[index].path
	src, ok := tx.image_load(path, context.temp_allocator)
	if !ok {
		show_notice(w, tr(w, "Não foi possível abrir a imagem", "Could not open the picture"))
		return
	}
	face := tx.image_square(src, AVATAR_SIZE, context.temp_allocator)
	file := join_path({home_dir(), ".face"})
	tmp := fmt.tprintf("%s.tmp", file)
	if os.write_entire_file(tmp, tx.png_encode(face, context.temp_allocator)) != nil || os.rename(tmp, file) != nil {
		os.remove(tmp)
		log.warnf("Settings: cannot write %s", file)
		show_notice(w, tr(w, "Não foi possível salvar a foto", "Could not save the picture"))
		return
	}
	// ~/.face.icon follows ~/.face, unless the user keeps a picture of their own there.
	icon := join_path({home_dir(), ".face.icon"})
	if fi, err := os.lstat(icon, context.temp_allocator); err != nil || fi.type == .Symlink {
		os.remove(icon)
		_ = os.symlink(".face", icon)
	}
	accounts_set_icon(file)
	a.loaded = false
	a.picking = false
	log.infof("Settings: profile picture from %s", path)
	show_notice(w, tr(w, "Foto de perfil salva", "Profile picture saved"))
}

@(private)
avatar_remove :: proc(w: ^Wizard) {
	os.remove(join_path({home_dir(), ".face"}))
	icon := join_path({home_dir(), ".face.icon"})
	if fi, err := os.lstat(icon, context.temp_allocator); err == nil && fi.type == .Symlink { os.remove(icon) }
	accounts_set_icon("")
	w.set.avatar.loaded = false
	show_notice(w, tr(w, "Foto de perfil removida", "Profile picture removed"))
}

// Tell AccountsService (when it runs) about the picture; "" removes it.
@(private)
accounts_set_icon :: proc(file: string) {
	if !executable_in_path("busctl") { return }
	argv := []string{"busctl", "--system", "call", "org.freedesktop.Accounts",
	                 fmt.tprintf("/org/freedesktop/Accounts/User%d", posix.getuid()),
	                 "org.freedesktop.Accounts.User", "SetIconFile", "s", file}
	if _, err := os.process_start(os.Process_Desc{command = argv}); err != nil {
		log.debugf("Settings: busctl: %v", err)
	}
}

@(private)
executable_in_path :: proc(name: string) -> bool {
	path_env, _ := os.lookup_env("PATH", context.temp_allocator)
	for dir in strings_split(path_env) {
		if dir != "" && os.is_file(join_path({dir, name})) { return true }
	}
	return false
}

@(private)
strings_split :: proc(s: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	start := 0
	for i in 0 ..= len(s) {
		if i == len(s) || s[i] == ':' {
			append(&out, s[start:i])
			start = i + 1
		}
	}
	return out[:]
}

// The settings row: the picture, Choose… and (when there is one) Remove.
@(private)
draw_avatar_row :: proc(w: ^Wizard, cv: ^tx.Canvas, row: tx.Rect) {
	th := &w.theme
	row_label(w, row, tr(w, "Foto de perfil", "Profile picture"),
	          tr(w, "Na tela de bloqueio e nas telas de login", "On the lock screen and the login screens"))
	img, has := avatar_image(w)
	x := row.x + row.w
	if has {
		remove := tr(w, "Remover", "Remove")
		rw := button_width(w, remove)
		x -= rw
		button(w, cv, {x, row.y + (row.h - BUTTON_H) / 2, rw, BUTTON_H}, remove, .Text, .Avatar_Remove)
		x -= 8
	}
	choose := tr(w, "Escolher…", "Choose…")
	cw := button_width(w, choose, .Photo)
	x -= cw
	button(w, cv, {x, row.y + (row.h - BUTTON_H) / 2, cw, BUTTON_H}, choose, .Tonal, .Avatar_Pick, 0, .Photo)
	cx := x - 16 - AVATAR_ROW
	cy := row.y + (row.h - AVATAR_ROW) / 2
	if has {
		tx.canvas_blit_image(cv, img, cx, cy)
	} else {
		tx.canvas_fill_circle(cv, f32(cx) + AVATAR_ROW / 2, f32(cy) + AVATAR_ROW / 2, AVATAR_ROW / 2, th.accent)
		if w.f_icon_small != nil { icon(w, w.f_icon_small, {cx, cy, AVATAR_ROW, AVATAR_ROW}, .Photo, th.accent_fg) }
	}
}

// The picker: every candidate picture as a round tile; a click saves it.
@(private)
draw_avatar_picker :: proc(w: ^Wizard, cv: ^tx.Canvas, c: tx.Rect) {
	th := &w.theme
	a := &w.set.avatar
	back := tr(w, "Voltar", "Back")
	bw := button_width(w, back, .Arrow_Left)
	button(w, cv, {c.x, c.y, bw, BUTTON_H}, back, .Text, .Avatar_Back, 0, .Arrow_Left)
	text(w, w.f_h2, c.x + bw + 16, c.y, BUTTON_H, tr(w, "Escolha uma foto de perfil", "Choose a profile picture"), th.fg)
	text(w, w.f_small, c.x, c.y + BUTTON_H + 6, 20,
	     ellipsize(w, w.f_small, tr(w, "Imagens da sua pasta Imagens, dos papéis de parede e do sistema",
	                                   "Pictures from your Pictures folder, the wallpapers and the system"), c.w), th.muted)

	vp := tx.Rect{c.x - 6, c.y + BUTTON_H + 36, c.w + 12, c.h - BUTTON_H - 36}
	visible := picture_candidates(w)
	if w.started && len(visible) == 0 {
		text_centered(w, w.f_body, {vp.x, vp.y + 40, vp.w, 30}, tr(w, "Nenhuma imagem encontrada", "No pictures found"), th.muted)
		return
	}
	count := w.started ? len(visible) : 12
	gap: i32 = 22
	cols := max(i32(2), (vp.w - 12 + gap) / (AVATAR_TILE + gap))
	left := (vp.w - (cols * AVATAR_TILE + (cols - 1) * gap)) / 2
	rows := (i32(count) + cols - 1) / cols
	content_h := rows * (AVATAR_TILE + gap) - gap + 16
	max_scroll := max(content_h - vp.h, 0)
	a.scroll = clamp(a.scroll, 0, max_scroll)
	append(&w.scrolls, Scroll_Area{r = vp, id = .Avatars, max = max_scroll})
	sub := tx.canvas_make(vp.w, vp.h, context.temp_allocator)
	tx.canvas_fill(&sub, th.bg)
	phase := anim_phase(w, 1.4)
	for k in 0 ..< count {
		index := w.started ? visible[k] : -1
		col, row := i32(k) % cols, i32(k) / cols
		t := tx.Rect{left + col * (AVATAR_TILE + gap), 8 + row * (AVATAR_TILE + gap) - a.scroll, AVATAR_TILE, AVATAR_TILE}
		if t.y + t.h + 8 < 0 { continue }
		if t.y - 8 > vp.h { break }
		if img, ok := candidate_scaled(w, index, t.w, t.h); ok && index >= 0 {
			blit_rounded(&sub, img, t.x, t.y, f32(t.w) / 2)
		} else {
			fill_shimmer(&sub, t, f32(t.w) / 2, th.field, mix(th.field, th.fg, th.dark ? 0.1 : 0.06), phase)
		}
		win_t := tx.Rect{vp.x + t.x, vp.y + t.y, t.w, t.h}
		if index >= 0 && hovered(w, .Avatar_Tile, index) {
			tx.canvas_stroke_rounded_rect(&sub, {t.x - 4, t.y - 4, t.w + 8, t.h + 8}, f32(t.w + 8) / 2, 2.5, th.accent)
		}
		if index >= 0 { add_hit(w, win_t, .Avatar_Tile, index, vp) }
	}
	if max_scroll > 0 {
		track := vp.h - 16
		thumb_h := max(track * vp.h / content_h, 32)
		thumb_y := 8 + (track - thumb_h) * a.scroll / max_scroll
		tx.canvas_fill_rounded_rect(&sub, {vp.w - 8, thumb_y, 4, thumb_h}, 2, tx.color_with_alpha(th.muted, 150))
	}
	composite_rounded(cv, sub, vp.x, vp.y, 0)
}
