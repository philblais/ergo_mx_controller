import Foundation

/// Accumulates discrete volume steps and emits bounded scalar changes suitable
/// for a short 60 Hz ramp. New input is never dropped; opposite input cancels
/// pending movement naturally.
public struct VolumeRampAccumulator: Sendable, Equatable {
    public let scalarPerStep: Float
    public let maximumScalarChangePerTick: Float
    public private(set) var pendingScalarChange: Float = 0

    public init(
        scalarPerStep: Float = 1.0 / 16.0,
        maximumScalarChangePerTick: Float = 1.0 / 32.0
    ) {
        precondition(scalarPerStep > 0)
        precondition(maximumScalarChangePerTick > 0)
        self.scalarPerStep = scalarPerStep
        self.maximumScalarChangePerTick = maximumScalarChangePerTick
    }

    public var hasPendingChange: Bool {
        abs(pendingScalarChange) > 0.000_001
    }

    public mutating func enqueue(steps: Int) {
        pendingScalarChange += Float(steps) * scalarPerStep
        normalizePendingChange()
    }

    /// Replaces pending motion after a caller clamps its absolute target.
    /// Keeping the unapplied excess would make a later reversal move toward
    /// a target the caller has already discarded.
    public mutating func retarget(pendingScalarChange: Float) {
        precondition(pendingScalarChange.isFinite)
        self.pendingScalarChange = pendingScalarChange
        normalizePendingChange()
    }

    public mutating func takeNextChange() -> Float? {
        guard hasPendingChange else { return nil }
        let change = min(
            maximumScalarChangePerTick,
            max(-maximumScalarChangePerTick, pendingScalarChange)
        )
        pendingScalarChange -= change
        normalizePendingChange()
        return change
    }

    public mutating func reset() {
        pendingScalarChange = 0
    }

    private mutating func normalizePendingChange() {
        if abs(pendingScalarChange) <= 0.000_001 {
            pendingScalarChange = 0
        }
    }
}
