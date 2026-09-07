#pragma once
#include <stdbool.h>
#include <stdint.h>
typedef unsigned int uint;
#define clk_sys 0
static inline uint32_t clock_get_hz(int clock) { return 150000000; }
#define GPIO_FUNC_PWM 4

typedef struct { uint32_t divider; uint16_t top; bool invert_a, invert_b; } pwm_config;
typedef struct { pwm_config config; uint16_t a, b; } mock_pwm_slice;
static struct { uint32_t en; mock_pwm_slice slice[8]; } mock_pwm;
#define pwm_hw (&mock_pwm)
static uint32_t mock_pwm_pin_mask;
static inline uint pwm_gpio_to_slice_num(uint pin) { return (pin >> 1) & 7; }
static inline pwm_config pwm_get_default_config(void) { return (pwm_config){.divider=1, .top=65535}; }
static inline void pwm_config_set_clkdiv_int(pwm_config *c, uint32_t divider) { c->divider=divider; }
static inline void pwm_config_set_wrap(pwm_config *c, uint16_t top) { c->top=top; }
static inline void pwm_config_set_output_polarity(pwm_config *c, bool a, bool b) { c->invert_a=a; c->invert_b=b; }
static inline void pwm_init(uint slice, pwm_config *c, bool start) {
    mock_pwm.slice[slice] = (mock_pwm_slice){.config=*c};
    if (start) mock_pwm.en |= 1u << slice;
    else mock_pwm.en &= ~(1u << slice);
}
static inline void pwm_set_both_levels(uint slice, uint16_t a, uint16_t b) { mock_pwm.slice[slice].a=a; mock_pwm.slice[slice].b=b; }
static inline void gpio_set_function(uint pin, uint function) { if (function==GPIO_FUNC_PWM) mock_pwm_pin_mask |= 1u << pin; }
static inline void pwm_set_mask_enabled(uint32_t mask) { mock_pwm.en=mask; }
