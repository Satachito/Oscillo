"""Prints the input-to-converter transfer and the anti-alias response.

Run this after changing any resistor value: the constants it prints are the
ones the application compiles into `FrontEnd.revA`, and the corner figures say
how much of the range a 1% part can eat.
"""

import math
from itertools import product

R_SERIES = 998_000.0        # R1 + R2
R_TOP = 125_000.0           # R3, to 3V3
R_BOTTOM = 143_000.0        # R4, to AGND
GAIN_FEEDBACK = 10_000.0    # R7
GAIN_GROUND = 2_670.0       # R8
SUPPLY = 3.3
VMID = SUPPLY / 2


def stage_one(vin, r_series=R_SERIES, r_top=R_TOP, r_bottom=R_BOTTOM):
    """Voltage at the divider node."""
    conductance = 1 / r_series + 1 / r_top + 1 / r_bottom
    return (vin / r_series + SUPPLY / r_top) / conductance


def transfer(r_series=R_SERIES, r_top=R_TOP, r_bottom=R_BOTTOM, gain=1.0):
    """The straight line the application needs: (gain, offset)."""
    zero = gain * (stage_one(0, r_series, r_top, r_bottom) - VMID) + VMID
    one = gain * (stage_one(1, r_series, r_top, r_bottom) - VMID) + VMID
    return one - zero, zero


FINE_GAIN = 1 + GAIN_FEEDBACK / GAIN_GROUND
RANGES = (("+/-25 V", 1.0, 25.0), ("+/-5 V", FINE_GAIN, 5.0))

print(f"fine-range amplifier gain {FINE_GAIN:.4f}")
node_impedance = 1 / (1 / R_SERIES + 1 / R_TOP + 1 / R_BOTTOM)
print(f"input impedance  {R_SERIES + 1 / (1 / R_TOP + 1 / R_BOTTOM):,.0f} ohm")
print(f"node impedance   {node_impedance:,.0f} ohm")
print(f"compensation     C_series = C_node / {R_SERIES / (1 / (1 / R_TOP + 1 / R_BOTTOM)):.1f}")

for name, gain, limit in RANGES:
    slope, offset = transfer(gain=gain)
    print(f"\n{name}:  Vadc = {offset:.6f} + {slope:.6f} * Vin")
    for vin in (-limit, 0.0, limit):
        value = gain * (stage_one(vin) - VMID) + VMID
        flag = "" if 0.0 <= value <= SUPPLY else "   OUT OF RANGE"
        print(f"  {vin:+6.1f} V -> {value:.4f} V{flag}")

    print("  1% resistor corners at the ends of the range")
    for vin in (-limit, limit):
        values = [
            gain * (stage_one(vin, R_SERIES * a, R_TOP * b, R_BOTTOM * c) - VMID) + VMID
            for a, b, c in product((0.99, 1.01), repeat=3)
        ]
        print(f"  {vin:+6.1f} V -> {min(values):.4f} .. {max(values):.4f} V")

# --- Anti-alias filter ---------------------------------------------------
# One unity-gain Sallen-Key section per channel, between the gain stage and the
# converter. Equal resistors, so
#     fc = 1 / (2*pi*R*sqrt(C1*C2))      Q = 0.5*sqrt(C1/C2)
# C1 is the feedback capacitor and C2 returns to VMID, which is AC ground and
# keeps the mid-rail bias intact through the filter.
FILTER_R = 2_670.0
FILTER_C1 = 2.2e-9
FILTER_C2 = 1.0e-9

# Per-channel sample rates: the converter's 97-cycle floor divided by however
# many channels are enabled. Nyquist is half of each.
ADC_CLOCK = 48e6
ADC_MIN_CYCLES = 97


def filter_response_db(frequency, r=FILTER_R, c1=FILTER_C1, c2=FILTER_C2):
    corner = 1 / (2 * math.pi * r * math.sqrt(c1 * c2))
    q = 0.5 * math.sqrt(c1 / c2)
    u = frequency / corner
    return 10 * math.log10(1 / ((1 - u * u) ** 2 + (u / q) ** 2))


corner = 1 / (2 * math.pi * FILTER_R * math.sqrt(FILTER_C1 * FILTER_C2))
q = 0.5 * math.sqrt(FILTER_C1 / FILTER_C2)
print(f"\nAnti-alias filter: fc {corner/1e3:.1f} kHz, Q {q:.3f} "
      f"(R {FILTER_R/1e3:g}k, C1 {FILTER_C1*1e9:g}n, C2 {FILTER_C2*1e9:g}n)")
for frequency in (1e3, 20e3, corner, 100e3):
    print(f"  {frequency/1e3:7.1f} kHz -> {filter_response_db(frequency):+6.1f} dB")

print("  at Nyquist, per channel count")
for channels in (1, 2, 3):
    rate = ADC_CLOCK / ADC_MIN_CYCLES / channels
    nyquist = rate / 2
    print(f"  {channels} ch: {rate/1e3:6.1f} kSa/s, Nyquist {nyquist/1e3:6.1f} kHz "
          f"-> {filter_response_db(nyquist):+6.1f} dB")
