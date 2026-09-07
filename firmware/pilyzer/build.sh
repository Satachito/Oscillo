#!/bin/bash
# Builds the PiLyzer firmware.
#
# The Pico SDK and the Arm toolchain live outside this repository. Set
# PICO_SDK_PATH and PICO_TOOLCHAIN_PATH if yours are somewhere other than the
# defaults below.
#
# Homebrew's arm-none-eabi-gcc ships without newlib, so a link that fails with
# "cannot find -lc" means the toolchain path is pointing at that one. Use the
# toolchain from developer.arm.com instead.
set -euo pipefail

cd "$(dirname "$0")"

: "${PICO_SDK_PATH:=$HOME/pico-sdk}"
: "${PICO_TOOLCHAIN_PATH:=$HOME/arm-none-eabi}"
: "${BOARD_ID:=0}"          # 0 = bare Pico 2, 1 = PiLyzer analogue front end
export PICO_SDK_PATH

if [ ! -f "$PICO_SDK_PATH/pico_sdk_init.cmake" ]; then
    echo "No Pico SDK at $PICO_SDK_PATH." >&2
    echo "  git clone --recurse-submodules https://github.com/raspberrypi/pico-sdk $PICO_SDK_PATH" >&2
    exit 1
fi

echo "==> SDK       $PICO_SDK_PATH"
echo "==> toolchain $PICO_TOOLCHAIN_PATH"
echo "==> board id  $BOARD_ID"

cmake -S . -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DPICO_TOOLCHAIN_PATH="$PICO_TOOLCHAIN_PATH" \
    -DPILYZER_BOARD_ID="$BOARD_ID" >/dev/null

cmake --build build

echo
echo "==> build/pilyzer.uf2 — copy it onto the Pico 2 in BOOTSEL"
"$PICO_TOOLCHAIN_PATH/bin/arm-none-eabi-size" build/pilyzer.elf
