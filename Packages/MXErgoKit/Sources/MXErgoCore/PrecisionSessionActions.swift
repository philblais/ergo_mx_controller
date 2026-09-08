import Foundation

/// Presentation gates supplement the runtime's authoritative checks.
public enum PrecisionSessionActions {
    public enum Action: Sendable, Hashable { case deactivate, release, archive }

    public static func available(bound: Bool, admitted: Bool, diverted: Bool,
        canDeactivate: Bool, canRelease: Bool, completedJournal: Bool,
        recovery: Bool, disconnected: Bool, busy: Bool, terminating: Bool) -> Set<Action> {
        guard !busy, !terminating else { return [] }
        if bound {
            if admitted && diverted && canDeactivate && !recovery && !disconnected { return [.deactivate] }
            if !admitted && !diverted && canRelease { return [.release] }
            return []
        }
        guard !admitted, !diverted, completedJournal, !recovery, !disconnected else { return [] }
        return [.archive]
    }

    public static func acceptsOwnerAction(_ action: Action, expected: UUID,
        current: UUID?, available: Set<Action>) -> Bool {
        action != .archive && expected == current && available.contains(action)
    }
}
