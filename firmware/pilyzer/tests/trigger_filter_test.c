#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "../trigger_filter.h"

static void bypass_and_reset(void)
{
    trigger_filter_t filter = {0};
    trigger_filter_configure(&filter, 0, 4e-6);
    for (int code = 0; code <= 65535; code += 257) {
        assert(trigger_filter_sample(&filter, (uint16_t)code) == code);
        assert(filter.remaining == 0);
    }
    trigger_filter_configure(&filter, 1000, 4e-6);
    assert(filter.settling_samples == 199);
    for (int i = 0; i < 1000; i++) trigger_filter_sample(&filter, 65520);
    trigger_filter_reset(&filter);
    assert(trigger_filter_sample(&filter, 0) == 0);
    assert(filter.remaining == filter.settling_samples - 1);
}

static void timing_and_extremes(void)
{
    // The same physical cutoff must decay at the same rate on different
    // timebases, even though their filter coefficients differ.
    for (int divisor = 1; divisor <= 4; divisor *= 2) {
        double dt = divisor * 4e-6;
        trigger_filter_t filter = {0};
        trigger_filter_configure(&filter, 1000, dt);
        trigger_filter_sample(&filter, 0);
        for (int i = 0; i < 40 / divisor; i++) trigger_filter_sample(&filter, 65520);
        double expected = 65520 * (1 - exp(-2 * 3.141592653589793 * 1000 * 160e-6));
        assert(fabs((double)filter.value_q16 / 65536 - expected) < 1);
    }
    for (int cutoff = 100; cutoff <= 100000; cutoff *= 10) {
        trigger_filter_t filter = {0};
        trigger_filter_configure(&filter, cutoff, 2e-6);
        for (int i = 0; i < 20000; i++) {
            int32_t value = trigger_filter_sample(&filter, i % 2 ? 65535 : 0);
            assert(value >= 0 && value <= 65535);
        }
    }
}

static double crossing(uint32_t cutoff, double noise_phase)
{
    const double frequency = 194;
    const double dt = 4e-6;
    trigger_filter_t filter = {0};
    trigger_filter_configure(&filter, cutoff, dt);
    bool armed = false;
    for (int i = 0; i < 2000; i++) {
        double t = -0.45 / frequency + i * dt;
        // A 30-step cycle with independently phased high-frequency ripple.
        double stair = sin(6.283185307179586 * floor(t * frequency * 30) / 30);
        double ripple = 200 * sin(6.283185307179586 * 8000 * t + noise_phase);
        uint16_t raw = (uint16_t)lround(32768 + 20000 * stair + ripple);
        int32_t value = trigger_filter_sample(&filter, raw);
        if (filter.remaining) continue;
        if (!armed) {
            if (value < 32768 - 256) armed = true;
        } else if (value >= 32768) {
            return t;
        }
    }
    assert(!"no crossing found");
    return 0;
}

static void stepped_194hz_jitter(void)
{
    double raw_min = 1, raw_max = -1, filtered_min = 1, filtered_max = -1;
    for (int phase = 0; phase < 128; phase++) {
        double angle = phase * 6.283185307179586 / 128;
        double raw = crossing(0, angle);
        double filtered = crossing(1000, angle);
        raw_min = fmin(raw_min, raw); raw_max = fmax(raw_max, raw);
        filtered_min = fmin(filtered_min, filtered); filtered_max = fmax(filtered_max, filtered);
    }
    double raw_span = raw_max - raw_min;
    double filtered_span = filtered_max - filtered_min;
    printf("194 Hz / 30 steps / 8 kHz ripple: trigger jitter %.1f us -> %.1f us peak-to-peak\n",
           raw_span * 1e6, filtered_span * 1e6);
    assert(raw_span > 40e-6);
    assert(filtered_span < raw_span / 2);
    assert(filtered_min > raw_min); // The marker retains the filter's delay.
}

int main(void)
{
    bypass_and_reset();
    timing_and_extremes();
    stepped_194hz_jitter();
    puts("Trigger LPF: 3 regressions passed");
}
