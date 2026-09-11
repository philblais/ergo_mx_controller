import Foundation
import MXErgoHIDPP
import MXErgoPrecisionRuntimeComposition
import MXErgoPrecisionTransport
import MXErgoPrecisionRuntimeJournal

package enum PrecisionRuntimeAdmissionError: Error, Sendable, Equatable {
    case explicitConfirmationRequired
    case invalidAuthorizationBinding
    case authorizationExpired
    case authorizationAlreadyConsumed
    case runtimeJournalEvidenceChanged
    case competingProcesses([String])
    case operationLeaseMismatch
    case invalidHostHandoff
    case actionNotPermitted
    case commandAlreadyInProgress
    case stopped
}

package enum PrecisionRuntimeAdmissionStage: Sendable, Equatable {
    case authorization
    case competitorScan
    case operationLease
    case hostHandoff
    case bootstrap
    case stateValidation
    case composition
    case operation
}

package struct PrecisionRuntimeAdmissionFailure: Error, @unchecked Sendable {
    package let stage: PrecisionRuntimeAdmissionStage
    package let underlying: any Error
    package let durableDisposition: PrecisionRuntimeShutdownDisposition?
    package let shutdownReport: PrecisionRuntimeShutdownReport?
}

package struct PrecisionRuntimeHostHandoffReceipt: Sendable, Equatable {
    package let launchID: UUID
    package let session: DeviceTransactionSession
    package let rootGeneration: UInt64
    package let observerRunID: UUID
    package let pendingRequestCount: Int
    package let observerWasUnscheduled: Bool
    package let observerDeviceWasClosed: Bool

    package init(
        launchID: UUID,
        session: DeviceTransactionSession,
        rootGeneration: UInt64,
        observerRunID: UUID,
        pendingRequestCount: Int,
        observerWasUnscheduled: Bool,
        observerDeviceWasClosed: Bool
    ) {
        self.launchID = launchID
        self.session = session
        self.rootGeneration = rootGeneration
        self.observerRunID = observerRunID
        self.pendingRequestCount = pendingRequestCount
        self.observerWasUnscheduled = observerWasUnscheduled
        self.observerDeviceWasClosed = observerDeviceWasClosed
    }
}

package protocol PrecisionRuntimeHostHandoff: Sendable {
    func stopAndWait(
        launchID: UUID,
        expectedSession: DeviceTransactionSession,
        expectedRootGeneration: UInt64,
        expectedObserverRunID: UUID,
        timeoutNanoseconds: UInt64
    ) async throws -> PrecisionRuntimeHostHandoffReceipt
}

/// Complete immutable binding reviewed before a one-use authorization is
/// issued. The readiness snapshot deliberately remains non-authorizing; this
/// separate value binds explicit consent to one launch and one operation.
package struct PrecisionRuntimeAdmissionIntent: Sendable {
    package let launchID: UUID
    package let observerRunID: UUID
    package let operation: PrecisionTemporaryDiversionOperation
    package let readiness: PrecisionTemporaryDiversionReadinessSnapshot
    package let session: DeviceTransactionSession
    package let rootGeneration: UInt64
    package let sourceBaselineURL: URL
    package let runtimeJournalURL: URL
    package let sourceBaselineCanonicalPath: String
    package let runtimeJournalCanonicalPath: String
    package let expectedRuntimeSnapshot: PrecisionRuntimeJournalSnapshot?
    package let expiresAtUptimeNanoseconds: UInt64

    fileprivate func matches(_ other: Self) -> Bool {
        launchID == other.launchID
            && observerRunID == other.observerRunID
            && operation == other.operation
            && readiness == other.readiness
            && session == other.session
            && rootGeneration == other.rootGeneration
            && sourceBaselineCanonicalPath
                == other.sourceBaselineCanonicalPath
            && runtimeJournalCanonicalPath
                == other.runtimeJournalCanonicalPath
            && expectedRuntimeSnapshot == other.expectedRuntimeSnapshot
            && expiresAtUptimeNanoseconds
                == other.expiresAtUptimeNanoseconds
    }
}

