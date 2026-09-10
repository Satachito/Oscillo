// Analogue acquisition.
//
// The converter runs continuously into a small hardware ring that the DMA
// wraps by itself, and the processor decimates out of that ring into the
// record buffer. Decimation is a box-car average, so a slow sweep is not a
// sub-sampled fast one: it is the average of everything that happened between
// two points on screen. That is the anti-alias filter, and it hands back the
// bits the averaging earns — which is why samples leave here as 16-bit values
// however many bits the converter itself has.
//
// Sampling never stops while a record is being hunted for, so the trigger scan
// is simply a pointer walking behind the write pointer.

#include <string.h>

#include "analog.h"
#include "board_config.h"
#include "hardware/adc.h"
#include "hardware/dma.h"
#include "pico/time.h"
#include "trigger_filter.h"

#define ADC_DMA_TRANSFERS 0x0FFFFFFFu
#define ADC_DMA_COUNT_MASK 0x0FFFFFFFu

static uint16_t raw_ring[ADC_RAW_SAMPLES] __attribute__((aligned(ADC_RAW_BYTES)));
static uint16_t record_buffer[ANALOG_BUFFER_CONVERSIONS];

static int raw_dma = -1;
static trigger_filter_t trigger_filter;

static struct {
    bool     valid;
    uint8_t  channel_mask;
    uint8_t  channels;        // conversions per sample
    uint8_t  first_input;     // converter input the round robin starts on
    uint8_t  source_index;    // trigger channel's slot within one sample
    uint8_t  mode;
    uint8_t  slope;
    uint16_t level;
    uint16_t hysteresis;
    uint32_t record;
    uint32_t pretrigger;
    uint32_t timeout_us;
    uint32_t decimation;
    uint32_t cycles_q8;       // converter period, 24.8 fixed point
    uint32_t capacity;        // samples per channel the buffer holds
    uint32_t high_water;      // start over rather than run out of tail room
} plan;

static struct {
    uint8_t  state;
    bool     triggered;
    bool     armed;           // the trigger has seen the far side of the level
    uint32_t written;         // conversions in the record buffer
    uint32_t scanned;         // samples already tested for the trigger
    uint32_t record_start;    // sample index the record begins at
    uint32_t trigger_index;   // where the edge sits inside the record
    uint32_t stop_at;         // sample count that completes the record
    uint32_t raw_consumed;
    uint32_t phase;
    uint32_t accumulated;
    uint64_t accumulator[ANALOG_CHANNELS];
    absolute_time_t armed_at;
} run;

void analog_init(void)
{
    adc_init();
    adc_gpio_init(PIN_ADC_CH1);
    adc_gpio_init(PIN_ADC_CH2);
#if ANALOG_CHANNELS > 2
    adc_gpio_init(PIN_ADC_CH3);
#endif
    raw_dma = dma_claim_unused_channel(true);
    run.state = STATE_IDLE;
}

bool analog_idle(void)
{
    return run.state != STATE_FILLING && run.state != STATE_WAITING && run.state != STATE_POST;
}

// One conversion costs `cycles` converter clocks. 1e15 femtoseconds divided by
// (48 MHz x 256) is exactly 1953125/24, which keeps this in integers.
static void solve_timing(uint64_t period_fs, uint32_t channels,
                         uint32_t *decimation, uint32_t *cycles_q8)
{
    const uint32_t floor_q8 = ADC_MIN_PERIOD_CYCLES << 8;
    const uint32_t ceiling_q8 = 0xFFFFFFu + 256u;

    uint64_t sample_q8 = period_fs * 24ULL / 1953125ULL;
    uint64_t conversion_q8 = sample_q8 / (channels ? channels : 1);

    uint64_t factor = conversion_q8 / floor_q8;
    if (factor < 1) factor = 1;
    if (factor > 1000000) factor = 1000000;

    uint64_t each = conversion_q8 / factor;
    if (each < floor_q8) each = floor_q8;
    if (each > ceiling_q8) each = ceiling_q8;

    *decimation = (uint32_t)factor;
    *cycles_q8 = (uint32_t)each;
}

