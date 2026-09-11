import Foundation

public enum PrecisionTemporaryDiversionError: Error, Sendable, Equatable {
    case unsupportedDevice
    case unstableRecoveryIdentity
    case journalRequiresRecovery
    case featureMismatch
    case unsupportedFeatureVersion(UInt8)
    case precisionControlMissing
    case precisionControlNotEligible
    case precisionBaselineNotClean
    case invalidMutation
    case unexpectedLifecyclePhase(DeviceTransactionControlPhase)
    case unrelatedDirtyControls([UInt16])
}

/// Pure, byte-exact description of the only temporary-diversion lifecycle this
/// app intends to own. Constructing or using a plan performs no HID I/O.
public struct PrecisionTemporaryDiversionPlan: Sendable, Equatable {
    public static let controlID: UInt16 = 0x00ED

    public let controlIndex: UInt8
    public let baseline: DeviceTransactionWireState
    public let activeState: DeviceTransactionWireState
    public let applySetRequest: HIDPP20LongMessage
    public let restoreSetRequest: HIDPP20LongMessage
    public let verificationRequest: HIDPP20LongMessage
    public let device: JournalDeviceIdentity
    public let featureIndex: UInt8
    public let featureVersion: UInt8

    public static func make(
        journal: DeviceStateJournal,
        currentFeature: HIDPP20FeatureDescriptor,
        deviceIndex: UInt8,
        softwareID: UInt8
    ) throws -> PrecisionTemporaryDiversionPlan {
        try journal.validateForRecovery()
        guard !journal.requiresRecovery else {
            throw PrecisionTemporaryDiversionError.journalRequiresRecovery
        }
        guard journal.device.vendorID == 0x046D,
              journal.device.productID == 0xB01D,
              journal.device.transport == "Bluetooth Low Energy" else {
            throw PrecisionTemporaryDiversionError.unsupportedDevice
        }
        guard journal.device.serialNumber?.isEmpty == false,
              journal.device.locationID != nil,
              journal.device.firmwareIdentity?.isEmpty == false else {
            throw PrecisionTemporaryDiversionError.unstableRecoveryIdentity
        }
        guard currentFeature.index != 0,
              currentFeature.index != 0xFF,
              journal.feature.index == currentFeature.index,
              journal.feature.version == currentFeature.version else {
            throw PrecisionTemporaryDiversionError.featureMismatch
        }
        guard currentFeature.version == 3 else {
            throw PrecisionTemporaryDiversionError.unsupportedFeatureVersion(
                currentFeature.version
            )
        }
        guard let entry = journal.controls.first(where: {
            $0.controlInfo.controlID == controlID
        }) else {
            throw PrecisionTemporaryDiversionError.precisionControlMissing
        }

        let capabilities = entry.controlInfo.capabilityFlags
        let isPhysical = capabilities & 0x80 == 0
        let isReprogrammable = capabilities & 0x10 != 0
        let isDivertable = capabilities & 0x20 != 0
        guard isPhysical, isReprogrammable, isDivertable else {
            throw PrecisionTemporaryDiversionError.precisionControlNotEligible
        }

        let baseline = try DeviceTransactionWireState(
            rawParameters: entry.baselineReporting.rawParameters
        )
        guard entry.phase == .baselineVerified,
              entry.intendedReporting == nil,
              entry.readBackReporting == nil,
              baseline.controlID == controlID,
              baseline.rawFlags(featureVersion: 3) == 0,
              baseline.mappedControlID == 0,
              baseline.rawParameters.dropFirst(5).allSatisfy({ $0 == 0 }) else {
            throw PrecisionTemporaryDiversionError.precisionBaselineNotClean
        }

        let active = try baseline.replacingRawFlags(0x01, featureVersion: 3)
        let apply = try HIDPP20LongMessage(
            deviceIndex: deviceIndex,
            featureIndex: currentFeature.index,
            functionID: 3,
            softwareID: softwareID,
            parameters: [0x00, 0xED, 0x03, 0x00, 0x00]
        )
        let restore = try HIDPP20LongMessage(
            deviceIndex: deviceIndex,
            featureIndex: currentFeature.index,
            functionID: 3,
            softwareID: softwareID,
            parameters: [0x00, 0xED, 0x02, 0x00, 0x00]
        )
        let verification = try ReprogControlsV4.getReportingRequest(
            controlID: controlID,
            featureIndex: currentFeature.index,
            deviceIndex: deviceIndex,
            softwareID: softwareID
        )
        return PrecisionTemporaryDiversionPlan(
            controlIndex: entry.controlInfo.index,
            baseline: baseline,
            activeState: active,
            applySetRequest: apply,
            restoreSetRequest: restore,
            verificationRequest: verification,
            device: journal.device,
            featureIndex: currentFeature.index,
            featureVersion: currentFeature.version
        )
    }

