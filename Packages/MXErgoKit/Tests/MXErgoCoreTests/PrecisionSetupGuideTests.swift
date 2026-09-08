import Foundation
import Testing
@testable import MXErgoCore

@Test func setupGuideRequiresEveryPredecessorBeforeOfferingConfirmation() {
    var progress = Dictionary(uniqueKeysWithValues: PrecisionSetupGuide.Step.allCases.map { ($0, PrecisionSetupGuide.Progress.pending) })
    for step in PrecisionSetupGuide.Step.allCases {
        let state = PrecisionSetupGuide.evaluate(progress, operationInProgress: false, stopReason: nil)
        #expect(state == .next(step))
        progress[step] = .complete
    }
    #expect(PrecisionSetupGuide.evaluate(progress, operationInProgress: false, stopReason: nil) == .readyForConfirmation)
}

@Test func setupGuideDoesNotSkipInvalidatedEarlierEvidence() {
    var progress = Dictionary(uniqueKeysWithValues: PrecisionSetupGuide.Step.allCases.map { ($0, PrecisionSetupGuide.Progress.complete) })
    progress[.firmware] = .blocked("Connection changed")
    #expect(PrecisionSetupGuide.evaluate(progress, operationInProgress: false, stopReason: nil) == .blocked("Connection changed"))
    progress[.firmware] = nil
    guard case .blocked = PrecisionSetupGuide.evaluate(progress, operationInProgress: false, stopReason: nil) else {
        Issue.record("Missing evidence offered activation"); return
    }
}

@Test func setupGuideStopsForRecoveryEvenWhenPreparationIsComplete() {
    let progress = Dictionary(uniqueKeysWithValues: PrecisionSetupGuide.Step.allCases.map { ($0, PrecisionSetupGuide.Progress.complete) })
    for reason in ["Recovery required", "Disconnected", "Expired", "Terminating"] {
        #expect(PrecisionSetupGuide.evaluate(progress, operationInProgress: false, stopReason: reason) == .blocked(reason))
    }
}

@Test func setupGuideDoesNotOfferAnotherActionDuringConcurrentWork() {
    var progress: [PrecisionSetupGuide.Step: PrecisionSetupGuide.Progress] = [.connection: .pending, .selfTest: .working]
    #expect(PrecisionSetupGuide.evaluate(progress, operationInProgress: false, stopReason: nil) == .working)
    progress[.selfTest] = .pending
    #expect(PrecisionSetupGuide.evaluate(progress, operationInProgress: true, stopReason: nil) == .working)
}

@Test func setupGuideRejectsStaleConfirmationInsteadOfAdvancingIt() {
    #expect(PrecisionSetupGuide.accepts(.connection, current: .next(.connection)))
    for state: PrecisionSetupGuide.State in [.next(.firmware), .working, .blocked("Changed"), .readyForConfirmation] {
        #expect(!PrecisionSetupGuide.accepts(.connection, current: state))
    }
}

@Test func setupGuideRoutesRecoveryBeforeBinding() {
    var progress = Dictionary(uniqueKeysWithValues: PrecisionSetupGuide.Step.allCases.map { ($0, PrecisionSetupGuide.Progress.complete) })
    progress[.bind] = .pending
    guard case .blocked = PrecisionSetupGuide.evaluate(progress, operationInProgress: false,
        stopReason: nil, readiness: .recover) else { Issue.record("Recovery offered normal bind"); return }
}

@Test func setupGuideRoutesCompletedJournalBeforeAnyPreparation() {
    let progress = Dictionary(uniqueKeysWithValues: PrecisionSetupGuide.Step.allCases.map { ($0, PrecisionSetupGuide.Progress.pending) })
    guard case .blocked = PrecisionSetupGuide.evaluate(progress, operationInProgress: false,
        stopReason: nil, completedJournalAvailable: true) else { Issue.record("Completed journal offered preparation"); return }
}

@Test func setupGuideActivationAttemptCannotRepeatAfterFailure() {
    let token = UUID()
    var attempt = PrecisionSetupGuide.EnableAttempt()
    let accepted1 = attempt.consume(expected: token, current: token, ready: true)
    #expect(accepted1)
    let accepted2 = attempt.consume(expected: token, current: token, ready: true)
    #expect(!accepted2)
}

@Test func setupGuideRejectsStaleOrUnavailableBindingWithoutConsumingCurrentAttempt() {
    let old = UUID(), current = UUID()
    var attempt = PrecisionSetupGuide.EnableAttempt()
    let accepted3 = attempt.consume(expected: old, current: current, ready: true)
    #expect(!accepted3)
    let accepted4 = attempt.consume(expected: current, current: nil, ready: true)
    #expect(!accepted4)
    let accepted5 = attempt.consume(expected: current, current: current, ready: false)
    #expect(!accepted5)
    let accepted6 = attempt.consume(expected: current, current: current, ready: true)
    #expect(accepted6)
}

@Test func setupGuideAudioRequiresSameActivelyDivertedSession() {
    let token = UUID()
    #expect(PrecisionSetupGuide.shouldEnableAudio(expected: token, current: token,
        diverted: true, recovery: false, disconnected: false, terminating: false, operationInProgress: false))
    // Admission alone, including admission after verified restore, is insufficient.
    #expect(!PrecisionSetupGuide.shouldEnableAudio(expected: token, current: token,
        diverted: false, recovery: false, disconnected: false, terminating: false, operationInProgress: false))
    #expect(!PrecisionSetupGuide.shouldEnableAudio(expected: token, current: UUID(),
        diverted: true, recovery: false, disconnected: false, terminating: false, operationInProgress: false))
}

@Test func setupGuideAudioStopsForEveryFailureAndShutdownState() {
    let token = UUID()
    for flags in [(true, false, false, false), (false, true, false, false),
                  (false, false, true, false), (false, false, false, true)] {
        #expect(!PrecisionSetupGuide.shouldEnableAudio(expected: token, current: token,
            diverted: true, recovery: flags.0, disconnected: flags.1,
            terminating: flags.2, operationInProgress: flags.3))
    }
}
