import Foundation
import MXErgoHIDPP

/// Retires a spent schema-v3 runtime journal so a new lifecycle can begin.
///
/// A runtime journal models exactly one apply/restore lifecycle. Once it
/// reaches `completed` the admission policy permits neither activate
/// (`prepared` + `baselineVerified`) nor recover, so without rotation a second
/// session is impossible and the failure surfaces only as `invalidIntent`.
///
/// Rotation is deliberately **not** part of bootstrap. Bootstrap runs inside an
/// already-authorized admission, and silently retiring durable evidence there
/// would let a single confirmation both discard a journal and open the device.
/// This is a separate, separately confirmed operation that performs no HID I/O
/// and never touches the schema-v2 baseline.
///
/// Only a provably spent journal may be rotated: every recovery-relevant
/// state — active, ambiguous, conflicted, recovery-required, or any dirty
/// control — is refused, because those are exactly the journals whose evidence
/// a later recover depends on.
package enum PrecisionRuntimeJournalRotation {
    /// Read-only verdict. Producing one performs no mutation, and it names the
    /// exact bytes it was derived from so the mutating step can prove the file
    /// has not changed since it was reviewed.
    package struct Review: Sendable, Equatable {
        package let journalURL: URL
        package let archiveURL: URL
        package let transactionID: UUID
        package let revision: UInt64
        package let sha256: String
        package let status: DeviceTransactionStatus
        package let precisionPhase: DeviceTransactionControlPhase
    }

    package struct Receipt: Sendable, Equatable {
        package let archivedTransactionID: UUID
        package let archiveURL: URL
        package let archivedSHA256: String
    }

    /// Reviews the journal without changing anything. Returns `nil` when there
    /// is no journal to rotate, which is already the state a fresh bootstrap
    /// wants.
    package static func review(
        runtimeJournalURL: URL
    ) throws -> Review? {
        guard let data = try readRegularFile(
            at: runtimeJournalURL,
            missingError: .runtimeJournalMissing,
            nonRegularError: .runtimeJournalNotRegular
        ) else {
            return nil
        }

        let envelope = try JSONDecoder().decode(
            DeviceTransactionEnvelope.self,
            from: data
        )
        try envelope.validate()
        try requireSpent(envelope)

        return Review(
            journalURL: runtimeJournalURL,
            archiveURL: archiveURL(
                for: runtimeJournalURL,
                transactionID: envelope.transactionID
            ),
            transactionID: envelope.transactionID,
            revision: envelope.revision,
            sha256: sha256(data),
            status: envelope.status,
            precisionPhase: try envelope.control(
                PrecisionTemporaryDiversionPlan.controlID
            ).phase
        )
    }

    /// Archives the reviewed journal under the canonical device-operation
    /// lease, after proving the bytes are still exactly the reviewed bytes.
    ///
    /// The journal is renamed, never deleted: it is the durable record of a
    /// completed hardware lifecycle and remains available for forensic audit.
    package static func rotate(
        _ review: Review,
        operationLease: MXErgoDeviceOperationLease
    ) throws -> Receipt {
        guard operationLease.protects(journalURL: review.journalURL) else {
            throw PrecisionRuntimeJournalError.operationLeaseMismatch
        }

        // Re-derive under the lease. A journal that changed between review and
        // rotation may have gained evidence a later recover would need.
        guard let current = try Self.review(runtimeJournalURL: review.journalURL),
              current == review else {
            throw PrecisionRuntimeJournalError.rotationSourceChanged
        }

        guard try readRegularFile(
            at: review.archiveURL,
            missingError: .rotationArchiveAlreadyExists,
            nonRegularError: .rotationArchiveAlreadyExists
        ) == nil else {
            throw PrecisionRuntimeJournalError.rotationArchiveAlreadyExists
        }

        do {
            try FileManager.default.moveItem(
                at: review.journalURL,
                to: review.archiveURL
            )
        } catch {
            throw PrecisionRuntimeJournalError.rotationFailed
        }

        // Prove the outcome rather than assuming the move did what was asked.
        guard try readRegularFile(
            at: review.journalURL,
            missingError: .runtimeJournalMissing,
            nonRegularError: .runtimeJournalNotRegular
        ) == nil else {
            throw PrecisionRuntimeJournalError.rotationFailed
        }
        guard let archived = try readRegularFile(
            at: review.archiveURL,
            missingError: .rotationFailed,
            nonRegularError: .rotationFailed
        ), sha256(archived) == review.sha256 else {
            throw PrecisionRuntimeJournalError.rotationFailed
        }

        return Receipt(
            archivedTransactionID: review.transactionID,
            archiveURL: review.archiveURL,
            archivedSHA256: review.sha256
        )
    }

    /// A journal is spent only when nothing about it could still matter to a
    /// recover. Anything else is refused.
    private static func requireSpent(
        _ envelope: DeviceTransactionEnvelope
    ) throws {
        guard envelope.status == .completed else {
            throw PrecisionRuntimeJournalError.runtimeJournalNotRotatable
        }
        guard envelope.dirtyControlIDs.isEmpty else {
            throw PrecisionRuntimeJournalError.runtimeJournalNotRotatable
        }
        for control in envelope.controls {
            switch control.phase {
            case .baselineVerified, .restoredVerified:
                continue
            case .appliedVerified,
                 .applyMayHaveOccurred,
                 .restoreMayHaveOccurred,
                 .conflicted:
                throw PrecisionRuntimeJournalError.runtimeJournalNotRotatable
            }
        }
    }

    private static func archiveURL(
        for journalURL: URL,
        transactionID: UUID
    ) -> URL {
        journalURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(journalURL.deletingPathExtension().lastPathComponent)"
                    + ".completed-\(transactionID.uuidString).json",
                isDirectory: false
            )
    }
}
