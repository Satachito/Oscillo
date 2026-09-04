import Foundation
import IOKit
import IOKit.hid

/// Keeps a live list of attached DPScope SE units.
///
/// A one-shot enumeration is not enough: seizing a HID device makes the system
/// re-enumerate it when the owner exits, so for a moment after the app quits or
/// disconnects the scope is genuinely absent from the registry. Watching for
/// matching and removal notifications covers that window, and hot-plugging with
/// it.
public final class HIDDeviceWatcher {
    /// Called on `callbackQueue` whenever the set of attached scopes changes.
    public var onChange: (([HIDDeviceInfo]) -> Void)?

    public private(set) var devices: [HIDDeviceInfo] = []

    private let manager: IOHIDManager
    private let callbackQueue: DispatchQueue
    private var isRunning = false

    public init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(
            manager,
            [kIOHIDVendorIDKey: HIDTransport.vendorID, kIOHIDProductIDKey: HIDTransport.productID] as CFDictionary
        )
    }

    deinit { stop() }

    /// Starts watching. Must be called from a thread with a live run loop —
    /// in practice the main thread.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        let context = Unmanaged.passUnretained(self).toOpaque()
        let notify: IOHIDDeviceCallback = { context, _, _, _ in
            Unmanaged<HIDDeviceWatcher>.fromOpaque(context!).takeUnretainedValue().refresh()
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, notify, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, notify, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        refresh()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Re-reads the device list and reports it if it changed.
    public func refresh() {
        let found = HIDTransport.availableDevices()
        guard found != devices else { return }
        devices = found
        callbackQueue.async { [onChange, found] in onChange?(found) }
    }
}
