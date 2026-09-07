# PiLyzer analogue front end, rev A

Three DC-coupled analogue channels and eight logic inputs for a Raspberry Pi
Pico 2. Design status: **KiCad schematic captured and footprints assigned;
prototype measurements and PCB layout remain.** Open
[`kicad/pilyzer-afe.kicad_pro`](kicad/pilyzer-afe.kicad_pro) in KiCad 10.
The four sheets cover the Pico/power/logic interface, CH1, CH2, and CH3 (rev B).
See [`kicad/README.md`](kicad/README.md) for checks, sources and capture corrections.

This board is USB-ground referenced and **not isolated**. It must not be used
on mains primary circuits, on anything floating at a dangerous potential, or on
any circuit that is unsafe to connect to the Mac's USB ground.

## What it is for

| | |
| --- | --- |
| Channels | 3, DC coupled, about 1.06 MΩ in |
| Ranges | ±25 V and ±5 V, switched under software control |
| Resolution | 12 bits, extended by averaging on slow sweeps |
| Sample rate | 495 / 247 / 165 kSa/s per channel with 1 / 2 / 3 enabled |
| Analogue bandwidth | 40 kHz, set by a two-pole Sallen-Key on each channel |
| Logic | 8 inputs, 3.3 V only, up to 150 MSa/s |

The sample rate is the honest ceiling of the RP2350's converter, and it is what
decides the rest: there is no point building a megahertz front end in front of
it.

## The anti-alias filter

Each channel ends in a **unity-gain Sallen-Key low pass** before the converter.
It replaced a pair of passive RC sections that were sized when this was a
two-channel board: a third channel divides the converter three ways instead of
two, Nyquist fell from 124 kHz to 82 kHz, and the old passband reached past it —
so a signal between 82 kHz and roughly 250 kHz was neither rejected by the
filter nor resolved by the converter. It folded back and appeared as a lower
frequency that looked perfectly real.

Equal resistors make the arithmetic short:

```text
fc = 1 / (2π · R · √(C1 · C2))       Q = ½ · √(C1 / C2)
R = 2.67 kΩ   C1 = 2.2 nF   C2 = 1 nF
   -> fc = 40.2 kHz, Q = 0.742 (near Butterworth)
```

| | response |
| --- | ---: |
| 20 kHz — the top of the audio band | −0.1 dB |
| 40 kHz — the corner | −2.6 dB |
| 82.5 kHz — Nyquist with three channels | −12.5 dB |
| 124 kHz — Nyquist with two | −19.5 dB |
| 247 kHz — Nyquist with one | −31.6 dB |

`check_transfer.py` prints this table and is the thing to re-run after changing
a value.

Two poles cannot make aliasing go away, and it would be wrong to say it has.
What it does is turn a signal just past Nyquist from something that arrives at
nearly full amplitude into something that arrives at a quarter of it, and
everything an octave further out into a fortieth. The rest of the protection
comes from the firmware, which box-car averages every sample on a slow sweep
and so filters again at whatever rate is actually in use.

**The trade this makes.** The corner is fixed, so it is sized for the
three-channel case, which is the default. One- and two-channel modes are then
limited by the filter rather than by the converter: with a single channel the
converter would reach 247 kHz of Nyquist but the front end still stops at
40 kHz. Raising R to 3.48 kΩ moves the corner to 31 kHz and buys 4.5 dB more
rejection at Nyquist for 0.3 dB more loss at 20 kHz; that is the one value to
change if the balance is wrong.

**Choosing the parts cost nothing extra.** R is a value the board already uses
(R8 sets the fine-range gain), C2 is the 1 nF already in the BOM, and the
amplifier is a second TLV9064 — the same part number as U1. Only the 2.2 nF is
new, so the whole filter adds a single part type to the order.

## The signal path

Two stages per channel. The attenuator is **fixed**, and only the gain after it
changes with the range — which is what lets one frequency compensation serve
both ranges instead of needing a different trimmer for each.

```text
IN -- R1 499k -- R2 499k -- NODE --> U1A (+)
 |__________________________|
       C1 6.8p || TC1

NODE -- R3 125k -- 3V3     NODE -- R4 143k -- GND
NODE -- C4 82p -- GND      NODE -- BAV199 rail clamps -- GND / 3V3

U1A OUT -- R5 2.67k -- SK -- R6 2.67k -- U4A (+)
                       |                |
                    C21 2.2n          C6 1n
                       |                |
                   U4A OUT             VMID

U4A OUT -- U4A (-)            (unity gain)
U4A OUT -- R44 1k -- ADC -- C7 1n -- GND

U1A OUT -- R7 10k -- U1A (-) -- R8 2.67k -- U2A COM
U2A NO -- VMID        U2A NC -- not connected
GPIO16 LOW: COM-NC (gain 1); HIGH: COM-NO (gain 4.745)
```

