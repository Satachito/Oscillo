#pragma once

#include <stdbool.h>
#include <stdint.h>

// The instrument's own signal generator: a sine on PIN_SIGNAL_BASE and white,
// pink and brown noise on the three pins above it. Wire one to an input to
// exercise a front end without a second board.
//
// Each pin carries a PWM carrier whose duty follows a sample, so every one of
// them wants an RC to become a voltage — see tools/pico2-noise/README.md, which
// runs the same generator on a spare Pico.

/// Idle, until the host asks for something.
void signals_init(void);

/// Returns the sine frequency it settled on, or zero when switched off or when
/// the board has no pins to spare for it.
uint32_t signals_set(bool on, uint32_t sine_hz);

bool signals_available(void);
