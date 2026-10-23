import Foundation
import Testing
@testable import MXErgoCore

private let sequencerFeatureIndex: UInt8 = 0x0A
private let precisionPress: [UInt8] = [0x11, 0xFF, sequencerFeatureIndex, 0x00, 0x00, 0xED]
    + Array(repeating: 0, count: 14)
private let precisionRelease: [UInt8] = [0x11, 0xFF, sequencerFeatureIndex, 0x00, 0x00, 0x00]
    + Array(repeating: 0, count: 14)

private final class RecordedSequencerIntents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ControllerIntent] = []
    var values: [ControllerIntent] { lock.withLock { storage } }
    func append(_ intent: ControllerIntent) { lock.withLock { storage.append(intent) } }
}

private func recordingSequencer() -> (PrecisionInputSequencer, RecordedSequencerIntents) {
    let sequencer = PrecisionInputSequencer(featureIndex: sequencerFeatureIndex)
    let recorded = RecordedSequencerIntents()
    sequencer.setIntentHandler { recorded.append($0) }
    return (sequencer, recorded)
}

@Test func inputSequencerUpdatesHeldBeforeDeliveryReturns() {
    let (sequencer, _) = recordingSequencer()
    sequencer.receiveNotification(precisionPress, at: 1)
    // The scroll tap reads this on another thread; there is no hop to wait for.
    #expect(sequencer.held.isHeld)
    sequencer.receiveNotification(precisionRelease, at: 1.1)
    #expect(!sequencer.held.isHeld)
}

@Test func inputSequencerDeliversIntentsInArrivalOrderWithArrivalTimestamps() {
    let (sequencer, recorded) = recordingSequencer()
    sequencer.receiveNotification(precisionPress, at: 1.0)
    sequencer.receiveNotification(precisionRelease, at: 1.2)
    sequencer.receiveNotification(precisionPress, at: 2.0)
    sequencer.receiveVerticalScroll(notches: 1, at: 2.1)
    sequencer.receiveVerticalScroll(notches: -2, at: 2.2)
    sequencer.receiveNotification(precisionRelease, at: 2.3)
    // A hold longer than the tap limit is neither a mute nor volume.
    sequencer.receiveNotification(precisionPress, at: 3.0)
    sequencer.receiveNotification(precisionRelease, at: 3.5)
    #expect(recorded.values == [
        .toggleMute,
        .volumeUp(steps: 2),
        .volumeDown(steps: 4),
    ])
    #expect(!sequencer.held.isHeld)
}

@Test func inputSequencerResetForgetsAPressSoItsReleaseDoesNotMute() {
    let (sequencer, recorded) = recordingSequencer()
    sequencer.receiveNotification(precisionPress, at: 1)
    sequencer.reset()
    #expect(!sequencer.held.isHeld)
    // A notch after reset must not resume suppression or change volume.
    sequencer.receiveVerticalScroll(notches: 1, at: 1.05)
    #expect(!sequencer.held.isHeld)
    sequencer.receiveNotification(precisionRelease, at: 1.1)
    #expect(recorded.values.isEmpty)
    #expect(sequencer.isAcceptingInput)

    sequencer.receiveNotification(precisionPress, at: 2)
    sequencer.receiveNotification(precisionRelease, at: 2.1)
    #expect(recorded.values == [.toggleMute])
}

@Test func closedInputSequencerReleasesHeldAndIgnoresLaterInputAndHandlers() {
    let (sequencer, recorded) = recordingSequencer()
    sequencer.receiveNotification(precisionPress, at: 1)
    #expect(sequencer.held.isHeld)

    sequencer.close()
    #expect(!sequencer.held.isHeld)
    #expect(!sequencer.isAcceptingInput)
    let late = RecordedSequencerIntents()
    sequencer.setIntentHandler { late.append($0) }
    sequencer.receiveNotification(precisionPress, at: 2)
    sequencer.receiveVerticalScroll(notches: 3, at: 2.1)
    sequencer.receiveNotification(precisionRelease, at: 2.2)
    #expect(!sequencer.held.isHeld)
    #expect(recorded.values.isEmpty)
    #expect(late.values.isEmpty)
    sequencer.close()
    #expect(!sequencer.isAcceptingInput)
}

@Test func inputSequencerIgnoresOtherControlsAndOtherFeatureIndexes() {
    let (sequencer, recorded) = recordingSequencer()
    var otherControl = precisionPress
    otherControl[5] = 0x56
    var otherFeature = precisionPress
    otherFeature[2] = 0x0B
    sequencer.receiveNotification(otherControl, at: 1)
    sequencer.receiveNotification(otherFeature, at: 1.1)
    sequencer.receiveVerticalScroll(notches: 1, at: 1.2)
    #expect(!sequencer.held.isHeld)
    #expect(recorded.values.isEmpty)
}

@Test func inputSequencerConcurrentProducersNeverLeaveHeldAfterTheFinalRelease() async {
    let (sequencer, recorded) = recordingSequencer()
    let taps = 500
    let notches = 2_000
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for index in 0..<taps {
                let time = Double(index)
                sequencer.receiveNotification(precisionPress, at: time)
                sequencer.receiveNotification(precisionRelease, at: time + 0.1)
            }
        }
        group.addTask {
            for index in 0..<notches {
                sequencer.receiveVerticalScroll(notches: 1, at: Double(index) / 4)
            }
        }
    }
    #expect(!sequencer.held.isHeld)
    let values = recorded.values
    let mutes = values.filter { $0 == .toggleMute }.count
    let volume = values.filter { $0 == .volumeUp(steps: 2) }.count
    // Every intent is one of the two kinds, and each tap yields at most one mute.
    #expect(mutes + volume == values.count)
    #expect(mutes <= taps)
    #expect(volume <= notches)
}
