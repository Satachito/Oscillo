#include <assert.h>
#include <stdio.h>
#include "../logic.c"

static void configure(void)
{
    logic_abort();
    memset(buffer, 0, sizeof buffer);
    pilyzer_logic_config_t config = {
        .trigger_mode = TRIG_NORMAL, .sample_period_fs = 100000000ULL,
        .record_samples = 65536, .pretrigger_samples = 6552,
    };
    pilyzer_plan_t actual;
    assert(logic_configure(&config, &actual) == ST_OK);
    assert(logic_arm() == ST_OK);
}

static void fill_and_trigger(void)
{
    mock_dma.transfer_count = 0;
    mock_dma_busy = false;
    mock_trigger_flag = true;
    logic_poll();
    assert(run.state == STATE_POST);
    assert(run.trigger_hint == LOGIC_BUFFER_BYTES);
    logic_poll();
}

static void full_buffer_search_is_bounded(void)
{
    configure();
    // A valid edge leaves enough space for a complete record.
    memset(buffer + 10000, 1, sizeof buffer - 10000);
    fill_and_trigger();
    assert(run.state == STATE_COMPLETE);
    assert(run.trigger_index == plan.pretrigger);
    uint32_t count = plan.record;
    const uint8_t *samples = logic_record(0, &count);
    assert(count == plan.record);
    assert(samples[run.trigger_index - 1] == 0);
    assert(samples[run.trigger_index] == 1);
}

static void late_edge_rearms_instead_of_waiting_forever(void)
{
    configure();
    buffer[LOGIC_BUFFER_BYTES - 1] = 1;
    fill_and_trigger();
    assert(run.state == STATE_WAITING);
    assert(mock_dma_busy);
    assert(!run.triggered);
}

static void absent_edge_is_not_a_trigger(void)
{
    configure();
    fill_and_trigger();
    assert(run.state == STATE_WAITING);
    assert(!run.triggered);
    assert(mock_dma_busy);
}

static void empty_and_single_sample_searches(void)
{
    configure();
    uint32_t edge = 123;
    assert(!exact_trigger(0, 0, &edge));
    assert(!exact_trigger(1, 1, &edge));
    assert(edge == 123);
    plan.slope = SLOPE_FALLING;
    buffer[0] = 1;
    assert(exact_trigger(2, 2, &edge));
    assert(edge == 1);
}

int main(void)
{
    logic_init();
    assert(mock_pio_gpio_mask == 0xff00); // Only GPIO8…15 are claimed by PIO.
    full_buffer_search_is_bounded();
    late_edge_rearms_instead_of_waiting_forever();
    absent_edge_is_not_a_trigger();
    empty_and_single_sample_searches();
    puts("Logic: 4 boundary regressions passed");
}
