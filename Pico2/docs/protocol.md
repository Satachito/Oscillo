# PiLyzer wire protocol, version 1

This is the contract between the RP2350 firmware (`firmware/pilyzer`) and the
macOS application (`Sources/PiLyzerCore`). It carries no inheritance from the
DPScope SE: nothing here describes a register of a particular microcontroller.
The host asks for *what it wants* — a sample period, a record length, a trigger
condition — and the device answers with *what it will actually do*. Every axis
the application draws is labelled from the device's answer, never from a
constant compiled into the host.

## Transport

USB 2.0 full speed, one vendor-specific interface (class `0xFF`, subclass
`0x00`, protocol `0x00`) with two bulk endpoints of 64 bytes:

| Endpoint | Direction | Use |
| --- | --- | --- |
| `0x01` | OUT | requests |
| `0x82` | IN | responses |

A vendor interface is claimed by no macOS driver, so the application opens it
directly through IOKit with no kext, no driver package and no entitlement.
Windows binds drivers by name instead, so from firmware 1.6 the device names
`WINUSB` for itself in a Microsoft OS 2.0 descriptor and the browser
application can open the same interface with nothing installed. Those are
enumeration descriptors and two vendor control requests; no byte of this
protocol changes with them.
Bulk moves roughly 1 MB/s on this link, which is what makes 16 K-point records
and deep logic captures practical.

Exactly one response follows each request, in order. The host never pipelines.

### Frame header

Twelve bytes, little-endian, on both directions:

| Offset | Type | Field |
| ---: | --- | --- |
| 0 | `u8` | magic — `0xA5` request, `0x5A` response |
| 1 | `u8` | opcode, echoed in the response |
| 2 | `u8` | status — 0 in requests, a `Status` code in responses |
| 3 | `u8` | flags, reserved, 0 |
| 4 | `u16` | sequence number, echoed in the response |
| 6 | `u16` | reserved, 0 |
| 8 | `u32` | payload length in bytes, following the header |

A payload may be longer than one 64-byte packet; it is simply the next
`length` bytes of the bulk stream. When `length` is a multiple of 64 the sender
appends a zero-length packet, so the receiver always sees a clean end of
transfer.

### Status codes

| Value | Name | Meaning |
| ---: | --- | --- |
| 0 | `ok` | |
| 1 | `unknownOpcode` | |
| 2 | `badLength` | payload length wrong for the opcode |
| 3 | `badArgument` | a field is out of range |
| 4 | `busy` | an acquisition is running |
| 5 | `notConfigured` | arm before configure |
| 6 | `noData` | read before the record completed |
| 7 | `internalError` | |

## Opcodes

| Code | Name | Request | Response |
| ---: | --- | --- | --- |
| `0x01` | `identify` | — | `Identity` |
| `0x02` | `capabilities` | — | `Capabilities` |
| `0x03` | `setLED` | `u8 on` | — |
| `0x04` | `setRange` | `u8 channel, u8 range` | — |
| `0x05` | `setCalibrationOutput` | `u8 on, u32 frequencyHz` | `u32 actualFrequencyHz` |
| `0x06` | `rebootToBootloader` | — | — (device restarts) |
| `0x10` | `analogConfigure` | `AnalogConfig` | `AcquisitionPlan` |
| `0x11` | `analogArm` | — | — |
| `0x12` | `analogStatus` | — | `AcquisitionStatus` |
| `0x13` | `analogRead` | `u32 offset, u32 count` | `u16[]` samples |
| `0x14` | `analogAbort` | — | — |
| `0x15` | `analogSample` | `u16 averages` | `u16[analogChannels]` (CH1, CH2, CH3 on firmware 1.5) |
| `0x20` | `logicConfigure` | `LogicConfig` | `AcquisitionPlan` |
| `0x21` | `logicArm` | — | — |
| `0x22` | `logicStatus` | — | `AcquisitionStatus` |
| `0x23` | `logicRead` | `u32 offset, u32 count` | `u8[]` samples |
| `0x24` | `logicAbort` | — | — |

## Structures

All little-endian and explicitly padded; no field straddles its natural
alignment.

### `Identity` — 32 bytes

| Offset | Type | Field |
| ---: | --- | --- |
| 0 | `u32` | magic `0x5A594C50` (`"PLYZ"`) |
| 4 | `u16` | protocol version — 1 |
| 6 | `u16` | firmware version, `major << 8 \| minor` |
| 8 | `u32` | board id — 0 bare Pico 2, 1 PiLyzer AFE rev A |
| 12 | `char[20]` | product name, NUL padded |

