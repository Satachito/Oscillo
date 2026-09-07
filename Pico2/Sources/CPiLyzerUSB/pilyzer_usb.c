#include "pilyzer_usb.h"

#include <string.h>
#include <stdbool.h>
#include <stdlib.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>

struct pilyzer_usb_device {
    IOUSBDeviceInterface500    **device;
    IOUSBInterfaceInterface500 **interface;
    uint8_t  pipe_in;
    uint8_t  pipe_out;
    uint32_t packet_size;
};

static void copy_string_property(io_service_t service, CFStringRef key,
                                 char *destination, size_t capacity)
{
    destination[0] = '\0';
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!value) return;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)value, destination, (CFIndex)capacity, kCFStringEncodingUTF8);
    }
    CFRelease(value);
}

static uint32_t number_property(io_service_t service, CFStringRef key)
{
    uint32_t result = 0;
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!value) return 0;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, &result);
    }
    CFRelease(value);
    return result;
}

// IOKit will not match a USB device on idVendor alone — the vendor and the
// product have to be given together, and a dictionary carrying only idVendor
// silently matches nothing. So the whole bus is enumerated by class, which does
// work, and the identifiers are compared here. A product id of zero then means
// "any product of that vendor", which is how the application finds a board that
// is attached but is not an instrument.
static bool identifiers_match(io_service_t service, uint16_t vendor_id, uint16_t product_id)
{
    if (number_property(service, CFSTR(kUSBVendorID)) != vendor_id) return false;
    if (product_id == 0) return true;
    return number_property(service, CFSTR(kUSBProductID)) == product_id;
}

int32_t pilyzer_usb_enumerate(uint16_t vendor_id, uint16_t product_id,
                              pilyzer_usb_info *out, int32_t capacity)
{
    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matching) return -1;

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (result != KERN_SUCCESS) return -(int32_t)result;

    int32_t found = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        if (found < capacity && identifiers_match(service, vendor_id, product_id)) {
            pilyzer_usb_info *info = &out[found];
            memset(info, 0, sizeof *info);
            info->vendor_id = vendor_id;
            info->product_id = (uint16_t)number_property(service, CFSTR(kUSBProductID));
            info->location_id = number_property(service, CFSTR(kUSBDevicePropertyLocationID));
            copy_string_property(service, CFSTR(kUSBSerialNumberString), info->serial, sizeof info->serial);
            copy_string_property(service, CFSTR(kUSBProductString), info->product, sizeof info->product);
            found++;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return found;
}

static IOUSBDeviceInterface500 **create_device_interface(io_service_t service)
{
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                          kIOCFPlugInInterfaceID, &plugin, &score) != KERN_SUCCESS) {
        return NULL;
    }

    IOUSBDeviceInterface500 **device = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID500),
                              (LPVOID *)&device);
    (*plugin)->Release(plugin);
    return device;
}

