import Testing
@testable import MXErgoCore

@Test func calibratedControlsResolveToConfiguredActions() {
    var resolver = ControllerIntentResolver()

    #expect(resolver.process(.controlPressed(.upperThumb), at: 1) == [.desktopLeft])
    _ = resolver.process(.controlsReleased, at: 1.1)
    #expect(resolver.process(.controlPressed(.lowerThumb), at: 2) == [.desktopRight])
    _ = resolver.process(.controlsReleased, at: 2.1)
    #expect(resolver.process(.controlPressed(.wheelTiltLeft), at: 3) == [.navigateBack])
    _ = resolver.process(.controlsReleased, at: 3.1)
    #expect(resolver.process(.controlPressed(.wheelTiltRight), at: 4) == [.navigateForward])
}

@Test func wheelButtonDownResolvesToMissionControlOnlyOnce() {
    var resolver = ControllerIntentResolver()

    #expect(resolver.process(
        .standardMouseButtonsChanged(previous: 0x00, current: 0x04),
        at: 1
    ) == [.missionControl])
    #expect(resolver.process(
        .standardMouseButtonsChanged(previous: 0x04, current: 0x00),
        at: 1.1
    ).isEmpty)
    #expect(resolver.process(
        .standardMouseButtonsChanged(previous: 0x00, current: 0x01),
        at: 2
    ).isEmpty)
}

@Test func shortPrecisionTapResolvesToMute() {
    var resolver = ControllerIntentResolver(precisionTapMaximumDuration: 0.3)

    #expect(resolver.process(.controlPressed(.precision), at: 10).isEmpty)
    #expect(resolver.process(.controlsReleased, at: 10.3) == [.toggleMute])
}

@Test func longPrecisionPressDoesNotResolveToMute() {
    var resolver = ControllerIntentResolver(precisionTapMaximumDuration: 0.3)

    _ = resolver.process(.controlPressed(.precision), at: 10)
    #expect(resolver.process(.controlsReleased, at: 10.301).isEmpty)
}

@Test func precisionAndWheelResolveToTwoVolumeStepsPerNotchWithoutMute() {
    var resolver = ControllerIntentResolver(volumeStepsPerNotch: 2)

    _ = resolver.process(.controlPressed(.precision), at: 10)
    #expect(resolver.process(.verticalScroll(notches: 1), at: 10.1) == [.volumeUp(steps: 2)])
    #expect(resolver.process(.verticalScroll(notches: -2), at: 10.2) == [.volumeDown(steps: 4)])
    #expect(resolver.process(.controlsReleased, at: 10.25).isEmpty)
}

@Test func ordinaryWheelScrollProducesNoControllerIntent() {
    var resolver = ControllerIntentResolver()

    #expect(resolver.process(.verticalScroll(notches: 1), at: 1).isEmpty)
}

@Test func precisionPumpIgnoresOtherCIDsAndMutesOnShortTap() {
    var pump = PrecisionControlEventPump(featureIndex: 0x0A)
    let otherPress = notificationBytes(featureIndex: 0x0A, controlID: 0x0056)
    let precisionPress = notificationBytes(featureIndex: 0x0A, controlID: 0x00ED)
    let release = notificationBytes(featureIndex: 0x0A, controlID: 0)
    let wrongFeature = notificationBytes(featureIndex: 0x0B, controlID: 0x00ED)

    #expect(pump.processHIDPPNotification(otherPress, at: 1).isEmpty)
    #expect(pump.processHIDPPNotification(wrongFeature, at: 1).isEmpty)
    #expect(pump.processHIDPPNotification(precisionPress, at: 10).isEmpty)
    #expect(pump.processHIDPPNotification(release, at: 10.2) == [.toggleMute])
}

@Test func precisionPressedFlagTracksHoldState() {
    var resolver = ControllerIntentResolver()
    #expect(!resolver.isPrecisionPressed)
    _ = resolver.process(.controlPressed(.precision), at: 1)
    #expect(resolver.isPrecisionPressed)
    _ = resolver.process(.controlsReleased, at: 1.1)
    #expect(!resolver.isPrecisionPressed)
}

@Test func precisionPumpVolumeRequiresPrecisionHeld() {
    var pump = PrecisionControlEventPump(featureIndex: 0x0A, volumeStepsPerNotch: 2)
    #expect(pump.processVerticalScroll(notches: 1, at: 1).isEmpty)
    _ = pump.processHIDPPNotification(
        notificationBytes(featureIndex: 0x0A, controlID: 0x00ED),
        at: 10
    )
    #expect(pump.processVerticalScroll(notches: 1, at: 10.1) == [.volumeUp(steps: 2)])
    #expect(pump.processHIDPPNotification(
        notificationBytes(featureIndex: 0x0A, controlID: 0),
        at: 10.2
    ).isEmpty)
}

private func notificationBytes(featureIndex: UInt8, controlID: UInt16) -> [UInt8] {
    [
        0x11, 0xFF, featureIndex, 0x00,
        UInt8(controlID >> 8), UInt8(controlID & 0xFF),
    ] + Array(repeating: 0, count: 14)
}
