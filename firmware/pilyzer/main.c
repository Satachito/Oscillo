// PiLyzer — a two-channel oscilloscope, spectrum analyser front end and eight
// channel logic analyser on a Raspberry Pi Pico 2.
//
// This file is only the conversation with the host: it reassembles request
// frames from the bulk endpoint, hands them to the acquisition modules, and
// streams the answers back. Nothing here blocks, so the decimator in analog.c
// and the trigger watch in logic.c keep running while a record is being sent.

#include <string.h>

#include "analog.h"
#include "board_config.h"
#include "hardware/clocks.h"
#include "hardware/gpio.h"
#include "hardware/pwm.h"
#include "logic.h"
#include "pico/bootrom.h"
#include "pico/stdlib.h"
#include "pilyzer_protocol.h"
#include "tusb.h"

#define MAX_REQUEST_PAYLOAD 64

// --- Outgoing frames ----------------------------------------------------
// A response is a header, optionally a small inline payload, and optionally a
// large body that points straight into an acquisition buffer — records are
// never copied on their way out.
static uint8_t  tx_head[PILYZER_HEADER_SIZE + MAX_REQUEST_PAYLOAD];
static uint32_t tx_head_sent;
static uint32_t tx_head_size;
static const uint8_t *tx_body;
static uint32_t tx_body_sent;
static uint32_t tx_body_size;
static bool     reboot_when_drained;

// How long a response may make no progress before it is abandoned. The host's
// own transfer timeouts are a second or two, so nothing that is still being
// waited for is thrown away.
#define TX_ABANDON_MS 2500

static uint32_t tx_last_progress_ms;

static bool transmitting(void)
{
    return tx_head_sent < tx_head_size || tx_body_sent < tx_body_size;
}

// Forgets whatever was being said and starts listening again.
//
// A host that is killed mid-exchange leaves an answer nobody will ever read.
// Without this the transmit buffer stays full, the receive buffer fills behind
// it, the endpoint stops accepting anything, and the instrument needs its power
// removed before it will talk again.
static void abandon_exchange(void)
{
    tx_head_size = 0;
    tx_head_sent = 0;
    tx_body_size = 0;
    tx_body_sent = 0;
    tx_body = NULL;
    tud_vendor_read_flush();
}

static void respond(uint8_t opcode, uint16_t sequence, uint8_t status,
                    const void *inline_payload, uint32_t inline_size,
                    const uint8_t *body, uint32_t body_size)
{
    pilyzer_header_t header = {
        .magic = PILYZER_MAGIC_RESPONSE,
        .opcode = opcode,
        .status = status,
        .flags = 0,
        .sequence = sequence,
        .reserved = 0,
        .length = inline_size + body_size,
    };
    memcpy(tx_head, &header, sizeof header);
    if (inline_size) memcpy(tx_head + PILYZER_HEADER_SIZE, inline_payload, inline_size);

    tx_head_size = PILYZER_HEADER_SIZE + inline_size;
    tx_head_sent = 0;
    tx_body = body;
    tx_body_size = body ? body_size : 0;
    tx_body_sent = 0;
}

static void pump_transmit(void)
{
    uint32_t before = tx_head_sent + tx_body_sent;

    while (tx_head_sent < tx_head_size) {
        uint32_t written = tud_vendor_write(tx_head + tx_head_sent, tx_head_size - tx_head_sent);
        if (written == 0) break;
        tx_head_sent += written;
    }
    if (tx_head_sent == tx_head_size) {
        while (tx_body_sent < tx_body_size) {
            uint32_t written = tud_vendor_write(tx_body + tx_body_sent, tx_body_size - tx_body_sent);
            if (written == 0) break;
            tx_body_sent += written;
        }
    }
    tud_vendor_write_flush();

    if (!transmitting()) { tx_last_progress_ms = 0; return; }

    uint32_t now = to_ms_since_boot(get_absolute_time());
    if (tx_last_progress_ms == 0 || tx_head_sent + tx_body_sent != before) {
        tx_last_progress_ms = now;
    } else if (now - tx_last_progress_ms > TX_ABANDON_MS) {
        abandon_exchange();
        tx_last_progress_ms = 0;
    }
}

// --- Peripherals the host can poke --------------------------------------

static void set_led(bool on)
{
#ifdef PICO_DEFAULT_LED_PIN
    gpio_put(PICO_DEFAULT_LED_PIN, on);
#else
    (void)on;
#endif
}

