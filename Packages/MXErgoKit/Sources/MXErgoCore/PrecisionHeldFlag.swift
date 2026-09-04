import Foundation

/// Cross-thread flag for whether Precision is currently held. The wheel
/// observer reads this from a CGEvent tap without hopping to an actor.
public final class PrecisionHeldFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false

    public init() {}

    public var isHeld: Bool {
        lock.withLock { held }
    }

    public func set(_ isHeld: Bool) {
        lock.withLock { held = isHeld }
    }
}
