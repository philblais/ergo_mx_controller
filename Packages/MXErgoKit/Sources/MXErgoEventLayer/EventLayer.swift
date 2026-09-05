import Foundation
import MXErgoCore
import MXErgoEventSynthesis
import MXErgoEventTap

/// One rebound control, as text a person can check before turning the layer on.
public struct EventLayerBinding: Sendable, Equatable {
    public let control: String
    public let intent: String
    public let trigger: String
    public let replacement: String
    /// Injected instead of `replacement` in applications that ignore the
    /// back/forward mouse buttons. Nil where there is no alternative.
    public let keyboardAlternative: String?
}

/// What the layer would do, computable without starting anything.
///
/// Unlike the HID++ plans in this project it carries no `notAuthorizedForExecution`
/// marker, because that would now be a lie: this layer *can* execute. What
/// gates it is an explicit toggle that is off after every launch and an
/// Accessibility grant, which is the proportionate ceremony for an effect that
/// stops the moment the tap does.
public struct EventLayerReview: Sendable, Equatable {
    public let bindings: [EventLayerBinding]

    /// Applications that get the keyboard alternative instead of the mouse
    /// buttons, because they ignore those buttons for navigation.
    public static var keyboardNavigationApplications: [String] {
        EventSynthesisPlan.keyboardNavigationBundleIdentifiers.sorted()
    }

    public static func reviewed() throws -> EventLayerReview {
        let plan = try EventSynthesisPlan.reviewed()
        return EventLayerReview(
            bindings: plan.bindings.map {
                EventLayerBinding(
                    control: $0.control.name,
                    intent: $0.intent.name,
                    trigger: $0.trigger.description,
                    replacement: $0.replacement.description,
                    keyboardAlternative: $0.keyboardAlternative?.description
                )
            }
        )
    }
}

public enum EventLayerError: Error, Sendable, Equatable {
    /// Suppressing events requires Accessibility, not Input Monitoring.
    case accessibilityNotGranted
    case eventSourceUnavailable
    case tapUnavailable
    case alreadyRunning
    case planInvalid(String)

    init(_ error: Error) {
        switch error {
        case EventSynthesisTapError.accessibilityNotGranted:
            self = .accessibilityNotGranted
        case EventSynthesisTapError.eventSourceUnavailable:
            self = .eventSourceUnavailable
        case EventSynthesisTapError.alreadyRunning:
            self = .alreadyRunning
        case EventSynthesisTapError.tapCreationFailed,
             EventSynthesisTapError.runLoopSourceUnavailable:
            self = .tapUnavailable
        default:
            self = .planInvalid(String(describing: error))
        }
    }

    public var message: String {
        switch self {
        case .accessibilityNotGranted:
            "Grant Accessibility first; suppressing events requires it"
        case .eventSourceUnavailable:
            "The system refused an event source"
        case .tapUnavailable:
            "The system refused an event tap"
        case .alreadyRunning:
            "Already running"
        case let .planInvalid(detail):
            "The binding plan is invalid: \(detail)"
        }
    }
}

public struct EventLayerDiagnostics: Sendable, Equatable {
    public let observedCount: Int
    public let passedThroughCount: Int
    public let suppressedCount: Int
    public let postedCount: Int
    public let ownEventCount: Int
    public let postFailureCount: Int
    public let tapReenableCount: Int
    public let lastDecisionDescription: String?
    /// The last event the tap decoded, whether or not it was rebound. This is
    /// how an unbound button reveals itself.
    public let lastObservedDescription: String?

    /// `own` is the load-bearing number on a first run. This layer both
    /// swallows mouse buttons 3 and 4 and injects them, so it has to recognise
    /// its own events. If that marker ever failed, injected clicks would be
    /// re-consumed and counted as observed instead — visible here rather than
    /// only as strange behaviour.
    public var summary: String {
        "observed \(observedCount) · passed \(passedThroughCount) "
            + "· suppressed \(suppressedCount) · posted \(postedCount) "
            + "· own \(ownEventCount)"
    }

    /// Surfaced separately because these two are the ones that mean something
    /// is wrong rather than merely busy.
    public var needsAttention: Bool {
        postFailureCount > 0 || tapReenableCount > 0
    }
}

