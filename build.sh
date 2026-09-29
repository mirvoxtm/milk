#!/bin/sh
# Build the milk binary (requires the Odin compiler, libX11, libXrandr, libXft, fontconfig).
set -e
dir=$(dirname "$(readlink -f "$0")")
mkdir -p "$dir/bin"
odin build "$dir/src/milk" -out:"$dir/bin/milk" -o:speed -vet ${MILK_ODIN_FLAGS:-}
echo "built $dir/bin/milk"
