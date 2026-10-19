import Testing
@testable import MXErgoCore

@Test func volumeRampRetargetReplacesClippedExcessAndRetainsFractionalMotion() {
    var ramp = VolumeRampAccumulator()
    ramp.enqueue(steps: 10)
    ramp.retarget(pendingScalarChange: 0.10625)
    var total: Float = 0
    while let change = ramp.takeNextChange() { total += change }
    #expect(abs(total - 0.10625) < 0.000_001)
    #expect(!ramp.hasPendingChange)
}

@Test func volumeRampRetargetCanReverseOrCancelPendingMotion() {
    var ramp = VolumeRampAccumulator()
    ramp.enqueue(steps: 5)
    ramp.retarget(pendingScalarChange: -0.01)
    #expect(ramp.takeNextChange() == -0.01)
    ramp.enqueue(steps: 5)
    ramp.retarget(pendingScalarChange: 0.000_000_1)
    #expect(ramp.takeNextChange() == nil)
}

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
