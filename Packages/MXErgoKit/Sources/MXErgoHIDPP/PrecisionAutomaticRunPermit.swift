import Foundation

package enum PrecisionAutomaticRunError: Error, Sendable, Equatable {
    case revoked
    case invalidConsent
    case operationAlreadyUsed
    case rejectedBeforeDispatch
}

/// In-memory authority for one launch. Persisted consent is only its input.
/// Revocation and the final physical mutation claim share one lock.
package final class PrecisionAutomaticRunPermit: @unchecked Sendable, Equatable {
    package static func == (lhs: PrecisionAutomaticRunPermit, rhs: PrecisionAutomaticRunPermit) -> Bool { lhs === rhs }
    package let consent: PrecisionSeamlessRestartConsent
    private let lock = NSLock()
    private let consentIsCurrent: @Sendable () -> Bool
    private var revoked = false
    private var used: [PrecisionTemporaryDiversionOperation] = []
    private var dispatchClaimed = false
    private var initialOperationFinished = false

    package init(consent: PrecisionSeamlessRestartConsent, consentIsCurrent: @escaping @Sendable () -> Bool) {
        self.consent = consent
        self.consentIsCurrent = consentIsCurrent
    }

    package func validate() throws {
        try lock.withLock {
            guard !revoked, consent.enabled, consentIsCurrent() else { throw PrecisionAutomaticRunError.revoked }
        }
    }

    package func reserve(_ operation: PrecisionTemporaryDiversionOperation,
                         readiness: PrecisionTemporaryDiversionReadinessSnapshot) throws {
        try lock.withLock {
            guard !revoked, consentIsCurrent(), consent.enabled, consent.matches(readiness),
                  operation == .activate || operation == .resume else { throw PrecisionAutomaticRunError.invalidConsent }
            guard !used.contains(operation), !(operation == .resume && used.contains(.activate)) else {
                throw PrecisionAutomaticRunError.operationAlreadyUsed
            }
            used.append(operation)
            initialOperationFinished = false
        }
    }

    /// Later explicit restoration must not depend on the automatic preference.
    package func validateInitialOperation() throws {
        try lock.withLock {
            guard initialOperationFinished || dispatchClaimed || (!revoked && consentIsCurrent()) else { throw PrecisionAutomaticRunError.revoked }
        }
    }
    package func finishInitialOperation() { lock.withLock { initialOperationFinished = true } }

    /// Claim is the may-have-dispatched boundary, before the blocking call.
    /// The lock is never held while the physical call executes.
    package func claimMutation() throws {
        try lock.withLock {
            guard !revoked, consentIsCurrent(), used.contains(.activate), !dispatchClaimed else {
                throw PrecisionAutomaticRunError.rejectedBeforeDispatch
            }
            dispatchClaimed = true
        }
    }

    @discardableResult package func revoke() -> Bool {
        lock.withLock { revoked = true; return dispatchClaimed }
    }
}
