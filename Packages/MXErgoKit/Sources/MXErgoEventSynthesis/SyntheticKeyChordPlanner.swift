import Foundation

/// One key transition, with the modifier state as it stands at that moment.
package struct SynthesizedKeyStroke: Sendable, Equatable {
    package let virtualKey: UInt16
    package let isKeyDown: Bool
    /// Cumulative modifier state after this stroke, not the chord's modifiers.
    package let modifiers: SynthesizedModifiers

    package init(
        virtualKey: UInt16,
        isKeyDown: Bool,
        modifiers: SynthesizedModifiers
    ) {
        self.virtualKey = virtualKey
        self.isKeyDown = isKeyDown
        self.modifiers = modifiers
    }
}

/// Expands a chord into the key transitions a real keyboard would emit.
///
/// Setting a modifier flag on the arrow key alone is enough for an ordinary
/// application, which reads the flags off the event it receives. It is **not**
/// enough for a symbolic hotkey — Mission Control and the Spaces shortcuts are
/// matched by the window server against the modifier state it believes is
/// current, and a flag that appears out of nowhere on one key event never
/// makes Control *be* down. So the modifier is pressed and released around the
/// key, in the order a keyboard would.
///
/// The virtual key codes are the standard macOS ones. They are plain integers
/// here so this stays free of any framework that could post an event.
package enum SyntheticKeyChordPlanner {
    package static let controlVirtualKey: UInt16 = 0x3B
    package static let optionVirtualKey: UInt16 = 0x3A
    package static let commandVirtualKey: UInt16 = 0x37
    package static let shiftVirtualKey: UInt16 = 0x38

    /// Ordered so a chord is always built and unwound the same way.
    package static let modifierOrder: [(SynthesizedModifiers, UInt16)] = [
        (.control, controlVirtualKey),
        (.option, optionVirtualKey),
        (.command, commandVirtualKey),
        (.shift, shiftVirtualKey),
    ]

    package static func strokes(
        keyCode: UInt16,
        modifiers: SynthesizedModifiers
    ) -> [SynthesizedKeyStroke] {
        let active = modifierOrder.filter { modifiers.contains($0.0) }
        // Flags that ride on the key without ever being pressed.
        let passive = modifiers.subtracting(.pressable)
        var strokes: [SynthesizedKeyStroke] = []
        var state: SynthesizedModifiers = []

        for (modifier, virtualKey) in active {
            state.insert(modifier)
            strokes.append(
                SynthesizedKeyStroke(
                    virtualKey: virtualKey,
                    isKeyDown: true,
                    modifiers: state
                )
            )
        }
        strokes.append(
            SynthesizedKeyStroke(
                virtualKey: keyCode,
                isKeyDown: true,
                modifiers: state.union(passive)
            )
        )
        strokes.append(
            SynthesizedKeyStroke(
                virtualKey: keyCode,
                isKeyDown: false,
                modifiers: state.union(passive)
            )
        )
        for (modifier, virtualKey) in active.reversed() {
            state.remove(modifier)
            strokes.append(
                SynthesizedKeyStroke(
                    virtualKey: virtualKey,
                    isKeyDown: false,
                    modifiers: state
                )
            )
        }
        return strokes
    }
}
