import Foundation
import MXErgoHIDPP
import MXErgoPrecisionRuntimeJournal

package enum PrecisionSeamlessRestartDecision: Sendable, Equatable {
    case disabled
    case reviewRequired
    case activateAfterFreshBaseline
    case resumeWithFreshRead
    case archiveCompletedAndRefresh
}

/// Classifies durable evidence only. No decision enables audio or performs
/// effects. Completed-journal rotation must use its existing CAS review, then
/// collect new evidence; resume must classify a live GET before enabling audio.
package enum PrecisionSeamlessRestartPolicy {
    package static func review(
        consent: PrecisionSeamlessRestartConsent?,
        readiness: PrecisionTemporaryDiversionReadinessSnapshot,
        runtime: PrecisionRuntimeJournalSnapshot?
    ) -> PrecisionSeamlessRestartDecision {
        guard let consent, consent.enabled else { return .disabled }
        guard consent.matches(readiness) else { return .reviewRequired }
        guard let runtime else { return .activateAfterFreshBaseline }
        let envelope = runtime.envelope
        do {
            try envelope.validate()
            let control = try envelope.control(PrecisionTemporaryDiversionPlan.controlID)
            guard envelope.device == readiness.plan.device,
                  envelope.sourceBaselineTransactionID == readiness.sourceBaselineTransactionID,
                  envelope.featureIndex == readiness.plan.featureIndex,
                  envelope.featureVersion == readiness.plan.featureVersion,
                  control.baseline == readiness.plan.baseline,
                  !envelope.controls.contains(where: { $0.phase == .conflicted }),
                  envelope.dirtyControlIDs.allSatisfy({
                      $0 == PrecisionTemporaryDiversionPlan.controlID
                  }),
                  !envelope.controls.contains(where: {
                      $0.attempts.contains(where: {
                          $0.outcome == .outcomeUnknown || $0.outcome == .armed
                      })
                  }) else { return .reviewRequired }

            switch (envelope.status, control.phase) {
            case (.prepared, .baselineVerified):
                // A fresh transaction has no earlier mutation to retry.
                guard envelope.controls.allSatisfy({ $0.attempts.isEmpty }) else {
                    return .reviewRequired
                }
                return .activateAfterFreshBaseline
            case (.running, .appliedVerified):
                guard control.intended == readiness.plan.activeState else {
                    return .reviewRequired
                }
                return .resumeWithFreshRead
            case (.completed, .restoredVerified):
                return .archiveCompletedAndRefresh
            default:
                return .reviewRequired
            }
        } catch {
            return .reviewRequired
        }
    }
}
