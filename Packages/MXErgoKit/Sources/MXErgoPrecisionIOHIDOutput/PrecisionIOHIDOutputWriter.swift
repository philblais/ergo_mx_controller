import Foundation
@preconcurrency import IOKit.hid
import MXErgoHIDPP
import MXErgoPrecisionTransport
import MXErgoPrecisionWriteLifecycle

/// The output target's sole package construction door. It returns only the
/// already-reviewed writer-plus-drain capability, never the concrete runtime.
package enum PrecisionIOHIDOutputFactory {
    package static func make(
        exclusivelyOwnedDevice device: IOHIDDevice,
        plan: PrecisionTemporaryDiversionPlan,
        binding: PrecisionTransportBinding
    ) throws -> any PrecisionTransportDrainingReportWriter {
        try PrecisionIOHIDOutputWriter(
            exclusivelyOwnedDevice: device,
            plan: plan,
            binding: binding
        )
    }
}

enum PrecisionIOHIDOutputError: Error, Sendable, Equatable {
    case invalidPhysicalIdentity
    case invalidOutputReportCapability
}

struct PrecisionIOHIDOutputPhysicalDescriptor: Sendable, Equatable {
    let vendorID: Int?
    let productID: Int?
    let transport: String?
    let serialNumber: String?
    let locationID: Int?
    let primaryUsagePage: Int?
    let primaryUsage: Int?
    let outputReportIDs: Set<UInt32>
    let maximumOutputReportByteCount: Int?

    var deviceID: String {
        [vendorID, productID, locationID, primaryUsagePage, primaryUsage]
            .map { $0.map(String.init) ?? "unknown" }
            .joined(separator: "-")
    }
}

protocol PrecisionIOHIDOutputRuntime: AnyObject, Sendable {
    var physicalDescriptor: PrecisionIOHIDOutputPhysicalDescriptor { get }

    /// Synchronous, potentially blocking, and outcome-unknown after entry.
    /// The lifecycle guarantees this receives only one owned reviewed record.
    func setOutputReport(reportID: UInt8, bytes: [UInt8]) -> Int32
}

/// Productless output facade for one already-open, exclusively transferred
/// IOHIDDevice. It owns no discovery, open/close, activation, callback, retry,
/// inverse, or acknowledgement behavior. The existing reviewed lifecycle is
/// the only state machine and the only route to the blocking runtime call.
final class PrecisionIOHIDOutputWriter:
    PrecisionTransportDrainingReportWriter,
    @unchecked Sendable {
    private let runtime: any PrecisionIOHIDOutputRuntime
    private let lifecycle: any PrecisionTransportDrainingReportWriter

    init(
        plan: PrecisionTemporaryDiversionPlan,
        binding: PrecisionTransportBinding,
        runtime: any PrecisionIOHIDOutputRuntime
    ) throws {
        try Self.validate(
            runtime.physicalDescriptor,
            expectedDevice: binding.session.device
        )
        let retainedRuntime = runtime
        self.runtime = retainedRuntime
        lifecycle = try PrecisionWriteLifecycleFactory.make(
            plan: plan,
            binding: binding
        ) { record in
            guard record.device == binding.session.device,
                  record.connectionEpoch
                    == binding.session.connectionEpoch,
                  record.rootGeneration == binding.rootGeneration,
                  record.bytes.count == HIDPP20LongMessage.byteCount,
                  record.bytes.first == HIDPP20LongMessage.reportID else {
                return Int32(kIOReturnBadArgument)
            }
            return retainedRuntime.setOutputReport(
                reportID: HIDPP20LongMessage.reportID,
                bytes: record.bytes
            )
        }
    }

    /// Deliberately file-private. The narrow package factory above is the only
    /// cross-module construction route; no concrete runtime type escapes.
    fileprivate convenience init(
        exclusivelyOwnedDevice device: IOHIDDevice,
        plan: PrecisionTemporaryDiversionPlan,
        binding: PrecisionTransportBinding
    ) throws {
        try self.init(
            plan: plan,
            binding: binding,
            runtime: SystemPrecisionIOHIDOutputRuntime(
                retainedDevice: device
            )
        )
    }

    func write(_ frame: PrecisionTransportOutputFrame) async throws -> Int32 {
        try await lifecycle.write(frame)
    }

    func cancelPendingWrite(
        requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        lifecycle.cancelPendingWrite(requestID: requestID, reason: reason)
    }

    func shutdownAndDrain() async {
        await lifecycle.shutdownAndDrain()
    }

    private static func validate(
        _ descriptor: PrecisionIOHIDOutputPhysicalDescriptor,
        expectedDevice: JournalDeviceIdentity
    ) throws {
        guard expectedDevice.vendorID == 0x046D,
              expectedDevice.productID == 0xB01D,
              expectedDevice.transport == "Bluetooth Low Energy",
              expectedDevice.hasStableDiscriminator,
              expectedDevice.firmwareIdentity?.isEmpty == false,
              descriptor.vendorID == expectedDevice.vendorID,
              descriptor.productID == expectedDevice.productID,
              descriptor.transport == expectedDevice.transport,
              descriptor.serialNumber == expectedDevice.serialNumber,
              descriptor.locationID == expectedDevice.locationID,
              descriptor.deviceID == expectedDevice.deviceID else {
            throw PrecisionIOHIDOutputError.invalidPhysicalIdentity
        }
        guard descriptor.outputReportIDs
                == Set([UInt32(HIDPP20LongMessage.reportID)]),
              descriptor.maximumOutputReportByteCount
                == HIDPP20LongMessage.byteCount else {
            throw PrecisionIOHIDOutputError.invalidOutputReportCapability
        }
    }
}

