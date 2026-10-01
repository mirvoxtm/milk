#!/usr/bin/env bash
# milk installer for the popular Linux distributions: Arch and its family
# (CachyOS, EndeavourOS, Manjaro, Garuda, Artix...), Debian and Ubuntu and
# theirs (Linux Mint, Pop!_OS, elementary, Zorin...), Fedora (Nobara,
# Ultramarine...), openSUSE (Tumbleweed, Slowroll, Leap) and Void. The
# distribution is detected from /etc/os-release (else from its package
# manager); when that fails you pick it from a list, or "other" to install
# the dependencies yourself.
#
# Interactive by default: it asks for the language, which parts to install,
# shows the plan and waits for your confirmation. It installs every dependency
# with your package manager, the Odin compiler when your distribution has no
# recent one, milk itself, Spoil (the file manager, Super+E) and lactase (the
# compositor) next to milk, matugen (colours from the wallpaper) if you want
# it, the Tabler icon font when Noctalia's copy is missing, the Alacritty theme
# and the login-screen entry. Run over an existing installation it reinstalls
# everything (your settings stay), and the setup wizard always opens afterwards.
#
#   ./install.sh                 interactive install / reinstall
#   ./install.sh --lang es       language of the installer and of milk: pt, en or es
#   ./install.sh --distro fedora force the distribution: arch, debian, fedora, opensuse, void or other
#   ./install.sh --yes           accept every default without asking
#   ./install.sh --dry-run       show the plan and stop without changing anything
#   ./install.sh --minimal       skip the optional tools
#   ./install.sh --no-spoil      do not install Spoil
#   ./install.sh --no-lactase    do not install lactase (shadows, animations, transparency)
#   ./install.sh --no-matugen    do not install matugen (theme colours from the wallpaper)
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
# The Odin release milk is built with; installed when the system has no Odin this recent.
ODIN_RELEASE="dev-2026-09"
ODIN_BASE_URL="https://github.com/odin-lang/Odin/releases/download/$ODIN_RELEASE"
# matugen's release binary, for distributions that do not package it (x86_64 only).
MATUGEN_VERSION="4.2.0"
MATUGEN_URL="https://github.com/InioX/matugen/releases/download/v$MATUGEN_VERSION/matugen-$MATUGEN_VERSION-x86_64.tar.gz"
# adw-gtk3, the GTK 3 theme milk colours (appearance.themeApps), where the distribution has no package.
ADW_GTK3_VERSION="6.5"
ADW_GTK3_URL="https://github.com/lassekongo83/adw-gtk3/releases/download/v$ADW_GTK3_VERSION/adw-gtk3v$ADW_GTK3_VERSION.tar.xz"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/milk"
FONT_DIR="$DATA_DIR/fonts"
BIN_DIR="$HOME/.local/bin"
# Commands installed here (milk, odin, matugen) are found by the rest of the run.
user_path=$PATH
export PATH="$BIN_DIR:$PATH"

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

assume_yes=0; minimal=0; want_spoil=1; want_lactase=1; want_matugen=1; with_sddm=0; uninstall=0; dry_run=0
distro=""
args=("$@")
while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)    assume_yes=1 ;;
        --minimal)   minimal=1 ;;
        --no-spoil)  want_spoil=0 ;;
        --no-lactase) want_lactase=0 ;;
        --no-matugen) want_matugen=0 ;;
        --with-sddm) with_sddm=1 ;;
        --uninstall) uninstall=1 ;;
        --dry-run)   dry_run=1 ;;
        --distro=*)  distro="${1#--distro=}" ;;
        --distro)    shift; distro="${1:-}" ;;
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
step_no=0; step_total=9
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

# --- distribution -------------------------------------------------------------------
# arch, debian, fedora, opensuse, void, or other (the dependencies are yours to install).
DISTROS=(arch debian fedora opensuse void other)

distro_title() {
    case "$1" in
        arch)     printf 'Arch Linux (pacman)' ;;
        debian)   printf 'Debian / Ubuntu (apt)' ;;
        fedora)   printf 'Fedora (dnf)' ;;
        opensuse) printf 'openSUSE (zypper)' ;;
        void)     printf 'Void Linux (xbps)' ;;
        *)        t "outra (você instala as dependências)" "other (you install the dependencies)" "otra (tú instalas las dependencias)" ;;
    esac
}

# The family from /etc/os-release (ID, then ID_LIKE), else from the package manager.
detect_distro() {
    local ids="" id
    if [ -r /etc/os-release ]; then
        ids=$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")
    fi
    for id in $ids; do
        case "$id" in
            arch|archarm|manjaro*|endeavouros|cachyos|garuda|artix|arcolinux|rebornos|parabola) echo arch; return ;;
            debian|ubuntu|linuxmint|pop|elementary|zorin|kali|raspbian|neon|devuan|mx|deepin|peppermint) echo debian; return ;;
            fedora|nobara|ultramarine|rhel|centos|rocky|almalinux) echo fedora; return ;;
            opensuse*|suse|sles|sled) echo opensuse; return ;;
            void) echo void; return ;;
        esac
    done
    if command -v pacman >/dev/null; then echo arch
    elif command -v apt-get >/dev/null; then echo debian
    elif command -v dnf >/dev/null; then echo fedora
    elif command -v zypper >/dev/null; then echo opensuse
    elif command -v xbps-install >/dev/null; then echo void
    fi
}

case "$distro" in
    "") distro=$(detect_distro) ;;
    arch|debian|fedora|opensuse|void|other) ;;
    ubuntu|mint|pop) distro=debian ;;
    suse|tumbleweed|leap) distro=opensuse ;;
    *) die "--distro: arch, debian, fedora, opensuse, void, other" ;;
