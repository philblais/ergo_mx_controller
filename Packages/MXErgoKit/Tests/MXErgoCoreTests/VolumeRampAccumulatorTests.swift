import Testing
@testable import MXErgoCore

@Test func volumeRampRetainsEveryEnqueuedStepAndBoundsEachTick() {
    var ramp = VolumeRampAccumulator(
        scalarPerStep: 0.1,
        maximumScalarChangePerTick: 0.04
    )
    ramp.enqueue(steps: 2)

    let changes = [
        ramp.takeNextChange(),
        ramp.takeNextChange(),
        ramp.takeNextChange(),
        ramp.takeNextChange(),
        ramp.takeNextChange(),
    ]

    #expect(changes == [0.04, 0.04, 0.04, 0.04, 0.04])
    #expect(!ramp.hasPendingChange)
}

@Test func oppositeVolumeInputCancelsPendingRampMovement() {
    var ramp = VolumeRampAccumulator(
        scalarPerStep: 0.1,
        maximumScalarChangePerTick: 0.04
    )
    ramp.enqueue(steps: 2)
    ramp.enqueue(steps: -1)

    #expect(ramp.takeNextChange() == 0.04)
    #expect(ramp.takeNextChange() == 0.04)
    let finalChange = ramp.takeNextChange()
    #expect(finalChange != nil)
    #expect(abs((finalChange ?? 0) - 0.02) < 0.000_001)
    #expect(!ramp.hasPendingChange)
}

@Test func resettingVolumeRampDropsPendingMovement() {
    var ramp = VolumeRampAccumulator()
    ramp.enqueue(steps: 4)
    ramp.reset()

    #expect(ramp.takeNextChange() == nil)
}
