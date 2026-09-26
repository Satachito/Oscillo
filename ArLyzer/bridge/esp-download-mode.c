// Puts an UNO R4 WiFi's ESP32-S3 into its ROM's download mode, so esptool can
// write it, with no jumper: the bridge firmware takes HID feature report 0xAA
// on its CMSIS-DAP interface as the signal. Arduino's own updater does the
// same (unor4wifi-reboot in arduino/uno-r4-wifi-usb-bridge); this is that one
// call in C, for a Mac, so nothing has to be installed to make it.
//
//   xcrun clang -framework IOKit -framework CoreFoundation esp-download-mode.c -o esp-download-mode
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <stdio.h>
#include <string.h>

static CFDictionaryRef matching(int vendor, int product) {
  CFMutableDictionaryRef dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks,
                                                          &kCFTypeDictionaryValueCallBacks);
  CFNumberRef v = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vendor);
  CFNumberRef p = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &product);
  CFDictionarySetValue(dict, CFSTR(kIOHIDVendorIDKey), v);
  CFDictionarySetValue(dict, CFSTR(kIOHIDProductIDKey), p);
  CFRelease(v);
  CFRelease(p);
  return dict;
}

int main(void) {
  IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
  CFDictionaryRef match = matching(0x2341, 0x1002);
  IOHIDManagerSetDeviceMatching(manager, match);
  CFRelease(match);
  IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
  CFSetRef devices = IOHIDManagerCopyDevices(manager);
  if (!devices || CFSetGetCount(devices) == 0) {
    fprintf(stderr, "No UNO R4 WiFi (2341:1002) found.\n");
    return 1;
  }
  const void *first = NULL;
  CFSetGetValues(devices, &first);  // one is enough: it has a single HID interface
  IOHIDDeviceRef device = (IOHIDDeviceRef)first;
  if (IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
    fprintf(stderr, "Cannot open the board's HID interface.\n");
    return 1;
  }
  uint8_t report[64];
  memset(report, 0, sizeof report);
  report[0] = 0xAA;
  // The board resets as it takes this, so the call may report a failure that
  // is in fact the device leaving; the ROM's own USB port appearing is the test.
  IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, report, sizeof report);
  printf("Asked the ESP32-S3 to restart into download mode.\n");
  return 0;
}
