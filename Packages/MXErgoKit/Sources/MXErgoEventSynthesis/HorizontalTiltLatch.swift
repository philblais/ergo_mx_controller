import Foundation
import MXErgoCore

/// Turns a stream of discrete horizontal wheel units into at most one
/// navigation per deliberate tilt.
///
/// The device reports wheel tilt as AC Pan notches on the Consumer page, and a
/// single physical flick produces several of them. Firing per notch would send
/// a browser several pages back from one gesture, so a fired direction is held
/// off until `repeatInterval` has passed. A deliberate change of direction is
/// treated as a new gesture and is not held off, because waiting to undo an
/// overshoot is the one case where latency is actually felt.
package struct HorizontalTiltLatch: Sendable, Equatable {
    /// Accumulated magnitude required before the first fire of a gesture.
    package let threshold: Int
    /// Minimum spacing between two fires in the same direction. Holding the
    /// tilt therefore auto-repeats, but no faster than this.
    package let repeatInterval: TimeInterval
    /// Silence after which the next unit starts a fresh gesture.
    package let gestureGap: TimeInterval

    private var accumulated = 0
    private var pendingDirection: MappedControlHorizontalSwipe?
    private var lastUnitAt: TimeInterval?
    private var lastFiredAt: TimeInterval?

    package init(
        threshold: Int = 1,
        repeatInterval: TimeInterval = 0.35,
        gestureGap: TimeInterval = 0.5
    ) {
        self.threshold = max(1, threshold)
        self.repeatInterval = repeatInterval
        self.gestureGap = gestureGap
    }

    package mutating func accumulate(
        units: Int,
        at timestamp: TimeInterval
    ) -> MappedControlHorizontalSwipe? {
        guard units != 0 else { return nil }
        let direction: MappedControlHorizontalSwipe = units > 0 ? .right : .left

        if let lastUnitAt, timestamp - lastUnitAt > gestureGap {
            reset()
        }
        if pendingDirection != direction {
            // A new gesture, including a reversal. Clearing the fire time is
            // what lets an overshoot be corrected immediately.
            reset()
            pendingDirection = direction
        }
        lastUnitAt = timestamp

        if let lastFiredAt, timestamp - lastFiredAt < repeatInterval {
            return nil
        }

        accumulated += abs(units)
        guard accumulated >= threshold else { return nil }
        accumulated = 0
        lastFiredAt = timestamp
        return direction
    }

    package mutating func reset() {
        accumulated = 0
        pendingDirection = nil
        lastUnitAt = nil
        lastFiredAt = nil
    }
}
