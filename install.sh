#!/usr/bin/env bash
# milk installer for Arch Linux and derivatives (CachyOS, EndeavourOS, Manjaro, ...).
#
# Interactive by default: it asks for the language, which parts to install,
# shows the plan and waits for your confirmation. It installs every dependency
# with pacman, milk itself, Spoil (the file manager, Super+E) and lactase (the
# compositor) next to milk, the Tabler icon font when Noctalia's copy is
# missing, the Alacritty theme and the login-screen entry. Run over an existing
# installation it reinstalls everything (your settings stay), and the setup
# wizard always opens afterwards.
#
#   ./install.sh                 interactive install / reinstall
#   ./install.sh --lang es       language of the installer and of milk: pt, en or es
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

# --- language -------------------------------------------------------------------
# pt, en or es: the system's until the user picks one (--lang or the first question).
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
    pt*) lang=pt ;;
    es*) lang=es ;;
    *)   lang=en ;;
esac
lang_chosen=0

# t PT EN ES → the text in the installer's language
t() {
    case "$lang" in
        pt) printf '%s' "$1" ;;
        es) printf '%s' "$3" ;;
        *)  printf '%s' "$2" ;;
    esac
}

set_lang() {
    case "$1" in
        pt|pt[-_]*|por*) lang=pt ;;
        en|en[-_]*|eng*) lang=en ;;
        es|es[-_]*|spa*|esp*) lang=es ;;
        *) return 1 ;;
    esac
    lang_chosen=1
}

assume_yes=0; minimal=0; want_spoil=1; want_lactase=1; with_sddm=0; uninstall=0
args=("$@")
while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)    assume_yes=1 ;;
        --minimal)   minimal=1 ;;
        --no-spoil)  want_spoil=0 ;;
        --no-lactase) want_lactase=0 ;;
        --with-sddm) with_sddm=1 ;;
        --uninstall) uninstall=1 ;;
        --lang=*)    set_lang "${1#--lang=}" || { echo "--lang: pt, en, es" >&2; exit 2; } ;;
        --lang)      shift; set_lang "${1:-}" || { echo "--lang: pt, en, es" >&2; exit 2; } ;;
        -h|--help)   sed -n '2,/^set /{/^#/s/^# \{0,1\}//p}' "$0"; exit 0 ;;
        *) echo "$(t "opção desconhecida: $1 (veja --help)" "unknown option: $1 (see --help)" "opción desconocida: $1 (consulta --help)")" >&2; exit 2 ;;
    esac
    shift
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
    if [ "$default" = y ]; then hint=$(t "S/n" "Y/n" "S/n"); else hint=$(t "s/N" "y/N" "s/N"); fi
    while true; do
        printf '  %s?%s %s [%s] ' "$Y" "$N" "$question" "$hint"
        read -r answer < "$tty" || answer=""
        answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
        case "$answer" in
            "")                   [ "$default" = y ]; return ;;
            s|sim|si|sí|y|yes)    return 0 ;;
            n|nao|não|no)         return 1 ;;
        esac
    done
}

# The first question: the language of the rest of the installer and of milk.
if [ "$interactive" -eq 1 ] && [ "$lang_chosen" -eq 0 ]; then
    case "$lang" in pt) default=1 ;; es) default=3 ;; *) default=2 ;; esac
    printf '\n  %sIdioma / Language / Idioma%s\n' "$B" "$N"
    printf '    1) Português\n    2) English\n    3) Español\n'
    while true; do
        printf '  %s?%s [%s] ' "$Y" "$N" "$default"
        read -r answer < "$tty" || answer=""
        answer=$(printf '%s' "${answer:-$default}" | tr '[:upper:]' '[:lower:]')
        case "$answer" in
            1) set_lang pt; break ;;
            2) set_lang en; break ;;
            3) set_lang es; break ;;
            *) set_lang "$answer" && break ;;
        esac
    done
fi

[ "$(id -u)" -ne 0 ] || die "$(t "Rode como seu usuário, não como root (ele usa sudo quando precisa)." \
                                 "Run this as your user, not as root (it uses sudo when needed)." \
                                 "Ejecútalo con tu usuario, no como root (usa sudo cuando hace falta).")"
command -v pacman >/dev/null || die "$(t "pacman não encontrado: este instalador é para o Arch Linux e derivados." \
                                         "pacman not found: this installer is for Arch Linux and derivatives." \
                                         "No se encontró pacman: este instalador es para Arch Linux y derivadas.")"

