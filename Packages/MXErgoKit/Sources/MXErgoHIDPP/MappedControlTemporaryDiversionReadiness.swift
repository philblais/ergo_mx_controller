import CryptoKit
import Foundation

public enum MappedControlsTemporaryDiversionReadinessAuthorization:
    String, Sendable, Equatable {
    case notAuthorizedForExecution
}

public struct MappedControlsTemporaryDiversionReadinessInput: Sendable, Equatable {
    public let sourceJournalData: Data
    public let reloadedJournalData: Data
    public let currentSession: DeviceTransactionSession
    public let currentFeature: HIDPP20FeatureDescriptor
    public let connectionGeneration: UInt64
    public let rootEvidenceGeneration: UInt64
    public let firmwareEvidenceGeneration: UInt64
    public let competitorsBefore: [PrecisionCompetingProcess]
    public let competitorsAfter: [PrecisionCompetingProcess]
    public let deviceIndex: UInt8
    public let softwareID: UInt8

    public init(
        sourceJournalData: Data,
        reloadedJournalData: Data,
        currentSession: DeviceTransactionSession,
        currentFeature: HIDPP20FeatureDescriptor,
        connectionGeneration: UInt64,
        rootEvidenceGeneration: UInt64,
        firmwareEvidenceGeneration: UInt64,
        competitorsBefore: [PrecisionCompetingProcess],
        competitorsAfter: [PrecisionCompetingProcess],
        deviceIndex: UInt8,
        softwareID: UInt8
    ) {
        self.sourceJournalData = sourceJournalData
        self.reloadedJournalData = reloadedJournalData
        self.currentSession = currentSession
        self.currentFeature = currentFeature
        self.connectionGeneration = connectionGeneration
        self.rootEvidenceGeneration = rootEvidenceGeneration
        self.firmwareEvidenceGeneration = firmwareEvidenceGeneration
        self.competitorsBefore = competitorsBefore
        self.competitorsAfter = competitorsAfter
        self.deviceIndex = deviceIndex
        self.softwareID = softwareID
    }
}

public enum MappedControlsTemporaryDiversionReadinessError:
    Error, Sendable, Equatable {
    case competingProcesses([PrecisionCompetingProcess])
    case journalChangedDuringReview
    case journalRequiresRecovery
    case staleConnectionEvidence
    case sessionMismatch
    case featureMismatch
}

/// Immutable proof that the app can describe the five mapped-control
/// temporary-diversion packets. This value has no coordinator, repository,
/// transport, SET authorization, or event-synthesis method.
public struct MappedControlsTemporaryDiversionReadinessSnapshot:
    Sendable, Equatable {
    public let plan: MappedControlsTemporaryDiversionPlan
    public let sourceJournalSHA256: String
    public let sourceBaselineTransactionID: UUID
    public let connectionGeneration: UInt64
    public let connectionEpoch: UInt64
    public let authorization: MappedControlsTemporaryDiversionReadinessAuthorization

    public init(
        plan: MappedControlsTemporaryDiversionPlan,
        sourceJournalSHA256: String,
        sourceBaselineTransactionID: UUID,
        connectionGeneration: UInt64,
        connectionEpoch: UInt64,
        authorization: MappedControlsTemporaryDiversionReadinessAuthorization
    ) {
        self.plan = plan
        self.sourceJournalSHA256 = sourceJournalSHA256
        self.sourceBaselineTransactionID = sourceBaselineTransactionID
        self.connectionGeneration = connectionGeneration
        self.connectionEpoch = connectionEpoch
        self.authorization = authorization
    }
}

public enum MappedControlsTemporaryDiversionReadinessAudit {
    public static func evaluate(
        _ input: MappedControlsTemporaryDiversionReadinessInput
    ) throws -> MappedControlsTemporaryDiversionReadinessSnapshot {
        guard input.competitorsBefore.isEmpty else {
            throw MappedControlsTemporaryDiversionReadinessError
                .competingProcesses(input.competitorsBefore)
        }
        guard input.sourceJournalData == input.reloadedJournalData else {
            throw MappedControlsTemporaryDiversionReadinessError
                .journalChangedDuringReview
        }
        guard input.connectionGeneration == input.rootEvidenceGeneration,
              input.connectionGeneration == input.firmwareEvidenceGeneration else {
            throw MappedControlsTemporaryDiversionReadinessError.staleConnectionEvidence
        }
        guard input.currentSession.featureID == ReprogControlsV4.featureID,
              input.currentFeature.index == input.currentSession.featureIndex,
              input.currentFeature.version == input.currentSession.featureVersion,
              input.currentFeature.version == 3 else {
            throw MappedControlsTemporaryDiversionReadinessError.featureMismatch
        }

        let journal = try JSONDecoder().decode(
            DeviceStateJournal.self,
            from: input.sourceJournalData
        )
        try journal.validateForRecovery()
        guard !journal.requiresRecovery else {
            throw MappedControlsTemporaryDiversionReadinessError.journalRequiresRecovery
        }
        guard journal.device.isSafeRecoveryMatch(input.currentSession.device),
              journal.featureID == input.currentSession.featureID,
              journal.feature.index == input.currentSession.featureIndex,
              journal.feature.version == input.currentSession.featureVersion else {
            throw MappedControlsTemporaryDiversionReadinessError.sessionMismatch
        }

        let plan = try MappedControlsTemporaryDiversionPlan.make(
            journal: journal,
            currentFeature: input.currentFeature,
            deviceIndex: input.deviceIndex,
            softwareID: input.softwareID
        )
        guard input.competitorsAfter.isEmpty else {
            throw MappedControlsTemporaryDiversionReadinessError
                .competingProcesses(input.competitorsAfter)
        }
        return MappedControlsTemporaryDiversionReadinessSnapshot(
            plan: plan,
            sourceJournalSHA256: sourceJournalSHA256(input.sourceJournalData),
            sourceBaselineTransactionID: journal.transactionID,
            connectionGeneration: input.connectionGeneration,
            connectionEpoch: input.currentSession.connectionEpoch,
            authorization: .notAuthorizedForExecution
        )
    }

    public static func sourceJournalSHA256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
