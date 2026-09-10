#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
: "${PICO_SDK_PATH:=$HOME/pico-sdk}"
: "${PICO_TOOLCHAIN_PATH:=$HOME/arm-none-eabi}"
export PICO_SDK_PATH
cmake -S ../../Pico2/firmware/pilyzer -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DPILYZER_BOARD_ID=3 \
  -DPICO_TOOLCHAIN_PATH="$PICO_TOOLCHAIN_PATH"
cmake --build build
cp build/pilyzer.uf2 build/PiLyzer-PL2407AFE-Pico2.uf2
