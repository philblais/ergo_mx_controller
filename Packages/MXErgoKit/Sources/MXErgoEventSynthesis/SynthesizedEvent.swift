import Foundation
import MXErgoCore

/// Modifier keys a synthesized chord may carry.
///
/// Deliberately not `CGEventFlags`. The entire policy layer is value-only so it
/// can be exercised without a window server, an Accessibility grant, or any
/// possibility of a stray event reaching the user's session.
package struct SynthesizedModifiers: OptionSet, Sendable, Equatable {
    package let rawValue: UInt8

    package init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    package static let control = SynthesizedModifiers(rawValue: 1 << 0)
    package static let option = SynthesizedModifiers(rawValue: 1 << 1)
    package static let command = SynthesizedModifiers(rawValue: 1 << 2)
    package static let shift = SynthesizedModifiers(rawValue: 1 << 3)

    /// Not modifiers a person presses. macOS sets both on a real arrow key,
    /// which is a keypad-group key reached through Fn. A synthetic arrow that
    /// omits them is not the same event as the one a keyboard produces, and a
    /// system hotkey matcher may or may not care — which is the open question
    /// these exist to answer.
    package static let numericPad = SynthesizedModifiers(rawValue: 1 << 4)
    package static let secondaryFunction = SynthesizedModifiers(rawValue: 1 << 5)

    /// The four a key transition can be built from. The other two ride along
    /// on the key's own flags and never get a press of their own.
    package static let pressable: SynthesizedModifiers =
        [.control, .option, .command, .shift]
}

/// What the layer may inject. Two shapes only, both public CoreGraphics
/// constructions. There is no gesture case: macOS exposes no public
/// gesture-synthesis API, which is why the plan substitutes a mouse click for
/// the three-finger swipe `MappedControlActionPlan` describes.
package enum SyntheticEvent: Sendable, Equatable {
    case keyChord(keyCode: UInt16, modifiers: SynthesizedModifiers)
    case otherMouseClick(buttonNumber: Int)

    package var description: String {
        switch self {
        case let .keyChord(keyCode, modifiers):
            var parts: [String] = []
            if modifiers.contains(.control) { parts.append("Control") }
            if modifiers.contains(.option) { parts.append("Option") }
            if modifiers.contains(.command) { parts.append("Command") }
            if modifiers.contains(.shift) { parts.append("Shift") }
            parts.append("key \(keyCode)")
            return parts.joined(separator: "+")
        case let .otherMouseClick(buttonNumber):
            return "mouse button \(buttonNumber + 1)"
        }
    }
}

/// One observed event, reduced to the scalars the policy needs.
///
/// The primary and secondary mouse buttons have no case here and are absent
/// from the tap's event mask, so no combination of state can make this layer
/// swallow an ordinary click. That is a structural guarantee, not a check.
package enum ObservedEventKind: Sendable, Equatable {
    case otherMouseDown(buttonNumber: Int)
    case otherMouseUp(buttonNumber: Int)
    /// `isContinuous` separates a trackpad's continuous gesture stream from a
    /// discrete wheel notch. Suppressing the former would break two-finger
    /// swipe for every pointing device on the machine.
    case scroll(horizontalUnits: Int, verticalUnits: Int, isContinuous: Bool)
}

package enum EventSynthesisDecision: Sendable, Equatable {
    /// Hand the original event back to the system unchanged.
    case passThrough
    /// Swallow the original and inject nothing.
    case suppress
    /// Swallow the original and inject these instead.
    case suppressAndPost([SyntheticEvent])
}
