#!/bin/bash
# Builds ArLyzer's firmware for the UNO R4 WiFi's ESP32-S3: Arduino's own USB
# bridge (arduino/uno-r4-wifi-usb-bridge, at the commit below) with its AT
# server replaced by arlyzer_net.cpp. See README.md.
#
#   ARLYZER_WIFI_SSID='your network' ARLYZER_WIFI_PASSWORD='its password' ./build.sh
#
# ARLYZER_HOSTNAME (default arlyzer) is the name it answers to over mDNS.
# ARDUINO_CLI names the arduino-cli to use (default: the one on PATH).
# The first run fetches the bridge, its submodules and its toolchain into
# build/ — about 1 GB — and later runs reuse them.
set -euo pipefail

: "${ARLYZER_WIFI_SSID:?set ARLYZER_WIFI_SSID to the 2.4 GHz network the board joins}"
: "${ARLYZER_WIFI_PASSWORD:?set ARLYZER_WIFI_PASSWORD}"
hostname=${ARLYZER_HOSTNAME:-arlyzer}
cli=${ARDUINO_CLI:-arduino-cli}

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=$here/build
upstream=$work/uno-r4-wifi-usb-bridge
commit=94d5bb2e8c2cb5492345bfb84d787fde65d1c183  # its 0.6.0
sketch=$upstream/UNOR4USBBridge

if [ ! -d "$upstream/.git" ]; then
  mkdir -p "$work"
  git clone https://github.com/arduino/uno-r4-wifi-usb-bridge.git "$upstream"
  git -C "$upstream" checkout -q "$commit"
  git -C "$upstream" submodule update --init --depth 1 --no-single-branch
  (cd "$upstream/hardware/esp32-patched/esp32/tools" && python3 get.py)
fi

# The sketch as Arduino has it, then ours on top.
git -C "$upstream" checkout -q "$commit"
git -C "$upstream" checkout -q -- UNOR4USBBridge
git -C "$upstream" clean -q -f -- UNOR4USBBridge
git -C "$upstream" apply "$here/bridge.patch"
cp "$here/arlyzer_net.h" "$here/arlyzer_net.cpp" "$sketch/"
cp "$repo/Pico2/firmware/pilyzer/http_request.h" "$repo/Pico2/firmware/pilyzer/http_request.c" "$sketch/"

(cd "$repo/Pico2/Web" && npm run build >/dev/null)
python3 "$repo/Pico2/firmware/pilyzer/bake-web.py" "$repo/Pico2/Web/dist" "$sketch/web_files.h"

# The network goes into the build, never into the repository.
python3 - "$sketch/arlyzer_config.h" "$ARLYZER_WIFI_SSID" "$ARLYZER_WIFI_PASSWORD" "$hostname" <<'EOF'
import sys
def c(text):  # a C string literal, octal escapes so no hex escape runs on
    return '"' + ''.join(chr(b) if 32 <= b < 127 and chr(b) not in '"\\?' else f'\\{b:03o}'
                         for b in text.encode()) + '"'
path, ssid, password, hostname = sys.argv[1:]
open(path, 'w').write('// Written by build.sh. Not in the repository.\n#pragma once\n'
                      f'#define ARLYZER_WIFI_SSID {c(ssid)}\n'
                      f'#define ARLYZER_WIFI_PASSWORD {c(password)}\n'
                      f'#define ARLYZER_HOSTNAME {c(hostname)}\n')
EOF

sed "s#PWD#$upstream#g" "$upstream/arduino-cli.yaml.orig" > "$upstream/arduino-cli.yaml"
fqbn=esp32-patched:esp32:arduino_unor4wifi_usb_bridge:JTAGAdapter=default,PSRAM=disabled,FlashMode=qio,FlashSize=4M,LoopCore=1,EventsCore=1,USBMode=default,CDCOnBoot=default,MSCOnBoot=default,DFUOnBoot=default,UploadMode=default,PartitionScheme=unor4wifi,CPUFreq=240,UploadSpeed=921600,DebugLevel=none,EraseFlash=none
"$cli" compile --config-file "$upstream/arduino-cli.yaml" --fqbn "$fqbn" --output-dir "$work/out" "$sketch"
cp "$upstream/boot/boot_app0.bin" "$work/out/"
echo "Built $work/out — flash it with ./flash.sh"
