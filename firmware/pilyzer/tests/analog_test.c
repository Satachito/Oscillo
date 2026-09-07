#include <assert.h>
#include <stdio.h>
// Compile the production acquisition code against the SDK substitutes.
#include "../analog.c"

static void configure(void)
{
    analog_abort();
    memset(raw_ring, 0, sizeof raw_ring);
    memset(record_buffer, 0, sizeof record_buffer);
    pilyzer_analog_config_t config = {
        .channel_mask = 3, .trigger_mode = TRIG_NORMAL,
        .trigger_level = 32768, .sample_period_fs = 4000000000ULL,
        .record_samples = 16384, .pretrigger_samples = 15564,
    };
    pilyzer_plan_t actual;
    assert(analog_configure(&config, &actual) == ST_OK);
    assert(analog_arm() == ST_OK);
    assert(plan.decimation == 1);
}

static void late_trigger_restarts(void)
{
    configure();
    // One DMA batch crosses the last edge position with room for a tail.
    run.state = STATE_WAITING;
    run.armed = true;
    run.written = (plan.high_water - 1) * plan.channels;
    run.scanned = run.written / plan.channels;
    raw_ring[198] = 4095;
    mock_dma.transfer_count = ADC_DMA_TRANSFERS - 200;
    analog_poll();
    assert(run.state == STATE_WAITING);
    assert(run.written == plan.pretrigger * plan.channels);
    assert(run.raw_consumed == 0); // The DMA has been restarted.
}

static void last_valid_trigger_completes(void)
{
    configure();
    run.state = STATE_WAITING;
    run.armed = true;
    run.written = (plan.high_water - 1) * plan.channels;
    run.scanned = run.written / plan.channels;
    raw_ring[2] = 4095; // Edge exactly at high_water: tail fits exactly.
    mock_dma.transfer_count = ADC_DMA_TRANSFERS - 200;
    analog_poll();
    assert(run.state == STATE_POST);
    assert(run.stop_at == plan.capacity);
    for (int i = 0; i < 30 && !analog_idle(); i++) {
        mock_dma.transfer_count -= 200;
        analog_poll();
    }
    assert(run.state == STATE_COMPLETE);
    assert(run.triggered);
    assert(run.record_start + plan.record == plan.capacity);
    uint32_t count = plan.record;
    uint8_t channels;
    const uint16_t *samples = analog_record(0, &count, &channels);
    assert(count == 16384 && channels == 2);
    assert(samples[plan.pretrigger * channels] == 65520);
    (void)samples[count * channels - 1];
}

static void full_buffer_never_writes_past_end(void)
{
    configure();
    run.written = ANALOG_BUFFER_CONVERSIONS;
    mock_dma.transfer_count = ADC_DMA_TRANSFERS - 2;
    drain_converter();
    assert(run.written == ANALOG_BUFFER_CONVERSIONS);
    assert(run.raw_consumed == 0);
}

static void filtered_trigger_preserves_raw_record(void)
{
    for (int enabled = 0; enabled <= 1; enabled++) {
        analog_abort();
        pilyzer_analog_config_t config = {
            .channel_mask = 3, .trigger_mode = TRIG_NORMAL,
            .trigger_level = 32768, .trigger_hysteresis = 256,
            .sample_period_fs = 4000000000ULL,
            .record_samples = 1024, .pretrigger_samples = 200,
            .trigger_lowpass_hz = enabled ? 1000 : 0,
        };
        pilyzer_plan_t actual;
        assert(analog_configure(&config, &actual) == ST_OK);
        assert(analog_arm() == ST_OK);
        for (int i = 0; i < 2048; i++) {
            record_buffer[i * 2] = i == 300 ? 65520 : (i >= 600 ? 35000 : 30000);
            record_buffer[i * 2 + 1] = (uint16_t)i;
        }
        uint16_t original[4096];
        memcpy(original, record_buffer, sizeof original);
        run.written = 4096;
        scan_for_trigger();
        assert(run.state == STATE_POST);
        uint32_t edge = run.record_start + run.trigger_index;
        if (enabled) assert(edge > 600 && edge < 900);
        else assert(edge == 300);
        assert(memcmp(original, record_buffer, sizeof original) == 0);
    }
}