* **R1 + R2** are the 1 MΩ input, split in two so each 0805 sees half the
  voltage. That is what sets the working voltage, not a number on a datasheet
  for the pair.
* **R3 and R4** bias the divider node so that 0 V at the input lands on mid
  rail. They are deliberately *not* equal: the input resistor pulls the node
  toward ground, and R3 being the smaller leg is what cancels it.
* **C1 and C4** compensate the divider. Without them the ranges roll off at a
  few tens of kHz, differently from each other, and a square wave comes back
  with the wrong shape.
* **The op amp** is a follower when the switch is open, and a ×4.745 amplifier
  referenced to VMID when it is closed. R7 carries no current with R8
  disconnected, so the open position is exactly unity — there is nothing to
  calibrate about it.
* **SW** is the range switch, and it sits at VMID on both sides. Its
  on-resistance therefore never sees a signal swing, so it adds a fixed 0.2%
  gain error that calibration removes rather than distortion that nothing can.
* **R5, R6, C21 and C6 with U4A** are a unity-gain Sallen-Key low pass, the
  anti-alias filter. C6 returns to VMID rather than to ground: VMID is AC
  ground and is buffered, so the filter passes the mid-rail bias through
  untouched and stays ratiometric with the converter's reference.
* **R44 and C7** isolate the filter's output from the converter's sampling
  capacitor and give it a charge reservoir to draw on.

VMID is 3V3 halved by two 10 kΩ resistors and buffered by U1D. C15 (1 µF)
is across the lower divider resistor, before the buffer.

Two quads carry the analogue path. U1 is the gain stages — U1A, U1B, U1C — plus
U1D for VMID; U4 is the three anti-alias filters, U4A, U4B and U4C, leaving U4D
as the only spare amplifier on the board. Tie its input to VMID and close the
loop rather than leaving it floating.

## Why the bias comes from 3V3 and must keep coming from 3V3

The converter's reference on a Pico 2 is the 3V3 rail, filtered. This board's
bias and VMID come from the same rail, so a wobble in it moves the reading and
the reference **by the same fraction** and cancels to first order. That is worth
more than a precision reference would be.

So: do not "improve" this by filtering the front end's supply separately, and do
not fit an external reference on ADC_VREF unless the bias legs and VMID are
moved onto it as well. Splitting them is the one change that would quietly make
every reading worse.

## The numbers

With the nominal values above:

```text
±25 V range (switch open, gain 1)
    Vadc = 1.650515 V + 0.062645 · Vin
    −25 V → 0.0844 V     0 V → 1.6505 V     +25 V → 3.2166 V

±5 V range (switch closed, gain 4.745)
    Vadc = 1.652442 V + 0.297269 · Vin
     −5 V → 0.1661 V     0 V → 1.6524 V      +5 V → 3.1388 V
```

The fine range's amplifier is 4.745 rather than a round 5, and that is the
reason R8 is 2.67 kΩ. At a gain of 5 the nominal range fits, but the 1% corner
of the resistor stack pushes the ends of ±5 V past the converter — the script
prints −0.017 V and 3.310 V — and a range that clips on a bad batch is worse
than one that is 5% short. At 4.745 the worst corner is 0.073 V to 3.220 V,
inside the converter with the tolerances at their least helpful.

The coarse range has no such problem: 1% parts move its ends by ±32 mV against
84 mV of headroom.

Input impedance is 998 kΩ + (125 kΩ ∥ 143 kΩ) = 1.065 MΩ. The node the op amp
looks at is 62.5 kΩ, which is what sets the compensation ratio:

```text
C1 · (R1 + R2) = C_node · (R3 ∥ R4)
C1 = C_node · 66.7 k / 998 k = C_node / 15.0
```

With C4 at 82 pF plus roughly 18 pF of stray and amplifier capacitance, C1
comes out at 6.7 pF, so 6.8 pF is the part and TC1 beside it is the adjustment.

`check_transfer.py` prints these lines and the 1% corners, and is the thing to
re-run after changing any value.

## Adjusting the compensation

The firmware puts a square wave on GPIO20 for exactly this. Feed it into a
channel, set the ±25 V range, and adjust TC1 until the corners are square — the
same procedure as compensating a scope probe, and the same failure modes:
overshoot means too much capacitance across the input resistor, a slumped
leading edge means too little.

The signal is only 3.3 V into a ±25 V range, so put the display on a fine
volts-per-division setting to see the corner.

## Ranges are switched, not jumpered

The range switch is driven from GPIO16, GPIO17 and GPIO18, so the application always
knows which range a channel is on, can offer per-range calibration, and can
change ranges without anyone touching the board.

This is deliberate. A pair of jumpers per channel is cheaper, but a jumper left
in the wrong place produces a reading that is wrong by a factor of five and
looks perfectly plausible, with nothing in software able to tell.

