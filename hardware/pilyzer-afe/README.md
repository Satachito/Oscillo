# PiLyzer analogue front end, rev A

Two DC-coupled analogue channels and eight logic inputs for a Raspberry Pi
Pico 2. Design status: **circuit and values fixed, ready to breadboard.** The
schematic capture, PCB layout and Gerbers are not done — see *Before
fabrication* at the end.

This board is USB-ground referenced and **not isolated**. It must not be used
on mains primary circuits, on anything floating at a dangerous potential, or on
any circuit that is unsafe to connect to the Mac's USB ground.

## What it is for

| | |
| --- | --- |
| Channels | 2, DC coupled, about 1.06 MΩ in |
| Ranges | ±25 V and ±5 V, switched under software control |
| Resolution | 12 bits, extended by averaging on slow sweeps |
| Sample rate | 250 kSa/s per channel with both on, 500 kSa/s with one |
| Analogue bandwidth | set by the anti-alias filter, about 100 kHz |
| Logic | 8 inputs, 3.3 V only, up to 150 MSa/s |

The sample rate is the honest ceiling of the RP2350's converter, and it is what
decides the rest: with 125 kHz of Nyquist there is no point building a
megahertz front end, and the filter below is sized to match rather than to
impress.

## The signal path

Two stages per channel. The attenuator is **fixed**, and only the gain after it
changes with the range — which is what lets one frequency compensation serve
both ranges instead of needing a different trimmer for each.

```text
                   C1 6.8p
                ┌────┤├────┐
                │          │
 IN ──┬── R1 ───┴─ R2 ─────┴──┬── node ──┬───────► +  ┌────────┐
      │  499k       499k      │          │         │  │TLV9064 │──┬── R5 1k ──┬── R6 1k ──┬── ADC
      │                       │        C4 82p      └──┤        │  │           │           │
     D1 clamp            R3 125k                      └────────┘  │          C6 1n       C7 1n
     to 3V3/AGND          to 3V3                        ▲    │    │           │           │
                          R4 143k                       │    └────┴─ R7 10k ──┘          AGND
                          to AGND                       │                 │
                                                        │            ┌────┴─────┐
                                                     (inverting)     │ R8 2.49k │
                                                        └────────────┤  + SW    ├── VMID
                                                                     └──────────┘
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
* **The op amp** is a follower when the switch is open, and a ×5 amplifier
  referenced to VMID when it is closed. R7 carries no current with R8
  disconnected, so the open position is exactly unity — there is nothing to
  calibrate about it.
* **SW** is the range switch, and it sits at VMID on both sides. Its
  on-resistance therefore never sees a signal swing, so it adds a fixed 0.2%
  gain error that calibration removes rather than distortion that nothing can.
* **R5/C6 and R6/C7** are the anti-alias filter and the converter's isolation
  resistor in one. R6 also stops the op amp from seeing the converter's
  sampling capacitor directly.

VMID is 3V3 halved by two 10 kΩ resistors and buffered by the fourth amplifier.

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

The firmware puts a square wave on GPIO2 for exactly this. Feed it into a
channel, set the ±25 V range, and adjust TC1 until the corners are square — the
same procedure as compensating a scope probe, and the same failure modes:
overshoot means too much capacitance across the input resistor, a slumped
leading edge means too little.

The signal is only 3.3 V into a ±25 V range, so put the display on a fine
volts-per-division setting to see the corner.

## Ranges are switched, not jumpered

The range switch is driven from GPIO14 and GPIO15, so the application always
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

Eight inputs on GPIO6…GPIO13, each through 330 Ω. **3.3 V logic only.** The
series resistor limits the current into the RP2350's own clamp diodes to about
5 mA at 5 V, which the chip survives, but a 5 V system will still be loaded and
the levels are outside specification. There is no buffer and no level shifter on
this board; feeding it 5 V logic is a rev B question, not a "probably fine".

Unpopulated 100 kΩ pulldowns keep unused inputs from floating and filling the
display with noise.

## Connections to the Pico 2

| Signal | GPIO | Physical pin |
| --- | ---: | ---: |
| CH1 to converter | GPIO26 / ADC0 | 31 |
| CH2 to converter | GPIO27 / ADC1 | 32 |
| Analogue ground | AGND | 33 |
| Converter reference | ADC_VREF | 35 |
| Front-end supply | 3V3(OUT) | 36 |
| CH1 range switch | GPIO14 | 19 |
| CH2 range switch | GPIO15 | 20 |
| Logic D0…D7 | GPIO6…GPIO13 | 9,10,11,12,14,15,16,17 |
| Test output | GPIO2 | 4 |

The op amp draws about 4 mA, so the whole board runs from 3V3(OUT).

## Before fabrication

1. Breadboard one channel and **measure** the frequency response in both
   ranges. Every number above is nominal; the compensation in particular is
   only as good as the stray capacitance, which a layout changes.
2. Measure the anti-alias filter's actual corner and stopband, and decide
   whether the passive two-pole is enough or the spare amplifier should become
   a Sallen-Key.
3. Check the clamp diodes' leakage at temperature on the ±5 V range, where a
   nanoamp through 62 kΩ is already visible.
4. Capture the schematic, assign footprints, run ERC.
5. Lay out, keeping the divider node small — it is the compensation.
6. DRC, Gerber review, BOM and CPL.

The previous jumper-switched design is still in `hardware/pico2-afe`, and is
superseded by this one.