package enum PrecisionRuntimeAdmissionReview {
    /// Performs read-only journal inspection and captures the exact existing
    /// runtime revision/digest when present. No lock, file write, host handoff,
    /// device acquisition, or HID operation occurs here.
    package static func makeIntent(
        launchID: UUID,
        observerRunID: UUID,
        operation: PrecisionTemporaryDiversionOperation? = nil,
        readiness: PrecisionTemporaryDiversionReadinessSnapshot,
        session: DeviceTransactionSession,
        rootGeneration: UInt64,
        sourceBaselineURL: URL,
        runtimeJournalURL: URL,
        expiresAtUptimeNanoseconds: UInt64
    ) throws -> PrecisionRuntimeAdmissionIntent {
        let canonicalSourceURL = canonicalURL(sourceBaselineURL)
        let canonicalRuntimeURL = canonicalURL(runtimeJournalURL)
        let request = PrecisionRuntimeJournalBootstrapRequest(
            plan: readiness.plan,
            session: session,
            rootGeneration: rootGeneration,
            sourceBaselineURL: canonicalSourceURL,
            sourceBaselineSHA256: readiness.sourceJournalSHA256,
            sourceBaselineTransactionID:
                readiness.sourceBaselineTransactionID,
            runtimeJournalURL: canonicalRuntimeURL
        )
        let expectedRuntimeSnapshot = try PrecisionRuntimeJournalBootstrap
            .inspect(request)
        let resolvedOperation = try operation ?? initialOperation(
            for: expectedRuntimeSnapshot
        )
        let intent = PrecisionRuntimeAdmissionIntent(
            launchID: launchID,
            observerRunID: observerRunID,
            operation: resolvedOperation,
            readiness: readiness,
            session: session,
            rootGeneration: rootGeneration,
            sourceBaselineURL: canonicalSourceURL,
            runtimeJournalURL: canonicalRuntimeURL,
            sourceBaselineCanonicalPath: canonicalSourceURL.path,
            runtimeJournalCanonicalPath: canonicalRuntimeURL.path,
            expectedRuntimeSnapshot: expectedRuntimeSnapshot,
            expiresAtUptimeNanoseconds: expiresAtUptimeNanoseconds
        )
        try validateIntent(intent)
        return intent
    }

    package static func initialOperation(
        for snapshot: PrecisionRuntimeJournalSnapshot?
    ) throws -> PrecisionTemporaryDiversionOperation {
        guard let snapshot else { return .activate }
        do {
            try validateAction(
                .recover,
                snapshot: snapshot,
                permitsDeactivate: false
            )
            return .recover
        } catch {
            try validateAction(
                .activate,
                snapshot: snapshot,
                permitsDeactivate: false
            )
            return .activate
        }
    }
}

/// Non-Codable, actor-isolated, and one-use. A failed consumption attempt also
/// burns the capability so a mismatched launch cannot probe and replay it.
package actor PrecisionRuntimeAdmissionAuthorization {
    private let binding: PrecisionRuntimeAdmissionIntent
    private var consumed = false

    fileprivate init(binding: PrecisionRuntimeAdmissionIntent) {
        self.binding = binding
    }

    fileprivate func consume(
        matching intent: PrecisionRuntimeAdmissionIntent,
        nowUptimeNanoseconds: UInt64
    ) throws {
        guard !consumed else {
            throw PrecisionRuntimeAdmissionError.authorizationAlreadyConsumed
        }
        consumed = true
        guard binding.matches(intent) else {
            throw PrecisionRuntimeAdmissionError.invalidAuthorizationBinding
        }
        guard nowUptimeNanoseconds <= binding.expiresAtUptimeNanoseconds else {
            throw PrecisionRuntimeAdmissionError.authorizationExpired
        }
    }
}

