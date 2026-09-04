import Foundation
import MXErgoHIDPP

public enum MXErgoControlEnumerationStage: Sendable, Equatable {
    case controlCount
    case controlInfo(index: UInt8)

    public var description: String {
        switch self {
        case .controlCount:
            "control count"
        case let .controlInfo(index):
            "control metadata at index \(index)"
        }
    }
}

public struct MXErgoReadOnlyControlSnapshot: Sendable, Equatable {
    public let feature: HIDPP20FeatureDescriptor
    public let expectedControlCount: Int
    public let controls: [ReprogControlInfo]

    public init(
        feature: HIDPP20FeatureDescriptor,
        expectedControlCount: Int,
        controls: [ReprogControlInfo]
    ) {
        self.feature = feature
        self.expectedControlCount = expectedControlCount
        self.controls = controls
    }
}

public enum MXErgoReadOnlyControlEnumerationRejection: Sendable, Equatable {
    case observerNotRunning
    case alreadyAttempted
    case matchingDeviceCount(Int)
    case missingExpectedOutputReport
    case missingStableIdentity
    case featureNotResolvedForCurrentConnection
    case requestRegistrationFailed
}

public enum MXErgoReadOnlyControlEnumerationResult: Sendable, Equatable {
    case success(MXErgoReadOnlyControlSnapshot)
    case protocolError(
        stage: MXErgoControlEnumerationStage,
        requestBytes: [UInt8],
        responseBytes: [UInt8],
        code: UInt8
    )
    case malformedResponse(
        stage: MXErgoControlEnumerationStage,
        requestBytes: [UInt8],
        responseBytes: [UInt8]
    )
    case outputFailed(
        stage: MXErgoControlEnumerationStage,
        requestBytes: [UInt8],
        code: Int32
    )
    case timedOut(stage: MXErgoControlEnumerationStage, requestBytes: [UInt8])
    case disconnected(stage: MXErgoControlEnumerationStage, requestBytes: [UInt8])
    case observerStopped
    case rejected(MXErgoReadOnlyControlEnumerationRejection)
}
