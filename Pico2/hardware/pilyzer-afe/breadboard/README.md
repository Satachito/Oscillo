# One channel on a breadboard

Everything in [`bom.csv`](bom.csv) builds **one** analogue channel of the AFE,
because every measurement in "Before fabrication" is a per-channel measurement.
Three channels on a breadboard would cost three times as much and tell you the
same thing three times.

The PCB bill of materials next door is 0805 and SOIC. This one is through hole
wherever a through-hole part exists, and names the adapter where none does.

**There is no clamp on this build.** The PCB carries a BAV199 across the divider
node; a breadboard is a bench where you already know what you are connecting, so
it saves a SOT-23 adapter and a part whose leakage would otherwise sit in every
reading. The 1 MΩ input is doing the protecting either way — it is what turns
100 V at the probe into 96 µA — but the last few volts now land on the op amp's
own input diodes, which are not specified for the job and leak more than a
BAV199 does. **Keep the input inside the range the board is built for**, and do
not use this one to find out what happens above it: that is what
[the clamp tables](../README.md#protection) are for, and they describe the PCB.

Leaving it out also gives up a measurement. The clamp's leakage, warmed up, was
one of the things this build was meant to show; it can still be measured, but
only on a board that has the part fitted.

## What one channel needs

`U1` is a quad, and a single channel uses three of its four amplifiers, so
**one TLV9064 is the whole analogue path**:

| Unit | Job |
| --- | --- |
| U1A | gain stage — follower on ±25 V, ×4.745 on ±5 V |
| U1B | the Sallen-Key filter (U4A on the PCB) |
| U1D | the VMID buffer |

Wire it as the block diagram in [`../README.md`](../README.md#the-signal-path)
draws it, with `U4A` read as `U1B`.

## Trying it before you wire it

[`falstad-one-channel.txt`](falstad-one-channel.txt) is this channel as a
circuit for the [Falstad simulator](https://www.falstad.com/circuit/circuitjs.html),
which runs in a browser with nothing to install — the same bargain the
application itself makes.

**[Open it in the simulator](https://www.falstad.com/circuit/circuitjs.html?cct=%24%201%201.0E-6%2010.20027730826997%2050%203.3%2050%205.0E-11%0AR%2080%20320%2032%20320%200%201%20100.0%205.0%200.0%200.0%200.5%0Aw%2080%20320%20144%20320%200%0Ar%20144%20320%20208%20320%200%20499000.0%0Ar%20208%20320%20272%20320%200%20499000.0%0Aw%20144%20320%20144%20256%200%0Aw%20272%20320%20272%20256%200%0Ac%20144%20256%20272%20256%200%206.8E-12%200%0Aw%20272%20320%20336%20320%200%0Ar%20336%20320%20336%20256%200%20125000.0%0AR%20336%20256%20336%20224%200%200%2040.0%203.3%200.0%200.0%200.5%0Ar%20336%20320%20336%20384%200%20143000.0%0Ag%20336%20384%20336%20416%200%0Aw%20336%20320%20400%20320%200%0Ac%20400%20320%20400%20384%200%208.2E-11%200%0Ag%20400%20384%20400%20416%200%0Aw%20400%20320%20544%20320%200%0Aa%20544%20304%20640%20304%200%203.3%200.0%201000000.0%0Aw%20640%20304%20640%20224%200%0Ar%20640%20224%20544%20224%200%2010000.0%0Aw%20544%20224%20544%20288%200%0Ar%20544%20224%20544%20160%200%202670.0%0Aw%20640%20304%20704%20304%200%0Ar%20704%20304%20768%20304%200%202670.0%0Ar%20768%20304%20832%20304%200%202670.0%0Aw%20832%20304%20848%20304%200%0Aa%20848%20288%20944%20288%200%203.3%200.0%201000000.0%0Aw%20944%20288%20944%20224%200%0Aw%20944%20224%20848%20224%200%0Aw%20848%20224%20848%20272%200%0Aw%20944%20288%20944%20368%200%0Ac%20944%20368%20768%20368%200%202.2E-9%200%0Aw%20768%20368%20768%20304%200%0Ac%20848%20304%20848%20448%200%201.0E-9%200%0Aw%20944%20288%201008%20288%200%0Ar%201008%20288%201072%20288%200%201000.0%0Ac%201072%20288%201072%20368%200%201.0E-9%200%0Ag%201072%20368%201072%20400%200%0AO%201072%20288%201136%20288%200%0AR%2096%20400%2096%20368%200%200%2040.0%203.3%200.0%200.0%200.5%0Ar%2096%20400%2096%20464%200%2010000.0%0Ar%2096%20464%2096%20528%200%2010000.0%0Ag%2096%20528%2096%20560%200%0Aw%2096%20464%20160%20464%200%0Ac%20160%20464%20160%20528%200%201.0E-6%201.65%0Ag%20160%20528%20160%20560%200%0Aa%20224%20448%20320%20448%200%203.3%200.0%201000000.0%0Aw%20160%20464%20224%20464%200%0Aw%20320%20448%20320%20400%200%0Aw%20320%20400%20224%20400%200%0Aw%20224%20400%20224%20432%200%0Aw%20320%20448%20848%20448%200%0Aw%20848%20448%201200%20448%200%0Aw%201200%20448%201200%20160%200%0Aw%201200%20160%20544%20160%200%0A)**

Or open the simulator and use *File → Import From Text*, which is the shorter
road if that link has been mangled by something in between.

What is in it: the 1 MΩ input split in two, the compensation across it, the
bias legs to 3V3 and ground, `C4`, the gain stage at ×4.745,
the VMID divider and its buffer, the Sallen-Key section, and `R44`/`C7` at the
converter pin. The source is a 5 V 100 Hz sine, which is the fine range's full
scale, so the output swings very nearly rail to rail.

It agrees with [`../check_transfer.py`](../check_transfer.py), which is the
point of having it:

| Input | Divider node | At the converter | `check_transfer.py` |
| ---: | ---: | ---: | ---: |
| 0 V | 1.6505 V | 1.652 V | 1.6524 V |
| +5 V | 1.9637 V | 3.139 V | 3.1388 V |
| −5 V | 1.3373 V | 0.1662 V | 0.1661 V |

A 1 V peak sine at 1 kHz comes out 0.595 V peak to peak, which is
2 × 0.29727 exactly, and at 100 kHz it is 6.8 times smaller — the anti-alias
filter doing what the 40.2 kHz corner says it should.

Two things it is not. The op amps are ideal ones with the rails set to 0 and
3.3 V, so it will not show you the TLV9064's offset, noise or bandwidth; and
past about ±10 V at the input the ideal model stops converging on anything
physical. It has no clamp in it, because this build has none — what happens
above the range is in [`../README.md`](../README.md#protection), and it is the
PCB's behaviour, not this one's.

Change `R8` from 2.67 kΩ to 15 kΩ in the simulator and you have the one-range
±15 V build below, with nothing else moved.

## Changing range by hand instead of fitting the switch

`U2A` selects the range by connecting the far end of `R8` either to VMID or to
nothing:

| Range | `U2A` | Gain | On the breadboard |
| --- | --- | ---: | --- |
| ±25 V | COM–NC, so `R8` goes nowhere | 1 | **take `R8` out** |
| ±5 V | COM–NO, so `R8` goes to VMID | 4.745 | `R8` in, far end wired to VMID |

**A bench that wants no switch at all** can have one ±15 V range instead: the
same circuit with `R8` at 15 kΩ wired permanently to VMID. Building that instead
is a change of one resistor; everything measured here — the compensation, the
filter, the compensation — is identical either way, and
[the rev A notes](../README.md#building-it-with-one-range-instead-of-two) carry
the arithmetic and what the single range costs in resolution.

That is exactly the two states, and it works because the switch sits at VMID on
both sides on the real board and so never sees a signal swing.

**Pull `R8` out rather than leaving one end dangling.** Its other end is on the
amplifier's inverting input, which is a high-impedance summing node; a free wire
there is an aerial, and a breadboard's is a much better one than a PCB trace. An
empty pair of holes is what "connected to nothing" is supposed to mean.

**Keep the application's range selection matching the wire.** The host sends
`setRange` to GPIO4, which with no switch fitted drives nothing at all — but it
still applies that range's gain and offset to everything it reads. Choose ±5 V
in the panel with `R8` out and every number will be wrong by the ratio of the
two ranges, with nothing on screen to say so. If that is a trap you would rather
not step in, hang an LED and a resistor off GPIO4: lit means the application
thinks it is on the fine range, and the wire should agree.

Change the link with the acquisition stopped. Nothing here is delicate, but that
summing node will pick up your hand.

### What the jumper costs

The switch's on resistance is in series with `R8`, and the design notes put it
at a fixed **0.2%** of gain — about 7 Ω:

| | Gain |
| --- | ---: |
| jumper, 0 Ω | 4.7453 |
| `U2A` at 7 Ω | 4.7352 |

So the gain a jumper measures is the circuit's, not the board's. That matters
for the absolute gain figure and for nothing else: the frequency response and
the filter's Q are unaffected. Fit the real part when
you want the board's own number — and buy the adapter now either way, since you
will want it eventually.

## The op amp is not optional, and there is no DIP one

There is no through-hole TLV9064, and the DIP op amps everybody has in a drawer
— LM358, TL072, NE5532, OPA2134 — cannot do this job at all: none of them will
run rail to rail on a single 3.3 V supply, and on the ±25 V range the follower's
input covers the whole 0 V to 3.3 V of the divider node. So the choice is a
SOIC-14 adapter or a different modern part.

What the circuit actually asks for:

| | | |
| --- | --- | --- |
| Supply | single 3.3 V | the board runs off the Pico's 3V3 and nothing else |
| Input and output | both rail to rail | the follower's input is the divider node, 0 – 3.3 V |
| Gain bandwidth | ≥ 4 MHz | 100 × the filter's 40.2 kHz corner. The TLV9064's 10 MHz is 249 × |
| Input bias current | ≤ 1 nA, so CMOS or FET | see below |
| Amplifiers | three | one quad, or two duals |

The bandwidth and the bias current are not preferences. **The filter's Q is a
measurement of the amplifier as much as of the circuit around it**, and the bias
current lands directly on the reading, so substituting the part quietly defeats
the point of measuring either.

The divider node's source impedance is 62.5 kΩ — 125k, 143k and the 998k input
in parallel. Input bias current flows through that:

| Input stage | Bias current | At the node | In converter counts |
| --- | ---: | ---: | ---: |
| CMOS, as specified | 10 pA | 0.6 µV | 0.00 LSB |
| a nanoamp, from anywhere | 1 nA | 62.5 µV | 0.08 LSB |
| an ordinary bipolar input | 45 nA | 2813 µV | 3.49 LSB |

A bipolar-input part puts three and a half counts of its own into every reading,
before anything else in the circuit has had a turn, and it moves with
temperature.

The bandwidth argument is the same shape. A 1 MHz part is 25 × the filter's
corner, not 249 ×, and its finite gain bandwidth moves Q by several per cent —
the same order as the difference the measurement is looking for, which is 0.742
against 0.8, or 5.7% overshoot against 8.1%.

If a DIP part is wanted anyway, the specification above is the test to apply.
Check current stock rather than this list, which will rot:

| Part | GBW | Verdict |
| --- | ---: | --- |
| MCP6024, MCP6294 | 10 MHz | CMOS, rail to rail, PDIP-14 — near enough equivalent |
| MCP6004, LMC6484 | 1 – 1.5 MHz | fine for checking the wiring and for the compensation trim; not for Q |

The cheapest correct answer is the adapter. SOIC-14 is 1.27 mm pitch and easier
to solder by hand than the SOT-23 and VSSOP-10 parts already on this list. If
you would rather prove the wiring before committing, an MCP6004 does that and
the compensation trim happily, and then comes out.

## What a breadboard can and cannot tell you

**It can:**

- the Sallen-Key's real corner and Q against the calculated 40.2 kHz and 0.742,
  which is set by the capacitors you actually bought
- whether the gain stage does ×1 and ×4.745 to the accuracy your resistors allow
- noise, and whether the whole path behaves at all

**It cannot:** give you the compensation setting. `C1`/`TC1` work against the
stray capacitance at the divider node — the target is `C_node / 14.96` — and a
breadboard's stray is both larger and less predictable than a PCB's, which is
why the trimmer here has more range than the one on the board and the fixed
capacitor beside it is smaller. Trim it flat on the breadboard to prove the
method, then **trim it again on the first real board**, where the number will be
different.

It cannot tell you whether the *board's* trimmer window is wide enough either,
and worse, it will look as though it can. A breadboard's larger stray pushes the
answer **up**, into the window, so it trims happily even from a board that could
not. That window has to be got right by arithmetic before fabrication rather
than by measurement after it — which is what moved `C1` from 6.8 pF to 5.6 pF.
See [`../README.md`](../README.md#adjusting-the-compensation).

## Measuring

The Pico's own calibration output (GPIO22 through `R35`, 100 Hz to 100 kHz) is a
square wave, which is the right signal for the compensation trim: adjust `TC1`
until the corners are square, with no overshoot and no sag.

For the filter you want a sine sweep and something to measure amplitude with,
which the Pico cannot generate. Failing a function generator, the step response
to that same square wave gives you Q from its overshoot. A two-pole section at
the calculated **Q 0.742 overshoots by 5.7%**; at **Q 0.8 it is 8.1%**, and at
Butterworth's 0.707 it is 4.3%. Those are far enough apart to tell by eye which
one you built.

Do not measure this channel with PiLyzer itself while it is the thing under
test: its own front end and its own anti-alias filter are in the path you are
trying to characterise.

## Resistor tolerance

The PCB calls for 0.1% on `R7`, `R8`, `R17` and `R18` because those set the gain
and the mid rail. On a breadboard 1% parts are fine **as long as you measure
them** and work the expected gain out from what you measured rather than from
what the label says. You are checking that the circuit behaves as designed, not
that a resistor is what it claims to be.

The Sallen-Key pair `R5`/`R6` must be equal to each other more than they need to
be 2.67k — measure a handful and pick the closest pair.
