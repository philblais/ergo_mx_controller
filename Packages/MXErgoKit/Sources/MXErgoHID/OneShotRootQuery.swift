import Foundation
import MXErgoHIDPP

/// The first hardware-output operation in the read-only discovery session.
///
/// It asks HID++ Root for the runtime index of REPROG_CONTROLS_V4. A successful
/// result can unlock the separately confirmed metadata-enumeration sequence.
/// Neither operation can divert a control or change persistent device state.
public enum MXErgoOneShotRootQuery {
    public static let featureID: UInt16 = 0x1B04
    public static let deviceIndex: UInt8 = 0x00
    public static let softwareID: UInt8 = 0x0E
    public static let timeout: TimeInterval = 1.5

    public static func makeRequest() throws -> HIDPP20LongMessage {
        try HIDPP20Root.getFeatureRequest(
            featureID,
            deviceIndex: deviceIndex,
            softwareID: softwareID
        )
    }
}

public enum MXErgoOneShotRootQueryRejection: Sendable, Equatable {
    case observerNotRunning
    case alreadyAttempted
    case matchingDeviceCount(Int)
    case missingExpectedOutputReport
    case missingStableIdentity
    case requestRegistrationFailed
}

public enum MXErgoOneShotRootQueryResult: Sendable, Equatable {
    case success(
        requestBytes: [UInt8],
        responseBytes: [UInt8],
        descriptor: HIDPP20FeatureDescriptor
    )
    case protocolError(
        requestBytes: [UInt8],
        responseBytes: [UInt8],
        code: UInt8
    )
    case malformedResponse(requestBytes: [UInt8], responseBytes: [UInt8])
    case outputFailed(requestBytes: [UInt8], code: Int32)
    case timedOut(requestBytes: [UInt8])
    case disconnected(requestBytes: [UInt8])
    case observerStopped
    case rejected(MXErgoOneShotRootQueryRejection)
}
