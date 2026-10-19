import Foundation
import Testing
@testable import MXErgoCore

@MainActor
private final class SleepFlowGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var entered = false

    func wait() async {
        await withCheckedContinuation { continuation in
            waiter = continuation
            entered = true
            observer?.resume()
            observer = nil
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func open() { waiter?.resume(); waiter = nil }
}

/// Stands in for the owner's wake capability: revocation invalidates it.
@MainActor
private final class FakeWakeRun {
    let cycleID: UUID
    var isValid = true
    init(cycleID: UUID) { self.cycleID = cycleID }
}

private struct InjectedShutdownFailure: Error {}

@MainActor
private final class SleepFlowFixture {
    let previousObserverRunID = UUID()
    var events: [String] = []
    var reports: [PrecisionSleepReconnect.Status] = []
    var operationInProgress = false
    var terminating = false
    var ownerIsCurrent = true
    var automaticStartupEnabled = true
    var shutdownGate: SleepFlowGate?
    var reopenGate: SleepFlowGate?
    var shutdownFails = false
    lazy var reopenResult = PrecisionSleepReconnect.ReopenResult.ready(
        previousObserverRunID: previousObserverRunID
    )
    var resumeResult = PrecisionSleepReconnect.ResumeResult.active(audioEnabled: true)
    var resumedWith: (restoreAudio: Bool, previousObserverRunID: UUID?)?
    var issuedRuns: [FakeWakeRun] = []

    lazy var flow = PrecisionSleepReconnectFlow<FakeWakeRun>(
        pauseControls: { self.events.append("pause") },
        revokeAutomaticStartup: {
            self.events.append("revoke")
            for run in self.issuedRuns { run.isValid = false }
        },
        setOperationInProgress: {
            self.operationInProgress = $0
            self.events.append("operation \($0)")
        },
        isTerminating: { self.terminating },
        report: { _, status in self.reports.append(status) }
    )

    @discardableResult
    func sleep(eligible: Bool = true, audio: Bool = true) -> PrecisionSleepReconnect.Decision {
        guard eligible else { return flow.willSleep(nil) }
        return flow.willSleep(PrecisionSleepRollover(
            restoresAudioAfterWake: audio,
            ownerIsCurrent: { self.ownerIsCurrent },
            shutdown: { cycleID in
                self.events.append("shutdown")
                if let gate = self.shutdownGate { await gate.wait() }
                if self.shutdownFails { throw InjectedShutdownFailure() }
                let run = FakeWakeRun(cycleID: cycleID)
                self.issuedRuns.append(run)
                return run
            }
        ))
    }

    func wake() -> Task<Void, Never>? {
        flow.didWake(
            wakeRunIsUsable: { run, cycleID in
                self.automaticStartupEnabled && run.cycleID == cycleID && run.isValid
            },
            wakeRunIsValid: { $0.isValid },
            reopen: {
                self.events.append("reopen")
                if let gate = self.reopenGate { await gate.wait() }
                return self.reopenResult
            },
            resume: { _, restoreAudio, previousObserverRunID in
                self.events.append("resume")
                self.resumedWith = (restoreAudio, previousObserverRunID)
                return self.resumeResult
            }
        )
    }

    func finishShutdown() async -> FakeWakeRun? {
        await flow.shutdownTask?.value
    }
}

@Test @MainActor func sleepReconnectPausesShutsDownThenResumesOnceAfterWake() async throws {
    let fixture = SleepFlowFixture()
    let decision = fixture.sleep()
    let cycleID = try #require(fixture.flow.cycleID)
    #expect(decision == .began(cycleID))
    #expect(fixture.operationInProgress)

    let run = await fixture.finishShutdown()
    #expect(run?.cycleID == cycleID)
    #expect(!fixture.operationInProgress)
    #expect(fixture.reports == [.pausing, .paused])

    await fixture.wake()?.value
    #expect(fixture.events == ["pause", "operation true", "shutdown", "operation false",
                               "reopen", "resume", "operation false"])
    #expect(fixture.resumedWith?.restoreAudio == true)
    #expect(fixture.resumedWith?.previousObserverRunID == fixture.previousObserverRunID)
    #expect(fixture.reports.last == .finished(.reconnected(audioRestored: true)))
    #expect(fixture.flow.cycleID == nil)
}

