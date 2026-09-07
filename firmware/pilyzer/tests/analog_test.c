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

int main(void)
{
    analog_init();
    late_trigger_restarts();
    last_valid_trigger_completes();
    full_buffer_never_writes_past_end();
    filtered_trigger_preserves_raw_record();
    rollover_replays_filter_history_without_triggering_in_it();
    puts("Analog: 5 regressions passed");
}
