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

> **On screen:** a 100 kΩ divider from 3.3 V to ground, going to two channels
> at once — one straight to a converter pin, one through the follower. Both
> cards on screen together.

Here is the sip, made visible. A divider of two hundred-kilohm resistors sits
at one point six five volts.

Through the follower, the instrument reads **one point six four**, and it sits
there.

Straight into the converter, the same node reads **one point six two** — twenty
millivolts low — and it is noisier with it: seventy-three millivolts peak to
peak against twenty-seven.

Twenty millivolts is one and a bit per cent, on a divider that is exactly
right. The converter takes a sip of charge every time it samples, and fifty
kilohms cannot put it back before the next one.

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
hard to drive by how much it is loaded. Apple's own published ceilings: under
a hundred fifty ohms, one and a quarter volts RMS; from there to a kilohm,
three volts RMS — already past the converter's whole range. Left to itself,
looking at fifty kilohms, this channel sits past both brackets, driven as a
line input. A hundred ohms across the plug drops it under a hundred fifty
ohms, headphone territory, and the music we actually play into it stays well
under that ceiling — it lands inside the range with room to spare.

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

> **On screen:** `Shots/Clipped.png`, the screenshot from the evening it
> happened: the trace on the zero line with its bottom flattened, Mean
> 324 mV, and CLIP in the legend. Push in on the plot, then on the readings.

The first one: the audio went into the direct channel. That half has no
capacitor and no divider — it is a follower and nothing else — so a signal
centred on zero arrives centred on zero, and everything below the line is gone.

> **On screen:** stay on the same screenshot — the picture is the same for
> both faults, which is the point. Cut to the breadboard for where the 100 Ω
> was.

The second one is better, because the circuit was right. The hundred ohms that
tells the jack it is driving headphones had gone in on the wrong side of the
coupling capacitor — across the op amp's input instead of across the plug. A
hundred ohms against the divider's fifty kilohms wins, and it pulls mid rail
down to nothing. Same picture. Bottom half gone.

> **On screen:** the bench, live: unplug and the bias reads 1.65 V again,
> plug in and it collapses.

And that is how you tell them apart without a meter: **unplug the source and
watch the bias**. If it comes back to one point six five and collapses when you
plug in, the source is dragging the bias, not the circuit failing to make it.

> **On screen:** `Shots/ClippedRepaired.png` — the trace centred on the
> dotted line, Mean 1.67 V, 1.45 V peak to peak, no CLIP. Cut the two
> screenshots against each other; they are the same window, so they register.

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

- **Everything demonstrated must be real.** One number above is
  **[MEASURE]** and one detail is **[CONFIRM]**, both in "The resistor I got
  wrong." Measure them on camera before recording the narration, and change
  the words to match what the bench says. (The headphone-jack peak to peak
  was the other [MEASURE]; closed 2026-09-22.)
- **Measured already:** MCP6022 output 3.30 V pp from the raw carrier; through
  1 kΩ + 10 nF, 3.15 / 3.12 / 2.95 V pp at 440 Hz / 1 kHz / 5 kHz; LM358 output
  stops about 1.5 V below the rail, so ~1.8 V on 3.3 V.
- **The follower section, measured 2026-09-21** on a 100 kΩ / 100 kΩ divider
  read by two channels at once, gain corrections cleared:

  | | Mean | AC RMS | Peak to peak |
  | --- | ---: | ---: | ---: |
  | through the follower | 1.64 V | 2.69 / 3.09 mV | 20.1 / 26.6 mV |
  | straight to the pin | 1.62 V | 4.59 / 7.94 mV | 25.8 / 73.3 mV |

  Two passes with the channels swapped between them, so the figures follow the
  path and not the channel: 1.64 V stayed with the follower and 1.62 V with the
  direct pin both times. Say "twenty millivolts low" and "noisier"; do not
  quote the peak-to-peak spread as a fixed number, it moves from sweep to
  sweep.
- **From the simulator, not the bench:** both channels 1.999 V pp for a 1 V sine,
  and both 1.720 V pp at 20 kHz. Do not say these as measurements unless the
  bench repeats them.
