import CryptoKit
import Foundation
import MXErgoHIDPP

enum PrecisionForensicEvidenceError: Error, Sendable, Equatable {
    case missingOrNonRegularFile(String)
    case hashMismatch(String)
    case invalidJSON(String)
    case invalidLiveBaseline
    case invalidTrial
    case invalidProbe
    case invalidReconciliation
    case invalidTimestampOrder
}

struct PrecisionForensicEvidenceLocations: Sendable, Equatable {
    let liveJournal: URL
    let backupJournal: URL
    let probeResult: URL
    let trialJournal: URL
    let reconciliationResult: URL

    init(directory: URL) {
        liveJournal = directory.appendingPathComponent("device-state-journal.json")
        backupJournal = directory.appendingPathComponent(
            "device-state-journal.pre-firmware-identity.json"
        )
        probeResult = directory.appendingPathComponent(
            "restore-trial-probe-result.json"
        )
        trialJournal = directory.appendingPathComponent(
            "restore-only-precision-trial.json"
        )
        reconciliationResult = directory.appendingPathComponent(
            "restore-only-precision-reconciliation-result.json"
        )
    }
}

struct PrecisionForensicEvidenceProfile: Sendable, Equatable {
    let liveJournalSHA256: String
    let backupJournalSHA256: String
    let probeResultSHA256: String
    let reconciledTrialSHA256: String
    let reconciliationResultSHA256: String
    let preReconciliationTrialSHA256: String
    let sourceTransactionID: UUID
    let trialTransactionID: UUID
    let attemptID: UUID

    static let preservedAugust2026 = PrecisionForensicEvidenceProfile(
        liveJournalSHA256:
            "60ab614927d20871994ad0ebe7368158af9a26b2c1d60f7a2ab3c51635f77097",
        backupJournalSHA256:
            "4ef802eb1185c56f24b7635324113ab414f2acca499a4addc4e4117cd3cdf3aa",
        probeResultSHA256:
            "7887950ec9602a21ff1d030310b0cb52b78a02e9a495f58bd7396922436c5460",
        reconciledTrialSHA256:
            "1efee23b585baac98ad2a6a888bbf741d88674fb71479640a332cf2c4cba66ac",
        reconciliationResultSHA256:
            "f208abe8cf1e2b5ac31c67c0eaf6649f8f1369f1238f2cab40631896647c6593",
        preReconciliationTrialSHA256:
            "03fda6abd3fe720ebdde0eed5dd35c2b1d428e1e237954e22a9f99eee0971468",
        sourceTransactionID: UUID(
            uuidString: "75465823-37D5-4685-A6C8-398A9B0D72F1"
        )!,
        trialTransactionID: UUID(
            uuidString: "96BEAE07-7727-4D1E-8439-48AB574CBD81"
        )!,
        attemptID: UUID(
            uuidString: "C7D0303B-F065-4812-8EE8-87581C5C1191"
        )!
    )
}

struct PrecisionForensicEvidenceReport: Sendable, Equatable {
    let sourceTransactionID: UUID
    let trialTransactionID: UUID
    let attemptID: UUID
    let observation: [UInt8]
    let probeCompletedAt: Date
    let reconciliationCompletedAt: Date
}

enum PrecisionForensicEvidenceAudit {
    private struct ProbeResult: Decodable {
        let schemaVersion: Int
        let succeeded: Bool
        let completedAt: Date
        let journalSHA256Before: String?
        let journalSHA256After: String?
        let backupSHA256Before: String?
        let backupSHA256After: String?
        let precisionRequest: [UInt8]?
        let precisionResponse: [UInt8]?
        let connectionEpoch: UInt64?
    }

