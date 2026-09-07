import Foundation
import MXErgoHID
import MXErgoHIDPP
import MXErgoPrecisionRuntimeAdmission
import MXErgoPrecisionTransport
import MXErgoPrecisionRuntimeComposition
import MXErgoPrecisionRuntimeHostHandoff

package enum PrecisionRuntimeLifecycleError: Error, Sendable, Equatable {
    case observerNotRunning
    case observerRunMismatch(expectedRunID: UUID, actualRunID: UUID?)
    case restartFenceUnavailable
    case alreadyAdmitted
    case notAdmitted
    case shuttingDown
    case stillOwningRuntime
    case alreadyReleased
    case invalidAuthorizationBinding
}

package enum PrecisionRuntimeLifecyclePhase: Sendable, Equatable {
    case bound
    case admitted
    case shutDown
    case released
}

package protocol PrecisionRuntimeLifecycleSession: AnyObject, Sendable {
    var state: PrecisionRuntimeAdmissionState { get async }
    func reviewIntent(
        for operation: PrecisionTemporaryDiversionOperation,
        expiresAtUptimeNanoseconds: UInt64
    ) async throws -> PrecisionRuntimeAdmissionIntent
    func perform(
        _ intent: PrecisionRuntimeAdmissionIntent,
        authorization: PrecisionRuntimeAdmissionAuthorization
    ) async throws
    func shutdown() async -> PrecisionRuntimeShutdownReport
    func inputDiagnostics() async -> PrecisionInputDiagnostics?
}

extension PrecisionRuntimeLifecycleSession {
    /// Diagnostics are evidence, not a capability. A session that cannot
    /// produce them is valid; it simply reports nothing.
    package func inputDiagnostics() async -> PrecisionInputDiagnostics? { nil }
}

extension PrecisionRuntimeAdmission: PrecisionRuntimeLifecycleSession {}

