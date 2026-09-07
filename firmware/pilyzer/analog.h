#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "pilyzer_protocol.h"

void    analog_init(void);
uint8_t analog_configure(const pilyzer_analog_config_t *config, pilyzer_plan_t *plan);
uint8_t analog_arm(void);
void    analog_abort(void);
void    analog_poll(void);
void    analog_status(pilyzer_acq_status_t *out);
bool    analog_idle(void);

// Points at `*count` samples per channel of the finished record, starting at
// `offset`. Channels are interleaved, so the block is `*count * channels`
// 16-bit words long. Valid until the next arm.
const uint16_t *analog_record(uint32_t offset, uint32_t *count, uint8_t *channels);

void analog_immediate(uint16_t averages, uint16_t *first, uint16_t *second);
