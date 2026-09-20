# Episode 2 — "One op amp, and a Pico can hear audio"

A Pico 2, one MCP6022, a handful of parts on a breadboard, and the Mac app.
Target **9–10 minutes**.

Episode 1 ended on a promise: most things you want to measure swing about zero
volts, a bare Pico cannot see them at all, and next time one op amp, a coupling
capacitor and two resistors would fix that. It also promised two stories — the
op amp tried first that could not do it, and the resistor got wrong that cost
an afternoon — and that the instrument itself caught both. This episode keeps
all three promises and nothing else.

The spine: **a front end is two jobs — give the converter a low impedance, and
put the signal where the converter can see it** — and the mini AFE does one of
each, on the two halves of one dual op amp.

**Thumbnail** — the breadboard with the MCP6022 in focus, the Mac app beside it
showing a sine centred on the dotted mid-rail line. Words: **ONE OP AMP** large,
"Pico 2 · PiLyzer #2" small.

Items marked **[MEASURE]** are numbers the bench has not produced yet. Every
number the narration says must come off the bench on camera; if one will not,
cut the line, not the honesty.

---

## Cold open — 0:00

> **On screen:** the Mac app, CH2, a 1 kHz tone from the Mac mini's headphone
> jack, sitting on the dotted mid-rail line. Hold three seconds before the
> first word.

This is audio. It swings above and below zero volts.

Last time, a bare Pico could not see half of it.

> **On screen:** cut to the breadboard, the MCP6022 in focus.

This is what changed. One op amp, and a few parts that cost less than the
cable.

---

## The problem, again — 0:25

> **On screen:** the "0 – 3.3 V" card from episode 1, then the card of a sine
> swinging about zero with only its top half lit.

A Pico's converter reads zero to three point three volts. Audio, a function
generator, anything alternating — they spend half their time below zero, where
the converter sees nothing.

And there is a second problem nobody warns you about. The converter does not
just read a voltage; it takes a sip of charge every time it samples. Anything
that cannot supply that sip quickly reads low.

So a front end has two jobs. **Give the converter something stiff to drink
from, and put the signal where the converter can see it.** One op amp has two
halves. Each half does one job.

---

## What it is — 1:15

> **On screen:** the breadboard, top-down, then the schematic from the README
> drawn as a card: CH1 direct, CH2 through the capacitor and the divider.

An MCP6022. It is a dual, so there are two amplifiers in the one package.

The first is a **follower**: the input goes straight in, and the output copies
it. Gain of one. It changes nothing about the voltage — what it changes is who
does the work. Whatever you are measuring now drives a few picoamps into the op
amp, and the op amp drives the converter.

The second half does the same, but its input comes through a **capacitor and two
hundred-kilohm resistors**. The resistors hold that point at mid rail — one
point six five volts — and the capacitor lets only the swing through. So a
signal centred on zero comes out centred on one point six five, and the whole
of it fits.

On each output there is a kilohm and four point seven nanofarads. That is not
an anti-alias filter; one pole is not enough for that. It is there so the
converter's sampling capacitor never hangs directly on an op amp's output,
which is the kind of load that makes some amplifiers ring.

> **On screen:** the parts laid out on white before they go in: the DIP-8, two
> 100 kΩ, two 1 kΩ, two 4.7 nF, one 1.5 µF, one 100 nF.

That is the whole parts list.

---

## Why a follower at all — 2:15

> **On screen:** a 100 kΩ divider from 3.3 V to ground, tapped to CH1 directly;
> then the same tap through the follower. The readings side by side.

Here is the sip, made visible. A divider of two hundred-kilohm resistors should
sit at one point six five volts.

Straight into the converter, with a second channel running, it reads
**[MEASURE: direct reading]** — and it wanders.

Through the follower: **[MEASURE: follower reading]**. Still.

The converter wants whatever feeds it to look like **less than ten kilohms**.
A follower looks like almost nothing, and never runs out of charge.

---

## The op amp I tried first — 3:05

> **On screen:** the LM358 in the socket. The generator's sine through it, the
> top of the trace flattened.

The first op amp in that socket was an LM358, because every drawer has one.

And the instrument showed me the problem immediately. Look at the top of the
trace. Flat.

An LM358's output cannot get closer than about one and a half volts to its
positive supply. On three point three volts, that means it stops near **one
point eight**. Everything above that is gone — and one point eight is barely
past the middle of the range.

