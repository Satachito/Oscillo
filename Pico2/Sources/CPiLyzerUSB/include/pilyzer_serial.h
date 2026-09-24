// A small C surface over a USB CDC serial port, for instruments whose USB
// stack offers nothing else — the ArLyzer on an Arduino Nano R4. The frames
// are the vendor interface's own; only the pipe is a tty instead.
//
// termios and the modem-control ioctls are macros Swift cannot see, so the
// port is opened and configured here and Swift gets a descriptor back.
#ifndef PILYZER_SERIAL_H
#define PILYZER_SERIAL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t location_id;
    uint16_t vendor_id;
    uint16_t product_id;
    char     path[128];     // the callout device, /dev/cu.*
    char     serial[64];
    char     product[64];
} pilyzer_serial_info;

// Fills `out` with up to `capacity` serial ports whose USB device has this
// vendor and one of `product_count` product ids. Returns the number written,
// or a negative IOKit error.
int32_t pilyzer_serial_enumerate(uint16_t vendor_id, const uint16_t *product_ids,
                                 int32_t product_count,
                                 pilyzer_serial_info *out, int32_t capacity);

// Opens the port for exclusive use, raw, with DTR and RTS asserted, and
// flushes whatever a previous session left in it. Returns a descriptor, or -1
// with `error` set to errno.
int pilyzer_serial_open(const char *path, int32_t *error);

void pilyzer_serial_close(int fd);

// 0 once every byte is written, otherwise errno (ETIMEDOUT past the timeout).
int32_t pilyzer_serial_write(int fd, const void *bytes, uint32_t length, uint32_t timeout_ms);

// Waits up to `timeout_ms` for data, then reads what is there, at most
// `capacity` bytes. 0 with `transferred` 0 means the time ran out.
int32_t pilyzer_serial_read(int fd, void *bytes, uint32_t capacity, uint32_t timeout_ms,
                            uint32_t *transferred);

// Throws away anything waiting in either direction.
void pilyzer_serial_flush(int fd);

#ifdef __cplusplus
}
#endif

#endif