package enum PrecisionRuntimeAdmissionAuthorizationFactory {
    package static func issue(
        for intent: PrecisionRuntimeAdmissionIntent,
        explicitlyConfirmed: Bool
    ) throws -> PrecisionRuntimeAdmissionAuthorization {
        try issue(
            for: intent,
            explicitlyConfirmed: explicitlyConfirmed,
            nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    package static func issue(
        for intent: PrecisionRuntimeAdmissionIntent,
        explicitlyConfirmed: Bool,
        nowUptimeNanoseconds: UInt64
    ) throws -> PrecisionRuntimeAdmissionAuthorization {
        guard explicitlyConfirmed else {
            throw PrecisionRuntimeAdmissionError.explicitConfirmationRequired
        }
        try validateIntent(intent)
        guard nowUptimeNanoseconds <= intent.expiresAtUptimeNanoseconds else {
            throw PrecisionRuntimeAdmissionError.authorizationExpired
        }
        return PrecisionRuntimeAdmissionAuthorization(binding: intent)
    }
}

package struct PrecisionRuntimeAdmissionConfiguration: Sendable {
    package typealias CompetitorProbe = @Sendable () throws -> [String]

    package let intent: PrecisionRuntimeAdmissionIntent
    package let authorization: PrecisionRuntimeAdmissionAuthorization
    package let hostHandoff: any PrecisionRuntimeHostHandoff
    package let competitorProbe: CompetitorProbe
    package let sessionProvider:
        @Sendable () async throws -> DeviceTransactionSession
    package let rootGenerationProvider: @Sendable () async throws -> UInt64
    package let handoffTimeoutNanoseconds: UInt64
    package let operationTimeoutNanoseconds: UInt64
    package let unsolicitedHIDPPHandler: (@Sendable ([UInt8]) -> Void)?
    package let deviceDisconnectHandler: (@Sendable () -> Void)?
    let nowProvider: @Sendable () -> UInt64

    package init(
        intent: PrecisionRuntimeAdmissionIntent,
        authorization: PrecisionRuntimeAdmissionAuthorization,
        hostHandoff: any PrecisionRuntimeHostHandoff,
        competitorProbe: @escaping CompetitorProbe,
        sessionProvider: @escaping
            @Sendable () async throws -> DeviceTransactionSession,
        rootGenerationProvider: @escaping
            @Sendable () async throws -> UInt64,
        handoffTimeoutNanoseconds: UInt64 = 5_000_000_000,
        operationTimeoutNanoseconds: UInt64 = 5_000_000_000,
        unsolicitedHIDPPHandler: (@Sendable ([UInt8]) -> Void)? = nil,
        deviceDisconnectHandler: (@Sendable () -> Void)? = nil
    ) {
        self.intent = intent
        self.authorization = authorization
        self.hostHandoff = hostHandoff
        self.competitorProbe = competitorProbe
        self.sessionProvider = sessionProvider
        self.rootGenerationProvider = rootGenerationProvider
        self.handoffTimeoutNanoseconds = handoffTimeoutNanoseconds
        self.operationTimeoutNanoseconds = operationTimeoutNanoseconds
        self.unsolicitedHIDPPHandler = unsolicitedHIDPPHandler
        self.deviceDisconnectHandler = deviceDisconnectHandler
        nowProvider = { DispatchTime.now().uptimeNanoseconds }
    }

    package init(
        intent: PrecisionRuntimeAdmissionIntent,
        authorization: PrecisionRuntimeAdmissionAuthorization,
        hostHandoff: any PrecisionRuntimeHostHandoff,
        competitorProbe: @escaping CompetitorProbe,
        sessionProvider: @escaping
            @Sendable () async throws -> DeviceTransactionSession,
        rootGenerationProvider: @escaping
            @Sendable () async throws -> UInt64,
        handoffTimeoutNanoseconds: UInt64 = 5_000_000_000,
        operationTimeoutNanoseconds: UInt64 = 5_000_000_000,
        unsolicitedHIDPPHandler: (@Sendable ([UInt8]) -> Void)? = nil,
        deviceDisconnectHandler: (@Sendable () -> Void)? = nil,
        nowProvider: @escaping @Sendable () -> UInt64
    ) {
        self.intent = intent
        self.authorization = authorization
        self.hostHandoff = hostHandoff
        self.competitorProbe = competitorProbe
        self.sessionProvider = sessionProvider
        self.rootGenerationProvider = rootGenerationProvider
        self.handoffTimeoutNanoseconds = handoffTimeoutNanoseconds
        self.operationTimeoutNanoseconds = operationTimeoutNanoseconds
        self.unsolicitedHIDPPHandler = unsolicitedHIDPPHandler
        self.deviceDisconnectHandler = deviceDisconnectHandler
        self.nowProvider = nowProvider
    }
}

package enum PrecisionRuntimeAdmissionState: Sendable, Equatable {
    case admitting
    case inactive
    case active
    case restored
    case recoveryRequired
    case conflicted
    case stopping
    case stopped(PrecisionRuntimeShutdownDisposition)
    case failed(
        stage: PrecisionRuntimeAdmissionStage,
        durableDisposition: PrecisionRuntimeShutdownDisposition?
    )
}

package enum PrecisionRuntimeAdmissionFactory {
    typealias Inspect = @Sendable (
        PrecisionRuntimeJournalBootstrapRequest
    ) throws -> PrecisionRuntimeJournalSnapshot?
    typealias AcquireLease = @Sendable (
        URL
    ) throws -> MXErgoDeviceOperationLease
    typealias Bootstrap = @Sendable (
        PrecisionRuntimeJournalBootstrapRequest,
        MXErgoDeviceOperationLease
    ) async throws -> PrecisionRuntimeJournalContext
    typealias MakeRuntime = @Sendable (
        PrecisionRuntimeCompositionConfiguration
    ) async throws -> any PrecisionRuntimeControlling

    package static func admit(
        configuration: PrecisionRuntimeAdmissionConfiguration
    ) async throws -> PrecisionRuntimeAdmission {
        try await admit(
            configuration: configuration,
            inspect: { try PrecisionRuntimeJournalBootstrap.inspect($0) },
            acquireLease: {
                try MXErgoDeviceOperationLease.acquire(beside: $0)
            },
            bootstrap: { request, lease in
                try await PrecisionRuntimeJournalBootstrap.prepare(
                    request,
                    operationLease: lease
                )
            },
            makeRuntime: {
                try await PrecisionRuntimeCompositionFactory.make(
                    configuration: $0
                )
            }
        )
    }

    static func admit(
        configuration: PrecisionRuntimeAdmissionConfiguration,
        inspect: Inspect,
        acquireLease: AcquireLease,
        bootstrap: Bootstrap,
        makeRuntime: MakeRuntime
    ) async throws -> PrecisionRuntimeAdmission {
        let intent = configuration.intent
        do {
            try validateIntent(intent)
            try await configuration.authorization.consume(
                matching: intent,
                nowUptimeNanoseconds: configuration.nowProvider()
            )
        } catch {
            throw failure(.authorization, error)
        }

        let request = bootstrapRequest(for: intent)
        do {
            guard try inspect(request) == intent.expectedRuntimeSnapshot else {
                throw PrecisionRuntimeAdmissionError
                    .runtimeJournalEvidenceChanged
            }
            try requireAuthorizationUnexpired(
                intent,
                nowUptimeNanoseconds: configuration.nowProvider()
            )
        } catch {
            throw failure(.authorization, error)
        }

        do {
            try requireNoCompetitors(configuration.competitorProbe)
        } catch {
            throw failure(.competitorScan, error)
        }

        let operationLease: MXErgoDeviceOperationLease
        do {
            operationLease = try acquireLease(intent.runtimeJournalURL)
            guard operationLease.protects(
                journalURL: intent.runtimeJournalURL
            ) else {
                throw PrecisionRuntimeAdmissionError.operationLeaseMismatch
            }
            guard try inspect(request) == intent.expectedRuntimeSnapshot else {
                throw PrecisionRuntimeAdmissionError
                    .runtimeJournalEvidenceChanged
            }
        } catch {
            throw failure(.operationLease, error)
        }

        do {
            try Task.checkCancellation()
            let receipt = try await configuration.hostHandoff.stopAndWait(
                launchID: intent.launchID,
                expectedSession: intent.session,
                expectedRootGeneration: intent.rootGeneration,
                expectedObserverRunID: intent.observerRunID,
                timeoutNanoseconds: configuration.handoffTimeoutNanoseconds
            )
            guard receipt.launchID == intent.launchID,
                  receipt.session == intent.session,
                  receipt.rootGeneration == intent.rootGeneration,
                  receipt.observerRunID == intent.observerRunID,
                  receipt.pendingRequestCount == 0,
                  receipt.observerWasUnscheduled,
                  receipt.observerDeviceWasClosed else {
                throw PrecisionRuntimeAdmissionError.invalidHostHandoff
            }
            try Task.checkCancellation()
            try requireAuthorizationUnexpired(
                intent,
                nowUptimeNanoseconds: configuration.nowProvider()
            )
        } catch {
            throw failure(.hostHandoff, error)
        }

        do {
            try requireNoCompetitors(configuration.competitorProbe)
            try requireAuthorizationUnexpired(
                intent,
                nowUptimeNanoseconds: configuration.nowProvider()
            )
        } catch {
            throw failure(.competitorScan, error)
        }

        let context: PrecisionRuntimeJournalContext
        do {
            context = try await bootstrap(request, operationLease)
        } catch {
            throw failure(.bootstrap, error)
        }

        do {
            try requireAuthorizationUnexpired(
                intent,
                nowUptimeNanoseconds: configuration.nowProvider()
            )
            try validateAuthorizedBootstrapContext(
                context,
                intent: intent
            )
            try validateInitialAction(
                intent.operation,
                snapshot: context.snapshot
            )
        } catch {
            throw failure(.stateValidation, error)
        }

        let runtime: any PrecisionRuntimeControlling
        do {
            let runtimeConfiguration = PrecisionRuntimeCompositionConfiguration(
                journalContext: context,
                operationLease: operationLease,
                sessionProvider: configuration.sessionProvider,
                rootGenerationProvider:
                    configuration.rootGenerationProvider,
                competitorProbe: configuration.competitorProbe,
                operationTimeoutNanoseconds:
                    configuration.operationTimeoutNanoseconds,
                unsolicitedHIDPPHandler:
                    configuration.unsolicitedHIDPPHandler,
                deviceDisconnectHandler:
                    configuration.deviceDisconnectHandler
            )
            runtime = try await makeRuntime(runtimeConfiguration)
        } catch {
            throw failure(.composition, error)
        }

        let admission = PrecisionRuntimeAdmission(
            baseIntent: intent,
            journalContext: context,
            runtime: runtime,
            operationLease: operationLease,
            competitorProbe: configuration.competitorProbe,
            sessionProvider: configuration.sessionProvider,
            rootGenerationProvider: configuration.rootGenerationProvider,
            nowProvider: configuration.nowProvider
        )
        try await admission.performInitiallyAuthorized(intent)
        return admission
    }

    private static func failure(
        _ stage: PrecisionRuntimeAdmissionStage,
        _ error: any Error
    ) -> PrecisionRuntimeAdmissionFailure {
        PrecisionRuntimeAdmissionFailure(
            stage: stage,
            underlying: error,
            durableDisposition: nil,
            shutdownReport: nil
        )
    }
}

/// Sole productless façade over the admitted runtime. It never exposes the
/// composition, endpoint, transport, coordinator, repository, or an
/// authorization-free mutation method.
package actor PrecisionRuntimeAdmission {
    private let baseIntent: PrecisionRuntimeAdmissionIntent
    private let journalContext: PrecisionRuntimeJournalContext
    private let competitorProbe:
        PrecisionRuntimeAdmissionConfiguration.CompetitorProbe
    private let sessionProvider:
        @Sendable () async throws -> DeviceTransactionSession
    private let rootGenerationProvider: @Sendable () async throws -> UInt64
    private let nowProvider: @Sendable () -> UInt64
    private var runtime: (any PrecisionRuntimeControlling)?

    /// Diagnostics are readable whenever a runtime exists, including while an
    /// operation is in flight. They gate nothing, so they take no reservation.
    package func inputDiagnostics() async -> PrecisionInputDiagnostics? {
        await runtime?.inputDiagnostics()
    }
    private var operationLease: MXErgoDeviceOperationLease?
    private var stateStorage: PrecisionRuntimeAdmissionState = .admitting
    private var commandInProgress = false
    private var shutdownReportStorage: PrecisionRuntimeShutdownReport?
    private var shutdownWaiters:
        [CheckedContinuation<PrecisionRuntimeShutdownReport, Never>] = []

    fileprivate init(
        baseIntent: PrecisionRuntimeAdmissionIntent,
        journalContext: PrecisionRuntimeJournalContext,
        runtime: any PrecisionRuntimeControlling,
        operationLease: MXErgoDeviceOperationLease,
        competitorProbe: @escaping
            PrecisionRuntimeAdmissionConfiguration.CompetitorProbe,
        sessionProvider: @escaping
            @Sendable () async throws -> DeviceTransactionSession,
        rootGenerationProvider: @escaping
            @Sendable () async throws -> UInt64,
        nowProvider: @escaping @Sendable () -> UInt64
    ) {
        self.baseIntent = baseIntent
        self.journalContext = journalContext
        self.runtime = runtime
        self.operationLease = operationLease
        self.competitorProbe = competitorProbe
        self.sessionProvider = sessionProvider
        self.rootGenerationProvider = rootGenerationProvider
        self.nowProvider = nowProvider
    }

    package var state: PrecisionRuntimeAdmissionState { stateStorage }

    /// Produces a fresh read-only binding for a subsequent operation. The
    /// returned intent is still non-authorizing and must receive separate,
    /// explicit one-use confirmation.
    package func reviewIntent(
        for operation: PrecisionTemporaryDiversionOperation,
        expiresAtUptimeNanoseconds: UInt64
    ) async throws -> PrecisionRuntimeAdmissionIntent {
        try beginCommand()
        defer { finishCommand() }
        let session = try await sessionProvider()
        try requireCommandOperational()
        let rootGeneration = try await rootGenerationProvider()
        try requireCommandOperational()
        guard session == baseIntent.session,
              rootGeneration == baseIntent.rootGeneration else {
            throw PrecisionRuntimeAdmissionError.invalidAuthorizationBinding
        }
        let request = bootstrapRequest(for: baseIntent)
        let snapshot = try await journalContext.source.loadValidatedSnapshot()
        try requireCommandOperational()
        guard try PrecisionRuntimeJournalBootstrap.inspect(request)
                == snapshot else {
            throw PrecisionRuntimeAdmissionError
                .runtimeJournalEvidenceChanged
        }
        try validateSubsequentAction(operation, snapshot: snapshot)
        let intent = PrecisionRuntimeAdmissionIntent(
            launchID: baseIntent.launchID,
            observerRunID: baseIntent.observerRunID,
            operation: operation,
            readiness: baseIntent.readiness,
            session: baseIntent.session,
            rootGeneration: baseIntent.rootGeneration,
            sourceBaselineURL: baseIntent.sourceBaselineURL,
            runtimeJournalURL: baseIntent.runtimeJournalURL,
            sourceBaselineCanonicalPath:
                baseIntent.sourceBaselineCanonicalPath,
            runtimeJournalCanonicalPath:
                baseIntent.runtimeJournalCanonicalPath,
            expectedRuntimeSnapshot: snapshot,
            expiresAtUptimeNanoseconds: expiresAtUptimeNanoseconds
        )
        try validateIntent(intent)
        try requireCommandOperational()
        return intent
    }

    package func perform(
        _ intent: PrecisionRuntimeAdmissionIntent,
        authorization: PrecisionRuntimeAdmissionAuthorization
    ) async throws {
        try beginCommand()
        defer { finishCommand() }
        guard intent.launchID == baseIntent.launchID,
              intent.observerRunID == baseIntent.observerRunID,
              intent.readiness == baseIntent.readiness,
              intent.session == baseIntent.session,
              intent.rootGeneration == baseIntent.rootGeneration,
              intent.sourceBaselineCanonicalPath
                == baseIntent.sourceBaselineCanonicalPath,
              intent.runtimeJournalCanonicalPath
                == baseIntent.runtimeJournalCanonicalPath else {
            throw PrecisionRuntimeAdmissionError.invalidAuthorizationBinding
        }
        try await authorization.consume(
            matching: intent,
            nowUptimeNanoseconds: nowProvider()
        )
        try requireCommandOperational()
        do {
            guard let operationLease else {
                throw PrecisionRuntimeAdmissionError.stopped
            }
            guard operationLease.protects(
                journalURL: journalContext.source.journalURL
            ) else {
                throw PrecisionRuntimeAdmissionError.operationLeaseMismatch
            }
            let request = bootstrapRequest(for: intent)
            guard try PrecisionRuntimeJournalBootstrap.inspect(request)
                    == intent.expectedRuntimeSnapshot,
                  let expected = intent.expectedRuntimeSnapshot,
                  try await journalContext.source.loadValidatedSnapshot()
                    == expected else {
                throw PrecisionRuntimeAdmissionError
                    .runtimeJournalEvidenceChanged
            }
            try requireNoCompetitors(competitorProbe)
            try requireAuthorizationUnexpired(
                intent,
                nowUptimeNanoseconds: nowProvider()
            )
            try validateSubsequentAction(intent.operation, snapshot: expected)
            try await runOperation(intent.operation)
        } catch {
            let report = await shutdown()
            throw PrecisionRuntimeAdmissionFailure(
                stage: .operation,
                underlying: error,
                durableDisposition: report.disposition,
                shutdownReport: report
            )
        }
    }

    package func shutdown() async -> PrecisionRuntimeShutdownReport {
        if let shutdownReportStorage { return shutdownReportStorage }
        switch stateStorage {
        case .stopping:
            return await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
        default:
            stateStorage = .stopping
        }
        guard let runtime else {
            let report = PrecisionRuntimeShutdownReport(
                disposition: .stateUnavailable("runtime unavailable"),
                deviceCloseReturn: nil
            )
            finishShutdown(report)
            return report
        }
        let report = await runtime.shutdown()
        self.runtime = nil
        operationLease = nil
        finishShutdown(report)
        return report
    }

    fileprivate func performInitiallyAuthorized(
        _ intent: PrecisionRuntimeAdmissionIntent
    ) async throws {
        do {
            try beginCommand()
        } catch {
            throw PrecisionRuntimeAdmissionFailure(
                stage: .operation,
                underlying: error,
                durableDisposition: nil,
                shutdownReport: nil
            )
        }
        defer { finishCommand() }
        do {
            try Task.checkCancellation()
            try requireAuthorizationUnexpired(
                intent,
                nowUptimeNanoseconds: nowProvider()
            )
            guard try await journalContext.source.loadValidatedSnapshot()
                    == journalContext.snapshot else {
                throw PrecisionRuntimeAdmissionError
                    .runtimeJournalEvidenceChanged
            }
            try requireCommandOperational()
            try requireAuthorizationUnexpired(
                intent,
                nowUptimeNanoseconds: nowProvider()
            )
            try await runOperation(intent.operation)
        } catch {
            let report = await shutdown()
            throw PrecisionRuntimeAdmissionFailure(
                stage: .operation,
                underlying: error,
                durableDisposition: report.disposition,
                shutdownReport: report
            )
        }
    }

    private func runOperation(
        _ operation: PrecisionTemporaryDiversionOperation
    ) async throws {
        try requireCommandOperational()
        guard let runtime else {
            throw PrecisionRuntimeAdmissionError.stopped
        }
        switch operation {
        case .activate:
            _ = try await runtime.activate()
        case .deactivate:
            _ = try await runtime.deactivate()
        case .recover:
            _ = try await runtime.recoverExplicitly()
        case .resume:
            _ = try await runtime.resumeVerified()
        }
        try requireCommandOperational()
        let snapshot = try await journalContext.source.loadValidatedSnapshot()
        try requireCommandOperational()
        stateStorage = try admissionState(snapshot.envelope)
    }

    private func beginCommand() throws {
        try requireCommandOperational()
        guard !commandInProgress else {
            throw PrecisionRuntimeAdmissionError.commandAlreadyInProgress
        }
        commandInProgress = true
    }

    private func finishCommand() {
        commandInProgress = false
    }

    private func requireCommandOperational() throws {
        guard runtime != nil, operationLease != nil else {
            throw PrecisionRuntimeAdmissionError.stopped
        }
        switch stateStorage {
        case .stopping, .stopped:
            throw PrecisionRuntimeAdmissionError.stopped
        default:
            return
        }
    }

    private func finishShutdown(_ report: PrecisionRuntimeShutdownReport) {
        shutdownReportStorage = report
        stateStorage = .stopped(report.disposition)
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: report) }
    }
}

