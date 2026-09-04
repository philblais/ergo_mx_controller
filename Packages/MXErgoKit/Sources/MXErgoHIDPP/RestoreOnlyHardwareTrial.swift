import CryptoKit
import Darwin
import Foundation

public enum RestoreOnlyHardwareTrialError: Error, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case journalRequiresRecovery
    case invalidDeviceIdentity
    case invalidFirmwareIdentity
    case unsupportedFeature(index: UInt8, version: UInt8)
    case missingPrecisionControl
    case precisionBaselineIsNotClean
    case invalidPacket
    case invalidPhase
    case invalidRevision(expected: UInt64, actual: UInt64)
    case compareAndSwapMismatch
    case transactionIdentityMismatch
    case nonRegularFile
    case lockUnavailable
    case operationLeaseUnavailable
    case durableVerificationFailed
    case invalidAuthorization
    case authorizationAlreadyConsumed
    case sessionChanged
    case liveBaselineMismatch
    case preflightMismatch
    case acknowledgementMismatch
    case verificationMismatch
    case outcomeUnknown(String)
    case posix(operation: String, code: Int32)
}

extension RestoreOnlyHardwareTrialError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return "unsupported restore-only trial schema version \(version)"
        case .journalRequiresRecovery:
            return "the live baseline already requires recovery"
        case .invalidDeviceIdentity:
            return "the saved device is not the exact BLE MX Ergo identity"
        case .invalidFirmwareIdentity:
            return "the baseline is not bound to a firmware fingerprint"
        case let .unsupportedFeature(index, version):
            return String(
                format: "REPROG feature index 0x%02X version %d is not eligible",
                index,
                version
            )
        case .missingPrecisionControl:
            return "Precision CID 0x00ED is missing from the baseline"
        case .precisionBaselineIsNotClean:
            return "Precision CID 0x00ED is not at the exact clean baseline"
        case .invalidPacket:
            return "the SET or verification bytes exceeded the narrow packet allowlist"
        case .invalidPhase:
            return "the restore-only trial phase transition is not valid"
        case let .invalidRevision(expected, actual):
            return "trial revision mismatch: expected \(expected), found \(actual)"
        case .compareAndSwapMismatch:
            return "the trial journal changed before atomic replacement"
        case .transactionIdentityMismatch:
            return "the trial transaction or attempt identity changed"
        case .nonRegularFile:
            return "the trial journal path is not a regular file"
        case .lockUnavailable:
            return "another writer holds the trial journal lock"
        case .operationLeaseUnavailable:
            return "another process holds the restore-only trial operation lease"
        case .durableVerificationFailed:
            return "the durable trial journal did not read back byte-for-byte"
        case .invalidAuthorization:
            return "the armed revision did not match its one-use authorization"
        case .authorizationAlreadyConsumed:
            return "the one-use SET authorization was already consumed"
        case .sessionChanged:
            return "the device identity, feature, or connection epoch changed"
        case .liveBaselineMismatch:
            return "the live recovery baseline changed or no longer matches the prepared trial"
        case .preflightMismatch:
            return "the independent preflight GET did not match the saved baseline"
        case .acknowledgementMismatch:
            return "the SET acknowledgement did not echo every reviewed byte"
        case .verificationMismatch:
            return "the independent verification GET did not match the baseline"
        case let .outcomeUnknown(detail):
            return "the scripted SET outcome is unknown: \(detail)"
        case let .posix(operation, code):
            return "\(operation) failed with POSIX code \(code)"
        }
    }
}

public enum RestoreOnlyHardwareTrialPhase: String, Sendable, Codable, Equatable {
    case prepared
    case armedMayHaveDispatched
    case acknowledged
    case baselineVerified
    case outcomeUnknown
    case conflicted
}

