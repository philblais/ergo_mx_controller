import CryptoKit
import Darwin
import Foundation
import MXErgoHIDPP

package enum PrecisionRuntimeJournalError: Error, Sendable, Equatable {
    case invalidRequestBinding
    case sourceAndRuntimeJournalCollide
    case journalsDoNotShareCanonicalDirectory
    case sourceBaselineMissing
    case sourceBaselineNotRegular
    case sourceBaselineChanged
    case sourceBaselineMismatch
    case operationLeaseMismatch
    case runtimeJournalNotRegular
    case runtimeJournalTooLarge
    case existingRuntimeJournalMismatch
    case commitReceiptMismatch
}

package struct PrecisionRuntimeJournalSnapshot: Sendable, Equatable {
    package let data: Data
    package let envelope: DeviceTransactionEnvelope
    package let sha256: String
}

/// One canonical source supplies both coordinator persistence and an atomic
/// envelope-plus-digest snapshot. A runtime can therefore never bind a
/// repository from one file to authorization bytes from another.
package protocol PrecisionRuntimeJournalSource:
    DeviceTransactionJournalRepository {
    var journalURL: URL { get }
    func loadValidatedSnapshot() async throws -> PrecisionRuntimeJournalSnapshot
}

package struct PrecisionRuntimeJournalBootstrapRequest: Sendable {
    package let plan: PrecisionTemporaryDiversionPlan
    package let session: DeviceTransactionSession
    package let rootGeneration: UInt64
    package let sourceBaselineURL: URL
    package let sourceBaselineSHA256: String
    package let sourceBaselineTransactionID: UUID
    package let runtimeJournalURL: URL

    package init(
        plan: PrecisionTemporaryDiversionPlan,
        session: DeviceTransactionSession,
        rootGeneration: UInt64,
        sourceBaselineURL: URL,
        sourceBaselineSHA256: String,
        sourceBaselineTransactionID: UUID,
        runtimeJournalURL: URL
    ) {
        self.plan = plan
        self.session = session
        self.rootGeneration = rootGeneration
        self.sourceBaselineURL = sourceBaselineURL
        self.sourceBaselineSHA256 = sourceBaselineSHA256
        self.sourceBaselineTransactionID = sourceBaselineTransactionID
        self.runtimeJournalURL = runtimeJournalURL
    }
}

package enum PrecisionRuntimeJournalBootstrapDisposition: Sendable, Equatable {
    case created
    case reused(DeviceTransactionStatus)
}

package struct PrecisionRuntimeJournalContext: Sendable {
    package let plan: PrecisionTemporaryDiversionPlan
    package let session: DeviceTransactionSession
    package let rootGeneration: UInt64
    package let sourceBaselineSHA256: String
    package let sourceBaselineTransactionID: UUID
    package let source: any PrecisionRuntimeJournalSource
    package let snapshot: PrecisionRuntimeJournalSnapshot
    package let disposition: PrecisionRuntimeJournalBootstrapDisposition
}

