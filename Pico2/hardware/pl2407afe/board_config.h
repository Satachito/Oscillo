// PL2407AFE rev.1c nominal circuit values; see ../README.md.
#pragma once
#define PIN_CALIBRATION_OUT 22
#define PIN_LOGIC_BASE 6
#define PIN_RANGE_CH1 2
#define PIN_RANGE_CH2 4
#define PIN_RANGE_CH3 0 // unused: this board has two channels
#define PIN_LED PICO_DEFAULT_LED_PIN
#define PIN_ADC_CH1 26
#define PIN_ADC_CH2 27
#define PIN_ADC_CH3 28
#define ANALOG_CHANNELS 2
#define LOGIC_CHANNELS 8
#define ANALOG_RANGES 3
#define PILYZER_INPUT_RANGES { \
    { .switch_position = 0, .gain_micro = 43395, .offset_microvolts = 1577207, .name = "±30 V" }, \
    { .switch_position = 1, .gain_micro = 212277, .offset_microvolts = 1597473, .name = "±6 V" }, \
    { .switch_position = 2, .gain_micro = 880411, .offset_microvolts = 1677649, .name = "±1.5 V" }, \
}
