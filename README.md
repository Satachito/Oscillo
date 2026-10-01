# Oscillo

Oscilloscope projects: one instrument — oscilloscope, spectrum analyser, logic
analyser and meter — on a Raspberry Pi Pico 2 (PiLyzer) or an Arduino R4
(ArLyzer), and the applications that drive both.

| Project | Hardware | Applications |
| --- | --- | --- |
| [Pico2](Pico2/) | Raspberry Pi Pico 2, bare or behind a front end — the [PiLyzer AFE](Pico2/hardware/pilyzer-afe/), a one-op-amp [mini AFE](Pico2/hardware/mini-afe/), or a picoLABO [PL2407AFE](Pico2/hardware/pl2407afe/) | [macOS](Pico2/README.md) · [WebUSB](Pico2/Web/) |
| [ArLyzer](ArLyzer/) | Arduino Nano R4, UNO R4 Minima or UNO R4 WiFi — the same protocol as the Pico 2, up to eight analogue inputs and logic on D2–D9; the UNO R4 WiFi also over Wi-Fi | the same [macOS](Pico2/README.md) · [Web](Pico2/Web/) applications |
| [PCBScope](PCBScope/) | PCBScope / DPScope SE | Native macOS HID application restored from the original project |

**[Open PiLyzer Web](https://satachito.github.io/Oscillo/)** ·
**[Download macOS releases](https://github.com/Satachito/Oscillo/releases)**

PiLyzer's firmware, KiCad schematics, documentation and native app now live
under `Pico2/`; ArLyzer's sketch and the UNO R4 WiFi's Wi-Fi bridge under
`ArLyzer/`. The Git repository remains at this level. Each native app is
an independent Swift package; run its build commands from its own directory.

```sh
(cd Pico2 && ./Scripts/make-app.sh)
(cd PCBScope && ./Scripts/make-app.sh)
```

PiLyzer Web talks directly to the instrument in Chrome or Edge on a desktop
computer — macOS, Windows and Linux alike, with nothing to install on any of
them: WebUSB for a Pico 2 (firmware 1.6 and later), Web Serial for an ArLyzer.
A Pico 2 W or an UNO R4 WiFi serves it itself over Wi-Fi, at
`http://pilyzer.local` or `http://arlyzer.local`, so a phone or a tablet needs
no USB at all. Demo mode also works without an instrument.
Captured samples remain in the browser; CSV export saves them locally.
