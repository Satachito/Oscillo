#pragma once

// Four fixed square-wave notes. Each adjacent GPIO pair uses one PWM slice:
// even pin = channel A, odd pin = inverted channel B, both at exactly 50% duty.
// This runs independently of USB, acquisition and the adjustable calibration output.
#ifdef __cplusplus
extern "C" {
#endif
void chord_output_init(void);
#ifdef __cplusplus
}
#endif
