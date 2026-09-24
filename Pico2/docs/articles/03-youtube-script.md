# Episode 3 — "A board someone else designed, and the bug it still has"

A Pico 2, a picoLABO PL2407AFE, a BNC cable. Target **9–10 minutes**.

Episodes 1 and 2 built the front end from nothing: one op amp, no protection,
no range, honest about both. This episode is the other half of that honesty —
what it looks like to bring up a board *someone else* designed, one with real
protection and three switched ranges, and to say on camera exactly which part
of it doesn't work yet rather than editing around it.

The spine: **protection has to sit ahead of anything software controls, not
behind it** — this board's input divider is fixed and in front of the range
switch, so a wrong range selection can never remove headroom the input
doesn't have — and **calibrating a range you can't reach directly by
borrowing a range you can**, which is what turns a multimeter that stops at
two decimals into a measurement good to four.

**Thumbnail** — the PL2407AFE on the bench, BNC cable in, the Mac app beside
it showing the range menu open (±30 V / ±6 V / ±1.5 V). Words: **PROTECTED**
large, "Pico 2 · PiLyzer #3" small.

Items marked **[MEASURE]** are numbers the bench has not produced on this
take yet — the board_config.h values already exist from the 2026-09-22
bring-up, so most of these are re-confirmations, not unknowns. Items marked
**[CONFIRM]** are places where a shot needs to actually show what the text
here claims it shows. Every number the narration says must come off the bench
on camera; if one will not, cut the line, not the honesty.

---

## Cold open — 0:00

> **On screen:** the mini AFE from episode 2, still on the breadboard, input
> lead touching nothing. Cut to the PL2407AFE, BNC cable already connected to
> a bench supply or battery pack.

Two episodes ago, this — [gesture at the breadboard] — had no protection. Keep
the input outside zero to three point three volts and it was fine. Go past it
and there was nothing between the signal and the chip.

This board is built for the case that breaks that promise.

> **On screen:** the Mac app, range menu open on CH1: ±30 V, ±6 V, ±1.5 V.

