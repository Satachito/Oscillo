#include "signal_source.h"

#include <math.h>

// A quarter of a percent of the range is left at each end, so that a peak
// lands on a duty the hardware can actually produce rather than on the rail.
#define CENTRE 127.5f
#define SINE_AMPLITUDE 0.95f
// White comes out of the generator uniform, so its peak is exactly its
// amplitude and it can have nearly all of the range. The two tilted ones are
// filtered, so their peaks are a matter of luck: these are set from measuring
// half a million samples and leaving room above the worst of them.
#define WHITE_AMPLITUDE 0.90f
#define PINK_AMPLITUDE 0.60f
#define BROWN_AMPLITUDE 0.45f

#define TABLE_LENGTH 256
static float sine_table[TABLE_LENGTH + 1];
static int table_ready;

static void build_table(void) {
    if (table_ready) return;
    for (int index = 0; index <= TABLE_LENGTH; ++index) {
        sine_table[index] = sinf(2.0f * (float)M_PI * (float)index / (float)TABLE_LENGTH);
    }
    table_ready = 1;
}

void signal_source_init(signal_source_t *source, float sample_rate_hz,
                        float sine_hz, uint32_t seed) {
    build_table();
    source->phase = 0;
    // The accumulator wraps at one turn, so a step is the fraction of a turn
    // one sample covers, in units of 2^-32 turns.
    source->step = (uint32_t)llrintf(4294967296.0f * sine_hz / sample_rate_hz);
    source->rng = seed ? seed : 0x1234567u;
    source->pink[0] = source->pink[1] = source->pink[2] = 0;
    source->brown = 0;
}

/// Interpolated between table entries: without it a 256-entry table leaves
/// steps a spectrum analyser reads as harmonics.
static float sine(const signal_source_t *source) {
    const uint32_t index = source->phase >> 24;                  // 0…255
    const float fraction = (float)(source->phase & 0xFFFFFFu) / 16777216.0f;
    return sine_table[index] + fraction * (sine_table[index + 1] - sine_table[index]);
}

static float white(signal_source_t *source) {
    // xorshift32: a full period of 2^32-1, and three shifts a sample.
    uint32_t x = source->rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    source->rng = x;
    return (float)(int32_t)x / 2147483648.0f;
}

/// Paul Kellett's three-pole fit to a 3 dB per octave tilt, which is within a
/// few tenths of a decibel across the audio band and costs three multiplies.
static float pink(signal_source_t *source, float noise) {
    source->pink[0] = 0.99765f * source->pink[0] + noise * 0.0990460f;
    source->pink[1] = 0.96300f * source->pink[1] + noise * 0.2965164f;
    source->pink[2] = 0.57000f * source->pink[2] + noise * 1.0526913f;
    return (source->pink[0] + source->pink[1] + source->pink[2] + noise * 0.1848f) * 0.2f;
}

/// Brown is white integrated — 6 dB per octave — and an integrator with no
/// leak wanders off the rail and stays there, so this one forgets slowly.
static float brown(signal_source_t *source, float noise) {
    source->brown = 0.995f * source->brown + 0.02f * noise;
    return source->brown * 4.0f;
}

static uint8_t duty(float value, float amplitude) {
    const float level = CENTRE + CENTRE * amplitude * value;
    if (level <= 0) return 0;
    if (level >= (float)SIGNAL_TOP) return SIGNAL_TOP;
    return (uint8_t)lrintf(level);
}

void signal_source_next(signal_source_t *source, uint8_t out[SIGNAL_COUNT]) {
    const float noise = white(source);
    out[0] = duty(sine(source), SINE_AMPLITUDE);
    out[1] = duty(noise, WHITE_AMPLITUDE);
    out[2] = duty(pink(source, noise), PINK_AMPLITUDE);
    out[3] = duty(brown(source, noise), BROWN_AMPLITUDE);
    source->phase += source->step;
}
