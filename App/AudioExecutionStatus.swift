import Foundation

enum AudioExecutionStatus: Sendable, Equatable {
    case disabled
    case ready(volumePercent: Int)
    case volumeAdjusting(currentPercent: Int, targetPercent: Int)
    case volumeChanged(percent: Int)
    case muteChanged(isMuted: Bool)
    case failed(message: String)

    var message: String {
        switch self {
        case .disabled:
            "Audio execution disabled"
        case let .ready(volumePercent):
            "Ready · volume \(volumePercent)%"
        case let .volumeAdjusting(currentPercent, targetPercent):
            "Volume \(currentPercent)% → \(targetPercent)%"
        case let .volumeChanged(percent):
            "Volume \(percent)%"
        case let .muteChanged(isMuted):
            isMuted ? "Muted" : "Unmuted"
        case let .failed(message):
            message
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
