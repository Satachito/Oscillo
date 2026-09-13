#pragma once

#include <stdint.h>

// Four test signals as PWM duty values: a 440 Hz pseudo-sine and white, pink
// and brown noise, one per output. Nothing here touches the SDK, so the host
// tests run exactly the code the Pico does.

enum {
    SIGNAL_COUNT = 4,     // sine, white, pink, brown — in that order
    SIGNAL_TOP = 255,     // 8-bit duty: an 8-bit carrier is 586 kHz at 150 MHz
};

typedef struct {
    uint32_t phase, step;   // sine, in turns of a 32-bit accumulator
    uint32_t rng;           // white
    float pink[3];          // the three poles that tilt white into pink
    float brown;            // the leaky integral that tilts it further
} signal_source_t;

/// `seed` may be anything but zero; zero is replaced, since the generator
/// would otherwise stay there.
void signal_source_init(signal_source_t *source, float sample_rate_hz,
                        float sine_hz, uint32_t seed);

/// One sample of each signal, as duty values from 0 to SIGNAL_TOP.
void signal_source_next(signal_source_t *source, uint8_t out[SIGNAL_COUNT]);
