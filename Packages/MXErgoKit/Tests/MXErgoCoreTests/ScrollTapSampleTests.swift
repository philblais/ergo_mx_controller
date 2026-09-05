import Foundation
import Testing
@testable import MXErgoCore

@Test func scrollTapSampleNamesTheHorizontalSignExplicitly() {
    // The sign is the entire content of this observation, and a bare "1" in a
    // screenshot invites exactly the misreading the sample exists to prevent.
    let right = ScrollTapSample(
        deltaAxis1: 0, deltaAxis2: 3, isContinuous: false, wasSuppressed: false
    )
    let left = ScrollTapSample(
        deltaAxis1: 0, deltaAxis2: -3, isContinuous: false, wasSuppressed: false
    )
    #expect(right.description == "axis1 0 · axis2 +3 · discrete")
    #expect(left.description == "axis1 0 · axis2 -3 · discrete")
    #expect(right.description != left.description)
}

@Test func scrollTapSampleDistinguishesContinuousFromDiscreteAndSuppressed() {
    #expect(ScrollTapSample(
        deltaAxis1: -2, deltaAxis2: 0, isContinuous: true, wasSuppressed: false
    ).description == "axis1 -2 · axis2 0 · continuous")

    // A suppressed sample can only come from the Precision volume path, which
    // is the one case where a missing scroll is intended.
    #expect(ScrollTapSample(
        deltaAxis1: 1, deltaAxis2: 0, isContinuous: false, wasSuppressed: true
    ).description == "axis1 +1 · axis2 0 · discrete · suppressed")
}

@Test func scrollTapSampleIsHorizontalOnlyWhenTheSecondAxisMoved() {
    #expect(!ScrollTapSample(
        deltaAxis1: 5, deltaAxis2: 0, isContinuous: false, wasSuppressed: false
    ).isHorizontal)
    #expect(ScrollTapSample(
        deltaAxis1: 0, deltaAxis2: -1, isContinuous: false, wasSuppressed: false
    ).isHorizontal)
    // Mixed-axis events exist, and the horizontal half is what the tilt
    // measurement is after.
    #expect(ScrollTapSample(
        deltaAxis1: 2, deltaAxis2: 1, isContinuous: false, wasSuppressed: false
    ).isHorizontal)
}

@Test func naturalScrollDirectionReadsTheGlobalPreferenceKey() throws {
    #expect(NaturalScrollDirection.preferenceKey == "com.apple.swipescrolldirection")

    let suiteName = "com.phib.MXErgoControllerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // Absent means off, which is the macOS default for a mouse.
    #expect(!NaturalScrollDirection.isEnabled(in: defaults))
    defaults.set(true, forKey: NaturalScrollDirection.preferenceKey)
    #expect(NaturalScrollDirection.isEnabled(in: defaults))
    defaults.set(false, forKey: NaturalScrollDirection.preferenceKey)
    #expect(!NaturalScrollDirection.isEnabled(in: defaults))

    #expect(NaturalScrollDirection.description(isEnabled: true) == "Natural scrolling on")
    #expect(NaturalScrollDirection.description(isEnabled: false) == "Natural scrolling off")
}
