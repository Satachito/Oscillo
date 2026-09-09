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

## The analogue switch is optional at first

`U2A` selects the range by connecting `R8` either to VMID (fine) or to nothing
(coarse). On the board it sits at VMID on both sides, so it never sees a signal
swing; the design notes put its contribution at a fixed **0.2%** of gain, which
calibration removes.

So for the first measurements a **wire link stands in for it**: link `R8` to
VMID for the ±5 V range, lift it for ±25 V. That is exactly the two states, to
within the 0.2% the switch adds. Fit the real part when you want the gain
figure to be the board's rather than the breadboard's — and buy the adapter now
either way, since you will want it eventually.

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