package enum PrecisionRuntimeJournalBootstrap {
    typealias MakeSource = @Sendable (URL) -> any PrecisionRuntimeJournalSource

    /// Read-only authorization preflight. It validates the exact source
    /// baseline and, when present, returns the exact existing runtime bytes,
    /// envelope, and digest without creating or rewriting either journal.
    package static func inspect(
        _ request: PrecisionRuntimeJournalBootstrapRequest
    ) throws -> PrecisionRuntimeJournalSnapshot? {
        try validateRequest(request)
        guard let sourceBaselineData = try readRegularFile(
            at: request.sourceBaselineURL,
            missingError: .sourceBaselineMissing,
            nonRegularError: .sourceBaselineNotRegular
        ) else {
            throw PrecisionRuntimeJournalError.sourceBaselineMissing
        }
        guard sha256(sourceBaselineData) == request.sourceBaselineSHA256 else {
            throw PrecisionRuntimeJournalError.sourceBaselineMismatch
        }
        let baseline = try JSONDecoder().decode(
            DeviceStateJournal.self,
            from: sourceBaselineData
        )
        try baseline.validateForRecovery()
        guard !baseline.requiresRecovery,
              baseline.transactionID == request.sourceBaselineTransactionID,
              baseline.device == request.plan.device,
              baseline.featureID == request.session.featureID,
              baseline.feature.index == request.plan.featureIndex,
              baseline.feature.version == request.plan.featureVersion,
              baseline.device.isSafeRecoveryMatch(request.session.device),
              let precision = baseline.controls.first(where: {
                  $0.controlInfo.controlID
                      == PrecisionTemporaryDiversionPlan.controlID
              }),
              try DeviceTransactionWireState(
                  rawParameters: precision.baselineReporting.rawParameters
              ) == request.plan.baseline else {
            throw PrecisionRuntimeJournalError.sourceBaselineMismatch
        }

        guard let runtimeData = try readRegularFile(
            at: request.runtimeJournalURL,
            missingError: .sourceBaselineMissing,
            nonRegularError: .runtimeJournalNotRegular
        ) else {
            return nil
        }
        let envelope = try JSONDecoder().decode(
            DeviceTransactionEnvelope.self,
            from: runtimeData
        )
        let expected = try DeviceTransactionEnvelope(
            baselineJournal: baseline
        )
        try validateExisting(
            envelope,
            expected: expected,
            request: request
        )
        return PrecisionRuntimeJournalSnapshot(
            data: runtimeData,
            envelope: envelope,
            sha256: sha256(runtimeData)
        )
    }

    /// Test-only convenience. Production package peers must supply the one
    /// session lease acquired before host handoff and retain it through device
    /// close; they cannot let bootstrap acquire a short-lived substitute.
    static func prepare(
        _ request: PrecisionRuntimeJournalBootstrapRequest
    ) async throws -> PrecisionRuntimeJournalContext {
        let operationLease = try MXErgoDeviceOperationLease.acquire(
            beside: request.runtimeJournalURL
        )
        defer { withExtendedLifetime(operationLease) {} }
        return try await prepare(
            request,
            operationLease: operationLease
        )
    }

    package static func prepare(
        _ request: PrecisionRuntimeJournalBootstrapRequest,
        operationLease: MXErgoDeviceOperationLease
    ) async throws -> PrecisionRuntimeJournalContext {
        try await prepare(
            request,
            operationLease: operationLease,
            makeSource: { journalURL in
                DurablePrecisionRuntimeJournalSource(journalURL: journalURL)
            }
        )
    }

    static func prepare(
        _ request: PrecisionRuntimeJournalBootstrapRequest,
        makeSource: MakeSource
    ) async throws -> PrecisionRuntimeJournalContext {
        let operationLease = try MXErgoDeviceOperationLease.acquire(
            beside: request.runtimeJournalURL
        )
        defer { withExtendedLifetime(operationLease) {} }
        return try await prepare(
            request,
            operationLease: operationLease,
            makeSource: makeSource
        )
    }

    static func prepare(
        _ request: PrecisionRuntimeJournalBootstrapRequest,
        operationLease: MXErgoDeviceOperationLease,
        makeSource: MakeSource
    ) async throws -> PrecisionRuntimeJournalContext {
        try validateRequest(request)
        guard operationLease.protects(
            journalURL: request.runtimeJournalURL
        ) else {
            throw PrecisionRuntimeJournalError.operationLeaseMismatch
        }

        guard let sourceBaselineData = try readRegularFile(
            at: request.sourceBaselineURL,
            missingError: .sourceBaselineMissing,
            nonRegularError: .sourceBaselineNotRegular
        ) else {
            throw PrecisionRuntimeJournalError.sourceBaselineMissing
        }
        guard sha256(sourceBaselineData) == request.sourceBaselineSHA256 else {
            throw PrecisionRuntimeJournalError.sourceBaselineMismatch
        }
        let baseline = try JSONDecoder().decode(
            DeviceStateJournal.self,
            from: sourceBaselineData
        )
        try baseline.validateForRecovery()
        guard !baseline.requiresRecovery,
              baseline.transactionID == request.sourceBaselineTransactionID,
              baseline.device == request.plan.device,
              baseline.featureID == request.session.featureID,
              baseline.feature.index == request.plan.featureIndex,
              baseline.feature.version == request.plan.featureVersion,
              baseline.device.isSafeRecoveryMatch(request.session.device),
              let precision = baseline.controls.first(where: {
                  $0.controlInfo.controlID
                      == PrecisionTemporaryDiversionPlan.controlID
              }),
              try DeviceTransactionWireState(
                  rawParameters: precision.baselineReporting.rawParameters
              ) == request.plan.baseline else {
            throw PrecisionRuntimeJournalError.sourceBaselineMismatch
        }

        let expected = try DeviceTransactionEnvelope(
            baselineJournal: baseline
        )
        let source = makeSource(request.runtimeJournalURL)
        guard source.journalURL.standardizedFileURL.resolvingSymlinksInPath()
                == request.runtimeJournalURL.standardizedFileURL
                    .resolvingSymlinksInPath() else {
            throw PrecisionRuntimeJournalError.existingRuntimeJournalMismatch
        }
        let snapshot: PrecisionRuntimeJournalSnapshot
        let disposition: PrecisionRuntimeJournalBootstrapDisposition
        if FileManager.default.fileExists(atPath: request.runtimeJournalURL.path) {
            snapshot = try await source.loadValidatedSnapshot()
            try validateExisting(
                snapshot.envelope,
                expected: expected,
                request: request
            )
            disposition = .reused(snapshot.envelope.status)
        } else {
            let receipt = try await source.commit(
                expected,
                expectedRevision: nil
            )
            snapshot = try await source.loadValidatedSnapshot()
            guard receipt.transactionID == snapshot.envelope.transactionID,
                  receipt.revision == snapshot.envelope.revision,
                  receipt.sha256 == snapshot.sha256 else {
                throw PrecisionRuntimeJournalError.commitReceiptMismatch
            }
            try validateExisting(
                snapshot.envelope,
                expected: expected,
                request: request
            )
            disposition = .created
        }

        guard try readRegularFile(
            at: request.sourceBaselineURL,
            missingError: .sourceBaselineMissing,
            nonRegularError: .sourceBaselineNotRegular
        ) == sourceBaselineData else {
            throw PrecisionRuntimeJournalError.sourceBaselineChanged
        }

        return PrecisionRuntimeJournalContext(
            plan: request.plan,
            session: request.session,
            rootGeneration: request.rootGeneration,
            sourceBaselineSHA256: request.sourceBaselineSHA256,
            sourceBaselineTransactionID: request.sourceBaselineTransactionID,
            source: source,
            snapshot: snapshot,
            disposition: disposition
        )
    }

    private static func validateRequest(
        _ request: PrecisionRuntimeJournalBootstrapRequest
    ) throws {
        let session = request.session
        let hashBytes = request.sourceBaselineSHA256.utf8
        guard request.plan.device == session.device,
              session.device.vendorID == 0x046D,
              session.device.productID == 0xB01D,
              session.device.transport == "Bluetooth Low Energy",
              session.device.hasStableDiscriminator,
              session.device.firmwareIdentity?.isEmpty == false,
              session.featureID == ReprogControlsV4.featureID,
              session.featureVersion == 3,
              request.plan.featureVersion == session.featureVersion,
              request.plan.featureIndex == session.featureIndex,
              session.featureIndex != 0,
              session.featureIndex != 0xFF,
              hashBytes.count == 64,
              hashBytes.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw PrecisionRuntimeJournalError.invalidRequestBinding
        }

        let source = request.sourceBaselineURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let runtime = request.runtimeJournalURL.standardizedFileURL
            .resolvingSymlinksInPath()
        guard source.path != runtime.path else {
            throw PrecisionRuntimeJournalError.sourceAndRuntimeJournalCollide
        }
        guard source.deletingLastPathComponent().path
                == runtime.deletingLastPathComponent().path else {
            throw PrecisionRuntimeJournalError
                .journalsDoNotShareCanonicalDirectory
        }
    }

    private static func validateExisting(
        _ actual: DeviceTransactionEnvelope,
        expected: DeviceTransactionEnvelope,
        request: PrecisionRuntimeJournalBootstrapRequest
    ) throws {
        try actual.validate()
        let actualBaselines = actual.controls.map {
            RuntimeControlBaseline(
                index: $0.controlIndex,
                id: $0.controlID,
                state: $0.baseline
            )
        }
        let expectedBaselines = expected.controls.map {
            RuntimeControlBaseline(
                index: $0.controlIndex,
                id: $0.controlID,
                state: $0.baseline
            )
        }
        guard actual.sourceBaselineTransactionID
                == request.sourceBaselineTransactionID,
              actual.device == expected.device,
              actual.featureID == expected.featureID,
              actual.featureVersion == expected.featureVersion,
              actual.featureIndex == expected.featureIndex,
              actual.isSafeSessionMatch(request.session),
              actualBaselines == expectedBaselines else {
            throw PrecisionRuntimeJournalError.existingRuntimeJournalMismatch
        }
    }

    private struct RuntimeControlBaseline: Equatable {
        let index: UInt8
        let id: UInt16
        let state: DeviceTransactionWireState
    }
}

