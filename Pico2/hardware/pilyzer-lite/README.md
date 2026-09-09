# PiLyzer Lite

Two DC-coupled analogue channels and eight logic inputs for a Raspberry Pi
Pico 2, at a price a classroom can carry. Design status: **KiCad schematic
captured and footprints assigned; prototype measurements and PCB layout
remain.** Open [`kicad/pilyzer-lite.kicad_pro`](kicad/pilyzer-lite.kicad_pro)
in KiCad 10.

This board is USB-ground referenced and **not isolated**. It must not be used
on mains primary circuits, on anything floating at a dangerous potential, or on
any circuit that is unsafe to connect to the computer's USB ground.

## What it is for

| | |
| --- | --- |
| Channels | 2, DC coupled, about 1.06 MΩ in |
| Range | one, −15.81 to +15.80 V — a 12 V supply with room to spare |
| Logic | 8 inputs, 3.3 V only, up to 150 MSa/s |
| Resolution | 12 bits, extended by averaging on slow sweeps |
| Instruments | oscilloscope, spectrum, logic analyser, logger |
| Firmware | `PILYZER_BOARD_ID 2`, 1.7 or later |

## Why one range

A switch costs two packages, two GPIOs and a calibration point per channel, and
the thing it buys is resolution on small signals. On a board for teaching, one
range that reaches a 12 V supply is worth more than two that need explaining.

The cost is honest and worth stating: one range this wide is **1.5 bits coarser
on small signals** than rev A's fine range — 7.72 mV a count against 2.71 mV.
3.3 V logic still lands on about 430 counts and line-level audio on 360, and the
firmware's box-car decimation puts bits back on slow sweeps.

## Why the attenuator did not shrink with the range

The fixed 1 MΩ attenuator is where the input protection lives, not where the
range is chosen, so it is rev A's exactly:

| Input | Divider node | |
| ---: | ---: | --- |
| ±15.8 V | 2.64 V | the top of the range |
| 25 V | 3.22 V | reads as clipped; the clamp is still idle |
| 26.3 V | 3.30 V | the clamp begins to conduct |
| 100 V | 7.92 V | the continuous rating, 96 µA through the clamp |

Sizing a divider straight for ±15 V and dropping the gain stage would save two
resistors and put the divider node **at the rail** at full scale, leaving the
clamp on the edge of conduction with its leakage inside the measurement instead
of 26 V away from it. On a board where the wrong thing will be probed, that
trade is the wrong way round.

Anything past the range clips rather than damaging, all the way to the ±100 V
the attenuator is rated for.

## The signal path

Unchanged from [rev A](../pilyzer-afe/README.md#the-signal-path) except that the
gain leg goes to VMID directly instead of through a switch, and two capacitor
values differ:

```text
IN -- R1 499k -- R2 499k -- NODE --> U1A (+)
 |__________________________|
       C1 15p || TC1

NODE -- R3 125k -- 3V3     NODE -- R4 143k -- GND
NODE -- C4 220p -- GND     NODE -- BAV199 rail clamps -- GND / 3V3

U1A OUT -- R5 2.67k -- SK -- R6 2.67k -- U4A (+)   (Sallen-Key, 40.2 kHz)
U1A OUT -- R44 1k -- ADC

U1A OUT -- R7 10k -- U1A (-) -- R8 15k -- VMID      (gain 1.667, fixed)
```

## Building the firmware for it

```sh
cd ../../firmware/pilyzer && BOARD_ID=2 ./build.sh
```

Neither application needs a release. The device has described its own front end
since firmware 1.7, so Lite answers with one range and both front panels hide
the range menu on their own.

## Before fabrication

The measurements are rev A's, and a single channel on a breadboard settles all
of them — see [`../pilyzer-afe/breadboard`](../pilyzer-afe/breadboard), which
differs only in `R8` being 15 kΩ.

1. Measure the frequency response and trim the compensation.
2. Measure the Sallen-Key's real corner and Q against 40.2 kHz and 0.742.
3. Check the clamp diodes' leakage warmed up.
4. Review the capture and the footprints against the parts to be ordered.
5. Lay out, keeping the divider node small — it is the compensation.
6. DRC, Gerber review, BOM and CPL.
7. Measure the first boards, then **replace `TC1`/`TC2` with the fixed value
   they land on**. The larger `C4` is what makes that possible.
