import Foundation
import IOKit
import IOKit.hid

public enum DPScopeError: Error, LocalizedError, Equatable {
    case noDeviceFound
    case cannotOpen(IOReturn)
    case writeFailed(IOReturn)
    case timeout(command: UInt8)
    case shortReply(command: UInt8, length: Int)
    case unexpectedAcknowledge(command: UInt8, received: UInt8)
    case notIdentified(String)
    case disconnected
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .noDeviceFound:
            return "No DPScope SE found on the USB bus."
        case let .cannotOpen(status):
            return String(format: "Could not open the DPScope SE (IOReturn 0x%08X).", UInt32(bitPattern: status))
        case let .writeFailed(status):
            return String(format: "Sending a command failed (IOReturn 0x%08X).", UInt32(bitPattern: status))
        case let .timeout(command):
            return "The scope did not answer command \(command)."
        case let .shortReply(command, length):
            return "Command \(command) returned only \(length) bytes."
        case let .unexpectedAcknowledge(command, received):
            return String(format: "Command %d was acknowledged with 0x%02X.", command, received)
        case let .notIdentified(identity):
            return "The device answered “\(identity)”, which is not a DPScope SE."
        case .disconnected:
            return "The DPScope SE was disconnected."
        case .notConnected:
            return "No scope is connected."
        }
    }
}

/// One DPScope SE attached to the machine.
public struct HIDDeviceInfo: Hashable, Sendable, Identifiable {
    public let locationID: UInt32
    public let product: String
    public let serialNumber: String?

    public var id: UInt32 { locationID }

    public var label: String {
        if let serialNumber, !serialNumber.isEmpty { return "\(product) (\(serialNumber))" }
        return String(format: "%@ @ 0x%08X", product, locationID)
    }
}

/// Request/response transport over USB HID.
///
/// The DPScope SE exchanges fixed 64-byte reports and answers exactly one
/// report per command, so the transport is a synchronous send-then-wait.
/// Input reports arrive on a private run loop thread, which keeps device I/O
/// independent of the main thread.
public final class HIDTransport {
    public static let vendorID = 0x04D8
    public static let productID = 0xF891
    public static let reportSize = 64

    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: HIDTransport.reportSize)
    private let lock = NSLock()
    private var reply: [UInt8]?
    private let replyReady = DispatchSemaphore(value: 0)
    private var ioThread: Thread?
    private var ioRunLoop: CFRunLoop?
    private let threadReady = DispatchSemaphore(value: 0)

    /// Lists the DPScope SE units currently attached.
    public static func availableDevices() -> [HIDDeviceInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, matchingDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>
        else { return [] }
        return devices.compactMap(describe).sorted { $0.locationID < $1.locationID }
    }

    private static var matchingDictionary: CFDictionary {
        [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID] as CFDictionary
    }

    private static func describe(_ device: IOHIDDevice) -> HIDDeviceInfo? {
        let location = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? UInt32 ?? 0
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "DPScope SE"
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        return HIDDeviceInfo(locationID: location, product: product, serialNumber: serial)
    }

    /// Opens the scope at `locationID`, or the first one found when it is nil.
    public init(locationID: UInt32? = nil) throws {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, HIDTransport.matchingDictionary)

        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else { throw DPScopeError.cannotOpen(status) }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            throw DPScopeError.noDeviceFound
        }

        let ordered = devices.sorted { (HIDTransport.describe($0)?.locationID ?? 0) < (HIDTransport.describe($1)?.locationID ?? 0) }
        // A caller that names a device must get that device or an error —
        // never a different scope that happens to be plugged in.
        let chosen = locationID.map { wanted in
            ordered.first { HIDTransport.describe($0)?.locationID == wanted }
        } ?? ordered.first
        guard let found = chosen else { throw DPScopeError.noDeviceFound }

        // Take the device exclusively: two clients talking to one scope get
        // each other's replies, which looks like corrupt data rather than an
        // error. Fall back to a shared open if the system refuses to seize.
        var openStatus = IOHIDDeviceOpen(found, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if openStatus != kIOReturnSuccess {
            openStatus = IOHIDDeviceOpen(found, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard openStatus == kIOReturnSuccess else { throw DPScopeError.cannotOpen(openStatus) }
        device = found

        startIOThread(for: found)
    }

    deinit {
        close()
        reportBuffer.deallocate()
    }

    private func startIOThread(for device: IOHIDDevice) {
        let thread = Thread { [self] in
            ioRunLoop = CFRunLoopGetCurrent()

            IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, HIDTransport.reportSize, { context, _, _, _, _, report, length in
                let transport = Unmanaged<HIDTransport>.fromOpaque(context!).takeUnretainedValue()
                transport.deliver(Array(UnsafeBufferPointer(start: report, count: length)))
            }, Unmanaged.passUnretained(self).toOpaque())

            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            threadReady.signal()

            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        thread.name = "com.dpscope.hid"
        thread.qualityOfService = .userInitiated
        ioThread = thread
        thread.start()
        threadReady.wait()
    }

    private func deliver(_ report: [UInt8]) {
        lock.lock()
        reply = report
        lock.unlock()
        replyReady.signal()
    }

    public var isOpen: Bool { device != nil }

    public func close() {
        guard let device else { return }
        self.device = nil
        ioThread?.cancel()
        if let ioRunLoop { CFRunLoopWakeUp(ioRunLoop) }
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        ioThread = nil
        ioRunLoop = nil
    }

    /// Sends one command packet and returns the scope's 64-byte answer.
    public func exchange(_ payload: [UInt8], timeout: TimeInterval = 1.0) throws -> [UInt8] {
        guard let device else { throw DPScopeError.disconnected }
        precondition(payload.count <= HIDTransport.reportSize, "packet longer than one report")

        // Drop anything left over from an abandoned exchange.
        lock.lock()
        reply = nil
        lock.unlock()
        while replyReady.wait(timeout: .now()) == .success {}

        var report = [UInt8](repeating: 0, count: HIDTransport.reportSize)
        report.replaceSubrange(0..<payload.count, with: payload)

        let status = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, report, report.count)
        guard status == kIOReturnSuccess else {
            if status == kIOReturnNotOpen || status == kIOReturnNoDevice { throw DPScopeError.disconnected }
            throw DPScopeError.writeFailed(status)
        }

        guard replyReady.wait(timeout: .now() + timeout) == .success else {
            throw DPScopeError.timeout(command: payload.first ?? 0)
        }
        lock.lock()
        let answer = reply
        lock.unlock()
        guard let answer else { throw DPScopeError.timeout(command: payload.first ?? 0) }
        return answer
    }
}
