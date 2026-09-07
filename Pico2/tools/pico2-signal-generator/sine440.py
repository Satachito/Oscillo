"""440 Hz sine on GPIO26 of a Pico 2 (RP2350).

The RP2350 has no DAC, so the sine is synthesised as a PWM carrier whose duty
cycle follows a sine table. A DMA channel feeds the table into the PWM compare
register, paced by the PWM's own wrap signal, so the timing is pure hardware —
no interrupt, no Python loop, no jitter. Put an RC low-pass on the pin
(1 kOhm + 100 nF works well) to turn the 113 kHz carrier back into a sine.

    import sine440
    gen = sine440.start()        # 440 Hz
    gen = sine440.start(1000)    # or any frequency
    gen.stop()
"""

import math
import machine
import rp2
import uctypes
from machine import Pin, PWM

PWM_BASE = 0x400A8000          # RP2350 PWM block
PWM_SLICE_STRIDE = 0x14
PWM_CSR = 0x00
PWM_CC = 0x0C
PWM_TOP = 0x10
PWM_DIV = 0x04
DREQ_PWM_WRAP0 = 32            # measured on RP2350: slice n -> 32 + n

DEFAULT_PIN = 26
TABLE_LENGTH = 256             # a power of two: the DMA rings on the table
TABLE_BYTES = TABLE_LENGTH * 4


class SineOutput:
    """A running sine generator. Keep a reference to it or it stops."""

    def __init__(self, pin, frequency, amplitude):
        self._pin = pin
        self._slice = (pin // 2) % 8
        self._channel = pin % 2                      # 0 = A, 1 = B
        self._pwm = PWM(Pin(pin))
        self._pwm.freq(int(round(frequency * TABLE_LENGTH)))
        self._pwm.duty_u16(32768)

        registers = PWM_BASE + self._slice * PWM_SLICE_STRIDE
        # Enable the slice by hand: a slice that was deinit-ed earlier stays
        # switched off, and a counter that never wraps means the DMA waits
        # forever for its pacing signal.
        machine.mem32[registers + PWM_CSR] = machine.mem32[registers + PWM_CSR] | 1
        top = machine.mem32[registers + PWM_TOP]
        divider = machine.mem32[registers + PWM_DIV] / 16
        self.carrier = machine.freq() / ((top + 1) * divider)
        self.frequency = self.carrier / TABLE_LENGTH

        self._table = self._build_table(top, amplitude)
        self._start_dma(registers)

    def _build_table(self, top, amplitude):
        # The DMA rings its read address, which needs the table aligned to its
        # own size, so carve an aligned window out of a larger buffer.
        self._buffer = bytearray(TABLE_BYTES * 2)
        address = uctypes.addressof(self._buffer)
        self._table_address = address + (-address % TABLE_BYTES)
        table = uctypes.bytearray_at(self._table_address, TABLE_BYTES)

        span = top * amplitude / 2
        middle = (top + 1) / 2
        shift = 16 if self._channel else 0
        for index in range(TABLE_LENGTH):
            level = int(middle + span * math.sin(2 * math.pi * index / TABLE_LENGTH))
            level = max(0, min(top, level)) << shift
            table[index * 4 + 0] = level & 0xFF
            table[index * 4 + 1] = (level >> 8) & 0xFF
            table[index * 4 + 2] = (level >> 16) & 0xFF
            table[index * 4 + 3] = (level >> 24) & 0xFF
        return table

    def _start_dma(self, registers):
        self._data = rp2.DMA()
        self._reload = rp2.DMA()

        # The reload channel writes the table address back into the data
        # channel's trigger register, which restarts it. Chaining it to itself
        # means "no chain", so the pair loops forever. It has to be armed
        # before the data channel, which chains straight into it.
        self._pointer = bytearray(4)
        for shift in range(4):
            self._pointer[shift] = (self._table_address >> (8 * shift)) & 0xFF
        trigger = 0x50000000 + self._data.channel * 0x40 + 0x3C   # AL3_READ_ADDR_TRIG

        self._reload.config(
            read=uctypes.addressof(self._pointer),
            write=trigger,
            count=1,
            ctrl=self._reload.pack_ctrl(
                size=2,
                inc_read=False,
                inc_write=False,
                treq_sel=0x3F,                # unpaced: run as soon as chained
                chain_to=self._reload.channel,
            ),
        )

        # The data channel walks the table into the compare register, one entry
        # per PWM period, then hands over to the reload channel. Enabling a
        # channel is not enough to start it — it has to be triggered.
        self._data.config(
            read=self._table_address,
            write=registers + PWM_CC,
            count=TABLE_LENGTH,
            ctrl=self._data.pack_ctrl(
                size=2,
                inc_read=True,
                inc_write=False,
                ring_sel=0,                   # ring the read address
                ring_size=10,                 # ... every 1024 bytes
                treq_sel=DREQ_PWM_WRAP0 + self._slice,
                chain_to=self._reload.channel,
            ),
            trigger=True,
        )

    def stop(self):
        self._data.active(0)
        self._reload.active(0)
        self._data.close()
        self._reload.close()
        self._pwm.deinit()
        Pin(self._pin, Pin.IN)

    def __repr__(self):
        return "<sine %.3f Hz on GPIO%d, %.1f kHz carrier>" % (
            self.frequency, self._pin, self.carrier / 1000)


def start(frequency=440, pin=DEFAULT_PIN, amplitude=0.98):
    """Starts the generator and returns it. Call .stop() to release the pin."""
    return SineOutput(pin, frequency, amplitude)
