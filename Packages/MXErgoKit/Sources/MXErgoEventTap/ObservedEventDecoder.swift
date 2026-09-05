import CoreGraphics
import Foundation
import MXErgoCore
import MXErgoEventSynthesis

/// Which physical tilt a positive `scrollWheelEventDeltaAxis2` means.
///
/// UNVERIFIED against this trackball. The device reports tilt as AC Pan on the
/// Consumer page and macOS republishes it as horizontal scroll, but which sign
/// corresponds to a left tilt has never been observed here — the 2026-09-04
/// session confirmed only that tilt moves a carousel, not in which direction
/// the delta ran. One hardware session settles it, and this is the single
/// place that decides, so settling it is a one-line change.
package enum HorizontalScrollConvention: Sendable, Equatable {
    case positiveIsLeft
    case positiveIsRight

    package static let assumed = HorizontalScrollConvention.positiveIsLeft

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
        convention: HorizontalScrollConvention = .assumed
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
