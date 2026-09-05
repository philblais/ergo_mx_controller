import Foundation
import Testing
@testable import MXErgoEventLayer
import MXErgoEventTap

@Test func reviewDescribesEveryReboundControlInPlainText() throws {
    let review = try EventLayerReview.reviewed()
    #expect(review.bindings.count == 5)

    #expect(review.bindings.map(\.control) == [
        "Wheel click", "Lower thumb", "Upper thumb",
        "Wheel tilt left", "Wheel tilt right",
    ])
    #expect(review.bindings.map(\.intent) == [
        "Mission Control", "Desktop right", "Desktop left", "Back", "Forward",
    ])
    #expect(review.bindings.map(\.trigger) == [
        "mouse button 3", "mouse button 4", "mouse button 5",
        "wheel tilt left", "wheel tilt right",
    ])
    #expect(review.bindings.map(\.replacement) == [
        "Control+key 126", "Control+key 124", "Control+key 123",
        "mouse button 4", "mouse button 5",
    ])
    // Precision emits no ordinary report, so no tap can see it. It stays on
    // the HID++ runtime and must never appear here.
    #expect(!review.bindings.contains { $0.control == "Precision" })
}

@Test func everyTapFailureIsProjectedWithAMessageAPersonCanActOn() {
    #expect(EventLayerError(EventSynthesisTapError.accessibilityNotGranted)
        == .accessibilityNotGranted)
    #expect(EventLayerError(EventSynthesisTapError.eventSourceUnavailable)
        == .eventSourceUnavailable)
    #expect(EventLayerError(EventSynthesisTapError.alreadyRunning)
        == .alreadyRunning)
    // Both tap-construction failures collapse: the distinction is internal and
    // the remedy is identical.
    #expect(EventLayerError(EventSynthesisTapError.tapCreationFailed)
        == .tapUnavailable)
    #expect(EventLayerError(EventSynthesisTapError.runLoopSourceUnavailable)
        == .tapUnavailable)

    #expect(EventLayerError.accessibilityNotGranted.message
        == "Grant Accessibility first; suppressing events requires it")
    for error: EventLayerError in [
        .accessibilityNotGranted, .eventSourceUnavailable,
        .tapUnavailable, .alreadyRunning, .planInvalid("x"),
    ] {
        #expect(!error.message.isEmpty)
    }
}

@Test func aLayerThatWasNeverStartedReportsNothingRatherThanZeroes() {
    let layer = EventLayer()
    #expect(!layer.isRunning)
    // Nil rather than an all-zero struct: "never started" and "started and saw
    // nothing" are different answers, and conflating them is exactly what made
    // the Precision audio failure undiagnosable.
    #expect(layer.diagnostics == nil)
    // Stopping something that never ran is not an error.
    layer.stop()
    #expect(!layer.isRunning)
}

@Test func diagnosticsFlagOnlyTheCountersThatMeanSomethingIsWrong() {
    func make(postFailures: Int = 0, reenables: Int = 0) -> EventLayerDiagnostics {
        EventLayerDiagnostics(
            observedCount: 10, passedThroughCount: 4, suppressedCount: 6,
            postedCount: 3, ownEventCount: 3,
            postFailureCount: postFailures, tapReenableCount: reenables,
            lastDecisionDescription: nil
        )
    }
    #expect(make().summary
        == "observed 10 · passed 4 · suppressed 6 · posted 3 · own 3")
    #expect(!make().needsAttention)
    // A failed injection means input was passed through unremapped.
    #expect(make(postFailures: 1).needsAttention)
    // A re-enable means macOS disabled the tap, usually for being too slow.
    #expect(make(reenables: 1).needsAttention)
}

@Test func theFacadeExposesStartStopReviewAndCountersAndNothingElse() throws {
    let facadeRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MXErgoEventLayer")
    let enumerator = try #require(
        FileManager.default.enumerator(
            at: facadeRoot,
            includingPropertiesForKeys: nil
        )
    )
    let source = try enumerator.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
        .map { try String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")

    let publicDeclarations = source.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("public ") }

    // A pinned list, in the same spirit as the package-declaration lists that
    // guard the Precision stack. Widening the surface of the one type that can
    // take over the user's mouse should require editing this on purpose.
    #expect(publicDeclarations == [
        "public struct EventLayerBinding: Sendable, Equatable {",
        "public let control: String",
        "public let intent: String",
        "public let trigger: String",
        "public let replacement: String",
        "public struct EventLayerReview: Sendable, Equatable {",
        "public let bindings: [EventLayerBinding]",
        "public static func reviewed() throws -> EventLayerReview {",
        "public enum EventLayerError: Error, Sendable, Equatable {",
        "public var message: String {",
        "public struct EventLayerDiagnostics: Sendable, Equatable {",
        "public let observedCount: Int",
        "public let passedThroughCount: Int",
        "public let suppressedCount: Int",
        "public let postedCount: Int",
        "public let ownEventCount: Int",
        "public let postFailureCount: Int",
        "public let tapReenableCount: Int",
        "public let lastDecisionDescription: String?",
        "public var summary: String {",
        "public var needsAttention: Bool {",
        "public final class EventLayer: @unchecked Sendable {",
        "public init() {}",
        "public var isRunning: Bool { tap.isRunning }",
        "public func start(naturalScrollingEnabled: Bool) throws {",
        "public func setNaturalScrolling(enabled: Bool) {",
        "public func stop() {",
        "public enum DiagnosticChord: String, Sendable, Equatable, CaseIterable {",
        "public var label: String {",
        "public func postDiagnosticChord(_ chord: DiagnosticChord) throws -> Bool {",
        "public var diagnostics: EventLayerDiagnostics? {",
    ])
}
