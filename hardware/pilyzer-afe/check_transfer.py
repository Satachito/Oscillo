"""Prints the input-to-converter transfer of the PiLyzer rev A front end.

Run this after changing any resistor value: the constants it prints are the
ones the application compiles into `FrontEnd.revA`, and the corner figures say
how much of the range a 1% part can eat.
"""

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
