import CoreGraphics
import Foundation
import MXErgoCore
import MXErgoEventSynthesis
import Testing
@testable import MXErgoEventTap

private final class RecordingPoster: SyntheticEventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private let succeeds: Bool
    private var storage: [SyntheticEvent] = []

    init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    var posted: [SyntheticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func post(_ events: [SyntheticEvent]) -> Bool {
        lock.lock()
        storage.append(contentsOf: events)
        lock.unlock()
        return succeeds
    }
}

@Test func tapMaskAdmitsExactlyOtherMouseDownUpAndScrollWheel() {
    let mask = EventSynthesisTap.observedEventMask
    let admitted: [CGEventType] = [.otherMouseDown, .otherMouseUp, .scrollWheel]
    for type in admitted {
        #expect(mask & CGEventMask(1 << type.rawValue) != 0)
    }
    // The ordinary click types are the ones that matter: an event the tap
    // never receives is an event it can never swallow, whatever its state.
    let excluded: [CGEventType] = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .keyDown, .keyUp, .mouseMoved, .leftMouseDragged, .flagsChanged,
    ]
    for type in excluded {
        #expect(mask & CGEventMask(1 << type.rawValue) == 0)
    }
    #expect(mask.nonzeroBitCount == admitted.count)
}

@Test func decoderTranslatesButtonsAndBothScrollAxes() {
    #expect(ObservedEventDecoder.decode(
        type: .otherMouseDown, buttonNumber: 3,
        deltaAxis1: 0, deltaAxis2: 0, isContinuous: 0
    ) == .otherMouseDown(buttonNumber: 3))

    #expect(ObservedEventDecoder.decode(
        type: .otherMouseUp, buttonNumber: 4,
        deltaAxis1: 0, deltaAxis2: 0, isContinuous: 0
    ) == .otherMouseUp(buttonNumber: 4))

    #expect(ObservedEventDecoder.decode(
        type: .scrollWheel, buttonNumber: 0,
        deltaAxis1: -3, deltaAxis2: 0, isContinuous: 0
    ) == .scroll(horizontalUnits: 0, verticalUnits: -3, isContinuous: false))

    #expect(ObservedEventDecoder.decode(
        type: .scrollWheel, buttonNumber: 0,
        deltaAxis1: 0, deltaAxis2: 2, isContinuous: 1
    ) == .scroll(horizontalUnits: -2, verticalUnits: 0, isContinuous: true))
}

@Test func decoderConventionIsTheOnePlaceThatDecidesWhichSignIsALeftTilt() {
    // Which sign a left tilt produces has never been observed on this
    // trackball. It is a single switch so one hardware session settles it.
    #expect(HorizontalScrollConvention.assumed == .positiveIsLeft)

    #expect(HorizontalScrollConvention.positiveIsLeft.direction(forDeltaAxis2: 1) == .left)
    #expect(HorizontalScrollConvention.positiveIsLeft.direction(forDeltaAxis2: -1) == .right)
    #expect(HorizontalScrollConvention.positiveIsRight.direction(forDeltaAxis2: 1) == .right)
    #expect(HorizontalScrollConvention.positiveIsRight.direction(forDeltaAxis2: -1) == .left)
    #expect(HorizontalScrollConvention.positiveIsLeft.direction(forDeltaAxis2: 0) == nil)

    // The policy's own convention is that negative units mean a left tilt, so
    // flipping the wire convention flips the sign the policy sees.
    #expect(ObservedEventDecoder.decode(
        type: .scrollWheel, buttonNumber: 0,
        deltaAxis1: 0, deltaAxis2: 5, isContinuous: 0,
        convention: .positiveIsLeft
    ) == .scroll(horizontalUnits: -5, verticalUnits: 0, isContinuous: false))
    #expect(ObservedEventDecoder.decode(
        type: .scrollWheel, buttonNumber: 0,
        deltaAxis1: 0, deltaAxis2: 5, isContinuous: 0,
        convention: .positiveIsRight
    ) == .scroll(horizontalUnits: 5, verticalUnits: 0, isContinuous: false))
}