/// Productless owner for one authorized observer run. It installs a restart
/// fence before admission, retains it through runtime ownership and ordered
/// shutdown, and releases it only for an explicit session rollover. Abandoning
/// the owner does not lift the fence.
package actor PrecisionRuntimeLifecycle {
    package typealias Admit = @Sendable (
        PrecisionRuntimeAdmissionConfiguration
    ) async throws -> any PrecisionRuntimeLifecycleSession

    package typealias FenceReleaser = @Sendable (
        MXErgoObserverRestartFence
    ) -> Bool

    private let intent: PrecisionRuntimeAdmissionIntent
    private let fence: MXErgoObserverRestartFence
    private let hostHandoff: any PrecisionRuntimeHostHandoff
    private let releaseFence: FenceReleaser
    private var session: (any PrecisionRuntimeLifecycleSession)?
    private var admissionTask: Task<any PrecisionRuntimeLifecycleSession, Error>?
    private var shutdownTask: Task<PrecisionRuntimeShutdownReport?, Never>?
    private var shutdownRequested = false

    /// Read-only. Available whenever a session exists, regardless of phase.
    package func inputDiagnostics() async -> PrecisionInputDiagnostics? {
        await session?.inputDiagnostics()
    }
    private var phaseStorage: PrecisionRuntimeLifecyclePhase = .bound
    private var lastShutdownReportStorage: PrecisionRuntimeShutdownReport?

    /// Captures the exact running observer, requires the reviewed intent to
    /// name that run, and installs the restart fence before constructing the
    /// host-handoff adapter.
    package static func bind(
        observer: MXErgoObserver,
        intent: PrecisionRuntimeAdmissionIntent,
        evidenceProvider: @escaping
            PrecisionRuntimeObserverHostHandoff.EvidenceProvider
    ) throws -> PrecisionRuntimeLifecycle {
        guard let capturedRun = observer.captureHandoffRun() else {
            throw PrecisionRuntimeLifecycleError.observerNotRunning
        }
        guard capturedRun.runID == intent.observerRunID else {
            throw PrecisionRuntimeLifecycleError.observerRunMismatch(
                expectedRunID: intent.observerRunID,
                actualRunID: capturedRun.runID
            )
        }
        guard let fence = observer.installRestartFence(for: capturedRun) else {
            throw PrecisionRuntimeLifecycleError.restartFenceUnavailable
        }
        let hostHandoff: PrecisionRuntimeObserverHostHandoff
        do {
            hostHandoff = try PrecisionRuntimeObserverHostHandoff(
                observer: observer,
                intent: intent,
                evidenceProvider: evidenceProvider
            )
        } catch {
            _ = observer.releaseRestartFence(fence)
            throw error
        }
        return PrecisionRuntimeLifecycle(
            intent: intent,
            fence: fence,
            hostHandoff: hostHandoff,
            releaseFence: { observer.releaseRestartFence($0) }
        )
    }

    init(
        intent: PrecisionRuntimeAdmissionIntent,
        fence: MXErgoObserverRestartFence,
        hostHandoff: any PrecisionRuntimeHostHandoff,
        releaseFence: @escaping FenceReleaser
    ) {
        self.intent = intent
        self.fence = fence
        self.hostHandoff = hostHandoff
        self.releaseFence = releaseFence
    }

    package var phase: PrecisionRuntimeLifecyclePhase { phaseStorage }

    package var capturedObserverRunID: UUID { intent.observerRunID }

    package var lastShutdownReport: PrecisionRuntimeShutdownReport? {
        lastShutdownReportStorage
    }

    package var shutdownRequiresRecovery: Bool {
        switch lastShutdownReportStorage?.disposition {
        case .recoveryRequired, .stateUnavailable:
            return true
        case .clean, .none:
            return false
        }
    }

    package var admissionState: PrecisionRuntimeAdmissionState? {
        get async { await session?.state }
    }

    package func admit(
        authorization: PrecisionRuntimeAdmissionAuthorization,
        competitorProbe: @escaping
            PrecisionRuntimeAdmissionConfiguration.CompetitorProbe,
        sessionProvider: @escaping
            @Sendable () async throws -> DeviceTransactionSession,
        rootGenerationProvider: @escaping
            @Sendable () async throws -> UInt64,
        handoffTimeoutNanoseconds: UInt64 = 5_000_000_000,
        operationTimeoutNanoseconds: UInt64 = 5_000_000_000,
        unsolicitedHIDPPHandler: (@Sendable ([UInt8]) -> Void)? = nil,
        deviceDisconnectHandler: (@Sendable () -> Void)? = nil
    ) async throws {
        try await admit(
            authorization: authorization,
            competitorProbe: competitorProbe,
            sessionProvider: sessionProvider,
            rootGenerationProvider: rootGenerationProvider,
            handoffTimeoutNanoseconds: handoffTimeoutNanoseconds,
            operationTimeoutNanoseconds: operationTimeoutNanoseconds,
            unsolicitedHIDPPHandler: unsolicitedHIDPPHandler,
            deviceDisconnectHandler: deviceDisconnectHandler,
            admit: { configuration in
                try await PrecisionRuntimeAdmissionFactory.admit(
                    configuration: configuration
                )
            }
        )
    }

    func admit(
        authorization: PrecisionRuntimeAdmissionAuthorization,
        competitorProbe: @escaping
            PrecisionRuntimeAdmissionConfiguration.CompetitorProbe,
        sessionProvider: @escaping
            @Sendable () async throws -> DeviceTransactionSession,
        rootGenerationProvider: @escaping
            @Sendable () async throws -> UInt64,
        handoffTimeoutNanoseconds: UInt64 = 5_000_000_000,
        operationTimeoutNanoseconds: UInt64 = 5_000_000_000,
        nowProvider: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        unsolicitedHIDPPHandler: (@Sendable ([UInt8]) -> Void)? = nil,
        deviceDisconnectHandler: (@Sendable () -> Void)? = nil,
        admit: @escaping Admit
    ) async throws {
        try requireBound()
        guard intent.observerRunID == fence.capturedRunID else {
            throw PrecisionRuntimeLifecycleError.invalidAuthorizationBinding
        }
        let configuration = PrecisionRuntimeAdmissionConfiguration(
            intent: intent,
            authorization: authorization,
            hostHandoff: hostHandoff,
            competitorProbe: competitorProbe,
            sessionProvider: sessionProvider,
            rootGenerationProvider: rootGenerationProvider,
            handoffTimeoutNanoseconds: handoffTimeoutNanoseconds,
            operationTimeoutNanoseconds: operationTimeoutNanoseconds,
            unsolicitedHIDPPHandler: unsolicitedHIDPPHandler,
            deviceDisconnectHandler: deviceDisconnectHandler,
            nowProvider: nowProvider
        )
        // Reserve admission before suspension so shutdown can join a late result.
        let pending = Task { try await admit(configuration) }
        admissionTask = pending
        do {
            let acquired = try await withTaskCancellationHandler {
                try await pending.value
            } onCancel: {
                pending.cancel()
            }
            guard !shutdownRequested else {
                _ = await shutdown()
                throw PrecisionRuntimeLifecycleError.shuttingDown
            }
            session = acquired
            admissionTask = nil
            if Task.isCancelled {
                _ = await shutdown()
                throw CancellationError()
            }
            phaseStorage = .admitted
        } catch {
            if !shutdownRequested { admissionTask = nil }
            throw error
        }
    }

    package func reviewIntent(
        for operation: PrecisionTemporaryDiversionOperation,
        expiresAtUptimeNanoseconds: UInt64
    ) async throws -> PrecisionRuntimeAdmissionIntent {
        try requireAdmitted()
        guard let session else {
            throw PrecisionRuntimeLifecycleError.notAdmitted
        }
        let reviewed = try await session.reviewIntent(
            for: operation,
            expiresAtUptimeNanoseconds: expiresAtUptimeNanoseconds
        )
        guard reviewed.observerRunID == intent.observerRunID,
              reviewed.launchID == intent.launchID else {
            throw PrecisionRuntimeLifecycleError.invalidAuthorizationBinding
        }
        return reviewed
    }

    package func perform(
        _ nextIntent: PrecisionRuntimeAdmissionIntent,
        authorization: PrecisionRuntimeAdmissionAuthorization
    ) async throws {
        try requireAdmitted()
        guard nextIntent.observerRunID == intent.observerRunID,
              nextIntent.launchID == intent.launchID else {
            throw PrecisionRuntimeLifecycleError.invalidAuthorizationBinding
        }
        guard let session else {
            throw PrecisionRuntimeLifecycleError.notAdmitted
        }
        try await session.perform(nextIntent, authorization: authorization)
    }

    package func shutdown() async -> PrecisionRuntimeShutdownReport? {
        if let shutdownTask { return await shutdownTask.value }
        if phaseStorage == .released { return lastShutdownReportStorage }
        shutdownRequested = true
        let pending = admissionTask
        let active = session
        pending?.cancel()
        let task = Task<PrecisionRuntimeShutdownReport?, Never> {
            // Cancellation is logical only. Even an admission that ignores it
            // must finish, and its late session must drain before quit can finish.
            let acquired: (any PrecisionRuntimeLifecycleSession)?
            if let active {
                acquired = active
            } else if let pending {
                acquired = try? await pending.value
            } else {
                acquired = nil
            }
            let report = await acquired?.shutdown()
            self.session = nil
            self.admissionTask = nil
            self.lastShutdownReportStorage = report
            self.phaseStorage = .shutDown
            return report
        }
        shutdownTask = task
        return await task.value
    }

    /// Releases the observer restart fence only after the runtime is gone or
    /// when admission never began. Quit and abandonment keep the fence.
    @discardableResult
    package func releaseObserverRestartFence() throws -> Bool {
        guard admissionTask == nil,
              !shutdownRequested || phaseStorage == .shutDown || phaseStorage == .released else {
            throw PrecisionRuntimeLifecycleError.stillOwningRuntime
        }
        switch phaseStorage {
        case .admitted:
            throw PrecisionRuntimeLifecycleError.stillOwningRuntime
        case .released:
            throw PrecisionRuntimeLifecycleError.alreadyReleased
        case .bound, .shutDown:
            break
        }
        let released = releaseFence(fence)
        phaseStorage = .released
        return released
    }

    private func requireBound() throws {
        guard !shutdownRequested else {
            throw PrecisionRuntimeLifecycleError.shuttingDown
        }
        guard admissionTask == nil else {
            throw PrecisionRuntimeLifecycleError.alreadyAdmitted
        }
        switch phaseStorage {
        case .bound:
            return
        case .admitted:
            throw PrecisionRuntimeLifecycleError.alreadyAdmitted
        case .released:
            throw PrecisionRuntimeLifecycleError.alreadyReleased
        case .shutDown:
            throw PrecisionRuntimeLifecycleError.notAdmitted
        }
    }

    private func requireAdmitted() throws {
        guard !shutdownRequested else {
            throw PrecisionRuntimeLifecycleError.shuttingDown
        }
        guard phaseStorage == .admitted, session != nil else {
            throw PrecisionRuntimeLifecycleError.notAdmitted
        }
    }

}
