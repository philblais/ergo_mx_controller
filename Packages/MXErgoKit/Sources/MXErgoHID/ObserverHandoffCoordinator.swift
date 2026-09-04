import Foundation

package enum MXErgoObserverOwnershipDisposition: Sendable, Equatable {
    case neverAcquired
    case managerClosed
    case releaseUncertain(closeReturn: Int32)
}

/// Teardown truth for one observer run. Construction is intentionally hidden
/// inside the coordinator so a zero-pending, callback-quiesced receipt cannot
/// be fabricated by a future integration adapter.
package struct MXErgoObserverHandoffReceipt: Sendable, Equatable {
    package let runID: UUID
    package let pendingRequestCountAtStop: Int
    package let finalPendingRequestCount: Int
    package let callbackDeliveryQuiesced: Bool
    package let ownershipDisposition: MXErgoObserverOwnershipDisposition
}

/// Non-forgeable package capability for one exact observer run. A future
/// host-handoff adapter may retain this value, but only the originating
/// observer can construct and validate it.
package struct MXErgoObserverHandoffRun: Sendable, Equatable {
    package let runID: UUID
    let observerID: UUID

    init(observerID: UUID, runID: UUID) {
        self.observerID = observerID
        self.runID = runID
    }
}

/// Non-forgeable restart fence for one captured observer run. Installing it
/// keeps `start()` blocked after a clean stop until the matching token is
/// released. Abandoning the holder does not lift the fence.
package struct MXErgoObserverRestartFence: Sendable, Equatable {
    package let fenceID: UUID
    package let capturedRunID: UUID
    let observerID: UUID

    init(fenceID: UUID, capturedRunID: UUID, observerID: UUID) {
        self.fenceID = fenceID
        self.capturedRunID = capturedRunID
        self.observerID = observerID
    }
}

package enum MXErgoObserverHandoffWaitResult: Sendable, Equatable {
    case stopped(MXErgoObserverHandoffReceipt)
    case timedOut(runID: UUID)
    case cancelled(runID: UUID)
    case notRunning
    case runMismatch(expectedRunID: UUID, actualRunID: UUID?)
}

enum MXErgoObserverHandoffLifecycleState: Sendable, Equatable {
    case stopped
    case starting(runID: UUID)
    case running(runID: UUID)
    case stopping(runID: UUID)
    case releaseUncertain(runID: UUID, closeReturn: Int32)
}

struct MXErgoObserverRequestTicket: Sendable, Hashable {
    let runID: UUID
    let requestID: UUID
}

struct MXErgoObserverTeardownCalls {
    let clearRequestState: () -> Void
    let unscheduleManager: () -> Void
    let closeManager: () -> Int32
    let didQuiesceCallbacks: () -> Void
}

/// IOKit-free linearization point shared by the observer façade and its
/// run-loop owner. It owns lifecycle state, queued/active request tickets, and
/// async handoff waiters; only the InputLoop supplies system cleanup calls.
final class MXErgoObserverHandoffCoordinator: @unchecked Sendable {
    private enum State {
        case stopped(MXErgoObserverHandoffReceipt?)
        case starting(UUID)
        case running(UUID)
        case stopping(UUID, pendingAtStop: Int)
        case tearingDown(UUID, pendingAtStop: Int)
        case releaseUncertain(MXErgoObserverHandoffReceipt)
    }

    private struct Request {
        enum Phase {
            case queued
            case active
        }

        let acceptanceOrder: UInt64
        var phase: Phase
        let cancel: @Sendable () -> Void
    }

    private struct Waiter {
        let runID: UUID
        let continuation:
            CheckedContinuation<MXErgoObserverHandoffWaitResult, Never>
    }

    private struct TeardownPlan {
        let runID: UUID
        let pendingAtStop: Int
        let cancellations: [@Sendable () -> Void]
    }

    private struct InstalledFence {
        let fenceID: UUID
        let capturedRunID: UUID
    }

    private let lock = NSLock()
    private var state: State = .stopped(nil)
    private var requests: [MXErgoObserverRequestTicket: Request] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var nextRequestAcceptanceOrder: UInt64 = 0
    private var installedFence: InstalledFence?

    var lifecycleState: MXErgoObserverHandoffLifecycleState {
        lock.withLock {
            switch state {
            case .stopped:
                return .stopped
            case let .starting(runID):
                return .starting(runID: runID)
            case let .running(runID):
                return .running(runID: runID)
            case let .stopping(runID, _),
                 let .tearingDown(runID, _):
                return .stopping(runID: runID)
            case let .releaseUncertain(receipt):
                guard case let .releaseUncertain(closeReturn) =
                    receipt.ownershipDisposition else {
                    preconditionFailure("Invalid uncertain observer receipt")
                }
                return .releaseUncertain(
                    runID: receipt.runID,
                    closeReturn: closeReturn
                )
            }
        }
    }

