#include <assert.h>
#include <math.h>
#include <stdio.h>
#define PILYZER_BOARD_ID 3
#include "../../Pico2/firmware/pilyzer/analog.c"
static const pilyzer_input_range_t ranges[] = PILYZER_INPUT_RANGES;
int main(void) {
    assert(ANALOG_CHANNELS == 2 && ANALOG_RANGES == 3);
    assert(PIN_LOGIC_BASE == 6 && PIN_CALIBRATION_OUT == 22);
    assert(PIN_RANGE_CH1 == 2 && PIN_RANGE_CH2 == 4);
    const double maximum[] = {30, 6, 1.5};
    for (int i = 0; i < 3; ++i) {
        double gain = ranges[i].gain_micro / 1e6;
        double offset = ranges[i].offset_microvolts / 1e6;
        assert(ranges[i].switch_position == i);
        assert(offset - maximum[i] * gain > 0);
        assert(offset + maximum[i] * gain < 3.3);
        if (i) assert(gain > ranges[i-1].gain_micro / 1e6);
    }
    analog_init();
    pilyzer_analog_config_t config = {
        .channel_mask = 3, .trigger_mode = TRIG_AUTO,
        .trigger_level = 32768, .sample_period_fs = 5000000000ULL,
        .record_samples = 2048, .pretrigger_samples = 200,
    };
    pilyzer_plan_t actual;
    assert(analog_configure(&config, &actual) == ST_OK);
    config.channel_mask = 4;
    assert(analog_configure(&config, &actual) == ST_BAD_ARGUMENT);
    puts("PL2407AFE: ranges, GPIO and two-channel acquisition passed");
}
