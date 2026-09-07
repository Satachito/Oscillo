// Logic acquisition.
//
// The capture state machine free-runs into a linear buffer while the trigger
// state machine watches the chosen pin. When the flag comes up the processor
// notes roughly where the write pointer was, waits for the rest of the record,
// and only then walks backwards through the captured bytes to find the edge
// itself. The reported trigger position is therefore exact, and the polling
// latency only decides how much of the buffer is searched.

#include <string.h>

#include "board_config.h"
#include "hardware/clocks.h"
#include "hardware/dma.h"
#include "hardware/pio.h"
#include "logic.h"
#include "logic_capture.pio.h"
#include "pico/time.h"

#define LOGIC_PIO       pio0
#define SM_CAPTURE      0
#define SM_TRIGGER      1
#define TRIGGER_FLAG    4

static uint8_t buffer[LOGIC_BUFFER_BYTES] __attribute__((aligned(4)));

static int dma_channel = -1;
static uint capture_offset;
static uint trigger_offset;
static uint32_t system_clock;

static struct {
    bool     valid;
    uint8_t  mode;
    uint8_t  channel;
    uint8_t  slope;
    uint32_t record;
    uint32_t pretrigger;
    uint32_t timeout_us;
    uint32_t divisor_q8;
    uint32_t high_water;
} plan;

static struct {
    uint8_t  state;
    bool     triggered;
    uint32_t base;            // bytes already in the buffer when the DMA started
    uint32_t words;           // transfers the DMA was given
    uint32_t trigger_hint;    // byte position the flag was noticed at
    uint32_t stop_at;
    uint32_t record_start;
    uint32_t trigger_index;
    absolute_time_t armed_at;
} run;

uint32_t logic_clock_hz(void) { return system_clock; }

bool logic_idle(void)
{
    return run.state != STATE_FILLING && run.state != STATE_WAITING && run.state != STATE_POST;
}

void logic_init(void)
{
    system_clock = clock_get_hz(clk_sys);
    dma_channel = dma_claim_unused_channel(true);

    capture_offset = pio_add_program(LOGIC_PIO, &logic_capture_program);
    trigger_offset = pio_add_program(LOGIC_PIO, &logic_trigger_program);
    pio_sm_claim(LOGIC_PIO, SM_CAPTURE);
    pio_sm_claim(LOGIC_PIO, SM_TRIGGER);

    for (int i = 0; i < LOGIC_CHANNELS; i++) {
        pio_gpio_init(LOGIC_PIO, PIN_LOGIC_BASE + i);
        gpio_set_pulls(PIN_LOGIC_BASE + i, false, false);
    }
    pio_sm_set_consecutive_pindirs(LOGIC_PIO, SM_CAPTURE, PIN_LOGIC_BASE, LOGIC_CHANNELS, false);
    run.state = STATE_IDLE;
}

// div = period * system clock, in 24.8 fixed point. Split into two steps so the
// intermediate stays inside 64 bits for every period the divider can express.
static uint32_t solve_divisor(uint64_t period_fs)
{
    if (period_fs > 1000000000000ULL) period_fs = 1000000000000ULL;
    uint64_t scaled = period_fs * 256ULL / 1000000ULL;
    uint64_t divisor = scaled * system_clock / 1000000000ULL;
    if (divisor < 256) divisor = 256;
    if (divisor > 0xFFFFFFULL) divisor = 0xFFFFFFULL;
    return (uint32_t)divisor;
}

static void hardware_stop(void)
{
    pio_sm_set_enabled(LOGIC_PIO, SM_CAPTURE, false);
    pio_sm_set_enabled(LOGIC_PIO, SM_TRIGGER, false);
    if (dma_channel >= 0) dma_channel_abort(dma_channel);
}

