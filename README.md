# PiLyzer

A three-channel oscilloscope, spectrum analyser and eight-channel logic analyser
built on a Raspberry Pi Pico 2, with a native macOS application to drive it.

The RP2350 appears as a vendor-specific USB device, so the application claims it
directly through IOKit: no driver, no kext, no permission dialog, no Python.

## What it is

| | |
| --- | --- |
| Analogue | 3 channels, 12 bits, 40 kHz; 495 / 247 / 165 kSa/s per channel with 1 / 2 / 3 enabled |
| Vertical | ±25 V and ±5 V, switched from the application |
| Record | up to 16 384 points a channel, with pre-trigger |
| Spectrum | windowed FFT with averaging, THD, THD+N, SNR, SINAD and ENOB |
| Logic | 8 channels, up to 150 MSa/s, 65 536 points, UART / SPI / I²C decoding |
| Trigger | edge, with hysteresis, on either analogue channel or any logic input |

There is a built-in signal generator, so the whole application works with
nothing plugged in:

```bash
swift run PiLyzer --demo
```

`--mode scope|spectrum|logic|meter` opens on one of the four screens, and
`--autostart` connects to the remembered instrument and starts sweeping.

Three flags answer without opening a window, which is what to reach for when an
instrument does not appear in the list:

```bash
swift run PiLyzer --list       # what is on the USB bus, and why it is not an instrument
swift run PiLyzer --selftest   # walk the whole command set against a real board
swift run PiLyzer --timing     # measure the time axis against the calibration output
swift run PiLyzer --testout 1000   # drive that output, or "off"
swift run PiLyzer --bootsel    # restart it in its bootloader to load new firmware
```

## Requirements

* macOS 13 or later
* Xcode 16 or later (Swift 6 toolchain) to build the application
* A Raspberry Pi Pico 2 running the firmware in `firmware/pilyzer`
* Optionally the analogue front end in `hardware/pilyzer-afe`, which is what
  makes anything outside 0–3.3 V safe to measure

## Building and running

```bash
./Scripts/make-app.sh
```

puts a double-clickable, ad-hoc signed `build/PiLyzer.app` together. To run from
the package instead, `swift run PiLyzer`. Tests:

```bash
swift test
```

The whole acquisition path is exercised against the built-in generator, so the
test suite needs no hardware.

The firmware has its own build; see [firmware/pilyzer/README.md](firmware/pilyzer/README.md).

## Using it

1. Pick the instrument (or **Demo signal**) in the toolbar and press
   **Connect** (⌘K). The list follows the hardware as it is plugged and
   unplugged. The application checks the firmware's identity, so nothing else
   on the bus can be mistaken for an instrument.
2. Press **Run** (⌘R) for continuous sweeps, or **Single** (⇧⌘S) for one.
3. **Export** (⌘E) writes what is on screen to CSV — samples, spectrum, logic
   transitions or decoded protocol, whichever screen is showing.

| Screen | |
| --- | --- |
| **Scope** | voltage against time, or X/Y; Vpp, mean, RMS, AC RMS, frequency, duty, rise time |
| **Spectrum** | windowed FFT with peak markers, and the distortion figures |
| **Logic** | eight traces, per-channel rate and duty, protocol decoding |
| **Meter** | all inputs as numbers, with a rolling chart |

### The instrument tells the application what it can do

Nothing about the hardware is compiled into the application. On connecting it
asks the instrument for its capabilities — how many channels, how fast, how
deep, which ranges — and builds the sweep speeds, record lengths and range
menus from the answer. When a sweep is set up, the instrument replies with the
sample interval it will *actually* use, and that is what the time axis is
labelled with.

This is the reason the time axis can be trusted: it is a hardware register
divided down, not a number the application hoped for.

### Fast sweeps show fewer points, not invented ones

The converter runs at 165 kSa/s a channel with all three on. A sweep faster than the record length
can be filled at that rate keeps the converter flat out and **shortens the
record** instead of interpolating: at 50 µs/div you get 125 real samples across
the screen rather than 2 000 imaginary ones. The panel always shows the rate and
the point count it settled on.

The other direction is handled by averaging rather than skipping. Every sample
on a slow sweep is the mean of all the conversions underneath it, which is both
the anti-alias filter and where the extra bits below the converter's twelve come
from.

### Triggering a noisy or stepped waveform

