import Foundation
@preconcurrency import IOKit.hid
import MXErgoHIDPP
import MXErgoPrecisionIOHIDAssembly
import MXErgoPrecisionIOHIDOwnership
import MXErgoPrecisionTransport
import MXErgoPrecisionWriteLifecycle

enum PrecisionIOHIDAcquisitionError: Error, Sendable, Equatable {
    case invalidBinding
    case managerOpenFailed(Int32, managerCloseReturn: Int32)
    case deviceEnumerationUnavailable(managerCloseReturn: Int32)
    case noMatchingDevice(managerCloseReturn: Int32)
    case multipleMatchingDevices(count: Int, managerCloseReturn: Int32)
    case deviceOpenFailed(Int32, managerCloseReturn: Int32)
    case managerCloseFailed(Int32, deviceCloseReturn: Int32)
}

struct PrecisionIOHIDAssemblyRollbackError: Error, @unchecked Sendable {
    let underlying: any Error
    let deviceCloseReturn: Int32
}

struct PrecisionIOHIDAcquisitionCalls<Manager: AnyObject, Device: AnyObject> {
    let createManager: () -> Manager
    let configureMatching: (Manager) -> Void
    let openManager: (Manager) -> Int32
    let copyDevices: (Manager) -> [Device]?
    let matchesExpectedDevice: (Device) -> Bool
    let openDevice: (Device) -> Int32
    let closeManager: (Manager) -> Int32
    let closeDevice: (Device) -> Int32
    let makeAssembly: (
        Device,
        any PrecisionIOHIDQuiescentReleaseAnchor
    ) throws -> any PrecisionIOHIDAssembledEndpoint
}

/// The only capability allowed to cross from acquisition into the dormant
/// runtime-composition target. It exposes no manager, device, assembly, or
/// callback implementation.
package protocol PrecisionIOHIDAcquiredEndpoint:
    AnyObject,
    PrecisionTransportReportReader,
    PrecisionTransportDrainingReportWriter {
    func start() async throws
    var deviceCloseReturn: Int32? { get }
    func setUnsolicitedHIDPPHandler(
        _ handler: (@Sendable (PrecisionTransportInputFrame) -> Void)?
    )
    func setDisconnectHandler(_ handler: (@Sendable () -> Void)?)
}

extension PrecisionIOHIDAcquiredEndpoint {
    func setUnsolicitedHIDPPHandler(
        _ handler: (@Sendable (PrecisionTransportInputFrame) -> Void)?
    ) {
        _ = handler
    }

    func setDisconnectHandler(_ handler: (@Sendable () -> Void)?) {
        _ = handler
    }
}

package enum PrecisionIOHIDAcquisitionFactory {
    package static func validate(
        plan: PrecisionTemporaryDiversionPlan,
        binding: PrecisionTransportBinding
    ) throws {
        guard PrecisionIOHIDAcquiredSession.isValidBinding(
            plan: plan,
            binding: binding
        ) else {
            throw PrecisionIOHIDAcquisitionError.invalidBinding
        }
    }

    package static func make(
        plan: PrecisionTemporaryDiversionPlan,
        binding: PrecisionTransportBinding,
        operationLease: MXErgoDeviceOperationLease
    ) throws -> any PrecisionIOHIDAcquiredEndpoint {
        try validate(plan: plan, binding: binding)
        return try PrecisionIOHIDAcquiredSession(
            plan: plan,
            binding: binding,
            operationLease: operationLease
        )
    }
}