static void hardware_start(uint32_t base)
{
    hardware_stop();

    pio_sm_config capture = logic_capture_program_get_default_config(capture_offset);
    sm_config_set_in_pins(&capture, PIN_LOGIC_BASE);
    sm_config_set_in_shift(&capture, true, true, 32);
    sm_config_set_fifo_join(&capture, PIO_FIFO_JOIN_RX);
    sm_config_set_clkdiv_int_frac8(&capture, plan.divisor_q8 >> 8, plan.divisor_q8 & 0xFF);
    pio_sm_init(LOGIC_PIO, SM_CAPTURE, capture_offset, &capture);

    uint entry = trigger_offset +
        ((plan.slope == SLOPE_RISING) ? logic_trigger_offset_rise : logic_trigger_offset_fall);
    pio_sm_config watcher = logic_trigger_program_get_default_config(trigger_offset);
    sm_config_set_in_pins(&watcher, PIN_LOGIC_BASE + plan.channel);
    sm_config_set_clkdiv_int_frac8(&watcher, 1, 0);
    pio_sm_init(LOGIC_PIO, SM_TRIGGER, entry, &watcher);

    pio_interrupt_clear(LOGIC_PIO, TRIGGER_FLAG);
    pio_sm_clear_fifos(LOGIC_PIO, SM_CAPTURE);

    run.base = base;
    run.words = (LOGIC_BUFFER_BYTES - base) / 4;

    dma_channel_config cfg = dma_channel_get_default_config(dma_channel);
    channel_config_set_transfer_data_size(&cfg, DMA_SIZE_32);
    channel_config_set_read_increment(&cfg, false);
    channel_config_set_write_increment(&cfg, true);
    channel_config_set_dreq(&cfg, pio_get_dreq(LOGIC_PIO, SM_CAPTURE, false));
    dma_channel_configure(dma_channel, &cfg, buffer + base,
                          &LOGIC_PIO->rxf[SM_CAPTURE], run.words, true);

    pio_sm_set_enabled(LOGIC_PIO, SM_CAPTURE, true);
    if (plan.mode != TRIG_FREE_RUN) pio_sm_set_enabled(LOGIC_PIO, SM_TRIGGER, true);
}

static uint32_t captured_bytes(void)
{
    if (logic_idle()) return 0;
    uint32_t remaining = dma_channel_hw_addr(dma_channel)->transfer_count & 0x0FFFFFFFu;
    return run.base + (run.words - remaining) * 4;
}

uint8_t logic_configure(const pilyzer_logic_config_t *config, pilyzer_plan_t *out)
{
    if (!logic_idle()) return ST_BUSY;
    if (config->trigger_mode > TRIG_NORMAL) return ST_BAD_ARGUMENT;
    if (config->trigger_slope > SLOPE_FALLING) return ST_BAD_ARGUMENT;
    if (config->trigger_channel >= LOGIC_CHANNELS) return ST_BAD_ARGUMENT;
    if (config->record_samples == 0) return ST_BAD_ARGUMENT;

    plan.mode = config->trigger_mode;
    plan.channel = config->trigger_channel;
    plan.slope = config->trigger_slope;
    plan.record = config->record_samples;
    if (plan.record > LOGIC_MAX_RECORD) plan.record = LOGIC_MAX_RECORD;
    plan.pretrigger = config->pretrigger_samples;
    if (plan.pretrigger >= plan.record) plan.pretrigger = plan.record - 1;
    plan.timeout_us = config->auto_timeout_us;
    plan.divisor_q8 = solve_divisor(config->sample_period_fs);
    plan.high_water = LOGIC_BUFFER_BYTES - (plan.record - plan.pretrigger);
    plan.valid = true;

    out->clock_hz = system_clock;
    out->divisor_q8 = plan.divisor_q8;
    out->decimation = 1;
    out->record_samples = plan.record;
    out->pretrigger_samples = plan.pretrigger;
    out->channel_mask = (1u << LOGIC_CHANNELS) - 1;
    out->conversions_per_sample = 1;
    out->reserved = 0;
    return ST_OK;
}

uint8_t logic_arm(void)
{
    if (!plan.valid) return ST_NOT_CONFIGURED;
    if (!logic_idle()) return ST_BUSY;

    run.state = STATE_FILLING;
    run.triggered = false;
    run.trigger_hint = 0;
    run.stop_at = 0;
    run.record_start = 0;
    run.trigger_index = 0;
    run.armed_at = get_absolute_time();
    hardware_start(0);
    return ST_OK;
}

