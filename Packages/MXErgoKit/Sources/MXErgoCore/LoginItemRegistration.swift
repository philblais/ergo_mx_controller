import Foundation

/// Whether the app is set to launch at login, in the four states macOS
/// actually has.
///
/// `requiresApproval` is the one that matters. Registering succeeds, the app is
/// listed in Login Items, and macOS silently declines to launch it until a
/// person approves it there. Reporting that as "on" would be a lie the user
/// only discovers after the next restart.
public enum LoginItemRegistration: Sendable, Equatable {
    case notRegistered
    case registered
    case requiresApproval
    case notFound

    public var isRegistered: Bool { self == .registered }

    public var needsAttention: Bool {
        self == .requiresApproval || self == .notFound
    }

    public var message: String {
        switch self {
        case .notRegistered:
            "Not launching at login"
        case .registered:
            "Launches at login"
        case .requiresApproval:
            "Registered, but macOS needs you to approve it in "
                + "System Settings › General › Login Items before it will start"
        case .notFound:
            "macOS cannot find this app bundle to register it. This happens "
                + "with builds run from a temporary location."
        }
    }
}
