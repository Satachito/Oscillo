# PiLyzer firmware

Turns a Raspberry Pi Pico 2 into the instrument the macOS application in this
repository talks to: two analogue channels, eight logic channels, and a bulk USB
endpoint carrying the protocol in `docs/protocol.md`.

## What runs where

| File | |
| --- | --- |
| `main.c` | reassembles request frames, streams answers back; never blocks |
| `analog.c` | converter → DMA → decimation → trigger search |
| `logic.c` | PIO capture, PIO trigger watch, exact edge search |
| `logic_capture.pio` | the two state machine programs |
| `trigger_filter.h` | optional trigger-only LPF, with fractional-code state |
| `usb_descriptors.c` | one vendor-specific interface, so macOS loads no driver |
| `pilyzer_protocol.h` | the wire structures, shared with the host by hand |

## The two ideas worth knowing

**Nothing is paced by software.** The converter free-runs at its own clock into
a hardware ring the DMA wraps by itself, and the processor's only job is to
decimate out of it. Sample intervals are therefore exact — they are a register,
not a `sleep_us` — and the host is told the register rather than a rounded
number, so the time axis on screen is right by construction.

**Decimation is an average, not a skip.** Every slow sample is the mean of all
the conversions underneath it. That is the anti-alias filter for slow sweeps, it
hands back the bits the averaging earns, and it means one code path covers
250 kSa/s and 4 Sa/s.

The logic side inverts the usual arrangement: a second state machine watches the
trigger pin at full clock speed, and the *processor* finds the exact edge
afterwards by looking through the captured bytes. So the trigger lands on a
sample even though nothing running on the processor could have seen it live.

## Memory

| | |
| --- | --- |
| Analogue record | 65 536 conversions, 128 KB |
| Converter ring | 4 096 conversions, 8 KB, wrapped by the DMA |
| Logic record | 131 072 samples, 128 KB |
| Code | about 32 KB |

Change these in `board_config.h`; the host reads the limits out of
`OP_CAPABILITIES` and follows.

## Pins

| Signal | GPIO |
| --- | --- |
| CH1 | 26 (ADC0) |
| CH2 | 27 (ADC1) |
| Logic D0…D7 | 8…15, consecutive because PIO reads them in one instruction |
| CH1 range switch | 16 |
| CH2 range switch | 17 |
| Adjustable calibration square wave | 28 |
| C4 / E♭4 / F♯4 / A4 pairs | 0/1, 2/3, 4/5, 6/7 (even normal, odd inverted) |
| Status LED | the board's own |

On a bare Pico 2 with nothing else attached, CH1 and CH2 read 0 V to 3.3 V
directly and **must not go outside that**. The front end in
`hardware/pilyzer-afe` is what makes ±25 V safe.

### Fixed chord outputs (firmware 1.3)

`chord_output.c` starts four PWM slices at boot. The requested frequencies are
261.626, 311.127, 369.994 and 440.000 Hz. Integer clock dividers and even counter
periods give 50% duty without fractional-divider modulation. Channel B is the
hardware inverse of channel A, so each pair has complementary levels with no
software timing loop. At the nominal 150 MHz system clock, divider/period
rounding yields 261.626690, 311.131023, 369.993981 and 440.001408 Hz; oscillator
accuracy still applies.

GPIO0–7 notes run continuously. The existing `setCalibrationOutput` command
and application `Test output` control affect **only GPIO28**. GPIO28 uses
slice 6, independent of chord slices 0–3. Stop/Single control acquisition only.
UART stdio remains disabled so it cannot take GPIO0/1 away from the notes.

The AFE's J8 connector maps pins 1/2→GPIO0/1, 3/6→GPIO2/3,
4/5→GPIO4/5, 7/8→GPIO6/7; **J8 pin 9 is GND**. These are not Pico physical
pin numbers. Firmware 1.2 used logic GPIO6–13, range GPIO14/15 and calibration
GPIO2: update wiring before installing firmware 1.3.

## Building

Needs the Pico SDK 2.x and an `arm-none-eabi` toolchain that includes newlib —
the Homebrew `arm-none-eabi-gcc` on its own does not, so point
`PICO_TOOLCHAIN_PATH` at the Arm-supplied toolchain if the link fails with
`cannot find -lc`.