/// Dedicated state for the first restore-only hardware experiment. It is kept
/// separate from the general schema-v3 apply/restore transaction because a
/// no-op restore starts and ends at the same clean baseline.
public struct RestoreOnlyHardwareTrialRecord: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1
    public static let precisionControlID: UInt16 = 0x00ED
    public static let requiredSetFlags: UInt8 = 0x02
    public static let requiredMappedControlID: UInt16 = 0x0000

    public let schemaVersion: Int
    public let transactionID: UUID
    public let attemptID: UUID
    public let sourceBaselineTransactionID: UUID
    public let sourceBaselineSHA256: String
    public let device: JournalDeviceIdentity
    public let featureID: UInt16
    public let featureIndex: UInt8
    public let featureVersion: UInt8
    public let connectionEpoch: UInt64
    public let controlID: UInt16
    public let preflightState: DeviceTransactionWireState
    public let setRequestBytes: [UInt8]
    public let verificationRequestBytes: [UInt8]
    public private(set) var revision: UInt64
    public private(set) var phase: RestoreOnlyHardwareTrialPhase
    public private(set) var acknowledgementBytes: [UInt8]?
    public private(set) var verificationState: DeviceTransactionWireState?
    public private(set) var detail: String?
    public let createdAt: Date
    public private(set) var updatedAt: Date

    public static func prepare(
        sourceBaselineData: Data,
        currentFeature: HIDPP20FeatureDescriptor,
        connectionEpoch: UInt64,
        transactionID: UUID = UUID(),
        attemptID: UUID = UUID(),
        now: Date = Date()
    ) throws -> RestoreOnlyHardwareTrialRecord {
        let journal = try JSONDecoder().decode(DeviceStateJournal.self, from: sourceBaselineData)
        try journal.validateForRecovery()
        guard !journal.requiresRecovery else {
            throw RestoreOnlyHardwareTrialError.journalRequiresRecovery
        }
        guard journal.device.vendorID == 0x046D,
              journal.device.productID == 0xB01D,
              journal.device.transport == "Bluetooth Low Energy",
              journal.device.serialNumber?.isEmpty == false,
              journal.device.locationID != nil else {
            throw RestoreOnlyHardwareTrialError.invalidDeviceIdentity
        }
        guard journal.device.firmwareIdentity?.isEmpty == false else {
            throw RestoreOnlyHardwareTrialError.invalidFirmwareIdentity
        }
        guard currentFeature.index != 0,
              currentFeature.index != 0xFF,
              currentFeature.version == 3,
              journal.feature.version == 3 else {
            throw RestoreOnlyHardwareTrialError.unsupportedFeature(
                index: currentFeature.index,
                version: currentFeature.version
            )
        }
        guard let entry = journal.controls.first(where: {
            $0.controlInfo.controlID == precisionControlID
        }) else {
            throw RestoreOnlyHardwareTrialError.missingPrecisionControl
        }
        guard entry.phase == .baselineVerified,
              entry.intendedReporting == nil,
              entry.readBackReporting == nil,
              entry.baselineReporting.rawFlags == 0,
              entry.baselineReporting.rawMappedControlID == 0 else {
            throw RestoreOnlyHardwareTrialError.precisionBaselineIsNotClean
        }

        let plan = try RestoreOnlyReportingPlanner.makePlan(
            for: precisionControlID,
            journal: journal,
            currentFeature: currentFeature,
            deviceIndex: 0,
            softwareID: 0x0E
        )
        guard plan.setFlags == requiredSetFlags,
              plan.setMappedControlID == requiredMappedControlID else {
            throw RestoreOnlyHardwareTrialError.invalidPacket
        }

        let record = RestoreOnlyHardwareTrialRecord(
            schemaVersion: currentSchemaVersion,
            transactionID: transactionID,
            attemptID: attemptID,
            sourceBaselineTransactionID: journal.transactionID,
            sourceBaselineSHA256: sha256(sourceBaselineData),
            device: journal.device,
            featureID: ReprogControlsV4.featureID,
            featureIndex: currentFeature.index,
            featureVersion: currentFeature.version,
            connectionEpoch: connectionEpoch,
            controlID: precisionControlID,
            preflightState: try DeviceTransactionWireState(
                rawParameters: entry.baselineReporting.rawParameters
            ),
            setRequestBytes: plan.setRequest.bytes,
            verificationRequestBytes: plan.verificationRequest.bytes,
            revision: 0,
            phase: .prepared,
            acknowledgementBytes: nil,
            verificationState: nil,
            detail: nil,
            createdAt: now,
            updatedAt: now
        )
        try record.validate()
        return record
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RestoreOnlyHardwareTrialError.unsupportedSchemaVersion(schemaVersion)
        }
        guard device.vendorID == 0x046D,
              device.productID == 0xB01D,
              device.transport == "Bluetooth Low Energy",
              device.serialNumber?.isEmpty == false,
              device.locationID != nil else {
            throw RestoreOnlyHardwareTrialError.invalidDeviceIdentity
        }
        guard device.firmwareIdentity?.isEmpty == false else {
            throw RestoreOnlyHardwareTrialError.invalidFirmwareIdentity
        }
        guard featureID == ReprogControlsV4.featureID,
              featureIndex != 0,
              featureIndex != 0xFF,
              featureVersion == 3 else {
            throw RestoreOnlyHardwareTrialError.unsupportedFeature(
                index: featureIndex,
                version: featureVersion
            )
        }
        guard controlID == Self.precisionControlID,
              sourceBaselineSHA256.count == 64 else {
            throw RestoreOnlyHardwareTrialError.invalidPacket
        }
        try preflightState.validate(controlID: controlID)
        guard preflightState.rawFlags(featureVersion: featureVersion) == 0,
              preflightState.mappedControlID == 0 else {
            throw RestoreOnlyHardwareTrialError.precisionBaselineIsNotClean
        }

        let set = try HIDPP20LongMessage(bytes: setRequestBytes)
        let verify = try HIDPP20LongMessage(bytes: verificationRequestBytes)
        guard set.deviceIndex == 0,
              set.featureIndex == featureIndex,
              set.functionID == 3,
              set.softwareID == 0x0E,
              Array(set.parameters.prefix(5)) == [0x00, 0xED, 0x02, 0x00, 0x00],
              set.parameters.dropFirst(5).allSatisfy({ $0 == 0 }),
              verify.deviceIndex == 0,
              verify.featureIndex == featureIndex,
              verify.functionID == 2,
              verify.softwareID == 0x0E,
              Array(verify.parameters.prefix(2)) == [0x00, 0xED],
              verify.parameters.dropFirst(2).allSatisfy({ $0 == 0 }) else {
            throw RestoreOnlyHardwareTrialError.invalidPacket
        }

        switch phase {
        case .prepared, .armedMayHaveDispatched:
            guard acknowledgementBytes == nil,
                  verificationState == nil,
                  detail == nil else {
                throw RestoreOnlyHardwareTrialError.invalidPhase
            }
        case .acknowledged:
            guard acknowledgementBytes == setRequestBytes,
                  verificationState == nil,
                  detail == nil else {
                throw RestoreOnlyHardwareTrialError.invalidPhase
            }
        case .baselineVerified:
            guard (acknowledgementBytes == nil || acknowledgementBytes == setRequestBytes),
                  verificationState == preflightState,
                  detail == nil else {
                throw RestoreOnlyHardwareTrialError.invalidPhase
            }
        case .outcomeUnknown:
            guard verificationState == nil, detail?.isEmpty == false else {
                throw RestoreOnlyHardwareTrialError.invalidPhase
            }
        case .conflicted:
            guard verificationState != nil, detail?.isEmpty == false else {
                throw RestoreOnlyHardwareTrialError.invalidPhase
            }
        }
    }

    /// Revalidates the exact schema-v2 source that was pinned when the trial
    /// was prepared. Hash equality protects its original byte representation;
    /// the decoded checks bind the transaction, device, firmware, feature, and
    /// Precision baseline semantics used by the runner.
    public func validateSourceBaseline(_ data: Data) throws {
        guard Self.sha256(data) == sourceBaselineSHA256 else {
            throw RestoreOnlyHardwareTrialError.liveBaselineMismatch
        }
        let journal = try JSONDecoder().decode(DeviceStateJournal.self, from: data)
        try journal.validateForRecovery()
        guard !journal.requiresRecovery,
              journal.schemaVersion == DeviceStateJournal.currentSchemaVersion,
              journal.transactionID == sourceBaselineTransactionID,
              journal.device == device,
              journal.feature.index == featureIndex,
              journal.feature.version == featureVersion,
              let precision = journal.controls.first(where: {
                  $0.controlInfo.controlID == controlID
              }),
              precision.phase == .baselineVerified,
              precision.intendedReporting == nil,
              precision.readBackReporting == nil,
              try DeviceTransactionWireState(
                  rawParameters: precision.baselineReporting.rawParameters
              ) == preflightState else {
            throw RestoreOnlyHardwareTrialError.liveBaselineMismatch
        }
    }

    fileprivate func advancing(
        to nextPhase: RestoreOnlyHardwareTrialPhase,
        acknowledgementBytes: [UInt8]? = nil,
        verificationState: DeviceTransactionWireState? = nil,
        detail: String? = nil,
        now: Date = Date()
    ) throws -> RestoreOnlyHardwareTrialRecord {
        guard revision < .max else {
            throw RestoreOnlyHardwareTrialError.invalidRevision(
                expected: revision,
                actual: revision
            )
        }
        var next = self
        next.revision += 1
        next.phase = nextPhase
        next.acknowledgementBytes = acknowledgementBytes
            ?? self.acknowledgementBytes
        next.verificationState = verificationState
        next.detail = detail
        next.updatedAt = now
        try next.validate()
        return next
    }

    fileprivate static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum RestoreOnlyHardwareTrialReducer {
    public static func arm(
        _ current: RestoreOnlyHardwareTrialRecord,
        now: Date = Date()
    ) throws -> RestoreOnlyHardwareTrialRecord {
        try current.validate()
        guard current.phase == .prepared else {
            throw RestoreOnlyHardwareTrialError.invalidPhase
        }
        return try current.advancing(to: .armedMayHaveDispatched, now: now)
    }

    public static func acknowledge(
        _ current: RestoreOnlyHardwareTrialRecord,
        responseBytes: [UInt8],
        now: Date = Date()
    ) throws -> RestoreOnlyHardwareTrialRecord {
        try current.validate()
        guard current.phase == .armedMayHaveDispatched,
              responseBytes == current.setRequestBytes else {
            throw RestoreOnlyHardwareTrialError.acknowledgementMismatch
        }
        return try current.advancing(
            to: .acknowledged,
            acknowledgementBytes: responseBytes,
            now: now
        )
    }

    public static func verify(
        _ current: RestoreOnlyHardwareTrialRecord,
        observation: DeviceTransactionWireState,
        now: Date = Date()
    ) throws -> RestoreOnlyHardwareTrialRecord {
        try current.validate()
        try observation.validate(controlID: current.controlID)
        guard current.phase == .acknowledged else {
            throw RestoreOnlyHardwareTrialError.invalidPhase
        }
        if observation == current.preflightState {
            return try current.advancing(
                to: .baselineVerified,
                verificationState: observation,
                now: now
            )
        }
        return try current.advancing(
            to: .conflicted,
            verificationState: observation,
            detail: "Independent GET did not match the exact preflight baseline",
            now: now
        )
    }

    /// Classifies an interrupted or ambiguous attempt using one fresh GET.
    /// This path never arms a record and cannot create a SET authorization.
    public static func reconcileReadOnly(
        _ current: RestoreOnlyHardwareTrialRecord,
        observation: DeviceTransactionWireState,
        now: Date = Date()
    ) throws -> RestoreOnlyHardwareTrialRecord {
        try current.validate()
        try observation.validate(controlID: current.controlID)
        guard current.phase == .armedMayHaveDispatched
                || current.phase == .acknowledged
                || current.phase == .outcomeUnknown else {
            throw RestoreOnlyHardwareTrialError.invalidPhase
        }
        if observation == current.preflightState {
            return try current.advancing(
                to: .baselineVerified,
                verificationState: observation,
                now: now
            )
        }
        return try current.advancing(
            to: .conflicted,
            verificationState: observation,
            detail: "Read-only restart reconciliation did not match the exact baseline",
            now: now
        )
    }

    public static func markOutcomeUnknown(
        _ current: RestoreOnlyHardwareTrialRecord,
        detail: String,
        now: Date = Date()
    ) throws -> RestoreOnlyHardwareTrialRecord {
        try current.validate()
        guard current.phase == .armedMayHaveDispatched || current.phase == .acknowledged,
              !detail.isEmpty else {
            throw RestoreOnlyHardwareTrialError.invalidPhase
        }
        return try current.advancing(to: .outcomeUnknown, detail: detail, now: now)
    }
}

