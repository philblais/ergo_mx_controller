import Foundation
import MXErgoCore

/// The whole decision layer, as a pure value.
///
/// Every question the tap can ask is answered here, without CoreGraphics and
/// without side effects, so "could this swallow my click" is decidable by a
/// test rather than by trying it on a live machine.
package struct EventSynthesisPolicy: Sendable {
    package let plan: EventSynthesisPlan

    /// Buttons whose press this policy actually swallowed.
    ///
    /// The release consults this set and never the plan. If the plan changed
    /// while a button was physically held, consulting it would let the release
    /// through and hand the frontmost app a mouse-up it never saw a down for.
    private var suppressedButtons: Set<Int> = []
    private var tilt: HorizontalTiltLatch

    package init(
        plan: EventSynthesisPlan,
        tilt: HorizontalTiltLatch = HorizontalTiltLatch()
    ) {
        self.plan = plan
        self.tilt = tilt
    }

    package var heldSuppressedButtons: [Int] { suppressedButtons.sorted() }

    package mutating func decide(
        _ kind: ObservedEventKind,
        at timestamp: TimeInterval
    ) -> EventSynthesisDecision {
        switch kind {
        case let .otherMouseDown(buttonNumber):
            guard let binding = plan.binding(
                for: .otherMouseButton(number: buttonNumber)
            ) else {
                return .passThrough
            }
            suppressedButtons.insert(buttonNumber)
            return .suppressAndPost([binding.replacement])

        case let .otherMouseUp(buttonNumber):
            guard suppressedButtons.remove(buttonNumber) != nil else {
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
            return .suppressAndPost([binding.replacement])
        }
    }

    /// Forgets in-flight gesture state. Called when the tap stops, so a later
    /// run cannot inherit a stale latch or a phantom held button.
    package mutating func reset() {
        suppressedButtons.removeAll()
        tilt.reset()
    }
}
