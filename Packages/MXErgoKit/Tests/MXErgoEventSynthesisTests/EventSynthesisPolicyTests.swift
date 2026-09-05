import Foundation
import MXErgoCore
import Testing
@testable import MXErgoEventSynthesis

private func reviewedPolicy(
    latch: HorizontalTiltLatch = HorizontalTiltLatch()
) throws -> EventSynthesisPolicy {
    EventSynthesisPolicy(plan: try EventSynthesisPlan.reviewed(), tilt: latch)
}

@Test func reviewedPlanRebindsFiveOrdinaryControlsAndExcludesPrecision() throws {
    let plan = try EventSynthesisPlan.reviewed()

    #expect(plan.bindings.count == 5)
    #expect(!plan.bindings.contains { $0.control == .precision })
    #expect(Set(plan.bindings.map(\.control)) == [
        .wheelClick, .lowerThumb, .upperThumb, .wheelTiltLeft, .wheelTiltRight,
    ])

    // The triggers are the CGEvent shapes macOS already delivers for these
    // controls, which is why none of them needs HID++ diversion.
    #expect(plan.binding(for: .otherMouseButton(number: 2))?.control == .wheelClick)
    #expect(plan.binding(for: .otherMouseButton(number: 3))?.control == .lowerThumb)
    #expect(plan.binding(for: .otherMouseButton(number: 4))?.control == .upperThumb)
    #expect(plan.binding(for: .horizontalTilt(direction: .left))?.control == .wheelTiltLeft)
    #expect(plan.binding(for: .horizontalTilt(direction: .right))?.control == .wheelTiltRight)
}

@Test func reviewedReplacementsMatchTheActionPlanAndSubstituteForTheSwipe() throws {
    let plan = try EventSynthesisPlan.reviewed()

    #expect(plan.binding(for: .otherMouseButton(number: 4))?.replacement
        == .keyChord(keyCode: 123, modifiers: .control))
    #expect(plan.binding(for: .otherMouseButton(number: 3))?.replacement
        == .keyChord(keyCode: 124, modifiers: .control))
    #expect(plan.binding(for: .otherMouseButton(number: 2))?.replacement
        == .keyChord(keyCode: 126, modifiers: .control))

    // macOS exposes no public gesture-synthesis API, so the action plan's
    // three-finger swipe becomes the mouse buttons the system already reads as
    // back and forward — the same buttons the thumbs are being rebound away
    // from, which is what makes the substitution a straight swap.
    #expect(plan.binding(for: .horizontalTilt(direction: .left))?.replacement
        == .otherMouseClick(buttonNumber: 3))
    #expect(plan.binding(for: .horizontalTilt(direction: .right))?.replacement
        == .otherMouseClick(buttonNumber: 4))
}

@Test func reviewedPlanIntentsAgreeWithTheMappedControlActionPlan() throws {
    let plan = try EventSynthesisPlan.reviewed()
    let actionPlan = try MappedControlActionPlan.make(
        reviewedControlIDs: MappedControlActionPlan.controlIDs
    )
    for binding in plan.bindings {
        let action = try actionPlan.binding(for: binding.control.rawValue)
        #expect(action.intent == binding.intent)
    }
    #expect(plan.bindsHorizontalTilt)
    #expect(plan.bindsMouseButton(2))
    #expect(plan.bindsMouseButton(3))
    #expect(plan.bindsMouseButton(4))
}

@Test func ordinaryClicksHaveNoBindingAndAreNeverSuppressed() throws {
    var policy = try reviewedPolicy()
    let plan = policy.plan

    // The tap's mask excludes these outright, so this asserts the second,
    // independent guarantee: even if one were somehow delivered, no state the
    // policy can reach turns a primary or secondary click into a suppression.
    for button in [0, 1, 5, 6, 31] {
        #expect(!plan.bindsMouseButton(button))
        #expect(policy.decide(.otherMouseDown(buttonNumber: button), at: 1) == .passThrough)
        #expect(policy.decide(.otherMouseUp(buttonNumber: button), at: 1.1) == .passThrough)
    }
    #expect(policy.heldSuppressedButtons.isEmpty)
}

@Test func boundButtonPressIsSuppressedAndReplacedAndItsReleaseIsSuppressedToo() throws {
    var policy = try reviewedPolicy()

    #expect(policy.decide(.otherMouseDown(buttonNumber: 3), at: 1)
        == .suppressAndPost([.keyChord(keyCode: 124, modifiers: .control)]))
    #expect(policy.heldSuppressedButtons == [3])

    // The release must not reach the frontmost app: it never saw the press.
    #expect(policy.decide(.otherMouseUp(buttonNumber: 3), at: 1.05) == .suppress)
    #expect(policy.heldSuppressedButtons.isEmpty)
}

