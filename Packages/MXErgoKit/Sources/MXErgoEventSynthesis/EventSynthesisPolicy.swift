import Foundation
import MXErgoCore

/// The whole decision layer, as a pure value.
///
/// Every question the tap can ask is answered here, without CoreGraphics and
/// without side effects, so "could this swallow my click" is decidable by a
/// test rather than by trying it on a live machine.
package struct EventSynthesisPolicy: Sendable {
    package let plan: EventSynthesisPlan

    private enum HeldButtonDisposition: Sendable {
        case suppressed
        case passedThrough
    }

    /// A held button keeps the outcome of its first press until release. A
    /// duplicate down must not change that outcome or trigger another action.
    private var heldButtons: [Int: HeldButtonDisposition] = [:]
    private var tilt: HorizontalTiltLatch

    package init(
        plan: EventSynthesisPlan,
        tilt: HorizontalTiltLatch = HorizontalTiltLatch()
    ) {
        self.plan = plan
        self.tilt = tilt
    }

    package var heldSuppressedButtons: [Int] {
        heldButtons.compactMap { button, disposition in
            disposition == .suppressed ? button : nil
        }.sorted()
    }

    /// Evaluate on a copy, then commit only after the replacement is prepared.
    /// The event applier records a passed-through press if preparation fails.
    package mutating func decide(
        _ kind: ObservedEventKind,
        at timestamp: TimeInterval,
        frontmostBundleIdentifier: String? = nil
    ) -> EventSynthesisDecision {
        switch kind {
        case let .otherMouseDown(buttonNumber):
            switch heldButtons[buttonNumber] {
            case .suppressed: return .suppress
            case .passedThrough: return .passThrough
            case nil: break
            }
            guard let binding = plan.binding(
                for: .otherMouseButton(number: buttonNumber)
            ) else {
                return .passThrough
            }
            heldButtons[buttonNumber] = .suppressed
            return .suppressAndPost([plan.replacement(
                for: binding,
                frontmostBundleIdentifier: frontmostBundleIdentifier
            )])

        case let .otherMouseUp(buttonNumber):
            guard heldButtons.removeValue(forKey: buttonNumber) == .suppressed else {
                return .passThrough
            }
            return .suppress

        case let .scroll(horizontalUnits, verticalUnits, isContinuous):
            // A trackpad's horizontal swipe is continuous. Swallowing it would
            // break back/forward for every other pointing device on the Mac.
            guard !isContinuous else { return .passThrough }
            // Vertical scroll belongs to the Precision volume path, which owns
            // its own tap. A mixed-axis event is not a trackball tilt, and
            // suppressing it would silently eat the vertical half.
            guard horizontalUnits != 0, verticalUnits == 0 else {
                return .passThrough
            }
            guard plan.bindsHorizontalTilt else { return .passThrough }

            guard let direction = tilt.accumulate(
                units: horizontalUnits,
                at: timestamp
            ) else {
                // Held off by the latch. Still swallowed: letting the
                // intermediate notches through would scroll the page sideways
                // as well as navigating it.
                return .suppress
            }
            guard let binding = plan.binding(
                for: .horizontalTilt(direction: direction)
            ) else {
                return .suppress
            }
            return .suppressAndPost([plan.replacement(
                for: binding,
                frontmostBundleIdentifier: frontmostBundleIdentifier
            )])
        }
    }

    /// Called on the original policy, not the tentative copy. Keep a failed
    /// press passed through until its up, while discarding tentative tilt state.
    package mutating func recordReplacementFailure(for kind: ObservedEventKind) {
        guard case let .otherMouseDown(buttonNumber) = kind,
              heldButtons[buttonNumber] == nil else { return }
        heldButtons[buttonNumber] = .passedThrough
    }

    /// Forgets in-flight gesture state. Called when the tap stops, so a later
    /// run cannot inherit a stale latch or a phantom held button.
    package mutating func reset() {
        heldButtons.removeAll()
        tilt.reset()
    }
}
