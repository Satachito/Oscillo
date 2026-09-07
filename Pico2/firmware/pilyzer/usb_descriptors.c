#include "board_config.h"
#include "pico/unique_id.h"
#include "tusb.h"

#define EPNUM_VENDOR_OUT 0x01
#define EPNUM_VENDOR_IN  0x82

enum { ITF_NUM_VENDOR, ITF_NUM_TOTAL };
#define CONFIG_TOTAL_LEN (TUD_CONFIG_DESC_LEN + TUD_VENDOR_DESC_LEN)

static tusb_desc_device_t const device_descriptor = {
    .bLength            = sizeof(tusb_desc_device_t),
    .bDescriptorType    = TUSB_DESC_DEVICE,
    .bcdUSB             = 0x0200,
    .bDeviceClass       = 0x00,
    .bDeviceSubClass    = 0x00,
    .bDeviceProtocol    = 0x00,
    .bMaxPacketSize0    = CFG_TUD_ENDPOINT0_SIZE,
    .idVendor           = PILYZER_VID,
    .idProduct          = PILYZER_PID,
    .bcdDevice          = PILYZER_FIRMWARE_VERSION,
    .iManufacturer      = 1,
    .iProduct           = 2,
    .iSerialNumber      = 3,
    .bNumConfigurations = 1,
};

uint8_t const *tud_descriptor_device_cb(void)
{
    return (uint8_t const *)&device_descriptor;
}

// A vendor-specific interface, which is exactly what makes this driverless:
// macOS matches no driver against class 0xFF, so the application can claim the
// interface itself.
static uint8_t const configuration_descriptor[] = {
    TUD_CONFIG_DESCRIPTOR(1, ITF_NUM_TOTAL, 0, CONFIG_TOTAL_LEN, 0x00, 250),
    TUD_VENDOR_DESCRIPTOR(ITF_NUM_VENDOR, 4, EPNUM_VENDOR_OUT, EPNUM_VENDOR_IN, 64),
};

uint8_t const *tud_descriptor_configuration_cb(uint8_t index)
{
    (void)index;
    return configuration_descriptor;
}

static char const *const strings[] = {
    NULL,
    "PiLyzer project",
    "PiLyzer Pico 2",
    NULL,                 // filled in from the chip's unique id
    "PiLyzer instrument",
};

static uint16_t string_buffer[32];

uint16_t const *tud_descriptor_string_cb(uint8_t index, uint16_t langid)
{
    (void)langid;

    if (index == 0) {
        string_buffer[1] = 0x0409;
        string_buffer[0] = (uint16_t)((TUSB_DESC_STRING << 8) | 4);
        return string_buffer;
    }
    if (index >= TU_ARRAY_SIZE(strings)) return NULL;

    char serial[2 * PICO_UNIQUE_BOARD_ID_SIZE_BYTES + 1];
    char const *text = strings[index];
    if (index == 3) {
        pico_get_unique_board_id_string(serial, sizeof serial);
        text = serial;
    }

    uint8_t count = 0;
    while (text[count] && count < 31) {
        string_buffer[1 + count] = (uint16_t)text[count];
        count++;
    }
    string_buffer[0] = (uint16_t)((TUSB_DESC_STRING << 8) | (2 * count + 2));
    return string_buffer;
}
