import Foundation
import MXErgoCore
import Testing
@testable import MXErgoEventLayer

@Test func aRememberedOnArmsTheLayerOnlyWhenItCanActuallyWork() {
    #expect(EventLayerAutostart.decide(
        rememberedPreference: true,
        accessibilityGranted: true,
        alreadyRunning: false
    ) == .start)

    // The case worth having a function for: losing Accessibility between
    // launches is ordinary — a macOS update or a rebuild to a new path does
    // it — and a remembered "on" must then explain itself rather than fail
    // somewhere deeper or do nothing at all.
    #expect(EventLayerAutostart.decide(
        rememberedPreference: true,
        accessibilityGranted: false,
        alreadyRunning: false
    ) == .blockedOnAccessibility)

    #expect(EventLayerAutostart.decide(
        rememberedPreference: true,
        accessibilityGranted: true,
        alreadyRunning: true
    ) == .alreadyRunning)
}

@Test func aRememberedOffIsNeverOverriddenByAnythingElse() {
    // Nothing may arm a suppressing global tap that the user last left off.
    for accessibility in [true, false] {
        for running in [true, false] {
            #expect(EventLayerAutostart.decide(
                rememberedPreference: false,
                accessibilityGranted: accessibility,
                alreadyRunning: running
            ) == .stayOff)
        }
    }
}

@Test func theLoginItemDistinguishesApprovedFromMerelyRegistered() {
    // Registering succeeds and macOS then silently declines to launch the app
    // until a person approves it. Reporting that as "on" would be a lie the
    // user discovers only after the next restart.
    #expect(LoginItemRegistration.registered.isRegistered)
    #expect(!LoginItemRegistration.requiresApproval.isRegistered)
    #expect(LoginItemRegistration.requiresApproval.needsAttention)
    #expect(LoginItemRegistration.notFound.needsAttention)
    #expect(!LoginItemRegistration.notRegistered.needsAttention)
    #expect(!LoginItemRegistration.registered.needsAttention)

    for state: LoginItemRegistration in [
        .notRegistered, .registered, .requiresApproval, .notFound,
    ] {
        #expect(!state.message.isEmpty)
    }
    #expect(LoginItemRegistration.requiresApproval.message.contains("Login Items"))
}