static void rollover_replays_filter_history_without_triggering_in_it(void)
{
    analog_abort();
    pilyzer_analog_config_t config = {
        .channel_mask = 1, .trigger_mode = TRIG_NORMAL,
        .trigger_level = 32768, .sample_period_fs = 4000000000ULL,
        .record_samples = 1024, .pretrigger_samples = 512, .trigger_lowpass_hz = 1000,
    };
    pilyzer_plan_t actual;
    assert(analog_configure(&config, &actual) == ST_OK);
    assert(analog_arm() == ST_OK);
    for (int i = 0; i < 2048; i++) record_buffer[i] = i < 1800 ? 30000 : 35000;
    run.written = 2048;
    restart_with_history();
    assert(run.scanned == 0 && run.state == STATE_FILLING);
    scan_for_trigger();
    assert(run.state == STATE_FILLING); // Every replayed sample is pre-trigger history.
    assert(run.scanned == 512 && !run.triggered);
    assert(trigger_filter.remaining == 0);
}

// Exercise every ADC mask, including sparse CH1+CH3 and CH3 alone.
static void channel_masks_and_ring_wrap(void)
{
    for (uint8_t mask = 1; mask < 8; mask++) {
        analog_abort();
        pilyzer_analog_config_t config = {
            .channel_mask = mask, .trigger_mode = TRIG_FREE_RUN,
            .sample_period_fs = 1, .record_samples = 3000,
        };
        pilyzer_plan_t actual;
        assert(analog_configure(&config, &actual) == ST_OK);
        const uint channels = __builtin_popcount(mask);
        assert(actual.channel_mask == mask && actual.conversions_per_sample == channels);
        // The fastest the converter will actually honour. A 96-cycle interval
        // puts the pacing register below the value it obeys, and it free-runs.
        assert(actual.divisor_q8 == ADC_MIN_PERIOD_CYCLES * 256 && actual.decimation == 1);
        assert(plan.first_input == __builtin_ctz(mask));
        assert(plan.capacity >= 2 * ANALOG_MAX_RECORD);
        assert(analog_arm() == ST_OK);
        uint gpio_channel[3], slot = 0;
        for (uint c = 0; c < 3; c++) if (mask & (1u << c)) gpio_channel[slot++] = c;
        uint produced = 0;
        // 997-word batches split frames and cross the 4096-word DMA ring.
        while (produced < 3000 * channels) {
            uint batch = 997;
            if (batch > 3000 * channels - produced) batch = 3000 * channels - produced;
            for (uint i = 0; i < batch; i++) {
                uint absolute = produced + i;
                raw_ring[absolute & (ADC_RAW_SAMPLES - 1)] =
                    1000 * gpio_channel[absolute % channels] + (absolute / channels) % 900;
            }
            produced += batch;
            mock_dma.transfer_count = ADC_DMA_TRANSFERS - produced;
            drain_converter();
        }
        assert(run.written == 3000 * channels && run.phase == 0);
        for (uint i = 0; i < 3000; i++) for (uint c = 0; c < channels; c++)
            assert(record_buffer[i * channels + c] == (1000 * gpio_channel[c] + i % 900) * 16);
    }
    analog_abort();
    pilyzer_analog_config_t bad = {.channel_mask = 8, .record_samples = 10};
    pilyzer_plan_t actual;
    assert(analog_configure(&bad, &actual) == ST_BAD_ARGUMENT);
}

