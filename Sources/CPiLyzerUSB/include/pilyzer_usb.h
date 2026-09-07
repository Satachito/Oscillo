// A small C surface over IOKit's USB device interfaces.
//
// Swift can drive IOUSBLib directly, but only by reconstructing the CFPlugIn
// UUIDs that IOUSBLib.h defines as macros — and a wrong byte there is a
// runtime failure with nothing to read. Keeping the plug-in dance in C means
// the compiler checks it, and Swift sees an ordinary handle with read, write
// and close.
//
// The interface this opens is vendor-specific, so macOS matches no driver
// against it and an ordinary, unsandboxed application may claim it without any
// entitlement, kext or driver package.
#ifndef PILYZER_USB_H
#define PILYZER_USB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pilyzer_usb_device pilyzer_usb_device;

typedef struct {
    uint32_t location_id;
    uint16_t vendor_id;
    uint16_t product_id;
    char     serial[64];
    char     product[64];
} pilyzer_usb_info;

// Fills `out` with up to `capacity` attached devices matching vendor and
// product; a product id of zero matches every product of that vendor.
// Returns the number written, or a negative IOKit error.
int32_t pilyzer_usb_enumerate(uint16_t vendor_id, uint16_t product_id,
                              pilyzer_usb_info *out, int32_t capacity);

// Opens the device at `location_id` and claims its vendor interface.
// `error` receives the IOKit result when the call returns NULL.
pilyzer_usb_device *pilyzer_usb_open(uint16_t vendor_id, uint16_t product_id,
                                     uint32_t location_id, int32_t *error);

void pilyzer_usb_close(pilyzer_usb_device *device);

// Maximum packet size of the bulk endpoints, which is the granularity every
// read has to be a multiple of.
uint32_t pilyzer_usb_packet_size(const pilyzer_usb_device *device);

// 0 on success, otherwise the IOKit error.
int32_t pilyzer_usb_write(pilyzer_usb_device *device, const void *bytes,
                          uint32_t length, uint32_t timeout_ms);

// Reads at most `capacity` bytes — which must be a multiple of the packet
// size — and reports how many arrived in `transferred`.
int32_t pilyzer_usb_read(pilyzer_usb_device *device, void *bytes,
                         uint32_t capacity, uint32_t timeout_ms,
                         uint32_t *transferred);

// Recovers a pipe that stalled, so a failed exchange does not end the session.
int32_t pilyzer_usb_reset(pilyzer_usb_device *device);

// Asks the device to re-enumerate — a replug done from this end. It is the way
// back from an instrument left wedged by a host that died mid-exchange, and it
// is a last resort: the handle must be closed first, and the device disappears
// from the bus for a moment.
int32_t pilyzer_usb_reenumerate(uint16_t vendor_id, uint16_t product_id, uint32_t location_id);

#ifdef __cplusplus
}
#endif

#endif
