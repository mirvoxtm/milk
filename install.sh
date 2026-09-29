#!/usr/bin/env bash
# milk installer for Arch Linux and derivatives (CachyOS, EndeavourOS, Manjaro, ...).
#
# Interactive by default: it asks which parts to install, shows the plan and
# waits for your confirmation. It installs every dependency with pacman, milk
# itself, Spoil (the file manager, Super+E) and lactase (the compositor) next
# to milk, the Tabler icon font
# when Noctalia's copy is missing, the Alacritty theme and the login-screen
# entry.
#
#   ./install.sh                 interactive install / update
#   ./install.sh --yes           accept every default without asking
#   ./install.sh --minimal       skip the optional tools
#   ./install.sh --no-spoil      do not install Spoil
#   ./install.sh --no-lactase    do not install lactase (shadows, animations, transparency)
#   ./install.sh --with-sddm     also install and enable SDDM when no display manager is enabled
#   ./install.sh --uninstall     remove the session entry, the commands and the icon font
#
# Run it as your user (not root); it calls sudo when needed. It also works when
# piped from the network: milk is then cloned into ~/.local/share/milk.
set -euo pipefail

MILK_URL="https://github.com/mirvoxtm/milk.git"
SPOIL_URL="https://github.com/mirvoxtm/spoil.git"
LACTASE_URL="https://github.com/mirvoxtm/lactase.git"
TABLER_VERSION="3.48.0"
TABLER_URL="https://registry.npmjs.org/@tabler/icons-webfont/-/icons-webfont-${TABLER_VERSION}.tgz"
NOCTALIA_FONT="/usr/share/noctalia/assets/fonts/noctalia-tabler.ttf"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/milk"
FONT_DIR="$DATA_DIR/fonts"

assume_yes=0; minimal=0; want_spoil=1; want_lactase=1; with_sddm=0; uninstall=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y)    assume_yes=1 ;;
        --minimal)   minimal=1 ;;
        --no-spoil)  want_spoil=0 ;;
        --no-lactase) want_lactase=0 ;;
        --with-sddm) with_sddm=1 ;;
        --uninstall) uninstall=1 ;;
        -h|--help)   sed -n '2,/^set /{/^#/s/^# \{0,1\}//p}' "$0"; exit 0 ;;
        *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done

