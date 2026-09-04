import CryptoKit
import Foundation

public struct PrecisionRunningApplicationSnapshot: Sendable, Equatable, Hashable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let localizedName: String?

    public init(
        processIdentifier: Int32,
        bundleIdentifier: String?,
        localizedName: String?
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
    }
}

public struct PrecisionCompetingProcess: Sendable, Equatable, Hashable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let localizedName: String?

    public init(
        processIdentifier: Int32,
        bundleIdentifier: String?,
        localizedName: String?
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
    }

    public var displayName: String {
        if let localizedName, !localizedName.isEmpty { return localizedName }
        if let bundleIdentifier, !bundleIdentifier.isEmpty { return bundleIdentifier }
        return "PID \(processIdentifier)"
    }
}

public enum PrecisionCompetingProcessClassifier {
    public static func competitors(
        in snapshots: [PrecisionRunningApplicationSnapshot],
        excludingProcessIdentifier: Int32
    ) -> [PrecisionCompetingProcess] {
        let ordered = snapshots.sorted { lhs, rhs in
            if lhs.processIdentifier != rhs.processIdentifier {
                return lhs.processIdentifier < rhs.processIdentifier
            }
            let lhsIdentity = normalized(lhs.bundleIdentifier) + normalized(lhs.localizedName)
            let rhsIdentity = normalized(rhs.bundleIdentifier) + normalized(rhs.localizedName)
            return lhsIdentity < rhsIdentity
        }

        var seenProcessIdentifiers: Set<Int32> = []
        var matches: [PrecisionCompetingProcess] = []
        for snapshot in ordered {
            guard snapshot.processIdentifier != excludingProcessIdentifier,
                  isCompeting(snapshot),
                  seenProcessIdentifiers.insert(snapshot.processIdentifier).inserted else {
                continue
            }
            matches.append(PrecisionCompetingProcess(
                processIdentifier: snapshot.processIdentifier,
                bundleIdentifier: snapshot.bundleIdentifier,
                localizedName: snapshot.localizedName
            ))
        }
        return matches.sorted {
            let lhs = normalized($0.displayName)
            let rhs = normalized($1.displayName)
            if lhs != rhs { return lhs < rhs }
            return $0.processIdentifier < $1.processIdentifier
        }
    }

    private static func isCompeting(
        _ snapshot: PrecisionRunningApplicationSnapshot
    ) -> Bool {
        let bundle = normalized(snapshot.bundleIdentifier)
        let name = normalized(snapshot.localizedName)
        let values = [bundle, name]

        let isBetterTouchTool = values.contains {
            $0.contains("bettertouchtool")
        } || name == "btt" || name.hasPrefix("btthelper")

        let isLogiOptions = values.contains {
            $0.contains("logioptions") || $0.contains("logitechoptions")
        }

        let isMXErgoControllerFamily = bundle.hasPrefix("comphibmxergo")
            || values.contains { value in
                value.contains("mxergocontroller")
                    || value.contains("mxergorestoretrialprobe")
                    || value.contains("mxergoprecisionrestoretrial")
                    || value.contains("mxergoprecisiontrialreconciler")
            }

        return isBetterTouchTool || isLogiOptions || isMXErgoControllerFamily
    }

    private static func normalized(_ value: String?) -> String {
        guard let value else { return "" }
        return String(value.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }
}

public struct PrecisionCompetingProcessScanner: Sendable {
    public typealias SnapshotProvider =
        @Sendable () throws -> [PrecisionRunningApplicationSnapshot]

    private let snapshotProvider: SnapshotProvider

    public init(snapshotProvider: @escaping SnapshotProvider) {
        self.snapshotProvider = snapshotProvider
    }

    public func scan(
        excludingProcessIdentifier: Int32
    ) throws -> [PrecisionCompetingProcess] {
        PrecisionCompetingProcessClassifier.competitors(
            in: try snapshotProvider(),
            excludingProcessIdentifier: excludingProcessIdentifier
        )
    }
}

public enum PrecisionTemporaryDiversionReadinessAuthorization:
    String, Sendable, Equatable {
    case notAuthorizedForExecution
}

public struct PrecisionTemporaryDiversionReadinessInput: Sendable, Equatable {
    public let sourceJournalData: Data
    public let reloadedJournalData: Data
    public let currentSession: DeviceTransactionSession
    public let preflightSession: DeviceTransactionSession
    public let preflightState: DeviceTransactionWireState
    public let currentFeature: HIDPP20FeatureDescriptor
    public let connectionGeneration: UInt64
    public let rootEvidenceGeneration: UInt64
    public let firmwareEvidenceGeneration: UInt64
    public let preflightEvidenceGeneration: UInt64
    public let competitorsBefore: [PrecisionCompetingProcess]
    public let competitorsAfter: [PrecisionCompetingProcess]
    public let deviceIndex: UInt8
    public let softwareID: UInt8

