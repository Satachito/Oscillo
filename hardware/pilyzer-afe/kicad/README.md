# PiLyzer AFE — KiCad project

Open **pilyzer-afe.kicad_pro** in **KiCad 10** and launch the schematic editor.
This deliverable includes schematic capture and footprint assignment. It has
no PCB layout or manufacturing files.

## Sheets and files

- `pilyzer-afe.kicad_sch`: Pico 2 sockets, logic inputs, power, VMID and test output.
- `channel-1.kicad_sch`, `channel-2.kicad_sch`: fixed input divider, gain stage,
  range switch, clamps and passive ADC filter.
- `PiLyzer.kicad_sym`, `PiLyzer.pretty`, and both library tables: local symbols
  and all 13 footprint types. No external library is needed for schematic or
  footprint editing. Optional 3D models use the standard KiCad model paths.
- `bom.csv`: all 68 physical components, including the 10 DNP parts.
- `previews/`: SVG exports of all three sheets.
- `erc.rpt`: KiCad 10.0.5 electrical-rule-check report.
- `check_kicad.py`: checks the saved circuit via KiCad's exported netlist.

## Capture decisions and corrections

The saved schematic takes precedence over the earlier ASCII sketch.

1. R8/R16 are **2.67 kΩ**, following the BOM and `../check_transfer.py`; the old
   sketch's 2.49 kΩ was stale. The nominal fine-range gain remains 4.745.
2. C1/TC1 and C8/TC2 span the **entire 998 kΩ** input resistance.
3. R7/R15 return from the op-amp output **before** the passive RC filter.
4. One **BAV199 dual-series diode per channel** supplies both rail clamps.
   D1/D2 pin 1 = GND, pin 2 = 3V3, pin 3 = divider node. The old BOM's D3/D4
   duplicated the packages; those designators are now unused. The optional
   connector TVS footprints remain D5/D6, marked DNP with no exact part selected.
5. U2 COM connects to the 2.67 kΩ resistor, NO to VMID, and NC is deliberately
   unconnected. GPIO16/17 LOW gives ±25 V; HIGH gives ±5 V, matching firmware
   switch positions 0/1. The TI DGS package uses the KiCad footprint
   `TSSOP-10_3x3mm_P0.5mm` (VSSOP-10, not a generic footprint selected by name).
6. C15 bypasses the **divider midpoint before U1D**, avoiding a direct 1 µF
   capacitive load on its output. U1C, the spare amplifier, is a VMID follower.
7. Both Pico socket pad-1 ends face USB. J6 pad 1 = physical Pico pin 1;
   J7 pad 1 = physical Pico pin 40. The right socket maps in reverse physical
   pin order. Socket rows must be 17.78 mm apart in the future PCB layout.
8. C12 decouples U1, C13 decouples U2, and both share Pico 3V3(OUT). Pico AGND
   and ground are one net. ADC_VREF is left unconnected on the carrier.
9. R27–R34 are DNP. They suppress floating logic inputs only when populated.

## Firmware pin map (1.3 and later)

Logic D0–D7 use GPIO8–15. Range controls use GPIO16/17 (Pico pins 21/22,
J7 pads 20/19). The adjustable calibration output is GPIO28 (Pico pin 34,
J7 pad 7). These assignments remain unchanged in firmware 1.4.

The chord generator is now on a separate Pico 2. J8 and its sheet have been
removed; GPIO0–7 on J6 are explicitly unconnected. The check script verifies
these unused pins as well as the active pin map against the firmware macros.

## Validation

Executed with KiCad 10.0.5:

```sh
kicad-cli sch erc --exit-code-violations -o erc.rpt pilyzer-afe.kicad_sch
python3 check_kicad.py
python3 ../check_transfer.py
```

ERC: **0 errors, 0 warnings**, using the project's default ERC checks (the
report lists the default ignored check categories; no individual violations
were excluded). The separate netlist check verifies 39 exact net groups,
supply rails, range polarity, Pico mapping, every BOM entry, all electrically
used pin numbers against footprint pads, and the 10 DNP assignments.
All three sheets were exported and visually checked.

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
