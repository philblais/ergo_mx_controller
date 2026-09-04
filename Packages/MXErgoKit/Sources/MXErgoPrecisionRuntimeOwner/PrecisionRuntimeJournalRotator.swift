import Foundation
import MXErgoHIDPP
import MXErgoPrecisionRuntimeJournal

/// Public facade over runtime-journal rotation.
///
/// A schema-v3 runtime journal models exactly one apply/restore lifecycle. Once
/// it reaches `completed` the admission policy permits neither activate nor
/// recover, and binding fails with nothing more informative than
/// `invalidIntent`. Rotation retires a spent journal by renaming it, so a fresh
/// one can bootstrap from the unchanged schema-v2 baseline.
///
/// This sends no HID command, opens no device, and never touches the schema-v2
/// baseline. It refuses any journal whose evidence a later recover could still
/// need. The underlying decision logic lives in the canonical journal module;
/// this type only widens its visibility to the executable.
public enum PrecisionRuntimeJournalRotator {
    /// Read-only verdict, safe to compute at any time. `nil` means there is no
    /// journal to rotate, which is already what a fresh bootstrap wants.
    public static func review(
        runtimeJournalURL: URL
    ) throws -> PrecisionRuntimeJournalRotationReview? {
        do {
            guard let review = try PrecisionRuntimeJournalRotation.review(
                runtimeJournalURL: runtimeJournalURL
            ) else {
                return nil
            }
            return PrecisionRuntimeJournalRotationReview(underlying: review)
        } catch {
            throw PrecisionRuntimeJournalRotationError(error)
        }
    }

    /// Archives the reviewed journal under the canonical device-operation
    /// lease, proving the bytes are still exactly the reviewed bytes first.
    ///
    /// The lease is acquired here rather than passed in because rotation is a
    /// file-only operation that runs while no runtime is admitted. It still
    /// takes the same lock every journal writer takes, so it cannot race a
    /// live lifecycle.
    public static func rotate(
        _ review: PrecisionRuntimeJournalRotationReview
    ) throws -> PrecisionRuntimeJournalRotationReceipt {
        do {
            let lease = try MXErgoDeviceOperationLease.acquire(
                beside: review.journalURL
            )
            defer { withExtendedLifetime(lease) {} }
            let receipt = try PrecisionRuntimeJournalRotation.rotate(
                review.underlying,
                operationLease: lease
            )
            return PrecisionRuntimeJournalRotationReceipt(
                archivedTransactionID: receipt.archivedTransactionID,
                archiveURL: receipt.archiveURL,
                archivedSHA256: receipt.archivedSHA256
            )
        } catch {
            throw PrecisionRuntimeJournalRotationError(error)
        }
    }
}

public struct PrecisionRuntimeJournalRotationReview: Sendable, Equatable {
    public var journalURL: URL { underlying.journalURL }
    public var archiveURL: URL { underlying.archiveURL }
    public var transactionID: UUID { underlying.transactionID }
    public var revision: UInt64 { underlying.revision }
    public var sha256: String { underlying.sha256 }

    /// Human-readable state, for the confirmation dialog. The caller gets the
    /// facts it must show a person before discarding durable evidence, without
    /// gaining the ability to construct a review of its own.
    public var summary: String {
        "transaction \(transactionID.uuidString), revision \(revision), "
            + "status \(underlying.status), Precision \(underlying.precisionPhase)"
    }

    fileprivate let underlying: PrecisionRuntimeJournalRotation.Review
}

public struct PrecisionRuntimeJournalRotationReceipt: Sendable, Equatable {
    public let archivedTransactionID: UUID
    public let archiveURL: URL
    public let archivedSHA256: String
}


/// Public projection of the journal module's failures. The package error type
/// stays internal so the executable cannot pattern-match on states it has no
/// business knowing about.
public enum PrecisionRuntimeJournalRotationError: Error, Sendable, Equatable {
    /// The journal still holds active, ambiguous, conflicted, or
    /// recovery-required evidence a later recover may depend on.
    case notRotatable
    case archiveAlreadyExists
    case changedAfterReview
    case notARegularFile
    case leaseUnavailable
    case failed(String)

    init(_ error: Error) {
        guard let journalError = error as? PrecisionRuntimeJournalError else {
            if error is MXErgoDeviceOperationLeaseError {
                self = .leaseUnavailable
            } else {
                self = .failed(String(describing: error))
            }
            return
        }
        switch journalError {
        case .runtimeJournalNotRotatable: self = .notRotatable
        case .rotationArchiveAlreadyExists: self = .archiveAlreadyExists
        case .rotationSourceChanged: self = .changedAfterReview
        case .runtimeJournalNotRegular: self = .notARegularFile
        case .operationLeaseMismatch: self = .leaseUnavailable
        default: self = .failed(String(describing: journalError))
        }
    }
}
