import Foundation
import MXErgoHIDPP
import MXErgoPrecisionTransport

enum PrecisionWriteLifecycleError: Error, Sendable, Equatable {
    case invalidBinding
    case invalidFrame
    case singleFlightViolation
    case duplicateRequest(UUID)
    case shuttingDown
    case tombstoneCapacityExceeded
}

package enum PrecisionReviewedOutputKind: Sendable, Equatable, Hashable {
    case getReporting
    case applyTemporaryDiversion
    case restoreTemporaryDiversion
}

/// Owned record passed to the mandatory injected blocking call.
/// No pointer or device type crosses this pure target.
package struct PrecisionReviewedOutputRecord: Sendable, Equatable {
    package let requestID: UUID
    package let kind: PrecisionReviewedOutputKind
    package let bytes: [UInt8]
    package let device: JournalDeviceIdentity
    package let connectionEpoch: UInt64
    package let rootGeneration: UInt64

    // Deliberately module-internal. Sibling targets may inspect records handed
    // to the reviewed blocking seam but cannot manufacture one and bypass the
    // lifecycle's packet and binding validation.
    init(
        requestID: UUID,
        kind: PrecisionReviewedOutputKind,
        bytes: [UInt8],
        device: JournalDeviceIdentity,
        connectionEpoch: UInt64,
        rootGeneration: UInt64
    ) {
        self.requestID = requestID
        self.kind = kind
        self.bytes = bytes
        self.device = device
        self.connectionEpoch = connectionEpoch
        self.rootGeneration = rootGeneration
    }
}

package protocol PrecisionTransportDrainingReportWriter:
    PrecisionTransportReportWriter {
    /// Sticky teardown. Logical write cancellation is not physical quiescence;
    /// this returns only after every entered blocking call has actually returned.
    func shutdownAndDrain() async
}

/// The sole package boundary for constructing the reviewed write lifecycle.
/// It returns only the writer-plus-drain capability: callers cannot access the
/// scheduler, state machine, metrics, or record initializer.
package enum PrecisionWriteLifecycleFactory {
    package typealias BlockingCall = @Sendable (
        PrecisionReviewedOutputRecord
    ) -> Int32

    package static func make(
        plan: PrecisionTemporaryDiversionPlan,
        binding: PrecisionTransportBinding,
        blockingCall: @escaping BlockingCall
    ) throws -> any PrecisionTransportDrainingReportWriter {
        try PrecisionBlockingWriteLifecycle(
            plan: plan,
            binding: binding,
            blockingCall: blockingCall
        )
    }
}

