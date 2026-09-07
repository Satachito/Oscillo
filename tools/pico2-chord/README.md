# Standalone diminished-chord generator

Run this program on a dedicated Pico 2, separate from the PiLyzer instrument.
It continuously emits 50% duty square waves with complementary levels on each
pair: even GPIO normal, odd GPIO inverted. UART stdio is disabled; USB CDC
prints actual PWM frequencies and the board LED blinks.

| Note | Normal GPIO | Inverted GPIO | Nominal frequency |
| --- | ---: | ---: | ---: |
| C4 | 0 | 1 | 261.626 Hz |
| E♭4 | 2 | 3 | 311.127 Hz |
| F♯4 | 4 | 5 | 369.994 Hz |
| A4 | 6 | 7 | 440.000 Hz |

Use a GND pin on this Pico as the signal reference. Signals are 0–3.3 V square
waves. Analogue sine-wave conversion and DC removal belong on a separate board.

The four PWM slices start together. Integer clock dividers and even periods
keep duty at 50% without fractional-divider modulation. At a nominal 150 MHz
system clock, the actual frequencies are 261.626690, 311.131023, 369.993981 and
440.001408 Hz; oscillator accuracy still applies.

From the repository root, with the Pico SDK and ARM toolchain configured:

```sh
cmake -S tools/pico2-chord -B build/pico2-chord -G Ninja
cmake --build build/pico2-chord
bash tools/pico2-chord/tests/run.sh
```

The output is `build/pico2-chord/chord.uf2`. This program is independent of the
instrument firmware and is not linked into it. The PiLyzer carrier has no J8.
