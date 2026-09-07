#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "pilyzer_protocol.h"

void    logic_init(void);
uint8_t logic_configure(const pilyzer_logic_config_t *config, pilyzer_plan_t *plan);
uint8_t logic_arm(void);
void    logic_abort(void);
void    logic_poll(void);
void    logic_status(pilyzer_acq_status_t *out);
bool    logic_idle(void);
uint32_t logic_clock_hz(void);

// Points at `*count` bytes of the finished record starting at `offset`.
const uint8_t *logic_record(uint32_t offset, uint32_t *count);
