import Foundation

public enum DeviceTransactionModelError: Error, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case unstableDeviceIdentity
    case deviceIdentityMismatch
    case featureMismatch
    case emptyControlSet
    case duplicateControlID(UInt16)
    case duplicateControlIndex(UInt8)
    case invalidRawPayloadLength(expected: Int, actual: Int)
    case rawControlMismatch(expected: UInt16, actual: UInt16)
    case baselineIsNotClean(UInt16)
    case invalidPhaseState(UInt16)
    case invalidTransactionStatus
    case duplicateAttemptID(UUID)
    case duplicateAttemptOrdinal(UInt64)
    case missingActiveAttempt(UInt16)
    case invalidRevision(expected: UInt64, actual: UInt64)
    case unknownControlID(UInt16)
    case invalidReducerEvent(UInt16)
    case unsafeIntendedPayload(UInt16)
    case invalidInvocationEvidence(UInt16)
    case transactionConflicted
}

public enum DeviceTransactionInvocationResponseKind: String, Sendable, Codable, Equatable {
    case exactEcho
    case correlatedNonEcho
    case protocolError
    case missing
}

/// Bounded diagnostic evidence returned by a mutation transport. This record
/// never proves device state; only the coordinator's subsequent independent
/// reporting GET may advance an apply or restore phase.
public struct DeviceTransactionInvocationEvidence: Sendable, Codable, Equatable {
    public let attemptID: UUID
    public let requestBytes: [UInt8]
    public let ioReturn: Int32
    public let responseKind: DeviceTransactionInvocationResponseKind
    public let responseBytes: [UInt8]?
    public let connectionEpoch: UInt64

    public init(
        attemptID: UUID,
        requestBytes: [UInt8],
        ioReturn: Int32,
        responseKind: DeviceTransactionInvocationResponseKind,
        responseBytes: [UInt8]?,
        connectionEpoch: UInt64
    ) {
        self.attemptID = attemptID
        self.requestBytes = requestBytes
        self.ioReturn = ioReturn
        self.responseKind = responseKind
        self.responseBytes = responseBytes
        self.connectionEpoch = connectionEpoch
    }

    public func validate(controlID: UInt16, expectedAttemptID: UUID) throws {
        guard attemptID == expectedAttemptID,
              requestBytes.count == HIDPP20LongMessage.byteCount,
              requestBytes.first == HIDPP20LongMessage.reportID,
              responseBytes == nil || responseBytes?.count == HIDPP20LongMessage.byteCount else {
            throw DeviceTransactionModelError.invalidInvocationEvidence(controlID)
        }
        switch responseKind {
        case .exactEcho:
            guard responseBytes == requestBytes else {
                throw DeviceTransactionModelError.invalidInvocationEvidence(controlID)
            }
        case .correlatedNonEcho:
            guard let responseBytes, responseBytes != requestBytes else {
                throw DeviceTransactionModelError.invalidInvocationEvidence(controlID)
            }
        case .protocolError:
            guard responseBytes != nil else {
                throw DeviceTransactionModelError.invalidInvocationEvidence(controlID)
            }
        case .missing:
            guard responseBytes == nil else {
                throw DeviceTransactionModelError.invalidInvocationEvidence(controlID)
            }
        }
    }
}

/// Canonical reporting state for a transaction. Parsed fields are derived from
/// these bytes so persisted recovery evidence cannot disagree with the wire
/// representation that would eventually be read or written.
public struct DeviceTransactionWireState: Sendable, Codable, Equatable {
    public let rawParameters: [UInt8]

    public init(rawParameters: [UInt8]) throws {
        guard rawParameters.count == HIDPP20LongMessage.parameterCount else {
            throw DeviceTransactionModelError.invalidRawPayloadLength(
                expected: HIDPP20LongMessage.parameterCount,
                actual: rawParameters.count
            )
        }
        self.rawParameters = rawParameters
    }

    public var controlID: UInt16 {
        UInt16(rawParameters[0]) << 8 | UInt16(rawParameters[1])
    }