    /// Projects a durable coordinator mutation into the one allowed SET. The
    /// mutation state is the authoritative state expected from the later GET,
    /// not the command-validity flags placed on the SET wire packet.
    public func request(for mutation: DeviceTransactionMutation) throws -> HIDPP20LongMessage {
        guard mutation.controlID == Self.controlID else {
            throw PrecisionTemporaryDiversionError.invalidMutation
        }
        switch mutation.kind {
        case .apply:
            guard mutation.state == activeState else {
                throw PrecisionTemporaryDiversionError.invalidMutation
            }
            return applySetRequest
        case .restore:
            guard mutation.state == baseline else {
                throw PrecisionTemporaryDiversionError.invalidMutation
            }
            return restoreSetRequest
        }
    }

    /// Retains a correlated SET response without treating its shape as proof
    /// of applied state. Only a separate verification GET may do that.
    public func invocationEvidence(
        for mutation: DeviceTransactionMutation,
        responseBytes: [UInt8]?,
        ioReturn: Int32,
        connectionEpoch: UInt64
    ) throws -> DeviceTransactionInvocationEvidence {
        let request = try request(for: mutation).bytes
        let kind: DeviceTransactionInvocationResponseKind
        if let responseBytes {
            guard responseBytes.count == HIDPP20LongMessage.byteCount else {
                throw PrecisionTemporaryDiversionError.invalidMutation
            }
            kind = responseBytes == request ? .exactEcho : .correlatedNonEcho
        } else {
            kind = .missing
        }
        let evidence = DeviceTransactionInvocationEvidence(
            attemptID: mutation.attemptID,
            requestBytes: request,
            ioReturn: ioReturn,
            responseKind: kind,
            responseBytes: responseBytes,
            connectionEpoch: connectionEpoch
        )
        try evidence.validate(
            controlID: mutation.controlID,
            expectedAttemptID: mutation.attemptID
        )
        return evidence
    }
}

public enum PrecisionTemporaryDiversionLifecycleState: Sendable, Equatable {
    case inactive
    case active
    case restored
    case recoveryRequired
    case conflicted
}

public enum PrecisionTemporaryDiversionOperation: String, Sendable, Equatable {
    case activate
    case deactivate
    case recover
    case resume
}

public enum PrecisionTemporaryDiversionSafetyGateError: Error, Sendable, Equatable {
    case competingProcesses([String])
    case deviceOperationLeaseUnavailable
}

public protocol PrecisionTemporaryDiversionSafetyLease: AnyObject, Sendable {
    /// Rechecks external exclusion while the operation-wide lease is still
    /// alive. A failed post-dispatch check never authorizes a retry or an
    /// automatic inverse mutation.
    func validate() throws
}

public protocol PrecisionTemporaryDiversionSafetyGate: Sendable {
    func acquire(
        for operation: PrecisionTemporaryDiversionOperation
    ) async throws -> any PrecisionTemporaryDiversionSafetyLease
}

/// Concrete operation guard for future transport integration. The injected
/// process probe keeps AppKit/process enumeration outside the protocol library,
/// while the canonical file lease excludes every cooperating MX Ergo process.
public struct PrecisionTemporaryDiversionDeviceSafetyGate: Sendable {
    public typealias CompetitorProbe = @Sendable () throws -> [String]

    private let journalURL: URL
    private let competitorProbe: CompetitorProbe

    public init(
        journalURL: URL,
        competitorProbe: @escaping CompetitorProbe
    ) {
        self.journalURL = journalURL
        self.competitorProbe = competitorProbe
    }
}

extension PrecisionTemporaryDiversionDeviceSafetyGate:
    PrecisionTemporaryDiversionSafetyGate {
    public func acquire(
        for operation: PrecisionTemporaryDiversionOperation
    ) async throws -> any PrecisionTemporaryDiversionSafetyLease {
        _ = operation
        try Self.requireNoCompetitors(competitorProbe)
        let deviceLease: MXErgoDeviceOperationLease
        do {
            deviceLease = try MXErgoDeviceOperationLease.acquire(beside: journalURL)
        } catch MXErgoDeviceOperationLeaseError.unavailable {
            throw PrecisionTemporaryDiversionSafetyGateError
                .deviceOperationLeaseUnavailable
        }
        let lease = PrecisionTemporaryDiversionDeviceSafetyLease(
            deviceLease: deviceLease,
            competitorProbe: competitorProbe
        )
        try lease.validate()
        return lease
    }

    fileprivate static func requireNoCompetitors(
        _ probe: CompetitorProbe
    ) throws {
        let names = try probe()
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted()
        guard names.isEmpty else {
            throw PrecisionTemporaryDiversionSafetyGateError
                .competingProcesses(names)
        }
    }
}