@Test func decoderRefusesEventTypesOutsideTheMaskSoTheyArePassedThrough() {
    for type in [CGEventType.leftMouseDown, .keyDown, .flagsChanged, .tapDisabledByTimeout] {
        #expect(ObservedEventDecoder.decode(
            type: type, buttonNumber: 0,
            deltaAxis1: 0, deltaAxis2: 0, isContinuous: 0
        ) == nil)
    }
}

@Test func applierPassesThroughAndSuppressesWithoutInjectingAnything() {
    let poster = RecordingPoster()
    var diagnostics = EventSynthesisDiagnostics()

    #expect(EventSynthesisDecisionApplier.apply(
        .passThrough, poster: poster, diagnostics: &diagnostics
    ) == .passThrough)
    #expect(EventSynthesisDecisionApplier.apply(
        .suppress, poster: poster, diagnostics: &diagnostics
    ) == .suppress)

    #expect(poster.posted.isEmpty)
    #expect(diagnostics.passedThroughCount == 1)
    #expect(diagnostics.suppressedCount == 1)
    #expect(diagnostics.postedCount == 0)
}

@Test func applierSuppressesTheOriginalOnlyAfterTheReplacementIsInjected() {
    let poster = RecordingPoster()
    var diagnostics = EventSynthesisDiagnostics()
    let replacement = SyntheticEvent.keyChord(keyCode: 126, modifiers: .control)

    #expect(EventSynthesisDecisionApplier.apply(
        .suppressAndPost([replacement]), poster: poster, diagnostics: &diagnostics
    ) == .suppress)

    #expect(poster.posted == [replacement])
    #expect(diagnostics.suppressedCount == 1)
    #expect(diagnostics.postedCount == 1)
    #expect(diagnostics.postFailureCount == 0)
    #expect(diagnostics.lastDecisionDescription == "posted Control+key 126")
}

@Test func aFailedInjectionPassesTheOriginalThroughRatherThanSwallowingIt() {
    let poster = RecordingPoster(succeeds: false)
    var diagnostics = EventSynthesisDiagnostics()

    // Losing the input outright is the one outcome worse than not remapping,
    // so every failure path in this layer fails open.
    #expect(EventSynthesisDecisionApplier.apply(
        .suppressAndPost([.otherMouseClick(buttonNumber: 3)]),
        poster: poster,
        diagnostics: &diagnostics
    ) == .passThrough)

    #expect(diagnostics.postFailureCount == 1)
    #expect(diagnostics.passedThroughCount == 1)
    #expect(diagnostics.suppressedCount == 0)
    #expect(diagnostics.postedCount == 0)
}

@Test func endToEndDecisionsForOneFlickAndOneRemappedThumbPress() throws {
    let poster = RecordingPoster()
    var diagnostics = EventSynthesisDiagnostics()
    var policy = EventSynthesisPolicy(plan: try EventSynthesisPlan.reviewed())

    func feed(
        type: CGEventType,
        buttonNumber: Int64 = 0,
        deltaAxis2: Int64 = 0,
        at timestamp: TimeInterval
    ) -> SuppressionOutcome {
        guard let kind = ObservedEventDecoder.decode(
            type: type, buttonNumber: buttonNumber,
            deltaAxis1: 0, deltaAxis2: deltaAxis2, isContinuous: 0
        ) else {
            return .passThrough
        }
        diagnostics.observedCount += 1
        return EventSynthesisDecisionApplier.apply(
            policy.decide(kind, at: timestamp),
            poster: poster,
            diagnostics: &diagnostics
        )
    }

    #expect(feed(type: .otherMouseDown, buttonNumber: 4, at: 1) == .suppress)
    #expect(feed(type: .otherMouseUp, buttonNumber: 4, at: 1.05) == .suppress)
    #expect(feed(type: .leftMouseDown, at: 1.1) == .passThrough)
    // A three-notch flick under the assumed convention: positive is a left
    // tilt, which the plan binds to back.
    #expect(feed(type: .scrollWheel, deltaAxis2: 1, at: 2) == .suppress)
    #expect(feed(type: .scrollWheel, deltaAxis2: 1, at: 2.03) == .suppress)
    #expect(feed(type: .scrollWheel, deltaAxis2: 1, at: 2.06) == .suppress)

    #expect(poster.posted == [
        .keyChord(keyCode: 123, modifiers: .control),
        .otherMouseClick(buttonNumber: 3),
    ])
    #expect(diagnostics.observedCount == 5)
    #expect(diagnostics.suppressedCount == 5)
    #expect(diagnostics.postFailureCount == 0)
}

