import Foundation

public enum EventLayerAutostartDecision: Sendable, Equatable {
    /// The layer was not on when the app last quit.
    case stayOff
    /// Start it: it was on, and everything it needs is present.
    case start
    /// It was on, but a suppressing tap needs Accessibility. Say so rather
    /// than starting something that will not work.
    case blockedOnAccessibility
    case alreadyRunning
}

/// Decides whether a remembered "on" should arm the layer at launch.
///
/// Kept as a pure function because the interesting case is the one that is
/// easy to get wrong: a remembered preference plus a revoked permission must
/// produce a visible explanation, not a silent no-op and not an attempt that
/// fails somewhere deeper. Losing Accessibility between launches is ordinary —
/// a macOS update or a rebuild to a new path is enough.
public enum EventLayerAutostart {
    public static func decide(
        rememberedPreference: Bool,
        accessibilityGranted: Bool,
        alreadyRunning: Bool
    ) -> EventLayerAutostartDecision {
        guard rememberedPreference else { return .stayOff }
        guard !alreadyRunning else { return .alreadyRunning }
        guard accessibilityGranted else { return .blockedOnAccessibility }
        return .start
    }

    /// The preference key. Named in full because it lands in the user's
    /// defaults and a bare "enabled" there would be meaningless.
    public static let preferenceKey = "com.phib.MXErgoController.eventLayerEnabled"
}
