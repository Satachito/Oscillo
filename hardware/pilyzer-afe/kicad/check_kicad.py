#!/usr/bin/env python3
"""Check the captured circuit and footprint pad mapping, using KiCad's netlist.

Usage: python3 check_kicad.py [--cli /path/to/kicad-cli]
Checks the saved schematics, not the one-time capture script.
"""
import argparse
import csv
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
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

with tempfile.TemporaryDirectory(prefix='pilyzer-netlist-') as directory:
    netlist = Path(directory) / 'schematic.xml'
    run = subprocess.run([args.cli, 'sch', 'export', 'netlist', '--format', 'kicadxml',
                          str(HERE / 'pilyzer-afe.kicad_sch'), '-o', str(netlist)],
                         capture_output=True, text=True)
    if run.returncode:
        raise SystemExit(run.stderr)
    root = ET.parse(netlist).getroot()

nets = {net.attrib['name']: {(node.attrib['ref'], node.attrib['pin'])
                           for node in net.findall('node')}
        for net in root.find('nets')}
pin_net = {node: name for name, nodes in nets.items() for node in nodes}
checks = 0

with (HERE / 'bom.csv').open() as file:
    _bom_values = {row['Reference']: row['Value'] for row in csv.DictReader(file)}
def bom_value(ref):
    return _bom_values[ref]

def net(name, *nodes):
    global checks
    wanted = {tuple(node.split('.')) for node in nodes}
    assert nets.get(name) == wanted, f'{name}: expected {wanted}; got {nets.get(name)}'
    checks += 1

# Explicit topology requirements, independent of symbol positions / graphics.
for channel, offset, cn, ca, cb, comp, header, tvs, tp, switch, unit, adc, range_pin, fb_c, out_r in [
    (1, 0, 4, 6, 7, 1, 3, 5, 1, 'U2', 1, 10, 20, 21, 44),
    (2, 8, 9, 10, 11, 8, 4, 6, 2, 'U2', 2, 9, 19, 22, 45),
    (3, 35, 17, 18, 19, 16, 10, 7, 7, 'U3', 1, 7, 17, 23, 46),
]:
    prefix = f'CH{channel}_'
    plus, minus, output = {1: (3, 2, 1), 2: (5, 6, 7), 3: (10, 9, 8)}[channel]
    common, control, normally_open, normally_closed = (10, 1, 2, 9) if unit == 1 else (6, 5, 4, 7)
    r = lambda number: f'R{number + offset}'
    net(prefix+'IN', f'J{header}.1', f'D{tvs}.1',
        r(1)+'.1', f'C{comp}.1', f'TC{channel}.1')
    middle = pin_net[(r(1), '2')]
    net(middle, r(1)+'.2', r(2)+'.1')
    net(prefix+'NODE', r(2)+'.2', r(3)+'.2', r(4)+'.1', f'C{comp}.2', f'TC{channel}.2',
        f'C{cn}.1', f'D{channel}.3', f'U1.{plus}', f'TP{tp}.1')
    net(prefix+'AMP', f'U1.{output}', r(5)+'.1', r(7)+'.1')
    net(prefix+'FB', f'U1.{minus}', r(7)+'.2', r(8)+'.1')
    net(prefix+'GAIN', r(8)+'.2', f'{switch}.{common}')
    # Unity-gain Sallen-Key: R(5) and R(6) are the equal series pair, C{fb_c}
    # the feedback capacitor and C{ca} the shunt that returns to VMID.
    net(prefix+'SK', r(5)+'.2', r(6)+'.1', f'C{fb_c}.1')
    net(prefix+'SKIN', r(6)+'.2', f'C{ca}.1', f'U4.{plus}')
    net(prefix+'FILT', f'C{fb_c}.2', f'U4.{output}', f'U4.{minus}', f'R{out_r}.1')
    net(prefix+'ADC', f'R{out_r}.2', f'C{cb}.1', f'J7.{adc}')
    assert bom_value(r(5)) == bom_value(r(6)) == '2.67k 1%', prefix + 'Sallen-Key resistors'
    net(f'RANGE_CH{channel}', f'J7.{range_pin}', f'{switch}.{control}')
    assert pin_net[(switch, str(normally_open))] == 'VMID'
    assert pin_net[(switch, str(normally_closed))].startswith('unconnected-')
    assert pin_net[(f'D{channel}', '1')] == 'GND'
    assert pin_net[(f'D{channel}', '2')] == '+3V3'

