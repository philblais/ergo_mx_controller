import Foundation
import Testing
@testable import MXErgoCore

@MainActor
private final class ActionFlowGate {
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

@MainActor
private final class ActionFlowFixture {
    let flow = PrecisionSessionActionFlow()
    var bindingID: UUID? = UUID()
    var bound = true
    var admitted: Bool
    var diverted: Bool
    var recovery = false
    var disconnected = false
    var terminating = false
    var audio = true
    var operationSucceeds = true
    var cancelOnPause = false
    var replacementAfterRelease: UUID?
    var availableOverride: Set<PrecisionSessionActions.Action>?
    var gate: ActionFlowGate?
    var events: [String] = []

    init(active: Bool = true) { admitted = active; diverted = active }

    var snapshot: PrecisionSessionActionFlow.Snapshot {
        .init(bindingID: bindingID,
            available: availableOverride ?? PrecisionSessionActions.available(bound: bound, admitted: admitted,
                diverted: diverted, canDeactivate: diverted, canRelease: !admitted,
                completedJournal: false, recovery: recovery, disconnected: disconnected,
                busy: false, terminating: terminating),
            bound: bound, admitted: admitted, diverted: diverted, recovery: recovery,
            disconnected: disconnected, terminating: terminating)
    }

    func perform(_ action: PrecisionSessionActions.Action, expected: UUID) async -> PrecisionSessionActionFlow.Outcome {
        await flow.perform(action, expected: expected, snapshot: { self.snapshot },
            pauseAudio: {
                self.audio = false
                self.events.append("pause-audio")
                if self.cancelOnPause { withUnsafeCurrentTask { $0?.cancel() } }
            },
            deactivate: {
                self.events.append("deactivate")
                if let gate = self.gate { await gate.wait() }
                if self.operationSucceeds { self.diverted = false }
            }, release: {
                self.events.append("release")
                if let gate = self.gate { await gate.wait() }
                if self.operationSucceeds { self.bound = false; self.bindingID = self.replacementAfterRelease }
            })
    }
}

@Test @MainActor func actionFlowOnlyRunsAfterConfirmationAndPausesAudioBeforeRestoring() async throws {
    let fixture = ActionFlowFixture()
    #expect(fixture.events.isEmpty)
    let token = try #require(fixture.bindingID)
    let result = await fixture.perform(.deactivate, expected: token)
    #expect(result == .restored)
    #expect(fixture.events == ["pause-audio", "deactivate"])
    #expect(!fixture.audio && fixture.bound && fixture.admitted)
    #expect(fixture.bindingID == token)
    #expect(!fixture.flow.isPerforming)
}

@Test @MainActor func actionFlowRejectsStaleConfirmationAndRestoredOwnerBeforeEffects() async throws {
    let fixture = ActionFlowFixture()
    #expect(await fixture.perform(.deactivate, expected: UUID()) == .unavailable)
    fixture.diverted = false
    let token = try #require(fixture.bindingID)
    #expect(await fixture.perform(.deactivate, expected: token) == .unavailable)
    #expect(await fixture.perform(.release, expected: token) == .unavailable)
    #expect(await fixture.perform(.archive, expected: token) == .unavailable)
    #expect(fixture.events.isEmpty && fixture.audio)
}

@Test @MainActor func actionFlowFailedRestorationLeavesAudioOffAndNeverReleasesOwnership() async throws {
    let fixture = ActionFlowFixture()
    fixture.operationSucceeds = false
    let token = try #require(fixture.bindingID)
    #expect(await fixture.perform(.deactivate, expected: token) == .restorationFailed)
    #expect(fixture.events == ["pause-audio", "deactivate"])
    #expect(!fixture.audio && fixture.diverted && fixture.bound)
}

@Test @MainActor func actionFlowRejectsContradictoryFlagsEvenWhenAnActionIsListed() async throws {
    let fixture = ActionFlowFixture()
    fixture.diverted = false
    fixture.availableOverride = [.deactivate, .release]
    let token = try #require(fixture.bindingID)
    #expect(await fixture.perform(.deactivate, expected: token) == .unavailable)
    #expect(await fixture.perform(.release, expected: token) == .unavailable)
    #expect(fixture.events.isEmpty && fixture.audio)
}

@Test @MainActor func actionFlowCancellationDuringAudioPauseNeverStartsDeactivation() async throws {
    let fixture = ActionFlowFixture()
    fixture.cancelOnPause = true
    let token = try #require(fixture.bindingID)
    let task = Task { await fixture.perform(.deactivate, expected: token) }
    #expect(await task.value == .interrupted)
    #expect(fixture.events == ["pause-audio"])
    #expect(!fixture.audio && fixture.diverted && !fixture.flow.isPerforming)
}

@Test @MainActor func actionFlowReleaseRequiresTheBindingToBeCleared() async throws {
    let fixture = ActionFlowFixture(active: false)
    fixture.replacementAfterRelease = UUID()
    let token = try #require(fixture.bindingID)
    #expect(await fixture.perform(.release, expected: token) == .interrupted)
    #expect(!fixture.bound && fixture.bindingID != nil)
    #expect(fixture.events == ["release"])
}

@Test @MainActor func actionFlowSerializesReleaseAcrossSuspensionAndRejectsOldConfirmationAfterward() async throws {
    let fixture = ActionFlowFixture(active: false)
    let gate = ActionFlowGate()
    fixture.gate = gate
    let token = try #require(fixture.bindingID)
    let first = Task { await fixture.perform(.release, expected: token) }
    await gate.waitUntilEntered()
    #expect(fixture.flow.isPerforming)
    #expect(await fixture.perform(.release, expected: token) == .busy)
    #expect(fixture.events == ["release"] && fixture.bound)
    gate.open()
    #expect(await first.value == .released)
    #expect(!fixture.bound && fixture.bindingID == nil && !fixture.flow.isPerforming)
    #expect(await fixture.perform(.release, expected: token) == .unavailable)
    #expect(fixture.events == ["release"])
}

@Test @MainActor func actionFlowFailedReleaseRetainsBindingAndDoesNotStartAnotherOperation() async throws {
    let fixture = ActionFlowFixture(active: false)
    fixture.operationSucceeds = false
    let token = try #require(fixture.bindingID)
    #expect(await fixture.perform(.release, expected: token) == .releaseFailed)
    #expect(fixture.bound && fixture.bindingID == token)
    #expect(fixture.events == ["release"] && !fixture.flow.isPerforming)
}

@Test @MainActor func actionFlowDoesNotReportOldRestorationForAReplacementSession() async throws {
    let fixture = ActionFlowFixture()
    let gate = ActionFlowGate()
    fixture.gate = gate
    let token = try #require(fixture.bindingID)
    let task = Task { await fixture.perform(.deactivate, expected: token) }
    await gate.waitUntilEntered()
    fixture.bindingID = UUID()
    gate.open()
    #expect(await task.value == .interrupted)
    #expect(!fixture.audio && !fixture.flow.isPerforming)
    #expect(fixture.events == ["pause-audio", "deactivate"])
}

@Test @MainActor func actionFlowDetectsDisconnectAndRecoveryDuringRestoration() async throws {
    let fixture = ActionFlowFixture()
    let gate = ActionFlowGate()
    fixture.gate = gate
    let token = try #require(fixture.bindingID)
    let task = Task { await fixture.perform(.deactivate, expected: token) }
    await gate.waitUntilEntered()
    fixture.disconnected = true
    fixture.recovery = true
    gate.open()
    #expect(await task.value == .restorationFailed)
    #expect(!fixture.audio)
    #expect(fixture.events == ["pause-audio", "deactivate"])
}

@Test @MainActor func actionFlowSuppressesCompletionDuringTermination() async throws {
    let fixture = ActionFlowFixture(active: false)
    let gate = ActionFlowGate()
    fixture.gate = gate
    let token = try #require(fixture.bindingID)
    let task = Task { await fixture.perform(.release, expected: token) }
    await gate.waitUntilEntered()
    fixture.terminating = true
    gate.open()
    #expect(await task.value == .interrupted)
    #expect(!fixture.flow.isPerforming && fixture.events == ["release"])
}

@Test @MainActor func actionFlowRejectsCancellationBeforeEffectsAndAwaitsEnteredWork() async throws {
    let fixture = ActionFlowFixture(active: false)
    let start = ActionFlowGate()
    let token = try #require(fixture.bindingID)
    let cancelledBeforeEntry = Task {
        await start.wait()
        return await fixture.perform(.release, expected: token)
    }
    await start.waitUntilEntered()
    cancelledBeforeEntry.cancel()
    start.open()
    #expect(await cancelledBeforeEntry.value == .interrupted)
    #expect(fixture.events.isEmpty)

    let gate = ActionFlowGate()
    fixture.gate = gate
    let entered = Task { await fixture.perform(.release, expected: token) }
    await gate.waitUntilEntered()
    entered.cancel()
    #expect(fixture.flow.isPerforming && fixture.bound)
    gate.open()
    #expect(await entered.value == .interrupted)
    #expect(!fixture.flow.isPerforming && fixture.events == ["release"])
}
