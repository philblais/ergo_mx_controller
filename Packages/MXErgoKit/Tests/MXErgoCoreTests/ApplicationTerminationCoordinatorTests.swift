import Foundation
import Testing
@testable import MXErgoCore

@MainActor
private final class TerminationTestGate {
    private var opened = false
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var starters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        starters.forEach { $0.resume() }
        starters.removeAll()
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { starters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@Test @MainActor func terminationClosesAdmissionImmediatelyAndSharesOneCleanup() async {
    let cleanupGate = TerminationTestGate()
    let replied = TerminationTestGate()
    var closed = 0
    var cleaned = 0
    var replies: [Bool] = []
    let coordinator = ApplicationTerminationCoordinator(
        closeAdmission: { closed += 1 },
        cleanup: { cleaned += 1; await cleanupGate.wait(); return true },
        reply: { replies.append($0); replied.open() },
        stateChanged: { _ in },
        waitForDeadline: { try await Task.sleep(for: .seconds(10)) }
    )
    #expect(coordinator.requestTermination() == .terminateLater)
    #expect(closed == 1)
    #expect(replies.isEmpty)
    #expect(coordinator.requestTermination() == .terminateLater)
    await cleanupGate.waitUntilStarted()
    #expect(cleaned == 1)
    cleanupGate.open()
    await replied.wait()
    #expect(replies == [true])
    #expect(coordinator.state == .ready)
    #expect(coordinator.requestTermination() == .terminateNow)
    #expect(closed == 1)
}

@Test @MainActor func quitDeadlineCancelsTheRequestButRetainsPhysicalCleanup() async {
    let cleanupGate = TerminationTestGate()
    let deadline = TerminationTestGate()
    let replied = TerminationTestGate()
    let finished = TerminationTestGate()
    var replies: [Bool] = []
    var cleanupCancelled = false
    let coordinator = ApplicationTerminationCoordinator(
        closeAdmission: {},
        cleanup: {
            await cleanupGate.wait()
            cleanupCancelled = Task.isCancelled
            return true
        },
        reply: { replies.append($0); replied.open() },
        stateChanged: { if $0 == .ready { finished.open() } },
        waitForDeadline: { await deadline.wait() }
    )
    #expect(coordinator.requestTermination() == .terminateLater)
    await cleanupGate.waitUntilStarted()
    await deadline.waitUntilStarted()
    deadline.open()
    await replied.wait()
    #expect(replies == [false])
    #expect(coordinator.state == .waitingAfterDeadline)
    cleanupGate.open()
    await finished.wait()
    #expect(!cleanupCancelled)
    #expect(replies == [false])
    #expect(coordinator.requestTermination() == .terminateNow)
}

@Test @MainActor func anotherQuitWhileDrainingJoinsTheSameCleanup() async {
    let cleanupGate = TerminationTestGate()
    let firstDeadline = TerminationTestGate()
    let cancelled = TerminationTestGate()
    let completed = TerminationTestGate()
    var deadlines = 0
    var cleaned = 0
    var closed = 0
    var replies: [Bool] = []
    let coordinator = ApplicationTerminationCoordinator(
        closeAdmission: { closed += 1 },
        cleanup: { cleaned += 1; await cleanupGate.wait(); return true },
        reply: {
            replies.append($0)
            if $0 { completed.open() } else { cancelled.open() }
        },
        stateChanged: { _ in },
        waitForDeadline: {
            deadlines += 1
            if deadlines == 1 { await firstDeadline.wait() }
            else { try await Task.sleep(for: .seconds(60)) }
        }
    )
    #expect(coordinator.requestTermination() == .terminateLater)
    await cleanupGate.waitUntilStarted()
    await firstDeadline.waitUntilStarted()
    firstDeadline.open()
    await cancelled.wait()
    #expect(coordinator.requestTermination() == .terminateLater)
    cleanupGate.open()
    await completed.wait()
    #expect(replies == [false, true])
    #expect(cleaned == 1)
    #expect(closed == 1)
}

@Test @MainActor func uncertainReleaseCancelsQuitWithoutRepeatingCleanup() async {
    let replied = TerminationTestGate()
    var cleaned = 0
    var replies: [Bool] = []
    let coordinator = ApplicationTerminationCoordinator(
        closeAdmission: {},
        cleanup: { cleaned += 1; return false },
        reply: { replies.append($0); replied.open() },
        stateChanged: { _ in },
        waitForDeadline: { try await Task.sleep(for: .seconds(10)) }
    )
    #expect(coordinator.requestTermination() == .terminateLater)
    await replied.wait()
    #expect(replies == [false])
    #expect(coordinator.state == .blocked)
    #expect(coordinator.requestTermination() == .cancel)
    #expect(cleaned == 1)
}
