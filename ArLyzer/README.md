# ArLyzer

PiLyzer's oscilloscope, spectrum analyser, logic analyser and meter on an
Arduino Nano R4, UNO R4 Minima or UNO R4 WiFi. The sketch speaks the same wire
protocol as the Pico 2 ([`Pico2/docs/protocol.md`](../Pico2/docs/protocol.md)),
so [PiLyzer Web](https://satachito.github.io/Oscillo/) and the macOS
application drive it unchanged: the board says what it can do, and the
applications draw from that.

| | Nano R4 | UNO R4 Minima | UNO R4 WiFi |
| --- | --- | --- | --- |
| Analogue | 8 ch, A0–A7 | 8 ch, A0–A5, D4, D5 | 7 ch, A0–A5, D10 |
| Fastest, per channel | 88 kSa/s with 1 input, 47 with 8 | the same | 88 kSa/s with 1 input, 50 with 7 |
| Record | 1,024 points a channel | the same | the same |
| Logic | D2–D9, up to 167 kSa/s, 16,384 points | the same | the same, 14,336 points |
| Connection | USB serial | USB serial | USB serial, and Wi-Fi with [the bridge](bridge/) |

The inputs are 0–5 V: the converter measures against the board's own 5 V
rail, which the firmware reads against the chip's internal reference, so the
readings hold when the USB supply is not quite 5 V. The logic inputs are 5 V
logic — a 3.3 V signal may not read high, so put a level shifter in front of
3.3 V circuits.

## Load it

Open [`arlyzer/`](arlyzer/) in the Arduino IDE with the Arduino UNO R4 Boards
package installed, pick the board and upload. Or with arduino-cli:

```sh
arduino-cli compile --fqbn arduino:renesas_uno:nanor4 arlyzer        # or :minima, :unor4wifi
arduino-cli upload  --fqbn arduino:renesas_uno:nanor4 -p <port> arlyzer
```

The [release](https://github.com/Satachito/Oscillo/releases/latest) carries the
UNO R4 WiFi's build as `ArLyzer-R4WiFi.bin`
(`arduino-cli upload --fqbn arduino:renesas_uno:unor4wifi -p <port> --input-file ArLyzer-R4WiFi.bin`).

## Use it

In PiLyzer Web (Chrome or Edge), press **Serial** and pick the board's port;
in the macOS application, pick it from the instrument list. Plug the USB in
before any signal: a signal on an unpowered board can power it through the
input pin and stop its USB from starting.

The UNO R4 WiFi can also serve PiLyzer Web itself, at `http://arlyzer.local`,
once its ESP32-S3 runs ArLyzer's bridge — see [`bridge/`](bridge/). The
network is then set from the application's Wi-Fi section, over USB.

## In this directory

| | |
| --- | --- |
| [`arlyzer/`](arlyzer/) | the sketch |
| [`bridge/`](bridge/) | the UNO R4 WiFi's ESP32-S3 firmware: Wi-Fi, `arlyzer.local` and the browser application |
| [`host/`](host/) | a simulated ArLyzer behind a pseudo-terminal, to drive the applications without a board |
| [`tests/`](tests/) | host tests for the record, the logic analyser and the network hand-over |
| [`tools/probe.py`](tools/probe.py) | asks a board who it is and reads its inputs, from the command line |
