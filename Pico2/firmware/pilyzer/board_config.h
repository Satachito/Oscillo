// Pin map and memory budget for the PiLyzer Pico 2 instrument.
//
// Everything the rest of the firmware knows about the board is here. The
// numbers below are what the host is told through OP_CAPABILITIES, so the
// application never has to be recompiled when they change.
#pragma once

#ifndef PILYZER_BOARD_ID
// 0 = bare Pico 2, inputs straight on the converter pins.
// 1 = PiLyzer analogue front end rev A/B.
#define PILYZER_BOARD_ID 0
#endif

#define PILYZER_FIRMWARE_VERSION 0x0106   // 1.6: WinUSB/WebUSB descriptors; 1.5 added CH3 and the GPIO20 calibration output

// --- Pins ---------------------------------------------------------------
#define PIN_CALIBRATION_OUT 20    // adjustable calibration square wave
#define PIN_LOGIC_BASE      8     // D0…D7 on GPIO8…GPIO15, consecutive for PIO
#define PIN_RANGE_CH1       16    // switch position: 0 = ±25 V, 1 = ±5 V
#define PIN_RANGE_CH2       17
#define PIN_RANGE_CH3       18
#define PIN_LED             PICO_DEFAULT_LED_PIN
#define PIN_ADC_CH1         26    // ADC0
#define PIN_ADC_CH2         27    // ADC1
#define PIN_ADC_CH3         28    // ADC2

#define ANALOG_CHANNELS 3
#define LOGIC_CHANNELS  8
#define ANALOG_RANGES   2

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