- **The signal source is the Mac mini's front 3.5 mm jack**, which sets its
  level from the load it detects. Apple's own figures
  ([support.apple.com/ja-jp/108351](https://support.apple.com/ja-jp/108351)):
  under 150 Ω, a ceiling of 1.25 V RMS; from 150 Ω to 1 kΩ, a ceiling of
  3 V RMS (8.5 V peak to peak — already past both rails). The page does not
  give a figure above 1 kΩ. The AC channel alone looks like 50 kΩ, past both
  brackets, so it would be driven as a line output — at least as loud as the
  3 V RMS bracket below it, likely louder. **Put 100 Ω across the plug** (tip
  to sleeve, ¼ W is plenty at 10 mW): the jack then reads under 150 Ω,
  headphone territory, ceiling 1.25 V RMS ≈ 3.54 V peak to peak. At the volume
  this episode actually uses the real swing sits well under that ceiling and
  lands inside the range with room to spare. **The shoot's volume is fixed at
  −18 dB on the display** (see below); watch the trace and turn it down if
  the top flattens.

  **Measured 2026-09-22, same recording, full volume, three loads:**

  | Load | Peak to peak |
  | --- | ---: |
  | 100 Ω | 1.24 V |
  | 460 Ω | 1.05 V |
  | none (open) | 1.31 V |

  None of the three come near a rail (0.82–1.31 V from centre at most).
  Crossing into the 150 Ω–1 kΩ bracket did not raise the level — if anything
  it dropped — and removing the resistor entirely, which should read as a
  line output past both Apple's brackets, landed *between* the other two
  rather than above them. So the ceiling table does not predict this jack's
  actual level at a fixed volume position; whatever curve it follows is not
  monotonic in the load. Still no measurement above 1 kΩ with a real resistor
  in that bracket.

  One data point on the volume knob itself, open plug, about 20 %: 34 mV peak
  to peak against 1.31 V at full volume — a fortieth, not a fifth. Whatever
  curve a line output follows down from full volume is steeper than the
  volume position alone would suggest.

  **Measured 2026-09-22, 100 Ω fitted, volume at −30 dB on the display:
  37 mV peak to peak** (t=149 s of a 202.5 s pass, ±19/−18 mV about centre).
  Thin on screen — about 1 % of the 0–3.3 V range — so 12 dB more was tried.

  **Measured 2026-09-22, 100 Ω fitted, volume at −18 dB — the shoot's
  final condition, closing the MEASURE above: 194 mV peak to peak**
  (t=174 s of a 203.5 s pass, +102/−92 mV about centre, both well inside the
  rails: 1.54–1.57 V of room on either side). At 50 mV/div that is about
  3.9 divisions of an 8-division screen — comfortably visible, not filling
  it. 12 dB should scale voltage ×3.98 by the textbook; it came out ×5.27
  (37 → 194 mV), the closest any volume-or-load comparison this session came
  to matching its prediction, but still not exact — expect the same kind of
  gap if this gets pushed further. Do not carry the "fills the screen"
  framing from the plan into the edit; "about 40% of the screen" is what the
  capture supports.
- **Capacitors:** use film for the generator's 10 nF — the old ceramic 103 from
  the parts bag left ±0.5 V spikes on the sine in episode 1's shoot.
- **Firmware 1.13** on every board. Nothing in this episode touches the logic
  pins, but the pinout card must say GPIO26/27 for CH1/CH2.
- **Both failures in "Two ways to lose the bottom half" really happened**, on
  2026-09-20, and the screenshots are kept as `Shots/Clipped.png` (Mean 324 mV,
  780 mV pp, CLIP) and `Shots/ClippedRepaired.png` (Mean 1.67 V, 1.45 V pp,
  centred on the dotted line). **The screenshots are what goes in the edit** —
  they are the evening it happened, not a re-enactment. Both are 1808×1265, so
  crop to 16:9 around the plot and the readings; the second one carries
  Position −3.3 div, which the legend prints, so either crop it out or leave it
  and say nothing. Only the unplug-and-watch-the-bias beat is shot live.
- **Shot list worth having ready:** the tone on the mid-rail line; the
  parts on white; the divider read direct and through the follower; the LM358's
  flat top; the MCP6022's whole sine; the bias line landing on CH2; the two
  resistors' colour bands; the readings against the arithmetic; the simulator.
- **Do not show credentials, serial numbers, or the Wi-Fi SSID.**