# --- where is milk? --------------------------------------------------------------
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
if [ -n "$here" ] && [ -f "$here/src/milk/main.odin" ]; then
    MILK="$here"
else
    printf "$(t '%smilk%s ainda não está aqui; será clonado em %s' '%smilk%s is not here yet; it will be cloned into %s' '%smilk%s todavía no está aquí; se clonará en %s')\n" "$B" "$N" "$DATA_DIR/milk"
    sudo pacman -S --needed --noconfirm git
    mkdir -p "$DATA_DIR"
    if [ -d "$DATA_DIR/milk/.git" ]; then
        # milk.json used to live in the clone (it is now ~/.config/milk/milk.json):
        # set local edits aside so that the pull can remove it.
        if ! git -C "$DATA_DIR/milk" diff --quiet -- milk.json 2>/dev/null; then
            cp "$DATA_DIR/milk/milk.json" "$DATA_DIR/milk.json.bak"
            git -C "$DATA_DIR/milk" checkout -- milk.json
        fi
        git -C "$DATA_DIR/milk" pull --ff-only
    else
        git clone --depth 1 "$MILK_URL" "$DATA_DIR/milk"
    fi
    [ -f "$DATA_DIR/milk/src/milk/main.odin" ] || die "$(t "O repositório clonado não parece ser o milk." "The cloned repository does not look like milk." "El repositorio clonado no parece ser milk.")"
    # The clone asks nothing twice: it gets the language already chosen.
    if [ "$lang_chosen" -eq 1 ]; then args+=(--lang "$lang"); fi
    exec bash "$DATA_DIR/milk/install.sh" "${args[@]}"
fi
SPOIL="$(dirname "$MILK")/spoil"
LACTASE="$(dirname "$MILK")/lactase"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/milk"
config="$config_dir/milk.json"

# An earlier installation: the clone the last session started from, the command
# link, the login entry or the settings. It is reinstalled, not skipped.
installed_at=$(cat "$config_dir/location" 2>/dev/null || true)
if [ -z "$installed_at" ] && [ -L "$HOME/.local/bin/milk" ]; then
    installed_at=$(dirname "$(readlink -f "$HOME/.local/bin/milk")")
fi
reinstall=0
if [ -n "$installed_at" ] || [ -e /usr/local/bin/milk-session ] || [ -f "$config" ]; then reinstall=1; fi

if [ "$uninstall" -eq 1 ]; then
    printf "$(t '%sRemovendo o milk%s (configurações, dados e os clones continuam no lugar)' \
                '%sRemoving milk%s (settings, runtime data and the clones stay in place)' \
                '%sQuitando milk%s (la configuración, los datos y los clones se quedan donde están)')\n" "$B" "$N"
    ask "$(t "Remover a entrada da tela de login, os comandos milk/spoil/lactase e a fonte de ícones?" \
             "Remove the login entry, the milk/spoil/lactase commands and the icon font?" \
             "¿Quitar la entrada de la pantalla de inicio de sesión, los comandos milk/spoil/lactase y la fuente de iconos?")" y || exit 0
    sudo "$MILK/contrib/install-sddm-session.sh" --uninstall || true
    rm -f "$HOME/.local/bin/milk" "$HOME/.local/bin/spoil" "$HOME/.local/bin/lactase"
    rm -rf "$FONT_DIR"
    fc-cache -f >/dev/null 2>&1 || true
    ok "$(t "Pronto." "Done." "Listo.")"
    exit 0
fi

# --- choices ------------------------------------------------------------------------
echo
case "$lang" in
    pt) printf '  %smilk%s — um desktop em um só programa: gerenciador de janelas, barra, notificações,\n  histórico da área de transferência e papéis de parede e atalhos por área.\n' "$B" "$N" ;;
    es) printf '  %smilk%s — un escritorio en un solo programa: gestor de ventanas, barra, notificaciones,\n  historial del portapapeles y fondos de pantalla y atajos por área.\n' "$B" "$N" ;;
    *)  printf '  %smilk%s — a desktop in one program: window manager, bar, notifications,\n  clipboard history and per-area wallpapers and shortcuts.\n' "$B" "$N" ;;
esac
printf '  %s%s%s\n\n' "$D" "$(t "Instalando a partir de $MILK" "Installing from $MILK" "Instalando desde $MILK")" "$N"