The application refuses to talk to a device whose magic or protocol version it
does not know, so nothing else on the bus can be mistaken for an instrument.

### `Capabilities` — 48 bytes

| Offset | Type | Field |
| ---: | --- | --- |
| 0 | `u8` | analogue channels |
| 1 | `u8` | the converter's own resolution in bits |
| 2 | `u8` | logic channels |
| 3 | `u8` | selectable input ranges per analogue channel |
| 4 | `u32` | analogue base clock, Hz |
| 8 | `u32` | shortest analogue conversion period, in base-clock cycles |
| 12 | `u32` | analogue record limit, samples per channel |
| 16 | `u32` | analogue pre-trigger limit, samples per channel |
| 20 | `u32` | logic base clock, Hz |
| 24 | `u32` | logic record limit, samples |
| 28 | `u32` | logic pre-trigger limit, samples |
| 32 | `u32` | reference voltage, microvolts |
| 36 | `u32` | flags |
| 40 | `u32[2]` | reserved |

The shortest conversion period is not simply the converter's conversion time.
On the RP2350 the pacing register holds the interval minus one and is only
obeyed when it is 96 or more, so the shortest interval that is actually paced
is 97 cycles — ask for 96 and the converter free-runs at about twice the rate
while still reporting the interval it was given. A host should take this field
as authoritative rather than computing it from the converter's datasheet.

Flags: bit 0 the input ranges are switched under software control, bit 1 the
board has a calibration output, bit 2 the logic inputs are buffered, bit 3
the analogue trigger supports a low-pass filter (firmware 1.2 and later).

Analogue samples are unsigned 16-bit values, left-aligned from the converter's
own resolution: a 12-bit code `c` arrives as `c << 4`. So a reading at the top
of the converter's range is `((1 << bits) - 1) << (16 - bits)` — 65520 for
twelve bits, not 65535 — and that is what the host divides by to get a fraction
of the reference. Decimation (below) fills in the bits underneath, so the same
host code reads a raw sample and a 4096-fold average without a special case.

### `AnalogConfig` — 32 bytes

| Offset | Type | Field |
| ---: | --- | --- |
| 0 | `u8` | channel mask — bit 0 CH1, bit 1 CH2, bit 2 CH3 (firmware 1.5+) |
| 1 | `u8` | trigger mode — 0 free run, 1 auto, 2 normal |
| 2 | `u8` | trigger source — slot in the ascending enabled-channel list |
| 3 | `u8` | trigger slope — 0 rising, 1 falling |
| 4 | `u16` | trigger level, in the 16-bit sample space |
| 6 | `u16` | trigger hysteresis, in the 16-bit sample space |
| 8 | `u64` | requested sample period per channel, in femtoseconds |
| 16 | `u32` | record length, samples per channel |
| 20 | `u32` | pre-trigger length, samples per channel |
| 24 | `u32` | auto-trigger timeout, microseconds |
| 28 | `u32` | trigger low-pass cutoff, Hz — 0 off, otherwise 100…100000; requires capability bit 3 |

The device picks the conversion period and the decimation factor that come
closest to the requested sample period without exceeding the converter's rate,
and reports both in the plan. It always prefers the largest decimation factor
that fits, so slow sweeps are box-car averaged rather than sub-sampled: that is
both the anti-alias filter and the extra bits of resolution.

The low-pass field reuses a formerly reserved zero word without changing the
frame size or protocol version. Old hosts continue to send zero. A host must
check capability bit 3 before requesting a nonzero cutoff; older firmware
ignores that word and would otherwise report success without filtering.

The trigger-only filter is one pole, with `alpha = 1 - exp(-2*pi*cutoff*period)`
using the actual decimated sample period. This defines the time constant; at
cutoffs near or above Nyquist, the digital response approaches bypass and is
not an analogue reconstruction filter. Filter state retains fractional ADC
codes. It runs through the pre-trigger history and waits five time constants
before accepting an edge. Re-arming, or restarting after a buffer rollover,
resets the filter and replays retained history to avoid using stale state.

Samples returned by `analogRead` are unchanged. The reported trigger index is
the sample at which the **filtered** signal crossed the level; it is not shifted
back by an assumed delay. The phase delay depends on signal frequency, so the
original trace need not cross the trigger level at that index. A record shorter
than the settling time is still supported: settling precedes the trigger search.

### `LogicConfig` — 24 bytes

