import Foundation
import Testing
@testable import MXErgoCore

@Test func mappedActionPlanBuildsTheFiveBTTBindingsWithoutPosting() throws {
    let plan = try MappedControlActionPlan.make(
        reviewedControlIDs: MappedControlActionPlan.controlIDs
    )

    #expect(plan.authorization == .notAuthorizedForExecution)
    #expect(MappedControlActionPlan.controlIDs == [
        0x0052, 0x0053, 0x0056, 0x005B, 0x005D,
    ])
    #expect(plan.bindings.map(\.control) == [
        .wheelClick, .lowerThumb, .upperThumb, .wheelTiltLeft, .wheelTiltRight,
    ])
    #expect(!plan.bindings.contains { $0.control == .precision })
    #expect(plan.bindings.map(\.intent) == [
        .missionControl, .desktopRight, .desktopLeft, .navigateBack, .navigateForward,
    ])

    let wheel = try plan.binding(for: MXErgoControl.wheelClick.rawValue)
    #expect(wheel.synthesizedAction == .controlArrow(name: "Up Arrow", keyCode: 126))
    let upper = try plan.binding(for: MXErgoControl.upperThumb.rawValue)
    #expect(upper.synthesizedAction == .controlArrow(name: "Left Arrow", keyCode: 123))
    let lower = try plan.binding(for: MXErgoControl.lowerThumb.rawValue)
    #expect(lower.synthesizedAction == .controlArrow(name: "Right Arrow", keyCode: 124))
    let tiltLeft = try plan.binding(for: MXErgoControl.wheelTiltLeft.rawValue)
    #expect(tiltLeft.synthesizedAction == .threeFingerSwipe(name: "Page Back", direction: .left))
    let tiltRight = try plan.binding(for: MXErgoControl.wheelTiltRight.rawValue)
    #expect(tiltRight.synthesizedAction == .threeFingerSwipe(name: "Page Forward", direction: .right))
}

@Test func mappedActionPlanRejectsPrecisionMissingAndUnexpectedControls() {
    #expect(throws: MappedControlActionPlanError.precisionControlExcluded) {
        try MappedControlActionPlan.make(
            reviewedControlIDs: MappedControlActionPlan.controlIDs + [
                MXErgoControl.precision.rawValue,
            ]
        )
    }
    #expect(throws: MappedControlActionPlanError.missingMappedControl(0x0053)) {
        try MappedControlActionPlan.make(
            reviewedControlIDs: MappedControlActionPlan.controlIDs.filter { $0 != 0x0053 }
        )
    }
    #expect(throws: MappedControlActionPlanError.unexpectedMappedControl(0x00C8)) {
        try MappedControlActionPlan.make(
            reviewedControlIDs: MappedControlActionPlan.controlIDs + [0x00C8]
        )
    }
}

@Test func mappedActionPlanIntentsMatchTheControllerResolver() throws {
    let plan = try MappedControlActionPlan.make(
        reviewedControlIDs: MappedControlActionPlan.controlIDs
    )
    var resolver = ControllerIntentResolver()
    for binding in plan.bindings {
        _ = resolver.process(.controlsReleased, at: 0)
        let intents = resolver.process(.controlPressed(binding.control), at: 1)
        #expect(intents == [binding.intent])
    }
}
