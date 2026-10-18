#pragma once

#include <stdint.h>

// Four test signals as PWM duty values: a 440 Hz pseudo-sine and white, pink
// and brown noise, one per output. Nothing here touches the SDK, so the host
// tests run exactly the code the Pico does.

enum {
    SIGNAL_COUNT = 4,     // sine, white, pink, brown — in that order
    SIGNAL_TOP = 255,     // 8-bit duty: an 8-bit carrier is 586 kHz at 150 MHz (488 at an RP2040's 125)
};

// Integers throughout, a sample: the original Pico has no floating point unit,
// and its software floats took longer than the 20 µs a sample has, so the
// timer starved USB and the board stopped answering. Noise values are in units
// of 2^-15 of full scale.
typedef struct {
    uint32_t phase, step;   // sine, in turns of a 32-bit accumulator
    uint32_t rng;           // white
    int32_t pink[3];        // the three poles that tilt white into pink
    int32_t brown;          // the leaky integral that tilts it further
} signal_source_t;

/// `seed` may be anything but zero; zero is replaced, since the generator
/// would otherwise stay there.
void signal_source_init(signal_source_t *source, float sample_rate_hz,
                        float sine_hz, uint32_t seed);

/// One sample of each signal, as duty values from 0 to SIGNAL_TOP.
void signal_source_next(signal_source_t *source, uint8_t out[SIGNAL_COUNT]);