public enum RestoreOnlyHardwareTrialCommitBoundary: String, Sendable, CaseIterable {
    case beforeTemporaryWrite
    case afterTemporaryWrite
    case afterTemporaryFullSync
    case beforeCompareAndSwap
    case afterAtomicReplace
    case afterDirectorySync
    case beforeReceiptReturn
}

public struct RestoreOnlyHardwareTrialCommitReceipt: Sendable, Equatable {
    public let transactionID: UUID
    public let attemptID: UUID
    public let revision: UInt64
    public let phase: RestoreOnlyHardwareTrialPhase
    public let journalSHA256: String
    public let sourceBaselineSHA256: String
    public let controlID: UInt16
    public let setRequestSHA256: String
    public let firmwareIdentity: String
    public let connectionEpoch: UInt64
    fileprivate let authorizationID: UUID
}

private struct RestoreOnlyHardwareTrialAuthorizationBinding: Sendable, Equatable {
    let receipt: RestoreOnlyHardwareTrialCommitReceipt
    let exactJournalBytes: Data
}

/// `fcntl(F_SETLK)` locks are process-scoped on macOS, so two independent
/// repository actors in one process can otherwise both enter the same critical
/// section. This registry closes that gap before the descriptor-scoped `flock`
/// is acquired for cross-process exclusion.
private final class RestoreOnlyHardwareTrialProcessLockRegistry: @unchecked Sendable {
    static let shared = RestoreOnlyHardwareTrialProcessLockRegistry()

