import Foundation

/// Sequences bounded preparation steps for a user-requested read-only resume.
/// It holds no device authority; the runtime independently validates admission.
@MainActor
public final class PrecisionResumePreparationFlow {
    public enum Step: String, CaseIterable, Sendable {
        case connection, software, preview, selfTest, reporting, readiness, bind, resume
    }
    public enum Outcome: Equatable, Sendable {
        case busy, interrupted, failed(Step), resumed
    }
    public private(set) var isPerforming = false
    public init() {}

    public func perform(
        isCurrent: @MainActor () -> Bool,
        step: @MainActor (Step) async -> Bool
    ) async -> Outcome {
        guard !isPerforming else { return .busy }
        guard !Task.isCancelled, isCurrent() else { return .interrupted }
        isPerforming = true
        defer { isPerforming = false }
        for current in Step.allCases {
            guard !Task.isCancelled, isCurrent() else { return .interrupted }
            let succeeded = await step(current)
            guard !Task.isCancelled, isCurrent() else { return .interrupted }
            guard succeeded else { return .failed(current) }
        }
        return .resumed
    }
}