void logic_abort(void)
{
    hardware_stop();
    if (!logic_idle()) run.state = STATE_ABORTED;
}

// Walks back from where the flag was noticed to the edge that raised it. The
// search is bounded by the buffer, so a slow poll costs a longer walk, never a
// wrong answer.
static uint32_t exact_trigger(uint32_t hint, uint32_t available)
{
    if (hint > available) hint = available;
    uint8_t mask = 1u << plan.channel;
    for (uint32_t i = hint; i >= 1; i--) {
        bool before = (buffer[i - 1] & mask) != 0;
        bool after = (buffer[i] & mask) != 0;
        if (plan.slope == SLOPE_RISING ? (!before && after) : (before && !after)) return i;
    }
    return hint;
}

static void complete(uint32_t start, uint32_t trigger_index, bool triggered)
{
    hardware_stop();
    run.record_start = start;
    run.trigger_index = trigger_index;
    run.triggered = triggered;
    run.state = STATE_COMPLETE;
}

static void restart_with_history(void)
{
    uint32_t available = captured_bytes();
    uint32_t keep = plan.pretrigger;
    if (keep > available) keep = available;
    keep &= ~3u;                                     // the DMA writes whole words

    hardware_stop();
    if (keep) memmove(buffer, buffer + (available - keep), keep);
    run.state = (keep >= plan.pretrigger) ? STATE_WAITING : STATE_FILLING;
    hardware_start(keep);
}

void logic_poll(void)
{
    if (logic_idle()) return;

    uint32_t available = captured_bytes();

    if (run.state == STATE_POST) {
        if (available >= run.stop_at) {
            uint32_t edge = exact_trigger(run.trigger_hint, available);
            uint32_t start = (edge >= plan.pretrigger) ? edge - plan.pretrigger : 0;
            // The edge is usually a little behind where the flag was noticed,
            // so the tail of the record may still be arriving. Waiting is
            // right here; trimming the record to what has arrived would move
            // the trigger away from where it actually is.
            if (start + plan.record > available) return;
            complete(start, edge - start, true);
        }
        return;
    }

    if (run.state == STATE_FILLING && available >= plan.pretrigger) run.state = STATE_WAITING;

    if (plan.mode == TRIG_FREE_RUN) {
        if (available >= plan.record) complete(available - plan.record, plan.pretrigger, false);
        return;
    }

    if (run.state == STATE_WAITING && pio_interrupt_get(LOGIC_PIO, TRIGGER_FLAG)) {
        pio_interrupt_clear(LOGIC_PIO, TRIGGER_FLAG);
        run.trigger_hint = available;
        run.stop_at = available + (plan.record - plan.pretrigger);
        if (run.stop_at > LOGIC_BUFFER_BYTES) run.stop_at = LOGIC_BUFFER_BYTES;
        run.state = STATE_POST;
        return;
    }

    if (plan.mode == TRIG_AUTO && available >= plan.record) {
        int64_t waited = absolute_time_diff_us(run.armed_at, get_absolute_time());
        if (waited >= (int64_t)plan.timeout_us) {
            complete(available - plan.record, plan.pretrigger, false);
            return;
        }
    }

    if (available >= plan.high_water) restart_with_history();
}

void logic_status(pilyzer_acq_status_t *out)
{
    out->state = run.state;
    out->triggered = run.triggered ? 1 : 0;
    out->reserved = 0;
    out->samples_available = (run.state == STATE_COMPLETE) ? plan.record : captured_bytes();
    out->trigger_index = run.trigger_index;
    out->reserved2 = 0;
}

const uint8_t *logic_record(uint32_t offset, uint32_t *count)
{
    if (run.state != STATE_COMPLETE || offset >= plan.record) { *count = 0; return buffer; }
    uint32_t available = plan.record - offset;
    if (*count > available) *count = available;
    return &buffer[run.record_start + offset];
}