Three ranges, switched from software, on a board I did not design —
[picoLABO's](https://picolabo.org/pl2407afe/) PL2407AFE. Today: what
protection actually costs, how you calibrate a range a multimeter can't
reach, and the one thing on this board that still doesn't work, live, on
camera.

---

## Why this is a different problem — 0:25

> **On screen:** the "no protection, no attenuation" card from episode 2's
> ending, then a card: a fixed divider, then a switch, then a gain stage.

Episode two's front end had no attenuation, so the range it read was the
converter's own range — zero to three point three volts, gain one. That is
fine for a function generator. It is not fine for a twelve-volt battery, a
relay coil's back-EMF, or a car's accessory rail.

Once a board attenuates, a new failure shows up: what happens if the range
you *ask* for doesn't match the signal you *give* it? If the attenuation lived
after the range switch, picking the wrong range could remove headroom the
input needs. This board doesn't let that happen — the attenuator is fixed,
first, in front of everything else, and the range switch only changes what
happens *after* the signal has already been cut down to size.

> **On screen:** the manufacturer's schematic (linked in the description),
> the input divider highlighted.

The BNC sees a fixed **940 kΩ** on the way in, every range, no exceptions.
What changes downstream is a series resistor and a gain stage — 24.23 kΩ,
4.23 kΩ, or 330 Ω, one of three, selected by two GPIO lines per channel.

---

## What survives at the input — 1:30

> **On screen:** a card with the numbers below; the BNC connector in close-up.

picoLABO's own number: **plus or minus forty volts, absolute maximum, at the
BNC, regardless of range.** That number is not something this episode
measures — applying forty volts to find out where it stops being true is not
a shot worth having — so what follows is arithmetic, not a bench reading, and
the narration says so.

At forty volts, that 940 kΩ passes about forty-three microamps — nothing a
resistor notices. What forty volts
does move is the voltage *after* the divider, the point the switch and the
op amp actually see: **about four and a half volts**, on parts built for
three point three. The absolute maximum isn't a current limit. It's the
point where the divider stops being able to keep the back end inside its own
supply.

> **On screen:** a card comparing this board to episode 2's mini AFE and to
> the self-designed rev A front end (README table).

For scale: the [rev A design](../../hardware/pilyzer-afe/README.md) waiting
on a PCB run takes a **one-megohm** input to a continuous **hundred-volt**
rating — four times the headroom, a different set of tradeoffs, a different
episode. This board's forty volts is not a small number. It is a number with
a job: cover what actually shows up on a bench — batteries, low-voltage
automotive, small motors — without pretending to cover mains.

---

## Calibrating a range you can't reach — 2:45

> **On screen:** four AA batteries in a holder, a multimeter reading them, the
> Mac app's Calibrate panel for CH1's ±30 V range.

Two points make a line: zero volts, and one known voltage. Four dry cells in
series read [MEASURE] on the meter — call it five volts — read into the
±30 V range, and that's gain and offset for that range, done.

> **On screen:** the ±1.5 V range selected; the same four cells would pin the
> range, so cut to a single cell instead.

The ±1.5 V range can't take five volts — it would clip before it ever reached
mid rail. A single cell fits, but a meter that only reads two decimals turns
one and three tenths into a coin flip between one two nine five and one three
zero five: **plus or minus four tenths of a percent**, just from
rounding.

> **On screen:** switch that same single cell into the already-calibrated
> ±6 V range; read the number the *app* reports, not the meter.

Here's the trick: the ±6 V range is already calibrated against the five-volt
reading, so it's a better ruler for a small voltage than the meter is. Read
the same cell through it: **[MEASURE] volts** — a fourth significant figure
the meter never had. Use *that* number to calibrate ±1.5 V, and the only
error that survives is whatever error the five-volt reading carried in the
first place — about a fifth of a percent, twice as good as trusting the
meter directly on the small cell.

> **On screen:** a card: the ±30 V range's gain from the five-volt read and
> from the one-point-three-volt read, side by side.

The check on all of this: measure the *same* ±30 V range two ways — once
against five volts, once against one point three — and see if it agrees with
itself. It does, to **[MEASURE, expect ~0.03%]**. That's the linearity
promise a two-point calibration is quietly making, confirmed rather than
assumed.

---

## Bringing it up — 4:30

> **On screen:** the board on the bench, a multimeter probing the GND / VBUS
> / +3V3 / −3V3 test lands at the edge of the board.

Before any of that, the board had to actually turn on. Both op amps and the
analogue switches here run on plus and minus three point three volts, made
on-board from the Pico's own five-volt USB rail — so the first check on any
new board like this isn't a signal, it's **is minus three point three volts
actually there**.

> **On screen:** the +3V3 land reading something that is not 3.3 V.

It wasn't. The land read **[MEASURE, ~2.2 V]** — not zero, not three point
three, a voltage with nowhere honest to come from. That in-between reading
*is* the diagnosis: a regulator output is one of two numbers, on or off. What
was actually happening was the whole board floating on leakage current back
through the Pico's own GPIO and ADC protection diodes, because the real power
line — VBUS, into pin 40 — had a cold joint.

> **On screen:** the reflowed joint; the same land now reading 3.3 V cleanly.

Reflow the joint, and the rest of the board came up on its own — nothing
downstream was actually broken, it had just never been powered correctly.

> **On screen:** CH1 stuck reading ±30 V-shaped numbers with ±1.5 V selected.

One more, smaller: CH1's ±1.5 V range didn't respond, while CH2's did. Traced
to GPIO2 — the range-select line for CH1 — not reaching the switch chip's
pin, a second cold joint, this time at a socket. Fixed the same way.

---

## The bug that's still here — 5:45

> **On screen:** live, CH1's range menu; select ±6 V; the reading does not
> move.

This one isn't fixed, and it's staying on screen rather than being cut
around. Select CH1's ±6 V range, live: [CONFIRM — the reading stays parked on
±30 V-range numbers].

> **On screen:** a probe on GPIO3 at the header and at the switch chip's own
> pin, showing the same clean logic swing at both ends.

The control side is not the problem — I checked. GPIO3 swings cleanly between
zero and **[MEASURE, ~3.27]** volts, and that swing reaches the switch chip's
own pin; a probe at the header and a probe at the chip agree. The chip is
being told to switch. It isn't switching — at least, not that one path inside
it.

> **On screen:** a card: four switches in the package, three work, one
> doesn't; a note about the period the board ran on a dead ±3.3 V supply.

One theory, not a confirmed cause: this same chip spent time energized with
signal on its inputs while its own supply was the half-dead 2.2-volt state
from the VBUS fault — exactly the condition that can forward-bias a CMOS
switch's internal protection diodes. One of its four independent switches
failing, and not the other three, is consistent with that story. It is not
proof. Swapping the part would tell us; this episode doesn't do that, on
purpose — a board with one known, written-down fault is more honest than one
quietly reworked between takes.

