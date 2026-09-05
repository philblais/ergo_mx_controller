import ApplicationServices
import CoreGraphics
import Foundation
import MXErgoEventSynthesis

package enum EventSynthesisTapError: Error, Sendable, Equatable {
    /// A suppressing tap (`.defaultTap`) requires Accessibility, not merely
    /// Input Monitoring. This is the failure that made the Precision scroll
    /// swallow silently do nothing on 2026-09-04, so it is refused loudly here
    /// rather than discovered from a symptom.
    case accessibilityNotGranted
    case eventSourceUnavailable
    case tapCreationFailed
    case runLoopSourceUnavailable
    case alreadyRunning
}

/// Read-only counters, in the shape that settled the Precision audio question.
///
/// A remapper that does nothing and a remapper that is never asked look
/// identical from the outside. These make them distinguishable without
/// guessing.
package struct EventSynthesisDiagnostics: Sendable, Equatable {
    package var observedCount = 0
    package var passedThroughCount = 0
    package var suppressedCount = 0
    package var postedCount = 0
    package var ownEventCount = 0
    package var postFailureCount = 0
    package var tapReenableCount = 0
    package var lastDecisionDescription: String?

    package init() {}
}

/// Observes mouse buttons and scroll, swallows only what the plan rebinds, and
/// injects the replacements.
///
/// It touches no HID device, sends no report, and holds no lease. The hazard
/// it does carry is different in kind: a suppressing tap that misbehaves makes
/// the pointing device feel broken. So it fails open everywhere — an
/// unrecognised event, an undecodable event, or a failed injection all hand
/// the original back to the system rather than swallowing it.
package final class EventSynthesisTap: @unchecked Sendable {
    package typealias DiagnosticsHandler = @Sendable (EventSynthesisDiagnostics) -> Void

    private let lock = NSLock()
    private var loop: Loop?

    /// Exactly three event types. The primary and secondary buttons are not
    /// in the mask, so nothing this tap can observe — and therefore nothing it
    /// can suppress — is an ordinary click. That is structural, not a check.
    package static let observedEventMask = CGEventMask(
        1 << CGEventType.otherMouseDown.rawValue
            | 1 << CGEventType.otherMouseUp.rawValue
            | 1 << CGEventType.scrollWheel.rawValue
    )

    package init() {}

    package var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loop != nil
    }

    package var diagnostics: EventSynthesisDiagnostics? {
        lock.lock()
        let loop = self.loop
        lock.unlock()
        return loop?.snapshot()
    }

    /// Installs the tap. Throws rather than degrading: a remapper that half
    /// works is worse than one that plainly refused to start.
    package func start(
        plan: EventSynthesisPlan,
        latch: HorizontalTiltLatch = HorizontalTiltLatch(),
        convention: HorizontalScrollConvention = .current(),
        poster: SyntheticEventPosting? = nil
    ) throws {
        guard AXIsProcessTrusted() else {
            throw EventSynthesisTapError.accessibilityNotGranted
        }
        let resolvedPoster: SyntheticEventPosting
        if let poster {
            resolvedPoster = poster
        } else {
            do {
                resolvedPoster = try CoreGraphicsSyntheticEventPoster()
            } catch {
                throw EventSynthesisTapError.eventSourceUnavailable
            }
        }

        lock.lock()
        guard loop == nil else {
            lock.unlock()
            throw EventSynthesisTapError.alreadyRunning
        }
        let created = Loop(
            policy: EventSynthesisPolicy(plan: plan, tilt: latch),
            convention: convention,
            poster: resolvedPoster
        )
        loop = created
        lock.unlock()

        do {
            try created.start()
        } catch {
            lock.lock()
            if loop === created { loop = nil }
            lock.unlock()
            throw error
        }
    }

    /// Applies a new convention to a running tap.
    ///
    /// "Natural scrolling" can be changed at any moment from System Settings,
    /// and it inverts the horizontal delta. Without this, flipping it would
    /// silently swap back and forward until the tap was restarted. A host must
    /// call this whenever it refreshes the preference.
    package func setConvention(_ convention: HorizontalScrollConvention) {
        lock.lock()
        let running = loop
        lock.unlock()
        running?.setConvention(convention)
    }

    package func stop() {
        lock.lock()
        let running = loop
        loop = nil
        lock.unlock()
        running?.stop()
    }
}

/// The tap's own thread, run loop, and mutable decision state.
private final class Loop: @unchecked Sendable {
    private let stateLock = NSLock()
    private let poster: SyntheticEventPosting
    private var convention: HorizontalScrollConvention
    private var policy: EventSynthesisPolicy
    private var diagnostics = EventSynthesisDiagnostics()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var startError: EventSynthesisTapError?
    private var stopRequested = false
    private let started = DispatchSemaphore(value: 0)