    private let lock = NSLock()
    private var heldPaths: Set<String> = []

    func acquire(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return heldPaths.insert(path).inserted
    }

    func release(_ path: String) {
        lock.lock()
        heldPaths.remove(path)
        lock.unlock()
    }
}

private func canonicalTrialLockPath(_ url: URL) -> String {
    let directory = url.deletingLastPathComponent()
        .standardizedFileURL
        .resolvingSymlinksInPath()
    return directory.appendingPathComponent(url.lastPathComponent).path
}

/// A dedicated durable repository with a stable sidecar lock and a second
/// exact-byte CAS immediately before rename. Armed receipts are one-use,
/// in-memory capabilities and are revalidated against the durable bytes before
/// a runner may enter a transport call.
public actor DurableRestoreOnlyHardwareTrialRepository {
    public let fileURL: URL
    private let faultInjector: (@Sendable (RestoreOnlyHardwareTrialCommitBoundary) throws -> Void)?
    private var authorizations: [UUID: RestoreOnlyHardwareTrialAuthorizationBinding] = [:]
    private var consumedAuthorizations: Set<UUID> = []

    public init(fileURL: URL) {
        self.fileURL = fileURL
        faultInjector = nil
    }

    init(
        fileURL: URL,
        faultInjector: @escaping @Sendable (RestoreOnlyHardwareTrialCommitBoundary) throws -> Void
    ) {
        self.fileURL = fileURL
        self.faultInjector = faultInjector
    }

    public func loadValidated() throws -> RestoreOnlyHardwareTrialRecord? {
        guard let data = try Self.readRegularFileIfPresent(fileURL) else { return nil }
        let record = try JSONDecoder().decode(RestoreOnlyHardwareTrialRecord.self, from: data)
        try record.validate()
        return record
    }

    /// Durably classifies an interrupted trial from one independently obtained
    /// read-only observation. This path cannot prepare, arm, authorize, or send
    /// a SET request. A restarted process may have a new connection epoch, so
    /// the fresh session is matched by the exact device, firmware, feature, and
    /// single-interface report capability instead.
    @discardableResult
    public func reconcileRestartReadOnly(
        observation: DeviceTransactionWireState,
        freshSession: RestoreOnlyHardwareTrialSession,
        sourceBaselineData: Data,
        liveJournalURL: URL,
        now: Date = Date()
    ) throws -> RestoreOnlyHardwareTrialRecord {
        let deviceOperationLease = try MXErgoDeviceOperationLease.acquire(
            beside: liveJournalURL
        )
        defer { withExtendedLifetime(deviceOperationLease) {} }
        let operationLease = try acquireOperationLease()
        defer { withExtendedLifetime(operationLease) {} }

        guard let current = try loadValidated() else {
            throw RestoreOnlyHardwareTrialError.invalidPhase
        }
        guard current.phase == .armedMayHaveDispatched
                || current.phase == .acknowledged
                || current.phase == .outcomeUnknown else {
            throw RestoreOnlyHardwareTrialError.invalidPhase
        }
        guard current.matchesFreshRecoverySession(freshSession) else {
            throw RestoreOnlyHardwareTrialError.sessionChanged
        }
        try current.validateSourceBaseline(sourceBaselineData)

        let reconciled = try RestoreOnlyHardwareTrialReducer.reconcileReadOnly(
            current,
            observation: observation,
            now: now
        )
        _ = try commit(reconciled, expectedRevision: current.revision)
        return reconciled
    }

    func acquireOperationLease() throws -> RestoreOnlyHardwareTrialOperationLease {
        try RestoreOnlyHardwareTrialOperationLease.acquire(beside: fileURL)
    }

    public func commit(
        _ next: RestoreOnlyHardwareTrialRecord,
        expectedRevision: UInt64?
    ) throws -> RestoreOnlyHardwareTrialCommitReceipt {
        try next.validate()
        return try withExclusiveLock {
            let sourceBytes = try Self.readRegularFileIfPresent(fileURL)
            let current = try sourceBytes.map {
                let decoded = try JSONDecoder().decode(
                    RestoreOnlyHardwareTrialRecord.self,
                    from: $0
                )
                try decoded.validate()
                return decoded
            }
            guard current?.revision == expectedRevision else {
                throw RestoreOnlyHardwareTrialError.compareAndSwapMismatch
            }
            if let current {
                guard current.transactionID == next.transactionID,
                      current.attemptID == next.attemptID else {
                    throw RestoreOnlyHardwareTrialError.transactionIdentityMismatch
                }
                guard current.revision < .max,
                      next.revision == current.revision + 1 else {
                    throw RestoreOnlyHardwareTrialError.invalidRevision(
                        expected: current.revision + 1,
                        actual: next.revision
                    )
                }
            } else if next.revision != 0 {
                throw RestoreOnlyHardwareTrialError.invalidRevision(
                    expected: 0,
                    actual: next.revision
                )
            }

            let targetBytes = try Self.encoded(next)
            try faultInjector?(.beforeTemporaryWrite)
            let temporaryURL = try Self.writeFullySyncedTemporary(
                targetBytes,
                beside: fileURL,
                faultInjector: faultInjector
            )
            var temporaryExists = true
            defer {
                if temporaryExists { _ = Darwin.unlink(temporaryURL.path) }
            }

            try faultInjector?(.beforeCompareAndSwap)
            let lastMomentBytes = try Self.readRegularFileIfPresent(fileURL)
            guard lastMomentBytes == sourceBytes else {
                throw RestoreOnlyHardwareTrialError.compareAndSwapMismatch
            }

            guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
                throw Self.posixError("replace restore-only trial journal")
            }
            temporaryExists = false
            try faultInjector?(.afterAtomicReplace)
            try Self.syncDirectory(containing: fileURL)
            try faultInjector?(.afterDirectorySync)

            guard let verifiedBytes = try Self.readRegularFileIfPresent(fileURL),
                  verifiedBytes == targetBytes,
                  try JSONDecoder().decode(
                    RestoreOnlyHardwareTrialRecord.self,
                    from: verifiedBytes
                  ) == next else {
                throw RestoreOnlyHardwareTrialError.durableVerificationFailed
            }
            try faultInjector?(.beforeReceiptReturn)

            let authorizationID = UUID()
            let receipt = RestoreOnlyHardwareTrialCommitReceipt(
                transactionID: next.transactionID,
                attemptID: next.attemptID,
                revision: next.revision,
                phase: next.phase,
                journalSHA256: RestoreOnlyHardwareTrialRecord.sha256(targetBytes),
                sourceBaselineSHA256: next.sourceBaselineSHA256,
                controlID: next.controlID,
                setRequestSHA256: RestoreOnlyHardwareTrialRecord.sha256(
                    Data(next.setRequestBytes)
                ),
                firmwareIdentity: next.device.firmwareIdentity ?? "",
                connectionEpoch: next.connectionEpoch,
                authorizationID: authorizationID
            )
            if next.phase == .armedMayHaveDispatched {
                authorizations[authorizationID] = RestoreOnlyHardwareTrialAuthorizationBinding(
                    receipt: receipt,
                    exactJournalBytes: targetBytes
                )
            } else {
                authorizations = authorizations.filter {
                    $0.value.receipt.attemptID != next.attemptID
                }
            }
            return receipt
        }
    }

    func consumeArmedAuthorization(
        _ receipt: RestoreOnlyHardwareTrialCommitReceipt,
        request: HIDPP20LongMessage,
        expectedSession: RestoreOnlyHardwareTrialSession
    ) throws -> RestoreOnlyHardwareTrialRecord {
        if consumedAuthorizations.contains(receipt.authorizationID) {
            throw RestoreOnlyHardwareTrialError.authorizationAlreadyConsumed
        }
        guard let binding = authorizations.removeValue(forKey: receipt.authorizationID) else {
            throw RestoreOnlyHardwareTrialError.invalidAuthorization
        }
        consumedAuthorizations.insert(receipt.authorizationID)

        return try withExclusiveLock {
            guard binding.receipt == receipt,
                  receipt.phase == .armedMayHaveDispatched,
                  receipt.controlID == RestoreOnlyHardwareTrialRecord.precisionControlID,
                  receipt.connectionEpoch == expectedSession.connectionEpoch,
                  receipt.firmwareIdentity == expectedSession.device.firmwareIdentity,
                  receipt.setRequestSHA256 == RestoreOnlyHardwareTrialRecord.sha256(
                    Data(request.bytes)
                  ),
                  let liveBytes = try Self.readRegularFileIfPresent(fileURL),
                  liveBytes == binding.exactJournalBytes,
                  RestoreOnlyHardwareTrialRecord.sha256(liveBytes) == receipt.journalSHA256 else {
                throw RestoreOnlyHardwareTrialError.invalidAuthorization
            }
            let record = try JSONDecoder().decode(
                RestoreOnlyHardwareTrialRecord.self,
                from: liveBytes
            )
            try record.validate()
            guard record.transactionID == receipt.transactionID,
                  record.attemptID == receipt.attemptID,
                  record.revision == receipt.revision,
                  record.phase == receipt.phase,
                  record.sourceBaselineSHA256 == receipt.sourceBaselineSHA256,
                  record.setRequestBytes == request.bytes,
                  record.matches(expectedSession) else {
                throw RestoreOnlyHardwareTrialError.invalidAuthorization
            }
            return record
        }
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let lockURL = directoryURL.appendingPathComponent(".\(fileURL.lastPathComponent).lock")
        let processLockPath = canonicalTrialLockPath(lockURL)
        guard RestoreOnlyHardwareTrialProcessLockRegistry.shared.acquire(processLockPath) else {
            throw RestoreOnlyHardwareTrialError.lockUnavailable
        }
        defer {
            RestoreOnlyHardwareTrialProcessLockRegistry.shared.release(processLockPath)
        }
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw Self.posixError("open trial journal lock") }
        defer { _ = Darwin.close(descriptor) }
        var fileLock = flock()
        fileLock.l_start = 0
        fileLock.l_len = 0
        fileLock.l_pid = 0
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_OFD_SETLK, &fileLock) == 0 else {
            if errno == EACCES || errno == EAGAIN {
                throw RestoreOnlyHardwareTrialError.lockUnavailable
            }
            throw Self.posixError("lock trial journal")
        }
        defer {
            fileLock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_OFD_SETLK, &fileLock)
        }
        return try body()
    }

    private static func encoded(_ record: RestoreOnlyHardwareTrialRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(record)
    }

    private static func readRegularFileIfPresent(_ url: URL) throws -> Data? {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError("lstat restore-only trial journal")
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw RestoreOnlyHardwareTrialError.nonRegularFile
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError("open restore-only trial journal") }
        defer { _ = Darwin.close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError("read restore-only trial journal")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func writeFullySyncedTemporary(
        _ data: Data,
        beside fileURL: URL,
        faultInjector: (@Sendable (RestoreOnlyHardwareTrialCommitBoundary) throws -> Void)?
    ) throws -> URL {
        let temporaryURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        var descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixError("open temporary trial journal") }
        var keepFile = false
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if !keepFile { _ = Darwin.unlink(temporaryURL.path) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write temporary trial journal")
                }
                guard written > 0 else {
                    throw RestoreOnlyHardwareTrialError.posix(
                        operation: "write temporary trial journal",
                        code: EIO
                    )
                }
                offset += written
            }
        }
        try faultInjector?(.afterTemporaryWrite)
        guard Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw posixError("F_FULLFSYNC temporary trial journal")
        }
        try faultInjector?(.afterTemporaryFullSync)
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw posixError("close temporary trial journal")
        }
        descriptor = -1
        guard try readRegularFileIfPresent(temporaryURL) == data else {
            throw RestoreOnlyHardwareTrialError.durableVerificationFailed
        }
        keepFile = true
        return temporaryURL
    }

    private static func syncDirectory(containing fileURL: URL) throws {
        let descriptor = Darwin.open(fileURL.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError("open trial journal directory") }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError("fsync trial journal directory")
        }
    }

    private static func posixError(_ operation: String) -> RestoreOnlyHardwareTrialError {
        RestoreOnlyHardwareTrialError.posix(operation: operation, code: errno)
    }
}

