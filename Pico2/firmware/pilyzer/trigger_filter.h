#pragma once
#include <math.h>
#include <stdbool.h>
#include <stdint.h>

// One-pole low-pass, applied only to the trigger comparator input. Q16 state
// preserves sub-code resolution; the sample buffer is never modified.
#define TRIGGER_FILTER_Q30 (1LL << 30)
#define TRIGGER_FILTER_MIN_HZ 100u
#define TRIGGER_FILTER_MAX_HZ 100000u

typedef struct {
    uint32_t alpha_q30;
    uint32_t settling_samples;
    uint32_t remaining;
    int64_t value_q16;
    bool initialized;
} trigger_filter_t;

static inline void trigger_filter_reset(trigger_filter_t *filter)
{
    filter->initialized = false;
    filter->remaining = filter->settling_samples;
}

static inline void trigger_filter_configure(trigger_filter_t *filter,
                                            uint32_t frequency_hz, double period)
{
    double exponent = 6.283185307179586 * frequency_hz * period;
    filter->alpha_q30 = frequency_hz == 0 ? 0 :
        (uint32_t)llround(-expm1(-exponent) * TRIGGER_FILTER_Q30);
    filter->settling_samples = frequency_hz == 0 ? 0 : (uint32_t)ceil(5.0 / exponent);
    trigger_filter_reset(filter);
}

static inline int32_t trigger_filter_sample(trigger_filter_t *filter, uint16_t sample)
{
    if (filter->alpha_q30 == 0) return sample;
    int64_t target = (int64_t)sample * 65536;
    if (!filter->initialized) {
        filter->value_q16 = target;
        filter->initialized = true;
    } else {
        filter->value_q16 += (target - filter->value_q16) * filter->alpha_q30 / TRIGGER_FILTER_Q30;
    }
    if (filter->remaining) filter->remaining--;
    return (int32_t)((filter->value_q16 + 32768) / 65536);
}