    init(
        policy: EventSynthesisPolicy,
        convention: HorizontalScrollConvention,
        poster: SyntheticEventPosting
    ) {
        self.policy = policy
        self.convention = convention
        self.poster = poster
    }

    func start() throws {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "com.phib.MXErgoController.EventSynthesis"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        started.wait()
        stateLock.lock()
        let error = startError
        stateLock.unlock()
        if let error { throw error }
    }

    func stop() {
        stateLock.lock()
        stopRequested = true
        policy.reset()
        let loop = runLoop
        stateLock.unlock()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            CFRunLoopStop(loop)
        }
        CFRunLoopWakeUp(loop)
    }

    func setConvention(_ convention: HorizontalScrollConvention) {
        stateLock.lock()
        self.convention = convention
        stateLock.unlock()
    }

    func snapshot() -> EventSynthesisDiagnostics {
        stateLock.lock()
        defer { stateLock.unlock() }
        return diagnostics
    }

    private func run() {
        autoreleasepool {
            guard let currentRunLoop = CFRunLoopGetCurrent() else {
                fail(.tapCreationFailed)
                return
            }
            stateLock.lock()
            runLoop = currentRunLoop
            let alreadyStopped = stopRequested
            stateLock.unlock()
            guard !alreadyStopped else {
                started.signal()
                return
            }

            let context = Unmanaged.passUnretained(self).toOpaque()
            guard let createdTap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: EventSynthesisTap.observedEventMask,
                callback: synthesisTapCallback,
                userInfo: context
            ) else {
                fail(.tapCreationFailed)
                return
            }
            guard let source = CFMachPortCreateRunLoopSource(
                kCFAllocatorDefault,
                createdTap,
                0
            ) else {
                fail(.runLoopSourceUnavailable)
                return
            }

            stateLock.lock()
            tap = createdTap
            stateLock.unlock()

            CFRunLoopAddSource(currentRunLoop, source, .commonModes)
            CGEvent.tapEnable(tap: createdTap, enable: true)
            started.signal()

            CFRunLoopRun()

            CGEvent.tapEnable(tap: createdTap, enable: false)
            CFRunLoopRemoveSource(currentRunLoop, source, .commonModes)
            CFMachPortInvalidate(createdTap)
            stateLock.lock()
            tap = nil
            stateLock.unlock()
        }
    }

    private func fail(_ error: EventSynthesisTapError) {
        stateLock.lock()
        startError = error
        stateLock.unlock()
        started.signal()
    }

    fileprivate func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        // The system disables a tap that takes too long or that the user
        // interrupts, and it stays dead until re-enabled. This is not the
        // forbidden kind of retry: SAFETY.md forbids re-sending a command the
        // device may already have acted on. Nothing here reaches the device,
        // and re-arming is the documented contract of an event tap.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stateLock.lock()
            let tap = self.tap
            diagnostics.tapReenableCount += 1
            stateLock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passThrough
        }

        if event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker {
            stateLock.lock()
            diagnostics.ownEventCount += 1
            stateLock.unlock()
            return passThrough
        }

        stateLock.lock()
        let convention = self.convention
        stateLock.unlock()
        guard let kind = ObservedEventDecoder.decode(
            type: type,
            buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber),
            deltaAxis1: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            deltaAxis2: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous),
            convention: convention
        ) else {
            stateLock.lock()
            diagnostics.observedCount += 1
            diagnostics.passedThroughCount += 1
            stateLock.unlock()
            return passThrough
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        // The lock covers deciding and building only. Delivery happens after
        // the callback returns, so nothing slow or re-entrant runs under it.
        stateLock.lock()
        diagnostics.observedCount += 1
        let decision = policy.decide(kind, at: timestamp)
        let applied = EventSynthesisDecisionApplier.apply(
            decision,
            poster: poster,
            diagnostics: &diagnostics
        )
        let runLoop = self.runLoop
        stateLock.unlock()

        switch applied {
        case .passThrough:
            return passThrough
        case let .suppress(delivery):
            if let delivery, let runLoop {
                // The window server drops an event posted from inside a tap
                // callback. Delivering from a block on this same run loop puts
                // it after the callback has returned, on the same thread, so
                // ordering against later events is still exactly the order
                // they arrived in.
                CFRunLoopPerformBlock(
                    runLoop,
                    CFRunLoopMode.commonModes.rawValue
                ) {
                    delivery.deliver()
                }
                CFRunLoopWakeUp(runLoop)
            }
            return nil
        }
    }
}

private let synthesisTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<Loop>.fromOpaque(refcon).takeUnretainedValue()
        .handle(type: type, event: event)
}