static uint8_t range_pin(uint8_t channel)
{
    return channel == 0 ? PIN_RANGE_CH1 : PIN_RANGE_CH2;
}

static uint32_t set_calibration_output(bool on, uint32_t frequency_hz)
{
    uint slice = pwm_gpio_to_slice_num(PIN_CALIBRATION_OUT);
    uint channel = pwm_gpio_to_channel(PIN_CALIBRATION_OUT);

    if (!on) {
        pwm_set_enabled(slice, false);
        gpio_set_function(PIN_CALIBRATION_OUT, GPIO_FUNC_SIO);
        gpio_set_dir(PIN_CALIBRATION_OUT, GPIO_OUT);
        gpio_put(PIN_CALIBRATION_OUT, 0);
        return 0;
    }

    if (frequency_hz == 0) frequency_hz = 1000;
    uint32_t system_hz = clock_get_hz(clk_sys);
    if (frequency_hz > system_hz / 4) frequency_hz = system_hz / 4;

    uint32_t counts = system_hz / frequency_hz;
    uint32_t divider = counts / 65536u + 1u;
    if (divider > 255) divider = 255;
    uint32_t wrap = counts / divider;
    if (wrap < 2) wrap = 2;
    if (wrap > 65536) wrap = 65536;

    gpio_set_function(PIN_CALIBRATION_OUT, GPIO_FUNC_PWM);
    pwm_set_clkdiv_int_frac(slice, (uint8_t)divider, 0);
    pwm_set_wrap(slice, (uint16_t)(wrap - 1));
    pwm_set_chan_level(slice, channel, (uint16_t)(wrap / 2));
    pwm_set_enabled(slice, true);
    return system_hz / (divider * wrap);
}

// --- Request handling ---------------------------------------------------

static void fill_identity(pilyzer_identity_t *identity)
{
    memset(identity, 0, sizeof *identity);
    identity->magic = PILYZER_IDENTITY_MAGIC;
    identity->protocol_version = PILYZER_PROTOCOL_VERSION;
    identity->firmware_version = PILYZER_FIRMWARE_VERSION;
    identity->board_id = PILYZER_BOARD_ID;
    memcpy(identity->name, "PiLyzer Pico 2", 14);
}

static void fill_capabilities(pilyzer_capabilities_t *capabilities)
{
    memset(capabilities, 0, sizeof *capabilities);
    capabilities->analog_channels = ANALOG_CHANNELS;
    // The converter's own width. Samples are left-aligned into 16 bits and
    // decimation fills in below, so the host derives full scale from this.
    capabilities->analog_bits = 12;
    capabilities->logic_channels = LOGIC_CHANNELS;
    capabilities->analog_ranges = ANALOG_RANGES;
    capabilities->analog_clock_hz = ADC_CLOCK_HZ;
    capabilities->analog_min_period_cycles = ADC_MIN_PERIOD_CYCLES;
    capabilities->analog_max_record = ANALOG_MAX_RECORD;
    capabilities->analog_max_pretrigger = ANALOG_MAX_RECORD - 1;
    capabilities->logic_clock_hz = logic_clock_hz();
    capabilities->logic_max_record = LOGIC_MAX_RECORD;
    capabilities->logic_max_pretrigger = LOGIC_MAX_RECORD - 1;
    capabilities->reference_microvolts = ADC_REFERENCE_MICROVOLTS;
    capabilities->flags = CAP_CALIBRATION_OUTPUT |
                          (PILYZER_BOARD_ID != 0 ? CAP_SOFTWARE_RANGE : 0);
}