    public init(
        sourceJournalData: Data,
        reloadedJournalData: Data,
        currentSession: DeviceTransactionSession,
        preflightSession: DeviceTransactionSession,
        preflightState: DeviceTransactionWireState,
        currentFeature: HIDPP20FeatureDescriptor,
        connectionGeneration: UInt64,
        rootEvidenceGeneration: UInt64,
        firmwareEvidenceGeneration: UInt64,
        preflightEvidenceGeneration: UInt64,
        competitorsBefore: [PrecisionCompetingProcess],
        competitorsAfter: [PrecisionCompetingProcess],
        deviceIndex: UInt8,
        softwareID: UInt8
    ) {
        self.sourceJournalData = sourceJournalData
        self.reloadedJournalData = reloadedJournalData
        self.currentSession = currentSession
        self.preflightSession = preflightSession
        self.preflightState = preflightState
        self.currentFeature = currentFeature
        self.connectionGeneration = connectionGeneration
        self.rootEvidenceGeneration = rootEvidenceGeneration
        self.firmwareEvidenceGeneration = firmwareEvidenceGeneration
        self.preflightEvidenceGeneration = preflightEvidenceGeneration
        self.competitorsBefore = competitorsBefore
        self.competitorsAfter = competitorsAfter
        self.deviceIndex = deviceIndex
        self.softwareID = softwareID
    }
}

public enum PrecisionTemporaryDiversionReadinessError:
    Error, Sendable, Equatable {
    case competingProcesses([PrecisionCompetingProcess])
    case journalChangedDuringReview
    case journalRequiresRecovery
    case staleConnectionEvidence
    case sessionMismatch
    case featureMismatch
    case precisionPreflightMismatch
    case runtimeJournalChangedDuringReview
    case runtimeJournalNotEligible
}

/// Immutable proof that the app can describe the reviewed Precision lifecycle.
/// This value has no coordinator, repository, transport, or execution method.
public struct PrecisionTemporaryDiversionReadinessSnapshot:
    Sendable, Equatable {
    public let plan: PrecisionTemporaryDiversionPlan
    public let sourceJournalSHA256: String
    public let sourceBaselineTransactionID: UUID
    public let connectionGeneration: UInt64
    public let connectionEpoch: UInt64
    public let authorization: PrecisionTemporaryDiversionReadinessAuthorization

    public init(
        plan: PrecisionTemporaryDiversionPlan,
        sourceJournalSHA256: String,
        sourceBaselineTransactionID: UUID,
        connectionGeneration: UInt64,
        connectionEpoch: UInt64,
        authorization: PrecisionTemporaryDiversionReadinessAuthorization
    ) {
        self.plan = plan
        self.sourceJournalSHA256 = sourceJournalSHA256
        self.sourceBaselineTransactionID = sourceBaselineTransactionID
        self.connectionGeneration = connectionGeneration
        self.connectionEpoch = connectionEpoch
        self.authorization = authorization
    }
}

public enum PrecisionTemporaryDiversionReadinessAudit {
    public static func evaluate(
        _ input: PrecisionTemporaryDiversionReadinessInput
    ) throws -> PrecisionTemporaryDiversionReadinessSnapshot {
        let reviewed = try reviewedPlan(input)
        guard input.preflightState == reviewed.plan.baseline else {
            throw PrecisionTemporaryDiversionReadinessError
                .precisionPreflightMismatch
        }
        try requireNoCompetitorsAfter(input)
        return snapshot(reviewed, input: input)
    }

    /// Review for an explicit recover on a new connection after a
    /// recovery-required shutdown. Live Precision may still be diverted; it
    /// must be the reviewed baseline or active state. No SET is authorized.
    public static func evaluateReconnectRecovery(
        _ input: PrecisionTemporaryDiversionReadinessInput,
        runtimeJournalData: Data,
        reloadedRuntimeJournalData: Data
    ) throws -> PrecisionTemporaryDiversionReadinessSnapshot {
        let reviewed = try reviewedPlan(input)
        guard input.preflightState == reviewed.plan.baseline
                || input.preflightState == reviewed.plan.activeState else {
            throw PrecisionTemporaryDiversionReadinessError
                .precisionPreflightMismatch
        }
        guard runtimeJournalData == reloadedRuntimeJournalData else {
            throw PrecisionTemporaryDiversionReadinessError
                .runtimeJournalChangedDuringReview
        }
        let envelope = try JSONDecoder().decode(
            DeviceTransactionEnvelope.self,
            from: runtimeJournalData
        )
        try envelope.validate()
        guard envelope.isSafeSessionMatch(input.currentSession),
              envelope.device == reviewed.plan.device,
              envelope.featureIndex == reviewed.plan.featureIndex,
              envelope.featureVersion == reviewed.plan.featureVersion,
              try envelope.control(
                PrecisionTemporaryDiversionPlan.controlID
              ).baseline == reviewed.plan.baseline,
              isReconnectRecoveryEligible(envelope) else {
            throw PrecisionTemporaryDiversionReadinessError
                .runtimeJournalNotEligible
        }
        try requireNoCompetitorsAfter(input)
        return snapshot(reviewed, input: input)
    }

