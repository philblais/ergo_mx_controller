import AppKit
import CryptoKit
import Darwin
import Foundation
import MXErgoHIDPP

private enum OfflineReconciliationError: Error, LocalizedError, Sendable {
    case explicitConfirmationMissing
    case competingSoftwareRunning([String])
    case requiredFileMissing(String)
    case unexpectedExistingResult
    case nonRegularFile(String)
    case unexpectedTrialJournal(String)
    case invalidProbeEvidence(String)
    case protectedStateChanged
    case durableReconciliationMismatch
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .explicitConfirmationMissing:
            "The exact read-only reconciliation confirmation argument was not supplied"
        case let .competingSoftwareRunning(names):
            "Competing mouse software is still running: \(names.joined(separator: ", "))"
        case let .requiredFileMissing(name):
            "A required reconciliation file is missing: \(name)"
        case .unexpectedExistingResult:
            "A reconciliation result already exists; refusing to repeat"
        case let .nonRegularFile(path):
            "A required path is not a regular file: \(path)"
        case let .unexpectedTrialJournal(detail):
            "The durable trial journal is not the exact outcome-unknown record: \(detail)"
        case let .invalidProbeEvidence(detail):
            "The final GET-only probe evidence is not eligible: \(detail)"
        case .protectedStateChanged:
            "The live baseline or original-byte backup changed during reconciliation"
        case .durableReconciliationMismatch:
            "The reconciled trial journal did not read back at baselineVerified revision 3"
        case let .posix(operation, code):
            "\(operation) failed with POSIX code \(code)"
        }
    }
}

private struct ReadOnlyProbeResult: Decodable {
    let schemaVersion: Int
    let succeeded: Bool
    let completedAt: Date
    let detail: String
    let journalSHA256Before: String?
    let journalSHA256After: String?
    let backupSHA256Before: String?
    let backupSHA256After: String?
    let precisionRequest: [UInt8]?
    let precisionResponse: [UInt8]?
    let connectionEpoch: UInt64?
}

private struct ReconciliationResult: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let succeeded: Bool
    let completedAt: Date
    let detail: String
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

    static func failure(_ error: Error) -> ReconciliationResult {
        ReconciliationResult(
            schemaVersion: currentSchemaVersion,
            succeeded: false,
            completedAt: Date(),
            detail: error.localizedDescription,
            transactionID: nil,
            attemptID: nil,
            finalPhase: nil,
            finalRevision: nil,
            observation: nil,
            probeResultSHA256: nil,
            trialJournalSHA256Before: nil,
            trialJournalSHA256After: nil,
            liveJournalSHA256Before: nil,
            liveJournalSHA256After: nil,
            backupSHA256Before: nil,
            backupSHA256After: nil
        )
    }
}

private struct ReconciliationEvidence {
    let record: RestoreOnlyHardwareTrialRecord
    let observation: DeviceTransactionWireState
    let probeResultSHA256: String
    let trialBefore: String
    let trialAfter: String
    let liveBefore: String
    let liveAfter: String
    let backupBefore: String
    let backupAfter: String
}

@main
private enum MXErgoPrecisionTrialReconcilerMain {
    private static let confirmationArgument = "--confirmed-read-only-reconcile-baseline"
    private static let expectedTrialTransactionID = UUID(
        uuidString: "96BEAE07-7727-4D1E-8439-48AB574CBD81"
    )!
    private static let expectedAttemptID = UUID(
        uuidString: "C7D0303B-F065-4812-8EE8-87581C5C1191"
    )!
    private static let expectedSourceTransactionID = UUID(
        uuidString: "75465823-37D5-4685-A6C8-398A9B0D72F1"
    )!
    private static let expectedLiveSHA256 =
        "60ab614927d20871994ad0ebe7368158af9a26b2c1d60f7a2ab3c51635f77097"
    private static let expectedBackupSHA256 =
        "4ef802eb1185c56f24b7635324113ab414f2acca499a4addc4e4117cd3cdf3aa"
    private static let expectedTrialSHA256 =
        "03fda6abd3fe720ebdde0eed5dd35c2b1d428e1e237954e22a9f99eee0971468"
    private static let expectedProbeSHA256 =
        "7887950ec9602a21ff1d030310b0cb52b78a02e9a495f58bd7396922436c5460"