@Test func releaseIsKeyedOnWhatWasSuppressedRatherThanOnWhatThePlanBinds() throws {
    var policy = try reviewedPolicy()

    _ = policy.decide(.otherMouseDown(buttonNumber: 3), at: 1)
    // Button 4 is bound, but its press was never seen, so its release belongs
    // to whoever did see the press and must be passed through.
    #expect(policy.decide(.otherMouseUp(buttonNumber: 4), at: 1.1) == .passThrough)
    #expect(policy.heldSuppressedButtons == [3])

    // A second release of an already-released button is not swallowed either.
    #expect(policy.decide(.otherMouseUp(buttonNumber: 3), at: 1.2) == .suppress)
    #expect(policy.decide(.otherMouseUp(buttonNumber: 3), at: 1.3) == .passThrough)
}

@Test func modifiersOnThePhysicalPressDoNotChangeTheReviewedReplacement() throws {
    var policy = try reviewedPolicy()
    // The observed event carries no modifier state at all, by construction:
    // the replacement is exactly what was reviewed, every time.
    let first = policy.decide(.otherMouseDown(buttonNumber: 2), at: 1)
    _ = policy.decide(.otherMouseUp(buttonNumber: 2), at: 1.1)
    let second = policy.decide(.otherMouseDown(buttonNumber: 2), at: 2)
    #expect(first == second)
    #expect(first == .suppressAndPost([.keyChord(keyCode: 126, modifiers: .control)]))
}

@Test func continuousHorizontalScrollIsNeverSuppressed() throws {
    var policy = try reviewedPolicy()
    // A trackpad's two-finger swipe is continuous. Swallowing it would break
    // back and forward for every other pointing device on the machine.
    for units in [-8, -1, 1, 8] {
        #expect(policy.decide(
            .scroll(horizontalUnits: units, verticalUnits: 0, isContinuous: true),
            at: 1
        ) == .passThrough)
    }
}

@Test func mixedAxisAndPureVerticalScrollPassThroughUntouched() throws {
    var policy = try reviewedPolicy()
    // A single event can carry both axes. Suppressing it to catch the
    // horizontal half would silently eat the vertical half, which belongs to
    // the Precision volume path.
    #expect(policy.decide(
        .scroll(horizontalUnits: 1, verticalUnits: 3, isContinuous: false),
        at: 1
    ) == .passThrough)
    #expect(policy.decide(
        .scroll(horizontalUnits: 0, verticalUnits: -3, isContinuous: false),
        at: 1.1
    ) == .passThrough)
    #expect(policy.decide(
        .scroll(horizontalUnits: 0, verticalUnits: 0, isContinuous: false),
        at: 1.2
    ) == .passThrough)
}

@Test func oneFlickOfTiltProducesExactlyOneNavigationAndSwallowsTheRest() throws {
    var policy = try reviewedPolicy()

    #expect(policy.decide(
        .scroll(horizontalUnits: -1, verticalUnits: 0, isContinuous: false),
        at: 10
    ) == .suppressAndPost([.otherMouseClick(buttonNumber: 3)]))

    // The device emits several notches per flick. Firing on each would send a
    // browser several pages back from one gesture; letting them through would
    // scroll the page sideways as well.
    for offset in [0.02, 0.05, 0.1] {
        #expect(policy.decide(
            .scroll(horizontalUnits: -1, verticalUnits: 0, isContinuous: false),
            at: 10 + offset
        ) == .suppress)
    }
}

@Test func sustainedTiltRepeatsNoFasterThanTheRepeatInterval() throws {
    var policy = try reviewedPolicy(
        latch: HorizontalTiltLatch(threshold: 1, repeatInterval: 0.35, gestureGap: 0.5)
    )
    var fired = 0
    var time = 10.0
    // Two seconds of continuous tilt at 100 Hz.
    for _ in 0 ..< 200 {
        if case .suppressAndPost = policy.decide(
            .scroll(horizontalUnits: 1, verticalUnits: 0, isContinuous: false),
            at: time
        ) {
            fired += 1
        }
        time += 0.01
    }
    #expect(fired == 6)
}

@Test func reversingTiltFiresImmediatelyRatherThanWaitingOutTheHoldOff() throws {
    var policy = try reviewedPolicy()

    #expect(policy.decide(
        .scroll(horizontalUnits: 1, verticalUnits: 0, isContinuous: false),
        at: 10
    ) == .suppressAndPost([.otherMouseClick(buttonNumber: 4)]))
    #expect(policy.decide(
        .scroll(horizontalUnits: 1, verticalUnits: 0, isContinuous: false),
        at: 10.05
    ) == .suppress)
    // Correcting an overshoot is the one case where the hold-off would be felt,
    // so a deliberate reversal starts a new gesture instead of waiting.
    #expect(policy.decide(
        .scroll(horizontalUnits: -1, verticalUnits: 0, isContinuous: false),
        at: 10.1
    ) == .suppressAndPost([.otherMouseClick(buttonNumber: 3)]))
}