> **On screen:** swap in the MCP6022. The same sine, whole.

The MCP6022 is **rail to rail**, input and output. Driven with the generator's
raw carrier, its output swung **three point three zero volts peak to peak** —
the entire supply.

The part number is the one choice in this circuit that is not free. If you
substitute, the one thing to check is those two words: rail to rail.

---

## The AC channel — 4:05

> **On screen:** the Mac playing a 1 kHz tone into CH2. The sine centred on
> the dotted line. Then music; the trace dancing around the line.

Now the Mac's own headphone jack. Its output swings about zero, and through the
second half it arrives centred on mid rail.

> **On screen:** the 100 Ω resistor across the plug, in close-up.

One detail, because it is the kind of thing that bites. This jack decides how
hard to drive by how much it is loaded. Left to itself, looking at fifty
kilohms, it calls that a line input and sends three volts RMS — more than the
converter's whole range. A hundred ohms across the plug tells it there are
headphones on the end, and it settles for one volt RMS. Which is two point
eight volts peak to peak, and lands inside the range with room to spare.

> **On screen:** the Bias field for CH2 set to Mid rail; the dotted line lands
> on the trace's centre.

And this is where last episode's decision pays off. The reading is still the
volts the converter saw — one point six five plus the audio. I tell the panel
the bias is at mid rail, it draws the dotted line there, and zero is wherever
the line is. Nothing has been subtracted behind your back.

> **On screen:** the numbers as a card: 100 kΩ ∥ 100 kΩ = 50 kΩ; 1.5 µF → 2.1 Hz.

Two hundred-kilohm resistors look like fifty kilohms to the signal. With one and
a half microfarads, anything above about **two hertz** gets through.

Fifty kilohms is also the price. A function generator or a headphone output
does not notice it; a sensor or a high-value divider would. So high-impedance things go
on the first channel, the plain follower, where the load is picoamps.

That value was not my first choice, either. It started at a megohm a side, and
the AC channel went soft from about ten kilohertz, while the direct one did
not. At a hundred kilohms, the two channels fall off together.

---

## Two ways to lose the bottom half — 5:10

Both of these happened to me while making this, and the screen said so both
times. They are worth two minutes because the symptom is identical, and it is
not the symptom you would guess.

> **On screen:** audio into CH1 — the direct channel. The trace sits on the
> zero line with its bottom flattened. Mean reads about 0.3 V, and the legend
> says CLIP.

The first one: the audio went into the direct channel. That half has no
capacitor and no divider — it is a follower and nothing else — so a signal
centred on zero arrives centred on zero, and everything below the line is gone.

> **On screen:** the same trace, then the 100 Ω moved from the plug to the
> op amp's input, showing the same flattened bottom.

The second one is better, because the circuit was right. The hundred ohms that
tells the jack it is driving headphones had gone in on the wrong side of the
coupling capacitor — across the op amp's input instead of across the plug. A
hundred ohms against the divider's fifty kilohms wins, and it pulls mid rail
down to nothing. Same picture. Bottom half gone.

> **On screen:** unplug. Mean goes back to 1.65 V. Plug in. It collapses again.

And that is how you tell them apart without a meter: **unplug the source and
watch the bias**. If it comes back to one point six five and collapses when you
plug in, the source is dragging the bias, not the circuit failing to make it.

> **On screen:** the 100 Ω back across the plug. The trace centred on the
> dotted line, 1.45 V peak to peak, no CLIP.

Put it back at the plug and the picture is what it should be: centred on the
line, a volt and a half of swing, and room for more.

The screen never told me what was wrong. It told me what it saw — which was
enough, twice.

---

## The resistor I got wrong — 7:10

> **On screen:** close-up of the two resistors side by side,
> brown-black-red and brown-black-yellow.

Brown, black, red is one kilohm. Brown, black, yellow is a hundred.

**[CONFIRM: which position]** was meant to be a kilohm. I fitted a hundred
kilohms. Everything still worked — the trace was there, it had the right
shape — it was just smaller than it should be at the higher frequencies, and
I spent an afternoon doubting the op amp.

> **On screen:** the spectrum, or the peak-to-peak readout stepping from 440 Hz
> to 1 kHz to 5 kHz, set against the numbers the arithmetic predicts.
> **[MEASURE: the readings with the wrong part, if it can be put back in for
> the shot; otherwise show the arithmetic against the corrected readings.]**

