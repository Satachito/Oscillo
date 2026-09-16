# Episode 1 — "It shows you what the chip actually sees"

A Pico 2, a USB cable, a browser tab. Target **7–8 minutes**.

The spine of this one is a design decision, not a build: a bare Pico reads
0 to 3.3 V and nothing else, so what do you put on the screen? Everything else
in the episode is there to make that question land.

**Thumbnail** — the front panel with a trace on it, "PiLyzer" small, and the
words that carry it: **OSCILLOSCOPE / PICO 2**. A phone or a browser chrome
visible at the edge, so it reads as "no box" before anyone presses play.

---

## Cold open — 0:00

> **On screen:** a trace, already running. Nothing else. Hold three seconds
> before the first word.

No probe.

No signal generator.

Nothing installed — no driver, no app, no account.

> **On screen:** pull back. It is a Pico 2, one USB cable, and a browser tab.

That is a Raspberry Pi Pico 2, a USB cable, and a tab. The waveform is coming
from the chip itself.

I have been building this for a while, and there is one decision in it that
makes the screen look different from every other oscilloscope you have used.
That is what this video is about.

---

## What it is — 0:25

> **On screen:** click through the four modes as they are named.

PiLyzer. Three analogue channels, twelve bits. An oscilloscope, a spectrum
analyser, an eight-channel logic analyser, and a slow logger.

Two front ends, one instrument: a native macOS app, and a web page that talks
to the board over WebUSB. Same protocol, same numbers.

> **On screen:** the GitHub page, briefly. Do not linger.

All of it is open, and the link is below.

---

## The demo — 0:55

> **On screen:** do it for real. Plug in, open the page, press Connect, choose
> the device in the browser's chooser, press Run.

Plug the board in. Open the page. Connect — the browser asks which device, and
that is the only permission there is. Run.

> **On screen:** flat line. Let it sit for a beat. It should look boring.
> The RC is already wired; the generator is simply off, which is what makes
> the line genuinely flat rather than a floating pin picking up hum.

A flat line — nothing is driving that pin yet. So let us attach something —
without attaching anything.

> **On screen:** switch on Signal generator. The sine appears.

The firmware has a signal generator in it. A sine, and white, pink and brown
noise, on four pins of the board. Wire one of them back to an input and the
instrument measures itself.

> **On screen:** the sine, then switch to Spectrum and let the 440 Hz peak
> settle. Then Logic, then back.

Four hundred and forty hertz. There it is in the spectrum. And that is the
whole set-up cost: a board and a cable.

> **On screen:** the same page on an Android phone, on a USB-C cable.

Chrome on Android is a WebUSB host too, so this also runs on a phone. Same
page. No app.

---

## The catch — 2:20

> **On screen:** back to the scope, sine running. Then a still: "0 – 3.3 V".

Here is the problem I could not design my way around.

A Pico's converter reads zero to three point three volts. That is the whole
range. There is no negative side. There is no range switch, because there is
nothing in front of it to switch.

> **On screen:** a real oscilloscope's screen, or a drawing of one, with
> "±5 V", "1 V/div", the usual furniture.

A normal oscilloscope shows you volts at the probe tip. It knows what is in
front of it — an attenuator, a gain stage — so it can work backwards and tell
you what you actually connected.

A bare Pico knows none of that. So when the number on screen says one point
six five volts, what does it mean?

> **On screen:** the front panel, with the dotted bias line visible and the
> triangle at the edge.

I made it mean the one thing it can always mean: **this is what the converter
saw.** Not what I think you connected. Not a corrected number. The volts at
the pin.

If your circuit sits at mid rail — and most single-supply circuits do — the
trace sits in the middle of the screen, and the instrument draws that bias as a
dotted line instead of quietly subtracting it.

> **On screen:** toggle the bias line on a channel so the dotted line appears.

You can tell it where the bias is. It will draw it. It will not take it out.

Because a number that has been silently adjusted is a number you cannot check.
And on a home-made front end, the thing most likely to be wrong is the
adjustment.

> **On screen:** the gain correction note under a channel — "readings are
> scaled by it".

When there is a correction — when you have measured a known voltage and told
it the divider is two per cent low — it says so, as a percentage, on the panel.
Corrections you can see are corrections you can argue with.

That is the decision. Everything else follows from it.

---

## The test signal, and why it needs a resistor — 4:15

> **On screen:** the four generator pins on a pinout diagram, then a single
> wire from one of them to an input.

Back to that generator, because there is something worth knowing.

The RP2350 has no digital-to-analogue converter. So the sine is not a voltage.
It is a **pulse-width carrier at five hundred and eighty-six kilohertz**, whose
duty cycle follows a sine table.

> **On screen:** a wire straight from the pin to the input. The trace: a mess.

Wire that straight to an input and this is what you get. Garbage — because you
are sampling a square wave at half a megahertz with a converter running at a
few hundred kilohertz, and everything folds back on itself.

> **On screen:** add a resistor and a capacitor. The sine appears, clean.

One resistor and one capacitor — a kilohm and ten nanofarads — and it is a
sine. Three point one five volts peak to peak, which is what it is designed
to be.

That is a real lesson and not a detour: **a digital pin is never a voltage
until something has averaged it.**

---

## What it will and will not do — 5:45

> **On screen:** the rate readout as channels are enabled and disabled.

Numbers, honestly.

One channel: about **495 thousand samples a second**. Two: 247. Three: 165 —
they share one converter, so they share the rate.

Twelve bits across three point three volts, which is **eight hundred
microvolts a count**.

The logic analyser is eight channels at up to a hundred and fifty megasamples,
and it costs eight resistors and a header — which makes it, per yen, the best
thing on the board.

> **On screen:** a still frame listing the three limits.

What it will not do: it will not read a negative voltage, it will not read
anything above three point three volts, and it will survive neither. On a bare
Pico, that is the deal. There is nothing in front of the pin.

---

## What is next — 6:45

> **On screen:** a breadboard with the op amp on it, out of focus, teasing.

Which brings us to the next one.

Most things you want to measure swing about zero volts — audio, a function
generator, anything alternating. A bare Pico cannot see them at all.

So next time: one op amp, a coupling capacitor and two resistors, and a signal
that swings about zero becomes a signal a Pico can read. We will also talk
about the op amp I tried first that could not do it, and the resistor I got
wrong that cost me an afternoon — and how the instrument itself is what caught
both.

> **On screen:** the front panel again, running.

Link to the code below. If you have a Pico 2 sitting in a drawer, this is an
afternoon.

---

## Production notes

- **Everything demonstrated must be real.** Every number above is measured, and
  the instrument is on camera doing it. If a shot will not cooperate, cut the
  claim, not the honesty.
- **The 0–3.3 V section is the one to protect.** If the edit runs long, take it
  out of the demo and the rate table, not out of that.
- **Shot list worth having ready:** the flat line; the sine appearing; the
  spectrum peak; the phone; the raw carrier without an RC; the same with it;
  the dotted bias line toggling; the rate readout changing with channel count.
- **Do not show credentials, serial numbers, or the Wi-Fi episode's SSID.**
