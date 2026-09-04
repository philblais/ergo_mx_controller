import Foundation
import MXErgoHIDPP

public enum MXErgoFirmwareFingerprintDiscovery {
    public static let featureID = HIDPP20DeviceInformation.featureID
    public static let deviceIndex = MXErgoOneShotRootQuery.deviceIndex
    public static let softwareID = MXErgoOneShotRootQuery.softwareID
    public static let timeout = MXErgoOneShotRootQuery.timeout
    public static let maximumPacketCount = 2 + Int(HIDPP20DeviceInformation.maximumEntityCount)

    public static func makeRootRequest() throws -> HIDPP20LongMessage {
        try HIDPP20Root.getFeatureRequest(
            featureID,
            deviceIndex: deviceIndex,
            softwareID: softwareID
        )
    }
}

public enum MXErgoFirmwareFingerprintStage: Sendable, Equatable {
    case featureResolution
    case deviceInformation
    case firmwareEntity(UInt8)

    public var description: String {
        switch self {
        case .featureResolution:
            return "Device Information feature"
        case .deviceInformation:
            return "device information"
        case let .firmwareEntity(index):
            return "firmware entity \(index)"
        }
    }
}

public enum MXErgoFirmwareFingerprintRejection: Sendable, Equatable {
    case observerNotRunning
    case alreadyAttempted
    case matchingDeviceCount(Int)
    case missingExpectedOutputReport
    case missingStableIdentity
    case requestRegistrationFailed
}

public enum MXErgoFirmwareFingerprintResult: Sendable, Equatable {
    case success(HIDPP20FirmwareFingerprint)
    case unsupportedFeature(requestBytes: [UInt8], responseBytes: [UInt8])
    case protocolError(
        stage: MXErgoFirmwareFingerprintStage,
        requestBytes: [UInt8],
        responseBytes: [UInt8],
        code: UInt8
    )
    case malformedResponse(
        stage: MXErgoFirmwareFingerprintStage,
        requestBytes: [UInt8],
        responseBytes: [UInt8]
    )
    case outputFailed(
        stage: MXErgoFirmwareFingerprintStage,
        requestBytes: [UInt8],
        code: Int32
    )
    case timedOut(stage: MXErgoFirmwareFingerprintStage, requestBytes: [UInt8])
    case disconnected(stage: MXErgoFirmwareFingerprintStage, requestBytes: [UInt8])
    case observerStopped
    case rejected(MXErgoFirmwareFingerprintRejection)
}
