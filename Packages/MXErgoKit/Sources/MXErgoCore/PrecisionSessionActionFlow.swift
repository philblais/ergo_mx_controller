import Foundation

/// Sequences the app's confirmed actions. Snapshots describe UI/runtime state;
/// they are not device evidence or authority to bypass the runtime's checks.
@MainActor
public final class PrecisionSessionActionFlow {
    public struct Snapshot: Sendable {
        public let bindingID: UUID?
        public let available: Set<PrecisionSessionActions.Action>
        public let bound: Bool
        public let admitted: Bool
        public let diverted: Bool
        public let recovery: Bool
        public let disconnected: Bool
        public let terminating: Bool

        public init(bindingID: UUID?, available: Set<PrecisionSessionActions.Action>,
            bound: Bool, admitted: Bool, diverted: Bool, recovery: Bool,
            disconnected: Bool, terminating: Bool) {
            self.bindingID = bindingID
            self.available = available
            self.bound = bound
            self.admitted = admitted
            self.diverted = diverted
            self.recovery = recovery
            self.disconnected = disconnected
            self.terminating = terminating
        }
    }

    public enum Outcome: Sendable, Equatable {
        case unavailable, busy, interrupted
        case restored, restorationFailed, released, releaseFailed
    }

    public private(set) var isPerforming = false

    public init() {}

    public func perform(_ action: PrecisionSessionActions.Action, expected: UUID,
        snapshot: @MainActor () -> Snapshot,
        pauseAudio: @MainActor () -> Void,
        deactivate: @MainActor () async -> Void,
        release: @MainActor () async -> Void) async -> Outcome {
        guard !isPerforming else { return .busy }
        guard !Task.isCancelled else { return .interrupted }
        let before = snapshot()
        guard !before.terminating, before.bound,
              PrecisionSessionActions.acceptsOwnerAction(action, expected: expected,
                current: before.bindingID, available: before.available) else { return .unavailable }
        switch action {
        case .deactivate:
            guard before.admitted, before.diverted, !before.recovery,
                  !before.disconnected else { return .unavailable }
        case .release:
            guard !before.admitted, !before.diverted else { return .unavailable }
        case .archive: return .unavailable
        }
        isPerforming = true
        defer { isPerforming = false }

        switch action {
        case .deactivate:
            pauseAudio()
            guard !Task.isCancelled else { return .interrupted }
            await deactivate()
            let after = snapshot()
            guard !Task.isCancelled, !after.terminating,
                  after.bindingID == expected else { return .interrupted }
            return after.bound && after.admitted && !after.diverted
                && !after.recovery && !after.disconnected ? .restored : .restorationFailed
        case .release:
            await release()
            let after = snapshot()
            guard !Task.isCancelled, !after.terminating else { return .interrupted }
            if let current = after.bindingID, current != expected { return .interrupted }
            return after.bindingID == nil && !after.bound && !after.admitted && !after.diverted
                ? .released : .releaseFailed
        case .archive:
            // Archive is deliberately rejected by acceptsOwnerAction above.
            return .unavailable
        }
    }
}
