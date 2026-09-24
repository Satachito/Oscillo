#!/usr/bin/env python3
"""Talk to an ArLyzer over its USB serial port and print what it says.

    python3 probe.py                        # finds the Nano R4 by USB id
    python3 probe.py /dev/cu.usbmodem1101   # or name the port
    python3 probe.py --averages 256 --repeat 10

Sends identify, capabilities, inputRanges and analogSample, the same frames the
Pico's vendor interface carries, and prints the eight readings as volts.
"""
import argparse, struct, sys
import serial
from serial.tools import list_ports

ARDUINO_VID = 0x2341
NANO_R4_PIDS = {0x0074, 0x0374}

REQUEST, RESPONSE = 0xA5, 0x5A
HEADER = struct.Struct('<BBBBHHI')


class Device:
    def __init__(self, port):
        self.port = serial.Serial(port, 115200, timeout=3)
        self.sequence = 0

    def call(self, opcode, payload=b''):
        self.sequence = (self.sequence + 1) & 0xFFFF
        self.port.write(HEADER.pack(REQUEST, opcode, 0, 0, self.sequence, 0, len(payload)) + payload)
        header = self.port.read(HEADER.size)
        if len(header) < HEADER.size:
            sys.exit(f'no answer to opcode 0x{opcode:02x}')
        magic, op, status, _, sequence, _, length = HEADER.unpack(header)
        if magic != RESPONSE or op != opcode or sequence != self.sequence:
            sys.exit(f'out of step: magic 0x{magic:02x} opcode 0x{op:02x} sequence {sequence}')
        body = self.port.read(length)
        if status:
            sys.exit(f'opcode 0x{opcode:02x} answered status {status}')
        return body


def find_port():
    for info in list_ports.comports():
        if info.vid == ARDUINO_VID and info.pid in NANO_R4_PIDS:
            return info.device
    sys.exit('no Nano R4 found; name the port')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('port', nargs='?')
    parser.add_argument('--averages', type=int, default=16)
    parser.add_argument('--repeat', type=int, default=1)
    args = parser.parse_args()

    dev = Device(args.port or find_port())

    magic, protocol, firmware, board, name = struct.unpack('<IHHI20s', dev.call(0x01))
    if magic != 0x5A594C50:
        sys.exit(f'not an instrument: magic 0x{magic:08x}')
    name = name.rstrip(b'\0').decode()
    print(f'{name}  protocol {protocol}  '
          f'firmware {firmware >> 8}.{firmware & 0xFF}  board {board}')

    caps = struct.unpack('<BBBB9I2I', dev.call(0x02))
    channels, bits, logic, ranges = caps[:4]
    reference = caps[4 + 7] / 1e6
    print(f'{channels} analogue ch, {bits} bit, {logic} logic ch, {ranges} range(s), '
          f'reference {reference:.3f} V')

    raw = dev.call(0x07)
    for i in range(0, len(raw), 32):
        _, _, _, gain, offset, rname = struct.unpack('<BBHii20s', raw[i:i + 32])
        rname = rname.rstrip(b'\0').decode()
        print(f'range {i // 32}: {rname}  '
              f'gain {gain / 1e6:.6f}  offset {offset / 1e6:.6f} V')

    full_scale = ((1 << bits) - 1) << (16 - bits)
    for _ in range(args.repeat):
        values = struct.unpack(f'<{channels}H', dev.call(0x15, struct.pack('<H', args.averages)))
        print('  '.join(f'A{c} {v / full_scale * reference:6.4f}' for c, v in enumerate(values)))


if __name__ == '__main__':
    main()