esac
if [ -z "$distro" ]; then
    [ "$interactive" -eq 1 ] || die "$(t "Não foi possível reconhecer a distribuição; use --distro (arch, debian, fedora, opensuse, void ou other)." \
                                         "Could not recognise the distribution; use --distro (arch, debian, fedora, opensuse, void or other)." \
                                         "No se pudo reconocer la distribución; usa --distro (arch, debian, fedora, opensuse, void u other).")"
    printf '\n  %s%s%s\n' "$B" "$(t "Não reconheci sua distribuição. Qual destas é a sua (ou a base dela)?" \
                                     "I could not recognise your distribution. Which of these is it (or is it based on)?" \
                                     "No reconocí tu distribución. ¿Cuál de estas es (o en cuál se basa)?")" "$N"
    for k in "${!DISTROS[@]}"; do printf '    %d) %s\n' $((k + 1)) "$(distro_title "${DISTROS[$k]}")"; done
    while true; do
        printf '  %s?%s [1-%d] ' "$Y" "$N" "${#DISTROS[@]}"
        read -r answer < "$tty" || answer=""
        if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#DISTROS[@]}" ]; then
            distro=${DISTROS[$((answer - 1))]}
            break
        fi
    done
fi

# The init system that starts services: systemd, runit (Void), openrc (Artix, Devuan...).
if [ -d /run/systemd/system ]; then init=systemd
elif command -v sv >/dev/null && [ -d /var/service ]; then init=runit
elif command -v rc-service >/dev/null; then init=openrc
else init=none
fi

# --- package manager ------------------------------------------------------------------
# The queries run in the C locale: pacman and zypper translate their field names.
pm_install() {
    [ $# -gt 0 ] || return 0
    case "$distro" in
        arch)
            if [ "$interactive" -eq 1 ]; then sudo pacman -S --needed "$@" < "$tty"; else sudo pacman -S --needed --noconfirm "$@"; fi ;;
        debian)
            sudo apt-get update -qq || true
            if [ "$interactive" -eq 1 ]; then sudo apt-get install "$@" < "$tty"; else sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; fi ;;
        fedora)
            if [ "$interactive" -eq 1 ]; then sudo dnf install "$@" < "$tty"; else sudo dnf install -y "$@"; fi ;;
        opensuse)
            if [ "$interactive" -eq 1 ]; then sudo zypper install "$@" < "$tty"; else sudo zypper --non-interactive install "$@"; fi ;;
        void)
            if [ "$interactive" -eq 1 ]; then sudo xbps-install -S "$@" < "$tty"; else sudo xbps-install -Sy "$@"; fi ;;
        *) return 1 ;;
    esac
}

# Make sure the package lists exist before asking them anything (fresh systems and containers).
pm_prepare() {
    case "$distro" in
        arch)
            ls /var/lib/pacman/sync/*.db >/dev/null 2>&1 || sudo pacman -Sy >/dev/null ;;
        debian)
            if ! ls /var/lib/apt/lists/*_Packages >/dev/null 2>&1; then
                info "$(t "baixando a lista de pacotes (apt-get update)" "downloading the package lists (apt-get update)" "descargando las listas de paquetes (apt-get update)")"
                sudo apt-get update -qq
            fi ;;
        opensuse)
            ls /var/cache/zypp/solv/*/solv >/dev/null 2>&1 || sudo zypper --non-interactive --quiet refresh ;;
        void)
            ls /var/db/xbps/*/*-repodata >/dev/null 2>&1 || sudo xbps-install -S >/dev/null ;;
    esac
}

# The names among $@ that the repositories provide (or that are installed already), one per line.
pm_available() {
    local p
    case "$distro" in
        arch)
            { LC_ALL=C pacman -Si "$@"; LC_ALL=C pacman -Qi "$@"; } 2>/dev/null | sed -n 's/^Name *: *//p' | sort -u ;;
        debian)
            LC_ALL=C apt-cache show --no-all-versions "$@" 2>/dev/null | sed -n 's/^Package: *//p' | sort -u ;;
        fedora)
            LC_ALL=C dnf repoquery -q --queryformat '%{name}\n' "$@" 2>/dev/null | sed 's/\\n$//' | sort -u ;;
        opensuse)
            LC_ALL=C zypper --non-interactive --quiet search --match-exact -t package "$@" 2>/dev/null |
                sed -n 's/^[^|]*| *\([^ |]*\) *|.*/\1/p' | grep -vx Name | sort -u ;;
        void)
            for p in "$@"; do xbps-query -R "$p" >/dev/null 2>&1 && echo "$p"; done ;;
    esac
    return 0
}

# The names among $@ that are not installed yet, one per line.
pm_missing() {
    local p
    case "$distro" in
        arch) pacman -T "$@" || true ;;
        debian)
            for p in "$@"; do
                dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null | grep -q '^ii' || echo "$p"
            done ;;
        fedora|opensuse)
            for p in "$@"; do rpm -q "$p" >/dev/null 2>&1 || echo "$p"; done ;;
        void)
            for p in "$@"; do xbps-query "$p" >/dev/null 2>&1 || echo "$p"; done ;;
    esac
    return 0
}

# Package lists may give alternatives as "a|b" (the first one the repositories
# have is used) and mark packages "?name" that are skipped quietly when missing.
# Sets `resolved` (the names to install) and `unavailable` (required, not found).
resolve_packages() {
    local entry alt pick quiet
    local -a names=() alts=() avail=()
    local -A have=()
    for entry in "$@"; do
        IFS='|' read -ra alts <<< "${entry#\?}"
        names+=("${alts[@]}")
    done
    mapfile -t avail < <(pm_available "${names[@]}")
    for alt in "${avail[@]}"; do [ -n "$alt" ] && have[$alt]=1; done
    resolved=(); unavailable=()
    for entry in "$@"; do
        quiet=0
        if [ "${entry:0:1}" = "?" ]; then quiet=1; entry=${entry:1}; fi
        IFS='|' read -ra alts <<< "$entry"
        pick=""
        for alt in "${alts[@]}"; do
            if [ -n "${have[$alt]:-}" ]; then pick=$alt; break; fi
        done
        if [ -n "$pick" ]; then resolved+=("$pick")
        elif [ "$quiet" -eq 0 ]; then unavailable+=("$entry")
        fi
    done
    local -A seen=()
    local -a unique=()
    for alt in "${resolved[@]}"; do
        [ -n "${seen[$alt]:-}" ] || unique+=("$alt")
        seen[$alt]=1
    done
    resolved=("${unique[@]}")
}

