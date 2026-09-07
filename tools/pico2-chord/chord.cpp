// Standalone version of the instrument's four complementary note outputs.
// Uses the same implementation so pin order, frequency and polarity stay equal.
#include <cstdio>
#include "../../firmware/pilyzer/chord_output.h"
#include "hardware/clocks.h"
#include "hardware/pwm.h"
#include "pico/stdlib.h"

int main() {
    stdio_init_all();
    gpio_init(PICO_DEFAULT_LED_PIN);
    gpio_set_dir(PICO_DEFAULT_LED_PIN, GPIO_OUT);
    chord_output_init();
    const char *notes[] = {"C4", "Eb4", "F#4", "A4"};
    for (;;) {
        puts("C4 / Eb4 / F#4 / A4: even GPIO normal, odd GPIO inverted");
        for (uint i = 0; i < 4; ++i) {
            const uint slice = pwm_gpio_to_slice_num(2 * i);
            const double divider = pwm_hw->slice[slice].div / 16.0;
            const double period = pwm_hw->slice[slice].top + 1;
            const double frequency = clock_get_hz(clk_sys) / (divider * period);
            printf("GPIO%u/%u %-3s %.6f Hz, 50%% complementary\n", 2*i, 2*i+1,
                   notes[i], frequency);
        }
        for (int blink = 0; blink < 10; ++blink) {
            gpio_put(PICO_DEFAULT_LED_PIN, blink % 2 == 0);
            sleep_ms(500);
        }
    }
}