| Offset | Type | Field |
| ---: | --- | --- |
| 0 | `u8` | trigger mode — 0 free run, 1 auto, 2 normal |
| 1 | `u8` | trigger channel, 0…7 |
| 2 | `u8` | trigger slope — 0 rising, 1 falling |
| 3 | `u8` | reserved |
| 4 | `u64` | requested sample period, femtoseconds |
| 12 | `u32` | record length, samples |
| 16 | `u32` | pre-trigger length, samples |
| 20 | `u32` | auto-trigger timeout, microseconds |

### `AcquisitionPlan` — 24 bytes

| Offset | Type | Field |
| ---: | --- | --- |
| 0 | `u32` | sample clock, Hz |
| 4 | `u32` | clock divisor, 24.8 fixed point |
| 8 | `u32` | decimation factor |
| 12 | `u32` | granted record length |
| 16 | `u32` | granted pre-trigger length |
| 20 | `u8` | granted channel mask |
| 21 | `u8` | conversions per sample — number of enabled analogue channels (1–3) |
| 22 | `u16` | reserved |

The sample period the host draws its time axis with is

```
period = divisor / 256 / clock * conversionsPerSample * decimation
```

which is exact: the divisor is the hardware register, not a rounded number of
nanoseconds.

### `AcquisitionStatus` — 16 bytes

| Offset | Type | Field |
| ---: | --- | --- |
| 0 | `u8` | state — 0 idle, 1 filling, 2 waiting for trigger, 3 post-trigger, 4 complete, 5 aborted, 6 overrun |
| 1 | `u8` | 1 when the record came from a real trigger, 0 when it timed out |
| 2 | `u16` | reserved |
| 4 | `u32` | samples available per channel |
| 8 | `u32` | index of the trigger within the record |
| 12 | `u32` | reserved |

## Reading a record

`analogRead` and `logicRead` address the record linearly from its first
sample; the ring the firmware captured into is unwrapped on the way out, so the
host never sees a seam. Analogue samples are interleaved in ascending enabled-channel order: mask 5
returns CH1, CH3, CH1, CH3, and mask 7 returns CH1, CH2, CH3 repeatedly. Logic samples are one byte each, bit *n* being
input D*n*.

The host reads in chunks — 8 KB is a good size — and the device answers each
chunk with one response frame.

## How a record is acquired

The firmware runs the converter continuously into a small hardware ring and
decimates into the record ring, so sampling never stops and never jitters.
While that runs it walks a scan pointer behind the write pointer looking for
the trigger condition:

1. **Filling** — until `pre-trigger` samples exist there is no history to put
   in front of a trigger, so triggers are not accepted yet.
2. **Waiting** — each new sample is tested against the level and slope, with
   hysteresis, so a noisy crossing fires once.
3. **Post-trigger** — after the edge the firmware waits for the rest of the
   record, then stops and reports the exact index of the edge.
4. **Auto mode** — if nothing crosses within the timeout and a whole record
   exists, the newest record is returned with the triggered flag clear, so the
   trace sweeps rather than freezing. **Normal mode** waits indefinitely.

If the ring fills without a trigger, the last `pre-trigger` samples are carried
to the front and the search restarts. That is the only time the instrument is
blind, and it lasts for the memory copy alone.

The logic side works the same way, except that the edge is detected by a second
PIO state machine rather than by the processor — at 150 MS/s nothing else can
keep up. The processor then finds the exact edge in the captured data, so the
trigger position is sample-accurate rather than interrupt-latency-accurate.

## Firmware 1.5 pin allocation and channel count

CH1/CH2/CH3 use GPIO26/27/28. Logic D0–D7 use GPIO8–15, range controls use
GPIO16/17/18, and `setCalibrationOutput` controls GPIO20. GPIO0–7 are unused.
Firmware 1.3/1.4 used GPIO28 for test output, and 1.2 used GPIO2.

The capability reply advertises three analogue channels. `analogSample` returns
three little-endian u16 readings (CH1, CH2, CH3), one per advertised channel;
older two-channel firmware returns two readings. The app uses the advertised
count for controls, input masks and immediate replies. Wire version and packet
layouts otherwise remain unchanged.

Changing the enabled input mask recomputes the acquisition timing. Maximum
per-channel rates are 500,000 / 250,000 / 166,666.7 samples/s for 1 / 2 / 3 inputs.
The ADC samples enabled channels sequentially, not simultaneously. Lower rates
requested by the timebase still apply; checkbox count changes the rate ceiling.