private func validateIntent(
    _ intent: PrecisionRuntimeAdmissionIntent
) throws {
    let readiness = intent.readiness
    let session = intent.session
    let hashBytes = readiness.sourceJournalSHA256.utf8
    guard intent.observerRunID != nullObserverRunID,
          readiness.authorization == .notAuthorizedForExecution,
          readiness.plan.device == session.device,
          readiness.plan.featureIndex == session.featureIndex,
          readiness.plan.featureVersion == session.featureVersion,
          session.featureID == ReprogControlsV4.featureID,
          session.featureVersion == 3,
          session.connectionEpoch == readiness.connectionEpoch,
          intent.rootGeneration == readiness.connectionGeneration,
          hashBytes.count == 64,
          hashBytes.allSatisfy({ byte in
              (48...57).contains(byte) || (97...102).contains(byte)
          }),
          canonicalPath(intent.sourceBaselineURL)
            == intent.sourceBaselineCanonicalPath,
          canonicalPath(intent.runtimeJournalURL)
            == intent.runtimeJournalCanonicalPath,
          intent.sourceBaselineCanonicalPath
            != intent.runtimeJournalCanonicalPath,
          (intent.sourceBaselineCanonicalPath as NSString)
            .deletingLastPathComponent
            == (intent.runtimeJournalCanonicalPath as NSString)
                .deletingLastPathComponent else {
        throw PrecisionRuntimeAdmissionError.invalidAuthorizationBinding
    }
    if intent.operation == .resume {
        guard let snapshot = intent.expectedRuntimeSnapshot else {
            throw PrecisionRuntimeAdmissionError.actionNotPermitted
        }
        try validateAction(.resume, snapshot: snapshot, permitsDeactivate: false)
    }
    if let snapshot = intent.expectedRuntimeSnapshot {
        try snapshot.envelope.validate()
        guard snapshot.sha256.count == 64,
              snapshot.envelope.sourceBaselineTransactionID
                == readiness.sourceBaselineTransactionID,
              snapshot.envelope.device == readiness.plan.device,
              snapshot.envelope.featureIndex == readiness.plan.featureIndex,
              snapshot.envelope.featureVersion == readiness.plan.featureVersion,
              snapshot.envelope.isSafeSessionMatch(session),
              try snapshot.envelope.control(
                  PrecisionTemporaryDiversionPlan.controlID
              ).baseline == readiness.plan.baseline else {
            throw PrecisionRuntimeAdmissionError.invalidAuthorizationBinding
        }
        if intent.operation == .resume {
            guard try snapshot.envelope.control(
                PrecisionTemporaryDiversionPlan.controlID
            ).intended == readiness.plan.activeState else {
                throw PrecisionRuntimeAdmissionError.invalidAuthorizationBinding
            }
        }
    }
}