static void handle(const pilyzer_header_t *header, const uint8_t *payload)
{
    const uint8_t opcode = header->opcode;
    const uint16_t sequence = header->sequence;
    const uint32_t length = header->length;

    switch (opcode) {
    case OP_IDENTIFY: {
        pilyzer_identity_t identity;
        fill_identity(&identity);
        respond(opcode, sequence, ST_OK, &identity, sizeof identity, NULL, 0);
        return;
    }
    case OP_CAPABILITIES: {
        pilyzer_capabilities_t capabilities;
        fill_capabilities(&capabilities);
        respond(opcode, sequence, ST_OK, &capabilities, sizeof capabilities, NULL, 0);
        return;
    }
    case OP_SET_LED:
        if (length < 1) { respond(opcode, sequence, ST_BAD_LENGTH, NULL, 0, NULL, 0); return; }
        set_led(payload[0] != 0);
        respond(opcode, sequence, ST_OK, NULL, 0, NULL, 0);
        return;

    case OP_SET_RANGE:
        if (length < 2) { respond(opcode, sequence, ST_BAD_LENGTH, NULL, 0, NULL, 0); return; }
        if (payload[0] >= ANALOG_CHANNELS || payload[1] >= ANALOG_RANGES) {
            respond(opcode, sequence, ST_BAD_ARGUMENT, NULL, 0, NULL, 0);
            return;
        }
        gpio_put(range_pin(payload[0]), payload[1] != 0);
        respond(opcode, sequence, ST_OK, NULL, 0, NULL, 0);
        return;

    case OP_SET_CALIBRATION_OUT: {
        if (length < 5) { respond(opcode, sequence, ST_BAD_LENGTH, NULL, 0, NULL, 0); return; }
        uint32_t requested;
        memcpy(&requested, payload + 1, sizeof requested);
        uint32_t actual = set_calibration_output(payload[0] != 0, requested);
        respond(opcode, sequence, ST_OK, &actual, sizeof actual, NULL, 0);
        return;
    }
    case OP_REBOOT_BOOTLOADER:
        respond(opcode, sequence, ST_OK, NULL, 0, NULL, 0);
        reboot_when_drained = true;
        return;

    case OP_ANALOG_CONFIGURE: {
        if (length < sizeof(pilyzer_analog_config_t)) {
            respond(opcode, sequence, ST_BAD_LENGTH, NULL, 0, NULL, 0);
            return;
        }
        pilyzer_analog_config_t config;
        memcpy(&config, payload, sizeof config);
        pilyzer_plan_t plan;
        uint8_t status = analog_configure(&config, &plan);
        respond(opcode, sequence, status,
                status == ST_OK ? &plan : NULL, status == ST_OK ? sizeof plan : 0, NULL, 0);
        return;
    }
    case OP_ANALOG_ARM:
        respond(opcode, sequence, analog_arm(), NULL, 0, NULL, 0);
        return;

    case OP_ANALOG_STATUS: {
        pilyzer_acq_status_t status;
        analog_status(&status);
        respond(opcode, sequence, ST_OK, &status, sizeof status, NULL, 0);
        return;
    }
    case OP_ANALOG_READ: {
        if (length < sizeof(pilyzer_read_request_t)) {
            respond(opcode, sequence, ST_BAD_LENGTH, NULL, 0, NULL, 0);
            return;
        }
        pilyzer_read_request_t request;
        memcpy(&request, payload, sizeof request);
        uint8_t channels = 1;
        uint32_t count = request.count;
        const uint16_t *samples = analog_record(request.offset, &count, &channels);
        uint32_t ceiling = PILYZER_MAX_PAYLOAD / (channels * 2u);
        if (count > ceiling) count = ceiling;
        respond(opcode, sequence, ST_OK, NULL, 0,
                (const uint8_t *)samples, count * channels * 2u);
        return;
    }
    case OP_ANALOG_ABORT:
        analog_abort();
        respond(opcode, sequence, ST_OK, NULL, 0, NULL, 0);
        return;

    case OP_ANALOG_SAMPLE: {
        if (!analog_idle()) { respond(opcode, sequence, ST_BUSY, NULL, 0, NULL, 0); return; }
        uint16_t averages = 1;
        if (length >= 2) memcpy(&averages, payload, sizeof averages);
        uint16_t reading[2];
        analog_immediate(averages, &reading[0], &reading[1]);
        respond(opcode, sequence, ST_OK, reading, sizeof reading, NULL, 0);
        return;
    }

    case OP_LOGIC_CONFIGURE: {
        if (length < sizeof(pilyzer_logic_config_t)) {
            respond(opcode, sequence, ST_BAD_LENGTH, NULL, 0, NULL, 0);
            return;
        }
        pilyzer_logic_config_t config;
        memcpy(&config, payload, sizeof config);
        pilyzer_plan_t plan;
        uint8_t status = logic_configure(&config, &plan);
        respond(opcode, sequence, status,
                status == ST_OK ? &plan : NULL, status == ST_OK ? sizeof plan : 0, NULL, 0);
        return;
    }
    case OP_LOGIC_ARM:
        respond(opcode, sequence, logic_arm(), NULL, 0, NULL, 0);
        return;

    case OP_LOGIC_STATUS: {
        pilyzer_acq_status_t status;
        logic_status(&status);
        respond(opcode, sequence, ST_OK, &status, sizeof status, NULL, 0);
        return;
    }
    case OP_LOGIC_READ: {
        if (length < sizeof(pilyzer_read_request_t)) {
            respond(opcode, sequence, ST_BAD_LENGTH, NULL, 0, NULL, 0);
            return;
        }
        pilyzer_read_request_t request;
        memcpy(&request, payload, sizeof request);
        uint32_t count = request.count;
        if (count > PILYZER_MAX_PAYLOAD) count = PILYZER_MAX_PAYLOAD;
        const uint8_t *samples = logic_record(request.offset, &count);
        respond(opcode, sequence, ST_OK, NULL, 0, samples, count);
        return;
    }
    case OP_LOGIC_ABORT:
        logic_abort();
        respond(opcode, sequence, ST_OK, NULL, 0, NULL, 0);
        return;

    default:
        respond(opcode, sequence, ST_UNKNOWN_OPCODE, NULL, 0, NULL, 0);
        return;
    }
}

