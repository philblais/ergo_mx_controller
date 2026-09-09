/// Presentation policy only. This owns neither startup services nor any
/// remapping, login registration, or Precision execution preference.
public struct ControllerLaunchPresentation: Sendable {
    public enum Reason: Sendable {
        case loginItem
        case otherOrUnknown
    }

    public static let hasPresentedPreferenceKey =
        "com.phib.MXErgoController.hasPresentedController"

    private var didDecide = false

    public init() {}

    /// Consume the launch decision even when it is quiet. Opening a menu or
    /// receiving another launch callback must not raise the window later.
    /// Explicit Open/Reopen requests bypass this one-shot launch policy.
    public mutating func shouldPresentOnLaunch(
        reason: Reason,
        hasPresentedBefore: Bool,
        needsAttention: Bool
    ) -> Bool {
        guard !didDecide else { return false }
        didDecide = true
        return reason != .loginItem || !hasPresentedBefore || needsAttention
    }

    public static func needsAttention(
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool,
        remappingRemembered: Bool,
        remappingEnabled: Bool,
        remappingNeedsAttention: Bool,
        loginItem: LoginItemRegistration,
        savedPrecisionNeedsReview: Bool
    ) -> Bool {
        !inputMonitoringGranted
            || (remappingRemembered && (!accessibilityGranted || !remappingEnabled))
            || remappingNeedsAttention
            || loginItem.needsAttention
            || savedPrecisionNeedsReview
    }
}