/// Productless, IOKit-free lifecycle for one future blocking output seam.
///
/// `queued -> entered` is the may-have-dispatched linearization point. A
/// cancellation after entry promptly resolves the adapter-facing write while
/// the private executor, owned record, injected closure, and captured lifetime
/// anchor remain retained until the blocking call returns. There is no default
/// dispatcher and this target has no application or helper client.
final class PrecisionBlockingWriteLifecycle:
    PrecisionTransportDrainingReportWriter,
    @unchecked Sendable {
    typealias BlockingCall = @Sendable (PrecisionReviewedOutputRecord) -> Int32
    typealias Scheduler = @Sendable (@escaping @Sendable () -> Void) -> Void

    private enum LifecycleState: Sendable, Equatable {
        case accepting
        case shuttingDown
        case stopped
    }

    private final class Pending: @unchecked Sendable {
        let record: PrecisionReviewedOutputRecord
        var continuation: CheckedContinuation<Int32, any Error>?

        init(
            record: PrecisionReviewedOutputRecord,
            continuation: CheckedContinuation<Int32, any Error>
        ) {
            self.record = record
            self.continuation = continuation
        }
    }

    private struct Draining: @unchecked Sendable {
        let pending: Pending
        let firstReason: PrecisionTransportReportIOError
    }

    private enum RequestState: @unchecked Sendable {
        case none
        case queued(Pending)
        case entered(Pending)
        case draining(Draining)

        var requestID: UUID? {
            switch self {
            case .none:
                return nil
            case let .queued(pending), let .entered(pending):
                return pending.record.requestID
            case let .draining(draining):
                return draining.pending.record.requestID
            }
        }
    }

    private enum Tombstone: Sendable, Equatable {
        case cancelled(PrecisionTransportReportIOError)
        case completed
    }

    private let binding: PrecisionTransportBinding
    private let reviewedBytes: [PrecisionReviewedOutputKind: [UInt8]]
    private let blockingCall: BlockingCall
    private let scheduler: Scheduler
    private let condition = NSCondition()
    private let tombstoneLimit: Int
    private var lifecycleState: LifecycleState = .accepting
    private var requestState: RequestState = .none
    private var tombstones: [UUID: Tombstone] = [:]
    private var tombstoneCapacityWasExceeded = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var entryCountStorage = 0
    private var resumeCountStorage = 0
    private var lateDrainCountStorage = 0
    private var enteredKindsStorage: [PrecisionReviewedOutputKind] = []

    init(
        plan: PrecisionTemporaryDiversionPlan,
        binding: PrecisionTransportBinding,
        tombstoneLimit: Int = 64,
        scheduler: Scheduler? = nil,
        blockingCall: @escaping BlockingCall
    ) throws {
        guard tombstoneLimit > 0,
              plan.device == binding.session.device,
              binding.session.featureID == ReprogControlsV4.featureID,
              binding.session.featureVersion == 3,
              binding.session.featureIndex == plan.featureIndex,
              plan.featureVersion == 3 else {
            throw PrecisionWriteLifecycleError.invalidBinding
        }
        let expectedGet = try ReprogControlsV4.getReportingRequest(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            featureIndex: binding.session.featureIndex,
            deviceIndex: 0,
            softwareID: 0x0E
        )
        let expectedApply = try HIDPP20LongMessage(
            deviceIndex: 0,
            featureIndex: binding.session.featureIndex,
            functionID: 3,
            softwareID: 0x0E,
            parameters: [0x00, 0xED, 0x03, 0x00, 0x00]
        )
        let expectedRestore = try HIDPP20LongMessage(
            deviceIndex: 0,
            featureIndex: binding.session.featureIndex,
            functionID: 3,
            softwareID: 0x0E,
            parameters: [0x00, 0xED, 0x02, 0x00, 0x00]
        )
        guard plan.verificationRequest.bytes == expectedGet.bytes,
              plan.applySetRequest.bytes == expectedApply.bytes,
              plan.restoreSetRequest.bytes == expectedRestore.bytes else {
            throw PrecisionWriteLifecycleError.invalidBinding
        }

        self.binding = binding
        self.tombstoneLimit = tombstoneLimit
        self.blockingCall = blockingCall
        reviewedBytes = [
            .getReporting: expectedGet.bytes,
            .applyTemporaryDiversion: expectedApply.bytes,
            .restoreTemporaryDiversion: expectedRestore.bytes,
        ]
        if let scheduler {
            self.scheduler = scheduler
        } else {
            let executor = PrecisionPrivateSerialExecutor()
            self.scheduler = { operation in executor.schedule(operation) }
        }
    }

    func write(_ frame: PrecisionTransportOutputFrame) async throws -> Int32 {
        let record = try reviewedRecord(for: frame)
        return try await withCheckedThrowingContinuation { continuation in
            var immediate: Result<Int32, any Error>?
            var shouldSchedule = false
            condition.lock()
            if tombstoneCapacityWasExceeded {
                immediate = .failure(
                    PrecisionWriteLifecycleError.tombstoneCapacityExceeded
                )
            } else if lifecycleState != .accepting {
                immediate = .failure(PrecisionWriteLifecycleError.shuttingDown)
            } else if let tombstone = tombstones[record.requestID] {
                switch tombstone {
                case let .cancelled(reason):
                    immediate = .failure(reason)
                case .completed:
                    immediate = .failure(
                        PrecisionWriteLifecycleError.duplicateRequest(
                            record.requestID
                        )
                    )
                }
            } else if requestState.requestID != nil {
                immediate = .failure(
                    PrecisionWriteLifecycleError.singleFlightViolation
                )
            } else {
                requestState = .queued(Pending(
                    record: record,
                    continuation: continuation
                ))
                shouldSchedule = true
            }
            condition.unlock()

            if let immediate {
                continuation.resume(with: immediate)
            } else if shouldSchedule {
                scheduler { [self] in
                    enterAndInvoke(requestID: record.requestID)
                }
            }
        }
    }

    func cancelPendingWrite(
        requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        var continuation: CheckedContinuation<Int32, any Error>?
        var overflowedQueuedContinuation:
            CheckedContinuation<Int32, any Error>?
        var drainWaitersToResume: [CheckedContinuation<Void, Never>] = []
        condition.lock()
        switch requestState {
        case .none:
            if tombstones[requestID] == nil {
                _ = rememberTombstoneLocked(
                    .cancelled(reason),
                    requestID: requestID
                )
            }
            finishStoppedLifecycleIfDrainedLocked(
                drainWaiters: &drainWaitersToResume
            )
        case let .queued(pending) where pending.record.requestID == requestID:
            continuation = pending.continuation
            pending.continuation = nil
            requestState = .none
            _ = rememberTombstoneLocked(
                .cancelled(reason),
                requestID: requestID
            )
            resumeCountStorage += continuation == nil ? 0 : 1
            finishStoppedLifecycleIfDrainedLocked(
                drainWaiters: &drainWaitersToResume
            )
        case let .entered(pending) where pending.record.requestID == requestID:
            continuation = pending.continuation
            pending.continuation = nil
            requestState = .draining(Draining(
                pending: pending,
                firstReason: reason
            ))
            _ = rememberTombstoneLocked(
                .cancelled(reason),
                requestID: requestID
            )
            resumeCountStorage += continuation == nil ? 0 : 1
        case let .draining(draining)
            where draining.pending.record.requestID == requestID:
            break
        default:
            if tombstones[requestID] == nil {
                _ = rememberTombstoneLocked(
                    .cancelled(reason),
                    requestID: requestID
                )
            }
        }
        if tombstoneCapacityWasExceeded,
           case let .queued(pending) = requestState {
            overflowedQueuedContinuation = pending.continuation
            pending.continuation = nil
            requestState = .none
            resumeCountStorage += overflowedQueuedContinuation == nil ? 0 : 1
        }
        finishStoppedLifecycleIfDrainedLocked(
            drainWaiters: &drainWaitersToResume
        )
        condition.unlock()
        continuation?.resume(throwing: reason)
        overflowedQueuedContinuation?.resume(
            throwing: PrecisionWriteLifecycleError.tombstoneCapacityExceeded
        )
        drainWaitersToResume.forEach { $0.resume() }
    }

    func shutdownAndDrain() async {
        await withCheckedContinuation { continuation in
            var writeContinuation: CheckedContinuation<Int32, any Error>?
            var shouldResumeDrainImmediately = false
            condition.lock()
            if lifecycleState == .stopped {
                shouldResumeDrainImmediately = true
            } else {
                lifecycleState = .shuttingDown
                switch requestState {
                case .none:
                    lifecycleState = .stopped
                    shouldResumeDrainImmediately = true
                case let .queued(pending):
                    writeContinuation = pending.continuation
                    pending.continuation = nil
                    requestState = .none
                    _ = rememberTombstoneLocked(
                        .cancelled(.cancelled),
                        requestID: pending.record.requestID
                    )
                    resumeCountStorage += writeContinuation == nil ? 0 : 1
                    lifecycleState = .stopped
                    shouldResumeDrainImmediately = true
                case let .entered(pending):
                    writeContinuation = pending.continuation
                    pending.continuation = nil
                    requestState = .draining(Draining(
                        pending: pending,
                        firstReason: .cancelled
                    ))
                    _ = rememberTombstoneLocked(
                        .cancelled(.cancelled),
                        requestID: pending.record.requestID
                    )
                    resumeCountStorage += writeContinuation == nil ? 0 : 1
                    drainWaiters.append(continuation)
                case .draining:
                    drainWaiters.append(continuation)
                }
            }
            condition.unlock()

            writeContinuation?.resume(
                throwing: PrecisionTransportReportIOError.cancelled
            )
            if shouldResumeDrainImmediately { continuation.resume() }
        }
    }

    var entryCount: Int { withLock { entryCountStorage } }
    var resumeCount: Int { withLock { resumeCountStorage } }
    var lateDrainCount: Int { withLock { lateDrainCountStorage } }
    var enteredKinds: [PrecisionReviewedOutputKind] {
        withLock { enteredKindsStorage }
    }
    var isDraining: Bool {
        withLock {
            if case .draining = requestState { return true }
            return false
        }
    }
    var isStopped: Bool { withLock { lifecycleState == .stopped } }

    private func reviewedRecord(
        for frame: PrecisionTransportOutputFrame
    ) throws -> PrecisionReviewedOutputRecord {
        guard frame.reportType == .output,
              frame.reportID == HIDPP20LongMessage.reportID,
              frame.bytes.count == HIDPP20LongMessage.byteCount,
              frame.bytes.first == HIDPP20LongMessage.reportID,
              frame.device == binding.session.device,
              frame.connectionEpoch == binding.session.connectionEpoch,
              frame.rootGeneration == binding.rootGeneration,
              let kind = reviewedBytes.first(where: {
                $0.value == frame.bytes
              })?.key else {
            throw PrecisionWriteLifecycleError.invalidFrame
        }
        return PrecisionReviewedOutputRecord(
            requestID: frame.requestID,
            kind: kind,
            bytes: frame.bytes,
            device: frame.device,
            connectionEpoch: frame.connectionEpoch,
            rootGeneration: frame.rootGeneration
        )
    }

    private func enterAndInvoke(requestID: UUID) {
        let record: PrecisionReviewedOutputRecord
        condition.lock()
        guard case let .queued(pending) = requestState,
              pending.record.requestID == requestID,
              lifecycleState == .accepting else {
            condition.unlock()
            return
        }
        requestState = .entered(pending)
        record = pending.record
        entryCountStorage += 1
        enteredKindsStorage.append(record.kind)
        condition.unlock()

        let result = blockingCall(record)
        completeEnteredCall(requestID: requestID, result: result)
    }

    private func completeEnteredCall(requestID: UUID, result: Int32) {
        var continuation: CheckedContinuation<Int32, any Error>?
        var drainWaitersToResume: [CheckedContinuation<Void, Never>] = []
        condition.lock()
        switch requestState {
        case let .entered(pending) where pending.record.requestID == requestID:
            continuation = pending.continuation
            pending.continuation = nil
            requestState = .none
            _ = rememberTombstoneLocked(.completed, requestID: requestID)
            resumeCountStorage += continuation == nil ? 0 : 1
        case let .draining(draining)
            where draining.pending.record.requestID == requestID:
            _ = draining.firstReason
            requestState = .none
            lateDrainCountStorage += 1
        default:
            break
        }
        finishStoppedLifecycleIfDrainedLocked(
            drainWaiters: &drainWaitersToResume
        )
        condition.unlock()
        continuation?.resume(returning: result)
        drainWaitersToResume.forEach { $0.resume() }
    }

    @discardableResult
    private func rememberTombstoneLocked(
        _ tombstone: Tombstone,
        requestID: UUID
    ) -> Bool {
        if tombstones[requestID] != nil { return true }
        guard tombstones.count < tombstoneLimit else {
            tombstoneCapacityWasExceeded = true
            lifecycleState = .shuttingDown
            return false
        }
        tombstones[requestID] = tombstone
        return true
    }

    private func finishStoppedLifecycleIfDrainedLocked(
        drainWaiters: inout [CheckedContinuation<Void, Never>]
    ) {
        guard case .none = requestState,
              lifecycleState == .shuttingDown else { return }
        lifecycleState = .stopped
        drainWaiters = self.drainWaiters
        self.drainWaiters = []
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        condition.lock()
        defer { condition.unlock() }
        return operation()
    }
}

private final class PrecisionPrivateSerialExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.phib.MXErgoController.precision-blocking-write"
    )

    func schedule(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}
