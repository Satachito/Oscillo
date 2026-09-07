# PiLyzer Web

**[Open the app](https://satachito.github.io/Oscillo/)**

A static browser application for the Pico 2 PiLyzer instrument. USB packets use
exactly the same [protocol](../docs/protocol.md) as the macOS application. No
server, account, telemetry, external font or runtime dependency is involved.
Samples stay in browser memory until exported locally as CSV.

## Connecting

1. Use desktop Chrome or Edge over HTTPS (or localhost when developing).
2. Plug in a Pico 2 running PiLyzer firmware. Disconnect the native app and
   other tabs first: only one application can claim the USB interface.
3. Click **Connect USB** and select **PiLyzer Pico 2** in the browser chooser.
4. Set input range and trigger, then press **Run** or **Single**.

Safari and Firefox can use Demo but do not currently provide WebUSB. A Pico in
BOOTSEL does not appear in the PiLyzer chooser; install the firmware first.
On Windows, the vendor interface needs a WinUSB-compatible driver association.

## Features

- Scope: 1–3 channels according to device capabilities, voltage/probe scales,
  vertical position, mean removal, X/Y, peak-to-peak/RMS/mean/frequency readouts.
- Channel checkboxes change the ADC acquisition mask and the rate ceiling.
  Firmware 1.5 advertises a 97-cycle minimum: approximately 494.8 / 247.4 /
  164.9 kSa/s per channel with 1 / 2 / 3 enabled. The UI always uses the device's
  advertised timing and actual returned acquisition plan.
- Auto, Normal and Free run; rising/falling edges, pretrigger position,
  hysteresis, trigger-only LPF when supported by firmware.
- Spectrum: Hann-window FFT, RMS amplitude in dBV, peak and bin resolution.
- Logic: D0–D7, rate/record selection, hardware edge trigger, UART 8N1 decode.
- Meter: all ADC inputs and up to 1,000 readings of rolling history.
- Adjustable calibration square wave and per-channel Set zero / Reset.
  Ground the selected input and capture it before using Set zero. Calibration
  is session-local; changing devices starts a new calibration session.
- Local CSV export for scope, spectrum, logic and meter records.
- Independent 3-channel demo; no instrument required.

Demo waveforms are generated in the browser and are not measurements. The
native application's software spectrum averaging and SPI/I²C decoders are not
included in this web version. All meter inputs are read regardless of scope
checkboxes. The Pico ADC multiplexes channels rather than sampling simultaneously.

## Development and checks

Requires Node.js 22 or later. There are no npm dependencies.

```sh
npm ci
npm test
npm run dev    # http://localhost:4173
npm run build  # self-contained output in dist/
```

Protocol tests cover sparse channel masks, trigger slots, timing limits,
voltage conversion, bulk stream fragmentation/ZLP, transaction ordering,
malformed replies, FFT amplitude, UART decoding and acquisition cancellation.

GitHub Actions builds and deploys `dist/` using the repository's Pages workflow.
All asset paths are relative, so the same build works at `/Oscillo/` or locally.