private func bootstrapRequest(
    for intent: PrecisionRuntimeAdmissionIntent
) -> PrecisionRuntimeJournalBootstrapRequest {
    PrecisionRuntimeJournalBootstrapRequest(
        plan: intent.readiness.plan,
        session: intent.session,
        rootGeneration: intent.rootGeneration,
        sourceBaselineURL: intent.sourceBaselineURL,
        sourceBaselineSHA256: intent.readiness.sourceJournalSHA256,
        sourceBaselineTransactionID:
            intent.readiness.sourceBaselineTransactionID,
        runtimeJournalURL: intent.runtimeJournalURL
    )
}

private func requireNoCompetitors(
    _ probe: PrecisionRuntimeAdmissionConfiguration.CompetitorProbe
) throws {
    let competitors = try probe()
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .sorted()
    guard competitors.isEmpty else {
        throw PrecisionRuntimeAdmissionError.competingProcesses(competitors)
    }
}

private func requireAuthorizationUnexpired(
    _ intent: PrecisionRuntimeAdmissionIntent,
    nowUptimeNanoseconds: UInt64
) throws {
    guard nowUptimeNanoseconds <= intent.expiresAtUptimeNanoseconds else {
        throw PrecisionRuntimeAdmissionError.authorizationExpired
    }
}