# Services, whatever starts them. Names: NetworkManager, bluetooth, sddm, dbus, elogind.
svc_name() {
    case "$init:$1" in
        runit:bluetooth) echo bluetoothd ;;
        *) echo "$1" ;;
    esac
}
svc_exists() {
    local s; s=$(svc_name "$1")
    case "$init" in
        systemd) systemctl list-unit-files "$s.service" 2>/dev/null | grep -q "^$s.service" ;;
        runit)   [ -d "/etc/sv/$s" ] ;;
        openrc)  [ -x "/etc/init.d/$s" ] ;;
        *)       return 1 ;;
    esac
}
svc_enabled() {
    local s; s=$(svc_name "$1")
    case "$init" in
        systemd) systemctl is-enabled --quiet "$s.service" 2>/dev/null ;;
        runit)   [ -e "/var/service/$s" ] ;;
        openrc)  rc-update show default 2>/dev/null | grep -qw "$s" ;;
        *)       return 0 ;;
    esac
}
svc_enable() { # $1 = service, $2 = 1 to start it now
    local s; s=$(svc_name "$1")
    case "$init" in
        systemd) if [ "${2:-1}" -eq 1 ]; then sudo systemctl enable --now "$s.service"; else sudo systemctl enable "$s.service"; fi ;;
        runit)   sudo ln -sf "/etc/sv/$s" "/var/service/" ;;
        openrc)  sudo rc-update add "$s" default && { [ "${2:-1}" -eq 0 ] || sudo rc-service "$s" start; } ;;
        *)       return 1 ;;
    esac
}
# Whether some display manager (login screen) starts at boot.
dm_enabled() {
    local s
    case "$init" in
        systemd) systemctl is-enabled --quiet display-manager.service 2>/dev/null ;;
        runit)
            for s in sddm lightdm gdm lxdm slim ly emptty; do [ -e "/var/service/$s" ] && return 0; done
            return 1 ;;
        openrc) rc-update show default 2>/dev/null | grep -qE 'display-manager|sddm|lightdm|gdm' ;;
        *) return 0 ;;
    esac
}

# The Odin compiler: its release month (YYYYMM) or 0.
odin_month() {
    "$1" version 2>/dev/null | sed -nE 's/.*dev-([0-9]{4})-([0-9]{2}).*/\1\2/p' | head -n 1
}
ODIN_MIN=$(printf '%s' "$ODIN_RELEASE" | sed -E 's/dev-([0-9]{4})-([0-9]{2}).*/\1\2/')
# An Odin at least as recent as ODIN_RELEASE, if one is installed (its path).
usable_odin() {
    local cand month
    for cand in "$(command -v odin 2>/dev/null || true)" "$DATA_DIR/odin/current/odin"; do
        [ -n "$cand" ] && [ -x "$cand" ] || continue
        month=$(odin_month "$cand")
        if [ -n "$month" ] && [ "$month" -ge "$ODIN_MIN" ]; then echo "$cand"; return 0; fi
    done
    return 1
}

# --- where is milk? --------------------------------------------------------------
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
if [ -n "$here" ] && [ -f "$here/src/milk/main.odin" ]; then
    MILK="$here"
elif [ "$dry_run" -eq 1 ]; then
    MILK="$DATA_DIR/milk"
    printf "$(t '%smilk%s ainda não está aqui; seria clonado em %s' '%smilk%s is not here yet; it would be cloned into %s' '%smilk%s todavía no está aquí; se clonaría en %s')\n" "$B" "$N" "$MILK"
else
    printf "$(t '%smilk%s ainda não está aqui; será clonado em %s' '%smilk%s is not here yet; it will be cloned into %s' '%smilk%s todavía no está aquí; se clonará en %s')\n" "$B" "$N" "$DATA_DIR/milk"
    if ! command -v git >/dev/null; then
        [ "$distro" != other ] || die "$(t "Instale o git e rode o instalador de novo." "Install git and run the installer again." "Instala git y vuelve a ejecutar el instalador.")"
        pm_prepare
        pm_install git
    fi
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
    # The clone asks nothing twice: it gets the language and distribution already chosen.
    if [ "$lang_chosen" -eq 1 ]; then args+=(--lang "$lang"); fi
    args+=(--distro "$distro")
    exec bash "$DATA_DIR/milk/install.sh" "${args[@]}"
fi
SPOIL="$(dirname "$MILK")/spoil"
LACTASE="$(dirname "$MILK")/lactase"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/milk"
config="$config_dir/milk.json"

# Where the login entry goes: SDDM and GDM read /usr/local/share/xsessions too,
# LightDM (Mint, Xubuntu...) and other distributions' setups only /usr/share.
xsessions_dir=/usr/local/share/xsessions
if [ "$distro" != arch ] || [ -d /etc/lightdm ] || command -v lightdm >/dev/null; then xsessions_dir=/usr/share/xsessions; fi

# An earlier installation: the clone the last session started from, the command
# link, the login entry or the settings. It is reinstalled, not skipped.
installed_at=$(cat "$config_dir/location" 2>/dev/null || true)
if [ -z "$installed_at" ] && [ -L "$BIN_DIR/milk" ]; then
    installed_at=$(dirname "$(readlink -f "$BIN_DIR/milk")")
fi
reinstall=0
if [ -n "$installed_at" ] || [ -e /usr/local/bin/milk-session ] || [ -f "$config" ]; then reinstall=1; fi