static void hardware_stop(void)
{
    adc_run(false);
    adc_fifo_drain();
    if (raw_dma >= 0) dma_channel_abort(raw_dma);
}

static void hardware_start(void)
{
    hardware_stop();

    adc_set_round_robin(0);
    adc_select_input(plan.first_input);
    adc_set_round_robin(plan.channel_mask);
    // Never let the pacing register fall below the threshold at which the
    // converter gives up on pacing altogether; the timing the host was promised
    // depends on this register being honoured.
    uint32_t divisor = plan.cycles_q8 - 256u;
    if (divisor < (ADC_MIN_PERIOD_CYCLES - 1u) << 8) divisor = (ADC_MIN_PERIOD_CYCLES - 1u) << 8;
    adc_hw->div = divisor;
    adc_fifo_setup(true, true, 1, false, false);

    dma_channel_config cfg = dma_channel_get_default_config(raw_dma);
    channel_config_set_transfer_data_size(&cfg, DMA_SIZE_16);
    channel_config_set_read_increment(&cfg, false);
    channel_config_set_write_increment(&cfg, true);
    channel_config_set_ring(&cfg, true, ADC_RAW_RING_BITS);
    channel_config_set_dreq(&cfg, DREQ_ADC);
    dma_channel_configure(raw_dma, &cfg, raw_ring, &adc_hw->fifo, ADC_DMA_TRANSFERS, true);

    run.raw_consumed = 0;
    run.phase = 0;
    run.accumulated = 0;
    for (int i = 0; i < ANALOG_CHANNELS; i++) run.accumulator[i] = 0;

    adc_run(true);
}

uint8_t analog_configure(const pilyzer_analog_config_t *config, pilyzer_plan_t *out)
{
    if (!analog_idle()) return ST_BUSY;

    uint8_t mask = config->channel_mask;
    if (mask & ~((1u << ANALOG_CHANNELS) - 1u)) return ST_BAD_ARGUMENT;
    if (mask == 0) return ST_BAD_ARGUMENT;
    if (config->trigger_mode > TRIG_NORMAL) return ST_BAD_ARGUMENT;
    if (config->trigger_slope > SLOPE_FALLING) return ST_BAD_ARGUMENT;
    if (config->record_samples == 0) return ST_BAD_ARGUMENT;
    if (config->trigger_lowpass_hz != 0 &&
        (config->trigger_lowpass_hz < TRIGGER_FILTER_MIN_HZ ||
         config->trigger_lowpass_hz > TRIGGER_FILTER_MAX_HZ)) return ST_BAD_ARGUMENT;

    plan.channel_mask = mask;
    plan.channels = (uint8_t)__builtin_popcount(mask);
    plan.first_input = (uint8_t)__builtin_ctz(mask);
    plan.capacity = ANALOG_BUFFER_CONVERSIONS / plan.channels;

    plan.record = config->record_samples;
    if (plan.record > ANALOG_MAX_RECORD) plan.record = ANALOG_MAX_RECORD;
    plan.pretrigger = config->pretrigger_samples;
    if (plan.pretrigger >= plan.record) plan.pretrigger = plan.record ? plan.record - 1 : 0;

    // A channel that is switched off has no slot in the record, so a trigger
    // aimed at it falls back to the one that is on.
    uint8_t source = config->trigger_source;
    plan.source_index = source < plan.channels ? source : 0;

    plan.mode = config->trigger_mode;
    plan.slope = config->trigger_slope;
    plan.level = config->trigger_level;
    plan.hysteresis = config->trigger_hysteresis;
    plan.timeout_us = config->auto_timeout_us;
    plan.high_water = plan.capacity - (plan.record - plan.pretrigger);

    solve_timing(config->sample_period_fs, plan.channels, &plan.decimation, &plan.cycles_q8);
    double sample_period = (double)plan.cycles_q8 / 256.0 / ADC_CLOCK_HZ
        * plan.channels * plan.decimation;
    trigger_filter_configure(&trigger_filter, config->trigger_lowpass_hz, sample_period);
    plan.valid = true;

    out->clock_hz = ADC_CLOCK_HZ;
    out->divisor_q8 = plan.cycles_q8;
    out->decimation = plan.decimation;
    out->record_samples = plan.record;
    out->pretrigger_samples = plan.pretrigger;
    out->channel_mask = plan.channel_mask;
    out->conversions_per_sample = plan.channels;
    out->reserved = 0;
    return ST_OK;
}