    public static func sourceJournalSHA256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private struct ReviewedPlan {
        let journal: DeviceStateJournal
        let plan: PrecisionTemporaryDiversionPlan
    }

    private static func reviewedPlan(
        _ input: PrecisionTemporaryDiversionReadinessInput
    ) throws -> ReviewedPlan {
        guard input.competitorsBefore.isEmpty else {
            throw PrecisionTemporaryDiversionReadinessError
                .competingProcesses(input.competitorsBefore)
        }
        guard input.sourceJournalData == input.reloadedJournalData else {
            throw PrecisionTemporaryDiversionReadinessError
                .journalChangedDuringReview
        }
        guard input.connectionGeneration == input.rootEvidenceGeneration,
              input.connectionGeneration == input.firmwareEvidenceGeneration,
              input.connectionGeneration == input.preflightEvidenceGeneration else {
            throw PrecisionTemporaryDiversionReadinessError.staleConnectionEvidence
        }
        guard input.currentSession == input.preflightSession else {
            throw PrecisionTemporaryDiversionReadinessError.sessionMismatch
        }
        guard input.currentSession.featureID == ReprogControlsV4.featureID,
              input.currentFeature.index == input.currentSession.featureIndex,
              input.currentFeature.version == input.currentSession.featureVersion,
              input.currentFeature.version == 3 else {
            throw PrecisionTemporaryDiversionReadinessError.featureMismatch
        }

        let journal = try JSONDecoder().decode(
            DeviceStateJournal.self,
            from: input.sourceJournalData
        )
        try journal.validateForRecovery()
        guard !journal.requiresRecovery else {
            throw PrecisionTemporaryDiversionReadinessError.journalRequiresRecovery
        }
        guard journal.device.isSafeRecoveryMatch(input.currentSession.device),
              journal.featureID == input.currentSession.featureID,
              journal.feature.index == input.currentSession.featureIndex,
              journal.feature.version == input.currentSession.featureVersion else {
            throw PrecisionTemporaryDiversionReadinessError.sessionMismatch
        }

        let plan = try PrecisionTemporaryDiversionPlan.make(
            journal: journal,
            currentFeature: input.currentFeature,
            deviceIndex: input.deviceIndex,
            softwareID: input.softwareID
        )
        return ReviewedPlan(journal: journal, plan: plan)
    }

    private static func requireNoCompetitorsAfter(
        _ input: PrecisionTemporaryDiversionReadinessInput
    ) throws {
        guard input.competitorsAfter.isEmpty else {
            throw PrecisionTemporaryDiversionReadinessError
                .competingProcesses(input.competitorsAfter)
        }
    }

    private static func snapshot(
        _ reviewed: ReviewedPlan,
        input: PrecisionTemporaryDiversionReadinessInput
    ) -> PrecisionTemporaryDiversionReadinessSnapshot {
        PrecisionTemporaryDiversionReadinessSnapshot(
            plan: reviewed.plan,
            sourceJournalSHA256: sourceJournalSHA256(input.sourceJournalData),
            sourceBaselineTransactionID: reviewed.journal.transactionID,
            connectionGeneration: input.connectionGeneration,
            connectionEpoch: input.currentSession.connectionEpoch,
            authorization: .notAuthorizedForExecution
        )
    }

    private static func isReconnectRecoveryEligible(
        _ envelope: DeviceTransactionEnvelope
    ) -> Bool {
        guard !envelope.controls.contains(where: { $0.phase == .conflicted }),
              envelope.dirtyControlIDs.allSatisfy({
                  $0 == PrecisionTemporaryDiversionPlan.controlID
              }),
              let control = try? envelope.control(
                PrecisionTemporaryDiversionPlan.controlID
              ) else {
            return false
        }
        switch (envelope.status, control.phase) {
        case (.running, .appliedVerified),
             (.recoveryRequired, .applyMayHaveOccurred),
             (.recoveryRequired, .restoreMayHaveOccurred):
            return !envelope.hasAmbiguousRestoreSET
        default:
            return false
        }
    }
}
