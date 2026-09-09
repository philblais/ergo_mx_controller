import Testing
@testable import MXErgoCore

private func launchNeedsAttention(
    inputMonitoring: Bool = true,
    accessibility: Bool = true,
    remembered: Bool = false,
    enabled: Bool = false,
    remappingIssue: Bool = false,
    loginItem: LoginItemRegistration = .registered,
    savedPrecisionIssue: Bool = false
) -> Bool {
    ControllerLaunchPresentation.needsAttention(
        inputMonitoringGranted: inputMonitoring,
        accessibilityGranted: accessibility,
        remappingRemembered: remembered,
        remappingEnabled: enabled,
        remappingNeedsAttention: remappingIssue,
        loginItem: loginItem,
        savedPrecisionNeedsReview: savedPrecisionIssue
    )
}

@Test func routineLoginStaysQuietWithEitherWorkingRemappingOrRememberedOff() {
    for remembered in [false, true] {
        var policy = ControllerLaunchPresentation()
        let show = policy.shouldPresentOnLaunch(reason: .loginItem,
            hasPresentedBefore: true,
            needsAttention: launchNeedsAttention(remembered: remembered, enabled: remembered))
        #expect(!show)
    }
}

@Test func firstPresentationIsVisibleEvenAtLogin() {
    for reason: ControllerLaunchPresentation.Reason in [.loginItem, .otherOrUnknown] {
        var policy = ControllerLaunchPresentation()
        let show = policy.shouldPresentOnLaunch(reason: reason,
            hasPresentedBefore: false, needsAttention: false)
        #expect(show)
    }
}

@Test func manualOrUnrecognizedLaunchNeverAssumesQuietLogin() {
    var policy = ControllerLaunchPresentation()
    let show = policy.shouldPresentOnLaunch(reason: .otherOrUnknown,
        hasPresentedBefore: true, needsAttention: false)
    #expect(show)
}

@Test func loginSurfacesMissingPermissionsForRequestedServices() {
    #expect(launchNeedsAttention(inputMonitoring: false))
    #expect(launchNeedsAttention(accessibility: false, remembered: true))
    // Accessibility alone is not a startup problem when remapping was left Off.
    #expect(!launchNeedsAttention(accessibility: false, remembered: false))
}

@Test func loginSurfacesFailedRemappingEvenWithPermissionsGranted() {
    #expect(launchNeedsAttention(remembered: true, enabled: false))
    #expect(launchNeedsAttention(remembered: true, enabled: true, remappingIssue: true))
    #expect(launchNeedsAttention(remappingIssue: true))
}

@Test func loginRegistrationAttentionDoesNotTreatOptingOutAsFailure() {
    #expect(launchNeedsAttention(loginItem: .requiresApproval))
    #expect(launchNeedsAttention(loginItem: .notFound))
    #expect(!launchNeedsAttention(loginItem: .notRegistered))
    #expect(!launchNeedsAttention(loginItem: .registered))
}

@Test func savedPrecisionProblemsOpenTheWindowWithoutRequestingAnOperation() {
    var policy = ControllerLaunchPresentation()
    let show = policy.shouldPresentOnLaunch(reason: .loginItem,
        hasPresentedBefore: true,
        needsAttention: launchNeedsAttention(savedPrecisionIssue: true))
    #expect(show)
}

@Test func quietLaunchDecisionCannotBeReplayedToRaiseTheWindow() {
    var policy = ControllerLaunchPresentation()
    let initial = policy.shouldPresentOnLaunch(reason: .loginItem,
        hasPresentedBefore: true, needsAttention: false)
    let duplicate = policy.shouldPresentOnLaunch(reason: .otherOrUnknown,
        hasPresentedBefore: false, needsAttention: true)
    #expect(!initial)
    #expect(!duplicate)
}

@Test func visibleLaunchDecisionCannotBeReplayedAfterTheWindowCloses() {
    var policy = ControllerLaunchPresentation()
    let initial = policy.shouldPresentOnLaunch(reason: .otherOrUnknown,
        hasPresentedBefore: true, needsAttention: false)
    let duplicate = policy.shouldPresentOnLaunch(reason: .otherOrUnknown,
        hasPresentedBefore: true, needsAttention: true)
    #expect(initial)
    #expect(!duplicate)
}