uint8_t analog_arm(void)
{
    if (!plan.valid) return ST_NOT_CONFIGURED;
    if (!analog_idle()) return ST_BUSY;

    run.state = STATE_FILLING;
    run.triggered = false;
    run.armed = false;
    run.written = 0;
    run.scanned = 0;
    run.record_start = 0;
    run.trigger_index = 0;
    run.stop_at = 0;
    run.armed_at = get_absolute_time();
    trigger_filter_reset(&trigger_filter);
    hardware_start();
    return ST_OK;
}

void analog_abort(void)
{
    hardware_stop();
    if (!analog_idle()) run.state = STATE_ABORTED;
}

static void complete(uint32_t start, uint32_t trigger_index, bool triggered)
{
    hardware_stop();
    run.record_start = start;
    run.trigger_index = trigger_index;
    run.triggered = triggered;
    run.state = STATE_COMPLETE;
}

// Carries the newest pre-trigger samples to the front and starts over. This is
// the only moment the instrument is blind, and it lasts one memory copy.
static void restart_with_history(void)
{
    uint32_t available = run.written / plan.channels;
    uint32_t keep = plan.pretrigger;
    if (keep > available) keep = available;

    hardware_stop();
    if (keep) {
        memmove(record_buffer,
                record_buffer + (available - keep) * plan.channels,
                (size_t)keep * plan.channels * sizeof(uint16_t));
    }
    run.written = keep * plan.channels;
    // Replay retained history into a fresh filter after the sampling gap.
    run.scanned = trigger_filter.alpha_q30 ? 0 : keep;
    run.armed = false;
    run.state = trigger_filter.alpha_q30 || keep < plan.pretrigger ? STATE_FILLING : STATE_WAITING;
    trigger_filter_reset(&trigger_filter);
    hardware_start();
}

static void drain_converter(void)
{
    uint32_t remaining = dma_channel_hw_addr(raw_dma)->transfer_count & ADC_DMA_COUNT_MASK;
    uint32_t produced = ADC_DMA_TRANSFERS - remaining;
    uint32_t pending = produced - run.raw_consumed;

    if (pending > ADC_RAW_SAMPLES) {
        hardware_stop();
        run.state = STATE_OVERRUN;
        return;
    }

    uint32_t index = run.raw_consumed & (ADC_RAW_SAMPLES - 1);
    uint32_t consumed = 0;
    while (consumed < pending) {
        if (run.written + plan.channels > ANALOG_BUFFER_CONVERSIONS) break;
        run.accumulator[run.phase] += raw_ring[index];
        index = (index + 1) & (ADC_RAW_SAMPLES - 1);
        consumed++;

        if (++run.phase < plan.channels) continue;
        run.phase = 0;
        if (++run.accumulated < plan.decimation) continue;

        for (uint32_t c = 0; c < plan.channels; c++) {
            record_buffer[run.written + c] =
                (uint16_t)(run.accumulator[c] * 16u / plan.decimation);
            run.accumulator[c] = 0;
        }
        run.accumulated = 0;
        run.written += plan.channels;
        if (run.written + plan.channels > ANALOG_BUFFER_CONVERSIONS) break;
    }
    run.raw_consumed += consumed;
}

