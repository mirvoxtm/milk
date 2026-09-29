#!/bin/sh
# Add milk to the display manager's session list (SDDM, LightDM, GDM read the
# same xsessions directory). Run with sudo:
#     sudo ./contrib/install-sddm-session.sh            # install
#     sudo ./contrib/install-sddm-session.sh --uninstall
#
# The entry runs /usr/local/bin/milk-session, a small launcher that finds the
# milk folder by itself (the location recorded at the last start, then a
# search of the home folder), so moving or renaming the clone never breaks the
# login again.
set -e
dir=$(dirname "$(readlink -f "$0")")
target_dir=${XSESSIONS_DIR:-/usr/local/share/xsessions}
target="$target_dir/milk.desktop"
launcher=${MILK_SESSION_BIN:-/usr/local/bin/milk-session}
legacy="$target_dir/temenos.desktop"   # entry installed before the rename to milk

if [ "$1" = "--uninstall" ]; then
    rm -f "$target" "$legacy" "$launcher"
    echo "removed $target and $launcher"
    exit 0
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "run this with sudo (it writes to $target_dir and $(dirname "$launcher"))" >&2
    exit 1
fi
chmod 755 "$dir/milk-session" "$dir/../milk" "$dir/../build.sh"

mkdir -p "$(dirname "$launcher")"
cat > "$launcher" <<'LAUNCHER'
#!/bin/sh
# milk login session launcher (installed by milk/contrib/install-sddm-session.sh).
# Finds the milk clone even after it was moved or renamed.
recorded=$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/milk/location" 2>/dev/null)
if [ -n "$recorded" ] && [ -x "$recorded/contrib/milk-session" ]; then
    exec "$recorded/contrib/milk-session" "$@"
fi
for candidate in $(find "$HOME" -maxdepth 5 -path '*/contrib/milk-session' -type f 2>/dev/null); do
    root=$(dirname "$(dirname "$candidate")")
    if [ -f "$root/src/milk/main.odin" ] && [ -x "$candidate" ]; then
        exec "$candidate" "$@"
    fi
done
echo "milk-session: could not find the milk folder under $HOME" >&2
exit 1
LAUNCHER
chmod 755 "$launcher"

mkdir -p "$target_dir"
# No TryExec on purpose: the greeter runs as the sddm user and would hide the
# entry when it cannot look inside a private home directory.
sed "s|@SESSION@|$launcher|g" "$dir/milk.desktop.in" > "$target"
chmod 644 "$target"
rm -f "$legacy"
echo "installed $target"
echo "  Exec=$launcher (finds $(dirname "$dir") even if it is moved)"
echo "Pick \"milk\" in the session menu of the login screen."
