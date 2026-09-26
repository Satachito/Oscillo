# ArLyzer over Wi-Fi on an UNO R4 WiFi

The UNO R4 WiFi's USB port and its radio both belong to an ESP32-S3, which
runs Arduino's bridge firmware: a USB-to-UART bridge to the RA4M1, the
programmer that uploads sketches, and an AT-command server that the WiFiS3
library drives over a second UART. This directory builds that same firmware
with the AT server swapped for ArLyzer's own network side
(`arlyzer_net.cpp`), the way a Pico 2 W serves PiLyzer:

- it joins your network and answers to **`http://arlyzer.local`** over mDNS;
- it hands out the browser application from its own flash, gzipped;
- it passes each `POST /rpc` to the RA4M1 over the second UART, at 230400
  baud, and sends the reply back — the same frames the USB port carries, so
  the browser application connects to it exactly as it does to a Pico 2 W.

Everything else in the bridge is Arduino's and stays as it was: the USB serial
port, sketch uploads from the Arduino tools, the CMSIS-DAP interface, and the
HID request that restarts the ESP32-S3 into download mode (which is how
`flash.sh` writes it, and how Arduino's updater puts its own firmware back).

The RA4M1 runs the ordinary ArLyzer sketch (`../arlyzer`), which on a WiFi
answers on its USB port and on that second UART at once. With Arduino's
firmware on the ESP32-S3 nothing arrives on the second UART, and the sketch
works over USB alone.

## Build

```sh
ARLYZER_WIFI_SSID='your network' ARLYZER_WIFI_PASSWORD='its password' ./build.sh
```

The radio is 2.4 GHz only. `ARLYZER_HOSTNAME` changes the name from `arlyzer`.
The first run fetches Arduino's bridge at the commit `build.sh` names, its
submodules and its ESP32 toolchain into `build/` — about 1 GB — and later runs
reuse them. The network goes into `build/.../arlyzer_config.h`, never into the
repository. The browser application is built from `../../Pico2/Web` and baked
in with the Pico's own `bake-web.py`; `http_request.c`, which reads the
requests, is the Pico's too, with its host tests.

## Flash

```sh
./flash.sh
```

No jumper: it asks the bridge to restart into the ROM's download mode and
writes with the esptool that came with the toolchain. The board comes back in
download mode afterwards — the request is remembered across esptool's reset —
so **unplug its USB and plug it back in** to start the new firmware (signal
wires off the board first, as always). **The first time, it
reads the whole 4 MB flash back into `build/esp32-original.bin` before writing
anything**, so Arduino's firmware can be put back byte for byte:

```sh
esptool --chip esp32s3 --port /dev/cu.usbmodemXXXX write_flash 0 build/esp32-original.bin
```

Arduino's updater
([unor4wifi-updater](https://github.com/arduino/uno-r4-wifi-usb-bridge/tree/main/unor4wifi-updater))
restores its current release just as well.

## What to expect

A record comes across at the UART's 22 kB/s: about 0.1 s for one input's 1024
samples, 0.65 s for all seven. The page itself comes from the ESP32-S3 at the
radio's own speed.
