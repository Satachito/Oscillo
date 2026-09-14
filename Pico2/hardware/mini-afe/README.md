# Mini AFE

One MCP6022 in front of a bare Pico 2, on a breadboard. It is not a prototype of
[the rev A front end](../pilyzer-afe/) — that board's three amplifiers are going
straight to a PCB. This is the smallest thing that makes a signal readable:
**impedance conversion, twice, with the two halves set up differently.**

Used with `PILYZER_BOARD_ID 0`, the build that puts the converter pins straight
on the inputs and reports one 0 – 3.3 V range.

## What it is

```
IN(dc) ───────────── U1A + ── out ── R1 1k ──┬── GPIO26  CH1
                                             └── C1 4.7n ── GND

IN(ac) ── C3 1.5u ──┬── R2 100k ── +3V3
                    ├── R3 100k ── GND
                    └── U1B + ── out ── R4 1k ──┬── GPIO27  CH2
                                                └── C4 4.7n ── GND
```

Both halves of the dual are used, so there is nothing to switch:

| | Sees | For |
| --- | --- | --- |
| **CH1** | the input direct, DC coupled, gain 1 | a signal already inside 0 – 3.3 V |
| **CH2** | the input through `C3`, biased to mid rail | a signal that swings about 0 V |

[`breadboard-30rows.svg`](breadboard-30rows.svg) is where every part goes on a
30-row board, hole by hole, with the Pico on rows 1–20 and the MCP6022 on 24–27.
**Two jumpers are not on it**: each amplifier's output has to reach its converter
pin — row 23 A–E to row 10 F–J for CH1, and row 23 F–J to row 9 F–J for CH2.

Ground is taken twice on purpose. Pin 18 feeds the left rail and pin 23 the
right, and **pin 33 — AGND, the pin the converter measures against — joins the
right rail too**, so the analogue returns sit next to it rather than reaching it
through the Pico's own plane. The two rails are then linked at row 1.

That link closes a loop, which is worth a sentence because it looks alarming and
is not: both of its ends are the same Pico ground, so there is no second
reference to circulate current between. What it can pick up is magnetic, and the
area is small — a 1 µT field at 50 Hz induces 3 µV in it, which is 0.004 of a
count, and a 10 µT field 0.04. The gain is a return path that does not depend on
a single pin's contact.

Either way the follower does the job that matters: a high impedance to whatever
is being measured, a low one to the converter. The RP2350's ADC wants to see
**under 10 kΩ**, and a source that cannot promise that reads low and drifts —
the multiplexer's charge carries between channels and drags a high-impedance
input with it.

Set the bias in the panel to match: **0 on CH1, mid rail on CH2**. The dotted
line then lands where the channel actually sits, and both readings stay the
volts the converter saw.

## The numbers

**Output RC — `R1`/`C1` and `R4`/`C4`, 33.9 kHz.** The only bandlimiting in
either path, and the same on both.

| | |
| ---: | ---: |
| 20 kHz | −1.3 dB |
| 33.9 kHz | −3.0 dB |
| 100 kHz | −9.9 dB |
| 123.7 kHz — Nyquist with 2 channels | −11.6 dB |

One pole is not an anti-alias filter; rev A has a second-order section at
40.2 kHz for that. What this one does is stop the converter's sampling capacitor
from hanging on an op amp output, where a switched capacitor makes some
amplifiers ring. Treat anything above 100 kHz as suspect.

**The AC channel's divider — 100 kΩ each side, so 50 kΩ at the node.** That one
number carries the channel:

| | |
| --- | --- |
| Low corner, with `C3` at 1.5 µF | **2.1 Hz** |
| Settling from cold | 75 ms, `C3` charging through the divider |
| Its own high corner, with 20 pF of stray | 159 kHz — **above** the output RC, so the RC decides |
| Input impedance | 50 kΩ, and that is the price |

That last line is the trade. 50 kΩ is light for a function generator or an op
amp output and heavy for a sensor or a divider tap, so **high-impedance things
go on CH1**, where the only load is the amplifier's own picoamps.

The divider used to be 1 MΩ a side, which put 500 kΩ at the node and rolled the
AC channel off at 15.9 kHz — below the output RC, so the two channels stopped
agreeing above about 10 kHz. At 100 kΩ they agree all the way out.

## The op amp is the one part that is not free choice

