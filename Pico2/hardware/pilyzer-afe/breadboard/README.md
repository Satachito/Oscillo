# One channel on a breadboard

Everything in [`bom.csv`](bom.csv) builds **one** analogue channel of the AFE,
because every measurement in "Before fabrication" is a per-channel measurement.
Three channels on a breadboard would cost three times as much and tell you the
same thing three times.

The PCB bill of materials next door is 0805 and SOIC. This one is through hole
wherever a through-hole part exists, and names the adapter where none does.

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

## Changing range by hand instead of fitting the switch

`U2A` selects the range by connecting the far end of `R8` either to VMID or to
nothing:

| Range | `U2A` | Gain | On the breadboard |
| --- | --- | ---: | --- |
| ±25 V | COM–NC, so `R8` goes nowhere | 1 | **take `R8` out** |
| ±5 V | COM–NO, so `R8` goes to VMID | 4.745 | `R8` in, far end wired to VMID |

**PiLyzer Lite has no switch**, and its one ±15 V range is this same circuit
with `R8` at 15 kΩ wired permanently to VMID. Building that instead is a change
of one resistor; everything measured here — the compensation, the filter, the
clamp — is identical either way.

That is exactly the two states, and it works because the switch sits at VMID on
both sides on the real board and so never sees a signal swing.

**Pull `R8` out rather than leaving one end dangling.** Its other end is on the
amplifier's inverting input, which is a high-impedance summing node; a free wire
there is an aerial, and a breadboard's is a much better one than a PCB trace. An
empty pair of holes is what "connected to nothing" is supposed to mean.

**Keep the application's range selection matching the wire.** The host sends
`setRange` to GPIO16, which with no switch fitted drives nothing at all — but it
still applies that range's gain and offset to everything it reads. Choose ±5 V
in the panel with `R8` out and every number will be wrong by the ratio of the
two ranges, with nothing on screen to say so. If that is a trap you would rather
not step in, hang an LED and a resistor off GPIO16: lit means the application
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
for the absolute gain figure and for nothing else: the frequency response, the
filter's Q and the clamp's leakage are all unaffected. Fit the real part when
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

The bandwidth and the bias current are not preferences. **The filter's Q and the
clamp's leakage are measurements of the amplifier as much as of the circuit
around it**, so substituting it quietly defeats the point of making them.

The divider node's source impedance is 62.5 kΩ — 125k, 143k and the 998k input
in parallel. Input bias current flows through that:

| Input stage | Bias current | At the node | In converter counts |
| --- | ---: | ---: | ---: |
| CMOS, as specified | 10 pA | 0.6 µV | 0.00 LSB |
| **the clamp leakage being measured** | **1 nA** | **62.5 µV** | **0.08 LSB** |
| an ordinary bipolar input | 45 nA | 2813 µV | 3.49 LSB |

A bipolar-input part buries the nanoamp it is supposed to reveal under forty-five
of its own. Checking the clamp diodes at temperature stops being possible.

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
- the clamp diodes' leakage, including warmed up — a nanoamp through the bias
  legs is already visible on the ±5 V range
- whether the gain stage does ×1 and ×4.745 to the accuracy your resistors allow
- noise, and whether the whole path behaves at all

**It cannot:** give you the compensation setting. `C1`/`TC1` work against the
stray capacitance at the divider node, and a breadboard's stray is both larger
and less predictable than a PCB's — which is why the trimmer here has more range
than the one on the board and the fixed capacitor beside it is smaller. Trim it
flat on the breadboard to prove the method and the range, then **trim it again
on the first real board**, where the number will be different.

## Measuring

The Pico's own calibration output (GPIO20 through `R35`, 100 Hz to 100 kHz) is a
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