```bash
./build.sh
```

which expects the SDK at `~/pico-sdk` and the toolchain at `~/arm-none-eabi`.
Override either with `PICO_SDK_PATH` or `PICO_TOOLCHAIN_PATH`:

```bash
PICO_SDK_PATH=/somewhere/else/pico-sdk ./build.sh
```

If you do not have the SDK yet:

```bash
git clone --recurse-submodules https://github.com/raspberrypi/pico-sdk ~/pico-sdk
```

Flash `build/pilyzer.uf2` with the board in BOOTSEL. After that the application
can put it back into BOOTSEL itself — the `rebootToBootloader` command — so the
button is only needed once.

Building for a board with the analogue front end fitted:

```bash
BOARD_ID=1 ./build.sh
```

Pass it as a CMake cache entry (`-DPILYZER_BOARD_ID=1`) if you are calling
CMake yourself. Do **not** set it through `CMAKE_C_FLAGS`: that replaces the
flags the SDK's own toolchain file puts there, and the SDK stops compiling.

The board id is what tells the application which input ranges exist, so a bare
Pico 2 offers one range of 0–3.3 V and a rev A board offers ±25 V and ±5 V.

## Bringing a board up

The acquisition boundary regressions also run on the host, without the Pico
SDK or an attached board:

```bash
./firmware/pilyzer/tests/run.sh  # from the repository root; requires Clang
```

These compile the production `analog.c` and `logic.c` against small substitutes
for the hardware calls. AddressSanitizer and UndefinedBehaviorSanitizer check
full buffers, late trigger edges, and safe re-arming. They do not validate DMA
or PIO timing on a physical board.

Firmware 1.2 adds **Trigger LPF** (Off or a cutoff in Hz). It filters the
comparator input while leaving the acquired samples intact. Tests also cover
filter settling, buffer rollover, preserved raw waveforms and a 194 Hz,
30-step signal with high-frequency ripple. The LPF requires the matching host
application; old hosts keep it off via the zero reserved field.

```bash
swift run PiLyzer --list       # is it on the bus, and is it an instrument?
swift run PiLyzer --selftest   # walk the whole command set and report
swift run PiLyzer --bootsel    # restart in the bootloader, ready for new firmware
```

`--selftest` is the thing to run on a new board. It reads the identity and the
capabilities, takes an immediate sample, captures an analogue record, arms a
real trigger and checks that the edge is at the index the instrument reported,
and captures a logic record. Anything wrong below the front panel shows up
there rather than as a strange trace.

After the first flash the button is never needed again: `--bootsel` puts the
board back into its bootloader over USB, so the cycle is

```bash
./firmware/pilyzer/build.sh && swift run PiLyzer --bootsel && sleep 2 && \
  picotool load -x firmware/pilyzer/build/pilyzer.uf2
```

**Checking the time axis.** Nothing above proves the sample interval is right —
the samples alone cannot say how far apart they are. Put a jumper from GPIO28
(the test square wave) to GPIO26 (CH1) and the scope should read a 1 kHz square
wave with a 50% duty cycle. If the frequency reads correctly across several
sweep speeds, the whole timing chain is right; if it is wrong by a constant
factor, the divisor arithmetic in `analog.c` is where to look.

## Identity

VID:PID is **1209:0001** — pid.codes' identifier for prototypes that are not
shipped. Ask Raspberry Pi for a product id under 2E8A, or pid.codes for one of
your own, before this leaves the bench. The application checks the `PLYZ` magic
and the protocol version in the identify reply as well, so it will not mistake
another prototype on the same identifier for an instrument.

## What it does not do yet

* **Equivalent-time sampling.** The fastest real-time sweep is set by the
  converter: 4 µs per sample pair, so about 20 µs per division before the trace
  becomes dots. Building a record from many triggers would go far faster on a
  repetitive signal, and needs a programmable delay between the trigger and the
  start of capture.
* **A shared trigger between the analogue and logic sides.** Both run, but
  independently, so their records cannot be lined up against each other.
* **Pattern triggers on the logic inputs** — the watcher is one edge on one
  channel.
* **Streaming.** Records are captured and then read; there is no continuous
  mode, so the meter's rate is set by round trips.