    var restartFenceCapturedRunID: UUID? {
        lock.withLock { installedFence?.capturedRunID }
    }

    func beginRun() -> UUID? {
        lock.withLock {
            guard installedFence == nil else { return nil }
            switch state {
            case .stopped:
                let runID = UUID()
                state = .starting(runID)
                return runID
            case .starting, .running, .stopping, .tearingDown,
                 .releaseUncertain:
                return nil
            }
        }
    }

    func installRestartFence(capturedRunID: UUID) -> UUID? {
        lock.withLock {
            guard installedFence == nil else { return nil }
            let matchesCapturedRun: Bool
            switch state {
            case let .starting(runID), let .running(runID):
                matchesCapturedRun = runID == capturedRunID
            case let .stopping(runID, _), let .tearingDown(runID, _):
                matchesCapturedRun = runID == capturedRunID
            case let .stopped(receipt?):
                matchesCapturedRun = receipt.runID == capturedRunID
            case let .releaseUncertain(receipt):
                matchesCapturedRun = receipt.runID == capturedRunID
            case .stopped(nil):
                matchesCapturedRun = false
            }
            guard matchesCapturedRun else { return nil }
            let fenceID = UUID()
            installedFence = InstalledFence(
                fenceID: fenceID,
                capturedRunID: capturedRunID
            )
            return fenceID
        }
    }

    func releaseRestartFence(fenceID: UUID) -> Bool {
        lock.withLock {
            guard installedFence?.fenceID == fenceID else { return false }
            installedFence = nil
            return true
        }
    }

    func markRunning(runID: UUID) -> Bool {
        lock.withLock {
            switch state {
            case let .starting(activeRunID) where activeRunID == runID:
                state = .running(runID)
                return true
            case let .running(activeRunID) where activeRunID == runID:
                return true
            case let .stopping(activeRunID, _)
                where activeRunID == runID:
                return false
            case let .tearingDown(activeRunID, _)
                where activeRunID == runID:
                return false
            default:
                return false
            }
        }
    }

    @discardableResult
    func beginStop(runID: UUID) -> Bool {
        lock.withLock {
            switch state {
            case let .starting(activeRunID) where activeRunID == runID:
                state = .stopping(runID, pendingAtStop: requestCount(runID))
                return true
            case let .running(activeRunID) where activeRunID == runID:
                state = .stopping(runID, pendingAtStop: requestCount(runID))
                return true
            case let .stopping(activeRunID, _)
                where activeRunID == runID:
                return true
            case let .tearingDown(activeRunID, _)
                where activeRunID == runID:
                return true
            default:
                return false
            }
        }
    }

    func registerRequest(
        runID: UUID,
        cancel: @escaping @Sendable () -> Void
    ) -> MXErgoObserverRequestTicket? {
        lock.withLock {
            switch state {
            case let .starting(activeRunID) where activeRunID == runID:
                return insertRequest(runID: runID, cancel: cancel)
            case let .running(activeRunID) where activeRunID == runID:
                return insertRequest(runID: runID, cancel: cancel)
            default:
                return nil
            }
        }
    }

    /// A queued run-loop block must win this transition before doing any HID
    /// work. Once stop begins, queued work remains registered only so teardown
    /// can deliver its intentional-shutdown result exactly once.
    func activateRequest(_ ticket: MXErgoObserverRequestTicket) -> Bool {
        lock.withLock {
            guard var request = requests[ticket] else { return false }
            switch state {
            case let .starting(activeRunID) where activeRunID == ticket.runID:
                request.phase = .active
                requests[ticket] = request
                return true
            case let .running(activeRunID) where activeRunID == ticket.runID:
                request.phase = .active
                requests[ticket] = request
                return true
            default:
                return false
            }
        }
    }

    private func insertRequest(
        runID: UUID,
        cancel: @escaping @Sendable () -> Void
    ) -> MXErgoObserverRequestTicket {
        let ticket = MXErgoObserverRequestTicket(
            runID: runID,
            requestID: UUID()
        )
        let order = nextRequestAcceptanceOrder
        nextRequestAcceptanceOrder &+= 1
        requests[ticket] = Request(
            acceptanceOrder: order,
            phase: .queued,
            cancel: cancel
        )
        return ticket
    }

    /// Returns true exactly once. The caller may deliver its normal result
    /// only when it wins removal of the ticket.
    func completeRequest(_ ticket: MXErgoObserverRequestTicket) -> Bool {
        lock.withLock { requests.removeValue(forKey: ticket) != nil }
    }

