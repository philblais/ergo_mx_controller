import CoreGraphics
import Foundation
import MXErgoEventSynthesis

/// Stamped into every event this app creates, and checked on every event the
/// tap receives.
///
/// The tap both swallows mouse buttons 3 and 4 and injects mouse buttons 3 and
/// 4, so without a marker the first tilt would loop forever. Recognising our
/// own events is therefore load-bearing, not defensive.
package let syntheticEventMarker: Int64 = 0x4D58_4552_474F_0001

package protocol SyntheticEventPosting: Sendable {
    /// Returns false if anything could not be injected, so the caller can pass
    /// the original event through instead of swallowing it for nothing.
    func post(_ events: [SyntheticEvent]) -> Bool
}

package enum SyntheticEventPosterError: Error, Sendable, Equatable {
    case eventSourceUnavailable
}

/// The **only** place in this package that calls `CGEvent.post`.
///
/// It exists for the same reason `MXErgoPrecisionIOHIDOutput` holds the only
/// `IOHIDDeviceSetReport` call site: "what can this app inject into my
/// session" should be answerable by reading one function. A test asserts the
/// symbol occurs exactly once across both event-layer targets. Never add a
/// second; route through this one.
/// `@unchecked` because `CGEventSource` predates `Sendable`. The handle is
/// created once, never mutated after `init`, and only read, so sharing it
/// across the tap thread and its caller is safe.
package final class CoreGraphicsSyntheticEventPoster: SyntheticEventPosting, @unchecked Sendable {
    private let source: CGEventSource

    package init() throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw SyntheticEventPosterError.eventSourceUnavailable
        }
        source.userData = syntheticEventMarker
        // macOS otherwise ignores real input for 0.25 s after a synthetic
        // mouse event, which would make the trackball feel dead for a quarter
        // second after every remapped click.
        source.localEventsSuppressionInterval = 0
        self.source = source
    }

    package func post(_ events: [SyntheticEvent]) -> Bool {
        var posted = true
        for event in events {
            posted = emit(event) && posted
        }
        return posted
    }

    private func emit(_ event: SyntheticEvent) -> Bool {
        switch event {
        case let .keyChord(keyCode, modifiers):
            // The modifier is pressed and released around the key, because a
            // flag set on the key event alone never makes Control *be* down,
            // and the symbolic hotkeys this layer targets are matched against
            // the modifier state the window server believes is current.
            var events: [CGEvent] = []
            for stroke in SyntheticKeyChordPlanner.strokes(
                keyCode: keyCode,
                modifiers: modifiers
            ) {
                guard let event = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: CGKeyCode(stroke.virtualKey),
                    keyDown: stroke.isKeyDown
                ) else {
                    return false
                }
                event.flags = Self.flags(for: stroke.modifiers)
                events.append(event)
            }
            return dispatch(events)

        case let .otherMouseClick(buttonNumber):
            guard let location = CGEvent(source: nil)?.location,
                  let down = CGEvent(
                    mouseEventSource: source,
                    mouseType: .otherMouseDown,
                    mouseCursorPosition: location,
                    mouseButton: .center
                  ),
                  let up = CGEvent(
                    mouseEventSource: source,
                    mouseType: .otherMouseUp,
                    mouseCursorPosition: location,
                    mouseButton: .center
                  ) else {
                return false
            }
            // `CGMouseButton` only spells left, right and center, so buttons
            // beyond the third are addressed through the field directly.
            for event in [down, up] {
                event.setIntegerValueField(
                    .mouseEventButtonNumber,
                    value: Int64(buttonNumber)
                )
            }
            return dispatch([down, up])
        }
    }

    private func dispatch(_ events: [CGEvent]) -> Bool {
        for event in events {
            // Belt and braces: the source already carries the marker, but an
            // event that lost its source association must still be
            // recognisable or the tap would treat it as the user's input.
            event.setIntegerValueField(
                .eventSourceUserData,
                value: syntheticEventMarker
            )
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func flags(for modifiers: SynthesizedModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }
}