    public var mappedControlID: UInt16 {
        UInt16(rawParameters[3]) << 8 | UInt16(rawParameters[4])
    }

    public func rawFlags(featureVersion: UInt8) -> UInt16 {
        let extensionFlags = featureVersion >= 4 ? UInt16(rawParameters[5]) << 8 : 0
        return UInt16(rawParameters[2]) | extensionFlags
    }

    /// Returns a copy with only the feature-defined reporting-flag bytes
    /// changed. Control identity, mapping, and every reserved byte are retained
    /// verbatim from the canonical read-back payload.
    public func replacingRawFlags(
        _ flags: UInt16,
        featureVersion: UInt8
    ) throws -> DeviceTransactionWireState {
        var replacement = rawParameters
        replacement[2] = UInt8(flags & 0x00FF)
        if featureVersion >= 4 {
            replacement[5] = UInt8(flags >> 8)
        }
        return try DeviceTransactionWireState(rawParameters: replacement)
    }

    /// The current MX Ergo transaction can change reporting flags only. This
    /// comparison fails closed if an intended state changes the control ID,
    /// mapped control, or any reserved/unknown wire byte.
    public func preservesNonFlagBytes(
        of baseline: DeviceTransactionWireState,
        featureVersion: UInt8
    ) -> Bool {
        guard rawParameters.count == baseline.rawParameters.count else {
            return false
        }
        let mutableIndexes: Set<Int> = featureVersion >= 4 ? [2, 5] : [2]
        return rawParameters.indices.allSatisfy { index in
            mutableIndexes.contains(index)
                || rawParameters[index] == baseline.rawParameters[index]
        }
    }

    public func validate(controlID expectedControlID: UInt16) throws {
        guard rawParameters.count == HIDPP20LongMessage.parameterCount else {
            throw DeviceTransactionModelError.invalidRawPayloadLength(
                expected: HIDPP20LongMessage.parameterCount,
                actual: rawParameters.count
            )
        }
        guard controlID == expectedControlID else {
            throw DeviceTransactionModelError.rawControlMismatch(
                expected: expectedControlID,
                actual: controlID
            )
        }
    }
}

public enum DeviceTransactionStatus: String, Sendable, Codable, Equatable {
    case prepared
    case running
    case recoveryRequired
    case abortedClean
    case completed
    case conflicted
}

public enum DeviceTransactionControlPhase: String, Sendable, Codable, Equatable {
    case baselineVerified
    case applyMayHaveOccurred
    case appliedVerified
    case restoreMayHaveOccurred
    case restoredVerified
    case conflicted

    public var requiresRecovery: Bool {
        switch self {
        case .applyMayHaveOccurred, .appliedVerified, .restoreMayHaveOccurred:
            true
        case .baselineVerified, .restoredVerified, .conflicted:
            false
        }
    }
}

public enum DeviceTransactionMutationKind: String, Sendable, Codable, Equatable {
    case apply
    case restore
}

public enum DeviceTransactionAttemptOutcome: String, Sendable, Codable, Equatable {
    case armed
    case rejectedBeforeDispatch
    case outcomeUnknown
    case verified
    case observedNoMutation
    case conflicted
}

public struct DeviceTransactionAttempt: Sendable, Codable, Equatable {
    public let id: UUID
    public let ordinal: UInt64
    public let kind: DeviceTransactionMutationKind
    public let armedAtRevision: UInt64
    public internal(set) var outcome: DeviceTransactionAttemptOutcome
    public internal(set) var detail: String?
    public internal(set) var invocationEvidence: DeviceTransactionInvocationEvidence?

    public init(
        id: UUID,
        ordinal: UInt64,
        kind: DeviceTransactionMutationKind,
        armedAtRevision: UInt64,
        outcome: DeviceTransactionAttemptOutcome = .armed,
        detail: String? = nil,
        invocationEvidence: DeviceTransactionInvocationEvidence? = nil
    ) {
        self.id = id
        self.ordinal = ordinal
        self.kind = kind
        self.armedAtRevision = armedAtRevision
        self.outcome = outcome
        self.detail = detail
        self.invocationEvidence = invocationEvidence
    }
}

