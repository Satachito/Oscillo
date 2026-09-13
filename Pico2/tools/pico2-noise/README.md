# Four test signals on a Pico 2

A 440 Hz sine and three noises, on a Pico 2 with nothing else to do. Flash it
to a **spare board** — it is a separate program from
[`../pico2-chord`](../pico2-chord), and a Pico can only run one of them.

**The instrument does this itself** from firmware 1.9, from the same source
file: switch on Signal generator in the panel. It puts them on GPIO16–19 rather
than the pins below, which is where firmware 1.11 settled them for every board.
This program is for when the instrument's own pins are wanted for something
else, or when a second board is simply more convenient than sharing one.

| GPIO | Signal | Level (peak to peak) | RMS |
| ---: | --- | ---: | ---: |
| 0 | 440 Hz sine | 3.14 V | 1.11 V |
| 1 | white noise, flat | 2.96 V | 0.86 V |
| 2 | pink noise, −3 dB an octave | 2.82 V | 0.34 V |
| 3 | brown noise, −6 dB an octave | 2.76 V | 0.34 V |

All four sit on **1.65 V**, use 0–3.3 V and never reach either rail. Take the
reference from a GND pin on this board.

## Fit an RC on each pin

The RP2350 has no converter, so each signal is a **586 kHz PWM carrier whose
duty follows the sample**, 50,000 samples a second. Without a filter, a pin
carries square edges and the signal is only in their width:

```text
GPIO ──[ R ]──┬── to the instrument
              │
            [ C ]
              │
             GND
```

| R | C | Corner | Carrier left | Good for |
| ---: | ---: | ---: | ---: | --- |
| 1 kΩ | 100 nF | 1.6 kHz | −51 dB | the sine, and hearing the noises |
| 1 kΩ | 8.2 nF | 19 kHz | −30 dB | noise with its top octaves intact |

One pole is enough because the carrier is nine octaves above the signal. What
is left of it lands at 586 kHz, above anything PiLyzer samples — but **not
above what it aliases**: at 500 kSa/s a residual carrier folds back to 86 kHz,
so filter it rather than leave it.

## What the noises are

White comes from a 32-bit xorshift, which is uniform rather than Gaussian: its
peak is exactly its amplitude, so it can use nearly the whole range without
ever clipping. Pink is Paul Kellett's three-pole fit to a 3 dB per octave tilt.
Brown is white integrated, with a slow leak so it cannot wander onto a rail and
stay there.

The tests tell them apart without a spectrum analyser, by how much a sample
differs from the one before it against the signal's own power — 2 for
uncorrelated noise, and halving with each octave of tilt:

| | white | pink | brown |
| --- | ---: | ---: | ---: |
| measured | 2.00 | 0.37 | 0.011 |

## Building and flashing

From the repository root, with the Pico SDK and ARM toolchain configured:

```sh
cmake -S Pico2/tools/pico2-noise -B build/pico2-noise -G Ninja
cmake --build build/pico2-noise
bash Pico2/tools/pico2-noise/tests/run.sh
```

Hold BOOTSEL, plug the spare Pico 2 in, and copy `build/pico2-noise/noise.uf2`
onto the drive that appears. USB CDC prints the sample rate and the carrier;
the board LED blinks.

## Measuring it with PiLyzer

The signals are DC coupled and sit at mid rail, which is what the mini AFE in
front of the instrument wants: nothing on that board shifts them, so what the
converter reads is what this one made. 440 Hz is 113 samples at 50 kSa/s, so a
sweep of 1 ms/div holds four and a half cycles.