@Test func silenceLongerThanTheGestureGapStartsAFreshTilt() throws {
    var latch = HorizontalTiltLatch(threshold: 3, repeatInterval: 10, gestureGap: 0.5)
    #expect(latch.accumulate(units: 1, at: 1) == nil)
    #expect(latch.accumulate(units: 1, at: 1.1) == nil)
    // The half-built gesture is abandoned, so the next notch starts from zero.
    #expect(latch.accumulate(units: 1, at: 5) == nil)
    #expect(latch.accumulate(units: 1, at: 5.1) == nil)
    #expect(latch.accumulate(units: 1, at: 5.2) == .right)
}

@Test func latchIgnoresZeroUnitsAndAccumulatesMagnitude() {
    var latch = HorizontalTiltLatch(threshold: 4, repeatInterval: 10, gestureGap: 0.5)
    #expect(latch.accumulate(units: 0, at: 1) == nil)
    #expect(latch.accumulate(units: -3, at: 1.1) == nil)
    #expect(latch.accumulate(units: -1, at: 1.2) == .left)
    // A threshold below one would fire on nothing at all.
    #expect(HorizontalTiltLatch(threshold: 0).threshold == 1)
    #expect(HorizontalTiltLatch(threshold: -5).threshold == 1)
}

@Test func resetForgetsHeldButtonsAndInFlightTiltState() throws {
    var policy = try reviewedPolicy()
    _ = policy.decide(.otherMouseDown(buttonNumber: 3), at: 1)
    _ = policy.decide(.scroll(horizontalUnits: 1, verticalUnits: 0, isContinuous: false), at: 1)
    #expect(policy.heldSuppressedButtons == [3])

    policy.reset()

    #expect(policy.heldSuppressedButtons.isEmpty)
    // A stale latch would otherwise swallow the first notch of the next run.
    #expect(policy.decide(
        .scroll(horizontalUnits: 1, verticalUnits: 0, isContinuous: false),
        at: 1.01
    ) == .suppressAndPost([.otherMouseClick(buttonNumber: 4)]))
}

@Test func aChordPressesAndReleasesTheModifierAroundTheKey() {
    // Wheel click's replacement. Setting a flag on the arrow alone satisfies an
    // ordinary application but never makes Control *be* down, and Mission
    // Control is a symbolic hotkey matched against the modifier state the
    // window server believes is current. So the modifier gets real transitions.
    let strokes = SyntheticKeyChordPlanner.strokes(
        keyCode: 126,
        modifiers: .control
    )
    #expect(strokes == [
        SynthesizedKeyStroke(virtualKey: 0x3B, isKeyDown: true, modifiers: .control),
        SynthesizedKeyStroke(virtualKey: 126, isKeyDown: true, modifiers: .control),
        SynthesizedKeyStroke(virtualKey: 126, isKeyDown: false, modifiers: .control),
        SynthesizedKeyStroke(virtualKey: 0x3B, isKeyDown: false, modifiers: []),
    ])
}

@Test func aChordAlwaysEndsWithEveryModifierReleased() {
    // A chord that left a modifier down would leave the whole machine behaving
    // as though a key were stuck, which is far worse than the remap not
    // working.
    for modifiers: SynthesizedModifiers in [
        [], .control, [.control, .shift], [.command, .option, .shift, .control],
    ] {
        let strokes = SyntheticKeyChordPlanner.strokes(
            keyCode: 123,
            modifiers: modifiers
        )
        #expect(strokes.last?.modifiers == [])
        // Each modifier appears exactly once down and once up.
        for (modifier, virtualKey) in SyntheticKeyChordPlanner.modifierOrder
        where modifiers.contains(modifier) {
            let matching = strokes.filter { $0.virtualKey == virtualKey }
            #expect(matching.count == 2)
            #expect(matching.first?.isKeyDown == true)
            #expect(matching.last?.isKeyDown == false)
        }
        // The key itself is pressed with every modifier already down.
        let keyStrokes = strokes.filter { $0.virtualKey == 123 }
        #expect(keyStrokes.count == 2)
        #expect(keyStrokes.allSatisfy { $0.modifiers == modifiers })
        #expect(strokes.count == 2 + 2 * modifiers.rawValue.nonzeroBitCount)
    }
}

@Test func anUnmodifiedChordIsJustTheKeyItself() {
    #expect(SyntheticKeyChordPlanner.strokes(keyCode: 49, modifiers: []) == [
        SynthesizedKeyStroke(virtualKey: 49, isKeyDown: true, modifiers: []),
        SynthesizedKeyStroke(virtualKey: 49, isKeyDown: false, modifiers: []),
    ])
}