    private struct ReconciliationResult: Decodable {
        let schemaVersion: Int
        let succeeded: Bool
        let completedAt: Date
        let transactionID: UUID?
        let attemptID: UUID?
        let finalPhase: String?
        let finalRevision: UInt64?
        let observation: [UInt8]?
        let probeResultSHA256: String?
        let trialJournalSHA256Before: String?
        let trialJournalSHA256After: String?
        let liveJournalSHA256Before: String?
        let liveJournalSHA256After: String?
        let backupSHA256Before: String?
        let backupSHA256After: String?
    }

    static func audit(
        locations: PrecisionForensicEvidenceLocations,
        profile: PrecisionForensicEvidenceProfile
    ) throws -> PrecisionForensicEvidenceReport {
        let liveData = try readRegularFile(locations.liveJournal)
        let backupData = try readRegularFile(locations.backupJournal)
        let probeData = try readRegularFile(locations.probeResult)
        let trialData = try readRegularFile(locations.trialJournal)
        let reconciliationData = try readRegularFile(
            locations.reconciliationResult
        )

        try requireHash(
            liveData,
            profile.liveJournalSHA256,
            name: locations.liveJournal.lastPathComponent
        )
        try requireHash(
            backupData,
            profile.backupJournalSHA256,
            name: locations.backupJournal.lastPathComponent
        )
        try requireHash(
            probeData,
            profile.probeResultSHA256,
            name: locations.probeResult.lastPathComponent
        )
        try requireHash(
            trialData,
            profile.reconciledTrialSHA256,
            name: locations.trialJournal.lastPathComponent
        )
        try requireHash(
            reconciliationData,
            profile.reconciliationResultSHA256,
            name: locations.reconciliationResult.lastPathComponent
        )

        let live: DeviceStateJournal
        let trial: RestoreOnlyHardwareTrialRecord
        let probe: ProbeResult
        let reconciliation: ReconciliationResult
        do {
            live = try JSONDecoder().decode(DeviceStateJournal.self, from: liveData)
            trial = try JSONDecoder().decode(
                RestoreOnlyHardwareTrialRecord.self,
                from: trialData
            )
            let datedDecoder = JSONDecoder()
            datedDecoder.dateDecodingStrategy = .iso8601
            probe = try datedDecoder.decode(ProbeResult.self, from: probeData)
            reconciliation = try datedDecoder.decode(
                ReconciliationResult.self,
                from: reconciliationData
            )
        } catch {
            throw PrecisionForensicEvidenceError.invalidJSON(
                String(describing: error)
            )
        }

        do {
            try live.validateForRecovery()
        } catch {
            throw PrecisionForensicEvidenceError.invalidLiveBaseline
        }
        guard live.schemaVersion == DeviceStateJournal.currentSchemaVersion,
              live.transactionID == profile.sourceTransactionID,
              live.featureID == ReprogControlsV4.featureID,
              live.feature.index == 0x0A,
              live.feature.version == 3,
              live.expectedControlCount == 9,
              live.controls.count == 9,
              !live.requiresRecovery,
              let precision = live.controls.first(where: {
                  $0.controlInfo.controlID
                    == RestoreOnlyHardwareTrialRecord.precisionControlID
              }),
              precision.phase == .baselineVerified,
              precision.intendedReporting == nil,
              precision.readBackReporting == nil,
              precision.baselineReporting.rawParameters
                == cleanPrecisionParameters else {
            throw PrecisionForensicEvidenceError.invalidLiveBaseline
        }

        do {
            try trial.validate()
            try trial.validateSourceBaseline(liveData)
        } catch {
            throw PrecisionForensicEvidenceError.invalidTrial
        }
        guard trial.transactionID == profile.trialTransactionID,
              trial.attemptID == profile.attemptID,
              trial.sourceBaselineTransactionID == profile.sourceTransactionID,
              trial.sourceBaselineSHA256 == profile.liveJournalSHA256,
              trial.device == live.device,
              trial.featureID == live.featureID,
              trial.featureIndex == live.feature.index,
              trial.featureVersion == live.feature.version,
              trial.controlID
                == RestoreOnlyHardwareTrialRecord.precisionControlID,
              trial.phase == .baselineVerified,
              trial.revision == 3,
              trial.preflightState.rawParameters == cleanPrecisionParameters,
              trial.verificationState == trial.preflightState,
              trial.setRequestBytes == exactRestoreSet,
              trial.verificationRequestBytes == exactVerificationGet else {
            throw PrecisionForensicEvidenceError.invalidTrial
        }

        guard probe.schemaVersion == 1,
              probe.succeeded,
              probe.journalSHA256Before == profile.liveJournalSHA256,
              probe.journalSHA256After == profile.liveJournalSHA256,
              probe.backupSHA256Before == profile.backupJournalSHA256,
              probe.backupSHA256After == profile.backupJournalSHA256,
              probe.precisionRequest == exactProbeGet,
              probe.precisionResponse == exactProbeGet,
              probe.connectionEpoch == trial.connectionEpoch else {
            throw PrecisionForensicEvidenceError.invalidProbe
        }

        guard reconciliation.schemaVersion == 1,
              reconciliation.succeeded,
              reconciliation.transactionID == profile.trialTransactionID,
              reconciliation.attemptID == profile.attemptID,
              reconciliation.finalPhase
                == RestoreOnlyHardwareTrialPhase.baselineVerified.rawValue,
              reconciliation.finalRevision == 3,
              reconciliation.observation == cleanPrecisionParameters,
              reconciliation.probeResultSHA256 == profile.probeResultSHA256,
              reconciliation.trialJournalSHA256Before
                == profile.preReconciliationTrialSHA256,
              reconciliation.trialJournalSHA256After
                == profile.reconciledTrialSHA256,
              reconciliation.liveJournalSHA256Before
                == profile.liveJournalSHA256,
              reconciliation.liveJournalSHA256After
                == profile.liveJournalSHA256,
              reconciliation.backupSHA256Before
                == profile.backupJournalSHA256,
              reconciliation.backupSHA256After
                == profile.backupJournalSHA256 else {
            throw PrecisionForensicEvidenceError.invalidReconciliation
        }

        guard trial.createdAt < probe.completedAt,
              probe.completedAt < reconciliation.completedAt,
              trial.updatedAt >= probe.completedAt,
              abs(trial.updatedAt.timeIntervalSince(
                  reconciliation.completedAt
              )) <= 2 else {
            throw PrecisionForensicEvidenceError.invalidTimestampOrder
        }

        return PrecisionForensicEvidenceReport(
            sourceTransactionID: live.transactionID,
            trialTransactionID: trial.transactionID,
            attemptID: trial.attemptID,
            observation: cleanPrecisionParameters,
            probeCompletedAt: probe.completedAt,
            reconciliationCompletedAt: reconciliation.completedAt
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static let cleanPrecisionParameters: [UInt8] =
        [0x00, 0xED] + Array(repeating: 0, count: 14)

    private static let exactRestoreSet: [UInt8] =
        [0x11, 0x00, 0x0A, 0x3E, 0x00, 0xED, 0x02]
            + Array(repeating: 0, count: 13)

    private static let exactVerificationGet: [UInt8] =
        [0x11, 0x00, 0x0A, 0x2E, 0x00, 0xED]
            + Array(repeating: 0, count: 14)

    private static let exactProbeGet: [UInt8] =
        [0x11, 0x00, 0x0A, 0x2D, 0x00, 0xED]
            + Array(repeating: 0, count: 14)

    private static func requireHash(
        _ data: Data,
        _ expected: String,
        name: String
    ) throws {
        guard sha256(data) == expected else {
            throw PrecisionForensicEvidenceError.hashMismatch(name)
        }
    }

    private static func readRegularFile(_ url: URL) throws -> Data {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
        } catch {
            throw PrecisionForensicEvidenceError.missingOrNonRegularFile(
                url.lastPathComponent
            )
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw PrecisionForensicEvidenceError.missingOrNonRegularFile(
                url.lastPathComponent
            )
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}