    func performTeardown(
        runID: UUID,
        managerWasAcquired: Bool,
        calls: MXErgoObserverTeardownCalls
    ) -> MXErgoObserverHandoffReceipt? {
        guard let plan = takeTeardownPlan(runID: runID) else { return nil }
        calls.clearRequestState()

        let ownershipDisposition: MXErgoObserverOwnershipDisposition
        if managerWasAcquired {
            calls.unscheduleManager()
            let closeReturn = calls.closeManager()
            ownershipDisposition = closeReturn == 0
                ? .managerClosed
                : .releaseUncertain(closeReturn: closeReturn)
        } else {
            ownershipDisposition = .neverAcquired
        }

        for cancel in plan.cancellations { cancel() }
        calls.didQuiesceCallbacks()

        let receipt = MXErgoObserverHandoffReceipt(
            runID: plan.runID,
            pendingRequestCountAtStop: plan.pendingAtStop,
            finalPendingRequestCount: 0,
            callbackDeliveryQuiesced: true,
            ownershipDisposition: ownershipDisposition
        )
        publish(receipt)
        return receipt
    }

    func waitForStop(
        runID: UUID,
        timeoutNanoseconds: UInt64
    ) async -> MXErgoObserverHandoffWaitResult {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var registered = false
                let immediate: MXErgoObserverHandoffWaitResult? = lock.withLock {
                    if let receipt = terminalReceipt(runID: runID) {
                        return MXErgoObserverHandoffWaitResult.stopped(receipt)
                    }
                    if Task.isCancelled {
                        return .cancelled(runID: runID)
                    }
                    waiters[waiterID] = Waiter(
                        runID: runID,
                        continuation: continuation
                    )
                    registered = true
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                    return
                }
                guard registered else { return }
                let delay = Int(min(timeoutNanoseconds, UInt64(Int.max)))
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + .nanoseconds(delay)
                ) { [weak self] in
                    self?.finishWaiter(
                        waiterID,
                        result: .timedOut(runID: runID)
                    )
                }
            }
        } onCancel: { [weak self] in
            self?.finishWaiter(
                waiterID,
                result: .cancelled(runID: runID)
            )
        }
    }

    func latestTerminalReceipt() -> MXErgoObserverHandoffReceipt? {
        lock.withLock {
            switch state {
            case let .stopped(receipt): return receipt
            case let .releaseUncertain(receipt): return receipt
            default: return nil
            }
        }
    }

    private func requestCount(_ runID: UUID) -> Int {
        requests.keys.filter { $0.runID == runID }.count
    }

    private func takeTeardownPlan(runID: UUID) -> TeardownPlan? {
        lock.withLock {
            let pendingAtStop: Int
            switch state {
            case let .starting(activeRunID) where activeRunID == runID:
                pendingAtStop = requestCount(runID)
            case let .running(activeRunID) where activeRunID == runID:
                pendingAtStop = requestCount(runID)
            case let .stopping(activeRunID, recordedPending)
                where activeRunID == runID:
                pendingAtStop = recordedPending
            case .tearingDown, .stopped, .releaseUncertain:
                return nil
            default:
                return nil
            }
            state = .tearingDown(runID, pendingAtStop: pendingAtStop)
            let matching = requests
                .filter { $0.key.runID == runID }
                .sorted {
                    $0.value.acceptanceOrder < $1.value.acceptanceOrder
                }
            for (ticket, _) in matching { requests.removeValue(forKey: ticket) }
            return TeardownPlan(
                runID: runID,
                pendingAtStop: pendingAtStop,
                cancellations: matching.map(\.value.cancel)
            )
        }
    }

    private func terminalReceipt(
        runID: UUID
    ) -> MXErgoObserverHandoffReceipt? {
        switch state {
        case let .stopped(receipt?) where receipt.runID == runID:
            return receipt
        case let .releaseUncertain(receipt) where receipt.runID == runID:
            return receipt
        default:
            return nil
        }
    }

    private func publish(_ receipt: MXErgoObserverHandoffReceipt) {
        let continuations = lock.withLock { () -> [Waiter] in
            switch receipt.ownershipDisposition {
            case .neverAcquired, .managerClosed:
                state = .stopped(receipt)
            case .releaseUncertain:
                state = .releaseUncertain(receipt)
            }
            let matching = waiters.filter { $0.value.runID == receipt.runID }
            for (id, _) in matching { waiters.removeValue(forKey: id) }
            return matching.map(\.value)
        }
        for waiter in continuations {
            waiter.continuation.resume(returning: .stopped(receipt))
        }
    }

    private func finishWaiter(
        _ id: UUID,
        result: MXErgoObserverHandoffWaitResult
    ) {
        let continuation = lock.withLock {
            waiters.removeValue(forKey: id)?.continuation
        }
        continuation?.resume(returning: result)
    }
}