public struct DeviceTransactionControl: Sendable, Codable, Equatable {
    public let controlIndex: UInt8
    public let controlID: UInt16
    public let baseline: DeviceTransactionWireState
    public internal(set) var intended: DeviceTransactionWireState?
    public internal(set) var appliedObservation: DeviceTransactionWireState?
    public internal(set) var restoredObservation: DeviceTransactionWireState?
    public internal(set) var conflictingObservation: DeviceTransactionWireState?
    public internal(set) var phase: DeviceTransactionControlPhase
    public internal(set) var attempts: [DeviceTransactionAttempt]
    public internal(set) var activeAttemptID: UUID?
    public internal(set) var conflictReason: String?

    public init(
        controlIndex: UInt8,
        controlID: UInt16,
        baseline: DeviceTransactionWireState
    ) throws {
        try baseline.validate(controlID: controlID)
        self.controlIndex = controlIndex
        self.controlID = controlID
        self.baseline = baseline
        intended = nil
        appliedObservation = nil
        restoredObservation = nil
        conflictingObservation = nil
        phase = .baselineVerified
        attempts = []
        activeAttemptID = nil
        conflictReason = nil
    }
}

public struct DeviceTransactionEnvelope: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let transactionID: UUID
    public let sourceBaselineTransactionID: UUID
    public let device: JournalDeviceIdentity
    public let featureID: UInt16
    public let featureVersion: UInt8
    /// Optional only so existing schema-v3 journals decode. New envelopes bind
    /// the runtime-resolved feature index and old unbound envelopes fail closed
    /// at the session-match gate before any mutation can be invoked.
    public let featureIndex: UInt8?
    public internal(set) var revision: UInt64
    public internal(set) var status: DeviceTransactionStatus
    public internal(set) var controls: [DeviceTransactionControl]
    public let createdAt: Date
    public internal(set) var updatedAt: Date

    public init(
        transactionID: UUID = UUID(),
        baselineJournal: DeviceStateJournal,
        now: Date = Date()
    ) throws {
        try baselineJournal.validateForRecovery()
        guard baselineJournal.device.serialNumber?.isEmpty == false else {
            throw DeviceTransactionModelError.unstableDeviceIdentity
        }

        var transactionControls: [DeviceTransactionControl] = []
        transactionControls.reserveCapacity(baselineJournal.controls.count)
        for entry in baselineJournal.controls {
            guard entry.phase == .baselineVerified,
                  entry.intendedReporting == nil,
                  entry.readBackReporting == nil else {
                throw DeviceTransactionModelError.baselineIsNotClean(
                    entry.controlInfo.controlID
                )
            }
            let rawState = try DeviceTransactionWireState(
                rawParameters: entry.baselineReporting.rawParameters
            )
            guard rawState.rawFlags(featureVersion: baselineJournal.feature.version)
                    == entry.baselineReporting.rawFlags,
                  rawState.mappedControlID == entry.baselineReporting.rawMappedControlID else {
                throw DeviceTransactionModelError.invalidPhaseState(
                    entry.controlInfo.controlID
                )
            }
            transactionControls.append(try DeviceTransactionControl(
                controlIndex: entry.controlInfo.index,
                controlID: entry.controlInfo.controlID,
                baseline: rawState
            ))
        }

        schemaVersion = Self.currentSchemaVersion
        self.transactionID = transactionID
        sourceBaselineTransactionID = baselineJournal.transactionID
        device = baselineJournal.device
        featureID = baselineJournal.featureID
        featureVersion = baselineJournal.feature.version
        featureIndex = baselineJournal.feature.index
        revision = 0
        status = .prepared
        controls = transactionControls.sorted { $0.controlIndex < $1.controlIndex }
        createdAt = now
        updatedAt = now
        try validate()
    }

    public var needsRecoveryAttention: Bool {
        controls.contains { $0.phase.requiresRecovery || $0.phase == .conflicted }
    }

    /// A restore SET whose physical result is unknown must never be retried.
    public var hasAmbiguousRestoreSET: Bool {
        controls.contains { control in
            control.attempts.contains { attempt in
                attempt.kind == .restore && attempt.outcome == .outcomeUnknown
            }
        }
    }

    public var dirtyControlIDs: [UInt16] {
        controls
            .filter { $0.phase.requiresRecovery }
            .sorted { $0.controlIndex < $1.controlIndex }
            .map(\.controlID)
    }

    public func isSafeSessionMatch(_ session: DeviceTransactionSession) -> Bool {
        guard featureID == session.featureID,
              featureVersion == session.featureVersion,
              let featureIndex,
              featureIndex == session.featureIndex,
              let serial = device.serialNumber,
              !serial.isEmpty,
              serial == session.device.serialNumber,
              device.vendorID == session.device.vendorID,
              device.productID == session.device.productID,
              device.transport == session.device.transport,
              device.deviceID == session.device.deviceID,
              device.locationID == session.device.locationID,
              device.firmwareIdentity == session.device.firmwareIdentity else {
            return false
        }
        return true
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DeviceTransactionModelError.unsupportedSchemaVersion(schemaVersion)
        }
        guard device.serialNumber?.isEmpty == false else {
            throw DeviceTransactionModelError.unstableDeviceIdentity
        }
        guard featureID == ReprogControlsV4.featureID else {
            throw DeviceTransactionModelError.featureMismatch
        }
        guard !controls.isEmpty else {
            throw DeviceTransactionModelError.emptyControlSet
        }

        var controlIDs = Set<UInt16>()
        var controlIndexes = Set<UInt8>()
        var attemptIDs = Set<UUID>()
        var attemptOrdinals = Set<UInt64>()

        for control in controls {
            guard controlIDs.insert(control.controlID).inserted else {
                throw DeviceTransactionModelError.duplicateControlID(control.controlID)
            }
            guard controlIndexes.insert(control.controlIndex).inserted else {
                throw DeviceTransactionModelError.duplicateControlIndex(control.controlIndex)
            }
            try control.baseline.validate(controlID: control.controlID)
            try control.intended?.validate(controlID: control.controlID)
            try control.appliedObservation?.validate(controlID: control.controlID)
            try control.restoredObservation?.validate(controlID: control.controlID)
            try control.conflictingObservation?.validate(controlID: control.controlID)

            for attempt in control.attempts {
                guard attemptIDs.insert(attempt.id).inserted else {
                    throw DeviceTransactionModelError.duplicateAttemptID(attempt.id)
                }
                guard attemptOrdinals.insert(attempt.ordinal).inserted else {
                    throw DeviceTransactionModelError.duplicateAttemptOrdinal(attempt.ordinal)
                }
                try attempt.invocationEvidence?.validate(
                    controlID: control.controlID,
                    expectedAttemptID: attempt.id
                )
            }
            try Self.validatePhase(control)
        }

        guard status == Self.derivedStatus(for: controls) else {
            throw DeviceTransactionModelError.invalidTransactionStatus
        }
    }

    public func control(_ controlID: UInt16) throws -> DeviceTransactionControl {
        guard let control = controls.first(where: { $0.controlID == controlID }) else {
            throw DeviceTransactionModelError.unknownControlID(controlID)
        }
        return control
    }

    internal mutating func updateControl(
        _ controlID: UInt16,
        now: Date,
        _ body: (inout DeviceTransactionControl) throws -> Void
    ) throws {
        guard let index = controls.firstIndex(where: { $0.controlID == controlID }) else {
            throw DeviceTransactionModelError.unknownControlID(controlID)
        }
        try body(&controls[index])
        revision = try revision.incremented()
        updatedAt = now
        status = Self.derivedStatus(for: controls)
        try validate()
    }

    internal var nextAttemptOrdinal: UInt64 {
        (controls.flatMap(\.attempts).map(\.ordinal).max() ?? 0) + 1
    }

    private static func validatePhase(_ control: DeviceTransactionControl) throws {
        let activeAttempt = control.activeAttemptID.flatMap { id in
            control.attempts.first(where: { $0.id == id })
        }
        if control.activeAttemptID != nil, activeAttempt == nil {
            throw DeviceTransactionModelError.missingActiveAttempt(control.controlID)
        }

        switch control.phase {
        case .baselineVerified:
            guard control.activeAttemptID == nil,
                  control.conflictReason == nil,
                  control.conflictingObservation == nil else {
                throw DeviceTransactionModelError.invalidPhaseState(control.controlID)
            }
        case .applyMayHaveOccurred:
            guard control.intended != nil,
                  activeAttempt?.kind == .apply,
                  activeAttempt?.outcome == .armed
                    || activeAttempt?.outcome == .rejectedBeforeDispatch
                    || activeAttempt?.outcome == .outcomeUnknown,
                  control.appliedObservation == nil,
                  control.conflictReason == nil else {
                throw DeviceTransactionModelError.invalidPhaseState(control.controlID)
            }
        case .appliedVerified:
            guard let intended = control.intended,
                  control.appliedObservation == intended,
                  control.activeAttemptID == nil,
                  control.conflictReason == nil else {
                throw DeviceTransactionModelError.invalidPhaseState(control.controlID)
            }
        case .restoreMayHaveOccurred:
            guard let intended = control.intended,
                  control.appliedObservation == intended,
                  activeAttempt?.kind == .restore,
                  activeAttempt?.outcome == .armed
                    || activeAttempt?.outcome == .rejectedBeforeDispatch
                    || activeAttempt?.outcome == .outcomeUnknown,
                  control.conflictReason == nil else {
                throw DeviceTransactionModelError.invalidPhaseState(control.controlID)
            }
        case .restoredVerified:
            guard control.intended != nil,
                  control.restoredObservation == control.baseline,
                  control.activeAttemptID == nil,
                  control.conflictReason == nil else {
                throw DeviceTransactionModelError.invalidPhaseState(control.controlID)
            }
        case .conflicted:
            guard control.activeAttemptID == nil,
                  control.conflictReason?.isEmpty == false else {
                throw DeviceTransactionModelError.invalidPhaseState(control.controlID)
            }
        }
    }

    private static func derivedStatus(
        for controls: [DeviceTransactionControl]
    ) -> DeviceTransactionStatus {
        if controls.contains(where: { $0.phase == .conflicted }) {
            return .conflicted
        }
        if controls.contains(where: {
            $0.phase == .applyMayHaveOccurred || $0.phase == .restoreMayHaveOccurred
        }) {
            return .recoveryRequired
        }
        if controls.contains(where: { $0.phase == .appliedVerified }) {
            return .running
        }
        if controls.contains(where: { $0.phase == .restoredVerified }) {
            return .completed
        }
        if controls.contains(where: { $0.intended != nil }) {
            return .abortedClean
        }
        return .prepared
    }
}

public struct DeviceTransactionSession: Sendable, Equatable {
    public let device: JournalDeviceIdentity
    public let featureID: UInt16
    public let featureVersion: UInt8
    public let featureIndex: UInt8
    public let connectionEpoch: UInt64

    public init(
        device: JournalDeviceIdentity,
        featureID: UInt16,
        featureVersion: UInt8,
        featureIndex: UInt8,
        connectionEpoch: UInt64
    ) {
        self.device = device
        self.featureID = featureID
        self.featureVersion = featureVersion
        self.featureIndex = featureIndex
        self.connectionEpoch = connectionEpoch
    }
}

private extension UInt64 {
    func incremented() throws -> UInt64 {
        guard self < .max else {
            throw DeviceTransactionModelError.invalidRevision(
                expected: self,
                actual: self
            )
        }
        return self + 1
    }
}
