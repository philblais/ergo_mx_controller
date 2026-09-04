import Foundation
import MXErgoHIDPP

public struct MXErgoReportingSnapshotStage: Sendable, Equatable {
    public let index: UInt8
    public let controlID: UInt16

    public init(index: UInt8, controlID: UInt16) {
        self.index = index
        self.controlID = controlID
    }

    public var description: String {
        String(format: "reporting state for CID 0x%04X at index %d", controlID, index)
    }
}

public struct MXErgoReadOnlyReportingSnapshot: Sendable, Equatable {
    public let feature: HIDPP20FeatureDescriptor
    public let expectedControlCount: Int
    public let controls: [DeviceControlJournalEntry]

    public init(
        feature: HIDPP20FeatureDescriptor,
        expectedControlCount: Int,
        controls: [DeviceControlJournalEntry]
    ) {
        self.feature = feature
        self.expectedControlCount = expectedControlCount
        self.controls = controls
    }
}

public enum MXErgoReadOnlyReportingSnapshotRejection: Sendable, Equatable {
    case observerNotRunning
    case alreadyAttempted
    case matchingDeviceCount(Int)
    case missingExpectedOutputReport
    case missingStableIdentity
    case metadataNotEnumeratedForCurrentConnection
    case requestRegistrationFailed
}

public enum MXErgoReadOnlyReportingSnapshotResult: Sendable, Equatable {
    case success(MXErgoReadOnlyReportingSnapshot)
    case protocolError(
        stage: MXErgoReportingSnapshotStage,
        requestBytes: [UInt8],
        responseBytes: [UInt8],
        code: UInt8
    )
    case malformedResponse(
        stage: MXErgoReportingSnapshotStage,
        requestBytes: [UInt8],
        responseBytes: [UInt8]
    )
    case outputFailed(
        stage: MXErgoReportingSnapshotStage,
        requestBytes: [UInt8],
        code: Int32
    )
    case timedOut(stage: MXErgoReportingSnapshotStage, requestBytes: [UInt8])
    case disconnected(stage: MXErgoReportingSnapshotStage, requestBytes: [UInt8])
    case observerStopped
    case rejected(MXErgoReadOnlyReportingSnapshotRejection)
}