/// A stable process-wide lease held across preflight, durable arming,
/// transport, read-back, and the terminal commit. The per-commit repository
/// lock remains separate so a second process cannot enter between commits.
final class RestoreOnlyHardwareTrialOperationLease: @unchecked Sendable {
    private var descriptor: Int32
    private let processLockPath: String

    private init(descriptor: Int32, processLockPath: String) {
        self.descriptor = descriptor
        self.processLockPath = processLockPath
    }

    static func acquire(beside fileURL: URL) throws -> RestoreOnlyHardwareTrialOperationLease {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let lockURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).operation.lock"
        )
        let processLockPath = canonicalTrialLockPath(lockURL)
        guard RestoreOnlyHardwareTrialProcessLockRegistry.shared.acquire(processLockPath) else {
            throw RestoreOnlyHardwareTrialError.operationLeaseUnavailable
        }
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            RestoreOnlyHardwareTrialProcessLockRegistry.shared.release(processLockPath)
            throw RestoreOnlyHardwareTrialError.posix(
                operation: "open trial operation lease",
                code: errno
            )
        }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            RestoreOnlyHardwareTrialProcessLockRegistry.shared.release(processLockPath)
            throw RestoreOnlyHardwareTrialError.posix(
                operation: "inspect trial operation lease",
                code: code
            )
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            _ = Darwin.close(descriptor)
            RestoreOnlyHardwareTrialProcessLockRegistry.shared.release(processLockPath)
            throw RestoreOnlyHardwareTrialError.nonRegularFile
        }

        var fileLock = flock()
        fileLock.l_start = 0
        fileLock.l_len = 0
        fileLock.l_pid = 0
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_OFD_SETLK, &fileLock) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            RestoreOnlyHardwareTrialProcessLockRegistry.shared.release(processLockPath)
            if code == EACCES || code == EAGAIN {
                throw RestoreOnlyHardwareTrialError.operationLeaseUnavailable
            }
            throw RestoreOnlyHardwareTrialError.posix(
                operation: "lock trial operation lease",
                code: code
            )
        }
        return RestoreOnlyHardwareTrialOperationLease(
            descriptor: descriptor,
            processLockPath: processLockPath
        )
    }

    deinit {
        guard descriptor >= 0 else { return }
        var fileLock = flock()
        fileLock.l_start = 0
        fileLock.l_len = 0
        fileLock.l_pid = 0
        fileLock.l_type = Int16(F_UNLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_OFD_SETLK, &fileLock)
        _ = Darwin.close(descriptor)
        descriptor = -1
        RestoreOnlyHardwareTrialProcessLockRegistry.shared.release(processLockPath)
    }
}