CH2's ±6 V range works. CH1 falls back to reading its ±30 V circuit no matter
what the menu says, and that's exactly what the numbers in this board's
config file already say plainly: one range on one channel came from a
measurement that couldn't be taken.

---

## What it will not do — 7:45

> **On screen:** a card: no isolation; absolute maximum is not a working
> limit; can't read mains.

No isolation — this board's ground is the Mac's USB ground, full stop.
Forty volts absolute maximum is not a comfortable ceiling to work at; the
±30 V range only has about a third more headroom above it, and that has to
absorb a relay's back-EMF or a rough power-up, not just the number on the
dial. And a hundred-volt mains reading, peak, is three and a half times the
absolute maximum — this board does not do that, ever, on any range.

> **On screen:** the J1 header, a resistor lead pushed into it rather than a
> loose wire.

One mechanical note, because it cost real time on the bench: thin wire does
not make contact in this header's sockets. A resistor's own lead, or a pin
header, does.

---

## What is next — 8:45

> **On screen:** [CONFIRM — whatever the next board or build actually is].

[CONFIRM — this section needs a real answer before it's recorded: is the next
episode rev A's own PCB once it's back from fab, the one-range classroom
build, something else? Do not record a promise this project hasn't decided
on yet.]

---

## Production notes

- **Board identity.** picoLABO PL2407AFE, hardware rev.1d (silkscreen),
  Raspberry Pi Pico 2 serial `9B5C456F3E8EAF87`, firmware 1.16, board ID 3.
  Manufacturer's published schematic covers rev.1c; the power architecture is
  unchanged in 1d. Two analogue channels, no CH3 on this board. AC/DC coupling
  is a physical switch on the board, not software.
- **Ranges and pins.** CH1 range control: GPIO2/GPIO3. CH2: GPIO4/GPIO5.
  Encoding per channel, A/B: `00` = ±30 V, `01` = ±6 V, `10` = ±1.5 V. The
  firmware returns to `00` before changing ranges so the two bypasses are
  never both live at once.
- **Input protection, calculated, not measured on the bench (say so on
  camera):** BNC sees 940 kΩ direct, ahead of the range switch, on every
  range. At ±40 V (the manufacturer's absolute maximum): ~43 µA into the
  divider, divider node at ~4.53 V. The 120 kΩ leg's exact role (shunt vs.
  reference) is unconfirmed; either way the BNC's 940 kΩ figure holds. Above
  the rated ±40 V, the failure mode is believed to be the downstream op amp
  or analogue switch's own input protection diodes conducting — quiet, not a
  burnt resistor — consistent with a 5 V-rail part's absolute maximum input
  (V+ + 0.3 V ≈ 5.3 V) being reached around 47 V at the divider's ratio.
  **None of this paragraph is a bench measurement; do not let the narration
  imply it is.**
- **Comparison numbers for the "what survives" card:** rev A (self-designed,
  PCB not yet built): 1.06 MΩ in, ±25 V / ±5 V switched, continuous 100 V
  rating, momentary 200 V. PL2407AFE: 940 kΩ (+120 kΩ leg) in, ±30/±6/±1.5 V,
  absolute max ±40 V, no stated continuous rating distinct from that max.
  Different design goals — say so, don't rank them.