net('VMID_DIV', 'R17.2', 'R18.1', 'C15.1', 'U1.12')
net('VMID', 'U1.14', 'U1.13', 'U2.2', 'U2.4', 'U3.2', 'TP3.1',
    'C6.2', 'C10.2', 'C18.2', 'U4.12')
# The filter quad's spare amplifier is a follower on VMID, not left floating.
net('U4D_TIE', 'U4.13', 'U4.14')
net('CAL_GPIO20', 'J7.15', 'R35.1')
net('TEST_OUT', 'R35.2', 'TP6.1')
for i, socket_pin in enumerate([11, 12, 14, 15, 16, 17, 19, 20]):
    net(f'D{i}_IN', f'J5.{i+1}', f'R{19+i}.1')
    net(f'D{i}_GPIO{i+8}', f'R{19+i}.2', f'R{27+i}.1', f'J6.{socket_pin}')
for node in ['J7.5', 'U1.4', 'U4.4', 'U2.8', 'R3.1', 'R11.1', 'R17.1', 'C12.1', 'C13.1', 'C14.1',
             'TP4.1', 'R38.1', 'U3.8', 'C20.1', 'C24.1']:
    assert pin_net[tuple(node.split('.'))] == '+3V3', node
for node in ['U1.11', 'U4.11', 'U2.3', 'J7.8', 'C15.2', 'R18.2', 'U3.3', 'U3.5', 'C20.2', 'C24.2']:
    assert pin_net[tuple(node.split('.'))] == 'GND', node

# GPIO0–7 are deliberately unused on the instrument carrier.
for socket_pin in [1, 2, 4, 5, 6, 7, 9, 10]:
    node = ('J6', str(socket_pin))
    assert pin_net[node].startswith('unconnected-'), node
    assert nets[pin_net[node]] == {node}, node
# Keep the independently specified schematic pin map in step with firmware.
config = (HERE.parents[2] / 'firmware/pilyzer/board_config.h').read_text()
for macro, value in [('PIN_LOGIC_BASE',8),
                     ('PIN_RANGE_CH1',16), ('PIN_RANGE_CH2',17), ('PIN_RANGE_CH3',18),
                     ('PIN_ADC_CH1',26), ('PIN_ADC_CH2',27), ('PIN_ADC_CH3',28),
                     ('ANALOG_CHANNELS',3), ('PIN_CALIBRATION_OUT',20)]:
    found = re.search(r'^#define\s+'+macro+r'\s+(\d+)', config, re.MULTILINE)
    assert found and int(found[1]) == value, macro

# Unused half of the new range switch: control low, signal pins unconnected.
for pin in ['4', '6', '7']:
    assert pin_net[('U3', pin)].startswith('unconnected-')

# Check every saved BOM row and every electrically used pin against local pads.
with (HERE / 'bom.csv').open() as file:
    bom = {row['Reference']: row for row in csv.DictReader(file)}
parts = {part.attrib['ref']: part for part in root.find('components')}
assert 'J8' not in parts
assert len(parts) == 93 and parts.keys() == bom.keys()
for ref, part in parts.items():
    row = bom[ref]
    assert part.findtext('value') == row['Value'], ref
    fp = part.findtext('footprint')
    assert fp == row['Footprint'] and fp.startswith('PiLyzer:'), ref
    filename = HERE / 'PiLyzer.pretty' / (fp.split(':')[1] + '.kicad_mod')
    pads = set(re.findall(r'\(pad\s+"([^"]+)"', filename.read_text()))
    pins = {pin for (component, pin) in pin_net if component == ref}
    assert pins <= pads, f'{ref}: pins missing from footprint: {pins-pads}'
    assert ('dnp' in [p.attrib.get('name') for p in part.findall('property')]) == (row['DNP'] == 'yes'), ref
for ref in ['R8', 'R16', 'R43']:
    assert bom[ref]['Value'] == '2.67k 0.1%'
assert {ref for ref, row in bom.items() if row['DNP'] == 'yes'} == {'D5','D6','D7',*(f'R{i}' for i in range(27,35))}
print(f'PASS: {checks} exact net groups; supply, range polarity and Pico pin mapping; '
      f'{len(parts)} BOM entries and footprint pad mappings; 11 DNP parts.')
