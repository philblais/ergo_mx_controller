import Foundation
import MXErgoEventSynthesis

package enum SuppressionOutcome: Sendable, Equatable {
    case passThrough
    case suppress
}

/// Carries out a decision and records what happened.
///
/// Split out of the tap callback so the consequential half — "when exactly is
/// an event swallowed" — is exercised by ordinary tests with a fake poster,
/// rather than only by installing a real tap on a real session.
package enum EventSynthesisDecisionApplier {
    package static func apply(
        _ decision: EventSynthesisDecision,
        poster: SyntheticEventPosting,
        diagnostics: inout EventSynthesisDiagnostics
    ) -> SuppressionOutcome {
        switch decision {
        case .passThrough:
            diagnostics.passedThroughCount += 1
            diagnostics.lastDecisionDescription = "passed through"
            return .passThrough

        case .suppress:
            diagnostics.suppressedCount += 1
            diagnostics.lastDecisionDescription = "suppressed"
            return .suppress

        case let .suppressAndPost(events):
            guard poster.post(events) else {
                // Fail open. Swallowing the original after failing to replace
                // it would lose the input outright, which is the one outcome
                // worse than not remapping at all.
                diagnostics.postFailureCount += 1
                diagnostics.passedThroughCount += 1
                diagnostics.lastDecisionDescription =
                    "post failed; original passed through"
                return .passThrough
            }
            diagnostics.suppressedCount += 1
            diagnostics.postedCount += events.count
            diagnostics.lastDecisionDescription = "posted "
                + events.map(\.description).joined(separator: ", ")
            return .suppress
        }
    }
}
