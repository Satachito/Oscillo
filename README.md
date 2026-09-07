# Oscillo

Two independent oscilloscope projects:

| Project | Hardware | Applications |
| --- | --- | --- |
| [Pico2](Pico2/) | Raspberry Pi Pico 2 / PiLyzer AFE | [macOS](Pico2/README.md) · [WebUSB](Pico2/Web/) |
| [PCBScope](PCBScope/) | PCBScope / DPScope SE | Native macOS HID application restored from the original project |

**[Open PiLyzer Web](https://satachito.github.io/Oscillo/)** ·
**[Download macOS releases](https://github.com/Satachito/Oscillo/releases)**

PiLyzer's firmware, KiCad schematics, documentation and native app now live
under `Pico2/`. The Git repository remains at this level. Each native app is
an independent Swift package; run its build commands from its own directory.

```sh
(cd Pico2 && ./Scripts/make-app.sh)
(cd PCBScope && ./Scripts/make-app.sh)
```

PiLyzer Web talks directly to the instrument using WebUSB in Chrome or Edge
on a desktop computer. Demo mode also works without an instrument. Captured
samples remain in the browser; CSV export saves them locally.