**MCP6022: rail to rail in and out, on 3.3 V.** Both halves of that matter. The
follower's input is the signal itself, so a part whose input common mode stops
short of the rails cannot see the top of the range; and its output goes at a
converter measuring 0 to 3.3 V, so an output that stops short throws the top
away.

The LM358 that was in the socket shows exactly this. Its output reaches about
1.5 V below the positive rail, so on 3.3 V it stops near 1.8 V and **the top
clips**.

| | Input common mode | Output | On 3.3 V |
| --- | --- | --- | --- |
| **MCP6022** | rail to rail | rail to rail | the whole range |
| LM358 | stops ~1.5 V below V+ | stops ~1.5 V below V+ | usable to about 1.8 V |

CMOS input matters too, because bias current flows through the divider's 50 kΩ
and lands in the reading as an offset: 1 pA is 0.05 µV and nothing, where the
LM358's 45 nA is 2.25 mV, which is 2.8 counts.

## Trying it before you wire it

[`falstad-mini-afe.txt`](falstad-mini-afe.txt) is this circuit for the
[Falstad simulator](https://www.falstad.com/circuit/circuitjs.html), which runs
in a browser with nothing to install.

**[Open it in the simulator](https://www.falstad.com/circuit/circuitjs.html?cct=%24%201%201.0E-6%2010.20027730826997%2050%203.3%2050%205.0E-11%0AR%2080%20200%2032%20200%200%201%201000.0%201.0%200.0%200.0%200.5%0Aw%2080%20200%20144%20200%200%0Ac%20144%20200%20208%20200%200%201.5E-6%20-1.65%0Ar%20208%20200%20208%20136%200%20100000.0%0AR%20208%20136%20208%20104%200%200%2040.0%203.3%200.0%200.0%200.5%0Ar%20208%20200%20208%20264%200%20100000.0%0Ag%20208%20264%20208%20296%200%0Aw%20208%20200%20288%20200%200%0Aa%20288%20184%20384%20184%200%203.3%200.0%201000000.0%0Aw%20384%20184%20384%20136%200%0Aw%20384%20136%20288%20136%200%0Aw%20288%20136%20288%20168%200%0Aw%20384%20184%20416%20184%200%0Ar%20416%20184%20480%20184%200%201000.0%0Ac%20480%20184%20480%20248%200%204.7E-9%200%0Ag%20480%20248%20480%20280%200%0AO%20480%20184%20544%20184%200%0AR%2080%20400%2032%20400%200%201%201000.0%201.0%201.65%200.0%200.5%0Aw%2080%20400%20288%20400%200%0Aa%20288%20384%20384%20384%200%203.3%200.0%201000000.0%0Aw%20384%20384%20384%20336%200%0Aw%20384%20336%20288%20336%200%0Aw%20288%20336%20288%20368%200%0Aw%20384%20384%20416%20384%200%0Ar%20416%20384%20480%20384%200%201000.0%0Ac%20480%20384%20480%20448%200%204.7E-9%200%0Ag%20480%20448%20480%20480%200%0AO%20480%20384%20544%20384%200%0A)**

Both channels are drawn, each from its own source, so the coupled one and the
direct one can be watched together. A 1 V sine arrives at the converter pins as
**1.65 ± 1.0 V on both** — 1.999 V peak to peak, centred on 1.648 and 1.650 V —
and at 20 kHz both read 1.720 V peak to peak, which is what a 33.9 kHz single
pole does to 2 V and is the point of moving the divider to 100 kΩ: the two
channels now fall off together.

`C3` carries an initial −1.65 V so the mid rail starts settled rather than
taking 75 ms to charge. The 2.1 Hz low corner stays arithmetic — a cycle that
long is longer than the simulation advances while it is being watched.

## What it cannot do

- **No protection.** The input reaches the op amp through a coupling capacitor
  or nothing at all. There is no 1 MΩ in front of it and no clamp, so the op
  amp's own input diodes are all there is: keep the input inside the supply.
  Rev A's 1 MΩ input is
  [what protection looks like](../pilyzer-afe/README.md#protection).
- **No attenuation.** Gain is 1 on both channels, so the range is the
  converter's range.
- **No calibration story.** There is nothing to calibrate: what the converter
  reads is what reached it. The bias setting is the only thing to get right, and
  it is per channel.
- **No third channel.** GPIO28 is free if one is wanted, but the dual is full.