## Protection

| | |
| --- | --- |
| Continuous input | ±100 V, set by the 0805 resistors' working voltage |
| Absolute maximum | ±200 V, momentary |
| Fault current into the clamp | under 100 µA at 100 V, through 1 MΩ |

The 1 MΩ input is itself most of the protection: at 100 V the divider node
would sit at 7.9 V, the clamp diodes conduct, and the current they pass is
96 µA. D1/D2 are BAV199 for their nanoamp leakage — a general-purpose switching
diode leaks enough at temperature to shift the zero on the fine range.

The TVS footprints at the connectors are unpopulated. Their capacitance appears
directly across the input and would upset the compensation, so they go in only
after that has been measured with them fitted.

## Logic inputs

Eight inputs on GPIO8…GPIO15, each through 330 Ω. **3.3 V logic only.** The
series resistor limits the current into the RP2350's own clamp diodes to about
5 mA at 5 V, which the chip survives, but a 5 V system will still be loaded and
the levels are outside specification. There is no buffer and no level shifter on
this board; feeding it 5 V logic is a rev B question, not a "probably fine".

Optional 100 kΩ pulldowns can be populated to keep unused inputs from floating.
They are marked DNP in the schematic and do nothing while unpopulated.

## Connections to the Pico 2

| Signal | GPIO | Physical pin |
| --- | ---: | ---: |
| CH1 to converter | GPIO26 / ADC0 | 31 |
| CH2 to converter | GPIO27 / ADC1 | 32 |
| CH3 to converter | GPIO28 / ADC2 | 34 |
| Analogue ground | AGND | 33 |
| Converter reference | ADC_VREF | 35 |
| Front-end supply | 3V3(OUT) | 36 |
| CH1 range switch | GPIO16 | 21 |
| CH2 range switch | GPIO17 | 22 |
| CH3 range switch | GPIO18 | 24 |
| Logic D0…D7 | GPIO8…GPIO15 | 11,12,14,15,16,17,19,20 |
| Adjustable calibration output | GPIO20 | 26 |
| Unused | GPIO0…GPIO7 | 1,2,4,5,6,7,9,10 |

The op amp draws about 4 mA, so the whole board runs from 3V3(OUT).

## Third channel (rev B / firmware 1.5)

CH3 uses U1C for its gain stage and U4C for its filter. Its input is J10, a
2-pin header. R36–R43, C16–C19, TC3 and D3 repeat the CH1 input network; D7 is
the optional DNP TVS, and TP7 exposes the divider node. U3A switches its range;
C20 decouples U3. U3B has control tied low and signal pins left unconnected.
U1D continues to buffer VMID.

CH3 ADC is GPIO28 / J7.7; its range control is GPIO18 / J7.17. Test output
moves to GPIO20 / J7.15, through R35 to TP6. J8 remains unused.

The ADC scans only the channels enabled in the app. Maximum rates per channel
are 495 / 247 / 165 kSa/s with 1 / 2 / 3 checked. At maximum rate each
conversion is 2.02 µs after the previous one; the inputs are not sampled
simultaneously. Three-channel Nyquist frequency is about 82 kHz, so the
analogue filter must be evaluated at that rate as well as the faster modes.

## Separate chord generator

The diminished-chord generator runs on a separate Pico 2. The carrier has no
J8 or note-output circuitry; GPIO0–7 are marked unconnected on J6.
Firmware 1.5 adds CH3 on GPIO28 with range GPIO18 and moves test output to
GPIO20 / TP6. Logic GPIO8–15 and range GPIO16/17 remain unchanged.
See [`tools/pico2-chord`](../../tools/pico2-chord) for the standalone program.

This pin allocation supersedes firmware 1.2: rewire the logic and range signals
before using firmware 1.3 or later. Firmware 1.5 also requires moving the test
output from GPIO28 to GPIO20 before GPIO28 is used as CH3. The software range gains are unchanged.

## Before fabrication

1. Breadboard one channel and **measure** the frequency response in both
   ranges. Every number above is nominal; the compensation in particular is
   only as good as the stray capacitance, which a layout changes.
2. Measure the Sallen-Key's actual corner and Q against the calculated
   40.2 kHz and 0.742. Capacitor tolerance moves Q, and a Q much above 0.8
   puts a peak in the passband just where the filter is supposed to be
   flattening out.
3. Check the clamp diodes' leakage at temperature on the ±5 V range, where a
   nanoamp through 62 kΩ is already visible.
4. Review the captured schematic and assigned footprints against the actual parts
   to be ordered. KiCad ERC currently passes; rerun it after edits.
5. Lay out, keeping the divider node small — it is the compensation.
6. DRC, Gerber review, BOM and CPL.

The current schematic is in `hardware/pilyzer-afe/kicad`.
