import Foundation
import Testing
@testable import MXErgoCore

private func actions(bound: Bool = false, admitted: Bool = false, diverted: Bool = false,
    deactivate: Bool = false, release: Bool = false, journal: Bool = false,
    recovery: Bool = false, disconnected: Bool = false, busy: Bool = false,
    terminating: Bool = false) -> Set<PrecisionSessionActions.Action> {
    PrecisionSessionActions.available(bound: bound, admitted: admitted, diverted: diverted,
        canDeactivate: deactivate, canRelease: release, completedJournal: journal,
        recovery: recovery, disconnected: disconnected, busy: busy, terminating: terminating)
}

@Test func sessionActionsDistinguishActiveRestoredAndPreparedOwners() {
    #expect(actions(bound: true, admitted: true, diverted: true, deactivate: true) == [.deactivate])
    #expect(actions(bound: true, admitted: true, release: true).isEmpty)
    #expect(actions(bound: true, release: true) == [.release])
    #expect(actions(bound: true, diverted: true, release: true).isEmpty)
}

@Test func sessionArchiveRequiresAnEligibleRecordAndNoOwner() {
    #expect(actions(journal: true) == [.archive])
    #expect(actions().isEmpty)
    #expect(!actions(bound: true, release: true, journal: true).contains(.archive))
    #expect(actions(admitted: true, journal: true).isEmpty)
    #expect(actions(diverted: true, journal: true).isEmpty)
}

@Test func sessionActionsRejectRecoveryDisconnectShutdownAndConcurrentWork() {
    for flags in [(true, false, false, false), (false, true, false, false),
                  (false, false, true, false), (false, false, false, true)] {
        #expect(actions(bound: true, admitted: true, diverted: true, deactivate: true,
            recovery: flags.0, disconnected: flags.1, busy: flags.2, terminating: flags.3).isEmpty)
        #expect(actions(journal: true, recovery: flags.0, disconnected: flags.1,
            busy: flags.2, terminating: flags.3).isEmpty)
    }
}

@Test func sessionActionConfirmationRejectsReplacedOrReleasedOwner() {
    let token = UUID()
    for action: PrecisionSessionActions.Action in [.release, .deactivate] {
        #expect(PrecisionSessionActions.acceptsOwnerAction(action, expected: token,
            current: token, available: [action]))
        #expect(!PrecisionSessionActions.acceptsOwnerAction(action, expected: token,
            current: UUID(), available: [action]))
        #expect(!PrecisionSessionActions.acceptsOwnerAction(action, expected: token,
            current: nil, available: [action]))
        #expect(!PrecisionSessionActions.acceptsOwnerAction(action, expected: token,
            current: token, available: []))
    }
}

@Test func archiveCannotUseAnOwnerConfirmation() {
    let token = UUID()
    #expect(!PrecisionSessionActions.acceptsOwnerAction(.archive, expected: token,
        current: token, available: [.archive]))
}

@Test func sessionReleaseRetainsExplicitRecoveryRolloverButRefusesBusyOrAdmittedOwners() {
    #expect(actions(bound: true, release: true, recovery: true, disconnected: true) == [.release])
    #expect(actions(bound: true, release: true, busy: true).isEmpty)
    #expect(actions(bound: true, release: true, terminating: true).isEmpty)
    #expect(actions(bound: true, admitted: true, release: true, recovery: true).isEmpty)
}