actor DurablePrecisionRuntimeJournalSource:
    PrecisionRuntimeJournalSource {
    nonisolated let journalURL: URL
    private let repository: DurableDeviceTransactionFileRepository

    init(journalURL: URL) {
        self.journalURL = journalURL
        repository = DurableDeviceTransactionFileRepository(fileURL: journalURL)
    }

    init(
        journalURL: URL,
        repository: DurableDeviceTransactionFileRepository
    ) {
        self.journalURL = journalURL
        self.repository = repository
    }

    func loadValidated() async throws -> DeviceTransactionEnvelope? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            return nil
        }
        return try await loadValidatedSnapshot().envelope
    }

    func commit(
        _ next: DeviceTransactionEnvelope,
        expectedRevision: UInt64?
    ) async throws -> DeviceTransactionDurableCommitReceipt {
        try await repository.commit(next, expectedRevision: expectedRevision)
    }

    func loadValidatedSnapshot() async throws -> PrecisionRuntimeJournalSnapshot {
        guard let data = try readRegularFile(
            at: journalURL,
            missingError: .sourceBaselineMissing,
            nonRegularError: .runtimeJournalNotRegular
        ) else {
            throw DeviceTransactionCoordinatorError.missingTransactionJournal
        }
        let envelope = try JSONDecoder().decode(
            DeviceTransactionEnvelope.self,
            from: data
        )
        try envelope.validate()
        return PrecisionRuntimeJournalSnapshot(
            data: data,
            envelope: envelope,
            sha256: sha256(data)
        )
    }
}

