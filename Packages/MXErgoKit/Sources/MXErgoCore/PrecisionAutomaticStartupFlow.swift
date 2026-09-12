import Foundation

/// One launch can resume, or retire a verified baseline and activate once.
/// Execution authority remains exclusively in the runtime owner.
@MainActor public final class PrecisionAutomaticStartupFlow {
    public enum Result: Sendable, Equatable { case active, restored, stopped }
    public private(set) var attempted = false
    public init() {}
    public func perform(
        isCurrent: @MainActor () -> Bool,
        prepare: @MainActor (_ afterCleanRollover: Bool) async -> Result,
        releaseAndRefresh: @MainActor () async throws -> Void
    ) async -> Result {
        guard !attempted, !Task.isCancelled, isCurrent() else { return .stopped }
        attempted = true
        let initial = await prepare(false)
        guard !Task.isCancelled, isCurrent() else { return .stopped }
        guard initial == .restored else { return initial }
        do { try await releaseAndRefresh() } catch { return .stopped }
        guard !Task.isCancelled, isCurrent() else { return .stopped }
        let final = await prepare(true)
        guard !Task.isCancelled, isCurrent(), final == .active else { return .stopped }
        return .active
    }
}