@Test @MainActor func secondSleepDuringShutdownReleasesTheClaimAndNeverCompletesTheCycle() async throws {
    let fixture = SleepFlowFixture()
    let gate = SleepFlowGate()
    fixture.shutdownGate = gate
    fixture.sleep()
    let cycleID = try #require(fixture.flow.cycleID)
    await gate.waitUntilEntered()

    #expect(fixture.sleep() == .invalidated(cycleID))
    #expect(fixture.flow.cycleID == nil)
    // The shutdown really is still running, so the claim stays until it ends.
    #expect(fixture.operationInProgress)

    gate.open()
    #expect(await fixture.finishShutdown() == nil)
    #expect(!fixture.operationInProgress)
    #expect(fixture.reports == [.pausing, .invalidatedBySecondSleep])
    #expect(fixture.events.filter { $0 == "pause" }.count == 2)
    #expect(fixture.events.contains("revoke"))
    #expect(fixture.wake() == nil)
    #expect(!fixture.events.contains("reopen"))
}

@Test @MainActor func shutdownNeverReleasesAClaimForADifferentOwner() async throws {
    let fixture = SleepFlowFixture()
    let gate = SleepFlowGate()
    fixture.shutdownGate = gate
    fixture.sleep()
    await gate.waitUntilEntered()
    fixture.sleep()
    fixture.ownerIsCurrent = false

    gate.open()
    _ = await fixture.finishShutdown()
    #expect(fixture.operationInProgress)
    #expect(!fixture.events.contains("operation false"))
}

@Test @MainActor func secondSleepAfterShutdownInvalidatesTheWaitingCycle() async throws {
    let fixture = SleepFlowFixture()
    fixture.sleep()
    let cycleID = try #require(fixture.flow.cycleID)
    _ = await fixture.finishShutdown()

    #expect(fixture.sleep() == .invalidated(cycleID))
    #expect(fixture.issuedRuns.allSatisfy { !$0.isValid })
    #expect(fixture.wake() == nil)
    #expect(!fixture.events.contains("reopen"))
    #expect(!fixture.operationInProgress)
}

@Test @MainActor func failedShutdownNeedsReviewAndWakeNeverReopens() async throws {
    let fixture = SleepFlowFixture()
    fixture.shutdownFails = true
    fixture.sleep()
    _ = await fixture.finishShutdown()
    #expect(!fixture.operationInProgress)
    #expect(fixture.reports.count == 2)
    guard case .pauseFailed = fixture.reports.last else {
        Issue.record("A failed shutdown must report pauseFailed, not \(String(describing: fixture.reports.last))")
        return
    }

    await fixture.wake()?.value
    #expect(!fixture.events.contains("reopen"))
    #expect(fixture.reports.last == .finished(.notReconnected))
    #expect(fixture.flow.cycleID == nil)
}

@Test @MainActor func wakeWaitsForAShutdownThatSleepInterrupted() async throws {
    let fixture = SleepFlowFixture()
    let gate = SleepFlowGate()
    fixture.shutdownGate = gate
    fixture.sleep()
    await gate.waitUntilEntered()

    let completion = try #require(fixture.wake())
    for _ in 0..<5 { await Task.yield() }
    #expect(!fixture.events.contains("reopen"))

    gate.open()
    await completion.value
    #expect(fixture.events.suffix(2) == ["resume", "operation false"])
    #expect(fixture.reports.last == .finished(.reconnected(audioRestored: true)))
}

@Test @MainActor func optOutBeforeWakeFinishesWithoutReopening() async throws {
    let fixture = SleepFlowFixture()
    fixture.sleep()
    _ = await fixture.finishShutdown()
    fixture.automaticStartupEnabled = false

    await fixture.wake()?.value
    #expect(!fixture.events.contains("reopen"))
    #expect(fixture.reports.last == .finished(.notReconnected))
}