**Trigger LPF** in the Scope panel filters only the signal used to find the
trigger. The displayed/exported waveform keeps its original steps and noise.
It defaults to Off. An on/off switch retains the last cutoff, and a logarithmic
slider covers 100 Hz to 100 kHz. The **1 kHz** shortcut enables that cutoff.
For a roughly 194 Hz waveform, 1 kHz is a starting point;
compare Off, 500 Hz, 1 kHz and 2 kHz against the actual signal. Keep the level
near the middle of the waveform, and use Normal mode to distinguish a real
trigger from an automatic sweep.

This setting requires firmware 1.2 or later. The trigger marker follows the
filtered crossing, so the raw trace can cross the level earlier. The filter
uses the actual sample interval, and is reset and allowed to settle at each arm.

### Calibration

Every reading is a straight line from a converter code to a voltage, and the
resistors that set it are ordinary 1% parts. Two points fix them:

1. **Zero.** Ground all inputs, then **Calibrate Zero** (⌘-menu, or the button
   on the channel). Whatever is read becomes zero for the range that channel is
   on.
2. **Gain.** Apply a known voltage and tell the application what it is.

Calibration is stored per channel *and per range*, because the two ranges go
through different amplifier gains.

The front end's frequency compensation is a physical adjustment, not a software
one: the firmware puts a square wave on GPIO20 (firmware 1.5+) for it, and
[the front end's documentation](hardware/pilyzer-afe/README.md) explains what to
turn.

## How it is put together

| Target | |
| --- | --- |
| `Sources/CPiLyzerUSB` | IOKit's USB interfaces, wrapped so Swift sees a handle |
| `Sources/PiLyzerCore` | protocol, transport, instrument, engine, FFT, decoders |
| `Sources/PiLyzerApp` | SwiftUI front panel and the four screens |
| `firmware/pilyzer` | RP2350 firmware |
| `hardware/pilyzer-afe` | analogue front end: KiCad schematic, footprints, values, BOM |
| `docs/protocol.md` | the contract between the firmware and the application |

`PiLyzerCore` has no interface dependencies. The real instrument and the demo
generator both implement `Instrument`, so every path from the front panel down
to the samples is covered by the tests.

Device traffic runs on one background queue, and no acquisition ever blocks the
interface.

Run one program against an instrument at a time. The application asks for
exclusive access and refuses to take it away from another process, because two
clients on one bulk endpoint would read each other's answers.

## Limits worth knowing before you trust a reading

* **Bandwidth is 40 kHz**, set by a two-pole Sallen-Key on each channel rather
  than by the converter. The corner is sized for the three-channel case, where
  Nyquist is 82 kHz, so one- and two-channel modes are limited by the filter
  and not by the sample rate. Two poles reduce what folds back; they do not
  abolish it. This is an audio and low-frequency instrument.
* **The fastest sweep is 20 µs/div with one channel, 50 µs/div with two or
  three**, where a division holds five samples. There is no equivalent-time
  sampling yet.
* **Nothing is isolated.** Everything shares the Mac's USB ground. Not for mains
  primary circuits, and not for anything floating at a dangerous potential.
* **The logic inputs are 3.3 V only.** There is no buffer and no level shifter.
* **The analogue and logic sides trigger independently**, so their records
  cannot be lined up against each other.
* A channel that reaches the ends of the converter is marked **CLIP**: the trace
  is a flattened copy of the real signal and no calibration recovers it.

## Where this came from

This started as a rewrite of a macOS application for the DPScope SE, a PIC-based
USB HID instrument. When the hardware became a Pico 2 the old command set came
along with it for a while, and it fitted badly: registers of a microcontroller
that was no longer there, an eight-bit record, 211 samples, and an equivalent
time mode that existed only because the PIC could not sample faster than 30 µs.

None of it survives. The protocol, the firmware, the front end and the
application were designed again around what an RP2350 is actually good at:
hardware-paced conversion into DMA, a processor fast enough to find triggers in
the data, PIO fast enough to watch a pin at 150 MHz, and a USB link fast enough
that records do not have to be small.

## License

MIT. See [LICENSE](LICENSE).

Firmware 1.5 adds CH3 on GPIO28 and moves the test output to GPIO20 (TP6).
Logic stays on GPIO8–15; range controls are GPIO16/17/18. The application uses
the channel count reported by the device, so older two-channel firmware remains
usable. Channel Enabled checkboxes control acquisition as well as display:
1 / 2 / 3 enabled channels allow up to 495 / 247 / 165 kSa/s per channel.
Slower timebases still use averaging/decimation; the actual rate and the current
channel-count limit appear in the Horizontal section.
