import Foundation

public enum DeviceStateJournalError: Error, Sendable, Equatable {
    case emptySnapshot
    case incompleteSnapshot(expected: Int, actual: Int)
    case duplicateControlID(UInt16)
    case duplicateControlIndex(UInt8)
    case mismatchedControlID(info: UInt16, reporting: UInt16)
    case invalidFeaturePayloadLength(expected: Int, actual: Int)
    case invalidRawPayloadLength(controlID: UInt16, expected: Int, actual: Int)
    case missingStableDeviceIdentity
    case unexpectedFeatureID(UInt16)
    case unknownControlID(UInt16)
    case intendedStateRequired(UInt16)
    case invalidTransition(
        controlID: UInt16,
        from: DeviceControlJournalPhase,
        to: DeviceControlJournalPhase
    )
    case unsupportedSchemaVersion(Int)
}

/// Write-ahead state for one control. Every `MayHaveOccurred` phase must be
/// saved before the corresponding SET is sent to hardware.
public enum DeviceControlJournalPhase: String, Sendable, Codable, Equatable {
    case baselineVerified
    case applyMayHaveOccurred
    case appliedVerified
    case restoreMayHaveOccurred
    case restoredVerified
    case conflicted

    public var requiresRecovery: Bool {
        switch self {
        case .applyMayHaveOccurred, .appliedVerified, .restoreMayHaveOccurred, .conflicted:
            true
        case .baselineVerified, .restoredVerified:
            false
        }
    }
}

public struct JournalDeviceIdentity: Sendable, Codable, Equatable {
    public let deviceID: String
    public let vendorID: Int
    public let productID: Int
    public let transport: String
    public let serialNumber: String?
    public let locationID: Int?
    public let firmwareIdentity: String?

    public init(
        deviceID: String,
        vendorID: Int,
        productID: Int,
        transport: String,
        serialNumber: String?,
        locationID: Int?,
        firmwareIdentity: String? = nil
    ) {
        self.deviceID = deviceID
        self.vendorID = vendorID
        self.productID = productID
        self.transport = transport
        self.serialNumber = serialNumber
        self.locationID = locationID
        self.firmwareIdentity = firmwareIdentity
    }

    /// Automatic recovery requires a discriminator beyond the shared VID/PID.
    public var hasStableDiscriminator: Bool {
        serialNumber?.isEmpty == false || locationID != nil
    }

    public func isSafeRecoveryMatch(_ candidate: JournalDeviceIdentity) -> Bool {
        guard hasStableDiscriminator,
              candidate.vendorID == vendorID,
              candidate.productID == productID,
              candidate.transport == transport,
              candidate.deviceID == deviceID,
              candidate.locationID == locationID,
              candidate.firmwareIdentity == firmwareIdentity else {
            return false
        }

        if let serialNumber, !serialNumber.isEmpty {
            return candidate.serialNumber == serialNumber
        }
        return candidate.locationID == locationID
    }
}

public struct DeviceControlJournalEntry: Sendable, Codable, Equatable {
    public let controlInfo: ReprogControlInfo
    public let baselineReporting: ReprogControlReportingState
    public private(set) var intendedReporting: ReprogControlReportingState?
    public private(set) var readBackReporting: ReprogControlReportingState?
    public private(set) var phase: DeviceControlJournalPhase
    public private(set) var lastError: String?

    public init(
        controlInfo: ReprogControlInfo,
        baselineReporting: ReprogControlReportingState
    ) throws {
        guard controlInfo.controlID == baselineReporting.controlID else {
            throw DeviceStateJournalError.mismatchedControlID(
                info: controlInfo.controlID,
                reporting: baselineReporting.controlID
            )
        }
        try Self.validateRawPayload(controlID: controlInfo.controlID, controlInfo.rawParameters)
        try Self.validateRawPayload(controlID: controlInfo.controlID, baselineReporting.rawParameters)

        self.controlInfo = controlInfo
        self.baselineReporting = baselineReporting
        intendedReporting = nil
        readBackReporting = nil
        phase = .baselineVerified
        lastError = nil
    }