@Test @MainActor func revocationDuringReopenStopsBeforeResume() async throws {
    let fixture = SleepFlowFixture()
    let gate = SleepFlowGate()
    fixture.reopenGate = gate
    fixture.sleep()
    _ = await fixture.finishShutdown()
    let completion = try #require(fixture.wake())
    await gate.waitUntilEntered()

    for run in fixture.issuedRuns { run.isValid = false }
    gate.open()
    await completion.value
    #expect(!fixture.events.contains("resume"))
    #expect(fixture.reports.last == .finished(.notReadyAfterWake))
}

@Test @MainActor func freshObserverThatIsNotReadyStopsBeforeResume() async throws {
    let fixture = SleepFlowFixture()
    fixture.reopenResult = .notReady
    fixture.sleep()
    _ = await fixture.finishShutdown()

    await fixture.wake()?.value
    #expect(!fixture.events.contains("resume"))
    #expect(fixture.reports.last == .finished(.notReadyAfterWake))
    #expect(!fixture.operationInProgress)
}

@Test @MainActor func sleepDuringReopenLeavesTheStaleWakeUnfinished() async throws {
    let fixture = SleepFlowFixture()
    let gate = SleepFlowGate()
    fixture.reopenGate = gate
    fixture.sleep()
    let cycleID = try #require(fixture.flow.cycleID)
    _ = await fixture.finishShutdown()
    let completion = try #require(fixture.wake())
    await gate.waitUntilEntered()

    #expect(fixture.sleep() == .invalidated(cycleID))
    gate.open()
    await completion.value
    #expect(!fixture.events.contains("resume"))
    #expect(fixture.reports.last == .invalidatedBySecondSleep)
}

@Test @MainActor func terminationDuringShutdownReleasesTheClaimAndIgnoresWake() async throws {
    let fixture = SleepFlowFixture()
    let gate = SleepFlowGate()
    fixture.shutdownGate = gate
    fixture.sleep()
    await gate.waitUntilEntered()

    fixture.terminating = true
    fixture.flow.invalidateForTermination()
    gate.open()
    #expect(await fixture.finishShutdown() == nil)
    #expect(!fixture.operationInProgress)
    #expect(fixture.reports == [.pausing])
    #expect(fixture.wake() == nil)
}

@Test @MainActor func ineligibleSleepChangesNothingAndWakeHasNothingToComplete() {
    let fixture = SleepFlowFixture()
    #expect(fixture.sleep(eligible: false) == .ignored)
    #expect(fixture.events.isEmpty)
    #expect(fixture.reports.isEmpty)
    #expect(fixture.wake() == nil)
}

@Test @MainActor func pausedAudioStaysPausedThroughResume() async throws {
    let fixture = SleepFlowFixture()
    fixture.resumeResult = .active(audioEnabled: false)
    fixture.sleep(audio: false)
    _ = await fixture.finishShutdown()

    await fixture.wake()?.value
    #expect(fixture.resumedWith?.restoreAudio == false)
    #expect(fixture.reports.last == .finished(.reconnected(audioRestored: false)))
}

@Test @MainActor func resumeThatDoesNotVerifyActiveFinishesForReview() async throws {
    let fixture = SleepFlowFixture()
    fixture.resumeResult = .notActive
    fixture.sleep()
    _ = await fixture.finishShutdown()

    await fixture.wake()?.value
    #expect(fixture.reports.last == .finished(.notVerifiedActive))
    #expect(!PrecisionSleepReconnect.Outcome.notVerifiedActive.succeeded)
    #expect(PrecisionSleepReconnect.Outcome.reconnected(audioRestored: false).succeeded)
}

@Test @MainActor func duplicateWakeStartsOneCompletion() async throws {
    let fixture = SleepFlowFixture()
    fixture.sleep()
    let first = try #require(fixture.wake())
    #expect(fixture.wake() == nil)
    await first.value
    #expect(fixture.events.filter { $0 == "reopen" }.count == 1)
}
