#!/usr/bin/env python3
"""Check the captured PiLyzer Lite circuit against KiCad's own netlist.

Usage: python3 check_lite.py [--cli /path/to/kicad-cli]

ERC says the drawing is electrically legal. This says it is the circuit that
was meant: two channels, one fixed range, no analogue switch anywhere, and a
converter and logic map that matches the firmware's pin definitions.
"""
import argparse
import csv
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIRMWARE = HERE.parents[2] / 'firmware/pilyzer/board_config.h'

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cli', default=shutil.which('kicad-cli'))
args = parser.parse_args()
if not args.cli:
    for app in [Path.home() / 'Applications/KiCad.app', Path('/Applications/KiCad/KiCad.app')]:
        candidate = app / 'Contents/MacOS/kicad-cli'
        if candidate.exists():
            args.cli = str(candidate)
            break
if not args.cli:
    parser.error('Pass --cli with the path to kicad-cli.')

with tempfile.TemporaryDirectory(prefix='pilyzer-lite-netlist-') as directory:
    netlist = Path(directory) / 'schematic.xml'
    run = subprocess.run([args.cli, 'sch', 'export', 'netlist', '--format', 'kicadxml',
                          str(HERE / 'pilyzer-lite.kicad_sch'), '-o', str(netlist)],
                         capture_output=True, text=True)
    if run.returncode:
        raise SystemExit(run.stderr)
    root = ET.parse(netlist).getroot()

nets = {net.attrib['name']: {(node.attrib['ref'], node.attrib['pin'])
                             for node in net.findall('node')}
        for net in root.find('nets')}
pin_net = {node: name for name, nodes in nets.items() for node in nodes}
values = {c.attrib['ref']: c.findtext('value') for c in root.find('components')}
footprints = {c.attrib['ref']: c.findtext('footprint') for c in root.find('components')}
checks = 0


def net(name, *nodes):
    """The named net holds exactly these pins and no others."""
    global checks
    want = {tuple(n.split('.')) for n in nodes}
    assert name in nets, f'no net {name}'
    assert nets[name] == want, f'{name}: {sorted(nets[name])} != {sorted(want)}'
    checks += 1


def joined(a, b, why):
    global checks
    assert pin_net[tuple(a.split('.'))] == pin_net[tuple(b.split('.'))], why
    checks += 1


# --- Two channels, and only two -----------------------------------------
assert not [r for r in values if r.startswith('J10')], 'channel 3 input still present'
for missing in ('R36', 'R43', 'C16', 'D3', 'TP7'):
    assert missing not in values, f'{missing} belongs to the third channel'
checks += 1

# --- No analogue switch anywhere ----------------------------------------
# This is what makes Lite Lite: the gain leg is wired to VMID, not taken there
# by a part under software control.
for ref, value in values.items():
    assert 'TS5A' not in (value or ''), f'{ref} is an analogue switch'
assert not [n for n in nets if n.startswith('RANGE')], 'a range control net survives'
checks += 1

# --- One range, fixed, per channel --------------------------------------
# R7 from the amplifier's output to its inverting input, R8 from there to VMID:
# a gain of 1 + 10k/15k = 1.667, which with the attenuator gives +/-15.8 V.
for channel, (feedback, leg, amp_out) in enumerate(
        [('R7', 'R8', 'U1.1'), ('R15', 'R16', 'U1.7')], start=1):
    assert values[feedback] == '10k 0.1%', f'CH{channel} feedback is {values[feedback]}'
    assert values[leg] == '15k 0.1%', f'CH{channel} gain leg is {values[leg]}'
    joined(f'{leg}.2', 'TP3.1', f'CH{channel} gain leg must sit on VMID')
    joined(f'{feedback}.2', f'{leg}.1', f'CH{channel} feedback and gain leg share the summing node')
    joined(f'{feedback}.1', f'{amp_out}', f'CH{channel} feedback returns from the amplifier output')
checks += 1