public struct RestoreOnlyHardwareTrialSession: Sendable, Equatable {
    public let device: JournalDeviceIdentity
    public let featureIndex: UInt8
    public let featureVersion: UInt8
    public let connectionEpoch: UInt64
    public let matchingDeviceCount: Int
    public let outputReportByteCount: Int

    public init(
        device: JournalDeviceIdentity,
        featureIndex: UInt8,
        featureVersion: UInt8,
        connectionEpoch: UInt64,
        matchingDeviceCount: Int,
        outputReportByteCount: Int
    ) {
        self.device = device
        self.featureIndex = featureIndex
        self.featureVersion = featureVersion
        self.connectionEpoch = connectionEpoch
        self.matchingDeviceCount = matchingDeviceCount
        self.outputReportByteCount = outputReportByteCount
    }
}

private extension RestoreOnlyHardwareTrialRecord {
    func matches(_ session: RestoreOnlyHardwareTrialSession) -> Bool {
        device.isSafeRecoveryMatch(session.device)
            && featureIndex == session.featureIndex
            && featureVersion == session.featureVersion
            && connectionEpoch == session.connectionEpoch
            && session.matchingDeviceCount == 1
            && session.outputReportByteCount == HIDPP20LongMessage.byteCount
    }

    func matchesFreshRecoverySession(_ session: RestoreOnlyHardwareTrialSession) -> Bool {
        device.isSafeRecoveryMatch(session.device)
            && featureIndex == session.featureIndex
            && featureVersion == session.featureVersion
            && session.matchingDeviceCount == 1
            && session.outputReportByteCount == HIDPP20LongMessage.byteCount
    }
}

public protocol RestoreOnlyHardwareTrialTransport: Sendable {
    func currentSession() async throws -> RestoreOnlyHardwareTrialSession
    func readPrecisionReporting(
        request: HIDPP20LongMessage,
        expectedSession: RestoreOnlyHardwareTrialSession
    ) async throws -> DeviceTransactionWireState
    func setPrecisionTemporaryDiversionOff(
        request: HIDPP20LongMessage,
        expectedSession: RestoreOnlyHardwareTrialSession
    ) async throws -> HIDPP20LongMessage
}