/// Productless owner for one independently enumerated and directly opened
/// device. The manager is always closed before an assembled session escapes.
/// The device is closed only by the quarantined release anchor after output
/// drain and input callback quiescence, or synchronously during construction
/// rollback before an endpoint can escape.
final class PrecisionIOHIDAcquiredSession:
    PrecisionIOHIDAcquiredEndpoint,
    PrecisionTransportReportReader,
    PrecisionTransportDrainingReportWriter,
    @unchecked Sendable {
    private let endpoint: any PrecisionIOHIDAssembledEndpoint
    private let closeAnchor: any PrecisionIOHIDCloseResultAnchor

    convenience init(
        plan: PrecisionTemporaryDiversionPlan,
        binding: PrecisionTransportBinding,
        operationLease: MXErgoDeviceOperationLease
    ) throws {
        let expectedDevice = binding.session.device
        try self.init(
            plan: plan,
            binding: binding,
            calls: PrecisionIOHIDAcquisitionCalls<IOHIDManager, IOHIDDevice>(
                createManager: {
                    IOHIDManagerCreate(
                        kCFAllocatorDefault,
                        IOOptionBits(
                            IOHIDManagerOptions.independentDevices.rawValue
                        )
                    )
                },
                configureMatching: { manager in
                    IOHIDManagerSetDeviceMatching(manager, [
                        kIOHIDVendorIDKey: expectedDevice.vendorID,
                        kIOHIDProductIDKey: expectedDevice.productID,
                    ] as CFDictionary)
                },
                openManager: { manager in
                    IOHIDManagerOpen(
                        manager,
                        IOOptionBits(kIOHIDOptionsTypeNone)
                    )
                },
                copyDevices: { manager in
                    guard let devices = IOHIDManagerCopyDevices(manager)
                    else { return nil }
                    return (devices as NSSet).allObjects.map {
                        $0 as! IOHIDDevice
                    }
                },
                matchesExpectedDevice: { device in
                    Self.matchesExpectedDevice(
                        device,
                        expected: expectedDevice
                    )
                },
                openDevice: { device in
                    IOHIDDeviceOpen(
                        device,
                        IOOptionBits(kIOHIDOptionsTypeNone)
                    )
                },
                closeManager: { manager in
                    IOHIDManagerClose(
                        manager,
                        IOOptionBits(kIOHIDOptionsTypeNone)
                    )
                },
                closeDevice: { device in
                    IOHIDDeviceClose(
                        device,
                        IOOptionBits(kIOHIDOptionsTypeNone)
                    )
                },
                makeAssembly: { device, anchor in
                    try PrecisionIOHIDAssemblyFactory.make(
                        exclusivelyOpenedDevice: device,
                        quiescentReleaseAnchor: anchor,
                        plan: plan,
                        binding: binding
                    )
                }
            ),
            retainedOperationLease: operationLease
        )
    }

    init<Manager: AnyObject, Device: AnyObject>(
        plan: PrecisionTemporaryDiversionPlan,
        binding: PrecisionTransportBinding,
        calls: PrecisionIOHIDAcquisitionCalls<Manager, Device>,
        retainedOperationLease: MXErgoDeviceOperationLease? = nil
    ) throws {
        try PrecisionIOHIDAcquisitionFactory.validate(
            plan: plan,
            binding: binding
        )
        let acquired = try Self.acquire(
            calls: calls,
            retainedOperationLease: retainedOperationLease
        )
        endpoint = acquired.endpoint
        closeAnchor = acquired.closeAnchor
    }

    func start() async throws {
        try await endpoint.start()
    }

    func write(_ frame: PrecisionTransportOutputFrame) async throws -> Int32 {
        try await endpoint.write(frame)
    }

    func cancelPendingWrite(
        requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        endpoint.cancelPendingWrite(requestID: requestID, reason: reason)
    }

    func shutdownAndDrain() async {
        await endpoint.shutdownAndDrain()
    }

    func beginRequest(_ frame: PrecisionTransportOutputFrame) throws {
        try endpoint.beginRequest(frame)
    }

    func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame {
        try await endpoint.read(for: requestID)
    }

    func endRequest(_ requestID: UUID) {
        endpoint.endRequest(requestID)
    }

    func cancelRequest(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        endpoint.cancelRequest(requestID, reason: reason)
    }

    func disconnected() {
        endpoint.disconnected()
    }

    func setUnsolicitedHIDPPHandler(
        _ handler: (@Sendable (PrecisionTransportInputFrame) -> Void)?
    ) {
        endpoint.setUnsolicitedHIDPPHandler(handler)
    }

    func setDisconnectHandler(_ handler: (@Sendable () -> Void)?) {
        endpoint.setDisconnectHandler(handler)
    }

    var deviceCloseReturn: Int32? { closeAnchor.closeReturn }

    private static func acquire<Manager: AnyObject, Device: AnyObject>(
        calls: PrecisionIOHIDAcquisitionCalls<Manager, Device>,
        retainedOperationLease: MXErgoDeviceOperationLease?
    ) throws -> (
        endpoint: any PrecisionIOHIDAssembledEndpoint,
        closeAnchor: any PrecisionIOHIDCloseResultAnchor
    ) {
        defer { withExtendedLifetime(retainedOperationLease) {} }
        let manager = calls.createManager()
        calls.configureMatching(manager)

        let managerOpenReturn = calls.openManager(manager)
        guard managerOpenReturn == 0 else {
            throw PrecisionIOHIDAcquisitionError.managerOpenFailed(
                managerOpenReturn,
                managerCloseReturn: calls.closeManager(manager)
            )
        }

        guard let devices = calls.copyDevices(manager) else {
            throw PrecisionIOHIDAcquisitionError
                .deviceEnumerationUnavailable(
                    managerCloseReturn: calls.closeManager(manager)
                )
        }
        let matches = devices.filter(calls.matchesExpectedDevice)
        guard matches.count == 1, let device = matches.first else {
            let closeReturn = calls.closeManager(manager)
            if matches.isEmpty {
                throw PrecisionIOHIDAcquisitionError.noMatchingDevice(
                    managerCloseReturn: closeReturn
                )
            }
            throw PrecisionIOHIDAcquisitionError.multipleMatchingDevices(
                count: matches.count,
                managerCloseReturn: closeReturn
            )
        }

        let deviceOpenReturn = calls.openDevice(device)
        guard deviceOpenReturn == 0 else {
            throw PrecisionIOHIDAcquisitionError.deviceOpenFailed(
                deviceOpenReturn,
                managerCloseReturn: calls.closeManager(manager)
            )
        }

        let managerCloseReturn = calls.closeManager(manager)
        guard managerCloseReturn == 0 else {
            throw PrecisionIOHIDAcquisitionError.managerCloseFailed(
                managerCloseReturn,
                deviceCloseReturn: calls.closeDevice(device)
            )
        }

        let closeAnchor = PrecisionIOHIDDirectOpenReleaseAnchor(
            device: device,
            close: calls.closeDevice,
            retainedOperationLease: retainedOperationLease
        )
        do {
            let endpoint = try calls.makeAssembly(device, closeAnchor)
            return (endpoint, closeAnchor)
        } catch {
            closeAnchor.releaseAfterEndpointQuiescence()
            throw PrecisionIOHIDAssemblyRollbackError(
                underlying: error,
                deviceCloseReturn: closeAnchor.closeReturn ?? -1
            )
        }
    }

    fileprivate static func isValidBinding(
        plan: PrecisionTemporaryDiversionPlan,
        binding: PrecisionTransportBinding
    ) -> Bool {
        let session = binding.session
        return plan.device == session.device
            && session.device.vendorID == 0x046D
            && session.device.productID == 0xB01D
            && session.device.transport == "Bluetooth Low Energy"
            && session.device.hasStableDiscriminator
            && session.device.firmwareIdentity?.isEmpty == false
            && session.featureID == ReprogControlsV4.featureID
            && session.featureVersion == 3
            && plan.featureVersion == 3
            && session.featureIndex == plan.featureIndex
            && session.featureIndex != 0
            && session.featureIndex != 0xFF
    }

    private static func matchesExpectedDevice(
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
        guard expected.vendorID == vendorID,
              expected.productID == productID,
              expected.transport == transport,
              expected.serialNumber == serialNumber,
              expected.locationID == locationID,
              expected.deviceID == deviceID,
              expected.hasStableDiscriminator,
              expected.firmwareIdentity?.isEmpty == false,
              let maximumInput = integerProperty(
                kIOHIDMaxInputReportSizeKey,
                from: device
              ),
              maximumInput >= HIDPP20LongMessage.byteCount,
              maximumInput <= 4_096,
              integerProperty(kIOHIDMaxOutputReportSizeKey, from: device)
                == HIDPP20LongMessage.byteCount else {
            return false
        }

        let elements = IOHIDDeviceCopyMatchingElements(
            device,
            nil,
            IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] ?? []
        let outputReportIDs = Set(elements.compactMap { element -> UInt32? in
            guard IOHIDElementGetType(element) == kIOHIDElementTypeOutput
            else { return nil }
            return IOHIDElementGetReportID(element)
        })
        return outputReportIDs == Set([UInt32(HIDPP20LongMessage.reportID)])
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

private protocol PrecisionIOHIDCloseResultAnchor:
    PrecisionIOHIDQuiescentReleaseAnchor {
    var closeReturn: Int32? { get }
}

private final class PrecisionIOHIDDirectOpenReleaseAnchor<Device: AnyObject>:
    PrecisionIOHIDCloseResultAnchor,
    @unchecked Sendable {
    private let lock = NSLock()
    private var device: Device?
    private var retainedOperationLease: MXErgoDeviceOperationLease?
    private let close: (Device) -> Int32
    private var closeReturnStorage: Int32?

    init(
        device: Device,
        close: @escaping (Device) -> Int32,
        retainedOperationLease: MXErgoDeviceOperationLease?
    ) {
        self.device = device
        self.close = close
        self.retainedOperationLease = retainedOperationLease
    }

    deinit {
        releaseAfterEndpointQuiescence()
    }

    var closeReturn: Int32? { lock.withLock { closeReturnStorage } }

    func releaseAfterEndpointQuiescence() {
        let retained = lock.withLock {
            let retainedDevice = device
            device = nil
            let retainedLease = retainedOperationLease
            retainedOperationLease = nil
            return (retainedDevice, retainedLease)
        }
        guard let retainedDevice = retained.0 else { return }
        let result = close(retainedDevice)
        withExtendedLifetime(retained.1) {}
        lock.withLock { closeReturnStorage = result }
    }
}
