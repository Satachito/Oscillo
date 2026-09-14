# Mini AFE

One op amp in front of a bare Pico 2, on a breadboard. It is not a prototype of
[the rev A front end](../pilyzer-afe/) — that board's three amplifiers are being
taken straight to a PCB. This is the smallest thing that makes a signal
readable: **impedance conversion, and a choice about where the signal sits.**

Used with `PILYZER_BOARD_ID 0`, which is the build that puts the converter pins
straight on the inputs and reports one 0 – 3.3 V range.

## What it is

```
IN ──┬── C3 ──┬── R2 ─── +3V3          AC branch: coupled, sitting at mid rail
     │        └── R3 ─── GND
     │                  │
     │                  ├── J1 ── U1 + ── U1 out ── R1 1k ──┬── ADC pin
     └── direct ────────┘   (follower)                      └── C1 4.7n ── GND
```

`J1` picks what the follower looks at:

| `J1` | The follower sees | For |
| --- | --- | --- |
| **direct** | the input, DC coupled, gain 1, no bias | a signal that already sits inside 0 – 3.3 V |
| **AC** | the input through `C3`, biased to mid rail | a signal that swings about 0 V |

Either way the follower does the one job that matters: it presents a high
impedance to whatever is being measured and a low one to the converter. The
RP2350's ADC wants to see **under 10 kΩ**, and a source that cannot promise that
reads low and drifts — the multiplexer's charge carries between channels and
drags a high-impedance input with it.

## The output RC

`R1` and `C1` are **33.9 kHz**, and they are the only bandlimiting in the path.

| | |
| ---: | ---: |
| 20 kHz | −1.3 dB |
| 33.9 kHz | −3.0 dB |
| 100 kHz | −9.9 dB |
| 123.7 kHz — Nyquist with 2 channels | −11.6 dB |
| 247.4 kHz — Nyquist with 1 channel | −17.4 dB |

One pole is not an anti-alias filter; rev A has a second-order section at
40.2 kHz for that. What this one does is stop the converter's sampling capacitor
from hanging directly on the op amp's output, where a switched capacitor makes
some amplifiers ring. Treat everything above about 30 kHz as approximate, and
anything above 100 kHz as suspect.

## The op amp is the one part that is not free choice

**MCP6022: rail to rail in and out, on 3.3 V.** Both halves of that matter here.
The follower's input is the signal itself, so a part whose input common mode
stops short of the rails cannot see the top of the range; and its output goes
straight at a converter that measures 0 to 3.3 V, so an output that stops short
throws the top away.

The LM358 currently in the socket shows exactly this. Its output reaches about
1.5 V below the positive rail, so on a 3.3 V supply it stops near 1.8 V and
**the top of the signal clips** — which is what the bench is seeing. It was
fitted because it was in the drawer; it is not a substitute.

| | Input common mode | Output | On 3.3 V |
| --- | --- | --- | --- |
| **MCP6022** | rail to rail | rail to rail | the whole range |
| LM358 | stops ~1.5 V below V+ | stops ~1.5 V below V+ | usable to about 1.8 V |

CMOS input also means picoamps of bias current, so the source impedance can be
whatever it is without the amplifier adding an offset of its own.

## Trying it before you wire it

