import Foundation
import MXErgoCore

package enum EventSynthesisPlanError: Error, Sendable, Equatable {
    case precisionControlExcluded
    case unsynthesizableAction(String)
    case duplicateTrigger(String)
    case planError(MappedControlActionPlanError)
}

/// What physically has to happen for a binding to fire.
package enum EventSynthesisTrigger: Sendable, Equatable, Hashable {
    case otherMouseButton(number: Int)
    case horizontalTilt(direction: MappedControlHorizontalSwipe)

    package var description: String {
        switch self {
        case let .otherMouseButton(number): "mouse button \(number + 1)"
        case let .horizontalTilt(direction): "wheel tilt \(direction.rawValue)"
        }
    }
}

package struct EventSynthesisBinding: Sendable, Equatable {
    package let control: MXErgoControl
    package let intent: ControllerIntent
    package let trigger: EventSynthesisTrigger
    package let replacement: SyntheticEvent
}

/// The reviewed substitution table: five ordinary-HID controls, each observed
/// as a CGEvent the system already delivers, each replaced by an event this
/// app injects instead.
///
/// Nothing here diverts anything. These five controls emit ordinary mouse
/// reports — confirmed on hardware on 2026-09-04, where the 2026-08-27
/// BetterTouchTool baseline also showed every control at `flags 0000` — so
/// replacing them is an event-layer problem with no device write at all.
/// Precision is the sole exception and stays on the HID++ runtime, because it
/// emits no ordinary report for a tap to see.
package struct EventSynthesisPlan: Sendable, Equatable {
    /// HID button masks observed on this MX Ergo on 2026-09-04: wheel click
    /// `0x04`, lower thumb `0x08`, upper thumb `0x10`. A CGEvent button number
    /// is the mask's bit position, so those are 2, 3 and 4.
    package static let wheelClickButtonNumber = 2
    package static let lowerThumbButtonNumber = 3
    package static let upperThumbButtonNumber = 4

    package let bindings: [EventSynthesisBinding]

    /// Derived from `MappedControlActionPlan` rather than restated, so the two
    /// descriptions of "what the buttons should do" cannot drift apart.
    package static func reviewed() throws -> EventSynthesisPlan {
        let actionPlan: MappedControlActionPlan
        do {
            actionPlan = try MappedControlActionPlan.make(
                reviewedControlIDs: MappedControlActionPlan.controlIDs
            )
        } catch let error as MappedControlActionPlanError {
            throw EventSynthesisPlanError.planError(error)
        }

        var bindings: [EventSynthesisBinding] = []
        var seen: Set<EventSynthesisTrigger> = []
        for binding in actionPlan.bindings {
            guard binding.control != .precision else {
                throw EventSynthesisPlanError.precisionControlExcluded
            }
            let trigger = try Self.trigger(for: binding.control)
            guard seen.insert(trigger).inserted else {
                throw EventSynthesisPlanError.duplicateTrigger(trigger.description)
            }
            bindings.append(
                EventSynthesisBinding(
                    control: binding.control,
                    intent: binding.intent,
                    trigger: trigger,
                    replacement: try Self.replacement(for: binding.synthesizedAction)
                )
            )
        }
        return EventSynthesisPlan(bindings: bindings)
    }

    package func binding(for trigger: EventSynthesisTrigger) -> EventSynthesisBinding? {
        bindings.first { $0.trigger == trigger }
    }

    /// True only for buttons this plan actually rebinds. The tap consults this
    /// before swallowing anything, so an unbound button on any mouse keeps
    /// working normally.
    package func bindsMouseButton(_ number: Int) -> Bool {
        binding(for: .otherMouseButton(number: number)) != nil
    }

    package var bindsHorizontalTilt: Bool {
        bindings.contains {
            if case .horizontalTilt = $0.trigger { return true }
            return false
        }
    }

    private static func trigger(
        for control: MXErgoControl
    ) throws -> EventSynthesisTrigger {
        switch control {
        case .wheelClick: .otherMouseButton(number: wheelClickButtonNumber)
        case .lowerThumb: .otherMouseButton(number: lowerThumbButtonNumber)
        case .upperThumb: .otherMouseButton(number: upperThumbButtonNumber)
        case .wheelTiltLeft: .horizontalTilt(direction: .left)
        case .wheelTiltRight: .horizontalTilt(direction: .right)
        case .precision: throw EventSynthesisPlanError.precisionControlExcluded
        }
    }

    /// Translates the action plan's description into something injectable.
    ///
    /// `.threeFingerSwipe` has no public synthesis API on macOS. Rather than
    /// drop back/forward, the reviewed substitution is the pair of mouse
    /// buttons the system already treats as back and forward — which is what
    /// this trackball's thumb buttons natively emit, and what those thumb
    /// buttons are being rebound away from. The swap is deliberate.
    private static func replacement(
        for action: MappedControlSynthesizedAction
    ) throws -> SyntheticEvent {
        switch action {
        case let .controlArrow(_, keyCode):
            return .keyChord(keyCode: keyCode, modifiers: .control)
        case let .threeFingerSwipe(_, direction):
            switch direction {
            case .left: return .otherMouseClick(buttonNumber: lowerThumbButtonNumber)
            case .right: return .otherMouseClick(buttonNumber: upperThumbButtonNumber)
            }
        }
    }
}

/// Immutable proof that a review happened and nothing more, in the same shape
/// as every other plan in this package. It carries no tap, no poster, and no
/// method that could cause an event to exist.
package struct EventSynthesisReviewSnapshot: Sendable, Equatable {
    package let triggers: [String]
    package let replacements: [String]
    package let authorization: MappedControlActionSynthesisAuthorization

    package static func makeUnauthorized() throws -> EventSynthesisReviewSnapshot {
        let plan = try EventSynthesisPlan.reviewed()
        return EventSynthesisReviewSnapshot(
            triggers: plan.bindings.map(\.trigger.description),
            replacements: plan.bindings.map(\.replacement.description),
            authorization: .notAuthorizedForExecution
        )
    }
}
