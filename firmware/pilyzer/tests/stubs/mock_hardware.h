#pragma once
// Host-only substitutes for the SDK calls used by the acquisition modules.
// Tests drive DMA counters and input buffers explicitly; no device is opened.
#include <stdbool.h>
#include <stdint.h>

typedef unsigned int uint;
typedef int64_t absolute_time_t;
static absolute_time_t mock_time;
static inline absolute_time_t get_absolute_time(void) { return mock_time; }
static inline int64_t absolute_time_diff_us(absolute_time_t a, absolute_time_t b) { return b - a; }

typedef struct { uint32_t transfer_count; } mock_dma_registers;
static mock_dma_registers mock_dma;
static bool mock_dma_busy;
static inline mock_dma_registers *dma_channel_hw_addr(int c) { return &mock_dma; }
static inline bool dma_channel_is_busy(int c) { return mock_dma_busy; }
static inline int dma_claim_unused_channel(bool required) { return 0; }
static inline void dma_channel_abort(int c) { mock_dma_busy = false; }
typedef struct { int unused; } dma_channel_config;
static inline dma_channel_config dma_channel_get_default_config(int c) { return (dma_channel_config){0}; }
static inline void channel_config_set_transfer_data_size(dma_channel_config *c, int size) {}
static inline void channel_config_set_read_increment(dma_channel_config *c, bool on) {}
static inline void channel_config_set_write_increment(dma_channel_config *c, bool on) {}
static inline void channel_config_set_ring(dma_channel_config *c, bool write, uint bits) {}
static inline void channel_config_set_dreq(dma_channel_config *c, uint request) {}
static inline void dma_channel_configure(int c, const dma_channel_config *cfg,
                                         volatile void *dst, const volatile void *src,
                                         uint32_t count, bool start) {
    mock_dma.transfer_count = count;
    mock_dma_busy = start;
}
#define DMA_SIZE_16 1
#define DMA_SIZE_32 2
#define DREQ_ADC 36

static struct { uint32_t div, fifo; } mock_adc;
#define adc_hw (&mock_adc)
static inline void adc_init(void) {}
static uint32_t mock_adc_pin_mask;
static uint mock_adc_input;
static uint16_t mock_adc_values[3];
static inline void adc_gpio_init(uint pin) { mock_adc_pin_mask |= 1u << pin; }
static inline void adc_run(bool on) {}
static inline void adc_fifo_drain(void) {}
static inline void adc_set_round_robin(uint mask) {}
static inline void adc_select_input(uint input) { mock_adc_input = input; }
static inline void adc_fifo_setup(bool en, bool dreq, uint threshold, bool err, bool shift) {}
static inline uint16_t adc_read(void) { return mock_adc_values[mock_adc_input]; }

#define clk_sys 0
static inline uint32_t clock_get_hz(int clock) { return 150000000; }
static struct { uint32_t rxf[4]; } mock_pio;
#define pio0 (&mock_pio)
static bool mock_trigger_flag;
typedef struct { int unused; } pio_sm_config;
#define PIO_FIFO_JOIN_RX 1
static inline uint pio_add_program(void *pio, const void *program) { return 0; }
static inline void pio_sm_claim(void *pio, uint sm) {}
static uint32_t mock_pio_gpio_mask;
static inline void pio_gpio_init(void *pio, uint pin) { mock_pio_gpio_mask |= 1u << pin; }
static inline void gpio_set_pulls(uint pin, bool up, bool down) {}
static inline void pio_sm_set_consecutive_pindirs(void *pio, uint sm, uint pin, uint count, bool out) {}
static inline void pio_sm_set_enabled(void *pio, uint sm, bool on) {}
static inline void sm_config_set_in_pins(pio_sm_config *cfg, uint pin) {}
static inline void sm_config_set_in_shift(pio_sm_config *cfg, bool right, bool push, uint threshold) {}
static inline void sm_config_set_fifo_join(pio_sm_config *cfg, int join) {}
static inline void sm_config_set_clkdiv_int_frac8(pio_sm_config *cfg, uint16_t whole, uint8_t fraction) {}
static inline void pio_sm_init(void *pio, uint sm, uint entry, const pio_sm_config *cfg) {}
static inline void pio_interrupt_clear(void *pio, uint flag) { mock_trigger_flag = false; }
static inline bool pio_interrupt_get(void *pio, uint flag) { return mock_trigger_flag; }
static inline void pio_sm_clear_fifos(void *pio, uint sm) {}
static inline uint pio_get_dreq(void *pio, uint sm, bool tx) { return 0; }