static IOUSBInterfaceInterface500 **claim_vendor_interface(IOUSBDeviceInterface500 **device,
                                                           int32_t *error)
{
    IOUSBFindInterfaceRequest request = {
        .bInterfaceClass = kIOUSBFindInterfaceDontCare,
        .bInterfaceSubClass = kIOUSBFindInterfaceDontCare,
        .bInterfaceProtocol = kIOUSBFindInterfaceDontCare,
        .bAlternateSetting = kIOUSBFindInterfaceDontCare,
    };

    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn result = (*device)->CreateInterfaceIterator(device, &request, &iterator);
    if (result != kIOReturnSuccess) { *error = result; return NULL; }

    IOUSBInterfaceInterface500 **claimed = NULL;
    io_service_t service;
    while (!claimed && (service = IOIteratorNext(iterator))) {
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        if (IOCreatePlugInInterfaceForService(service, kIOUSBInterfaceUserClientTypeID,
                                              kIOCFPlugInInterfaceID, &plugin, &score) == KERN_SUCCESS) {
            IOUSBInterfaceInterface500 **candidate = NULL;
            (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID500),
                                      (LPVOID *)&candidate);
            (*plugin)->Release(plugin);

            if (candidate) {
                UInt8 interface_class = 0;
                (*candidate)->GetInterfaceClass(candidate, &interface_class);
                if (interface_class == kUSBVendorSpecificInterfaceClass &&
                    (*candidate)->USBInterfaceOpen(candidate) == kIOReturnSuccess) {
                    claimed = candidate;
                } else {
                    (*candidate)->Release(candidate);
                }
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);

    if (!claimed) *error = kIOReturnNoDevice;
    return claimed;
}

static int find_pipes(struct pilyzer_usb_device *handle)
{
    IOUSBInterfaceInterface500 **interface = handle->interface;
    UInt8 endpoints = 0;
    if ((*interface)->GetNumEndpoints(interface, &endpoints) != kIOReturnSuccess) return 0;

    handle->pipe_in = 0;
    handle->pipe_out = 0;
    for (UInt8 pipe = 1; pipe <= endpoints; pipe++) {
        UInt8 direction = 0, number = 0, transfer_type = 0, interval = 0;
        UInt16 max_packet = 0;
        if ((*interface)->GetPipeProperties(interface, pipe, &direction, &number,
                                            &transfer_type, &max_packet, &interval) != kIOReturnSuccess) {
            continue;
        }
        if (transfer_type != kUSBBulk) continue;
        if (direction == kUSBIn && handle->pipe_in == 0) {
            handle->pipe_in = pipe;
            handle->packet_size = max_packet;
        } else if (direction == kUSBOut && handle->pipe_out == 0) {
            handle->pipe_out = pipe;
        }
    }
    return handle->pipe_in && handle->pipe_out;
}

pilyzer_usb_device *pilyzer_usb_open(uint16_t vendor_id, uint16_t product_id,
                                     uint32_t location_id, int32_t *error)
{
    int32_t ignored = 0;
    if (!error) error = &ignored;
    *error = kIOReturnNoDevice;

    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matching) return NULL;

    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return NULL;
    }

    IOUSBDeviceInterface500 **device = NULL;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        if (!device && identifiers_match(service, vendor_id, product_id) &&
            (location_id == 0 ||
             number_property(service, CFSTR(kUSBDevicePropertyLocationID)) == location_id)) {
            device = create_device_interface(service);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    if (!device) return NULL;

    IOReturn result = (*device)->USBDeviceOpen(device);
    if (result == kIOReturnExclusiveAccess) {
        // Another process holds the instrument. Taking it would leave both
        // clients reading each other's replies, so refuse instead.
        (*device)->Release(device);
        *error = result;
        return NULL;
    }
    if (result != kIOReturnSuccess) {
        (*device)->Release(device);
        *error = result;
        return NULL;
    }

    UInt8 configuration = 0;
    (*device)->GetConfiguration(device, &configuration);
    if (configuration == 0) {
        IOUSBConfigurationDescriptorPtr descriptor = NULL;
        if ((*device)->GetConfigurationDescriptorPtr(device, 0, &descriptor) == kIOReturnSuccess &&
            descriptor != NULL) {
            (*device)->SetConfiguration(device, descriptor->bConfigurationValue);
        }
    }

    struct pilyzer_usb_device *handle = calloc(1, sizeof *handle);
    if (!handle) {
        (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        *error = kIOReturnNoMemory;
        return NULL;
    }
    handle->device = device;
    handle->interface = claim_vendor_interface(device, error);
    if (!handle->interface || !find_pipes(handle)) {
        pilyzer_usb_close(handle);
        return NULL;
    }

    *error = kIOReturnSuccess;
    return handle;
}

void pilyzer_usb_close(pilyzer_usb_device *handle)
{
    if (!handle) return;
    if (handle->interface) {
        (*handle->interface)->USBInterfaceClose(handle->interface);
        (*handle->interface)->Release(handle->interface);
    }
    if (handle->device) {
        (*handle->device)->USBDeviceClose(handle->device);
        (*handle->device)->Release(handle->device);
    }
    free(handle);
}

uint32_t pilyzer_usb_packet_size(const pilyzer_usb_device *handle)
{
    return handle ? handle->packet_size : 0;
}

int32_t pilyzer_usb_write(pilyzer_usb_device *handle, const void *bytes,
                          uint32_t length, uint32_t timeout_ms)
{
    if (!handle || !handle->interface) return kIOReturnNotOpen;
    IOUSBInterfaceInterface500 **interface = handle->interface;
    return (*interface)->WritePipeTO(interface, handle->pipe_out, (void *)bytes,
                                     length, timeout_ms, timeout_ms);
}

int32_t pilyzer_usb_read(pilyzer_usb_device *handle, void *bytes, uint32_t capacity,
                         uint32_t timeout_ms, uint32_t *transferred)
{
    if (!handle || !handle->interface) return kIOReturnNotOpen;
    IOUSBInterfaceInterface500 **interface = handle->interface;
    UInt32 size = capacity;
    IOReturn result = (*interface)->ReadPipeTO(interface, handle->pipe_in, bytes, &size,
                                               timeout_ms, timeout_ms);
    if (transferred) *transferred = (uint32_t)size;
    return result;
}

int32_t pilyzer_usb_reset(pilyzer_usb_device *handle)
{
    if (!handle || !handle->interface) return kIOReturnNotOpen;
    IOUSBInterfaceInterface500 **interface = handle->interface;
    (*interface)->ClearPipeStallBothEnds(interface, handle->pipe_in);
    (*interface)->ClearPipeStallBothEnds(interface, handle->pipe_out);
    return kIOReturnSuccess;
}

int32_t pilyzer_usb_reenumerate(uint16_t vendor_id, uint16_t product_id, uint32_t location_id)
{
    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matching) return kIOReturnNoMemory;

    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return kIOReturnNoDevice;
    }

    IOUSBDeviceInterface500 **device = NULL;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        if (!device && identifiers_match(service, vendor_id, product_id) &&
            (location_id == 0 ||
             number_property(service, CFSTR(kUSBDevicePropertyLocationID)) == location_id)) {
            device = create_device_interface(service);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    if (!device) return kIOReturnNoDevice;

    IOReturn result = (*device)->USBDeviceOpen(device);
    if (result == kIOReturnSuccess) {
        result = (*device)->USBDeviceReEnumerate(device, 0);
        // The device drops off the bus as a result, so there is nothing left to
        // close politely.
    }
    (*device)->Release(device);
    return result;
}
