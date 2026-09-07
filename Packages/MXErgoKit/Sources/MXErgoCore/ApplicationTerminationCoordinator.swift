import Foundation

public enum ApplicationTerminationDecision: Sendable, Equatable {
    case terminateNow
    case terminateLater
    case cancel
}

public enum ApplicationTerminationState: Sendable, Equatable {
    case idle
    case draining
    case waitingAfterDeadline
    case ready
    case blocked
}

/// One cleanup operation shared by every ordinary termination request. A reply
/// deadline cancels only the request to quit, never physical cleanup. Resources
/// remain retained until cleanup actually finishes.
@MainActor
public final class ApplicationTerminationCoordinator {
    public private(set) var state: ApplicationTerminationState = .idle
    private let closeAdmission: @MainActor () -> Void
    private let cleanup: @MainActor () async -> Bool
    private let reply: @MainActor (Bool) -> Void
    private let stateChanged: @MainActor (ApplicationTerminationState) -> Void
    private let waitForDeadline: @MainActor () async throws -> Void
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var pendingRequest: UUID?

    public init(
        closeAdmission: @escaping @MainActor () -> Void,
        cleanup: @escaping @MainActor () async -> Bool,
        reply: @escaping @MainActor (Bool) -> Void,
        stateChanged: @escaping @MainActor (ApplicationTerminationState) -> Void,
        waitForDeadline: @escaping @MainActor () async throws -> Void
    ) {
        self.closeAdmission = closeAdmission
        self.cleanup = cleanup
        self.reply = reply
        self.stateChanged = stateChanged
        self.waitForDeadline = waitForDeadline
    }

    public func requestTermination() -> ApplicationTerminationDecision {
        switch state {
        case .ready: return .terminateNow
        case .blocked: return .cancel
        case .idle, .draining, .waitingAfterDeadline: break
        }
        guard pendingRequest == nil else { return .terminateLater }
        let request = UUID()
        pendingRequest = request
        let needsCleanup = state == .idle
        transition(to: .draining)
        if needsCleanup {
            // Close admission synchronously, before the first suspension.
            closeAdmission()
            cleanupTask = Task {
                let mayTerminate = await self.cleanup()
                self.transition(to: mayTerminate ? .ready : .blocked)
                self.cleanupTask = nil
                self.deadlineTask?.cancel()
                self.deadlineTask = nil
                if self.pendingRequest != nil {
                    self.pendingRequest = nil
                    self.reply(mayTerminate)
                }
            }
        }
        deadlineTask = Task {
            do { try await self.waitForDeadline() }
            catch { return }
            guard self.pendingRequest == request else { return }
            self.pendingRequest = nil
            self.deadlineTask = nil
            self.transition(to: .waitingAfterDeadline)
            self.reply(false)
        }
        return .terminateLater
    }

    private func transition(to state: ApplicationTerminationState) {
        self.state = state
        stateChanged(state)
    }
}