    fileprivate mutating func transition(
        to nextPhase: DeviceControlJournalPhase,
        intendedReporting: ReprogControlReportingState?,
        readBackReporting: ReprogControlReportingState?,
        lastError: String?
    ) throws {
        guard Self.allowedTransitions[phase, default: []].contains(nextPhase) else {
            throw DeviceStateJournalError.invalidTransition(
                controlID: controlInfo.controlID,
                from: phase,
                to: nextPhase
            )
        }

        if nextPhase == .applyMayHaveOccurred, intendedReporting == nil {
            throw DeviceStateJournalError.intendedStateRequired(controlInfo.controlID)
        }
        if let intendedReporting {
            try Self.validateReportingState(intendedReporting, controlID: controlInfo.controlID)
            self.intendedReporting = intendedReporting
        }
        if let readBackReporting {
            try Self.validateReportingState(readBackReporting, controlID: controlInfo.controlID)
            self.readBackReporting = readBackReporting
        }

        phase = nextPhase
        self.lastError = lastError
    }

    private static func validateReportingState(
        _ state: ReprogControlReportingState,
        controlID: UInt16
    ) throws {
        guard state.controlID == controlID else {
            throw DeviceStateJournalError.mismatchedControlID(
                info: controlID,
                reporting: state.controlID
            )
        }
        try validateRawPayload(controlID: controlID, state.rawParameters)
    }

    private static func validateRawPayload(
        controlID: UInt16,
        _ payload: [UInt8]
    ) throws {
        guard payload.count == HIDPP20LongMessage.parameterCount else {
            throw DeviceStateJournalError.invalidRawPayloadLength(
                controlID: controlID,
                expected: HIDPP20LongMessage.parameterCount,
                actual: payload.count
            )
        }
    }

    private static let allowedTransitions: [DeviceControlJournalPhase: Set<DeviceControlJournalPhase>] = [
        .baselineVerified: [.applyMayHaveOccurred],
        .applyMayHaveOccurred: [.baselineVerified, .appliedVerified, .conflicted],
        .appliedVerified: [.restoreMayHaveOccurred, .conflicted],
        .restoreMayHaveOccurred: [.appliedVerified, .restoredVerified, .conflicted],
        .restoredVerified: [],
        .conflicted: [],
    ]
}