if [ "$interactive" -eq 1 ]; then
    printf '%s%s%s\n' "$B" "$(t "O que deve ser instalado?" "What should be installed?" "¿Qué quieres instalar?")" "$N"
    if [ "$want_spoil" -eq 1 ]; then
        ask "$(t "Spoil, o gerenciador de arquivos (Super+E), com prévias, miniaturas e arquivos compactados?" \
                 "Spoil, the file manager (Super+E), with previews, thumbnails and archives?" \
                 "¿Spoil, el gestor de archivos (Super+E), con vistas previas, miniaturas y archivos comprimidos?")" y || want_spoil=0
    fi
    if [ "$want_lactase" -eq 1 ]; then
        ask "$(t "lactase, o compositor (sombras, animações, transparência, desfoque, cantos suaves)?" \
                 "lactase, the compositor (shadows, animations, transparency, blur, smooth corners)?" \
                 "¿lactase, el compositor (sombras, animaciones, transparencia, desenfoque, esquinas suaves)?")" y || want_lactase=0
    fi
    if [ "$minimal" -eq 0 ]; then
        ask "$(t "Ferramentas opcionais (Alacritty, rofi, capturas de tela, teclas de brilho, informações do player)?" \
                 "Optional tools (Alacritty, rofi, screenshots, brightness keys, media player info)?" \
                 "¿Herramientas opcionales (Alacritty, rofi, capturas de pantalla, teclas de brillo, información del reproductor)?")" y || minimal=1
    fi
    if ! systemctl is-enabled --quiet display-manager.service 2>/dev/null && [ "$with_sddm" -eq 0 ]; then
        ask "$(t "Nenhuma tela de login (display manager) está ativada. Instalar e ativar o SDDM?" \
                 "No login screen (display manager) is enabled. Install and enable SDDM?" \
                 "No hay ninguna pantalla de inicio de sesión (display manager) activada. ¿Instalar y activar SDDM?")" y && with_sddm=1
    fi
    enable_services=1
    ask "$(t "Ativar o NetworkManager e o Bluetooth se estiverem desligados (usados pelos menus de Wi-Fi e Bluetooth)?" \
             "Enable NetworkManager and Bluetooth if they are off (needed by the Wi-Fi and Bluetooth menus)?" \
             "¿Activar NetworkManager y Bluetooth si están apagados (los usan los menús de Wi-Fi y Bluetooth)?")" y || enable_services=0
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
        warn "$(t "o pacote $p não está nos seus repositórios; ignorando" "package $p is not in your repositories; skipping it" "el paquete $p no está en tus repositorios; se omite")"
    fi
done
mapfile -t missing < <(pacman -T "${available[@]}" || true)

case "$lang" in pt) milk_locale=pt-BR; lang_name="Português" ;; es) milk_locale=es; lang_name="Español" ;; *) milk_locale=en; lang_name="English" ;; esac
parts="milk"
[ "$want_spoil" -eq 1 ] && parts+=" + Spoil"
[ "$want_lactase" -eq 1 ] && parts+=" + lactase"

printf '\n%s%s%s\n' "$B" "$(t "Plano" "Plan" "Plan")" "$N"
info "$(t "$parts, em $MILK" "$parts, in $MILK" "$parts, en $MILK")"
if [ "$reinstall" -eq 1 ]; then
    where=${installed_at:-$MILK}
    info "$(t "o milk já está instalado ($where) e será reinstalado; suas configurações em $config são mantidas" \
              "milk is already installed ($where) and will be reinstalled; your settings in $config are kept" \
              "milk ya está instalado ($where) y se reinstalará; tu configuración en $config se conserva")"
