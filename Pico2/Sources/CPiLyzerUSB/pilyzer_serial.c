#include "pilyzer_serial.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/serial/IOSerialKeys.h>
#include <IOKit/usb/USBSpec.h>

// The tty is a child of the USB device in the registry, so its identifiers are
// found by searching upwards from it rather than on the tty itself.
static CFTypeRef ancestor_property(io_service_t service, CFStringRef key)
{
    return IORegistryEntrySearchCFProperty(service, kIOServicePlane, key, kCFAllocatorDefault,
                                           kIORegistryIterateRecursively | kIORegistryIterateParents);
}

static uint32_t ancestor_number(io_service_t service, CFStringRef key)
{
    uint32_t result = 0;
    CFTypeRef value = ancestor_property(service, key);
    if (!value) return 0;
    if (CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, &result);
    CFRelease(value);
    return result;
}

static void copy_string(CFTypeRef value, char *destination, size_t capacity)
{
    destination[0] = '\0';
    if (!value) return;
    if (CFGetTypeID(value) == CFStringGetTypeID())
        CFStringGetCString((CFStringRef)value, destination, (CFIndex)capacity, kCFStringEncodingUTF8);
    CFRelease(value);
}

int32_t pilyzer_serial_enumerate(uint16_t vendor_id, const uint16_t *product_ids,
                                 int32_t product_count,
                                 pilyzer_serial_info *out, int32_t capacity)
{
    CFMutableDictionaryRef matching = IOServiceMatching(kIOSerialBSDServiceValue);
    if (!matching) return -1;
    CFDictionarySetValue(matching, CFSTR(kIOSerialBSDTypeKey), CFSTR(kIOSerialBSDAllTypes));

    io_iterator_t iterator = 0;
    kern_return_t result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (result != KERN_SUCCESS) return (int32_t)result;

    int32_t count = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != 0) {
        uint16_t vendor = (uint16_t)ancestor_number(service, CFSTR(kUSBVendorID));
        uint16_t product = (uint16_t)ancestor_number(service, CFSTR(kUSBProductID));
        int wanted = vendor == vendor_id;
        if (wanted) {
            wanted = 0;
            for (int32_t i = 0; i < product_count; i++) if (product_ids[i] == product) wanted = 1;
        }
        if (wanted && count < capacity) {
            pilyzer_serial_info *info = &out[count];
            memset(info, 0, sizeof *info);
            info->vendor_id = vendor;
            info->product_id = product;
            info->location_id = ancestor_number(service, CFSTR("locationID"));
            copy_string(IORegistryEntryCreateCFProperty(service, CFSTR(kIOCalloutDeviceKey),
                                                        kCFAllocatorDefault, 0),
                        info->path, sizeof info->path);
            copy_string(ancestor_property(service, CFSTR(kUSBSerialNumberString)),
                        info->serial, sizeof info->serial);
            copy_string(ancestor_property(service, CFSTR(kUSBProductString)),
                        info->product, sizeof info->product);
            if (info->path[0]) count++;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return count;
}

int pilyzer_serial_open(const char *path, int32_t *error)
{
    // Non-blocking, so opening does not wait on carrier detect; reads and
    // writes wait on poll() with their own timeouts instead.
    int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) { if (error) *error = errno; return -1; }

    struct termios options;
    if (ioctl(fd, TIOCEXCL) != 0 || tcgetattr(fd, &options) != 0) goto fail;
    cfmakeraw(&options);
    options.c_cflag |= CLOCAL | CREAD;
    // An UNO R4 WiFi's USB port is an ESP32-S3 that passes the bytes on over a
    // UART at this rate, and its sketch listens at the same one. A native CDC
    // port ignores the number — but never 1200, which an Arduino takes as the
    // signal to drop into its bootloader.
    cfsetspeed(&options, B230400);
    if (tcsetattr(fd, TCSANOW, &options) != 0) goto fail;

    // A CDC device may hold its output back until the host says a terminal is
    // there, which is what DTR means. A port with no modem lines at all — a
    // pseudo-terminal — refuses this, and needs no such thing.
    int bits = TIOCM_DTR | TIOCM_RTS;
    (void)ioctl(fd, TIOCMBIS, &bits);

    tcflush(fd, TCIOFLUSH);
    return fd;

fail:
    if (error) *error = errno;
    close(fd);
    return -1;
}

void pilyzer_serial_close(int fd)
{
    if (fd >= 0) close(fd);
}

static int64_t now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

int32_t pilyzer_serial_write(int fd, const void *bytes, uint32_t length, uint32_t timeout_ms)
{
    const uint8_t *next = bytes;
    int64_t deadline = now_ms() + timeout_ms;
    while (length > 0) {
        int64_t left = deadline - now_ms();
        if (left <= 0) return ETIMEDOUT;
        struct pollfd wait = { .fd = fd, .events = POLLOUT };
        int ready = poll(&wait, 1, (int)left);
        if (ready < 0) { if (errno == EINTR) continue; return errno; }
        if (ready == 0) return ETIMEDOUT;
        if (wait.revents & (POLLERR | POLLHUP | POLLNVAL)) return EIO;
        ssize_t written = write(fd, next, length);
        if (written < 0) {
            if (errno == EAGAIN || errno == EINTR) continue;
            return errno;
        }
        next += written;
        length -= (uint32_t)written;
    }
    return 0;
}

int32_t pilyzer_serial_read(int fd, void *bytes, uint32_t capacity, uint32_t timeout_ms,
                            uint32_t *transferred)
{
    *transferred = 0;
    int64_t deadline = now_ms() + timeout_ms;
    for (;;) {
        int64_t left = deadline - now_ms();
        if (left < 0) left = 0;
        struct pollfd wait = { .fd = fd, .events = POLLIN };
        int ready = poll(&wait, 1, (int)left);
        if (ready < 0) { if (errno == EINTR) continue; return errno; }
        if (ready == 0) return 0;
        if (wait.revents & (POLLERR | POLLNVAL)) return EIO;
        ssize_t got = read(fd, bytes, capacity);
        if (got < 0) {
            if (errno == EAGAIN || errno == EINTR) continue;
            return errno;
        }
        // Readable with nothing to read is the far end having gone away.
        if (got == 0) return (wait.revents & POLLHUP) ? EIO : 0;
        *transferred = (uint32_t)got;
        return 0;
    }
}

void pilyzer_serial_flush(int fd)
{
    tcflush(fd, TCIOFLUSH);
}
