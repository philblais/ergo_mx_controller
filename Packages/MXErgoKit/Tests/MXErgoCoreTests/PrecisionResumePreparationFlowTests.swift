import Testing
@testable import MXErgoCore

@Test @MainActor func resumePreparationStopsAtEveryFailedCheck() async {
    for failed in PrecisionResumePreparationFlow.Step.allCases {
        let flow = PrecisionResumePreparationFlow()
        var visited: [PrecisionResumePreparationFlow.Step] = []
        let outcome = await flow.perform(isCurrent: { true }) { step in
            visited.append(step)
            return step != failed
        }
        #expect(outcome == .failed(failed))
        #expect(visited.last == failed)
        #expect(visited == Array(PrecisionResumePreparationFlow.Step.allCases.prefix(visited.count)))
        #expect(!flow.isPerforming)
    }
}

@Test @MainActor func resumePreparationConnectionChangePreventsEveryLaterStep() async {
    let flow = PrecisionResumePreparationFlow()
    var current = true
    var visited: [PrecisionResumePreparationFlow.Step] = []
    let outcome = await flow.perform(isCurrent: { current }) { step in
        visited.append(step)
        current = false
        return true
    }
    #expect(outcome == .interrupted)
    #expect(visited == [.connection])
    #expect(!flow.isPerforming)
}

@Test @MainActor func resumePreparationRejectsConcurrentAndCancelledAttempts() async {
    let flow = PrecisionResumePreparationFlow()
    let gate = ResumePreparationGate()
    let first = Task { @MainActor in
        await flow.perform(isCurrent: { true }) { _ in
            await gate.wait()
            return true
        }
    }
    await gate.waitUntilEntered()
    let duplicate = await flow.perform(isCurrent: { true }) { _ in
        Issue.record("Duplicate must not perform a preparation step")
        return true
    }
    #expect(duplicate == .busy)
    first.cancel()
    gate.open()
    #expect(await first.value == .interrupted)
    #expect(!flow.isPerforming)
}

@Test @MainActor func resumePreparationOnlySucceedsAfterAllChecks() async {
    let flow = PrecisionResumePreparationFlow()
    var visited: [PrecisionResumePreparationFlow.Step] = []
    #expect(await flow.perform(isCurrent: { false }, step: { _ in
        Issue.record("An invalid generation must not begin")
        return true
    }) == .interrupted)
    let result = await flow.perform(isCurrent: { true }) { step in
        visited.append(step)
        return true
    }
    #expect(result == .resumed)
    #expect(visited == PrecisionResumePreparationFlow.Step.allCases)
}

@MainActor private final class ResumePreparationGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var entered = false
    func wait() async {
        await withCheckedContinuation { continuation in
            waiter = continuation
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func open() { waiter?.resume(); waiter = nil }
}
