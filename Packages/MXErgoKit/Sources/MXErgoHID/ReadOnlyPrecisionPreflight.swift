import Foundation
import MXErgoCore
import MXErgoHIDPP

public enum MXErgoPrecisionPreflightValidationError: Error, Sendable, Equatable {
    case invalidDeviceIdentity
    case unsupportedFeature
    case invalidBaseline
    case unexpectedResponse
}

/// Assigns a distinct HID++ software ID to each read-only phase so a delayed
/// response from an earlier phase cannot satisfy a later request correlator.
public enum MXErgoPrecisionReadPurpose: Sendable, Equatable {
    case menuPreflight
    case isolatedHelperProbe
    case restartReconciliation

    public var softwareID: UInt8 {
        switch self {
        case .isolatedHelperProbe: 0x0D
        case .menuPreflight: 0x0E
        case .restartReconciliation: 0x0F
        }
    }
}

public struct MXErgoPrecisionPreflightExpectation: Sendable, Equatable {
    public let device: JournalDeviceIdentity
    public let feature: HIDPP20FeatureDescriptor
    public let baseline: DeviceTransactionWireState
    public let purpose: MXErgoPrecisionReadPurpose

    public init(
        device: JournalDeviceIdentity,
        feature: HIDPP20FeatureDescriptor,
        baseline: DeviceTransactionWireState,
        purpose: MXErgoPrecisionReadPurpose = .menuPreflight
    ) throws {
        guard device.vendorID == DeviceIdentity.mxErgo.vendorID,
              device.productID == DeviceIdentity.mxErgo.productID,
              device.transport == "Bluetooth Low Energy",
              device.hasStableDiscriminator,
              device.firmwareIdentity?.isEmpty == false else {
            throw MXErgoPrecisionPreflightValidationError.invalidDeviceIdentity
        }
        guard feature.index != 0,
              feature.index != 0xFF,
              feature.version == 3 else {
            throw MXErgoPrecisionPreflightValidationError.unsupportedFeature
        }
        guard baseline.controlID == MXErgoReadOnlyPrecisionPreflight.controlID,
              baseline.rawFlags(featureVersion: feature.version) == 0,
              baseline.mappedControlID == 0 else {
            throw MXErgoPrecisionPreflightValidationError.invalidBaseline
        }

        self.device = device
        self.feature = feature
        self.baseline = baseline
        self.purpose = purpose
    }
}

public struct MXErgoReadOnlyPrecisionPreflightSnapshot: Sendable, Equatable {
    public let session: RestoreOnlyHardwareTrialSession
    public let requestBytes: [UInt8]
    public let responseBytes: [UInt8]
    public let state: DeviceTransactionWireState

    public init(
        session: RestoreOnlyHardwareTrialSession,
        requestBytes: [UInt8],
        responseBytes: [UInt8],
        state: DeviceTransactionWireState
    ) {
        self.session = session
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.state = state
    }
}

public enum MXErgoReadOnlyPrecisionPreflightRejection: Sendable, Equatable {
    case observerNotRunning
    case alreadyAttempted
    case matchingDeviceCount(Int)
    case missingExpectedOutputReport
    case missingStableIdentity
    case deviceIdentityMismatch
    case featureNotResolvedForCurrentConnection
    case requestRegistrationFailed
}

public enum MXErgoReadOnlyPrecisionPreflightResult: Sendable, Equatable {
    case success(MXErgoReadOnlyPrecisionPreflightSnapshot)
    case baselineMismatch(
        requestBytes: [UInt8],
        responseBytes: [UInt8],
        expected: DeviceTransactionWireState,
        actual: DeviceTransactionWireState,
        session: RestoreOnlyHardwareTrialSession
    )
    case protocolError(requestBytes: [UInt8], responseBytes: [UInt8], code: UInt8)
    case malformedResponse(requestBytes: [UInt8], responseBytes: [UInt8])
    case outputFailed(requestBytes: [UInt8], code: Int32)
    case timedOut(requestBytes: [UInt8])
    case disconnected(requestBytes: [UInt8])
    case observerStopped
    case rejected(MXErgoReadOnlyPrecisionPreflightRejection)
}

public enum MXErgoReadOnlyPrecisionPreflight {
    public static let controlID: UInt16 = 0x00ED
    public static let deviceIndex: UInt8 = 0x00
    public static let maximumPacketCount = 1
    public static let timeout: TimeInterval = 2.0

    public static func makeRequest(
        expectation: MXErgoPrecisionPreflightExpectation
    ) throws -> HIDPP20LongMessage {
        try ReprogControlsV4.getReportingRequest(
            controlID: controlID,
            featureIndex: expectation.feature.index,
            deviceIndex: deviceIndex,
            softwareID: expectation.purpose.softwareID
        )
    }

    public static func decodeResponse(
        _ response: HIDPP20LongMessage,
        expectation: MXErgoPrecisionPreflightExpectation
    ) throws -> DeviceTransactionWireState {
        let reporting = try ReprogControlsV4.decodeReporting(
            requestedControlID: controlID,
            from: response,
            featureIndex: expectation.feature.index,
            featureVersion: expectation.feature.version
        )
        let state = try DeviceTransactionWireState(
            rawParameters: reporting.rawParameters
        )
        guard state.controlID == controlID else {
            throw MXErgoPrecisionPreflightValidationError.unexpectedResponse
        }
        return state
    }

    public static func matchesPhysicalDevice(
        _ properties: HIDDeviceProperties,
        expectation: MXErgoPrecisionPreflightExpectation
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