# --- The attenuator is rev A's, untouched -------------------------------
# It is where the input protection lives, so it does not move with the range.
for channel, (top, second, high, low, node, amp_in, clamp) in enumerate(
        [('R1', 'R2', 'R3', 'R4', 'CH1_NODE', 'U1.3', 'D1.3'),
         ('R9', 'R10', 'R11', 'R12', 'CH2_NODE', 'U1.5', 'D2.3')], start=1):
    assert values[top] == values[second] == '499k 1%', f'CH{channel} input divider'
    assert values[high] == '125k 1%' and values[low] == '143k 1%', f'CH{channel} bias legs'
    # Everything that defines the node's capacitance, and the clamp, meet here.
    net(node, f'{second}.2', f'{high}.2', f'{low}.1', clamp, amp_in,
        f'C{1 if channel == 1 else 8}.2', f'C{4 if channel == 1 else 9}.1',
        f'TC{channel}.2', f'TP{channel}.1')
checks += 1

# --- Compensation sized for a 220 pF node -------------------------------
for fixed, trim, shunt in (('C1', 'TC1', 'C4'), ('C8', 'TC2', 'C9')):
    assert values[shunt] == '220p C0G', f'{shunt} is {values[shunt]}'
    assert values[fixed] == '15p C0G', f'{fixed} is {values[fixed]}'
    assert values[trim] == '0.5–3p', f'{trim} is {values[trim]}'
    joined(f'{fixed}.1', f'{trim}.1', 'the trimmer parallels the fixed part')
checks += 1

# --- The anti-alias filter is unchanged ---------------------------------
for r1, r2, feedback, shunt in (('R5', 'R6', 'C21', 'C6'), ('R13', 'R14', 'C22', 'C10')):
    assert values[r1] == values[r2] == '2.67k 1%', 'Sallen-Key resistors must be an equal pair'
    assert values[feedback] == '2.2n C0G' and values[shunt] == '1n C0G', 'Sallen-Key capacitors'
    joined(f'{shunt}.2', 'TP3.1', 'the Sallen-Key shunt returns to VMID, not to ground')
checks += 1

# --- Spare amplifiers are held, not floating ----------------------------
for spare in ('U1.10', 'U4.10'):
    joined(spare, 'TP3.1', f'{spare} is a spare input and must sit on VMID')
checks += 1

# --- The Pico map, against the firmware's own pin definitions -----------
macros = FIRMWARE.read_text()
for macro, expected_net in [('PIN_ADC_CH1', 'CH1_ADC'), ('PIN_ADC_CH2', 'CH2_ADC'),
                            ('PIN_LOGIC_BASE', 'D0_GPIO8'), ('PIN_CALIBRATION_OUT', 'CAL_GPIO20')]:
    found = re.search(rf'#define\s+{macro}\s+(\d+)', macros)
    assert found, f'{macro} not found in board_config.h'
    gpio = int(found.group(1))
    assert expected_net.endswith(f'GPIO{gpio}') or expected_net.startswith('CH'), \
        f'{macro} is GPIO{gpio} but the sheet calls the net {expected_net}'
    assert expected_net in nets, f'no net {expected_net}'
checks += 1

# The third channel's converter pin and the range controls go nowhere now.
for ref, pin in [('J7', '7'), ('J7', '17'), ('J7', '19'), ('J7', '20')]:
    name = pin_net.get((ref, pin), '')
    assert name.startswith('unconnected-'), f'{ref} pin {pin} should be unconnected, is on {name}'
checks += 1

# --- The bill of materials is the netlist ------------------------------
with (HERE / 'bom.csv').open() as file:
    bom = {row['Reference']: row for row in csv.DictReader(file)}
assert set(bom) == set(values), 'the BOM and the schematic disagree about which parts exist'
for ref, row in bom.items():
    assert row['Value'] == values[ref], f'{ref}: BOM says {row["Value"]}, schematic says {values[ref]}'
    assert row['Footprint'] == (footprints[ref] or ''), f'{ref}: footprint'
checks += 1

dnp = sorted(r for r, v in values.items() if 'DNP' in (v or ''))
assert dnp == ['D5', 'D6'] + [f'R{n}' for n in range(27, 35)], f'unexpected DNP set: {dnp}'
checks += 1

print(f'PASS: {checks} groups; two channels, one fixed ±15 V range, no analogue switch; '
      f'{len(values)} parts agree with the BOM; {len(dnp)} DNP.')
