#include "signal_source.h"

#include <math.h>

// Everything a sample does is integer arithmetic (signal_source.h has why).
// Values are in units of 2^-15 of full scale, filter coefficients in units of
// 2^-16, and duties are worked out in 256ths of a count before rounding.
// Only the table is built with floating point, once.

// A quarter of a percent of the range is left at each end, so that a peak
// lands on a duty the hardware can actually produce rather than on the rail.
#define CENTRE 127.5
#define SINE_AMPLITUDE 0.95
// White comes out of the generator uniform, so its peak is exactly its
// amplitude and it can have nearly all of the range. The two tilted ones are
// filtered, so their peaks are a matter of luck: these are set from measuring
// half a million samples and leaving room above the worst of them.
#define WHITE_AMPLITUDE 0.90
#define PINK_AMPLITUDE 0.60
#define BROWN_AMPLITUDE 0.45

// A constant in units of 2^-16, rounded.
#define Q16(x) ((int32_t)((x) * 65536.0 + 0.5))
// Counts per unit of value, in 256ths: what a full-scale value moves the duty.
#define SPAN(amplitude) ((int32_t)(CENTRE * (amplitude) * 256.0 + 0.5))

#define TABLE_LENGTH 256
static int16_t sine_table[TABLE_LENGTH + 1];
static int table_ready;

static void build_table(void) {
    if (table_ready) return;
    for (int index = 0; index <= TABLE_LENGTH; ++index) {
        sine_table[index] = (int16_t)lrint(32767.0 * sin(2.0 * M_PI * index / TABLE_LENGTH));
    }
    table_ready = 1;
}

void signal_source_init(signal_source_t *source, float sample_rate_hz,
                        float sine_hz, uint32_t seed) {
    build_table();
    source->phase = 0;
    // The accumulator wraps at one turn, so a step is the fraction of a turn
    // one sample covers, in units of 2^-32 turns.
    source->step = (uint32_t)llrint(4294967296.0 * sine_hz / sample_rate_hz);
    source->rng = seed ? seed : 0x1234567u;
    source->pink[0] = source->pink[1] = source->pink[2] = 0;
    source->brown = 0;
}

/// A value times a coefficient in units of 2^-16, rounded. 64 bits, because a
/// filter's state times a coefficient near one does not fit in 32.
static inline int32_t scale(int32_t value, int32_t coefficient) {
    return (int32_t)(((int64_t)value * coefficient + 32768) >> 16);
}

/// Interpolated between table entries: without it a 256-entry table leaves
/// steps a spectrum analyser reads as harmonics.
static int32_t sine(const signal_source_t *source) {
    const uint32_t index = source->phase >> 24;                   // 0…255
    const int32_t fraction = (int32_t)((source->phase >> 8) & 0xFFFFu);
    const int32_t here = sine_table[index], next = sine_table[index + 1];
    return here + (((next - here) * fraction + 32768) >> 16);
}

static int32_t white(signal_source_t *source) {
    // xorshift32: a full period of 2^32-1, and three shifts a sample.
    uint32_t x = source->rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    source->rng = x;
    return (int32_t)x >> 16;
}

/// Paul Kellett's three-pole fit to a 3 dB per octave tilt, which is within a
/// few tenths of a decibel across the audio band and costs three multiplies.
static int32_t pink(signal_source_t *source, int32_t noise) {
    source->pink[0] = scale(source->pink[0], Q16(0.99765)) + scale(noise, Q16(0.0990460));
    source->pink[1] = scale(source->pink[1], Q16(0.96300)) + scale(noise, Q16(0.2965164));
    source->pink[2] = scale(source->pink[2], Q16(0.57000)) + scale(noise, Q16(1.0526913));
    return scale(source->pink[0] + source->pink[1] + source->pink[2] + scale(noise, Q16(0.1848)),
                 Q16(0.2));
}

/// Brown is white integrated — 6 dB per octave — and an integrator with no
/// leak wanders off the rail and stays there, so this one forgets slowly.
static int32_t brown(signal_source_t *source, int32_t noise) {
    source->brown = scale(source->brown, Q16(0.995)) + scale(noise, Q16(0.02));
    return source->brown * 4;
}

static uint8_t duty(int32_t value, int32_t span) {
    // Past twice full scale the duty is on a rail anyway, and inside it the
    // product below fits in 32 bits.
    if (value > 65535) value = 65535;
    if (value < -65536) value = -65536;
    const int32_t level = SPAN(1.0) + ((value * span) >> 15);    // 256ths of a count
    if (level <= 0) return 0;
    if (level >= SIGNAL_TOP * 256) return SIGNAL_TOP;
    return (uint8_t)((level + 128) >> 8);
}

void signal_source_next(signal_source_t *source, uint8_t out[SIGNAL_COUNT]) {
    const int32_t noise = white(source);
    out[0] = duty(sine(source), SPAN(SINE_AMPLITUDE));
    out[1] = duty(noise, SPAN(WHITE_AMPLITUDE));
    out[2] = duty(pink(source, noise), SPAN(PINK_AMPLITUDE));
    out[3] = duty(brown(source, noise), SPAN(BROWN_AMPLITUDE));
    source->phase += source->step;
}
