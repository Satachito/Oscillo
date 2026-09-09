# PiLyzer AFE — KiCad project

Open **pilyzer-afe.kicad_pro** in **KiCad 10** and launch the schematic editor.
This deliverable includes schematic capture and footprint assignment. It has
no PCB layout or manufacturing files.

## Sheets and files

- `pilyzer-afe.kicad_sch`: Pico 2 sockets, logic inputs, power, VMID and test output.
- `channel-1.kicad_sch`, `channel-2.kicad_sch`, `channel-3.kicad_sch`: fixed input divider, gain stage,
  range switch, clamps and the Sallen-Key anti-alias filter.
- `PiLyzer.kicad_sym`, `PiLyzer.pretty`, and both library tables: local symbols
  and all 13 footprint types. No external library is needed for schematic or
  footprint editing. Optional 3D models use the standard KiCad model paths.
- `bom.csv`: all 93 physical components, including the 11 DNP parts.
- `previews/`: SVG exports of all four sheets.
- `erc.rpt`: KiCad 10.0.5 electrical-rule-check report.
- `check_kicad.py`: checks the saved circuit via KiCad's exported netlist.

## Capture decisions and corrections

The saved schematic takes precedence over the earlier ASCII sketch.

1. R8/R16/R43 are **2.67 kΩ**, following the BOM and `../check_transfer.py`; the old
   sketch's 2.49 kΩ was stale. The nominal fine-range gain remains 4.745.
2. C1/TC1, C8/TC2 and C16/TC3 span the **entire 998 kΩ** input resistance.
3. R7/R15/R42 return from the gain stage's own output, **before** the filter,
   so the range switching is not inside the filter's loop.
4. One **BAV199 dual-series diode per channel** supplies both rail clamps.
   D1/D2/D3 pin 1 = GND, pin 2 = 3V3, pin 3 = divider node. D3 now belongs
   to CH3; D4 remains unused. Optional connector TVS footprints D5/D6/D7 are
   marked DNP with no exact part selected.
5. U2A/U2B/U3A COM connects to the 2.67 kΩ resistor, NO to VMID, and NC is deliberately
   unconnected. GPIO16/17/18 LOW gives ±25 V; HIGH gives ±5 V, matching firmware
   switch positions 0/1. The TI DGS package uses the KiCad footprint
   `TSSOP-10_3x3mm_P0.5mm` (VSSOP-10, not a generic footprint selected by name).
6. C15 bypasses the **divider midpoint before U1D**, avoiding a direct 1 µF
   capacitive load on its output. U1C is the CH3 gain stage; U1D remains the VMID buffer.
7. **U4 is the anti-alias filter quad.** U4A/U4B/U4C are unity-gain Sallen-Key
   sections on the channel sheets — R5/R6, R13/R14 and R40/R41 as the equal
   2.67 kΩ pairs, C21/C22/C23 as feedback and C6/C10/C18 as the shunt to VMID,
   giving fc 40.2 kHz and Q 0.742. R44/R45/R46 isolate each output from the
   converter, C7/C11/C19 are the reservoir at the pin. U4D is a follower on
   VMID rather than a floating input, U4E is the supply unit, and C24 decouples
   it. Inputs are the 2-pin headers J3/J4/J10; the BNC footprints are gone.
8. Both Pico socket pad-1 ends face USB. J6 pad 1 = physical Pico pin 1;
   J7 pad 1 = physical Pico pin 40. The right socket maps in reverse physical
   pin order. Socket rows must be 17.78 mm apart in the future PCB layout.
8. C12 decouples U1, C13 decouples U2, C20 decouples U3; all use Pico 3V3(OUT). Pico AGND
   and ground are one net. ADC_VREF is left unconnected on the carrier.
9. R27–R34 are DNP. They suppress floating logic inputs only when populated.

## Firmware 1.5 pin map (rev B)

| Signal | GPIO | Pico physical pin | Carrier socket pad |
| --- | ---: | ---: | --- |
| CH1 ADC | 26 | 31 | J7.10 |
| CH2 ADC | 27 | 32 | J7.9 |
| CH3 ADC | 28 | 34 | J7.7 |
| CH1 range | 16 | 21 | J7.20 |
| CH2 range | 17 | 22 | J7.19 |
| CH3 range | 18 | 24 | J7.17 |
| Test output | 20 | 26 | J7.15 |

Logic D0–D7 remain on GPIO8–15. GPIO0–7 remain unconnected. J8 is unused:
CH3's input is J10, and the diminished-chord generator stays on a separate
Pico 2.
U3A is CH3's range switch; U3B control is grounded and its signal pins are NC.

The check script verifies the three complete analogue paths, unused pins,
active GPIO map against firmware macros, and every assigned footprint.

## Validation

Executed with KiCad 10.0.5:

```sh
kicad-cli sch erc --exit-code-violations -o erc.rpt pilyzer-afe.kicad_sch
python3 check_kicad.py
python3 ../check_transfer.py
```

ERC: **0 errors, 0 warnings**, using the project's default ERC checks (the
report lists the default ignored check categories; no individual violations
were excluded). The separate netlist check verifies 54 exact net groups,
supply rails, range polarity, Pico mapping, every BOM entry, all electrically
used pin numbers against footprint pads, and the 11 DNP assignments.
All four sheets were exported and visually checked.

These checks establish schematic consistency; they do not measure analogue
performance or certify the input-protection ratings in the design notes.
Prototype measurements, component sourcing (including the trimmer and DNP TVS),
PCB layout, and DRC remain before fabrication. Bare-Pico firmware must stay
board ID 0; board ID 1 is for use after this AFE is physically installed.

## Primary references

- [TI TLV9064 datasheet](https://www.ti.com/lit/ds/symlink/tlv9064.pdf): SOIC-14
  pinout, supply and amplifier connections.
- [TI TS5A23159 datasheet](https://www.ti.com/lit/ds/symlink/ts5a23159.pdf): DGS
  pinout, LOW→NC / HIGH→NO truth table and package drawing.
- [Nexperia BAV199 datasheet](https://assets.nexperia.com/documents/data-sheet/BAV199.pdf):
  dual-diode topology and pin mapping.
- [Raspberry Pi Pico 2 pinout](https://datasheets.raspberrypi.com/pico/Pico-2-Pinout.pdf)
  and [board datasheet](https://datasheets.raspberrypi.com/pico/pico-2-datasheet.pdf).

## Library attribution

Project-local symbols and footprints are derived from the **KiCad community
libraries bundled with KiCad 10.0.5**, under CC-BY-SA 4.0 with the KiCad design
exception. See `LIBRARY-LICENSE.md` and the
[KiCad library license](https://www.kicad.org/libraries/license/).
`library-sources.json` records each original library identifier. Symbols were
renamed into the local library and inherited symbols were flattened; footprint
geometry is unchanged. The PiLyzer circuit design and validation script retain
the repository's MIT license.
