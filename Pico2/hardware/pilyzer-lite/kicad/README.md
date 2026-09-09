# PiLyzer Lite — KiCad project

Open **pilyzer-lite.kicad_pro** in **KiCad 10**. Schematic capture and
footprint assignment; no PCB layout and no manufacturing files yet.

Lite is [`../../pilyzer-afe`](../../pilyzer-afe) with the third channel and the
range switching taken out. The attenuator, the clamp, the anti-alias filter and
the whole Pico interface are that board's, unchanged — this is a smaller board,
not a different circuit.

## Sheets

- `pilyzer-lite.kicad_sch`: Pico 2 sockets, logic inputs, power, VMID and the
  test output.
- `channel-1.kicad_sch`, `channel-2.kicad_sch`: fixed input divider, gain stage,
  clamps and the Sallen-Key anti-alias filter.
- `bom.csv`: all 70 parts, including the 10 that are DNP.
- `previews/`: SVG exports of all three sheets.
- `erc.rpt`: KiCad 10 electrical-rule-check report.
- `check_lite.py`: checks the saved circuit through KiCad's own netlist.
- `PiLyzer.kicad_sym`, `PiLyzer.pretty` and both library tables: a project-local
  copy of rev A's library, with the two footprints Lite does not use taken out.
  The project opens with no external library, which is worth more than sharing
  one file with the board next door.

## What differs from rev A

| | rev A | Lite |
| --- | --- | --- |
| Channels | 3 | 2 |
| Ranges | ±25 V and ±5 V, switched | **±15 V only** (−15.81 to +15.80 V) |
| Analogue switch | 2 × TS5A23159 | **none** |
| Gain leg `R8` | 2.67 kΩ through the switch to VMID | **15 kΩ wired to VMID** |
| Stage gain | 1 or 4.745 | 1.667 |
| Node capacitor `C4` | 82 pF | **220 pF** |
| Compensation `C1` | 5.6 pF | **15 pF** |
| Parts | 93 | **70** |
| GPIO16–18 | range control | unused |

The gain leg and the two capacitor values are the whole electrical difference.
Everything else is subtraction.

### Why `C4` grew

The divider is flat when `C_top = C_node / 14.96`, and `C_node` is `C4` plus
whatever the layout adds. The bigger `C4` is, the smaller a fraction of `C_node`
the unknown stray becomes — at 220 pF a 10 pF error in the estimate is 4.2%
rather than rev A's 9.8%.

That is what buys Lite a **fixed capacitor instead of a trimmer** in production,
which a teaching board wants: a trimmer is a cost, and it is something for a
student to turn. `TC1`/`TC2` are captured here for the prototype run; once the
first boards are measured, fit the value they land on and leave the trimmer off.
The price is input capacitance, which `C_top` is: about 16 pF, against a bench
oscilloscope's usual 10 to 20.

### Spare amplifiers

Two channels need five amplifiers — two gain stages, two filters and the VMID
buffer — so two quads carry them with three units left over. `U1C` and `U4C` are
held as followers on VMID rather than left floating, the same as `U4D`.

A quad plus a single would leave none spare and take less board area, at the
cost of a second part number. It is worth revisiting at layout; it is not worth
a different capture before the circuit has been measured once.

## Validation

```sh
kicad-cli sch erc --exit-code-violations -o erc.rpt pilyzer-lite.kicad_sch
python3 check_lite.py
```

ERC: **0 errors, 0 warnings**, on the project's default checks. `check_lite.py`
passes **25 groups** against KiCad's netlist: that there are two channels and no
third, that no analogue switch survives anywhere, that each gain leg really sits
on VMID at 15 kΩ, that both divider nodes hold exactly the parts that set their
capacitance, that the Sallen-Key shunts return to VMID rather than ground, that
the spare amplifier inputs are held, that the converter and logic pins match the
firmware's own `#define`s, and that every part and footprint agrees with
`bom.csv`.

It has been checked against mutations rather than only against itself: changing
`R8` back to 2.67 kΩ and moving the gain leg off VMID each fail it.

These checks establish that the capture is the circuit that was meant. They do
not measure anything. Prototype measurement, component sourcing, PCB layout and
DRC all remain — see [`../../pilyzer-afe/breadboard`](../../pilyzer-afe/breadboard),
whose one-channel build differs only in `R8`.

## Firmware

Lite is `PILYZER_BOARD_ID 2`:

```sh
cd ../../../firmware/pilyzer && BOARD_ID=2 ./build.sh
```

It reports one range and no software range switching, and both applications read
it correctly with no release of their own, because the board describes its own
front end from firmware 1.7.
