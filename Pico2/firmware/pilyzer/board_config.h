// Pin map and memory budget for the PiLyzer Pico 2 instrument.
//
// Everything the rest of the firmware knows about the board is here. The
// numbers below are what the host is told through OP_CAPABILITIES, so the
// application never has to be recompiled when they change.
#pragma once

#ifndef PILYZER_BOARD_ID
// 0 = bare Pico 2, inputs straight on the converter pins.
// 1 = PiLyzer analogue front end rev A/B.
// 0 bare Pico 2, 1 PiLyzer AFE rev A, 3 PL2407AFE. 2 was a second in-house
// board and is retired rather than reused, so an old build that still says 2
// fails here instead of quietly reading through rev A's ranges.
#define PILYZER_BOARD_ID 0
#endif

#define PILYZER_FIRMWARE_VERSION 0x0110   // 1.16: the PL2407AFE +-1.5 V gain is measured too, against a cell the +-6 V range read for us

// --- Pins ---------------------------------------------------------------
#if PILYZER_BOARD_ID == 3
#include "../../hardware/pl2407afe/board_config.h"
// Two pins a channel here, and they are 2-5, which is why this board was the
// first to want the generator somewhere other than 0.
#define RANGE_PINS_PER_CHANNEL 2
#define PIN_SIGNAL_BASE     16
#define PILYZER_HAS_SIGNALS 1
#else
// The PL2407AFE brings its own SG OUT pad on GPIO22, so every board uses that
// pin and nothing has to ask which board it is talking to.
#define PIN_CALIBRATION_OUT 22    // adjustable calibration square wave
// A sine and three noises, one per pin from here up. Every board puts them on
// the same four, so there is one answer to where they are rather than one an
// application has to look up; the range controls moved down to 4 to free them.
#define PIN_SIGNAL_BASE     16
#define PILYZER_HAS_SIGNALS 1
// Logic and the range controls sit where the PL2407AFE has them, so D0 is
// GPIO6 whichever board it is: one answer to where the logic inputs are.
#define PIN_LOGIC_BASE      6     // D0…D7 on GPIO6…GPIO13, consecutive for PIO
#define RANGE_PINS_PER_CHANNEL 1
#define PIN_RANGE_CH1       2     // switch position: 0 = ±25 V, 1 = ±5 V
#define PIN_RANGE_CH2       3
#define PIN_RANGE_CH3       4
#define PIN_LED             PICO_DEFAULT_LED_PIN
#define PIN_ADC_CH1         26    // ADC0
#define PIN_ADC_CH2         27    // ADC1
#define PIN_ADC_CH3         28    // ADC2

#define ANALOG_CHANNELS 3
#define LOGIC_CHANNELS  8
#endif

// --- Input ranges -------------------------------------------------------
// The straight line from a voltage at the input to a voltage at the converter,
// one entry per position of the range switch.
//
// These used to live in the host, selected by board id, which meant every new
// board needed a new release of both applications before it could be read
// correctly — the one place where the host used a compiled-in constant instead
// of the device's own answer. They belong here, with the board.
//
//   gain   converter volts per input volt, in millionths
//   offset converter volts with 0 V at the input, in microvolts
//
// A bare Pico 2 has nothing to switch, so it offers exactly one.
#if PILYZER_BOARD_ID == 3
// PL2407AFE descriptors are supplied by hardware/pl2407afe/board_config.h.
#elif PILYZER_BOARD_ID == 0
#define ANALOG_RANGES 1
#define PILYZER_INPUT_RANGES {                                                 \
    { .switch_position = 0, .gain_micro = 1000000, .offset_microvolts = 0,     \
      .name = "0 – 3.3 V" },                                                   \
}
#elif PILYZER_BOARD_ID == 2
#error "board id 2 is retired; a one-range rev A build reports its own ranges"
#else
// PiLyzer AFE rev A: both ranges sit on the same attenuator and the same
// mid-rail bias; the switch only changes the gain of the stage after it.
#define ANALOG_RANGES 2
#define PILYZER_INPUT_RANGES {                                                 \
    { .switch_position = 0, .gain_micro =  62645, .offset_microvolts = 1650515,\
      .name = "±25 V" },                                                       \
    { .switch_position = 1, .gain_micro = 297269, .offset_microvolts = 1652442,\
      .name = "±5 V" },                                                        \
}
#endif

// --- Converter ----------------------------------------------------------
#define ADC_CLOCK_HZ        48000000u
// A conversion takes 96 ADC clocks, but the pacing register holds the interval
// minus one — and the converter only honours it when that register is 96 or
// more. Ask for a 96-cycle interval and DIV becomes 95, which is below the
// threshold: the converter stops pacing and free-runs at roughly twice the
// rate, while the plan still reports the interval that was asked for. Measured
// on hardware: 96 cycles reads a 1 kHz square wave back as 2 kHz, 97 reads it
// as 1 kHz. So the shortest interval this firmware will use is 97 cycles.
#define ADC_MIN_PERIOD_CYCLES 97u
#define ADC_REFERENCE_MICROVOLTS 3300000u

// --- Memory -------------------------------------------------------------
// The hardware ring the converter's DMA wraps inside. Its size in bytes must
// be a power of two no larger than 32 KB, which is what the DMA can wrap.
#define ADC_RAW_SAMPLES 4096
#define ADC_RAW_BYTES   (ADC_RAW_SAMPLES * 2)
#define ADC_RAW_RING_BITS 13              // log2(ADC_RAW_BYTES)

// The decimated record buffer, in conversions. Three channels retain 32768
// samples each, leaving space for trigger history plus a full 16384-point record.
#define ANALOG_BUFFER_CONVERSIONS 98304
// A record may take at most half the buffer, so there is always room left to
// look for a trigger and then fill the tail.
#define ANALOG_MAX_RECORD (ANALOG_BUFFER_CONVERSIONS / (2 * ANALOG_CHANNELS))

#define LOGIC_BUFFER_BYTES 131072
#define LOGIC_MAX_RECORD   (LOGIC_BUFFER_BYTES / 2)

// --- USB ----------------------------------------------------------------
// pid.codes 1209:0001 is the identifier set aside for prototypes that are not
// shipped. Ask Raspberry Pi for a product id under 2E8A, or pid.codes for one
// under 1209, before this leaves the bench.
#define PILYZER_VID 0x1209
#define PILYZER_PID 0x0001
#define PILYZER_MAX_PAYLOAD 8192         // largest read the host may ask for