private func validateAuthorizedBootstrapContext(
    _ context: PrecisionRuntimeJournalContext,
    intent: PrecisionRuntimeAdmissionIntent
) throws {
    let snapshot = context.snapshot
    let envelope = snapshot.envelope
    try envelope.validate()
    guard context.plan == intent.readiness.plan,
          context.session == intent.session,
          context.rootGeneration == intent.rootGeneration,
          context.sourceBaselineSHA256
            == intent.readiness.sourceJournalSHA256,
          context.sourceBaselineTransactionID
            == intent.readiness.sourceBaselineTransactionID,
          canonicalPath(context.source.journalURL)
            == intent.runtimeJournalCanonicalPath,
          envelope.sourceBaselineTransactionID
            == intent.readiness.sourceBaselineTransactionID,
          envelope.device == intent.readiness.plan.device,
          envelope.featureIndex == intent.readiness.plan.featureIndex,
          envelope.featureVersion == intent.readiness.plan.featureVersion,
          envelope.isSafeSessionMatch(intent.session),
          try envelope.control(
              PrecisionTemporaryDiversionPlan.controlID
          ).baseline == intent.readiness.plan.baseline else {
        throw PrecisionRuntimeAdmissionError.runtimeJournalEvidenceChanged
    }

    switch (intent.expectedRuntimeSnapshot, context.disposition) {
    case (nil, .created):
        guard envelope.revision == 0,
              envelope.status == .prepared else {
            throw PrecisionRuntimeAdmissionError
                .runtimeJournalEvidenceChanged
        }
    case let (.some(expected), .reused(status)):
        guard snapshot == expected,
              status == expected.envelope.status else {
            throw PrecisionRuntimeAdmissionError
                .runtimeJournalEvidenceChanged
        }
    default:
        throw PrecisionRuntimeAdmissionError.runtimeJournalEvidenceChanged
    }
}