# Whether ~/.local/bin/$1 is a link into milk's data folder (the odin and matugen it downloaded).
our_link() {
    [ -L "$BIN_DIR/$1" ] || return 1
    case "$(readlink "$BIN_DIR/$1")" in "$DATA_DIR"/*) return 0 ;; esac
    return 1
}

if [ "$uninstall" -eq 1 ]; then
    printf "$(t '%sRemovendo o milk%s (configurações, dados e os clones continuam no lugar)' \
                '%sRemoving milk%s (settings, runtime data and the clones stay in place)' \
                '%sQuitando milk%s (la configuración, los datos y los clones se quedan donde están)')\n" "$B" "$N"
    ask "$(t "Remover a entrada da tela de login, os comandos milk/spoil/lactase, a fonte de ícones e o Odin/matugen baixados pelo instalador?" \
             "Remove the login entry, the milk/spoil/lactase commands, the icon font and the Odin/matugen the installer downloaded?" \
             "¿Quitar la entrada de la pantalla de inicio de sesión, los comandos milk/spoil/lactase, la fuente de iconos y el Odin/matugen que descargó el instalador?")" y || exit 0
    sudo "$MILK/contrib/install-sddm-session.sh" --uninstall || true
    if [ -e /usr/share/xsessions/milk.desktop ]; then
        sudo env XSESSIONS_DIR=/usr/share/xsessions "$MILK/contrib/install-sddm-session.sh" --uninstall || true
    fi
    if grep -q 'installed by milk/install.sh' /etc/pam.d/milk 2>/dev/null; then sudo rm -f /etc/pam.d/milk; fi
    rm -f "${BIN_DIR:?}/milk" "${BIN_DIR:?}/spoil" "${BIN_DIR:?}/lactase"
    if our_link odin; then rm -f "${BIN_DIR:?}/odin"; fi
    if our_link matugen; then rm -f "${BIN_DIR:?}/matugen"; fi
    rm -rf "${FONT_DIR:?}" "${DATA_DIR:?}/odin" "${DATA_DIR:?}/bin"
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
printf '  %s%s%s\n' "$D" "$(t "Instalando a partir de $MILK" "Installing from $MILK" "Instalando desde $MILK")" "$N"
printf '  %s%s: %s%s\n\n' "$D" "$(t "Distribuição" "Distribution" "Distribución")" "$(distro_title "$distro")" "$N"

enable_services=1
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
    if [ "$want_matugen" -eq 1 ]; then
        ask "$(t "matugen, para gerar o tema a partir das cores do papel de parede (tema \"Papel de parede\")?" \
                 "matugen, to make the theme from the colours of the wallpaper (the \"Wallpaper\" theme)?" \
                 "¿matugen, para generar el tema con los colores del fondo de pantalla (tema \"Fondo de pantalla\")?")" y || want_matugen=0
    fi
    if [ "$minimal" -eq 0 ]; then
        ask "$(t "Ferramentas opcionais (Alacritty, rofi, capturas de tela, teclas de brilho, informações do player)?" \
                 "Optional tools (Alacritty, rofi, screenshots, brightness keys, media player info)?" \
                 "¿Herramientas opcionales (Alacritty, rofi, capturas de pantalla, teclas de brillo, información del reproductor)?")" y || minimal=1
    fi
    if [ "$distro" != other ] && ! dm_enabled && [ "$with_sddm" -eq 0 ]; then
        ask "$(t "Nenhuma tela de login (display manager) está ativada. Instalar e ativar o SDDM?" \
                 "No login screen (display manager) is enabled. Install and enable SDDM?" \
                 "No hay ninguna pantalla de inicio de sesión (display manager) activada. ¿Instalar y activar SDDM?")" y && with_sddm=1
    fi
    if [ "$distro" != other ] && [ "$init" != none ]; then
        ask "$(t "Ativar o NetworkManager e o Bluetooth se estiverem desligados (usados pelos menus de Wi-Fi e Bluetooth)?" \
                 "Enable NetworkManager and Bluetooth if they are off (needed by the Wi-Fi and Bluetooth menus)?" \
                 "¿Activar NetworkManager y Bluetooth si están apagados (los usan los menús de Wi-Fi y Bluetooth)?")" y || enable_services=0
    fi
fi

# --- packages -------------------------------------------------------------------------
# Per distribution. "a|b": the first one the repositories have; "?name": skipped
# quietly when the repositories do not have it (the Nerd Font is only a fallback
# for the icon font, unrar lives in non-free repositories, and so on).
odin_pkg=""; matugen_pkg=""; services=(NetworkManager bluetooth)
case "$distro" in
    arch)
        required=(
            base-devel git clang curl pam              # build (pam: the lock screen)
            xorg-server xorg-xrandr xorg-setxkbmap xorg-xprop xorg-xinit
            libx11 libxft libxrandr libxfixes libxext fontconfig freetype2 zlib dbus
            feh librsvg imagemagick                    # wallpapers, SVG icons, thumbnails
            xdg-user-dirs xdg-utils libnotify glib2    # folders, links, notify-send, gio
            pipewire pipewire-pulse wireplumber        # volume (wpctl)
            networkmanager bluez bluez-utils           # Wi-Fi and Bluetooth menus
            noto-fonts noto-fonts-cjk noto-fonts-emoji "?ttf-nerd-fonts-symbols"
        )
        spoil_pkgs=(mpv ffmpegthumbnailer ffmpeg libarchive zip unzip "7zip|p7zip" alacritty)
        lactase_pkgs=(libxcomposite libxdamage libxrender mesa libglvnd)
        optional=(alacritty rofi brightnessctl playerctl maim xclip flameshot "?unrar" network-manager-applet
                  adw-gtk-theme qt5ct qt6ct)           # GTK and Qt apps in milk's colours
        odin_pkg=odin; matugen_pkg=matugen ;;
    debian)
        required=(
            build-essential git clang curl ca-certificates libpam0g-dev
            xserver-xorg x11-xserver-utils x11-xkb-utils x11-utils xinit
            libx11-dev libxft-dev libxrandr-dev libxfixes-dev libxext-dev "libfontconfig-dev|libfontconfig1-dev"
            "libfreetype-dev|libfreetype6-dev" zlib1g-dev libdbus-1-dev
            feh librsvg2-bin imagemagick
            xdg-user-dirs xdg-utils libnotify-bin libglib2.0-bin
            pipewire pipewire-pulse wireplumber
            network-manager bluez
            fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji "?fonts-symbols-nerd-font"
        )
        spoil_pkgs=(mpv ffmpegthumbnailer ffmpeg libarchive-tools zip unzip "7zip|p7zip-full" alacritty)
        lactase_pkgs=(libxcomposite-dev libxdamage-dev libxrender-dev libgl-dev libgl1-mesa-dri)
        optional=(alacritty rofi brightnessctl playerctl maim xclip flameshot "?unrar|unrar-free" network-manager-gnome
                  "?qt5ct" "?qt6ct") ;;
    fedora)
        required=(
            gcc git clang curl pam-devel
            xorg-x11-server-Xorg xrandr setxkbmap xprop "xorg-x11-xinit|xinit"
            libX11-devel libXft-devel libXrandr-devel libXfixes-devel libXext-devel fontconfig-devel freetype-devel
            "zlib-ng-compat-devel|zlib-devel" dbus-devel
            feh librsvg2-tools ImageMagick
            xdg-user-dirs xdg-utils libnotify glib2
            pipewire pipewire-pulseaudio wireplumber
            NetworkManager bluez
            google-noto-sans-fonts google-noto-sans-cjk-fonts "google-noto-color-emoji-fonts|google-noto-emoji-color-fonts"
            "?symbols-only-nerd-fonts"
        )
        spoil_pkgs=(mpv ffmpegthumbnailer "ffmpeg-free|ffmpeg" bsdtar zip unzip "7zip|p7zip" alacritty)
        lactase_pkgs=(libXcomposite-devel libXdamage-devel libXrender-devel mesa-libGL-devel mesa-dri-drivers)
        optional=(alacritty rofi brightnessctl playerctl maim xclip flameshot "?unrar" network-manager-applet
                  "?adw-gtk3-theme" qt5ct qt6ct)
        matugen_pkg=matugen ;;
    opensuse)
        required=(
            gcc make git clang curl gawk pam-devel
            xorg-x11-server xrandr setxkbmap xprop xinit
            libX11-devel libXft-devel libXrandr-devel libXfixes-devel libXext-devel fontconfig-devel freetype2-devel
            zlib-devel dbus-1-devel
            feh "rsvg-convert|librsvg2-tools" ImageMagick
            xdg-user-dirs xdg-utils libnotify-tools glib2-tools
            pipewire pipewire-pulseaudio wireplumber
            NetworkManager bluez
            google-noto-sans-fonts "google-noto-sans-cjk-fonts|noto-sans-cjk-fonts" google-noto-coloremoji-fonts
            "?symbols-only-nerd-fonts"
        )
        spoil_pkgs=(mpv ffmpegthumbnailer "ffmpeg-7|ffmpeg" bsdtar zip unzip "7zip|p7zip" alacritty)
        lactase_pkgs=(libXcomposite-devel libXdamage-devel libXrender-devel Mesa-libGL-devel Mesa-dri)
        optional=(alacritty rofi brightnessctl playerctl maim xclip flameshot "?unrar" NetworkManager-applet qt5ct qt6ct) ;;
    void)
        required=(
            base-devel git clang curl pam-devel
            xorg-minimal xrandr setxkbmap xprop xinit
            libX11-devel libXft-devel libXrandr-devel libXfixes-devel libXext-devel fontconfig-devel freetype-devel
            zlib-devel dbus-devel
            feh librsvg-utils ImageMagick
            xdg-user-dirs xdg-utils libnotify glib
            pipewire wireplumber
            NetworkManager bluez dbus elogind
            noto-fonts-ttf noto-fonts-cjk noto-fonts-emoji "?nerd-fonts-symbols-ttf"
        )
        spoil_pkgs=(mpv ffmpegthumbnailer ffmpeg bsdtar zip unzip "7zip|p7zip" alacritty)
        lactase_pkgs=(libXcomposite-devel libXdamage-devel libXrender-devel MesaLib-devel libglvnd-devel mesa-dri)
        optional=(alacritty rofi brightnessctl playerctl maim xclip flameshot "?unrar" network-manager-applet qt5ct qt6ct)
        matugen_pkg=matugen
        services=(dbus elogind NetworkManager bluetooth) ;;
    *)
        required=(); spoil_pkgs=(); lactase_pkgs=(); optional=(); services=() ;;
esac

# Odin from the repositories only when the installed one is missing or too old
# (step 3 downloads the release when the repositories' is too old as well).
have_odin=$(usable_odin || true)
need_odin=0; [ -n "$have_odin" ] || need_odin=1
need_matugen=0
if [ "$want_matugen" -eq 1 ] && ! command -v matugen >/dev/null; then need_matugen=1; fi

packages=("${required[@]}")
[ "$want_spoil" -eq 1 ] && packages+=("${spoil_pkgs[@]}")
[ "$want_lactase" -eq 1 ] && packages+=("${lactase_pkgs[@]}")
[ "$minimal" -eq 0 ] && packages+=("${optional[@]}")
[ "$with_sddm" -eq 1 ] && packages+=(sddm)
[ "$need_odin" -eq 1 ] && [ -n "$odin_pkg" ] && packages+=("?$odin_pkg")
[ "$need_matugen" -eq 1 ] && [ -n "$matugen_pkg" ] && packages+=("?$matugen_pkg")

resolved=(); unavailable=(); missing=()
if [ "$distro" != other ]; then
    pm_prepare
    resolve_packages "${packages[@]}"
    for p in "${unavailable[@]}"; do
        warn "$(t "o pacote $p não está nos seus repositórios; ignorando" "package $p is not in your repositories; skipping it" "el paquete $p no está en tus repositorios; se omite")"
    done
    mapfile -t missing < <(pm_missing "${resolved[@]}")
fi
in_resolved() {
    local p
    for p in "${resolved[@]}"; do [ "$p" = "$1" ] && return 0; done
    return 1
}
odin_download=$need_odin
if [ -n "$odin_pkg" ] && in_resolved "$odin_pkg"; then odin_download=0; fi
matugen_download=$need_matugen
if [ -n "$matugen_pkg" ] && in_resolved "$matugen_pkg"; then matugen_download=0; fi

case "$(uname -m)" in
    x86_64|amd64)  cpu=amd64 ;;
    aarch64|arm64) cpu=arm64 ;;
    *)             cpu="" ;;
esac
no_odin_msg=$(t "Não há Odin pronto para $(uname -m); instale o Odin $ODIN_RELEASE ou mais novo e rode de novo." \
                "There is no prebuilt Odin for $(uname -m); install Odin $ODIN_RELEASE or newer and run this again." \
                "No hay Odin precompilado para $(uname -m); instala Odin $ODIN_RELEASE o más reciente y vuelve a ejecutarlo.")

case "$lang" in pt) milk_locale=pt-BR; lang_name="Português" ;; es) milk_locale=es; lang_name="Español" ;; *) milk_locale=en; lang_name="English" ;; esac
parts="milk"
[ "$want_spoil" -eq 1 ] && parts+=" + Spoil"
[ "$want_lactase" -eq 1 ] && parts+=" + lactase"
[ "$want_matugen" -eq 1 ] && parts+=" + matugen"

printf '\n%s%s%s\n' "$B" "$(t "Plano" "Plan" "Plan")" "$N"
info "$(t "$parts, em $MILK" "$parts, in $MILK" "$parts, en $MILK")"
if [ "$reinstall" -eq 1 ]; then
    where=${installed_at:-$MILK}
    info "$(t "o milk já está instalado ($where) e será reinstalado; suas configurações em $config são mantidas" \
              "milk is already installed ($where) and will be reinstalled; your settings in $config are kept" \
              "milk ya está instalado ($where) y se reinstalará; tu configuración en $config se conserva")"
fi
if [ "$distro" = other ]; then
    info "$(t "dependências: por sua conta —" "dependencies: up to you —" "dependencias: por tu cuenta —")"
    printf '      %s\n' \
        "$(t "clang, git, curl; Xorg com xrandr, setxkbmap, xprop e xinit; os arquivos de desenvolvimento" \
             "clang, git, curl; Xorg with xrandr, setxkbmap, xprop and xinit; the development files" \
             "clang, git, curl; Xorg con xrandr, setxkbmap, xprop y xinit; los archivos de desarrollo")" \
        "$(t "de libX11, libXft, libXrandr, libXfixes, libXext, fontconfig, freetype, zlib e dbus;" \
             "of libX11, libXft, libXrandr, libXfixes, libXext, fontconfig, freetype, zlib and dbus;" \
             "de libX11, libXft, libXrandr, libXfixes, libXext, fontconfig, freetype, zlib y dbus;")" \
        "feh, rsvg-convert, ImageMagick, xdg-user-dirs, xdg-utils, notify-send, gio, PipeWire + wireplumber," \
        "$(t "NetworkManager, BlueZ e as fontes Noto; para o lactase, libXcomposite, libXdamage, libXrender e libGL." \
             "NetworkManager, BlueZ and the Noto fonts; for lactase, libXcomposite, libXdamage, libXrender and libGL." \
             "NetworkManager, BlueZ y las fuentes Noto; para lactase, libXcomposite, libXdamage, libXrender y libGL.")"
elif [ ${#missing[@]} -eq 0 ]; then
    info "$(t "todos os ${#resolved[@]} pacotes já estão instalados" "all ${#resolved[@]} packages are already installed" "los ${#resolved[@]} paquetes ya están instalados")"
elif [ ${#missing[@]} -eq 1 ]; then
    info "$(t "1 pacote para instalar:" "1 package to install:" "1 paquete por instalar:") ${missing[*]}"
else
    info "$(t "${#missing[@]} pacotes para instalar:" "${#missing[@]} packages to install:" "${#missing[@]} paquetes por instalar:") ${missing[*]}"
fi
if [ "$odin_download" -eq 1 ]; then
    [ -n "$cpu" ] || die "$no_odin_msg"
    info "$(t "o compilador Odin $ODIN_RELEASE em $DATA_DIR/odin (a distribuição não tem um recente)" \
              "the Odin compiler $ODIN_RELEASE into $DATA_DIR/odin (the distribution has no recent one)" \
              "el compilador Odin $ODIN_RELEASE en $DATA_DIR/odin (la distribución no tiene uno reciente)")"
fi
if [ "$matugen_download" -eq 1 ]; then
    if [ "$cpu" = amd64 ]; then
        info "$(t "matugen $MATUGEN_VERSION em ~/.local/bin" "matugen $MATUGEN_VERSION into ~/.local/bin" "matugen $MATUGEN_VERSION en ~/.local/bin")"
    else
        warn "$(t "não há matugen pronto para $(uname -m); o tema do papel de parede fica indisponível até você instalá-lo" \
                  "there is no prebuilt matugen for $(uname -m); the wallpaper theme stays unavailable until you install it" \
                  "no hay matugen precompilado para $(uname -m); el tema del fondo no estará disponible hasta que lo instales")"
    fi
fi
[ -f "$NOCTALIA_FONT" ] || info "$(t "fonte de ícones Tabler $TABLER_VERSION em $FONT_DIR" "Tabler icon font $TABLER_VERSION into $FONT_DIR" "fuente de iconos Tabler $TABLER_VERSION en $FONT_DIR")"
info "$(t "comandos em ~/.local/bin, o tema do Alacritty, a sessão \"milk\" na tela de login ($xsessions_dir) e o serviço PAM da tela de bloqueio" \
          "commands in ~/.local/bin, the Alacritty theme, the \"milk\" session on the login screen ($xsessions_dir) and the lock screen's PAM service" \
          "comandos en ~/.local/bin, el tema de Alacritty, la sesión \"milk\" en la pantalla de inicio de sesión ($xsessions_dir) y el servicio PAM de la pantalla de bloqueo")"
[ "$lang_chosen" -eq 1 ] && info "$(t "idioma do milk: $lang_name" "milk's language: $lang_name" "idioma de milk: $lang_name")"
info "$(t "no fim, a configuração inicial (tema, teclado, papéis de parede, barra, janelas) abre" \
          "afterwards the setup wizard (theme, keyboard, wallpapers, bar, windows) opens" \
          "al final se abre el asistente de configuración (tema, teclado, fondos, barra, ventanas)")"
echo
if [ "$dry_run" -eq 1 ]; then
    t "Simulação (--dry-run): nada foi alterado." "Dry run (--dry-run): nothing was changed." "Simulación (--dry-run): no se cambió nada."
    echo
    exit 0
fi
ask "$(t "Continuar?" "Continue?" "¿Continuar?")" y || { t "Nada foi alterado." "Nothing was changed." "No se cambió nada."; echo; exit 0; }

# --- 1. packages ------------------------------------------------------------------------
step "$(t "Instalando pacotes" "Installing packages" "Instalando paquetes")"
if [ "$distro" = other ]; then
    absent=()
    for cmd in clang git curl tar; do command -v "$cmd" >/dev/null || absent+=("$cmd"); done
    [ ${#absent[@]} -eq 0 ] || die "$(t "Faltam comandos: ${absent[*]}. Instale-os e rode o instalador de novo." \
                                         "Missing commands: ${absent[*]}. Install them and run the installer again." \
                                         "Faltan comandos: ${absent[*]}. Instálalos y vuelve a ejecutar el instalador.")"
    info "$(t "por sua conta (só os comandos de compilação foram conferidos)" "up to you (only the build commands were checked)" "por tu cuenta (solo se comprobaron los comandos de compilación)")"
else
    pm_install "${missing[@]}"
    ok "$(t "Dependências prontas" "Dependencies ready" "Dependencias listas")"
fi

# --- 2. services ------------------------------------------------------------------------
step "$(t "Serviços" "Services" "Servicios")"
if [ "$init" = none ] || [ "$distro" = other ]; then
    info "$(t "nenhum sistema de inicialização conhecido (systemd, runit, OpenRC); mantidos como estão" \
              "no known init system (systemd, runit, OpenRC); left as they are" \
              "ningún sistema de inicio conocido (systemd, runit, OpenRC); se quedan como están")"
elif [ "$enable_services" -eq 1 ]; then
    for svc in "${services[@]}"; do
        if ! svc_exists "$svc"; then
            continue
        elif svc_enabled "$svc"; then
            ok "$(t "$svc já estava ativado" "$svc already enabled" "$svc ya estaba activado")"
        elif svc_enable "$svc" 1; then
            ok "$(t "$svc ativado" "$svc enabled" "$svc activado")"
        else
            warn "$(t "não foi possível ativar $svc" "could not enable $svc" "no se pudo activar $svc")"
        fi
    done
else
    info "$(t "mantidos como estão" "left as they are" "se quedan como están")"
fi
if [ "$with_sddm" -eq 1 ] && [ "$init" != none ] && [ "$distro" != other ]; then
    if dm_enabled; then
        ok "$(t "Uma tela de login já está ativada" "A login screen is already enabled" "Ya hay una pantalla de inicio de sesión activada")"
    elif [ "$init" = runit ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        # runit starts a service as soon as it is linked: the login screen would
        # take over the display in the middle of this session.
        info "$(t "para ativar o SDDM (ele inicia na hora), rode fora da sessão gráfica: sudo ln -s /etc/sv/sddm /var/service/" \
                  "to enable SDDM (it starts at once), run outside the graphical session: sudo ln -s /etc/sv/sddm /var/service/" \
                  "para activar SDDM (se inicia al momento), ejecuta fuera de la sesión gráfica: sudo ln -s /etc/sv/sddm /var/service/")"
    elif svc_enable sddm 0; then
        ok "$(t "SDDM ativado (inicia no próximo boot)" "SDDM enabled (starts at the next boot)" "SDDM activado (se inicia en el próximo arranque)")"
    else
        warn "$(t "não foi possível ativar o SDDM" "could not enable SDDM" "no se pudo activar SDDM")"
    fi
fi
xdg-user-dirs-update >/dev/null 2>&1 || true

# --- 3. compiler and tools -----------------------------------------------------------------
step "$(t "Compilador e ferramentas" "Compiler and tools" "Compilador y herramientas")"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
if odin_bin=$(usable_odin); then
    ok "Odin: $odin_bin ($("$odin_bin" version 2>/dev/null | sed 's/^odin version //'))"
else
    [ -n "$cpu" ] || die "$no_odin_msg"
    odin_dest="$DATA_DIR/odin/$ODIN_RELEASE"
    if [ ! -x "$odin_dest/odin" ]; then
        info "$(t "baixando o Odin $ODIN_RELEASE" "downloading Odin $ODIN_RELEASE" "descargando Odin $ODIN_RELEASE")"
        curl -fL --progress-bar "$ODIN_BASE_URL/odin-linux-$cpu-$ODIN_RELEASE.tar.gz" -o "$tmp/odin.tar.gz"
        mkdir -p "$tmp/odin"
        tar xzf "$tmp/odin.tar.gz" -C "$tmp/odin" --strip-components=1
        mkdir -p "$DATA_DIR/odin"
        mv "$tmp/odin" "$odin_dest"
    fi
    ln -sfn "$ODIN_RELEASE" "$DATA_DIR/odin/current"
    mkdir -p "$BIN_DIR"
    if [ -e "$BIN_DIR/odin" ] && ! [ -L "$BIN_DIR/odin" ]; then
        die "$(t "$BIN_DIR/odin é um Odin antigo que o milk não instalou; remova-o ou atualize-o e rode de novo." \
                 "$BIN_DIR/odin is an old Odin that milk did not install; remove or update it and run this again." \
                 "$BIN_DIR/odin es un Odin antiguo que milk no instaló; quítalo o actualízalo y vuelve a ejecutarlo.")"
    fi
    ln -sfn "$DATA_DIR/odin/current/odin" "$BIN_DIR/odin"
    hash -r
    odin_bin=$(usable_odin) || die "$(t "O Odin baixado não funciona aqui." "The downloaded Odin does not run here." "El Odin descargado no funciona aquí.")"
    ok "$(t "Odin $ODIN_RELEASE em $DATA_DIR/odin (comando: odin)" "Odin $ODIN_RELEASE in $DATA_DIR/odin (command: odin)" "Odin $ODIN_RELEASE en $DATA_DIR/odin (comando: odin)")"
fi
if [ "$want_matugen" -eq 0 ]; then
    info "$(t "matugen ignorado" "matugen skipped" "matugen omitido")"
elif command -v matugen >/dev/null; then
    ok "matugen: $(command -v matugen) ($(matugen --version 2>/dev/null | head -n 1 | sed 's/^matugen //'))"
elif [ "$cpu" != amd64 ]; then
    warn "$(t "sem matugen para $(uname -m)" "no matugen for $(uname -m)" "sin matugen para $(uname -m)")"
elif curl -fL --progress-bar "$MATUGEN_URL" -o "$tmp/matugen.tar.gz" && tar xzf "$tmp/matugen.tar.gz" -C "$tmp" matugen; then
    mkdir -p "$DATA_DIR/bin" "$BIN_DIR"
    install -m 755 "$tmp/matugen" "$DATA_DIR/bin/matugen"
    if [ ! -e "$BIN_DIR/matugen" ] || [ -L "$BIN_DIR/matugen" ]; then ln -sfn "$DATA_DIR/bin/matugen" "$BIN_DIR/matugen"; fi
    ok "$(t "matugen $MATUGEN_VERSION (comando: matugen)" "matugen $MATUGEN_VERSION (command: matugen)" "matugen $MATUGEN_VERSION (comando: matugen)")"
else
    warn "$(t "não foi possível baixar o matugen; o tema do papel de parede fica indisponível" \
              "could not download matugen; the wallpaper theme stays unavailable" \
              "no se pudo descargar matugen; el tema del fondo no estará disponible")"
fi

# adw-gtk3: GTK 3 apps take milk's colours in full (and change them live) with it.
themes_dir="${XDG_DATA_HOME:-$HOME/.local/share}/themes"
if [ "$minimal" -eq 1 ]; then
    :
elif [ -d /usr/share/themes/adw-gtk3 ] || [ -d "$themes_dir/adw-gtk3" ]; then
    ok "$(t "tema GTK adw-gtk3 instalado" "GTK theme adw-gtk3 installed" "tema GTK adw-gtk3 instalado")"
elif curl -fsSL "$ADW_GTK3_URL" -o "$tmp/adw-gtk3.tar.xz" && mkdir -p "$tmp/adw" && tar xJf "$tmp/adw-gtk3.tar.xz" -C "$tmp/adw"; then
    mkdir -p "$themes_dir"
    for theme in adw-gtk3 adw-gtk3-dark; do
        [ -d "$tmp/adw/$theme" ] && cp -r "$tmp/adw/$theme" "$themes_dir/"
    done
    ok "$(t "tema GTK adw-gtk3 $ADW_GTK3_VERSION em $themes_dir" "GTK theme adw-gtk3 $ADW_GTK3_VERSION in $themes_dir" "tema GTK adw-gtk3 $ADW_GTK3_VERSION en $themes_dir")"
else
    warn "$(t "não foi possível baixar o adw-gtk3; apps GTK 3 pegam só parte das cores do milk" \
              "could not download adw-gtk3; GTK 3 apps take only part of milk's colours" \
              "no se pudo descargar adw-gtk3; las apps GTK 3 toman solo parte de los colores de milk")"
fi

# --- 4. icon font ---------------------------------------------------------------------------
step "$(t "Fonte de ícones" "Icon font" "Fuente de iconos")"
icon_font="$NOCTALIA_FONT"
if [ -f "$NOCTALIA_FONT" ]; then
    ok "$(t "Usando a fonte de ícones Tabler do Noctalia" "Using Noctalia's Tabler icon font" "Usando la fuente de iconos Tabler de Noctalia")"
else
    icon_font="$FONT_DIR/tabler-icons.ttf"
    if [ -f "$icon_font" ] && [ -f "$FONT_DIR/tabler.json" ]; then
        ok "$(t "Fonte de ícones Tabler já instalada" "Tabler icon font already installed" "La fuente de iconos Tabler ya está instalada")"
    else
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

# --- 5. milk ----------------------------------------------------------------------------------
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

# --- 6. Spoil -----------------------------------------------------------------------------------
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

# --- 7. lactase ---------------------------------------------------------------------------------
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
case ":$user_path:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$(t "~/.local/bin não está no seu PATH; adicione-o para usar os comandos milk, spoil e lactase" \
                 "~/.local/bin is not in your PATH; add it to use the milk, spoil and lactase commands" \
                 "~/.local/bin no está en tu PATH; añádelo para usar los comandos milk, spoil y lactase")" ;;
esac

# --- 8. terminal theme --------------------------------------------------------------------------
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

# --- 9. login screen ------------------------------------------------------------------------------
step "$(t "Tela de login" "Login screen" "Pantalla de inicio de sesión")"
sudo env XSESSIONS_DIR="$xsessions_dir" "$MILK/contrib/install-sddm-session.sh" | sed 's/^/  /'
# A single entry: SDDM would list a copy from each folder.
if [ "$xsessions_dir" != /usr/local/share/xsessions ] && [ -e /usr/local/share/xsessions/milk.desktop ]; then
    sudo rm -f /usr/local/share/xsessions/milk.desktop
fi
# The lock screen checks passwords through PAM service "milk": the system's own
# authentication stack, whichever this distribution has (openSUSE keeps it in /usr/lib/pam.d).
if [ -f /etc/pam.d/milk ]; then
    ok "$(t "Senha da tela de bloqueio: /etc/pam.d/milk" "Lock screen password check: /etc/pam.d/milk" "Contraseña de la pantalla de bloqueo: /etc/pam.d/milk")"
else
    pam_base=""
    for service in system-auth common-auth login; do
        for dir in /etc/pam.d /usr/lib/pam.d /usr/etc/pam.d; do
            if [ -f "$dir/$service" ]; then pam_base=$service; break 2; fi
        done
    done
    if [ -n "$pam_base" ]; then
        printf '#%%PAM-1.0\n# milk lock screen (installed by milk/install.sh)\nauth include %s\n' "$pam_base" | sudo tee /etc/pam.d/milk >/dev/null
        ok "$(t "Senha da tela de bloqueio: /etc/pam.d/milk ($pam_base)" "Lock screen password check: /etc/pam.d/milk ($pam_base)" "Contraseña de la pantalla de bloqueo: /etc/pam.d/milk ($pam_base)")"
    else
        warn "$(t "nenhum serviço PAM conhecido; a tela de bloqueio usa o padrão do sistema" "no known PAM service; the lock screen uses the system default" "ningún servicio PAM conocido; la pantalla de bloqueo usa el predeterminado")"
    fi
fi

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
    if [ "$init" != none ] && ! dm_enabled; then
        t "  Sem tela de login: ponha \"exec /usr/local/bin/milk-session\" no ~/.xinitrc e rode startx." \
          "  Without a login screen: put \"exec /usr/local/bin/milk-session\" in ~/.xinitrc and run startx." \
          "  Sin pantalla de inicio de sesión: pon \"exec /usr/local/bin/milk-session\" en ~/.xinitrc y ejecuta startx."
        echo
    fi
fi
t "  Depois: \"milk settings\" ou a engrenagem da barra; Super+E abre o Spoil." \
  "  Later: \"milk settings\" or the gear on the bar; Super+E opens Spoil." \
  "  Después: \"milk settings\" o el engranaje de la barra; Super+E abre Spoil."
echo
