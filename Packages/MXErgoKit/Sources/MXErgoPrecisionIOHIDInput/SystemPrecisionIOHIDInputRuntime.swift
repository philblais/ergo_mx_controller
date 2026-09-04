import Foundation
@preconcurrency import IOKit.hid
import MXErgoHIDPP
import MXErgoPrecisionIOHIDOwnership
import MXErgoPrecisionTransport

/// The input target's sole package construction door. The raw device never
/// leaves the private runtime, and the returned existential exposes only the
/// input lifecycle required by the pure ownership coordinator.
package enum PrecisionIOHIDInputFactory {
    package static func make(
        exclusivelyOwnedDevice device: IOHIDDevice,
        binding: PrecisionTransportBinding
    ) throws -> any PrecisionIOHIDInputLifetime {
        let runtime = try SystemPrecisionIOHIDInputRuntime(
            exclusivelyOwnedDevice: device,
            expectedDevice: binding.session.device
        )
        return try PrecisionIOHIDInputSession(
            binding: binding,
            runtime: runtime
        )
    }
}

struct PrecisionIOHIDInputSystemCalls: @unchecked Sendable {
    let setDispatchQueue: (DispatchQueue) -> Void
    let registerInputReport: (
        UnsafeMutablePointer<UInt8>,
        Int,
        IOHIDReportCallback?,
        UnsafeMutableRawPointer?
    ) -> Void
    let registerRemoval: (
        IOHIDCallback?,
        UnsafeMutableRawPointer?
    ) -> Void
    let setCancelHandler: (@escaping @Sendable () -> Void) -> Void
    let activate: () -> Void
    let cancel: () -> Void
}

