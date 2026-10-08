#!/bin/sh
# Build the milk binary (requires the Odin compiler, libX11, libXrandr, libXft, fontconfig).
set -e
dir=$(dirname "$(readlink -f "$0")")
mkdir -p "$dir/bin"
# Built aside and renamed into place: a program started meanwhile (a build may
# run in the background) finds either the old binary or the new one, whole.
tmp="$dir/bin/milk.build.$$"
trap 'rm -f "$tmp"' EXIT
odin build "$dir/src/milk" -out:"$tmp" -o:speed -vet ${MILK_ODIN_FLAGS:-}
mv -f "$tmp" "$dir/bin/milk"
echo "built $dir/bin/milk"
