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
// The +-1.5 V gain came from a 1.3 V cell instead, and the meter only reads it
// to two decimals. The +-6 V range was used as the ruler in its place: its gain
// is already known, so what it reads the cell as — 1.3078 V — is better than
// 1.30 by about half. That leans on the circuit being linear, which it is: the
// +-30 V gain comes out the same at 5.01 V and at 1.3 V to within 0.03 %.
//
// One figure is not measured. The +-6 V gain is CH2's alone, because CH1's
// switch 4 never closes and that range reads the +-30 V circuit.
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
    { .switch_position = 2, .gain_micro = 880496, .offset_microvolts = 1683325, .name = "±1.5 V" }, \
}
