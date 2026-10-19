import Foundation

/// No live audio/device APIs are invoked. The actual production controller runs
/// on its serial queue, and each delayed tick is advanced explicitly.
@main
private enum AppAudioRegression {
    static func main() throws {
        try clippedTargetsReverseAtBothBounds()
        try muteSupersedesOlderVolumeChanges()
        try cancellationCannotAccelerateANewerRamp()
        try failedReadDoesNotDispatchVolumeChanges()
        try pausedAudioGatePassesScrollWithoutStoppingInput()
        try stalledOutputDoesNotScheduleAnEndlessRamp()
        print("App audio regression: 6 checks passed (fake audio and scheduler only)")
    }

    private static func clippedTargetsReverseAtBothBounds() throws {
        let high = Fixture(volume: 0.8)
        high.controller.enqueueVolumeSteps(10)
        high.flush()
        high.controller.enqueueVolumeSteps(-1)
        high.flush()
        try high.drain()
        try expect(abs(high.audio.volume - 0.9375) < 0.000_001,
                   "upper-bound reversal must finish at the clamped target")
        try expect(high.statuses.values.last == .volumeChanged(percent: 94),
                   "reported final volume must match the actual fractional target")

        let low = Fixture(volume: 0.2)
        low.controller.enqueueVolumeSteps(-10)
        low.flush()
        low.controller.enqueueVolumeSteps(1)
        low.flush()
        try low.drain()
        try expect(abs(low.audio.volume - 0.0625) < 0.000_001,
                   "lower-bound reversal must discard clipped excess")
    }

    private static func muteSupersedesOlderVolumeChanges() throws {
        let fixture = Fixture(volume: 0.4)
        fixture.controller.enqueueVolumeSteps(5)
        fixture.flush()
        let writesBeforeMute = fixture.audio.adjustmentCount
        fixture.controller.toggleMute()
        fixture.flush()
        try fixture.drain()
        try expect(fixture.audio.isMuted, "older ramp ticks must not undo mute")
        try expect(fixture.audio.adjustmentCount == writesBeforeMute,
                   "mute must cancel remaining volume writes")
        try expect(fixture.statuses.values.last == .muteChanged(isMuted: true),
                   "stale ticks must not replace mute feedback")
    }

    private static func cancellationCannotAccelerateANewerRamp() throws {
        let fixture = Fixture(volume: 0.5)
        fixture.controller.enqueueVolumeSteps(6)
        fixture.flush()
        fixture.controller.cancelPendingVolumeChanges()
        fixture.flush()
        fixture.controller.enqueueVolumeSteps(-2)
        fixture.flush()
        let volumeAfterNewInput = fixture.audio.volume
        let writesAfterNewInput = fixture.audio.adjustmentCount
        try expect(fixture.ticks.runNext(on: fixture.queue), "old tick must still be queued")
        try expect(fixture.audio.volume == volumeAfterNewInput
                   && fixture.audio.adjustmentCount == writesAfterNewInput,
                   "a cancelled generation must not consume the new ramp")
        try fixture.drain()
        try expect(abs(fixture.audio.volume - 0.40625) < 0.000_001,
                   "the new ramp must retain its independent target")
    }

    private static func failedReadDoesNotDispatchVolumeChanges() throws {
        let fixture = Fixture(volume: 0.5)
        fixture.audio.failRead = true
        fixture.controller.enqueueVolumeSteps(1)
        fixture.flush()
        try fixture.drain()
        try expect(fixture.audio.adjustmentCount == 0,
                   "a failed volume read must stop before the first adjustment")
        try expect(fixture.statuses.values.last?.isFailure == true,
                   "failed preparation must be visible")
    }

    private static func pausedAudioGatePassesScrollWithoutStoppingInput() throws {
        let gate = AudioExecutionGate()
        let precisionIsHeld = true
        let shouldSuppress = { precisionIsHeld && gate.isEnabled }
        try expect(!shouldSuppress(), "paused audio must pass scroll through")
        gate.setEnabled(true)
        try expect(shouldSuppress(), "active audio may suppress the held gesture")
        gate.setEnabled(false)
        try expect(!shouldSuppress(), "pausing must synchronously release suppression")
    }

    private static func stalledOutputDoesNotScheduleAnEndlessRamp() throws {
        let fixture = Fixture(volume: 0.5)
        fixture.audio.ignoreAdjustments = true
        fixture.controller.enqueueVolumeSteps(10)
        fixture.flush()
        try fixture.drain()
        try expect(fixture.audio.adjustmentCount == 1,
                   "a successful but unchanged output must stop after its first tick")
        try expect(fixture.statuses.values.last == .volumeChanged(percent: 50),
                   "a stalled driver must report the actual level rather than its unreachable target")
    }
}

private final class Fixture {
    let queue = DispatchQueue(label: "app-audio-regression")
    let audio: FakeAudio
    let ticks = ManualTicks()
    let statuses = Statuses()
    let controller: SmoothSystemAudioController

    init(volume: Float32) {
        let audio = FakeAudio(volume: volume)
        self.audio = audio
        let ticks = self.ticks
        let statuses = self.statuses
        controller = SmoothSystemAudioController(
            output: audio.output,
            queue: queue,
            scheduleTick: { _, tick in ticks.append(tick) },
            statusHandler: { statuses.append($0) }
        )
    }

    func flush() { queue.sync {} }

    func drain() throws {
        var count = 0
        while ticks.runNext(on: queue) {
            count += 1
            try expect(count < 128, "ramp must settle within its bounded scalar range")
        }
    }
}

private final class ManualTicks: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: [@Sendable () -> Void] = []

    func append(_ tick: @escaping @Sendable () -> Void) {
        lock.withLock { ticks.append(tick) }
    }

    func runNext(on queue: DispatchQueue) -> Bool {
        let tick = lock.withLock { ticks.isEmpty ? nil : ticks.removeFirst() }
        guard let tick else { return false }
        queue.sync(execute: tick)
        return true
    }
}

private final class Statuses: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AudioExecutionStatus] = []
    var values: [AudioExecutionStatus] { lock.withLock { storage } }
    func append(_ value: AudioExecutionStatus) { lock.withLock { storage.append(value) } }
}

private final class FakeAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var storedVolume: Float32
    private var storedMuted = false
    private var writes = 0
    private var readFails = false
    private var ignoresAdjustments = false

    init(volume: Float32) { storedVolume = volume }
    var volume: Float32 { lock.withLock { storedVolume } }
    var isMuted: Bool { lock.withLock { storedMuted } }
    var adjustmentCount: Int { lock.withLock { writes } }
    var failRead: Bool {
        get { lock.withLock { readFails } }
        set { lock.withLock { readFails = newValue } }
    }
    var ignoreAdjustments: Bool {
        get { lock.withLock { ignoresAdjustments } }
        set { lock.withLock { ignoresAdjustments = newValue } }
    }

    var output: SystemAudioOutput {
        SystemAudioOutput(
            currentVolume: { [self] in
                try lock.withLock {
                    if readFails { throw TestFailure(message: "injected read failure") }
                    return storedVolume
                }
            },
            adjustVolume: { [self] change in
                lock.withLock {
                    if !ignoresAdjustments {
                        storedVolume = min(1, max(0, storedVolume + change))
                    }
                    storedMuted = false
                    writes += 1
                    return storedVolume
                }
            },
            toggleMute: { [self] in
                lock.withLock { storedMuted.toggle(); return storedMuted }
            }
        )
    }
}

private struct TestFailure: Error { let message: String }

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message: message) }
}
