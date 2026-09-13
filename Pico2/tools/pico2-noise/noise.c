// Four test signals on a dedicated Pico 2: 440 Hz on GPIO0, then white, pink
// and brown noise on GPIO1, 2 and 3.
//
// The RP2350 has no converter to play them out of, so each is a PWM carrier
// whose duty follows the sample — a one-bit DAC that an RC on the pin turns
// back into a voltage. See README.md for what to fit.
#include <stdio.h>

#include "hardware/clocks.h"
#include "hardware/pwm.h"
#include "pico/stdlib.h"
#include "signal_source.h"

#define PIN_SIGNAL_BASE 0
#define SAMPLE_RATE_HZ 50000
#define SINE_HZ 440

static signal_source_t source;

// GPIO0/1 are the two channels of slice 0 and GPIO2/3 of slice 1, so four
// signals cost two slices and one interrupt.
static bool next_sample(repeating_timer_t *timer) {
    (void)timer;
    uint8_t duty[SIGNAL_COUNT];
    signal_source_next(&source, duty);
    for (uint index = 0; index < SIGNAL_COUNT; ++index) {
        const uint pin = PIN_SIGNAL_BASE + index;
        pwm_set_chan_level(pwm_gpio_to_slice_num(pin), pwm_gpio_to_channel(pin), duty[index]);
    }
    return true;
}

int main(void) {
    stdio_init_all();
    gpio_init(PICO_DEFAULT_LED_PIN);
    gpio_set_dir(PICO_DEFAULT_LED_PIN, GPIO_OUT);

    signal_source_init(&source, (float)SAMPLE_RATE_HZ, (float)SINE_HZ, 0x2545F491u);

    pwm_config config = pwm_get_default_config();
    pwm_config_set_wrap(&config, SIGNAL_TOP);          // 8-bit duty
    pwm_config_set_clkdiv_int(&config, 1);             // and the fastest carrier
    for (uint index = 0; index < SIGNAL_COUNT; ++index) {
        const uint pin = PIN_SIGNAL_BASE + index;
        gpio_set_function(pin, GPIO_FUNC_PWM);
        pwm_init(pwm_gpio_to_slice_num(pin), &config, false);
        pwm_set_chan_level(pwm_gpio_to_slice_num(pin), pwm_gpio_to_channel(pin), SIGNAL_TOP / 2);
    }
    for (uint index = 0; index < SIGNAL_COUNT; index += 2) {
        pwm_set_enabled(pwm_gpio_to_slice_num(PIN_SIGNAL_BASE + index), true);
    }

    static repeating_timer_t timer;
    // Negative: the period is from the start of one call to the start of the
    // next, so a sample that takes longer does not slow the rate.
    if (!add_repeating_timer_us(-1000000 / SAMPLE_RATE_HZ, next_sample, NULL, &timer)) {
        puts("could not start the sample timer");
        return 1;
    }

    const char *names[] = {"440 Hz sine", "white noise", "pink noise", "brown noise"};
    for (;;) {
        const double carrier = clock_get_hz(clk_sys) / (double)(SIGNAL_TOP + 1);
        printf("%d samples a second, %.1f kHz carrier, 0-3.3 V:\n", SAMPLE_RATE_HZ, carrier / 1000);
        for (uint index = 0; index < SIGNAL_COUNT; ++index) {
            printf("  GPIO%u  %s\n", PIN_SIGNAL_BASE + index, names[index]);
        }
        for (int blink = 0; blink < 10; ++blink) {
            gpio_put(PICO_DEFAULT_LED_PIN, blink % 2 == 0);
            sleep_ms(500);
        }
    }
}