private final class PrecisionTemporaryDiversionDeviceSafetyLease:
    PrecisionTemporaryDiversionSafetyLease, @unchecked Sendable {
    private let deviceLease: MXErgoDeviceOperationLease
    private let competitorProbe:
        PrecisionTemporaryDiversionDeviceSafetyGate.CompetitorProbe

    init(
        deviceLease: MXErgoDeviceOperationLease,
        competitorProbe: @escaping
            PrecisionTemporaryDiversionDeviceSafetyGate.CompetitorProbe
    ) {
        self.deviceLease = deviceLease
        self.competitorProbe = competitorProbe
    }

    func validate() throws {
        withExtendedLifetime(deviceLease) {}
        try PrecisionTemporaryDiversionDeviceSafetyGate
            .requireNoCompetitors(competitorProbe)
    }
}

/// Thin Precision-only facade over the general durable transaction
/// coordinator. It owns no second state machine and has no HID transport.
public actor PrecisionTemporaryDiversionLifecycle {
    private let coordinator: DeviceTransactionCoordinator
    private let safetyGate: any PrecisionTemporaryDiversionSafetyGate
    public let plan: PrecisionTemporaryDiversionPlan

    public init(
        coordinator: DeviceTransactionCoordinator,
        plan: PrecisionTemporaryDiversionPlan,
        safetyGate: any PrecisionTemporaryDiversionSafetyGate
    ) {
        self.coordinator = coordinator
        self.plan = plan
        self.safetyGate = safetyGate
    }

    public func state() async throws -> PrecisionTemporaryDiversionLifecycleState {
        let envelope = try await requiredEnvelope()
        return try derivedState(from: envelope)
    }

    public func activate() async throws -> DeviceTransactionEnvelope {
        let safetyLease = try await safetyGate.acquire(for: .activate)
        try safetyLease.validate()
        defer { withExtendedLifetime(safetyLease) {} }
        let envelope = try await requiredEnvelope()
        let control = try envelope.control(PrecisionTemporaryDiversionPlan.controlID)
        guard control.phase == .baselineVerified else {
            throw PrecisionTemporaryDiversionError.unexpectedLifecyclePhase(control.phase)
        }
        let result = try await coordinator.apply(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            intended: plan.activeState
        )
        try safetyLease.validate()
        return result
    }

    public func deactivate() async throws -> DeviceTransactionEnvelope {
        let safetyLease = try await safetyGate.acquire(for: .deactivate)
        try safetyLease.validate()
        defer { withExtendedLifetime(safetyLease) {} }
        let envelope = try await requiredEnvelope()
        let control = try envelope.control(PrecisionTemporaryDiversionPlan.controlID)
        guard control.phase == .appliedVerified else {
            throw PrecisionTemporaryDiversionError.unexpectedLifecyclePhase(control.phase)
        }
        let result = try await coordinator.restore(
            controlID: PrecisionTemporaryDiversionPlan.controlID
        )
        try safetyLease.validate()
        return result
    }

    public func resumeVerified() async throws -> DeviceTransactionEnvelope {
        let safetyLease = try await safetyGate.acquire(for: .resume)
        try safetyLease.validate()
        defer { withExtendedLifetime(safetyLease) {} }
        let envelope = try await requiredEnvelope()
        guard try envelope.control(PrecisionTemporaryDiversionPlan.controlID).intended
                == plan.activeState else {
            throw PrecisionTemporaryDiversionError.featureMismatch
        }
        let result = try await coordinator.resumeVerified(
            controlID: PrecisionTemporaryDiversionPlan.controlID
        )
        try safetyLease.validate()
        return result
    }

    public func recoverExplicitly() async throws -> DeviceTransactionRecoveryReport {
        let safetyLease = try await safetyGate.acquire(for: .recover)
        try safetyLease.validate()
        defer { withExtendedLifetime(safetyLease) {} }
        _ = try await requiredEnvelope()
        let report = try await coordinator.recoverExplicitly()
        try safetyLease.validate()
        return report
    }

    private func requiredEnvelope() async throws -> DeviceTransactionEnvelope {
        guard let envelope = try await coordinator.currentEnvelope() else {
            throw DeviceTransactionCoordinatorError.missingTransactionJournal
        }
        guard envelope.device == plan.device,
              envelope.featureVersion == plan.featureVersion,
              envelope.featureIndex == plan.featureIndex,
              try envelope.control(PrecisionTemporaryDiversionPlan.controlID).baseline
                == plan.baseline else {
            throw PrecisionTemporaryDiversionError.featureMismatch
        }
        let unrelated = envelope.dirtyControlIDs.filter {
            $0 != PrecisionTemporaryDiversionPlan.controlID
        }
        guard unrelated.isEmpty else {
            throw PrecisionTemporaryDiversionError.unrelatedDirtyControls(unrelated)
        }
        return envelope
    }

    private func derivedState(
        from envelope: DeviceTransactionEnvelope
    ) throws -> PrecisionTemporaryDiversionLifecycleState {
        let control = try envelope.control(PrecisionTemporaryDiversionPlan.controlID)
        switch control.phase {
        case .baselineVerified: return .inactive
        case .appliedVerified: return .active
        case .restoredVerified: return .restored
        case .applyMayHaveOccurred, .restoreMayHaveOccurred: return .recoveryRequired
        case .conflicted: return .conflicted
        }
    }
}