public protocol RestoreOnlyHardwareTrialBaselineReader: Sendable {
    func readLiveBaseline() async throws -> Data
}

public actor RestoreOnlyHardwareTrialRunner {
    private let repository: DurableRestoreOnlyHardwareTrialRepository
    private let transport: any RestoreOnlyHardwareTrialTransport
    private let baselineReader: any RestoreOnlyHardwareTrialBaselineReader
    private let liveJournalURL: URL
    private let preacquiredDeviceOperationLease: MXErgoDeviceOperationLease?
    private var setAttempted = false

    public init(
        repository: DurableRestoreOnlyHardwareTrialRepository,
        transport: any RestoreOnlyHardwareTrialTransport,
        baselineReader: any RestoreOnlyHardwareTrialBaselineReader,
        liveJournalURL: URL,
        preacquiredDeviceOperationLease: MXErgoDeviceOperationLease? = nil
    ) {
        self.repository = repository
        self.transport = transport
        self.baselineReader = baselineReader
        self.liveJournalURL = liveJournalURL
        self.preacquiredDeviceOperationLease = preacquiredDeviceOperationLease
    }

    public func install(_ prepared: RestoreOnlyHardwareTrialRecord) async throws {
        guard prepared.phase == .prepared, prepared.revision == 0 else {
            throw RestoreOnlyHardwareTrialError.invalidPhase
        }
        _ = try await repository.commit(prepared, expectedRevision: nil)
    }

    public func runExplicitlyConfirmed() async throws -> RestoreOnlyHardwareTrialRecord {
        let deviceOperationLease = try preacquiredDeviceOperationLease
            ?? MXErgoDeviceOperationLease.acquire(beside: liveJournalURL)
        guard deviceOperationLease.protects(journalURL: liveJournalURL) else {
            throw RestoreOnlyHardwareTrialError.operationLeaseUnavailable
        }
        defer { withExtendedLifetime(deviceOperationLease) {} }
        let operationLease = try await repository.acquireOperationLease()
        defer { withExtendedLifetime(operationLease) {} }
        guard !setAttempted,
              let prepared = try await repository.loadValidated(),
              prepared.phase == .prepared else {
            throw RestoreOnlyHardwareTrialError.invalidPhase
        }
        let session = try await transport.currentSession()
        guard prepared.matches(session) else {
            throw RestoreOnlyHardwareTrialError.sessionChanged
        }
        let verificationRequest = try HIDPP20LongMessage(
            bytes: prepared.verificationRequestBytes
        )
        let preflight = try await transport.readPrecisionReporting(
            request: verificationRequest,
            expectedSession: session
        )
        guard preflight == prepared.preflightState else {
            throw RestoreOnlyHardwareTrialError.preflightMismatch
        }
        guard try await transport.currentSession() == session else {
            throw RestoreOnlyHardwareTrialError.sessionChanged
        }
        try prepared.validateSourceBaseline(
            try await baselineReader.readLiveBaseline()
        )

        let armed = try RestoreOnlyHardwareTrialReducer.arm(prepared)
        let receipt = try await repository.commit(
            armed,
            expectedRevision: prepared.revision
        )
        let setRequest = try HIDPP20LongMessage(bytes: armed.setRequestBytes)
        guard try await transport.currentSession() == session else {
            await persistOutcomeUnknown(
                fallback: armed,
                detail: "Session changed after durable arming"
            )
            throw RestoreOnlyHardwareTrialError.sessionChanged
        }
        do {
            _ = try await repository.consumeArmedAuthorization(
                receipt,
                request: setRequest,
                expectedSession: session
            )
            try Task.checkCancellation()
        } catch {
            await persistOutcomeUnknown(
                fallback: armed,
                detail: "Authorization was consumed or invalidated before dispatch: \(error)"
            )
            throw error
        }

        // This assignment happens before entering the transport call. Any
        // return path is therefore permanently ineligible for a second SET.
        setAttempted = true
        let acknowledgement: HIDPP20LongMessage
        do {
            acknowledgement = try await transport.setPrecisionTemporaryDiversionOff(
                request: setRequest,
                expectedSession: session
            )
            try Task.checkCancellation()
        } catch {
            await persistOutcomeUnknown(
                fallback: armed,
                detail: "SET transport outcome is unknown: \(error)"
            )
            throw RestoreOnlyHardwareTrialError.outcomeUnknown(String(describing: error))
        }

        let acknowledged: RestoreOnlyHardwareTrialRecord
        do {
            acknowledged = try RestoreOnlyHardwareTrialReducer.acknowledge(
                armed,
                responseBytes: acknowledgement.bytes
            )
            _ = try await repository.commit(
                acknowledged,
                expectedRevision: armed.revision
            )
        } catch {
            await persistOutcomeUnknown(
                fallback: armed,
                detail: "SET acknowledgement or its durable commit failed: \(error)"
            )
            throw RestoreOnlyHardwareTrialError.outcomeUnknown(String(describing: error))
        }

        let observation: DeviceTransactionWireState
        do {
            try Task.checkCancellation()
            guard try await transport.currentSession() == session else {
                throw RestoreOnlyHardwareTrialError.sessionChanged
            }
            observation = try await transport.readPrecisionReporting(
                request: verificationRequest,
                expectedSession: session
            )
            try acknowledged.validateSourceBaseline(
                try await baselineReader.readLiveBaseline()
            )
        } catch {
            await persistOutcomeUnknown(
                fallback: acknowledged,
                detail: "Independent verification could not be completed: \(error)"
            )
            throw RestoreOnlyHardwareTrialError.outcomeUnknown(String(describing: error))
        }

        let final = try RestoreOnlyHardwareTrialReducer.verify(
            acknowledged,
            observation: observation
        )
        do {
            _ = try await repository.commit(final, expectedRevision: acknowledged.revision)
        } catch {
            // The terminal replacement may or may not be durable. Never send
            // again; a fresh process must reopen and classify the exact bytes.
            throw RestoreOnlyHardwareTrialError.outcomeUnknown(
                "Terminal trial commit is indeterminate: \(error)"
            )
        }
        guard final.phase == .baselineVerified else {
            throw RestoreOnlyHardwareTrialError.verificationMismatch
        }
        return final
    }

    private func persistOutcomeUnknown(
        fallback: RestoreOnlyHardwareTrialRecord,
        detail: String
    ) async {
        let durable = (try? await repository.loadValidated()) ?? fallback
        guard durable.transactionID == fallback.transactionID,
              durable.attemptID == fallback.attemptID,
              (durable.phase == .armedMayHaveDispatched
                || durable.phase == .acknowledged) else {
            return
        }
        guard let unknown = try? RestoreOnlyHardwareTrialReducer.markOutcomeUnknown(
            durable,
            detail: detail
        ) else { return }
        _ = try? await repository.commit(
            unknown,
            expectedRevision: durable.revision
        )
    }
}

