// PL2407AFE rev.1d, measured on the bench 2026-09-22; see ../README.md.
//
// One table serves both channels, so each figure is the mean of CH1 and CH2.
// The half percent they differ by is left to the per-channel calibration in the
// applications, which is what that is for.
//
// Taken against 5.01 V from four dry cells, read back as 0.5 mV of spread on
// the converter. The meter flickered between 5.01 and 5.02 V, so the gains
// carry about 0.2 % of uncertainty and that is all from the meter.
//
// Two figures are not measured. The +-6 V gain is CH2's alone, because CH1's
// switch 4 never closes and that range reads the +-30 V circuit. The +-1.5 V
// gain is still the nominal one: 5 V overruns the range, and nothing near 1 V
// was to hand. Its offset is measured.
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
    { .switch_position = 0, .gain_micro = 44057, .offset_microvolts = 1584325, .name = "±30 V" }, \
    { .switch_position = 1, .gain_micro = 214483, .offset_microvolts = 1602975, .name = "±6 V" }, \
    { .switch_position = 2, .gain_micro = 880411, .offset_microvolts = 1683325, .name = "±1.5 V" }, \
}