- **Calibration, measured 2026-09-22** (`hardware/pl2407afe/README.md`,
  `board_config.h`). Four dry cells read 5.01 V on the meter (it alternated
  5.01/5.02, ~0.2% uncertainty, the dominant error in every figure below).
  Two-point cal (0 V and the cell) per range:

  | Range | | Nominal | Measured |
  | --- | --- | ---: | ---: |
  | ±30 V | gain | 0.043395 | CH1 0.043974 / CH2 0.044140 |
  | | offset | 1.577207 V | CH1 1.586325 V / CH2 1.582325 V |
  | ±6 V | gain | 0.212277 | CH2 0.214483 (CH1's switch does not close) |
  | | offset | 1.597473 V | CH2 1.602975 V |
  | ±1.5 V | gain | 0.880411 | CH1 0.882035 / CH2 0.878957 |
  | | offset | 1.677649 V | CH1 1.681950 V / CH2 1.684700 V |

  `board_config.h` stores one table per board (mean of CH1/CH2, the ~0.5%
  channel-to-channel spread is left to the apps' per-channel gain
  correction), except ±6 V, which is CH2 alone.

  **The ±1.5 V range's cell was 1.3 V nominal, meter-limited to two decimals
  (±0.4% uncertainty).** Read through the already-calibrated ±6 V range
  instead: the app reported **1.3078 V**. Using that instead of the meter's
  1.30 V halves the propagated uncertainty to about ±0.2%, inherited entirely
  from the original 5.01 V reading. This only works because the circuit is
  linear across the ranges — confirmed separately (next point).

  **Linearity check:** the ±30 V range's gain, computed from the 5.01 V
  reading and from the 1.3 V reading independently, agreed to **0.03%**.

  **One coincidence worth keeping honest on camera:** the ±30 V range's
  measured gain and the value calculated from nominal resistor values agree
  to **0.010%** — twenty times tighter than the ±0.2% measurement
  uncertainty, i.e. statistically indistinguishable. This does *not* mean the
  board needs no calibration; it means this one range's resistors happened to
  land close to nominal. The other two ranges did not (±6% gain error at
  ±6 V, 0% at ±1.5 V rounding) — scattered enough, and inconsistent with a
  single shared cause like the ADC reference, that per-resistor tolerance is
  the better explanation than a systematic offset.
- **Bring-up faults, both fixed 2026-09-22:**
  1. Pico 2 physical pin 40 (VBUS) — cold solder joint. Both on-board ±3.3 V
     rails depend on VBUS, so both died together; the board free-floated at
     ~2.2 V through the RP2350's own GPIO/ADC clamp diodes. The op amps'
     outputs pinned to the positive rail; the ADC read ~2.22 V / ~0.66 V.
     **The diagnostic tell to say on camera:** a regulator output reading
     neither a clean logic level nor zero is the sign of missing power, not
     a downstream fault — check power again before debugging further
     downstream.
  2. GPIO2 (CH1's range-select line) not reaching switch IC pin 6 (`3S`) —
     cold joint at a socket. Symptom was narrow: only CH1's ±1.5 V range was
     unreachable; CH2 and CH1's other range were fine.
- **Known open fault, not fixed on camera, on purpose:** CH1's ±6 V range
  (switch element 4, pins 12–13 on the switch IC, `U2`) never closes.
  Control side confirmed good: GPIO3 measured a clean 0 V / 3.27 V swing both
  at the header and at the chip's own pin. Selecting ±6 V on CH1 leaves the
  channel reading its ±30 V circuit with no change, down to 0.1 mV. Cannot
  distinguish an internal switch failure from an unprobed adjacent-pin solder
  fault on the TSSOP package without removing the part, which this episode
  does not do. Working theory, explicitly labeled as unconfirmed on camera:
  this switch's supply pins sat at the abnormal 2.2 V / 0 V split during the
  VBUS fault while a signal was already present at its inputs — a condition
  that can forward-bias a CMOS switch's own protection diodes — which would
  explain why one of the four independent switches in the package failed and
  the other three did not.
- **Open-input readings, unpowered signal, 2026-09-22 (not yet re-confirmed
  on this episode's own take — re-measure before quoting on camera):**

  | Range | CH1 | CH2 | Nominal offset |
  | --- | ---: | ---: | ---: |
  | ±30 V | 1.5864 V | 1.5827 V | 1.5772 V |
  | ±6 V | 1.5864 V (not switching) | 1.6032 V | 1.5975 V |
  | ±1.5 V | 1.6830 V | 1.6861 V | 1.6776 V |

- **Mechanical note:** J1's header sockets need a solid pin (a resistor lead,
  a header pin) — thin single-strand wire and female jumper contacts do not
  reliably seat in the socket's spring contact, even though the schematic
  shows the relevant GND pins (2/4/6) common and continuous on the back of
  the board.
- **What's genuinely undecided:** the "What is next" section. Do not record
  it until the next build is real — this project's own rule, kept from
  episodes 1 and 2, is that nothing on screen gets ahead of the bench.
- **Style continuity with episodes 1–2:** keep the "screen tells you what it
  saw, not what's wrong" framing for the CH1 ±6 V bug — same posture as
  episode 2's two clipping failures. Keep numbers in the narration to what a
  viewer needs to follow the story; the rest belongs here.
