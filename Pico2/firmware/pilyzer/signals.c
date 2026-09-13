#include "signals.h"

#include "board_config.h"

#if PILYZER_HAS_SIGNALS

#include "hardware/pwm.h"
#include "pico/stdlib.h"
#include "signal_source.h"

// 50 kHz: an integer number of microseconds a sample, which keeps the sine's
// frequency exact, and eight times over the audio band.
#define SAMPLE_RATE_HZ 50000

// Where the four pins may go. A board that moves them somewhere that cannot
// work is told here, at compile time, rather than on a bench with a probe.
//
// They are two PWM slices driven as an A/B pair each, so the first has to be
// an even GPIO, and neither slice may be the one the calibration square wave
// already owns: a slice has one wrap counter for both of its channels.
#define SIGNAL_SLICE(pin) (((pin) >> 1u) & 7u)
_Static_assert(PIN_SIGNAL_BASE % 2 == 0,
    "the generator's first pin must be the A channel of a PWM slice");
_Static_assert(SIGNAL_SLICE(PIN_CALIBRATION_OUT) != SIGNAL_SLICE(PIN_SIGNAL_BASE)
            && SIGNAL_SLICE(PIN_CALIBRATION_OUT) != SIGNAL_SLICE(PIN_SIGNAL_BASE + 2),
    "the generator and the calibration output would share a PWM slice");

// And the pins themselves have to be free. Two runs of pins overlap when each
// starts before the other ends, which covers one sitting wholly inside the
// other as well as the two merely crossing.
#define PINS_CLASH(a, na, b, nb) ((a) < (b) + (nb) && (b) < (a) + (na))
#define SIGNALS_CLASH(pin, count) PINS_CLASH(PIN_SIGNAL_BASE, SIGNAL_COUNT, pin, count)
_Static_assert(!SIGNALS_CLASH(PIN_CALIBRATION_OUT, 1),
    "the generator would drive the calibration output's pin");
_Static_assert(!SIGNALS_CLASH(PIN_LOGIC_BASE, LOGIC_CHANNELS),
    "the generator would drive a logic input");
_Static_assert(!SIGNALS_CLASH(PIN_RANGE_CH1, RANGE_PINS_PER_CHANNEL)
            && !SIGNALS_CLASH(PIN_RANGE_CH2, RANGE_PINS_PER_CHANNEL)
            && (ANALOG_CHANNELS < 3
                || !SIGNALS_CLASH(PIN_RANGE_CH3, RANGE_PINS_PER_CHANNEL)),
    "the generator would fight a range switch");
_Static_assert(!SIGNALS_CLASH(PIN_ADC_CH1, 1) && !SIGNALS_CLASH(PIN_ADC_CH2, 1)
            && (ANALOG_CHANNELS < 3 || !SIGNALS_CLASH(PIN_ADC_CH3, 1)),
    "the generator would drive a converter input");

static signal_source_t source;
static repeating_timer_t timer;
static bool running;

static bool next_sample(repeating_timer_t *unused)
{
    (void)unused;
    uint8_t duty[SIGNAL_COUNT];
    signal_source_next(&source, duty);
    for (uint i = 0; i < SIGNAL_COUNT; ++i) {
        uint pin = PIN_SIGNAL_BASE + i;
        pwm_set_chan_level(pwm_gpio_to_slice_num(pin), pwm_gpio_to_channel(pin), duty[i]);
    }
    return true;
}

static void release_pins(void)
{
    for (uint i = 0; i < SIGNAL_COUNT; ++i) {
        uint pin = PIN_SIGNAL_BASE + i;
        pwm_set_enabled(pwm_gpio_to_slice_num(pin), false);
        gpio_set_function(pin, GPIO_FUNC_SIO);
        gpio_set_dir(pin, GPIO_OUT);
        gpio_put(pin, 0);
    }
}

void signals_init(void)
{
    release_pins();
}

uint32_t signals_set(bool on, uint32_t sine_hz)
{
    if (running) {
        cancel_repeating_timer(&timer);
        running = false;
    }
    if (!on) {
        release_pins();
        return 0;
    }

    if (sine_hz == 0) sine_hz = 440;
    // Above a quarter of the sample rate the table is being read faster than
    // it can describe a wave, so this is where the host's number stops.
    if (sine_hz > SAMPLE_RATE_HZ / 4) sine_hz = SAMPLE_RATE_HZ / 4;

    signal_source_init(&source, (float)SAMPLE_RATE_HZ, (float)sine_hz, 0x2545F491u);

    pwm_config config = pwm_get_default_config();
    pwm_config_set_wrap(&config, SIGNAL_TOP);      // 8-bit duty…
    pwm_config_set_clkdiv_int(&config, 1);         // …at the fastest carrier
    for (uint i = 0; i < SIGNAL_COUNT; ++i) {
        uint pin = PIN_SIGNAL_BASE + i;
        gpio_set_function(pin, GPIO_FUNC_PWM);
        pwm_init(pwm_gpio_to_slice_num(pin), &config, false);
        pwm_set_chan_level(pwm_gpio_to_slice_num(pin), pwm_gpio_to_channel(pin), SIGNAL_TOP / 2);
    }
    for (uint i = 0; i < SIGNAL_COUNT; i += 2) {
        pwm_set_enabled(pwm_gpio_to_slice_num(PIN_SIGNAL_BASE + i), true);
    }

    // Negative: the period runs from the start of one call to the start of the
    // next, so a sample that takes longer does not slow the rate.
    running = add_repeating_timer_us(-(1000000 / SAMPLE_RATE_HZ), next_sample, NULL, &timer);
    if (!running) {
        release_pins();
        return 0;
    }
    return sine_hz;
}

bool signals_available(void) { return true; }

#else

void signals_init(void) {}
uint32_t signals_set(bool on, uint32_t sine_hz) { (void)on; (void)sine_hz; return 0; }
bool signals_available(void) { return false; }

#endif