@Test func eventLayerIsProductlessUnwiredAndHoldsExactlyOneInjectionSite() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectRoot = packageRoot
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let manifest = try String(
        contentsOf: packageRoot.appendingPathComponent("Package.swift"),
        encoding: .utf8
    )
    let products = try #require(
        manifest.split(separator: "targets: [", maxSplits: 1).first
    )
    #expect(!products.contains("MXErgoEventSynthesis"))
    #expect(!products.contains("MXErgoEventTap"))
    // Declaration, the tap's dependency, and one edge from each test target.
    #expect(manifest.components(
        separatedBy: "\"MXErgoEventSynthesis\""
    ).count - 1 == 4)
    // Declaration and one edge from its own test target.
    #expect(manifest.components(
        separatedBy: "\"MXErgoEventTap\""
    ).count - 1 == 2)

    // Neither module may reach a signed binary. A suppressing global tap is a
    // new capability class, and promotion is a separate review.
    let projectYAML = try String(
        contentsOf: projectRoot.appendingPathComponent("project.yml"),
        encoding: .utf8
    )
    let projectFile = try String(
        contentsOf: projectRoot
            .appendingPathComponent("MXErgoController.xcodeproj")
            .appendingPathComponent("project.pbxproj"),
        encoding: .utf8
    )
    let appSources = try sourceText(
        under: projectRoot.appendingPathComponent("App")
    )
    for module in ["MXErgoEventSynthesis", "MXErgoEventTap"] {
        #expect(!projectYAML.contains(module))
        #expect(!projectFile.contains(module))
        #expect(!appSources.contains(module))
    }

    // Comments are stripped first, so these assert what the code does rather
    // than what it mentions. Explaining a constraint must not trip it.
    let policyCode = try codeText(
        under: packageRoot.appendingPathComponent("Sources/MXErgoEventSynthesis")
    )
    let tapCode = try codeText(
        under: packageRoot.appendingPathComponent("Sources/MXErgoEventTap")
    )

    // The policy half decides and cannot cause an event to exist. Keeping
    // CoreGraphics out of it is what makes that checkable rather than claimed.
    for forbidden in ["CoreGraphics", "CGEvent", "AXIsProcess" + "Trusted"] {
        #expect(!policyCode.contains(forbidden))
    }
    // No product means no `public`: these modules are unreachable from outside
    // the package by the type system, not only by the build graph.
    for code in [policyCode, tapCode] {
        #expect(!code.contains("public "))
        #expect(!code.contains("@" + "main"))
    }

    // One door for injection, for the same reason the Precision runtime has
    // one IOHIDDeviceSetReport: "what can this app inject into my session"
    // should be answerable by reading one function.
    let allCode = try codeText(
        under: packageRoot.appendingPathComponent("Sources")
    )
    #expect(allCode.components(separatedBy: ".post" + "(tap:").count - 1 == 1)
    #expect(tapCode.components(separatedBy: ".post" + "(tap:").count - 1 == 1)
    // Two suppressing taps exist in the package: the Precision scroll swallow
    // in MXErgoHID, and this one. A third would need saying out loud.
    #expect(allCode.components(separatedBy: "CGEvent.tap" + "Create").count - 1 == 2)
    #expect(tapCode.components(separatedBy: "CGEvent.tap" + "Create").count - 1 == 1)
    // A suppressing tap needs Accessibility, and it is refused without it in
    // exactly one place.
    #expect(tapCode.components(
        separatedBy: "AXIsProcess" + "Trusted()"
    ).count - 1 == 1)
}

/// Source with line comments removed. These targets contain no block comments
/// and no string literal holding a double slash, so dropping from the first
/// occurrence on each line is exact for them.
private func codeText(under directory: URL) throws -> String {
    try sourceText(under: directory)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
            guard let range = line.range(of: "//") else { return line }
            return line[line.startIndex ..< range.lowerBound]
        }
        .joined(separator: "\n")
}

private func sourceText(under directory: URL) throws -> String {
    let enumerator = try #require(
        FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        )
    )
    let files = enumerator.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
    return try files.map {
        try String(contentsOf: $0, encoding: .utf8)
    }.joined(separator: "\n")
}
