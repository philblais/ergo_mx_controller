import Foundation
import MXErgoCore
import MXErgoHIDPP

public enum MXErgoMappedControlPreflightValidationError: Error, Sendable, Equatable {
    case invalidDeviceIdentity
    case unsupportedFeature
    case invalidPlan
}

public struct MXErgoMappedControlPreflightExpectation: Sendable, Equatable {
    public let device: JournalDeviceIdentity
    public let feature: HIDPP20FeatureDescriptor
    public let plan: MappedControlsReadOnlyPreflightPlan

    public init(
        device: JournalDeviceIdentity,
        feature: HIDPP20FeatureDescriptor,
        plan: MappedControlsReadOnlyPreflightPlan
    ) throws {
        guard device.vendorID == DeviceIdentity.mxErgo.vendorID,
              device.productID == DeviceIdentity.mxErgo.productID,
              device.transport == "Bluetooth Low Energy",
              device.hasStableDiscriminator,
              device.firmwareIdentity?.isEmpty == false else {
            throw MXErgoMappedControlPreflightValidationError.invalidDeviceIdentity
        }
        guard feature.index != 0,
              feature.index != 0xFF,
              feature.version == 3,
              feature.index == plan.featureIndex,
              feature.version == plan.featureVersion else {
            throw MXErgoMappedControlPreflightValidationError.unsupportedFeature
        }
        guard plan.authorization == .notAuthorizedForExecution,
              plan.controls.count == MappedControlsReadOnlyPreflightPlan.maximumPacketCount else {
            throw MXErgoMappedControlPreflightValidationError.invalidPlan
        }
        self.device = device
        self.feature = feature
        self.plan = plan
    }
}

public struct MXErgoReadOnlyMappedControlPreflightSnapshot: Sendable, Equatable {
    public let observations: [MappedControlReadOnlyPreflightObservation]
    public let connectionEpoch: UInt64
    public let featureIndex: UInt8
    public let featureVersion: UInt8
    public let authorization: MappedControlReadOnlyPreflightAuthorization
}

public enum MXErgoReadOnlyMappedControlPreflightRejection: Sendable, Equatable {
    case observerNotRunning
    case alreadyAttempted
    case matchingDeviceCount(Int)
    case missingExpectedOutputReport
    case missingStableIdentity
    case deviceIdentityMismatch
    case featureNotResolvedForCurrentConnection
    case requestRegistrationFailed
}

public enum MXErgoReadOnlyMappedControlPreflightResult: Sendable, Equatable {
    case success(MXErgoReadOnlyMappedControlPreflightSnapshot)
    case baselineMismatch(
        controlID: UInt16,
        requestBytes: [UInt8],
        responseBytes: [UInt8],
        expected: DeviceTransactionWireState,
        actual: DeviceTransactionWireState
    )
    case protocolError(
        controlID: UInt16,
        requestBytes: [UInt8],
        responseBytes: [UInt8],
        code: UInt8
    )
    case malformedResponse(
        controlID: UInt16,
        requestBytes: [UInt8],
        responseBytes: [UInt8]
    )
    case outputFailed(controlID: UInt16, requestBytes: [UInt8], code: Int32)
    case timedOut(controlID: UInt16, requestBytes: [UInt8])
    case disconnected(controlID: UInt16, requestBytes: [UInt8])
    case observerStopped
    case rejected(MXErgoReadOnlyMappedControlPreflightRejection)
}

public enum MXErgoReadOnlyMappedControlPreflight {
    public static let maximumPacketCount = MappedControlsReadOnlyPreflightPlan.maximumPacketCount
    public static let timeout: TimeInterval = 2.0

    public static func matchesPhysicalDevice(
        _ properties: HIDDeviceProperties,
        expectation: MXErgoMappedControlPreflightExpectation
    ) -> Bool {
        let expected = expectation.device
        guard properties.id == expected.deviceID,
              properties.vendorID == expected.vendorID,
              properties.productID == expected.productID,
              properties.transport == expected.transport,
              properties.locationID == expected.locationID else {
            return false
        }
        if let serial = expected.serialNumber, !serial.isEmpty {
            return properties.serialNumber == serial
        }
        return properties.locationID == expected.locationID
    }
}