    static func main() async {
        let result: ReconciliationResult
        do {
            guard CommandLine.arguments == [
                CommandLine.arguments[0], confirmationArgument,
            ] else {
                throw OfflineReconciliationError.explicitConfirmationMissing
            }
            let competitors = competingSoftware()
            guard competitors.isEmpty else {
                throw OfflineReconciliationError.competingSoftwareRunning(competitors)
            }
            guard !FileManager.default.fileExists(atPath: resultURL.path) else {
                throw OfflineReconciliationError.unexpectedExistingResult
            }

            let evidence = try await reconcile()
            result = ReconciliationResult(
                schemaVersion: ReconciliationResult.currentSchemaVersion,
                succeeded: true,
                completedAt: Date(),
                detail: "The outcome-unknown trial was durably classified baselineVerified from the signed post-power-cycle GET-only evidence; no HID API exists in this executable",
                transactionID: evidence.record.transactionID,
                attemptID: evidence.record.attemptID,
                finalPhase: evidence.record.phase.rawValue,
                finalRevision: evidence.record.revision,
                observation: evidence.observation.rawParameters,
                probeResultSHA256: evidence.probeResultSHA256,
                trialJournalSHA256Before: evidence.trialBefore,
                trialJournalSHA256After: evidence.trialAfter,
                liveJournalSHA256Before: evidence.liveBefore,
                liveJournalSHA256After: evidence.liveAfter,
                backupSHA256Before: evidence.backupBefore,
                backupSHA256After: evidence.backupAfter
            )
        } catch {
            result = .failure(error)
        }

        do {
            try writeResult(result)
            let bytes = try prettyEncoder.encode(result)
            FileHandle.standardOutput.write(bytes)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            FileHandle.standardError.write(Data("Reconciliation result write failed: \(error)\n".utf8))
            Darwin.exit(EXIT_FAILURE)
        }
        Darwin.exit(result.succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private static func reconcile() async throws -> ReconciliationEvidence {
        for url in [liveJournalURL, backupURL, trialJournalURL, probeResultURL] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw OfflineReconciliationError.requiredFileMissing(url.lastPathComponent)
            }
        }

        let liveBeforeData = try readRegularFile(liveJournalURL)
        let backupBeforeData = try readRegularFile(backupURL)
        let trialBeforeData = try readRegularFile(trialJournalURL)
        let probeData = try readRegularFile(probeResultURL)
        let liveBefore = sha256(liveBeforeData)
        let backupBefore = sha256(backupBeforeData)
        let trialBefore = sha256(trialBeforeData)
        let probeHash = sha256(probeData)

        guard liveBefore == expectedLiveSHA256,
              backupBefore == expectedBackupSHA256,
              trialBefore == expectedTrialSHA256 else {
            throw OfflineReconciliationError.unexpectedTrialJournal(
                "a pinned journal hash changed"
            )
        }
        guard probeHash == expectedProbeSHA256 else {
            throw OfflineReconciliationError.invalidProbeEvidence(
                "the post-power-cycle result hash changed"
            )
        }

        let repository = DurableRestoreOnlyHardwareTrialRepository(fileURL: trialJournalURL)
        guard let current = try await repository.loadValidated() else {
            throw OfflineReconciliationError.requiredFileMissing(trialJournalURL.lastPathComponent)
        }
        guard current.transactionID == expectedTrialTransactionID,
              current.attemptID == expectedAttemptID,
              current.sourceBaselineTransactionID == expectedSourceTransactionID,
              current.sourceBaselineSHA256 == expectedLiveSHA256,
              current.device.serialNumber == "7865BCA9046ED9FF",
              current.featureID == 0x1B04,
              current.featureIndex == 0x0A,
              current.featureVersion == 3,
              current.controlID == RestoreOnlyHardwareTrialRecord.precisionControlID,
              current.phase == .outcomeUnknown,
              current.revision == 2,
              current.acknowledgementBytes == nil,
              current.verificationState == nil else {
            throw OfflineReconciliationError.unexpectedTrialJournal(
                "identity, phase, or revision did not match the one authorized trial"
            )
        }
        try current.validateSourceBaseline(liveBeforeData)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let probe: ReadOnlyProbeResult
        do {
            probe = try decoder.decode(ReadOnlyProbeResult.self, from: probeData)
        } catch {
            throw OfflineReconciliationError.invalidProbeEvidence(
                "result decoding failed: \(error)"
            )
        }

        let expectedRequest = [UInt8](
            [0x11, 0x00, current.featureIndex, 0x2D, 0x00, 0xED]
                + Array(repeating: 0, count: 14)
        )
        guard probe.schemaVersion == 1,
              probe.succeeded,
              probe.completedAt > current.updatedAt,
              probe.journalSHA256Before == expectedLiveSHA256,
              probe.journalSHA256After == expectedLiveSHA256,
              probe.backupSHA256Before == expectedBackupSHA256,
              probe.backupSHA256After == expectedBackupSHA256,
              probe.precisionRequest == expectedRequest,
              let response = probe.precisionResponse,
              response.count == HIDPP20LongMessage.byteCount,
              Array(response.prefix(4)) == Array(expectedRequest.prefix(4)),
              let connectionEpoch = probe.connectionEpoch else {
            throw OfflineReconciliationError.invalidProbeEvidence(
                "schema, hashes, request, response header, or epoch did not match"
            )
        }

        let observation = try DeviceTransactionWireState(
            rawParameters: Array(response[4..<20])
        )
        guard observation == current.preflightState else {
            throw OfflineReconciliationError.invalidProbeEvidence(
                "the final read-only observation was not the exact clean baseline"
            )
        }

        let freshSession = RestoreOnlyHardwareTrialSession(
            device: current.device,
            featureIndex: current.featureIndex,
            featureVersion: current.featureVersion,
            connectionEpoch: connectionEpoch,
            matchingDeviceCount: 1,
            outputReportByteCount: HIDPP20LongMessage.byteCount
        )
        let reconciled = try await repository.reconcileRestartReadOnly(
            observation: observation,
            freshSession: freshSession,
            sourceBaselineData: liveBeforeData,
            liveJournalURL: liveJournalURL
        )

        let liveAfterData = try readRegularFile(liveJournalURL)
        let backupAfterData = try readRegularFile(backupURL)
        guard liveAfterData == liveBeforeData,
              backupAfterData == backupBeforeData else {
            throw OfflineReconciliationError.protectedStateChanged
        }
        let trialAfterData = try readRegularFile(trialJournalURL)
        guard let durable = try await repository.loadValidated(),
              durable == reconciled,
              durable.phase == .baselineVerified,
              durable.revision == 3,
              durable.verificationState == durable.preflightState,
              durable.detail == nil else {
            throw OfflineReconciliationError.durableReconciliationMismatch
        }

        return ReconciliationEvidence(
            record: durable,
            observation: observation,
            probeResultSHA256: probeHash,
            trialBefore: trialBefore,
            trialAfter: sha256(trialAfterData),
            liveBefore: liveBefore,
            liveAfter: sha256(liveAfterData),
            backupBefore: backupBefore,
            backupAfter: sha256(backupAfterData)
        )
    }

