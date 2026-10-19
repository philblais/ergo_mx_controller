import CoreGraphics
import Foundation
import MXErgoCore
import Testing
@testable import MXErgoHID

@Test func disabledPrecisionScrollTapIsReenabledWithoutSuppressingInput() throws {
    let event = try #require(CGEvent(source: nil))
    var reenabled = 0
    var suppressionChecks = 0
    for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
        let result = WheelScrollTapHandler.handle(
            type: type,
            event: event,
            isStopping: false,
            shouldSuppressScroll: {
                suppressionChecks += 1
                return true
            },
            reenableTap: { reenabled += 1 }
        )
        #expect(result?.takeUnretainedValue() === event)
    }
    #expect(reenabled == 2)
    #expect(suppressionChecks == 0)
}

@Test func precisionScrollTapSuppressesOnlyHeldDiscreteVerticalWheelInput() throws {
    let cases: [(vertical: Int64, horizontal: Int64, continuous: Int64, held: Bool, suppress: Bool)] = [
        (1, 0, 0, true, true),
        (-2, 0, 0, true, true),
        (1, 0, 0, false, false),
        (1, 0, 1, true, false),
        (0, 1, 0, true, false),
        (1, -1, 0, true, false),
        (0, 0, 0, true, false),
    ]
    for sample in cases {
        let event = try wheelScrollEvent(
            vertical: sample.vertical,
            horizontal: sample.horizontal,
            continuous: sample.continuous
        )
        let result = WheelScrollTapHandler.handle(
            type: .scrollWheel,
            event: event,
            isStopping: false,
            shouldSuppressScroll: { sample.held },
            reenableTap: { Issue.record("A scroll event must not reenable the tap") }
        )
        #expect((result == nil) == sample.suppress)
        if !sample.suppress {
            #expect(result?.takeUnretainedValue() === event)
        }
    }
}

@Test func stoppingPrecisionScrollTapPassesInputAndDoesNotRearm() throws {
    let event = try wheelScrollEvent(vertical: 1)
    for type in [CGEventType.scrollWheel, .tapDisabledByTimeout, .tapDisabledByUserInput, .otherMouseDown] {
        let result = WheelScrollTapHandler.handle(
            type: type,
            event: event,
            isStopping: true,
            shouldSuppressScroll: {
                Issue.record("A stopping observer must not consult its held flag")
                return true
            },
            reenableTap: { Issue.record("A stopping observer must not rearm its tap") },
            scrollTapObserver: { _ in Issue.record("A stopping observer must not publish samples") }
        )
        #expect(result?.takeUnretainedValue() === event)
    }
}

@Test func precisionScrollTapDiagnosticsReportTheActualScrollDisposition() throws {
    let samples = RecordedWheelScrollTapSamples()
    for continuous: Int64 in [0, 1] {
        let event = try wheelScrollEvent(vertical: -2, continuous: continuous)
        _ = WheelScrollTapHandler.handle(
            type: .scrollWheel,
            event: event,
            isStopping: false,
            shouldSuppressScroll: { true },
            reenableTap: {},
            scrollTapObserver: { samples.append($0) }
        )
    }
    #expect(samples.values == [
        ScrollTapSample(deltaAxis1: -2, deltaAxis2: 0, isContinuous: false, wasSuppressed: true),
        ScrollTapSample(deltaAxis1: -2, deltaAxis2: 0, isContinuous: true, wasSuppressed: false),
    ])
}

private func wheelScrollEvent(
    vertical: Int64,
    horizontal: Int64 = 0,
    continuous: Int64 = 0
) throws -> CGEvent {
    let event = try #require(CGEvent(
        scrollWheelEvent2Source: nil,
        units: .line,
        wheelCount: 2,
        wheel1: Int32(vertical),
        wheel2: Int32(horizontal),
        wheel3: 0
    ))
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous)
    return event
}

private final class RecordedWheelScrollTapSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScrollTapSample] = []

    var values: [ScrollTapSample] { lock.withLock { storage } }

    func append(_ sample: ScrollTapSample) {
        lock.withLock { storage.append(sample) }
    }
}