# --- output -------------------------------------------------------------------
if [ -t 1 ]; then
    B=$'\033[1m'; D=$'\033[2m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; C=$'\033[1;36m'; N=$'\033[0m'
else
    B=; D=; G=; Y=; R=; C=; N=
fi
step_no=0; step_total=8
step() { step_no=$((step_no + 1)); printf '\n%s[%d/%d]%s %s%s%s\n' "$C" "$step_no" "$step_total" "$N" "$B" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
info() { printf '  %s•%s %s\n' "$D" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

# Questions go to the terminal even when the script is piped from curl.
interactive=0; tty=/dev/stdin
if [ "$assume_yes" -eq 0 ]; then
    if [ -t 0 ]; then interactive=1
    elif { : < /dev/tty; } 2>/dev/null; then interactive=1; tty=/dev/tty
    fi
fi

# ask "Question" default(y|n) → returns 0 for yes
ask() {
    local question=$1 default=$2 answer hint
    if [ "$interactive" -eq 0 ]; then [ "$default" = y ]; return; fi
    if [ "$default" = y ]; then hint="S/n"; else hint="s/N"; fi
    while true; do
        printf '  %s?%s %s [%s] ' "$Y" "$N" "$question" "$hint"
        read -r answer < "$tty" || answer=""
        answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
        case "$answer" in
            "")          [ "$default" = y ]; return ;;
            s|sim|y|yes) return 0 ;;
            n|nao|não|no) return 1 ;;
        esac
    done
}

[ "$(id -u)" -ne 0 ] || die "Run this as your user, not as root (it uses sudo when needed)."
command -v pacman >/dev/null || die "pacman not found: this installer is for Arch Linux and derivatives."

# --- where is milk? --------------------------------------------------------------
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
if [ -n "$here" ] && [ -f "$here/src/milk/main.odin" ]; then
    MILK="$here"
else
    printf '%smilk%s is not here yet; it will be cloned into %s\n' "$B" "$N" "$DATA_DIR/milk"
    sudo pacman -S --needed --noconfirm git
    mkdir -p "$DATA_DIR"
    if [ -d "$DATA_DIR/milk/.git" ]; then git -C "$DATA_DIR/milk" pull --ff-only; else git clone --depth 1 "$MILK_URL" "$DATA_DIR/milk"; fi
    [ -f "$DATA_DIR/milk/src/milk/main.odin" ] || die "The cloned repository does not look like milk."
    exec bash "$DATA_DIR/milk/install.sh" "$@"
fi
SPOIL="$(dirname "$MILK")/spoil"
LACTASE="$(dirname "$MILK")/lactase"

if [ "$uninstall" -eq 1 ]; then
    printf '%sRemoving milk%s (settings, runtime data and the clones stay in place)\n' "$B" "$N"
    ask "Remove the login entry, the milk/spoil/lactase commands and the icon font?" y || exit 0
    sudo "$MILK/contrib/install-sddm-session.sh" --uninstall || true
    rm -f "$HOME/.local/bin/milk" "$HOME/.local/bin/spoil" "$HOME/.local/bin/lactase"
    rm -rf "$FONT_DIR"
    fc-cache -f >/dev/null 2>&1 || true
    ok "Done."
    exit 0
fi

# --- choices ------------------------------------------------------------------------
cat <<BANNER

  ${B}milk${N} — a desktop in one program: window manager, bar, notifications,
  clipboard history and per-area wallpapers and shortcuts.
  ${D}Installing from $MILK${N}

BANNER

if [ "$interactive" -eq 1 ]; then
    printf '%sWhat should be installed?%s\n' "$B" "$N"
    if [ "$want_spoil" -eq 1 ]; then
        ask "Spoil, the file manager (Super+E), with previews, thumbnails and archives?" y || want_spoil=0
    fi
    if [ "$want_lactase" -eq 1 ]; then
        ask "lactase, the compositor (shadows, animations, transparency, blur, smooth corners)?" y || want_lactase=0
    fi
    if [ "$minimal" -eq 0 ]; then
        ask "Optional tools (Alacritty, rofi, screenshots, brightness keys, media player info)?" y || minimal=1
    fi
    if ! systemctl is-enabled --quiet display-manager.service 2>/dev/null && [ "$with_sddm" -eq 0 ]; then
        ask "No login screen (display manager) is enabled. Install and enable SDDM?" y && with_sddm=1
    fi
    enable_services=1
    ask "Enable NetworkManager and Bluetooth if they are off (needed by the Wi-Fi and Bluetooth menus)?" y || enable_services=0
else
    enable_services=1
fi

# --- packages -------------------------------------------------------------------------
required=(
    base-devel git odin clang                      # build
    xorg-server xorg-xrandr xorg-setxkbmap xorg-xprop xorg-xinit
    libx11 libxft libxrandr libxfixes libxext fontconfig freetype2 zlib dbus
    feh librsvg imagemagick                        # wallpapers, SVG icons, thumbnails
    xdg-user-dirs xdg-utils libnotify glib2        # folders, links, notify-send, gio
    pipewire pipewire-pulse wireplumber            # volume (wpctl)
    networkmanager bluez bluez-utils               # Wi-Fi and Bluetooth menus
    noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-nerd-fonts-symbols
)
spoil_pkgs=(
    mpv ffmpegthumbnailer ffmpeg                   # previews and video thumbnails
    libarchive zip unzip 7zip                      # compress / extract
    alacritty                                      # the embedded terminal
)
lactase_pkgs=(
    libxcomposite libxdamage libxrender mesa libglvnd  # compositing and OpenGL
)
optional=(
    alacritty rofi                                 # default terminal and launcher
    brightnessctl playerctl                        # brightness keys, media widget
    maim xclip flameshot                           # screenshots (Super+Shift+S)
    unrar                                          # .rar archives in Spoil
    network-manager-applet                         # "Configurações de rede"
)
packages=("${required[@]}")
[ "$want_spoil" -eq 1 ] && packages+=("${spoil_pkgs[@]}")
[ "$want_lactase" -eq 1 ] && packages+=("${lactase_pkgs[@]}")
[ "$minimal" -eq 0 ] && packages+=("${optional[@]}")
[ "$with_sddm" -eq 1 ] && packages+=(sddm)
# Drop duplicates and packages this repository does not provide (e.g. 7zip vs p7zip).
mapfile -t packages < <(printf '%s\n' "${packages[@]}" | awk '!seen[$0]++')
available=()
for p in "${packages[@]}"; do
    if pacman -Si "$p" >/dev/null 2>&1 || pacman -Qi "$p" >/dev/null 2>&1; then
        available+=("$p")
    elif [ "$p" = 7zip ] && pacman -Si p7zip >/dev/null 2>&1; then
        available+=(p7zip)
    else
        warn "package $p is not in your repositories; skipping it"
    fi
done
mapfile -t missing < <(pacman -T "${available[@]}" || true)

printf '\n%sPlan%s\n' "$B" "$N"
info "milk$( [ "$want_spoil" -eq 1 ] && printf ' + Spoil' )$( [ "$want_lactase" -eq 1 ] && printf ' + lactase' ) from $MILK$( [ "$want_spoil" -eq 1 ] && printf ' (Spoil next to it: %s)' "$SPOIL" )"
if [ ${#missing[@]} -eq 0 ]; then
    info "all ${#available[@]} packages are already installed"
else
    info "${#missing[@]} packages to install: ${missing[*]}"
fi
[ -f "$NOCTALIA_FONT" ] || info "Tabler icon font $TABLER_VERSION into $FONT_DIR"
info "commands in ~/.local/bin, the Alacritty theme and the \"milk\" session on the login screen"
echo
ask "Continue?" y || { echo "Nothing was changed."; exit 0; }

# --- 1. packages ------------------------------------------------------------------------
step "Installing packages"
if [ ${#missing[@]} -gt 0 ]; then
    pacman_flags=(--needed)
    if [ "$interactive" -eq 1 ]; then
        sudo pacman -S "${pacman_flags[@]}" "${missing[@]}" < "$tty"   # pacman may ask about conflicts
    else
        sudo pacman -S "${pacman_flags[@]}" --noconfirm "${missing[@]}"
    fi
fi
ok "Dependencies ready"

# --- 2. services ------------------------------------------------------------------------
step "Services"
if [ "${enable_services:-1}" -eq 1 ]; then
    for unit in NetworkManager.service bluetooth.service; do
        if systemctl list-unit-files "$unit" >/dev/null 2>&1 && ! systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            sudo systemctl enable --now "$unit" && ok "$unit enabled"
        else
            ok "$unit already enabled"
        fi
    done
else
    info "left as they are"
fi
if [ "$with_sddm" -eq 1 ]; then
    if systemctl is-enabled --quiet display-manager.service 2>/dev/null; then
        ok "A login screen is already enabled"
    else
        sudo systemctl enable sddm.service && ok "SDDM enabled (starts at the next boot)"
    fi
fi
xdg-user-dirs-update >/dev/null 2>&1 || true

# --- 3. icon font ---------------------------------------------------------------------------
step "Icon font"
icon_font="$NOCTALIA_FONT"
if [ -f "$NOCTALIA_FONT" ]; then
    ok "Using Noctalia's Tabler icon font"
else
    icon_font="$FONT_DIR/tabler-icons.ttf"
    if [ -f "$icon_font" ] && [ -f "$FONT_DIR/tabler.json" ]; then
        ok "Tabler icon font already installed"
    else
        tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
        curl -fsSL "$TABLER_URL" -o "$tmp/tabler.tgz"
        tar xzf "$tmp/tabler.tgz" -C "$tmp" package/dist/tabler-icons.css package/dist/fonts/tabler-icons.ttf
        mkdir -p "$FONT_DIR"
        install -m 644 "$tmp/package/dist/fonts/tabler-icons.ttf" "$icon_font"
        # Name → codepoint map in Noctalia's tabler.json format: {"bell": {"codepoint": "U+EA35"}, ...}
        tr -d '\n' < "$tmp/package/dist/tabler-icons.css" \
            | grep -oE '\.ti-[a-z0-9-]+:before *\{ *content: *"\\[0-9a-fA-F]+"' \
            | sed -E 's/^\.ti-([a-z0-9-]+):before *\{ *content: *"\\([0-9a-fA-F]+)"/\1 \2/' \
            | awk 'BEGIN { printf "{" } { printf "%s\"%s\": {\"codepoint\": \"U+%s\"}", (NR > 1 ? ", " : ""), $1, toupper($2) } END { print "}" }' \
            > "$FONT_DIR/tabler.json"
        ok "Installed to $FONT_DIR"
    fi
fi

# --- 4. milk ----------------------------------------------------------------------------------
step "Building milk"
"$MILK/build.sh" | sed 's/^/  /'
mkdir -p "$HOME/.local/bin"
ln -sfn "$MILK/milk" "$HOME/.local/bin/milk"
ok "Command: milk"
config="$MILK/milk.json"
if [ -f "$config" ] && [ "$icon_font" != "$NOCTALIA_FONT" ]; then
    sed -i -E "s|(\"iconFontFile\": *)\"[^\"]*\"|\1\"$icon_font\"|" "$config"
    ok "milk.json uses $icon_font"
fi

# --- 5. Spoil -----------------------------------------------------------------------------------
step "Spoil"
if [ "$want_spoil" -eq 1 ]; then
    if [ ! -d "$SPOIL" ]; then
        info "cloning $SPOIL_URL into $SPOIL"
        git clone --depth 1 "$SPOIL_URL" "$SPOIL" || warn "Could not clone Spoil; Super+E will open the default file manager"
    elif [ -d "$SPOIL/.git" ]; then
        git -C "$SPOIL" pull --ff-only >/dev/null 2>&1 || warn "Could not update Spoil (local changes?); building what is there"
    fi
    if [ -x "$SPOIL/build.sh" ]; then
        MILK_SRC="$MILK/src" "$SPOIL/build.sh" | sed 's/^/  /'
        ln -sfn "$SPOIL/spoil" "$HOME/.local/bin/spoil"
        ok "Command: spoil (Super+E)"
    fi
else
    info "skipped"
fi

# --- 6. lactase ---------------------------------------------------------------------------------
step "lactase"
if [ "$want_lactase" -eq 1 ]; then
    if [ ! -d "$LACTASE" ]; then
        info "cloning $LACTASE_URL into $LACTASE"
        git clone --depth 1 "$LACTASE_URL" "$LACTASE" || warn "Could not clone lactase; milk runs without a compositor"
    elif [ -d "$LACTASE/.git" ]; then
        git -C "$LACTASE" pull --ff-only >/dev/null 2>&1 || warn "Could not update lactase (local changes?); building what is there"
    fi
    if [ -x "$LACTASE/build.sh" ]; then
        MILK_SRC="$MILK/src" "$LACTASE/build.sh" | sed 's/^/  /'
        ln -sfn "$LACTASE/lactase" "$HOME/.local/bin/lactase"
        ok "Command: lactase (milk starts it; settings under Efeitos)"
    fi
else
    info "skipped"
fi
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "~/.local/bin is not in your PATH; add it to use the milk, spoil and lactase commands";; esac

# --- 7. terminal theme --------------------------------------------------------------------------
step "Terminal theme"
alacritty_dir="${XDG_CONFIG_HOME:-$HOME/.config}/alacritty"
if [ ! -f "$alacritty_dir/milk.toml" ]; then
    mkdir -p "$alacritty_dir"
    imports="\"$MILK/contrib/alacritty/milk-light.toml\""
    [ -f "$alacritty_dir/alacritty.toml" ] && imports="\"$alacritty_dir/alacritty.toml\", $imports"
    printf '# Alacritty inside the milk session (the setup wizard switches the theme file).\n[general]\nimport = [%s]\n' "$imports" > "$alacritty_dir/milk.toml"
    ok "Created $alacritty_dir/milk.toml"
else
    ok "Alacritty already themed for milk"
fi

# --- 8. login screen ------------------------------------------------------------------------------
step "Login screen"
sudo "$MILK/contrib/install-sddm-session.sh" | sed 's/^/  /'

printf '\n%s✓ milk is installed.%s\n' "$G" "$N"
echo "  Log out and pick \"milk\" in the session menu of the login screen."
echo "  The first start opens the setup (theme, keyboard, wallpapers, bar)."
echo "  Later: \"milk settings\" or the gear on the bar; Super+E opens Spoil."