private let maximumRuntimeJournalByteCount = 1_048_576

private func readRegularFile(
    at url: URL,
    missingError: PrecisionRuntimeJournalError,
    nonRegularError: PrecisionRuntimeJournalError
) throws -> Data? {
    var pathStatus = stat()
    guard Darwin.lstat(url.path, &pathStatus) == 0 else {
        if errno == ENOENT { return nil }
        throw missingError
    }
    guard pathStatus.st_mode & S_IFMT == S_IFREG else {
        throw nonRegularError
    }
    guard pathStatus.st_size >= 0,
          pathStatus.st_size <= maximumRuntimeJournalByteCount else {
        throw PrecisionRuntimeJournalError.runtimeJournalTooLarge
    }

    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw nonRegularError }
    defer { _ = Darwin.close(descriptor) }

    var openedStatus = stat()
    guard Darwin.fstat(descriptor, &openedStatus) == 0,
          openedStatus.st_mode & S_IFMT == S_IFREG,
          openedStatus.st_dev == pathStatus.st_dev,
          openedStatus.st_ino == pathStatus.st_ino,
          openedStatus.st_size >= 0,
          openedStatus.st_size <= maximumRuntimeJournalByteCount else {
        throw nonRegularError
    }

    var bytes = [UInt8](repeating: 0, count: Int(openedStatus.st_size))
    var offset = 0
    while offset < bytes.count {
        let remaining = bytes.count - offset
        let count = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(
                descriptor,
                buffer.baseAddress!.advanced(by: offset),
                remaining
            )
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw nonRegularError
        }
        guard count > 0 else { throw nonRegularError }
        offset += count
    }
    return Data(bytes)
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