/// The only executable-facing surface of the event layer.
///
/// It exposes starting, stopping, the reviewed plan, and read-only counters.
/// It deliberately exposes no poster, no tap, no policy, and no way to change
/// what the bindings are: the plan is derived from `MappedControlActionPlan`
/// and cannot be supplied by a caller.
public final class EventLayer: @unchecked Sendable {
    private let tap = EventSynthesisTap()

    public init() {}

    public var isRunning: Bool { tap.isRunning }

    /// `naturalScrollingEnabled` is passed in rather than read here because
    /// the sign of a horizontal scroll delta inverts with that preference —
    /// established on hardware 2026-09-05 — and the host already reads and
    /// republishes it. Passing it keeps one reader of the preference.
    public func start(
        naturalScrollingEnabled: Bool,
        frontmostBundleIdentifier: @escaping @Sendable () -> String? = { nil }
    ) throws {
        do {
            try tap.start(
                plan: try EventSynthesisPlan.reviewed(),
                convention: .forNaturalScrolling(
                    isEnabled: naturalScrollingEnabled
                ),
                frontmostBundleIdentifier: frontmostBundleIdentifier
            )
        } catch {
            throw EventLayerError(error)
        }
    }

    /// Must be called whenever the preference changes. Without it, flipping
    /// natural scrolling silently swaps back and forward until the next
    /// restart.
    public func setNaturalScrolling(enabled: Bool) {
        tap.setConvention(.forNaturalScrolling(isEnabled: enabled))
    }

    public func stop() {
        tap.stop()
    }

    /// Which of the reviewed replacements to post directly, for diagnosis.
    ///
    /// The keypad-flag variant that these buttons once compared is gone: it won
    /// and is now what the planner always builds. What remains untested is the
    /// injected *click*, which only wheel tilt uses, so posting one from here
    /// separates "the click is wrong" from "the tilt was never seen".
    public enum DiagnosticInjection: String, Sendable, Equatable, CaseIterable {
        case wheelClickChord
        case tiltLeftClick
        case tiltRightClick

        public var label: String {
            switch self {
            case .wheelClickChord: "wheel click's chord"
            case .tiltLeftClick: "tilt left's click"
            case .tiltRightClick: "tilt right's click"
            }
        }

        fileprivate var trigger: EventSynthesisTrigger {
            switch self {
            case .wheelClickChord:
                .otherMouseButton(number: EventSynthesisPlan.wheelClickButtonNumber)
            case .tiltLeftClick: .horizontalTilt(direction: .left)
            case .tiltRightClick: .horizontalTilt(direction: .right)
            }
        }
    }

    /// Posts one reviewed replacement directly, from the caller's thread rather
    /// than from inside the tap callback, and reports what it sent.
    ///
    /// The description is returned rather than assumed, so a report of what
    /// happened can be matched against what was actually injected.
    public func postDiagnosticInjection(
        _ injection: DiagnosticInjection
    ) throws -> String {
        let plan: EventSynthesisPlan
        do {
            plan = try EventSynthesisPlan.reviewed()
        } catch {
            throw EventLayerError(error)
        }
        guard let binding = plan.binding(for: injection.trigger) else {
            throw EventLayerError.planInvalid(
                "no binding for \(injection.label)"
            )
        }
        do {
            guard try SyntheticEventDiagnosticPost.post(binding.replacement) else {
                throw EventLayerError.eventSourceUnavailable
            }
        } catch let error as EventLayerError {
            throw error
        } catch {
            throw EventLayerError(error)
        }
        return binding.replacement.description
    }

    public var diagnostics: EventLayerDiagnostics? {
        tap.diagnostics.map {
            EventLayerDiagnostics(
                observedCount: $0.observedCount,
                passedThroughCount: $0.passedThroughCount,
                suppressedCount: $0.suppressedCount,
                postedCount: $0.postedCount,
                ownEventCount: $0.ownEventCount,
                postFailureCount: $0.postFailureCount,
                tapReenableCount: $0.tapReenableCount,
                lastDecisionDescription: $0.lastDecisionDescription,
                lastObservedDescription: $0.lastObservedDescription
            )
        }
    }
}
