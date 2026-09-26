#!/bin/bash
# Writes what build.sh built to an UNO R4 WiFi's ESP32-S3, over USB, with no
# jumper. The first time, the whole 4 MB flash is read back into
# build/esp32-original.bin before anything is written, so Arduino's own
# firmware can be put back exactly (see README.md).
#
#   ./flash.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$here/build
out=$work/out
esptool=$work/uno-r4-wifi-usb-bridge/hardware/esp32-patched/esp32/tools/esptool/esptool
[ -f "$out/UNOR4USBBridge.ino.bin" ] || { echo "Run ./build.sh first." >&2; exit 1; }

xcrun clang -framework IOKit -framework CoreFoundation "$here/esp-download-mode.c" -o "$work/esp-download-mode"

# The ROM's own USB serial port (Espressif's 303a:1001), which is what appears
# once the bridge has let go of the board.
rom_port() {
  python3 -c "from serial.tools import list_ports; print(next((p.device for p in list_ports.comports() if p.vid == 0x303a), ''))"
}

port=$(rom_port)
if [ -z "$port" ]; then
  "$work/esp-download-mode"
  for _ in $(seq 1 20); do
    sleep 0.5
    port=$(rom_port)
    [ -n "$port" ] && break
  done
fi
[ -n "$port" ] || { echo "The ESP32-S3 did not come up in download mode." >&2; exit 1; }
echo "ESP32-S3 download mode on $port"

run() { "$esptool" --chip esp32s3 --port "$port" --baud 921600 --before no_reset "$@"; }
if [ ! -f "$work/esp32-original.bin" ]; then
  run --after no_reset read_flash 0 0x400000 "$work/esp32-original.bin.part"
  mv "$work/esp32-original.bin.part" "$work/esp32-original.bin"
fi
# The partitions are the stock ones (unor4wifi.csv): otadata at 0x9000 is
# rewritten to start app0, and the certificates, SPIFFS and NVS are left alone.
run --after hard_reset write_flash -z --flash_mode dio --flash_freq 80m --flash_size 4MB \
  0x0 "$out/UNOR4USBBridge.ino.bootloader.bin" \
  0x8000 "$out/UNOR4USBBridge.ino.partitions.bin" \
  0x9000 "$out/boot_app0.bin" \
  0x50000 "$out/UNOR4USBBridge.ino.bin"
# The restart into download mode is remembered across the reset esptool
# gives, so the board comes back in download mode; a power cycle clears it.
echo "Done. Unplug the board's USB and plug it back in to start the new firmware."