static void scan_for_trigger(void)
{
    uint32_t available = run.written / plan.channels;
    // A drain can cross high_water in one batch. Only accept edges with
    // enough buffer remaining for the entire post-trigger tail.
    if (available > plan.high_water + 1) available = plan.high_water + 1;
    int32_t level = plan.level;
    int32_t hysteresis = plan.hysteresis;

    while (run.scanned < available) {
        int32_t value = trigger_filter_sample(&trigger_filter,
            record_buffer[run.scanned * plan.channels + plan.source_index]);
        if (run.state == STATE_FILLING) {
            if (run.scanned < plan.pretrigger) { run.scanned++; continue; }
            run.state = STATE_WAITING;
        }

        if (trigger_filter.remaining) { run.scanned++; continue; }
        if (plan.slope == SLOPE_RISING) {
            if (!run.armed) {
                if (value < level - hysteresis) run.armed = true;
            } else if (value >= level) {
                run.record_start = run.scanned - plan.pretrigger;
                run.trigger_index = plan.pretrigger;
                run.stop_at = run.record_start + plan.record;
                run.state = STATE_POST;
                return;
            }
        } else {
            if (!run.armed) {
                if (value > level + hysteresis) run.armed = true;
            } else if (value <= level) {
                run.record_start = run.scanned - plan.pretrigger;
                run.trigger_index = plan.pretrigger;
                run.stop_at = run.record_start + plan.record;
                run.state = STATE_POST;
                return;
            }
        }
        run.scanned++;
    }
}

void analog_poll(void)
{
    if (analog_idle()) return;

    drain_converter();
    if (run.state == STATE_OVERRUN) return;

    uint32_t available = run.written / plan.channels;

    // The converter's transfer count is finite. It lasts several minutes, but
    // when it does run out the record in progress must not be thrown away.
    if (!dma_channel_is_busy(raw_dma)) {
        if (run.state == STATE_POST && available >= run.stop_at) {
            complete(run.record_start, run.trigger_index, true);
        } else if (run.state == STATE_POST) {
            hardware_stop();
            run.state = STATE_OVERRUN;
        } else {
            restart_with_history();
        }
        return;
    }

    if (run.state == STATE_POST) {
        if (available >= run.stop_at) complete(run.record_start, run.trigger_index, true);
        return;
    }

    if (plan.mode == TRIG_FREE_RUN) {
        if (available >= plan.record) complete(available - plan.record, plan.pretrigger, false);
        return;
    }

    scan_for_trigger();
    if (run.state == STATE_POST) {
        available = run.written / plan.channels;
        if (available >= run.stop_at) complete(run.record_start, run.trigger_index, true);
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

void analog_status(pilyzer_acq_status_t *out)
{
    out->state = run.state;
    out->triggered = run.triggered ? 1 : 0;
    out->reserved = 0;
    out->samples_available = (run.state == STATE_COMPLETE) ? plan.record : run.written / (plan.channels ? plan.channels : 1);
    out->trigger_index = run.trigger_index;
    out->reserved2 = 0;
}

const uint16_t *analog_record(uint32_t offset, uint32_t *count, uint8_t *channels)
{
    *channels = plan.channels;
    if (run.state != STATE_COMPLETE || offset >= plan.record) { *count = 0; return record_buffer; }
    uint32_t available = plan.record - offset;
    if (*count > available) *count = available;
    return &record_buffer[(run.record_start + offset) * plan.channels];
}

void analog_immediate(uint16_t averages, uint16_t *readings)
{
    hardware_stop();
    adc_set_round_robin(0);
    adc_fifo_setup(false, false, 0, false, false);

    if (averages == 0) averages = 1;
    if (averages > 4096) averages = 4096;

    uint32_t totals[ANALOG_CHANNELS] = {0};
    for (uint16_t i = 0; i < averages; i++) {
        for (int c = 0; c < ANALOG_CHANNELS; c++) {
            adc_select_input(c);
            (void)adc_read();            // the first conversion after the mux moves is not trustworthy
            totals[c] += adc_read();
        }
    }
    for (int c = 0; c < ANALOG_CHANNELS; c++)
        readings[c] = (uint16_t)((uint64_t)totals[c] * 16u / averages);
}
