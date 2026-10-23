import Foundation

/// Orders every input the Precision runtime acts on: diverted-button
/// notifications from the IOHID callback queue and wheel notches from the wheel
/// observer thread. Both pass through one lock in the order they arrive, and
/// each is stamped by its caller at arrival.
///
/// Each input used to reach the owner actor through its own unstructured task,
/// and separate tasks may run in either order. A release handled before its
/// press leaves Precision held, and the scroll tap then swallows discrete
/// vertical scroll from every pointing device until the next tap.
///
/// The held flag is updated before a delivery call returns, so the scroll tap
/// never sees a stale value for input that has already been processed.
public final class PrecisionInputSequencer: @unchecked Sendable {
    /// Called with the lock held, in processing order. It must not block or
    /// call back into this sequencer.
    public typealias IntentHandler = @Sendable (ControllerIntent) -> Void

    /// Read synchronously by the scroll tap without crossing an actor.
    public let held = PrecisionHeldFlag()

    private let lock = NSLock()
    private let featureIndex: UInt8
    private var pump: PrecisionControlEventPump
    private var intentHandler: IntentHandler?
    private var isClosed = false

    public init(featureIndex: UInt8) {
        self.featureIndex = featureIndex
        pump = PrecisionControlEventPump(featureIndex: featureIndex)
    }

    public var isAcceptingInput: Bool {
        lock.withLock { !isClosed }
    }

    /// Ignored once closed, so a quit cannot be undone by a late registration.
    public func setIntentHandler(_ handler: IntentHandler?) {
        lock.withLock {
            guard !isClosed else { return }
            intentHandler = handler
        }
    }

    public func receiveNotification(_ bytes: [UInt8], at timestamp: TimeInterval) {
        process { $0.processHIDPPNotification(bytes, at: timestamp) }
    }

    public func receiveVerticalScroll(notches: Int, at timestamp: TimeInterval) {
        process { $0.processVerticalScroll(notches: notches, at: timestamp) }
    }

    /// Forgets any press in progress and releases held. Later input is still
    /// accepted; a release for the forgotten press produces nothing.
    public func reset() {
        lock.withLock {
            pump = PrecisionControlEventPump(featureIndex: featureIndex)
            held.set(false)
        }
    }

    /// Permanently stops delivery, for physical removal and quit. Held is
    /// released first so suppression ends even if input keeps arriving.
    public func close() {
        lock.withLock {
            isClosed = true
            intentHandler = nil
            pump = PrecisionControlEventPump(featureIndex: featureIndex)
            held.set(false)
        }
    }

    private func process(
        _ step: (inout PrecisionControlEventPump) -> [ControllerIntent]
    ) {
        lock.withLock {
            guard !isClosed else { return }
            let intents = step(&pump)
            held.set(pump.isPrecisionPressed)
            for intent in intents { intentHandler?(intent) }
        }
    }
}