private final class SystemPrecisionIOHIDOutputRuntime:
    PrecisionIOHIDOutputRuntime,
    @unchecked Sendable {
    let physicalDescriptor: PrecisionIOHIDOutputPhysicalDescriptor
    private let device: UncheckedIOHIDOutputDevice

    init(retainedDevice device: IOHIDDevice) {
        let retained = UncheckedIOHIDOutputDevice(value: device)
        self.device = retained
        let elements = IOHIDDeviceCopyMatchingElements(
            retained.value,
            nil,
            IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] ?? []
        let outputReportIDs = Set(elements.compactMap { element -> UInt32? in
            guard IOHIDElementGetType(element)
                    == kIOHIDElementTypeOutput else { return nil }
            return IOHIDElementGetReportID(element)
        })
        physicalDescriptor = PrecisionIOHIDOutputPhysicalDescriptor(
            vendorID: Self.integerProperty(kIOHIDVendorIDKey, from: retained.value),
            productID: Self.integerProperty(kIOHIDProductIDKey, from: retained.value),
            transport: Self.stringProperty(kIOHIDTransportKey, from: retained.value),
            serialNumber: Self.stringProperty(
                kIOHIDSerialNumberKey,
                from: retained.value
            ),
            locationID: Self.integerProperty(
                kIOHIDLocationIDKey,
                from: retained.value
            ),
            primaryUsagePage: Self.integerProperty(
                kIOHIDPrimaryUsagePageKey,
                from: retained.value
            ),
            primaryUsage: Self.integerProperty(
                kIOHIDPrimaryUsageKey,
                from: retained.value
            ),
            outputReportIDs: outputReportIDs,
            maximumOutputReportByteCount: Self.integerProperty(
                kIOHIDMaxOutputReportSizeKey,
                from: retained.value
            )
        )
    }

    func setOutputReport(reportID: UInt8, bytes: [UInt8]) -> Int32 {
        guard reportID == HIDPP20LongMessage.reportID,
              bytes.count == HIDPP20LongMessage.byteCount,
              bytes.first == reportID else {
            return Int32(kIOReturnBadArgument)
        }
        var ownedBytes = bytes
        return Int32(ownedBytes.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(
                device.value,
                kIOHIDReportTypeOutput,
                CFIndex(reportID),
                baseAddress,
                bytes.count
            )
        })
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

private struct UncheckedIOHIDOutputDevice: @unchecked Sendable {
    let value: IOHIDDevice
}