// --- Incoming frames ----------------------------------------------------

static uint8_t  rx_header_bytes[PILYZER_HEADER_SIZE];
static uint32_t rx_header_have;
static pilyzer_header_t rx_header;
static bool     rx_header_complete;
static uint8_t  rx_payload[MAX_REQUEST_PAYLOAD];
static uint32_t rx_payload_have;
static uint32_t rx_discard;

static void reset_receiver(void)
{
    rx_header_have = 0;
    rx_payload_have = 0;
    rx_header_complete = false;
}

// The link went away and came back — a replug, or the host asking for a
// re-enumeration to get an unresponsive instrument back. Either way nothing
// that was in flight means anything now.
void tud_mount_cb(void)
{
    abandon_exchange();
    reset_receiver();
    rx_discard = 0;
    tx_last_progress_ms = 0;
}

void tud_umount_cb(void)
{
    tud_mount_cb();
    analog_abort();
    logic_abort();
}

static void pump_receive(void)
{
    // One exchange at a time: nothing new is parsed while an answer is still
    // going out, which is what lets a response body point into a live buffer.
    if (transmitting()) return;

    while (tud_vendor_available()) {
        if (rx_discard) {
            uint8_t scratch[64];
            uint32_t want = rx_discard < sizeof scratch ? rx_discard : sizeof scratch;
            rx_discard -= tud_vendor_read(scratch, want);
            continue;
        }

        if (!rx_header_complete) {
            uint32_t got = tud_vendor_read(rx_header_bytes + rx_header_have,
                                           PILYZER_HEADER_SIZE - rx_header_have);
            rx_header_have += got;
            if (rx_header_have < PILYZER_HEADER_SIZE) return;

            memcpy(&rx_header, rx_header_bytes, sizeof rx_header);
            rx_header_complete = true;
            rx_payload_have = 0;

            if (rx_header.magic != PILYZER_MAGIC_REQUEST) {
                // Out of step with the host: throw away everything queued and
                // start looking for a header again.
                reset_receiver();
                continue;
            }
            if (rx_header.length > MAX_REQUEST_PAYLOAD) {
                rx_discard = rx_header.length;
                respond(rx_header.opcode, rx_header.sequence, ST_BAD_LENGTH, NULL, 0, NULL, 0);
                reset_receiver();
                return;
            }
        }

        if (rx_payload_have < rx_header.length) {
            rx_payload_have += tud_vendor_read(rx_payload + rx_payload_have,
                                               rx_header.length - rx_payload_have);
            if (rx_payload_have < rx_header.length) return;
        }

        handle(&rx_header, rx_payload);
        reset_receiver();
        return;
    }
}

int main(void)
{
#ifdef PICO_DEFAULT_LED_PIN
    gpio_init(PICO_DEFAULT_LED_PIN);
    gpio_set_dir(PICO_DEFAULT_LED_PIN, GPIO_OUT);
#endif
    gpio_init(PIN_RANGE_CH1);
    gpio_set_dir(PIN_RANGE_CH1, GPIO_OUT);
    gpio_init(PIN_RANGE_CH2);
    gpio_set_dir(PIN_RANGE_CH2, GPIO_OUT);
    set_calibration_output(true, 1000);

    analog_init();
    logic_init();
    tusb_init();

    while (true) {
        tud_task();
        analog_poll();
        logic_poll();
        pump_receive();
        pump_transmit();

        if (reboot_when_drained && !transmitting()) {
            sleep_ms(20);            // let the last packet leave before the link drops
            reset_usb_boot(0, 0);
        }
    }
}
