import Foundation
import MXErgoHID
import MXErgoHIDPP
import MXErgoPrecisionRuntimeAdmission

/// Fresh repository evidence sampled only after observer teardown succeeds.
/// It prevents a receipt from echoing stale admission arguments as proof.
package struct PrecisionRuntimeObserverHostEvidence: Sendable, Equatable {
    package let session: DeviceTransactionSession
    package let rootGeneration: UInt64

    package init(
        session: DeviceTransactionSession,
        rootGeneration: UInt64
    ) {
        self.session = session
        self.rootGeneration = rootGeneration
    }
}

package enum PrecisionRuntimeObserverHostHandoffError:
    Error, Sendable, Equatable
{
    case observerNotRunning
    case requestBindingMismatch
    case observerRunMismatch(expectedRunID: UUID, actualRunID: UUID?)
    case observerStopTimedOut(runID: UUID)
    case observerStopCancelled(runID: UUID)
    case observerWasNeverAcquired
    case observerReleaseUncertain(closeReturn: Int32)
    case invalidObserverReceipt
    case evidenceUnavailable
    case evidenceChangedAfterStop
}

/// One-shot, productless bridge between a captured observer run and runtime
/// admission. It proves that the authorized run drained and released its
/// manager. A separate lifecycle owner must hold the observer restart fence
/// through runtime ownership, shutdown, quit, and session rollover.
package actor PrecisionRuntimeObserverHostHandoff:
    PrecisionRuntimeHostHandoff
{
    package typealias EvidenceProvider = @Sendable () async throws
        -> PrecisionRuntimeObserverHostEvidence

    typealias StopOperation = @Sendable (UInt64) async
        -> MXErgoObserverHandoffWaitResult

    private struct Binding: Sendable {
        let launchID: UUID
        let session: DeviceTransactionSession
        let rootGeneration: UInt64
        let observerRunID: UUID

        func matches(
            launchID: UUID,
            session: DeviceTransactionSession,
            rootGeneration: UInt64,
            observerRunID: UUID
        ) -> Bool {
            self.launchID == launchID
                && self.session == session
                && self.rootGeneration == rootGeneration
                && self.observerRunID == observerRunID
        }
    }

    private typealias Outcome = Result<
        PrecisionRuntimeHostHandoffReceipt,
        PrecisionRuntimeObserverHostHandoffError
    >

    private enum State {
        case ready
        case stopping(Task<Outcome, Never>)
        case terminal(Outcome)
    }

    private let binding: Binding
    private let evidenceProvider: EvidenceProvider
    private let stopOperation: StopOperation
    private var state: State = .ready

    /// Captures the exact observer run and the narrow launch/session/root
    /// binding before admission starts. The full intent is not retained.
    package init(
        observer: MXErgoObserver,
        intent: PrecisionRuntimeAdmissionIntent,
        evidenceProvider: @escaping EvidenceProvider
    ) throws {
        guard let handoffRun = observer.captureHandoffRun() else {
            throw PrecisionRuntimeObserverHostHandoffError.observerNotRunning
        }
        guard handoffRun.runID == intent.observerRunID else {
            throw PrecisionRuntimeObserverHostHandoffError.observerRunMismatch(
                expectedRunID: intent.observerRunID,
                actualRunID: handoffRun.runID
            )
        }
        binding = Binding(
            launchID: intent.launchID,
            session: intent.session,
            rootGeneration: intent.rootGeneration,
            observerRunID: handoffRun.runID
        )
        self.evidenceProvider = evidenceProvider
        stopOperation = { [observer, handoffRun] timeoutNanoseconds in
            await observer.stopForHandoff(
                expectedRun: handoffRun,
                timeoutNanoseconds: timeoutNanoseconds
            )
        }
    }

    /// Internal seam for deterministic, hardware-free contract tests.
    init(
        launchID: UUID,
        session: DeviceTransactionSession,
        rootGeneration: UInt64,
        observerRunID: UUID,
        evidenceProvider: @escaping EvidenceProvider,
        stopOperation: @escaping StopOperation
    ) {
        binding = Binding(
            launchID: launchID,
            session: session,
            rootGeneration: rootGeneration,
            observerRunID: observerRunID
        )
        self.evidenceProvider = evidenceProvider
        self.stopOperation = stopOperation
    }

    package func stopAndWait(
        launchID: UUID,
        expectedSession: DeviceTransactionSession,
        expectedRootGeneration: UInt64,
        expectedObserverRunID: UUID,
        timeoutNanoseconds: UInt64
    ) async throws -> PrecisionRuntimeHostHandoffReceipt {
        guard binding.matches(
            launchID: launchID,
            session: expectedSession,
            rootGeneration: expectedRootGeneration,
            observerRunID: expectedObserverRunID
        ) else {
            throw PrecisionRuntimeObserverHostHandoffError
                .requestBindingMismatch
        }

        let task: Task<Outcome, Never>
        switch state {
        case .ready:
            let binding = self.binding
            let stopOperation = self.stopOperation
            let evidenceProvider = self.evidenceProvider
            task = Task {
                await Self.performHandoff(
                    binding: binding,
                    timeoutNanoseconds: timeoutNanoseconds,
                    stopOperation: stopOperation,
                    evidenceProvider: evidenceProvider
                )
            }
            state = .stopping(task)
        case let .stopping(existing):
            task = existing
        case let .terminal(outcome):
            return try outcome.get()
        }

        let outcome = await task.value
        state = .terminal(outcome)
        return try outcome.get()
    }

    private static func performHandoff(
        binding: Binding,
        timeoutNanoseconds: UInt64,
        stopOperation: @escaping StopOperation,
        evidenceProvider: @escaping EvidenceProvider
    ) async -> Outcome {
        let stopResult = await stopOperation(timeoutNanoseconds)
        let observerReceipt: MXErgoObserverHandoffReceipt
        switch stopResult {
        case let .stopped(receipt):
            observerReceipt = receipt
        case let .timedOut(runID):
            return .failure(.observerStopTimedOut(runID: runID))
        case let .cancelled(runID):
            return .failure(.observerStopCancelled(runID: runID))
        case .notRunning:
            return .failure(.observerNotRunning)
        case let .runMismatch(expectedRunID, actualRunID):
            return .failure(.observerRunMismatch(
                expectedRunID: expectedRunID,
                actualRunID: actualRunID
            ))
        }

        guard observerReceipt.runID == binding.observerRunID,
              observerReceipt.finalPendingRequestCount == 0,
              observerReceipt.callbackDeliveryQuiesced else {
            return .failure(.invalidObserverReceipt)
        }
        switch observerReceipt.ownershipDisposition {
        case .managerClosed:
            break
        case .neverAcquired:
            return .failure(.observerWasNeverAcquired)
        case let .releaseUncertain(closeReturn):
            return .failure(.observerReleaseUncertain(
                closeReturn: closeReturn
            ))
        }

        let evidence: PrecisionRuntimeObserverHostEvidence
        do {
            evidence = try await evidenceProvider()
        } catch {
            return .failure(.evidenceUnavailable)
        }
        guard evidence.session == binding.session,
              evidence.rootGeneration == binding.rootGeneration else {
            return .failure(.evidenceChangedAfterStop)
        }

        return .success(PrecisionRuntimeHostHandoffReceipt(
            launchID: binding.launchID,
            session: binding.session,
            rootGeneration: binding.rootGeneration,
            observerRunID: binding.observerRunID,
            pendingRequestCount: observerReceipt.finalPendingRequestCount,
            observerWasUnscheduled: true,
            observerDeviceWasClosed: true
        ))
    }
}
