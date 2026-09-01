#!/bin/sh
# Espressif unified Xtensa GCC (wraps xtensa-esp32s2-elf-gcc). Not Python.
set -e
PREFIX="${XT_PREFIX:-$HOME/.local/xtensa-esp-elf}"
GCC="$PREFIX/xtensa-esp-elf/bin/xtensa-esp32s2-elf-gcc"
if [ -x "$GCC" ]; then
    echo "already installed: $GCC"
    "$GCC" --version | head -1
    exit 0
fi
VER="14.2.0_20260121"
URL="https://github.com/espressif/crosstool-NG/releases/download/esp-${VER}/xtensa-esp-elf-${VER}-x86_64-linux-gnu.tar.xz"
mkdir -p "$PREFIX" /tmp/xtensa-dl
cd /tmp/xtensa-dl
curl -L --fail --retry 3 -o xtensa-esp-elf.tar.xz "$URL"
tar -xJf xtensa-esp-elf.tar.xz -C "$PREFIX"
"$GCC" --version | head -1
