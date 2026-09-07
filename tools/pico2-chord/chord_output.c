#include "chord_output.h"
#define PIN_CHORD_BASE 0
#define CHORD_VOICES 4
#include "hardware/clocks.h"
#include "hardware/gpio.h"
#include "hardware/pwm.h"

// Equal temperament, A4 = 440 Hz. Millihertz avoids floating point at startup.
static const uint32_t note_millihz[CHORD_VOICES] = {261626, 311127, 369994, 440000};

_Static_assert(PIN_CHORD_BASE == 0 && CHORD_VOICES == 4, "GPIO0…7 use PWM slices 0…3");

void chord_output_init(void)
{
    const uint64_t clock_millihz = (uint64_t)clock_get_hz(clk_sys) * 1000;
    uint32_t enabled_mask = 0;
    for (uint voice = 0; voice < CHORD_VOICES; ++voice) {
        const uint pin = PIN_CHORD_BASE + 2 * voice;
        const uint slice = pwm_gpio_to_slice_num(pin);
        const uint64_t frequency = note_millihz[voice];
        // Integer dividers avoid fractional-divider timing modulation. Round
        // the period to an even count so both halves are exactly equal.
        uint32_t divider = (uint32_t)((clock_millihz + frequency * 65536 - 1)
                                     / (frequency * 65536));
        if (divider < 1) divider = 1;
        if (divider > 255) divider = 255;
        const uint64_t half_denominator = 2 * frequency * divider;
        uint32_t period = 2 * (uint32_t)((clock_millihz + half_denominator / 2)
                                        / half_denominator);
        if (period < 2) period = 2;
        if (period > 65536) period = 65536;

        pwm_config config = pwm_get_default_config();
        pwm_config_set_clkdiv_int(&config, divider);
        pwm_config_set_wrap(&config, (uint16_t)(period - 1));
        pwm_config_set_output_polarity(&config, false, true);
        pwm_init(slice, &config, false);
        pwm_set_both_levels(slice, (uint16_t)(period / 2), (uint16_t)(period / 2));
        gpio_set_function(pin, GPIO_FUNC_PWM);
        gpio_set_function(pin + 1, GPIO_FUNC_PWM);
        enabled_mask |= 1u << slice;
    }
    // Start the four counters together without stopping other enabled PWM slices.
    pwm_set_mask_enabled(pwm_hw->en | enabled_mask);
}
