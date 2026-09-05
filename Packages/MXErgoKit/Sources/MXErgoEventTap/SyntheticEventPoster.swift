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

/// Events that are built and ready, but not yet handed to the system.
///
/// The split exists because the window server drops an event posted from
/// inside an event-tap callback — established on hardware 2026-09-05, where
/// the identical chord worked when posted from a button and did nothing when
/// posted from the callback. Building stays inside the callback, because
/// construction is the only failure that can be detected, and delivery is
/// deferred until the callback has returned.
package protocol PreparedSyntheticEvents {
    func deliver()
}

package protocol SyntheticEventPosting: Sendable {
    /// Builds the events without handing them to the system. Returns nil if
    /// any could not be constructed, so the caller can pass the original
    /// through instead of swallowing it for nothing.
    func prepare(_ events: [SyntheticEvent]) -> (any PreparedSyntheticEvents)?
}

package enum SyntheticEventPosterError: Error, Sendable, Equatable {
    case eventSourceUnavailable
}

/// Builds the events. Delivery — the single `CGEvent.post` call site — lives
/// in `PreparedCoreGraphicsEvents` below.
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

    package func prepare(
        _ events: [SyntheticEvent]
    ) -> (any PreparedSyntheticEvents)? {
        var built: [CGEvent] = []
        for event in events {
            guard let constructed = build(event) else { return nil }
            built.append(contentsOf: constructed)
        }
        return PreparedCoreGraphicsEvents(events: built)
    }

    private func build(_ event: SyntheticEvent) -> [CGEvent]? {
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
                    return nil
                }
                event.flags = Self.flags(for: stroke.modifiers)
                events.append(event)
            }
            return stamped(events)

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
                return nil
            }
            // `CGMouseButton` only spells left, right and center, so buttons
            // beyond the third are addressed through the field directly.
            for event in [down, up] {
                event.setIntegerValueField(
                    .mouseEventButtonNumber,
                    value: Int64(buttonNumber)
                )
                // A real press carries a click count. Leaving it at zero says
                // "no click happened", which is not what a keyboard-equivalent
                // of a button press should say — the same unfaithfulness that
                // stopped a synthetic arrow key from matching a hotkey.
                event.setIntegerValueField(.mouseEventClickState, value: 1)
            }
            return stamped([down, up])
        }
    }

    private func stamped(_ events: [CGEvent]) -> [CGEvent] {
        for event in events {
            // Belt and braces: the source already carries the marker, but an
            // event that lost its source association must still be
            // recognisable or the tap would treat it as the user's input.
            event.setIntegerValueField(
                .eventSourceUserData,
                value: syntheticEventMarker
            )
        }
        return events
    }

    private static func flags(for modifiers: SynthesizedModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.numericPad) { flags.insert(.maskNumericPad) }
        if modifiers.contains(.secondaryFunction) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}


/// `@unchecked` because `CGEvent` predates `Sendable`. These are built and
/// delivered on the same thread — the tap's own run loop — and the type exists
/// only to carry them from the callback to the block that runs after it.
private final class PreparedCoreGraphicsEvents: PreparedSyntheticEvents, @unchecked Sendable {
    private let events: [CGEvent]

    init(events: [CGEvent]) {
        self.events = events
    }

    /// The **only** place in this package that calls `CGEvent.post`.
    func deliver() {
        for event in events {
            event.post(tap: .cghidEventTap)
        }
    }
}

/// Posts one reviewed event directly, outside any tap callback.
///
/// It exists to separate two failures that look identical from the outside: a
/// chord the system will not act on at all, and a chord the system will not act
/// on *when it is posted from inside an event-tap callback*. Those have
/// different fixes, and no amount of reading the code distinguishes them.
package enum SyntheticEventDiagnosticPost {
    package static func post(_ event: SyntheticEvent) throws -> Bool {
        guard let prepared = try CoreGraphicsSyntheticEventPoster()
            .prepare([event]) else {
            return false
        }
        prepared.deliver()
        return true
    }
}