static void third_channel_trigger_and_buffer_tail(void)
{
    analog_abort();
    pilyzer_analog_config_t config = {
        .channel_mask = 7, .trigger_mode = TRIG_NORMAL, .trigger_source = 2,
        .trigger_level = 32768, .sample_period_fs = 6000000000ULL,
        .record_samples = 16384, .pretrigger_samples = 15000,
    };
    pilyzer_plan_t actual;
    assert(analog_configure(&config, &actual) == ST_OK);
    assert(plan.source_index == 2 && actual.record_samples == 16384);
    assert(analog_arm() == ST_OK);
    // CH1 and CH2 are always high; only CH3 has the requested edge.
    for (uint i = 0; i < plan.capacity; i++) {
        record_buffer[i * 3] = record_buffer[i * 3 + 1] = 60000;
        record_buffer[i * 3 + 2] = i < plan.high_water ? 10000 : 50000;
    }
    run.written = plan.capacity * 3;
    scan_for_trigger();
    assert(run.state == STATE_POST && run.stop_at == plan.capacity);
    assert(run.record_start + plan.pretrigger == plan.high_water);
    complete(run.record_start, plan.pretrigger, true);
    uint32_t count = 16384;
    uint8_t channels;
    const uint16_t *samples = analog_record(0, &count, &channels);
    assert(count == 16384 && channels == 3);
    assert(samples[(count - 1) * 3 + 2] == 50000);
    // A full three-channel buffer must never write an incomplete frame.
    run.written = ANALOG_BUFFER_CONVERSIONS;
    run.raw_consumed = 0;
    mock_dma.transfer_count = ADC_DMA_TRANSFERS - 3;
    drain_converter();
    assert(run.raw_consumed == 0 && run.written == ANALOG_BUFFER_CONVERSIONS);
}

// The converter ignores its pacing register when the value is below 96, and
// free-runs instead — at which point the interval the host is told is a
// fiction. Measured on hardware: asking for a 96-cycle interval read a 1 kHz
// square wave back as 2 kHz. Whatever period is asked for, the register has to
// stay in the range the converter honours, and the plan has to describe the
// register that was actually written.
static void pacing_register_stays_in_the_honoured_range(void)
{
    static const uint64_t periods_fs[] = {
        1000ULL,                 // absurdly fast: everything clamps
        2000000ULL,              // 2 ns
        4041666ULL,              // the fastest three channels can really go
        6250000ULL, 10000000ULL, 1000000000ULL, 100000000000ULL,
    };
    for (unsigned mask = 1; mask <= 7; mask++) {
        for (unsigned i = 0; i < sizeof periods_fs / sizeof *periods_fs; i++) {
            analog_abort();
            pilyzer_analog_config_t config = {
                .channel_mask = (uint8_t)mask, .trigger_mode = TRIG_FREE_RUN,
                .trigger_level = 32768, .sample_period_fs = periods_fs[i],
                .record_samples = 1024, .pretrigger_samples = 128,
            };
            pilyzer_plan_t granted;
            assert(analog_configure(&config, &granted) == ST_OK);
            assert(analog_arm() == ST_OK);

            assert(mock_adc.div >= (ADC_MIN_PERIOD_CYCLES - 1u) << 8);
            // The plan must describe the register that was written, or the
            // time axis is drawn from a number nothing obeys.
            assert(granted.divisor_q8 == mock_adc.div + 256u);
            assert(granted.conversions_per_sample == __builtin_popcount(mask));
            assert(granted.decimation >= 1);
        }
    }
    analog_abort();
}

int main(void)
{
    analog_init();
    late_trigger_restarts();
    last_valid_trigger_completes();
    full_buffer_never_writes_past_end();
    filtered_trigger_preserves_raw_record();
    rollover_replays_filter_history_without_triggering_in_it();
    channel_masks_and_ring_wrap();
    third_channel_trigger_and_buffer_tail();
    pacing_register_stays_in_the_honoured_range();
    assert(mock_adc_pin_mask == ((1u << 26) | (1u << 27) | (1u << 28)));
    for (int i = 0; i < 3; i++) mock_adc_values[i] = 100 * (i + 1);
    uint16_t readings[3];
    analog_immediate(16, readings);
    for (int i = 0; i < 3; i++) assert(readings[i] == 1600 * (i + 1));
    puts("Analog: 9 regressions passed (all masks, three-channel trigger, DMA wrap and meter)");
}