[`falstad-mini-afe.txt`](falstad-mini-afe.txt) is this circuit for the
[Falstad simulator](https://www.falstad.com/circuit/circuitjs.html), which runs
in a browser with nothing to install.

**[Open it in the simulator](https://www.falstad.com/circuit/circuitjs.html?cct=%24%201%201.0E-6%2010.20027730826997%2050%203.3%2050%205.0E-11%0AR%2080%20200%2032%20200%200%201%201000.0%201.0%200.0%200.0%200.5%0Aw%2080%20200%20144%20200%200%0Ac%20144%20200%20208%20200%200%201.0E-7%20-1.65%0Ar%20208%20200%20208%20136%200%201000000.0%0AR%20208%20136%20208%20104%200%200%2040.0%203.3%200.0%200.0%200.5%0Ar%20208%20200%20208%20264%200%201000000.0%0Ag%20208%20264%20208%20296%200%0Aw%20208%20200%20288%20200%200%0Aa%20288%20184%20384%20184%200%203.3%200.0%201000000.0%0Aw%20384%20184%20384%20136%200%0Aw%20384%20136%20288%20136%200%0Aw%20288%20136%20288%20168%200%0Aw%20384%20184%20416%20184%200%0Ar%20416%20184%20480%20184%200%201000.0%0Ac%20480%20184%20480%20248%200%204.7E-9%200%0Ag%20480%20248%20480%20280%200%0AO%20480%20184%20544%20184%200%0AR%2080%20400%2032%20400%200%201%201000.0%201.0%201.65%200.0%200.5%0Aw%2080%20400%20288%20400%200%0Aa%20288%20384%20384%20384%200%203.3%200.0%201000000.0%0Aw%20384%20384%20384%20336%200%0Aw%20384%20336%20288%20336%200%0Aw%20288%20336%20288%20368%200%0Aw%20384%20384%20416%20384%200%0Ar%20416%20384%20480%20384%200%201000.0%0Ac%20480%20384%20480%20448%200%204.7E-9%200%0Ag%20480%20448%20480%20480%200%0AO%20480%20384%20544%20384%200%0A)**

Both branches are drawn, with the AC one fed from its own copy of the source, so
you can watch the coupled-and-biased version and the direct version at once
rather than moving a jumper. A 1 V sine reaches the converter pin as
**1.65 ± 1.0 V either way** — 0.648 to 2.647 V through the coupling capacitor
and 0.651 to 2.650 V direct, which is the whole point of the choice.

`C3` carries an initial −1.65 V so the mid rail starts settled instead of
taking the divider's 50 ms to charge. The low corner is arithmetic rather than
something the simulation shows well: at 3 Hz a cycle is longer than the
simulation advances while you watch it.

## What it cannot do

- **No protection.** The input goes to the op amp through a jumper and nothing
  else. There is no 1 MΩ in front of it and no clamp, so the op amp's own input
  diodes are all there is: keep the input inside the supply. Rev A's 1 MΩ input
  is [what protection looks like](../pilyzer-afe/README.md#protection).
- **No attenuation.** Gain is 1, so the range is the converter's range —
  0 to 3.3 V, or whatever the AC branch's divider allows about mid rail.
- **No calibration story.** There is nothing to calibrate: what the converter
  reads is what reached it. Set the channel's bias in the panel to 0 on the
  direct branch, and to the mid rail on the AC branch.

## The AC branch's own numbers

`R2` and `R3` are 1 MΩ each, so the node they bias sits at **500 kΩ** — and
that one number decides three things.

| | |
| --- | --- |
| Low corner, with `C3` at 100 nF | **3.2 Hz** — anything audio passes |
| Settling from cold | 50 ms, which is `C3` charging through the divider |
| What the op amp has to be | CMOS, and not by a little |

The last is worth spelling out. Bias current flows through that 500 kΩ and lands
in the reading as an offset:

| | Bias current | Offset it adds |
| --- | ---: | ---: |
| **MCP6022** | 1 pA | 0.5 µV, which is 0.00 LSB |
| LM358 | 45 nA | 22.5 mV, which is **28 LSB** |

So the part in the socket is not only clipping the top of the range, it is
sitting 28 counts off the middle of it on this branch. Both go away with the
MCP6022.

**Expect the AC branch to roll off earlier than the output RC does.** 500 kΩ
against whatever stray a breadboard puts on that node is a low-pass of its own,
and it lands below `R1`/`C1`:

| Stray at the node | Corner |
| ---: | ---: |
| 10 pF | 31.8 kHz |
| 20 pF | 15.9 kHz |
| 30 pF | 10.6 kHz |

The direct branch has none of this — it carries whatever the source's own
impedance gives it. If the AC branch measures softer at the top of the audio
band than the direct one, that is why, and it is the divider rather than the
amplifier.