private func validateInitialAction(
    _ operation: PrecisionTemporaryDiversionOperation,
    snapshot: PrecisionRuntimeJournalSnapshot
) throws {
    try validateAction(
        operation,
        snapshot: snapshot,
        permitsDeactivate: false
    )
}

private func validateSubsequentAction(
    _ operation: PrecisionTemporaryDiversionOperation,
    snapshot: PrecisionRuntimeJournalSnapshot
) throws {
    try validateAction(
        operation,
        snapshot: snapshot,
        permitsDeactivate: true
    )
}

func validateAction(
    _ operation: PrecisionTemporaryDiversionOperation,
    snapshot: PrecisionRuntimeJournalSnapshot,
    permitsDeactivate: Bool
) throws {
    let envelope = snapshot.envelope
    guard !envelope.controls.contains(where: { $0.phase == .conflicted }),
          envelope.dirtyControlIDs.allSatisfy({
              $0 == PrecisionTemporaryDiversionPlan.controlID
          }) else {
        throw PrecisionRuntimeAdmissionError.actionNotPermitted
    }
    let phase = try envelope.control(
        PrecisionTemporaryDiversionPlan.controlID
    ).phase
    switch (operation, envelope.status, phase) {
    case (.activate, .prepared, .baselineVerified):
        return
    case (.resume, .running, .appliedVerified):
        guard !envelope.controls.contains(where: {
            $0.attempts.contains(where: { $0.outcome == .outcomeUnknown })
        }) else {
            throw PrecisionRuntimeAdmissionError.actionNotPermitted
        }
        return
    case (.recover, .running, .appliedVerified),
         (.recover, .recoveryRequired, .applyMayHaveOccurred),
         (.recover, .recoveryRequired, .restoreMayHaveOccurred):
        guard !envelope.hasAmbiguousRestoreSET else {
            throw PrecisionRuntimeAdmissionError.actionNotPermitted
        }
        return
    case (.deactivate, .running, .appliedVerified) where permitsDeactivate:
        return
    default:
        throw PrecisionRuntimeAdmissionError.actionNotPermitted
    }
}

private func admissionState(
    _ envelope: DeviceTransactionEnvelope
) throws -> PrecisionRuntimeAdmissionState {
    guard !envelope.controls.contains(where: { $0.phase == .conflicted }) else {
        return .conflicted
    }
    let unrelatedDirty = envelope.dirtyControlIDs.filter {
        $0 != PrecisionTemporaryDiversionPlan.controlID
    }
    guard unrelatedDirty.isEmpty else { return .recoveryRequired }
    let control = try envelope.control(
        PrecisionTemporaryDiversionPlan.controlID
    )
    switch control.phase {
    case .baselineVerified: return .inactive
    case .appliedVerified: return .active
    case .restoredVerified: return .restored
    case .applyMayHaveOccurred, .restoreMayHaveOccurred:
        return .recoveryRequired
    case .conflicted: return .conflicted
    }
}

private func canonicalPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
}

private func canonicalURL(_ url: URL) -> URL {
    URL(fileURLWithPath: canonicalPath(url))
}

private let nullObserverRunID = UUID(
    uuidString: "00000000-0000-0000-0000-000000000000"
)!