public struct DeviceStateJournal: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let transactionID: UUID
    public let appBuild: String
    public let device: JournalDeviceIdentity
    public let featureID: UInt16
    /// The feature index is connection-local and diagnostic only.
    public let feature: HIDPP20FeatureDescriptor
    public let expectedControlCount: Int
    public private(set) var controls: [DeviceControlJournalEntry]
    public let createdAt: Date
    public private(set) var updatedAt: Date

    public init(
        transactionID: UUID = UUID(),
        appBuild: String,
        device: JournalDeviceIdentity,
        featureID: UInt16 = ReprogControlsV4.featureID,
        feature: HIDPP20FeatureDescriptor,
        expectedControlCount: Int,
        controls: [DeviceControlJournalEntry],
        now: Date = Date()
    ) throws {
        try Self.validateSnapshot(
            device: device,
            featureID: featureID,
            feature: feature,
            expectedControlCount: expectedControlCount,
            controls: controls
        )

        schemaVersion = Self.currentSchemaVersion
        self.transactionID = transactionID
        self.appBuild = appBuild
        self.device = device
        self.featureID = featureID
        self.feature = feature
        self.expectedControlCount = expectedControlCount
        self.controls = controls.sorted { $0.controlInfo.controlID < $1.controlInfo.controlID }
        createdAt = now
        updatedAt = now
    }

    public var requiresRecovery: Bool {
        controls.contains { $0.phase.requiresRecovery }
    }

    public var statusSummary: String {
        if controls.contains(where: { $0.phase == .conflicted }) {
            return "conflicted"
        }
        if requiresRecovery {
            return "recovery required"
        }
        if controls.allSatisfy({ $0.phase == .restoredVerified }) {
            return "restored verified"
        }
        return "baseline verified"
    }

    /// Revalidates every recovery-critical invariant after decoding. Codable's
    /// synthesized initializer bypasses the checked public initializer, so a
    /// journal must pass this method before it can drive any recovery logic.
    public func validateForRecovery() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DeviceStateJournalError.unsupportedSchemaVersion(schemaVersion)
        }
        try Self.validateSnapshot(
            device: device,
            featureID: featureID,
            feature: feature,
            expectedControlCount: expectedControlCount,
            controls: controls
        )
    }

    /// Changes only the durable transaction model. The caller must save this
    /// journal before acting on a `MayHaveOccurred` transition.
    public mutating func transitionControl(
        _ controlID: UInt16,
        to nextPhase: DeviceControlJournalPhase,
        intendedReporting: ReprogControlReportingState? = nil,
        readBackReporting: ReprogControlReportingState? = nil,
        lastError: String? = nil,
        now: Date = Date()
    ) throws {
        guard let index = controls.firstIndex(where: { $0.controlInfo.controlID == controlID }) else {
            throw DeviceStateJournalError.unknownControlID(controlID)
        }
        try controls[index].transition(
            to: nextPhase,
            intendedReporting: intendedReporting,
            readBackReporting: readBackReporting,
            lastError: lastError
        )
        updatedAt = now
    }

    private static func validateSnapshot(
        device: JournalDeviceIdentity,
        featureID: UInt16,
        feature: HIDPP20FeatureDescriptor,
        expectedControlCount: Int,
        controls: [DeviceControlJournalEntry]
    ) throws {
        guard device.hasStableDiscriminator else {
            throw DeviceStateJournalError.missingStableDeviceIdentity
        }
        guard featureID == ReprogControlsV4.featureID else {
            throw DeviceStateJournalError.unexpectedFeatureID(featureID)
        }
        guard !controls.isEmpty else {
            throw DeviceStateJournalError.emptySnapshot
        }
        guard controls.count == expectedControlCount else {
            throw DeviceStateJournalError.incompleteSnapshot(
                expected: expectedControlCount,
                actual: controls.count
            )
        }
        guard feature.rawParameters.count == HIDPP20LongMessage.parameterCount else {
            throw DeviceStateJournalError.invalidFeaturePayloadLength(
                expected: HIDPP20LongMessage.parameterCount,
                actual: feature.rawParameters.count
            )
        }

        var seenControlIDs = Set<UInt16>()
        var seenIndexes = Set<UInt8>()
        for entry in controls {
            let controlID = entry.controlInfo.controlID
            guard seenControlIDs.insert(controlID).inserted else {
                throw DeviceStateJournalError.duplicateControlID(controlID)
            }
            guard seenIndexes.insert(entry.controlInfo.index).inserted else {
                throw DeviceStateJournalError.duplicateControlIndex(entry.controlInfo.index)
            }
            guard controlID == entry.baselineReporting.controlID else {
                throw DeviceStateJournalError.mismatchedControlID(
                    info: controlID,
                    reporting: entry.baselineReporting.controlID
                )
            }
            try validatePayload(entry.controlInfo.rawParameters, controlID: controlID)
            try validatePayload(entry.baselineReporting.rawParameters, controlID: controlID)
            if let intended = entry.intendedReporting {
                guard intended.controlID == controlID else {
                    throw DeviceStateJournalError.mismatchedControlID(
                        info: controlID,
                        reporting: intended.controlID
                    )
                }
                try validatePayload(intended.rawParameters, controlID: controlID)
            }
            if let readBack = entry.readBackReporting {
                guard readBack.controlID == controlID else {
                    throw DeviceStateJournalError.mismatchedControlID(
                        info: controlID,
                        reporting: readBack.controlID
                    )
                }
                try validatePayload(readBack.rawParameters, controlID: controlID)
            }
        }
    }

    private static func validatePayload(_ payload: [UInt8], controlID: UInt16) throws {
        guard payload.count == HIDPP20LongMessage.parameterCount else {
            throw DeviceStateJournalError.invalidRawPayloadLength(
                controlID: controlID,
                expected: HIDPP20LongMessage.parameterCount,
                actual: payload.count
            )
        }
    }
}

public struct DeviceStateJournalStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> DeviceStateJournal? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        let journal = try decoder.decode(DeviceStateJournal.self, from: data)
        try journal.validateForRecovery()
        return journal
    }

    public func save(_ journal: DeviceStateJournal) throws {
        let operationLease = try MXErgoDeviceOperationLease.acquire(beside: fileURL)
        defer { withExtendedLifetime(operationLease) {} }
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: fileURL, options: .atomic)

        // Fail closed if the atomically replaced file cannot be decoded exactly.
        guard try load() == journal else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
