import Foundation

/// Presentation-only ordering. It carries neither device evidence nor permission
/// to execute an operation; the app must revalidate the selected action's gate.
public enum PrecisionSetupGuide {
    public enum Step: Int, Sendable, CaseIterable, Hashable {
        case connection, firmware, restorePreview, selfTest, baseline, readiness, bind
    }

    public enum Progress: Sendable, Equatable {
        case pending
        case complete
        case working
        case blocked(String)
    }

    public enum State: Sendable, Equatable {
        case working
        case blocked(String)
        case next(Step)
        case readyForConfirmation
    }

    public static func evaluate(
        _ progress: [Step: Progress],
        operationInProgress: Bool,
        stopReason: String?,
        readiness: Readiness? = nil,
        completedJournalAvailable: Bool = false
    ) -> State {
        if let stopReason { return .blocked(stopReason) }
        if readiness == .recover { return .blocked("Recovery needs a separate review. Open recovery controls in Advanced.") }
        if completedJournalAvailable { return .blocked("A completed session record needs archiving. Open Advanced and review Retire completed runtime journal before preparing again.") }
        if operationInProgress || progress.values.contains(.working) { return .working }
        for step in Step.allCases {
            guard let status = progress[step] else {
                return .blocked("Setup information is unavailable. Open Advanced to review the current state.")
            }
            switch status {
            case .complete: continue
            case .pending: return .next(step)
            case let .blocked(reason): return .blocked(reason)
            case .working: return .working
            }
        }
        return .readyForConfirmation
    }

    /// Recheck immediately before dispatching a button's captured step. A
    /// delayed confirmation must never silently execute a different operation.
    public static func accepts(_ step: Step, current: State) -> Bool {
        current == .next(step)
    }
}

extension PrecisionSetupGuide {
    public enum Readiness: Sendable, Equatable { case activate, recover }

    /// A presentation-layer latch in addition to the runtime's one-use authority.
    /// A failed activation must not cause the guide to offer another attempt.
    public struct EnableAttempt: Sendable {
        public private(set) var consumed = false
        public init() {}
        public mutating func consume(expected: UUID, current: UUID?, ready: Bool) -> Bool {
            guard !consumed, ready, current == expected else { return false }
            consumed = true
            return true
        }
    }

    public static func shouldEnableAudio(expected: UUID, current: UUID?,
        diverted: Bool, recovery: Bool, disconnected: Bool,
        terminating: Bool, operationInProgress: Bool) -> Bool {
        current == expected && diverted && !recovery && !disconnected
            && !terminating && !operationInProgress
    }
}