/// The only IOKit-linked implementation in the Precision input target.
/// It registers callbacks for an already-open, exclusively transferred device.
/// It performs no discovery, open, output report, or automatic activation.
final class SystemPrecisionIOHIDInputRuntime:
    PrecisionIOHIDInputRuntime,
    @unchecked Sendable {
    private enum State: Sendable, Equatable {
        case initialized
        case configured
        case active
        case cancelling
        case stopped
    }

    let inputReportBufferByteCount: Int
    private let calls: PrecisionIOHIDInputSystemCalls
    private let senderMatches: @Sendable (UnsafeMutableRawPointer?) -> Bool
    private let lock = NSLock()
    private var state: State = .initialized
    private var sink: (any PrecisionIOHIDInputEventSink)?

    init(
        inputReportBufferByteCount: Int,
        senderMatches: @escaping @Sendable (UnsafeMutableRawPointer?) -> Bool,
        calls: PrecisionIOHIDInputSystemCalls
    ) throws {
        guard inputReportBufferByteCount >= HIDPP20LongMessage.byteCount,
              inputReportBufferByteCount <= 4_096 else {
            throw PrecisionIOHIDInputError.invalidInputReportBufferLength
        }
        self.inputReportBufferByteCount = inputReportBufferByteCount
        self.senderMatches = senderMatches
        self.calls = calls
    }

    fileprivate convenience init(
        exclusivelyOwnedDevice device: IOHIDDevice,
        expectedDevice: JournalDeviceIdentity
    ) throws {
        guard Self.matchesExpectedIdentity(device, expected: expectedDevice),
              let bufferByteCount = Self.integerProperty(
                kIOHIDMaxInputReportSizeKey,
                from: device
              ) else {
            throw PrecisionIOHIDInputError.invalidDeviceIdentity
        }
        let uncheckedDevice = UncheckedIOHIDDevice(value: device)
        let calls = PrecisionIOHIDInputSystemCalls(
            setDispatchQueue: { queue in
                IOHIDDeviceSetDispatchQueue(uncheckedDevice.value, queue)
            },
            registerInputReport: { buffer, length, callback, context in
                IOHIDDeviceRegisterInputReportCallback(
                    uncheckedDevice.value,
                    buffer,
                    CFIndex(length),
                    callback,
                    context
                )
            },
            registerRemoval: { callback, context in
                IOHIDDeviceRegisterRemovalCallback(
                    uncheckedDevice.value,
                    callback,
                    context
                )
            },
            setCancelHandler: { handler in
                IOHIDDeviceSetCancelHandler(uncheckedDevice.value, handler)
            },
            activate: {
                IOHIDDeviceActivate(uncheckedDevice.value)
            },
            cancel: {
                IOHIDDeviceCancel(uncheckedDevice.value)
            }
        )
        try self.init(
            inputReportBufferByteCount: bufferByteCount,
            senderMatches: { sender in
                guard let sender else { return false }
                let candidate = Unmanaged<IOHIDDevice>
                    .fromOpaque(sender)
                    .takeUnretainedValue()
                return CFEqual(candidate, uncheckedDevice.value)
            },
            calls: calls
        )
    }

    func configure(
        queue: DispatchQueue,
        reportBuffer: UnsafeMutablePointer<UInt8>,
        reportBufferLength: Int,
        sink: any PrecisionIOHIDInputEventSink
    ) throws {
        lock.lock()
        guard state == .initialized else {
            lock.unlock()
            throw PrecisionIOHIDInputError.alreadyConfigured
        }
        guard reportBufferLength == inputReportBufferByteCount else {
            lock.unlock()
            throw PrecisionIOHIDInputError.invalidInputReportBufferLength
        }
        self.sink = sink
        state = .configured
        lock.unlock()

        let context = Unmanaged.passUnretained(self).toOpaque()
        calls.setDispatchQueue(queue)
        calls.registerInputReport(
            reportBuffer,
            reportBufferLength,
            precisionIOHIDInputReportCallback,
            context
        )
        calls.registerRemoval(
            precisionIOHIDRemovalCallback,
            context
        )
        calls.setCancelHandler { [weak self] in
            self?.didCancel()
        }
    }

    func activate() throws {
        lock.lock()
        guard state == .configured else {
            lock.unlock()
            throw PrecisionIOHIDInputError.notConfigured
        }
        state = .active
        lock.unlock()
        calls.activate()
    }

    func cancel() {
        lock.lock()
        switch state {
        case .initialized:
            state = .stopped
            let sink = self.sink
            self.sink = nil
            lock.unlock()
            sink?.ioHIDCallbacksCancelled()
            return
        case .configured, .active:
            state = .cancelling
        case .cancelling, .stopped:
            lock.unlock()
            return
        }
        lock.unlock()
        calls.cancel()
    }

    fileprivate func receiveInputReport(
        result: IOReturn,
        sender: UnsafeMutableRawPointer?,
        reportType: IOHIDReportType,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>?,
        reportLength: CFIndex
    ) {
        lock.lock()
        let sink = self.sink
        let acceptsCallbacks = state == .active || state == .cancelling
        lock.unlock()
        guard acceptsCallbacks, let sink else { return }
        sink.ioHIDInputReport(
            result: Int32(result),
            senderMatchesDevice: senderMatches(sender),
            isInputReport: reportType == kIOHIDReportTypeInput,
            reportID: reportID,
            report: report,
            reportLength: reportLength >= 0 ? Int(reportLength) : -1
        )
    }

    fileprivate func receiveRemoval(
        result: IOReturn,
        sender: UnsafeMutableRawPointer?
    ) {
        lock.lock()
        let sink = self.sink
        let acceptsCallbacks = state == .active || state == .cancelling
        lock.unlock()
        guard acceptsCallbacks, let sink else { return }
        sink.ioHIDDeviceRemoved(
            result: Int32(result),
            senderMatchesDevice: senderMatches(sender)
        )
    }

    private func didCancel() {
        lock.lock()
        guard state != .stopped else {
            lock.unlock()
            return
        }
        state = .stopped
        let sink = self.sink
        self.sink = nil
        lock.unlock()
        sink?.ioHIDCallbacksCancelled()
    }

    private static func matchesExpectedIdentity(
        _ device: IOHIDDevice,
        expected: JournalDeviceIdentity
    ) -> Bool {
        let vendorID = integerProperty(kIOHIDVendorIDKey, from: device)
        let productID = integerProperty(kIOHIDProductIDKey, from: device)
        let locationID = integerProperty(kIOHIDLocationIDKey, from: device)
        let usagePage = integerProperty(kIOHIDPrimaryUsagePageKey, from: device)
        let usage = integerProperty(kIOHIDPrimaryUsageKey, from: device)
        let transport = stringProperty(kIOHIDTransportKey, from: device)
        let serialNumber = stringProperty(kIOHIDSerialNumberKey, from: device)
        let deviceID = [vendorID, productID, locationID, usagePage, usage]
            .map { $0.map(String.init) ?? "unknown" }
            .joined(separator: "-")
        return expected.vendorID == vendorID
            && expected.productID == productID
            && expected.transport == transport
            && expected.serialNumber == serialNumber
            && expected.locationID == locationID
            && expected.deviceID == deviceID
            && expected.hasStableDiscriminator
            && expected.firmwareIdentity?.isEmpty == false
    }

    private static func integerProperty(
        _ key: String,
        from device: IOHIDDevice
    ) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private static func stringProperty(
        _ key: String,
        from device: IOHIDDevice
    ) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}

private struct UncheckedIOHIDDevice: @unchecked Sendable {
    let value: IOHIDDevice
}

private let precisionIOHIDInputReportCallback: IOHIDReportCallback = {
    context,
    result,
    sender,
    reportType,
    reportID,
    report,
    reportLength in
    guard let context else { return }
    Unmanaged<SystemPrecisionIOHIDInputRuntime>
        .fromOpaque(context)
        .takeUnretainedValue()
        .receiveInputReport(
            result: result,
            sender: sender,
            reportType: reportType,
            reportID: reportID,
            report: report,
            reportLength: reportLength
        )
}

private let precisionIOHIDRemovalCallback: IOHIDCallback = {
    context,
    result,
    sender in
    guard let context else { return }
    Unmanaged<SystemPrecisionIOHIDInputRuntime>
        .fromOpaque(context)
        .takeUnretainedValue()
        .receiveRemoval(result: result, sender: sender)
}
