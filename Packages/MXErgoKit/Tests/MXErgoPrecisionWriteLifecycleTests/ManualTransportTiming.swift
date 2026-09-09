import Foundation
import Testing
@testable import MXErgoPrecisionTransport

// Own both monotonic time and sleepers so deadline tests cannot expire during
// unrelated filesystem work. Cancellation removes a sleeper before resuming it.
final class ManualTransportTiming: @unchecked Sendable {
    private struct Sleeper {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }
    private let lock = NSLock()
    private var now: UInt64 = 0
    private var sleepers: [UUID: Sleeper] = [:]
    private var observers: [AsyncStream<Void>.Continuation] = []
    private var observationFinished = false

    var timing: PrecisionTransportTiming {
        PrecisionTransportTiming(
            nowNanoseconds: { self.lock.withLock { self.now } },
            sleepNanoseconds: { try await self.sleep($0) }
        )
    }

    var pendingCount: Int { lock.withLock { sleepers.count } }

    func sleep(_ nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        guard nanoseconds > 0 else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                var cancelled = false
                let ready: [AsyncStream<Void>.Continuation] = lock.withLock {
                    // Covers cancellation between the outer check and registration.
                    if Task.isCancelled { cancelled = true; return [] }
                    precondition(nanoseconds <= UInt64.max - now)
                    sleepers[id] = Sleeper(deadline: now + nanoseconds, continuation: continuation)
                    defer { observers.removeAll() }
                    return observers
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
                for observer in ready { observer.yield(()); observer.finish() }
            }
            try Task.checkCancellation()
        } onCancel: {
            let sleeper = self.lock.withLock { self.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func waitForPendingSleep() async throws {
        let (stream, observer) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock {
            if !sleepers.isEmpty { observer.yield(()); observer.finish() }
            else if observationFinished { observer.finish() }
            else { observers.append(observer) }
        }
        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() != nil else { throw ManualTimingError.operationEndedBeforeEntry }
    }

    func finishObservation() {
        let pending = lock.withLock {
            observationFinished = true
            defer { observers.removeAll() }
            return observers
        }
        for observer in pending { observer.finish() }
    }

    func advance(by nanoseconds: UInt64) {
        let due: [Sleeper] = lock.withLock {
            precondition(nanoseconds <= UInt64.max - now)
            now += nanoseconds
            let ids = sleepers.filter { $0.value.deadline <= now }.map(\.key)
            return ids.compactMap { sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

enum ManualTimingError: Error { case operationEndedBeforeEntry }

struct LifecycleEntrySignal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    func signal() { continuation.yield(()); continuation.finish() }
    func finish() { continuation.finish() }
    func wait() async throws {
        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() != nil else { throw ManualTimingError.operationEndedBeforeEntry }
    }
}

@Test func manualTransportTimingRemovesCancelledAndPrecancelledSleeps() async throws {
    let clock = ManualTransportTiming()
    try await clock.sleep(0)
    #expect(clock.pendingCount == 0)
    let task = Task { try await clock.sleep(25) }
    try await clock.waitForPendingSleep()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(clock.pendingCount == 0)
    clock.advance(by: 25)

    let precancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await clock.sleep(25)
    }
    await #expect(throws: CancellationError.self) { try await precancelled.value }
    #expect(clock.pendingCount == 0)
}

@Test func manualTransportTimingReleasesOnlyAtItsMonotonicDeadline() async throws {
    let clock = ManualTransportTiming()
    let task = Task { try await clock.sleep(25) }
    try await clock.waitForPendingSleep()
    clock.advance(by: 24)
    #expect(clock.pendingCount == 1)
    #expect(clock.timing.nowNanoseconds() == 24)
    clock.advance(by: 1)
    try await task.value
    #expect(clock.pendingCount == 0)
    #expect(clock.timing.nowNanoseconds() == 25)
}