    /// Delegates to the canonical, unit-tested classifier in MXErgoHIDPP.
    ///
    /// This helper previously carried its own keyword list, which diverged from
    /// the canonical rule in three ways: it never stripped punctuation, it
    /// missed the `btt` and `btthelper` aliases, and it read
    /// `localizedName ?? bundleIdentifier`, so a process with any localized
    /// name had its bundle identifier ignored entirely. A single classifier
    /// means the trial, the reconciler and the menu app cannot disagree about
    /// whether it is safe to touch the device.
    private static func competingSoftware() -> [String] {
        let scanner = PrecisionCompetingProcessScanner {
            NSWorkspace.shared.runningApplications.map { application in
                PrecisionRunningApplicationSnapshot(
                    processIdentifier: application.processIdentifier,
                    bundleIdentifier: application.bundleIdentifier,
                    localizedName: application.localizedName
                )
            }
        }
        let competitors = (try? scanner.scan(
            excludingProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        )) ?? []
        return competitors.map(\.displayName)
    }

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.phib.MXErgoController", isDirectory: true)
    }

    private static var liveJournalURL: URL {
        supportDirectory.appendingPathComponent("device-state-journal.json")
    }

    private static var backupURL: URL {
        supportDirectory.appendingPathComponent(
            "device-state-journal.pre-firmware-identity.json"
        )
    }

    private static var trialJournalURL: URL {
        supportDirectory.appendingPathComponent("restore-only-precision-trial.json")
    }

    private static var probeResultURL: URL {
        supportDirectory.appendingPathComponent("restore-trial-probe-result.json")
    }

    private static var resultURL: URL {
        supportDirectory.appendingPathComponent(
            "restore-only-precision-reconciliation-result.json"
        )
    }

    private static func writeResult(_ result: ReconciliationResult) throws {
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        try prettyEncoder.encode(result).write(to: resultURL, options: .atomic)
    }

    private static var prettyEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func readRegularFile(_ url: URL) throws -> Data {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw OfflineReconciliationError.posix(
                operation: "inspect \(url.lastPathComponent)",
                code: errno
            )
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw OfflineReconciliationError.nonRegularFile(url.path)
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw OfflineReconciliationError.posix(
                operation: "open \(url.lastPathComponent)",
                code: errno
            )
        }
        defer { _ = Darwin.close(descriptor) }

        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0 else {
            throw OfflineReconciliationError.posix(
                operation: "verify \(url.lastPathComponent)",
                code: errno
            )
        }
        guard openedStatus.st_mode & S_IFMT == S_IFREG,
              openedStatus.st_dev == status.st_dev,
              openedStatus.st_ino == status.st_ino else {
            throw OfflineReconciliationError.nonRegularFile(url.path)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw OfflineReconciliationError.posix(
                    operation: "read \(url.lastPathComponent)",
                    code: errno
                )
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
