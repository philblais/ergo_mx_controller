import Foundation

/// Values the sleep reconnect flow reports and receives. They describe app
/// bookkeeping only and carry no device authority.
public enum PrecisionSleepReconnect {
    public enum Decision: Sendable, Equatable {
        case ignored
        case began(UUID)
        case invalidated(UUID)
    }

    public enum Status: Sendable, Equatable {
        case pausing
        case paused
        case pauseFailed(detail: String)
        case invalidatedBySecondSleep
        case reopening
        case finished(Outcome)
    }

    public enum Outcome: Sendable, Equatable {
        case notReconnected
        case notReadyAfterWake
        case reconnected(audioRestored: Bool)
        case notVerifiedActive

        public var succeeded: Bool {
            if case .reconnected = self { return true }
            return false
        }
    }

    public enum ReopenResult: Sendable, Equatable {
        /// The wake capability may be used only on an observer run other than
        /// the one that held the endpoint before sleep, so that run is carried.
        case ready(previousObserverRunID: UUID?)
        case notReady
    }

    public enum ResumeResult: Sendable, Equatable {
        case active(audioEnabled: Bool)
        case notActive
    }
}

/// What the app hands over when the verified-active endpoint may roll over for
/// sleep. Its absence means the app is not in a state that may roll over.
public struct PrecisionSleepRollover<Run: Sendable> {
    public let restoresAudioAfterWake: Bool
    /// Whether the runtime owner that this shutdown claimed the operation flag
    /// for is still bound. A different owner's claim is never released here.
    public let ownerIsCurrent: @MainActor () -> Bool
    public let shutdown: @MainActor (_ cycleID: UUID) async throws -> Run

    public init(
        restoresAudioAfterWake: Bool,
        ownerIsCurrent: @escaping @MainActor () -> Bool,
        shutdown: @escaping @MainActor (_ cycleID: UUID) async throws -> Run
    ) {
        self.restoresAudioAfterWake = restoresAudioAfterWake
        self.ownerIsCurrent = ownerIsCurrent
        self.shutdown = shutdown
    }
}

/// Bookkeeping for one Mac sleep/wake Precision reconnect, kept out of the app
/// model so its stale-cycle and flag-claim rules are testable.
///
/// It decides which completions are still current and which claims to release.
/// It holds no device authority: the runtime owner validates every capability
/// itself, and nothing here can turn a stale or failed cycle into activation.
/// Every await is followed by a currency check, and only the current cycle may
/// finish.
@MainActor
public final class PrecisionSleepReconnectFlow<Run: Sendable> {
    public private(set) var cycleID: UUID?
    private(set) var shutdownTask: Task<Run?, Never>?
    private var restoresAudioAfterWake = false
    private var completionStarted = false

    private let pauseControls: @MainActor () -> Void
    private let revokeAutomaticStartup: @MainActor () -> Void
    private let setOperationInProgress: @MainActor (Bool) -> Void
    private let isTerminating: @MainActor () -> Bool
    private let report: @MainActor (UUID, PrecisionSleepReconnect.Status) -> Void

    public init(
        pauseControls: @escaping @MainActor () -> Void,
        revokeAutomaticStartup: @escaping @MainActor () -> Void,
        setOperationInProgress: @escaping @MainActor (Bool) -> Void,
        isTerminating: @escaping @MainActor () -> Bool,
        report: @escaping @MainActor (UUID, PrecisionSleepReconnect.Status) -> Void
    ) {
        self.pauseControls = pauseControls
        self.revokeAutomaticStartup = revokeAutomaticStartup
        self.setOperationInProgress = setOperationInProgress
        self.isTerminating = isTerminating
        self.report = report
    }

    /// Runs synchronously on the sleep notification, before the system may
    /// suspend the process.
    @discardableResult
    public func willSleep(
        _ rollover: PrecisionSleepRollover<Run>?
    ) -> PrecisionSleepReconnect.Decision {
        if let active = cycleID {
            // Sleeping again before reconnect finished. Nothing in flight may
            // complete this cycle, and audio stays off for review.
            revokeAutomaticStartup()
            invalidate()
            pauseControls()
            report(active, .invalidatedBySecondSleep)
            return .invalidated(active)
        }
        guard let rollover else { return .ignored }

        let id = UUID()
        cycleID = id
        completionStarted = false
        restoresAudioAfterWake = rollover.restoresAudioAfterWake
        pauseControls()
        setOperationInProgress(true)
        report(id, .pausing)
        let ownerIsCurrent = rollover.ownerIsCurrent
        let shutdown = rollover.shutdown
        shutdownTask = Task { [weak self] in
            // This task claimed the operation flag. A second sleep can
            // invalidate the cycle while shutdown is still running, and nothing
            // else would release the claim: the menu would say "Working…"
            // until quit. Every other claimant either requires the flag clear
            // or binds a different owner, which the identity check excludes.
            defer {
                if let self, ownerIsCurrent() { self.setOperationInProgress(false) }
            }
            do {
                let run = try await shutdown(id)
                guard let self, self.cycleID == id, !self.isTerminating() else {
                    return nil
                }
                self.report(id, .paused)
                return run
            } catch {
                guard let self, self.cycleID == id else { return nil }
                self.report(id, .pauseFailed(detail: String(describing: error)))
                return nil
            }
        }
        return .began(id)
    }

    /// Waits for this cycle's shutdown, then reopens and resumes GET-only.
    /// Returns nil when there is no cycle to complete or one already started.
    @discardableResult
    public func didWake(
        wakeRunIsUsable: @escaping @MainActor (Run, _ cycleID: UUID) -> Bool,
        wakeRunIsValid: @escaping @MainActor (Run) -> Bool,
        reopen: @escaping @MainActor () async -> PrecisionSleepReconnect.ReopenResult,
        resume: @escaping @MainActor (
            Run, _ restoreAudio: Bool, _ previousObserverRunID: UUID?
        ) async -> PrecisionSleepReconnect.ResumeResult
    ) -> Task<Void, Never>? {
        guard !completionStarted, let id = cycleID, let shutdownTask else {
            return nil
        }
        completionStarted = true
        return Task { [weak self] in
            let run = await shutdownTask.value
            guard let self, self.cycleID == id, !self.isTerminating() else { return }
            guard let run, wakeRunIsUsable(run, id) else {
                self.finish(id, .notReconnected)
                return
            }
            self.report(id, .reopening)
            let reopened = await reopen()
            guard case let .ready(previousObserverRunID) = reopened,
                  self.cycleID == id,
                  wakeRunIsValid(run) else {
                self.finish(id, .notReadyAfterWake)
                return
            }
            switch await resume(run, self.restoresAudioAfterWake, previousObserverRunID) {
            case let .active(audioEnabled):
                self.finish(id, .reconnected(audioRestored: audioEnabled))
            case .notActive:
                self.finish(id, .notVerifiedActive)
            }
        }
    }

    /// Termination closes admission: no cycle may complete and a later wake is
    /// ignored. An in-flight shutdown still releases its own claim.
    public func invalidateForTermination() {
        invalidate()
    }

    private func invalidate() {
        cycleID = nil
        completionStarted = true
        restoresAudioAfterWake = false
    }

    private func finish(_ id: UUID, _ outcome: PrecisionSleepReconnect.Outcome) {
        guard cycleID == id else { return }
        report(id, .finished(outcome))
        setOperationInProgress(false)
        cycleID = nil
        shutdownTask = nil
        completionStarted = false
        restoresAudioAfterWake = false
    }
}
