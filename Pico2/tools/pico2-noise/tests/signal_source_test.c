// The generator, checked on the host: the same file the Pico runs.
#include "../signal_source.c"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RATE 50000
#define SECONDS 4
#define SAMPLES (RATE * SECONDS)
#define SINE_HZ 440

static uint8_t samples[SIGNAL_COUNT][SAMPLES];

static double mean(const uint8_t *values) {
    double total = 0;
    for (int index = 0; index < SAMPLES; ++index) total += values[index];
    return total / SAMPLES;
}

/// Mean square about the signal's own mean.
static double power(const uint8_t *values) {
    const double centre = mean(values);
    double total = 0;
    for (int index = 0; index < SAMPLES; ++index) {
        const double deviation = values[index] - centre;
        total += deviation * deviation;
    }
    return total / SAMPLES;
}

/// Mean square of the difference between neighbours. Against the signal's own
/// power this says how much of it lives up at the top of the band, which is
/// what tells the three noises apart without an FFT: white is 2, and every
/// octave of tilt halves it.
static double roughness(const uint8_t *values) {
    double total = 0;
    for (int index = 1; index < SAMPLES; ++index) {
        const double step = (double)values[index] - values[index - 1];
        total += step * step;
    }
    return (total / (SAMPLES - 1)) / power(values);
}

int main(void) {
    signal_source_t source;
    signal_source_init(&source, (float)RATE, (float)SINE_HZ, 1);
    for (int index = 0; index < SAMPLES; ++index) {
        uint8_t frame[SIGNAL_COUNT];
        signal_source_next(&source, frame);
        for (int signal = 0; signal < SIGNAL_COUNT; ++signal) samples[signal][index] = frame[signal];
    }

    // Every signal sits on the middle of the range and uses it without ever
    // reaching a rail, which on a PWM carrier would be a duty the filter turns
    // into a flat top rather than a peak.
    for (int signal = 0; signal < SIGNAL_COUNT; ++signal) {
        const double centre = mean(samples[signal]);
        assert(centre > 125 && centre < 130);
        uint8_t low = 255, high = 0;
        for (int index = 0; index < SAMPLES; ++index) {
            if (samples[signal][index] < low) low = samples[signal][index];
            if (samples[signal][index] > high) high = samples[signal][index];
        }
        assert(low > 0 && high < 255);
        assert(high - low > 100);          // and it is not a whisper either
    }

    // The sine is a sine: within half a count of the ideal one, everywhere.
    double worst = 0;
    for (int index = 0; index < SAMPLES; ++index) {
        const double ideal = 127.5 + 127.5 * 0.95 * sin(2 * M_PI * SINE_HZ * index / (double)RATE);
        const double error = fabs(samples[0][index] - ideal);
        if (error > worst) worst = error;
    }
    assert(worst < 0.6);

    // And it is 440 Hz: count the rising crossings of its own centre.
    int crossings = 0;
    for (int index = 1; index < SAMPLES; ++index) {
        if (samples[0][index - 1] < 128 && samples[0][index] >= 128) ++crossings;
    }
    // Within one: the record starts on a crossing, so whether it is counted
    // depends on which side of the centre the first sample rounds to.
    assert(abs(crossings - SINE_HZ * SECONDS) <= 1);

    // White, pink, brown: each one is tilted further down than the last, and
    // white is where an uncorrelated signal has to be.
    const double white_roughness = roughness(samples[1]);
    const double pink_roughness = roughness(samples[2]);
    const double brown_roughness = roughness(samples[3]);
    assert(white_roughness > 1.9 && white_roughness < 2.1);
    assert(pink_roughness < white_roughness / 2);
    assert(brown_roughness < pink_roughness / 10);

    // A different seed is a different noise, and the same seed is the same
    // one — a generator nobody can reproduce is no use in a test.
    signal_source_t other;
    signal_source_init(&other, (float)RATE, (float)SINE_HZ, 99);
    uint8_t first[SIGNAL_COUNT], second[SIGNAL_COUNT];
    signal_source_next(&other, first);
    signal_source_init(&other, (float)RATE, (float)SINE_HZ, 99);
    signal_source_next(&other, second);
    assert(memcmp(first, second, sizeof first) == 0);
    signal_source_init(&other, (float)RATE, (float)SINE_HZ, 12345);
    signal_source_next(&other, second);
    assert(first[1] != second[1]);

    printf("Signals: sine within %.2f counts of ideal, %d crossings in %d s (%d expected); "
           "roughness white %.2f, pink %.2f, brown %.3f\n",
           worst, crossings, SECONDS, SINE_HZ * SECONDS,
           white_roughness, pink_roughness, brown_roughness);
    return 0;
}