fi
if [ ${#missing[@]} -eq 0 ]; then
    info "$(t "todos os ${#available[@]} pacotes já estão instalados" "all ${#available[@]} packages are already installed" "los ${#available[@]} paquetes ya están instalados")"
elif [ ${#missing[@]} -eq 1 ]; then
    info "$(t "1 pacote para instalar:" "1 package to install:" "1 paquete por instalar:") ${missing[*]}"
else
    info "$(t "${#missing[@]} pacotes para instalar:" "${#missing[@]} packages to install:" "${#missing[@]} paquetes por instalar:") ${missing[*]}"
fi
[ -f "$NOCTALIA_FONT" ] || info "$(t "fonte de ícones Tabler $TABLER_VERSION em $FONT_DIR" "Tabler icon font $TABLER_VERSION into $FONT_DIR" "fuente de iconos Tabler $TABLER_VERSION en $FONT_DIR")"
info "$(t "comandos em ~/.local/bin, o tema do Alacritty e a sessão \"milk\" na tela de login" \
          "commands in ~/.local/bin, the Alacritty theme and the \"milk\" session on the login screen" \
          "comandos en ~/.local/bin, el tema de Alacritty y la sesión \"milk\" en la pantalla de inicio de sesión")"
[ "$lang_chosen" -eq 1 ] && info "$(t "idioma do milk: $lang_name" "milk's language: $lang_name" "idioma de milk: $lang_name")"
info "$(t "no fim, a configuração inicial (tema, teclado, papéis de parede, barra, janelas) abre" \
          "afterwards the setup wizard (theme, keyboard, wallpapers, bar, windows) opens" \
          "al final se abre el asistente de configuración (tema, teclado, fondos, barra, ventanas)")"
echo
ask "$(t "Continuar?" "Continue?" "¿Continuar?")" y || { t "Nada foi alterado." "Nothing was changed." "No se cambió nada."; echo; exit 0; }

# --- 1. packages ------------------------------------------------------------------------
step "$(t "Instalando pacotes" "Installing packages" "Instalando paquetes")"
if [ ${#missing[@]} -gt 0 ]; then
    pacman_flags=(--needed)
    if [ "$interactive" -eq 1 ]; then
        sudo pacman -S "${pacman_flags[@]}" "${missing[@]}" < "$tty"   # pacman may ask about conflicts
    else
        sudo pacman -S "${pacman_flags[@]}" --noconfirm "${missing[@]}"
    fi
fi
ok "$(t "Dependências prontas" "Dependencies ready" "Dependencias listas")"

# --- 2. services ------------------------------------------------------------------------
step "$(t "Serviços" "Services" "Servicios")"
if [ "${enable_services:-1}" -eq 1 ]; then
    for unit in NetworkManager.service bluetooth.service; do
        if systemctl list-unit-files "$unit" >/dev/null 2>&1 && ! systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            sudo systemctl enable --now "$unit" && ok "$(t "$unit ativado" "$unit enabled" "$unit activado")"
        else
            ok "$(t "$unit já estava ativado" "$unit already enabled" "$unit ya estaba activado")"
        fi
    done
else
    info "$(t "mantidos como estão" "left as they are" "se quedan como están")"
fi
if [ "$with_sddm" -eq 1 ]; then
    if systemctl is-enabled --quiet display-manager.service 2>/dev/null; then
        ok "$(t "Uma tela de login já está ativada" "A login screen is already enabled" "Ya hay una pantalla de inicio de sesión activada")"
    else
        sudo systemctl enable sddm.service && ok "$(t "SDDM ativado (inicia no próximo boot)" "SDDM enabled (starts at the next boot)" "SDDM activado (se inicia en el próximo arranque)")"
    fi
fi
xdg-user-dirs-update >/dev/null 2>&1 || true

# --- 3. icon font ---------------------------------------------------------------------------
step "$(t "Fonte de ícones" "Icon font" "Fuente de iconos")"
icon_font="$NOCTALIA_FONT"
if [ -f "$NOCTALIA_FONT" ]; then
    ok "$(t "Usando a fonte de ícones Tabler do Noctalia" "Using Noctalia's Tabler icon font" "Usando la fuente de iconos Tabler de Noctalia")"
else
    icon_font="$FONT_DIR/tabler-icons.ttf"
    if [ -f "$icon_font" ] && [ -f "$FONT_DIR/tabler.json" ]; then
        ok "$(t "Fonte de ícones Tabler já instalada" "Tabler icon font already installed" "La fuente de iconos Tabler ya está instalada")"
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
        ok "$(t "Instalada em $FONT_DIR" "Installed to $FONT_DIR" "Instalada en $FONT_DIR")"
    fi
fi

# --- 4. milk ----------------------------------------------------------------------------------
step "$(t "Compilando o milk" "Building milk" "Compilando milk")"
"$MILK/build.sh" | sed 's/^/  /'
mkdir -p "$HOME/.local/bin"
ln -sfn "$MILK/milk" "$HOME/.local/bin/milk"
ok "$(t "Comando: milk" "Command: milk" "Comando: milk")"
# The login launcher starts the clone recorded here before looking elsewhere,
# so a reinstall from another clone takes over from now on.
mkdir -p "$config_dir"
printf '%s\n' "$MILK" > "$config_dir/location"
# The settings live outside the clone; a new installation starts from the defaults.
if [ ! -f "$config" ]; then
    cp "$MILK/milk.default.json" "$config"
    ok "$(t "Configurações em $config" "Settings in $config" "Configuración en $config")"
fi
# milk opens the setup wizard while this file exists (the wizard removes it),
# even when its runtime folder says the setup already ran.
: > "$config_dir/.setup-pending"
if [ -f "$config" ] && [ "$icon_font" != "$NOCTALIA_FONT" ]; then
    sed -i -E "s|(\"iconFontFile\": *)\"[^\"]*\"|\1\"$icon_font\"|" "$config"
    ok "$(t "milk.json usa $icon_font" "milk.json uses $icon_font" "milk.json usa $icon_font")"
fi
# milk speaks the language picked here (bar.locale); an unattended run leaves it alone.
if [ -f "$config" ] && [ "$lang_chosen" -eq 1 ]; then
    if grep -q '"locale"' "$config"; then
        sed -i -E "s|(\"locale\": *)\"[^\"]*\"|\1\"$milk_locale\"|" "$config"
    else
        sed -i -E "0,/\"bar\": *\{/s//\"bar\": {\n    \"locale\": \"$milk_locale\",/" "$config"
    fi
    ok "$(t "milk em português" "milk in English" "milk en español")"
fi

# --- 5. Spoil -----------------------------------------------------------------------------------
step "Spoil"
if [ "$want_spoil" -eq 1 ]; then
    if [ ! -d "$SPOIL" ]; then
        info "$(t "clonando $SPOIL_URL em $SPOIL" "cloning $SPOIL_URL into $SPOIL" "clonando $SPOIL_URL en $SPOIL")"
        git clone --depth 1 "$SPOIL_URL" "$SPOIL" || warn "$(t "Não foi possível clonar o Spoil; Super+E abrirá o gerenciador de arquivos padrão" \
                                                              "Could not clone Spoil; Super+E will open the default file manager" \
                                                              "No se pudo clonar Spoil; Super+E abrirá el gestor de archivos predeterminado")"
    elif [ -d "$SPOIL/.git" ]; then
        git -C "$SPOIL" pull --ff-only >/dev/null 2>&1 || warn "$(t "Não foi possível atualizar o Spoil (alterações locais?); compilando o que existe" \
                                                                  "Could not update Spoil (local changes?); building what is there" \
                                                                  "No se pudo actualizar Spoil (¿cambios locales?); se compila lo que hay")"
    fi
    if [ -x "$SPOIL/build.sh" ]; then
        MILK_SRC="$MILK/src" "$SPOIL/build.sh" | sed 's/^/  /'
        ln -sfn "$SPOIL/spoil" "$HOME/.local/bin/spoil"
        ok "$(t "Comando: spoil (Super+E)" "Command: spoil (Super+E)" "Comando: spoil (Super+E)")"
    fi
else
    info "$(t "ignorado" "skipped" "omitido")"
fi

# --- 6. lactase ---------------------------------------------------------------------------------
step "lactase"
if [ "$want_lactase" -eq 1 ]; then
    if [ ! -d "$LACTASE" ]; then
        info "$(t "clonando $LACTASE_URL em $LACTASE" "cloning $LACTASE_URL into $LACTASE" "clonando $LACTASE_URL en $LACTASE")"
        git clone --depth 1 "$LACTASE_URL" "$LACTASE" || warn "$(t "Não foi possível clonar o lactase; o milk funciona sem compositor" \
                                                                  "Could not clone lactase; milk runs without a compositor" \
                                                                  "No se pudo clonar lactase; milk funciona sin compositor")"
    elif [ -d "$LACTASE/.git" ]; then
        git -C "$LACTASE" pull --ff-only >/dev/null 2>&1 || warn "$(t "Não foi possível atualizar o lactase (alterações locais?); compilando o que existe" \
                                                                    "Could not update lactase (local changes?); building what is there" \
                                                                    "No se pudo actualizar lactase (¿cambios locales?); se compila lo que hay")"
    fi
    if [ -x "$LACTASE/build.sh" ]; then
        MILK_SRC="$MILK/src" "$LACTASE/build.sh" | sed 's/^/  /'
        ln -sfn "$LACTASE/lactase" "$HOME/.local/bin/lactase"
        ok "$(t "Comando: lactase (o milk o inicia; ajustes em Efeitos)" \
                "Command: lactase (milk starts it; settings under Effects)" \
                "Comando: lactase (milk lo inicia; ajustes en Efectos)")"
    fi
else
    info "$(t "ignorado" "skipped" "omitido")"
fi
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) warn "$(t "~/.local/bin não está no seu PATH; adicione-o para usar os comandos milk, spoil e lactase" \
                 "~/.local/bin is not in your PATH; add it to use the milk, spoil and lactase commands" \
                 "~/.local/bin no está en tu PATH; añádelo para usar los comandos milk, spoil y lactase")" ;;
esac

# --- 7. terminal theme --------------------------------------------------------------------------
step "$(t "Tema do terminal" "Terminal theme" "Tema de la terminal")"
alacritty_dir="${XDG_CONFIG_HOME:-$HOME/.config}/alacritty"
if [ ! -f "$alacritty_dir/milk.toml" ]; then
    mkdir -p "$alacritty_dir"
    imports="\"$MILK/contrib/alacritty/milk-light.toml\""
    [ -f "$alacritty_dir/alacritty.toml" ] && imports="\"$alacritty_dir/alacritty.toml\", $imports"
    printf '# Alacritty inside the milk session (the setup wizard switches the theme file).\n[general]\nimport = [%s]\n' "$imports" > "$alacritty_dir/milk.toml"
    ok "$(t "Criado $alacritty_dir/milk.toml" "Created $alacritty_dir/milk.toml" "Creado $alacritty_dir/milk.toml")"
else
    # The theme import follows the clone being installed (same light/dark file).
    sed -i -E "s|\"[^\"]*/contrib/alacritty/(milk-[A-Za-z0-9_-]+\.toml)\"|\"$MILK/contrib/alacritty/\1\"|g" "$alacritty_dir/milk.toml"
    ok "$(t "O Alacritty já tem o tema do milk" "Alacritty already themed for milk" "Alacritty ya tiene el tema de milk")"
fi

# --- 8. login screen ------------------------------------------------------------------------------
step "$(t "Tela de login" "Login screen" "Pantalla de inicio de sesión")"
sudo "$MILK/contrib/install-sddm-session.sh" | sed 's/^/  /'

printf '\n%s✓ %s%s\n' "$G" "$(t "O milk está instalado." "milk is installed." "milk está instalado.")" "$N"
# Inside a running milk session the setup opens right away (the running
# instance reloads when it is done); elsewhere at milk's next start.
if [ "${XDG_CURRENT_DESKTOP:-}" = milk ] && [ -n "${DISPLAY:-}" ] && "$MILK/bin/milk" status >/dev/null 2>&1; then
    setsid -f "$MILK/bin/milk" setup >/dev/null 2>&1 < /dev/null
    t "  A configuração inicial está abrindo (tema, teclado, papéis de parede, barra, janelas)." \
      "  The setup is opening now (theme, keyboard, wallpapers, bar, windows)." \
      "  La configuración se está abriendo (tema, teclado, fondos de pantalla, barra, ventanas)."
    echo
    t "  Saia da sessão e entre de novo para usar a nova versão do milk." \
      "  Log out and back in to run the new build of milk." \
      "  Cierra la sesión y vuelve a entrar para usar la nueva versión de milk."
    echo
else
    t "  Saia da sessão e escolha \"milk\" no menu de sessões da tela de login." \
      "  Log out and pick \"milk\" in the session menu of the login screen." \
      "  Cierra la sesión y elige \"milk\" en el menú de sesiones de la pantalla de inicio."
    echo
    t "  O próximo início abre a configuração (tema, teclado, papéis de parede, barra, janelas)." \
      "  The next start opens the setup (theme, keyboard, wallpapers, bar, windows)." \
      "  El próximo inicio abre la configuración (tema, teclado, fondos de pantalla, barra, ventanas)."
    echo
fi
t "  Depois: \"milk settings\" ou a engrenagem da barra; Super+E abre o Spoil." \
  "  Later: \"milk settings\" or the gear on the bar; Super+E opens Spoil." \
  "  Después: \"milk settings\" o el engranaje de la barra; Super+E abre Spoil."
echo
