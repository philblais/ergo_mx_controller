import Foundation

/// One `scrollWheel` CGEvent, reduced to the fields that decide how wheel tilt
/// must be interpreted.
///
/// It exists to settle a question code cannot answer on its own: which sign of
/// the horizontal delta a *left* tilt produces. The device reports tilt as AC
/// Pan on the Consumer page, but macOS re-publishes it as a scroll event, and
/// that translation is affected by the "natural scrolling" preference. So the
/// sign is not a property of the trackball, and guessing it would put back and
/// forward the wrong way round half the time.
public struct ScrollTapSample: Sendable, Equatable {
    public let deltaAxis1: Int
    public let deltaAxis2: Int
    /// True for a trackpad's continuous gesture stream, false for the discrete
    /// notches a wheel or a wheel tilt produces. This is the only reliable way
    /// to tell one pointing device's horizontal scroll from another's.
    public let isContinuous: Bool
    public let wasSuppressed: Bool

    public init(
        deltaAxis1: Int,
        deltaAxis2: Int,
        isContinuous: Bool,
        wasSuppressed: Bool
    ) {
        self.deltaAxis1 = deltaAxis1
        self.deltaAxis2 = deltaAxis2
        self.isContinuous = isContinuous
        self.wasSuppressed = wasSuppressed
    }

    public var isHorizontal: Bool { deltaAxis2 != 0 }

    /// Signed values are printed with an explicit sign, because the sign is the
    /// entire content of the observation and a bare "1" invites a misreading.
    public var description: String {
        let axis1 = deltaAxis1 > 0 ? "+\(deltaAxis1)" : String(deltaAxis1)
        let axis2 = deltaAxis2 > 0 ? "+\(deltaAxis2)" : String(deltaAxis2)
        var parts = ["axis1 \(axis1)", "axis2 \(axis2)"]
        parts.append(isContinuous ? "continuous" : "discrete")
        if wasSuppressed { parts.append("suppressed") }
        return parts.joined(separator: " · ")
    }
}

/// The macOS "natural scrolling" preference, which inverts scroll deltas.
///
/// Recorded alongside a sample because a horizontal sign observed under one
/// setting says nothing about the other. `NSGlobalDomain` holds it as
/// `com.apple.swipescrolldirection`, true when natural scrolling is on.
public enum NaturalScrollDirection {
    public static let preferenceKey = "com.apple.swipescrolldirection"

    public static func isEnabled(
        in defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: preferenceKey)
    }

    public static func description(isEnabled: Bool) -> String {
        isEnabled ? "Natural scrolling on" : "Natural scrolling off"
    }
}
