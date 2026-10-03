import Foundation

package enum PrecisionWakeResumePermitError: Error, Sendable, Equatable {
    case invalidBinding
    case alreadyUsed
    case disconnected
}

/// A callback-safe witness shared by the endpoint and the owner. The endpoint
/// marks it synchronously, before either actor receives its queued disconnect
/// notification, so a sleep rollover cannot release its restart fence through
/// that scheduling gap.
package final class PrecisionRuntimeDisconnectWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var disconnected = false

    package init() {}

    package func markDisconnected() {
        lock.withLock { disconnected = true }
    }

    package var wasDisconnected: Bool {
        lock.withLock { disconnected }
    }
}

/// Exact, non-persisted evidence carried from the closed pre-sleep endpoint to
/// one fresh post-wake GET-only admission. It deliberately contains no SET or
/// mutation claim.
package struct PrecisionWakeResumeBinding: Sendable, Equatable {
    package let launchID: UUID
    package let sleepCycleID: UUID
    package let priorObserverRunID: UUID
    package let newObserverRunID: UUID?
    package let sourceBaselineCanonicalPath: String
    package let runtimeJournalCanonicalPath: String
    package let sourceBaselineTransactionID: UUID
    package let sourceBaselineSHA256: String
    package let runtimeJournalData: Data
    package let runtimeEnvelope: DeviceTransactionEnvelope
    package let runtimeJournalSHA256: String

    package init(
        launchID: UUID,
        sleepCycleID: UUID,
        priorObserverRunID: UUID,
        newObserverRunID: UUID? = nil,
        sourceBaselineCanonicalPath: String,
        runtimeJournalCanonicalPath: String,
        sourceBaselineTransactionID: UUID,
        sourceBaselineSHA256: String,
        runtimeJournalData: Data,
        runtimeEnvelope: DeviceTransactionEnvelope,
        runtimeJournalSHA256: String
    ) {
        self.launchID = launchID
        self.sleepCycleID = sleepCycleID
        self.priorObserverRunID = priorObserverRunID
        self.newObserverRunID = newObserverRunID
        self.sourceBaselineCanonicalPath = sourceBaselineCanonicalPath
        self.runtimeJournalCanonicalPath = runtimeJournalCanonicalPath
        self.sourceBaselineTransactionID = sourceBaselineTransactionID
        self.sourceBaselineSHA256 = sourceBaselineSHA256
        self.runtimeJournalData = runtimeJournalData
        self.runtimeEnvelope = runtimeEnvelope
        self.runtimeJournalSHA256 = runtimeJournalSHA256
    }
}

/// One-use and resume-only. Its parent launch permit keeps persisted opt-in
/// revocable, while the exact binding prevents a wake token from authorizing a
/// different observer run, journal generation, device, or operation.
package final class PrecisionWakeResumePermit: @unchecked Sendable {
    private let lock = NSLock()
    private let parent: PrecisionAutomaticRunPermit
    private let disconnectWitness: PrecisionRuntimeDisconnectWitness
    private let binding: PrecisionWakeResumeBinding
    private var reserved = false
    private var initialOperationFinished = false

    package init(
        parent: PrecisionAutomaticRunPermit,
        disconnectWitness: PrecisionRuntimeDisconnectWitness,
        binding: PrecisionWakeResumeBinding
    ) {
        self.parent = parent
        self.disconnectWitness = disconnectWitness
        self.binding = binding
    }

    package var sleepCycleID: UUID { binding.sleepCycleID }
    package var priorObserverRunID: UUID { binding.priorObserverRunID }

    package func validate() throws {
        try parent.validate()
        guard !disconnectWitness.wasDisconnected else {
            throw PrecisionWakeResumePermitError.disconnected
        }
    }

    package func reserve(matching candidate: PrecisionWakeResumeBinding) throws {
        try validate()
        try lock.withLock {
            guard !reserved else {
                throw PrecisionWakeResumePermitError.alreadyUsed
            }
            reserved = true
            guard binding.newObserverRunID == nil,
                  candidate.newObserverRunID != nil,
                  candidate.newObserverRunID != binding.priorObserverRunID,
                  candidate.launchID == binding.launchID,
                  candidate.sleepCycleID == binding.sleepCycleID,
                  candidate.priorObserverRunID == binding.priorObserverRunID,
                  candidate.sourceBaselineCanonicalPath
                    == binding.sourceBaselineCanonicalPath,
                  candidate.runtimeJournalCanonicalPath
                    == binding.runtimeJournalCanonicalPath,
                  candidate.sourceBaselineTransactionID
                    == binding.sourceBaselineTransactionID,
                  candidate.sourceBaselineSHA256 == binding.sourceBaselineSHA256,
                  candidate.runtimeJournalData == binding.runtimeJournalData,
                  candidate.runtimeEnvelope == binding.runtimeEnvelope,
                  candidate.runtimeJournalSHA256 == binding.runtimeJournalSHA256 else {
                throw PrecisionWakeResumePermitError.invalidBinding
            }
        }
        try validate()
    }

    package func validateInitialOperation() throws {
        try validate()
        try lock.withLock {
            guard reserved || initialOperationFinished else {
                throw PrecisionWakeResumePermitError.invalidBinding
            }
        }
    }

    package func finishInitialOperation() {
        lock.withLock { initialOperationFinished = true }
    }
}