public struct RestoreOnlyHardwareTrialSimulationReport: Sendable, Equatable {
    public let finalPhase: RestoreOnlyHardwareTrialPhase
    public let durableCommitCount: Int
    public let setAttemptCount: Int
    public let readBackCount: Int
    public let liveBaselineReadCount: Int
    public let operationLeaseCount: Int
    public let setRequestBytes: [UInt8]
    public let verificationRequestBytes: [UInt8]

    public init(
        finalPhase: RestoreOnlyHardwareTrialPhase,
        durableCommitCount: Int,
        setAttemptCount: Int,
        readBackCount: Int,
        liveBaselineReadCount: Int,
        operationLeaseCount: Int,
        setRequestBytes: [UInt8],
        verificationRequestBytes: [UInt8]
    ) {
        self.finalPhase = finalPhase
        self.durableCommitCount = durableCommitCount
        self.setAttemptCount = setAttemptCount
        self.readBackCount = readBackCount
        self.liveBaselineReadCount = liveBaselineReadCount
        self.operationLeaseCount = operationLeaseCount
        self.setRequestBytes = setRequestBytes
        self.verificationRequestBytes = verificationRequestBytes
    }
}

public enum RestoreOnlyHardwareTrialSimulation {
    public static func run(
        sourceBaselineData: Data,
        currentFeature: HIDPP20FeatureDescriptor,
        connectionEpoch: UInt64
    ) async throws -> RestoreOnlyHardwareTrialSimulationReport {
        let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
            sourceBaselineData: sourceBaselineData,
            currentFeature: currentFeature,
            connectionEpoch: connectionEpoch
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mx-ergo-restore-trial-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DurableRestoreOnlyHardwareTrialRepository(
            fileURL: directory.appendingPathComponent("restore-only-hardware-trial.json")
        )
        let session = RestoreOnlyHardwareTrialSession(
            device: prepared.device,
            featureIndex: prepared.featureIndex,
            featureVersion: prepared.featureVersion,
            connectionEpoch: prepared.connectionEpoch,
            matchingDeviceCount: 1,
            outputReportByteCount: HIDPP20LongMessage.byteCount
        )
        let transport = RestoreOnlyHardwareTrialSimulationTransport(
            session: session,
            state: prepared.preflightState
        )
        let baselineReader = RestoreOnlyHardwareTrialSimulationBaselineReader(
            data: sourceBaselineData
        )
        let runner = RestoreOnlyHardwareTrialRunner(
            repository: repository,
            transport: transport,
            baselineReader: baselineReader,
            liveJournalURL: directory.appendingPathComponent(
                "device-state-journal.json"
            )
        )
        try await runner.install(prepared)
        let final = try await runner.runExplicitlyConfirmed()
        return RestoreOnlyHardwareTrialSimulationReport(
            finalPhase: final.phase,
            durableCommitCount: 4,
            setAttemptCount: await transport.setCount,
            readBackCount: await transport.readCount,
            liveBaselineReadCount: await baselineReader.readCount,
            operationLeaseCount: 1,
            setRequestBytes: prepared.setRequestBytes,
            verificationRequestBytes: prepared.verificationRequestBytes
        )
    }
}

private actor RestoreOnlyHardwareTrialSimulationBaselineReader:
    RestoreOnlyHardwareTrialBaselineReader
{
    let data: Data
    private(set) var readCount = 0

    init(data: Data) {
        self.data = data
    }

    func readLiveBaseline() -> Data {
        readCount += 1
        return data
    }
}

private actor RestoreOnlyHardwareTrialSimulationTransport: RestoreOnlyHardwareTrialTransport {
    let session: RestoreOnlyHardwareTrialSession
    var state: DeviceTransactionWireState
    private(set) var setCount = 0
    private(set) var readCount = 0

    init(session: RestoreOnlyHardwareTrialSession, state: DeviceTransactionWireState) {
        self.session = session
        self.state = state
    }

    func currentSession() -> RestoreOnlyHardwareTrialSession { session }

    func readPrecisionReporting(
        request: HIDPP20LongMessage,
        expectedSession: RestoreOnlyHardwareTrialSession
    ) throws -> DeviceTransactionWireState {
        guard expectedSession == session,
              request.functionID == 2,
              request.parameters[0] == 0,
              request.parameters[1] == 0xED else {
            throw RestoreOnlyHardwareTrialError.invalidPacket
        }
        readCount += 1
        return state
    }

    func setPrecisionTemporaryDiversionOff(
        request: HIDPP20LongMessage,
        expectedSession: RestoreOnlyHardwareTrialSession
    ) throws -> HIDPP20LongMessage {
        guard expectedSession == session,
              request.functionID == 3,
              Array(request.parameters.prefix(5)) == [0, 0xED, 0x02, 0, 0] else {
            throw RestoreOnlyHardwareTrialError.invalidPacket
        }
        setCount += 1
        return request
    }
}
