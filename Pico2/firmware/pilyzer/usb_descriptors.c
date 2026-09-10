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
    // 2.1 rather than 2.0: anything below this and the host never asks for
    // the BOS descriptor, which is where the Windows driver binding lives.
    .bcdUSB             = 0x0210,
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

// Windows binds a driver to a vendor-specific interface by name, and with no
// name it binds nothing: the interface is visible but no application — Chrome's
// WebUSB included — can open it without the user running Zadig by hand. The
// Microsoft OS 2.0 descriptor below is the device saying "WinUSB" for itself,
// which is what makes the browser build work on Windows out of the box. macOS
// and Linux ignore all of this and are unaffected.
//
// The WebUSB capability alongside it is what lets Chrome offer the hosted
// application when the instrument is plugged in.

#define VENDOR_REQUEST_WEBUSB   1
#define VENDOR_REQUEST_MICROSOFT 2

#define MS_OS_20_DESC_LEN 0xA2
#define BOS_TOTAL_LEN (TUD_BOS_DESC_LEN + TUD_BOS_WEBUSB_DESC_LEN + TUD_BOS_MICROSOFT_OS_DESC_LEN)

static uint8_t const bos_descriptor[] = {
    TUD_BOS_DESCRIPTOR(BOS_TOTAL_LEN, 2),
    TUD_BOS_WEBUSB_DESCRIPTOR(VENDOR_REQUEST_WEBUSB, 1),
    TUD_BOS_MS_OS_20_DESCRIPTOR(MS_OS_20_DESC_LEN, VENDOR_REQUEST_MICROSOFT),
};

uint8_t const *tud_descriptor_bos_cb(void)
{
    return bos_descriptor;
}

// The interface GUID is this project's own, so a PiLyzer is not confused with
// any other WinUSB device that happens to copy an example descriptor.
static uint8_t const ms_os_20_descriptor[] = {
    // Set header: length, type, minimum Windows version, total length.
    U16_TO_U8S_LE(0x000A), U16_TO_U8S_LE(MS_OS_20_SET_HEADER_DESCRIPTOR),
    U32_TO_U8S_LE(0x06030000), U16_TO_U8S_LE(MS_OS_20_DESC_LEN),

    // Compatible id: this device wants WinUSB. It sits directly under the set
    // header, at device level, with no configuration or function subset around
    // it. Those subsets exist so that a composite device can hand different
    // metadata to each of its functions, and usbccgp is what reads them; a
    // device with one interface never loads usbccgp, so a compatible id buried
    // in a function subset is read by nobody and no driver is bound at all.
    U16_TO_U8S_LE(0x0014), U16_TO_U8S_LE(MS_OS_20_FEATURE_COMPATBLE_ID),
    'W', 'I', 'N', 'U', 'S', 'B', 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

    // Registry property: DeviceInterfaceGUIDs, so applications can find it.
    U16_TO_U8S_LE(MS_OS_20_DESC_LEN - 0x0A - 0x14),
    U16_TO_U8S_LE(MS_OS_20_FEATURE_REG_PROPERTY),
    U16_TO_U8S_LE(0x0007),               // REG_MULTI_SZ
    U16_TO_U8S_LE(0x002A),               // name length, "DeviceInterfaceGUIDs" in UTF-16
    'D', 0, 'e', 0, 'v', 0, 'i', 0, 'c', 0, 'e', 0, 'I', 0, 'n', 0, 't', 0, 'e', 0,
    'r', 0, 'f', 0, 'a', 0, 'c', 0, 'e', 0, 'G', 0, 'U', 0, 'I', 0, 'D', 0, 's', 0, 0, 0,
    U16_TO_U8S_LE(0x0050),               // value length
    '{', 0, '3', 0, 'F', 0, 'A', 0, '8', 0, '8', 0, '6', 0, 'C', 0, '9', 0, '-', 0,
    '4', 0, '8', 0, '6', 0, 'C', 0, '-', 0, '4', 0, 'D', 0, 'E', 0, 'A', 0, '-', 0,
    '8', 0, '0', 0, 'C', 0, '7', 0, '-', 0, '4', 0, '1', 0, '3', 0, '6', 0, '6', 0,
    'E', 0, '8', 0, '7', 0, '3', 0, 'C', 0, '4', 0, '8', 0, '}', 0, 0, 0, 0, 0,
};

TU_VERIFY_STATIC(sizeof(ms_os_20_descriptor) == MS_OS_20_DESC_LEN,
                 "the Microsoft OS 2.0 descriptor set does not match its declared length");

// Where Chrome offers to send someone who plugs the instrument in. The array
// carries the string's NUL so the compiler is happy; bLength leaves it out, so
// it is never transmitted.
#define PILYZER_WEBUSB_URL "satachito.github.io/Oscillo/"

static struct TU_ATTR_PACKED {
    uint8_t bLength;
    uint8_t bDescriptorType;
    uint8_t bScheme;
    char url[sizeof PILYZER_WEBUSB_URL];
} const webusb_url = {
    .bLength = 3 + sizeof PILYZER_WEBUSB_URL - 1,
    .bDescriptorType = 3,   // WEBUSB_URL
    .bScheme = 1,           // https://
    .url = PILYZER_WEBUSB_URL,
};

bool tud_vendor_control_xfer_cb(uint8_t rhport, uint8_t stage, tusb_control_request_t const *request)
{
    if (stage != CONTROL_STAGE_SETUP) return true;
    if (request->bmRequestType_bit.type != TUSB_REQ_TYPE_VENDOR) return false;

    switch (request->bRequest) {
    case VENDOR_REQUEST_WEBUSB:
        return tud_control_xfer(rhport, request, (void *)(uintptr_t)&webusb_url, webusb_url.bLength);
    case VENDOR_REQUEST_MICROSOFT:
        // wIndex 7 is the only defined one: get the whole descriptor set.
        if (request->wIndex != 7) return false;
        return tud_control_xfer(rhport, request, (void *)(uintptr_t)ms_os_20_descriptor,
                                sizeof ms_os_20_descriptor);
    default:
        return false;
    }
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