What caught it was not a meter. It was the instrument, reading the response
at a few frequencies, and the numbers refusing to match the arithmetic.

It happened twice. A capacitor marked one-oh-four — a hundred nanofarads —
had gone in where a one-oh-three belonged. Same symptom: the five kilohertz
reading came up short. With the right parts, the generator's sine through its
filter reads **three point one five volts at four forty, three point one two
at one kilohertz, and two point nine five at five**.

The lesson is the same as last time: when the number disagrees with the
arithmetic, believe the number, then go and find out why.

---

## What it will not do — 8:10

> **On screen:** a card: no protection; no attenuation; keep the input inside
> the supply.

It has **no protection**. There is nothing in front of the op amp but a
capacitor, or nothing at all, so keep the input inside the supply — zero to
three point three on the direct channel, and about plus or minus one and a
half volts on the AC one.

It has **no attenuation**. Gain is one, so the range is still the converter's
range.

And that is fine. It is a breadboard and an evening, and it turns a Pico that
cannot see audio into one that can.

> **On screen:** the Falstad simulator running the circuit, both channels.

If you would rather try it before you wire it, the whole circuit runs in a
browser simulator — the link is below.

---

## What is next — 8:40

> **On screen:** the rev A schematic or board render; then the picoLABO
> PL2407AFE, unsoldered.

Next: a front end that is protected, switches ranges, and reads plus or minus
twenty-five volts — and a board someone else designed, with calibration to
prove on camera.

> **On screen:** the Mac app, CH1 and CH2 running together.

The circuit, the parts list and the simulator link are below. If you built the
last one, this is the evening after.

---

## Production notes

- **Everything demonstrated must be real.** Three numbers above are
  **[MEASURE]** and one detail is **[CONFIRM]**. Measure them on camera before
  recording the narration, and change the words to match what the bench says.
- **Measured already:** MCP6022 output 3.30 V pp from the raw carrier; through
  1 kΩ + 10 nF, 3.15 / 3.12 / 2.95 V pp at 440 Hz / 1 kHz / 5 kHz; LM358 output
  stops about 1.5 V below the rail, so ~1.8 V on 3.3 V.
- **From the simulator, not the bench:** both channels 1.999 V pp for a 1 V sine,
  and both 1.720 V pp at 20 kHz. Do not say these as measurements unless the
  bench repeats them.
- **The signal source is the Mac mini's front 3.5 mm jack**, which sets its
  level from the load it detects: under 150 Ω it is a headphone output at
  1.0 V RMS, over 1 kΩ a line output at 2.0–3.0 V RMS. The AC channel alone
  looks like 50 kΩ, so it would be driven as a line output — 3.0 V RMS is
  8.5 V peak to peak, past both rails. **Put 100 Ω across the plug** (tip to
  sleeve, ¼ W is plenty at 10 mW): the jack then behaves as a headphone output,
  1.0 V RMS ≈ 2.83 V peak to peak, which on mid rail is 0.24–3.06 V — inside
  the range, and nearly filling the screen. Start at 20–30 % volume and watch
  the trace; if the top flattens, turn it down. **[MEASURE: the actual peak to
  peak at the volume used, and what it becomes without the 100 Ω — worth
  showing only if it stays inside the rails.]**
- **Capacitors:** use film for the generator's 10 nF — the old ceramic 103 from
  the parts bag left ±0.5 V spikes on the sine in episode 1's shoot.
- **Firmware 1.13** on every board. Nothing in this episode touches the logic
  pins, but the pinout card must say GPIO26/27 for CH1/CH2.
- **Both failures in "Two ways to lose the bottom half" really happened**, on
  2026-09-20, and the screenshots are kept as `Shots/Clipped.png` (Mean 324 mV,
  780 mV pp, CLIP) and `Shots/ClippedRepaired.png` (Mean 1.67 V, 1.45 V pp,
  centred on the dotted line). Re-stage them for the camera rather
  than using the screenshots, and keep the Position slider at 0 div for the
  takes — the legend calls it out otherwise.
- **Shot list worth having ready:** the tone on the mid-rail line; the
  parts on white; the divider read direct and through the follower; the LM358's
  flat top; the MCP6022's whole sine; the bias line landing on CH2; the two
  resistors' colour bands; the readings against the arithmetic; the simulator.
- **Do not show credentials, serial numbers, or the Wi-Fi SSID.**
