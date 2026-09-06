import Foundation
import MXErgoEventSynthesis

package enum SuppressionOutcome: Sendable, Equatable {
    case passThrough
    case suppress
}

/// What the callback must do, and what it must hand to the run loop afterwards.
///
/// Delivery is separated from the decision because the window server drops an
/// event posted from inside a tap callback. The decision has to be made now —
/// the callback must return suppress or pass-through synchronously — while the
/// injection has to happen once that return has been made.
package enum AppliedDecision {
    case passThrough
    case suppress(delivery: (any PreparedSyntheticEvents)?)
}

/// Carries out a decision and records what happened.
///
/// Split out of the tap callback so the consequential half — "when exactly is
/// an event swallowed" — is exercised by ordinary tests with a fake poster,
/// rather than only by installing a real tap on a real session.
package enum EventSynthesisDecisionApplier {
    /// Commit gesture state only once we know what the callback will return.
    /// Otherwise a failed build passes the down but swallows its up, or consumes
    /// a tilt's repeat interval without ever delivering its replacement.
    package static func apply(
        _ event: ObservedEventKind,
        at timestamp: TimeInterval,
        frontmostBundleIdentifier: String? = nil,
        policy: inout EventSynthesisPolicy,
        poster: SyntheticEventPosting,
        diagnostics: inout EventSynthesisDiagnostics
    ) -> AppliedDecision {
        var candidate = policy
        let decision = candidate.decide(
            event, at: timestamp,
            frontmostBundleIdentifier: frontmostBundleIdentifier
        )
        let applied = apply(decision, poster: poster, diagnostics: &diagnostics)
        if case .suppressAndPost = decision, case .passThrough = applied {
            policy.recordReplacementFailure(for: event)
        } else {
            policy = candidate
        }
        return applied
    }

    // Only the transactional entry point above is exposed across the package.
    static func apply(
        _ decision: EventSynthesisDecision,
        poster: SyntheticEventPosting,
        diagnostics: inout EventSynthesisDiagnostics
    ) -> AppliedDecision {
        switch decision {
        case .passThrough:
            diagnostics.passedThroughCount += 1
            diagnostics.lastDecisionDescription = "passed through"
            return .passThrough

        case .suppress:
            diagnostics.suppressedCount += 1
            diagnostics.lastDecisionDescription = "suppressed"
            return .suppress(delivery: nil)

        case let .suppressAndPost(events):
            // Construction is the only failure this layer can detect —
            // `CGEvent.post` reports nothing — so it stays here, inside the
            // callback, and still fails open. Swallowing the original after
            // failing to build its replacement would lose the input outright,
            // which is the one outcome worse than not remapping at all.
            guard let prepared = poster.prepare(events) else {
                diagnostics.postFailureCount += 1
                diagnostics.passedThroughCount += 1
                diagnostics.lastDecisionDescription =
                    "could not build the replacement; original passed through"
                return .passThrough
            }
            diagnostics.suppressedCount += 1
            diagnostics.postedCount += events.count
            diagnostics.lastDecisionDescription = "posted "
                + events.map(\.description).joined(separator: ", ")
            return .suppress(delivery: prepared)
        }
    }
}
