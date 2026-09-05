import CoreGraphics
import Foundation
import MXErgoCore
import MXErgoEventSynthesis

/// Which physical tilt a positive `scrollWheelEventDeltaAxis2` means.
///
/// Settled on hardware on 2026-09-05, and the answer is that it is **not a
/// property of the trackball**. The device's own AC Pan value is invariant —
/// left is `-1` and right is `+1` under every setting — but macOS inverts the
/// scroll event it publishes from it when "natural scrolling" is on:
///
/// | natural scrolling | tilt left | tilt right |
/// |---|---|---|
/// | off | axis2 `+1` | axis2 `-1` |
/// | on  | axis2 `-1` | axis2 `+1` |
///
/// So a compiled-in constant would be right for one setting and silently
/// reverse back and forward for the other. It is derived from the preference
/// instead, and this is the only place that derives it.
package enum HorizontalScrollConvention: Sendable, Equatable {
    case positiveIsLeft
    case positiveIsRight

    /// The observed relationship. Natural scrolling on makes the scroll event
    /// agree with the device's own AC Pan sign; off inverts it.
    package static func forNaturalScrolling(
        isEnabled: Bool
    ) -> HorizontalScrollConvention {
        isEnabled ? .positiveIsRight : .positiveIsLeft
    }

    package static func current(
        in defaults: UserDefaults = .standard
    ) -> HorizontalScrollConvention {
        forNaturalScrolling(
            isEnabled: NaturalScrollDirection.isEnabled(in: defaults)
        )
    }

    package func direction(
        forDeltaAxis2 delta: Int64
    ) -> MappedControlHorizontalSwipe? {
        guard delta != 0 else { return nil }
        switch self {
        case .positiveIsLeft: return delta > 0 ? .left : .right
        case .positiveIsRight: return delta > 0 ? .right : .left
        }
    }
}

/// Reduces a CGEvent to the scalars the pure policy understands.
///
/// It takes the field values rather than a `CGEvent` so the whole translation
/// is testable without a window server, and so the only code that reads a live
/// event is the handful of `getIntegerValueField` calls in the tap callback.
package enum ObservedEventDecoder {
    /// Signed horizontal units in the policy's own convention, where negative
    /// is a left tilt. The convention flip lives here rather than in the
    /// policy so the policy never has to know how macOS spells a direction.
    package static func decode(
        type: CGEventType,
        buttonNumber: Int64,
        deltaAxis1: Int64,
        deltaAxis2: Int64,
        isContinuous: Int64,
        convention: HorizontalScrollConvention = .current()
    ) -> ObservedEventKind? {
        switch type {
        case .otherMouseDown:
            return .otherMouseDown(buttonNumber: Int(buttonNumber))
        case .otherMouseUp:
            return .otherMouseUp(buttonNumber: Int(buttonNumber))
        case .scrollWheel:
            let horizontal: Int
            switch convention.direction(forDeltaAxis2: deltaAxis2) {
            case .none: horizontal = 0
            case .left: horizontal = -abs(Int(deltaAxis2))
            case .right: horizontal = abs(Int(deltaAxis2))
            }
            return .scroll(
                horizontalUnits: horizontal,
                verticalUnits: Int(deltaAxis1),
                isContinuous: isContinuous != 0
            )
        default:
            // The tap's mask admits nothing else. Anything that arrives anyway
            // is returned unrecognised so the callback passes it through.
            return nil
        }
    }
}
