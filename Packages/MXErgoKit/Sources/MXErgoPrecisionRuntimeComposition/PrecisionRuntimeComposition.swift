import Foundation
import MXErgoHIDPP
import MXErgoPrecisionIOHIDAcquisition
import MXErgoPrecisionRuntimeJournal
import MXErgoPrecisionTransport

package enum PrecisionRuntimeCompositionPhase: Sendable, Equatable {
    case configurationValidation
    case transportConstruction
    case endpointStart
    case connectionVerification
}

/// Preserves both the primary construction failure and the direct-device
/// close result produced by mandatory rollback.
package struct PrecisionRuntimeCompositionFailure: Error, @unchecked Sendable {
    package let phase: PrecisionRuntimeCompositionPhase
    package let underlying: any Error
    package let deviceCloseReturn: Int32?
}

package enum PrecisionRuntimeOperationError: Error, Sendable, Equatable {
    case operationAlreadyInProgress
    case shuttingDown
    case permanentlyStopped
    case deviceDisconnected
}

package enum PrecisionRuntimeConfigurationError: Error, Sendable, Equatable {
    case invalidDurableSnapshot
    case operationLeaseMismatch
}

package enum PrecisionRuntimeShutdownDisposition: Sendable, Equatable {
    case clean(PrecisionTemporaryDiversionLifecycleState)
    case recoveryRequired(PrecisionTemporaryDiversionLifecycleState)
    case stateUnavailable(String)
}

package struct PrecisionRuntimeShutdownReport: Sendable, Equatable {
    package let disposition: PrecisionRuntimeShutdownDisposition
    package let deviceCloseReturn: Int32?

    package init(
        disposition: PrecisionRuntimeShutdownDisposition,
        deviceCloseReturn: Int32?
    ) {
        self.disposition = disposition
        self.deviceCloseReturn = deviceCloseReturn
    }
}

/// All dynamic inputs required to bind the transport to the exact validated
/// device/session generation and the exact durable journal generation.
package struct PrecisionRuntimeCompositionConfiguration: Sendable {
    package typealias CompetitorProbe = @Sendable () throws -> [String]

    package let automaticPermit: PrecisionAutomaticRunPermit?
    package let journalContext: PrecisionRuntimeJournalContext
    package let operationLease: MXErgoDeviceOperationLease
    package let sessionProvider: PrecisionTransportFactory.SessionProvider
    package let rootGenerationProvider:
        PrecisionTransportFactory.RootGenerationProvider
    package let competitorProbe: CompetitorProbe
    package let operationTimeoutNanoseconds: UInt64
    package let unsolicitedHIDPPHandler: (@Sendable ([UInt8]) -> Void)?
    package let deviceDisconnectHandler: (@Sendable () -> Void)?

    package var plan: PrecisionTemporaryDiversionPlan {
        journalContext.plan
    }

    package var binding: PrecisionTransportBinding {
        PrecisionTransportBinding(
            session: journalContext.session,
            rootGeneration: journalContext.rootGeneration
        )
    }

    package init(
        journalContext: PrecisionRuntimeJournalContext,
        operationLease: MXErgoDeviceOperationLease,
        sessionProvider: @escaping PrecisionTransportFactory.SessionProvider,
        rootGenerationProvider: @escaping
            PrecisionTransportFactory.RootGenerationProvider,
        competitorProbe: @escaping CompetitorProbe,
        operationTimeoutNanoseconds: UInt64 = 5_000_000_000,
        unsolicitedHIDPPHandler: (@Sendable ([UInt8]) -> Void)? = nil,
        deviceDisconnectHandler: (@Sendable () -> Void)? = nil,
        automaticPermit: PrecisionAutomaticRunPermit? = nil
    ) {
        self.journalContext = journalContext
        self.automaticPermit = automaticPermit
        self.operationLease = operationLease
        self.sessionProvider = sessionProvider
        self.rootGenerationProvider = rootGenerationProvider
        self.competitorProbe = competitorProbe
        self.operationTimeoutNanoseconds = operationTimeoutNanoseconds
        self.unsolicitedHIDPPHandler = unsolicitedHIDPPHandler
        self.deviceDisconnectHandler = deviceDisconnectHandler
    }
}

/// Runtime-local operation guard for an admission supervisor that already
/// owns the canonical lease. Keeping this implementation in the productless
/// composition target prevents it from entering the menu-app binary.
private final class PrecisionTemporaryDiversionPreacquiredSafetyGate:
    PrecisionTemporaryDiversionSafetyGate,
    @unchecked Sendable {
    typealias CompetitorProbe = @Sendable () throws -> [String]

    private weak var deviceLease: MXErgoDeviceOperationLease?
    private let journalURL: URL
    private let competitorProbe: CompetitorProbe

    init(
        deviceLease: MXErgoDeviceOperationLease,
        journalURL: URL,
        competitorProbe: @escaping CompetitorProbe
    ) {
        self.deviceLease = deviceLease
        self.journalURL = journalURL
        self.competitorProbe = competitorProbe
    }

    func acquire(
        for operation: PrecisionTemporaryDiversionOperation
    ) async throws -> any PrecisionTemporaryDiversionSafetyLease {
        _ = operation
        return try acquireValidatedLease()
    }

    func acquireForRuntimeStart()
        throws -> any PrecisionTemporaryDiversionSafetyLease {
        try acquireValidatedLease()
    }

    private func acquireValidatedLease()
        throws -> any PrecisionTemporaryDiversionSafetyLease {
        try Self.requireNoCompetitors(competitorProbe)
        guard let deviceLease,
              deviceLease.protects(journalURL: journalURL) else {
            throw PrecisionTemporaryDiversionSafetyGateError
                .deviceOperationLeaseUnavailable
        }
        let lease = PrecisionTemporaryDiversionPreacquiredSafetyLease(
            deviceLease: deviceLease,
            journalURL: journalURL,
            competitorProbe: competitorProbe
        )
        try lease.validate()
        return lease
    }

    fileprivate static func requireNoCompetitors(
        _ probe: CompetitorProbe
    ) throws {
        let names = try probe()
            .filter {
                !$0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            }
            .sorted()
        guard names.isEmpty else {
            throw PrecisionTemporaryDiversionSafetyGateError
                .competingProcesses(names)
        }
    }
}

private final class PrecisionTemporaryDiversionPreacquiredSafetyLease:
    PrecisionTemporaryDiversionSafetyLease,
    @unchecked Sendable {
    private let deviceLease: MXErgoDeviceOperationLease
    private let journalURL: URL
    private let competitorProbe:
        PrecisionTemporaryDiversionPreacquiredSafetyGate.CompetitorProbe

    init(
        deviceLease: MXErgoDeviceOperationLease,
        journalURL: URL,
        competitorProbe: @escaping
            PrecisionTemporaryDiversionPreacquiredSafetyGate.CompetitorProbe
    ) {
        self.deviceLease = deviceLease
        self.journalURL = journalURL
        self.competitorProbe = competitorProbe
    }

    func validate() throws {
        guard deviceLease.protects(journalURL: journalURL) else {
            throw PrecisionTemporaryDiversionSafetyGateError
                .deviceOperationLeaseUnavailable
        }
        try PrecisionTemporaryDiversionPreacquiredSafetyGate
            .requireNoCompetitors(competitorProbe)
    }
}

package enum PrecisionRuntimeCompositionFactory {
    typealias Acquire = @Sendable (
        PrecisionTemporaryDiversionPlan,
        PrecisionTransportBinding,
        MXErgoDeviceOperationLease
    ) throws -> any PrecisionIOHIDAcquiredEndpoint

    typealias MakeTransport = @Sendable (
        PrecisionRuntimeCompositionConfiguration,
        any PrecisionIOHIDAcquiredEndpoint
    ) throws -> any PrecisionTransportSession

    /// A façade is returned only after acquisition, complete graph assembly,
    /// and input activation have all succeeded. Every post-acquisition failure
    /// disconnects any transport and drains/quiesces/closes the endpoint.
    package static func make(
        configuration: PrecisionRuntimeCompositionConfiguration
    ) async throws -> PrecisionRuntimeComposition {
        try await make(
            configuration: configuration,
            verifyConnection: { configuration, endpoint in
                _ = try await PrecisionConnectionVerificationDriver.verify(
                    endpoint: endpoint, binding: configuration.binding,
                    competitorProbe: configuration.competitorProbe,
                    requestTimeoutNanoseconds: min(configuration.operationTimeoutNanoseconds, 5_000_000_000)
                )
            },
            acquire: { plan, binding, operationLease in
                try PrecisionIOHIDAcquisitionFactory.make(
                    plan: plan,
                    binding: binding,
                    operationLease: operationLease
                )
            },
            makeTransport: { configuration, endpoint in
                let source = configuration.journalContext.source
                return try PrecisionTransportFactory.make(
                    plan: configuration.plan,
                    binding: configuration.binding,
                    writer: endpoint,
                    reader: endpoint,
                    sessionProvider: {
                        try await validatedEndpointEvidence(
                            endpoint: endpoint, provider: configuration.sessionProvider
                        )
                    },
                    rootGenerationProvider: {
                        try await validatedEndpointEvidence(
                            endpoint: endpoint, provider: configuration.rootGenerationProvider
                        )
                    },
                    competitorProbe: {
                        try configuration.competitorProbe()
                    },
                    durableSnapshotLoader: {
                        let snapshot = try await source.loadValidatedSnapshot()
                        return PrecisionTransportDurableSnapshot(
                            envelope: snapshot.envelope,
                            sha256: snapshot.sha256
                        )
                    },
                    connectionValidator: { try endpoint.validateActiveConnection() },
                    operationTimeoutNanoseconds:
                        configuration.operationTimeoutNanoseconds,
                    automaticPermit: configuration.automaticPermit
                )
            }
        )
    }

    /// External values remain authorized binding context. Liveness comes from
    /// the acquired input endpoint, checked on both sides of each suspension.
    static func validatedEndpointEvidence<Value: Sendable>(
        endpoint: any PrecisionIOHIDAcquiredEndpoint,
        provider: @Sendable () async throws -> Value
    ) async throws -> Value {
        try endpoint.validateActiveConnection()
        let value = try await provider()
        try endpoint.validateActiveConnection()
        return value
    }

    static func make(
        configuration: PrecisionRuntimeCompositionConfiguration,
        verifyConnection: @Sendable (PrecisionRuntimeCompositionConfiguration, any PrecisionIOHIDAcquiredEndpoint) async throws -> Void,
        acquire: Acquire,
        makeTransport: MakeTransport
    ) async throws -> PrecisionRuntimeComposition {
        let safetyGate = PrecisionTemporaryDiversionPreacquiredSafetyGate(
            deviceLease: configuration.operationLease,
            journalURL: configuration.journalContext.source.journalURL,
            competitorProbe: configuration.competitorProbe
        )
        let startupSafetyLease: any PrecisionTemporaryDiversionSafetyLease
        do {
            guard configuration.operationLease.protects(
                journalURL: configuration.journalContext.source.journalURL
            ) else {
                throw PrecisionRuntimeConfigurationError.operationLeaseMismatch
            }
            try PrecisionIOHIDAcquisitionFactory.validate(
                plan: configuration.plan,
                binding: configuration.binding
            )
            let snapshot = try await configuration.journalContext.source
                .loadValidatedSnapshot()
            try validate(snapshot: snapshot, configuration: configuration)
            startupSafetyLease = try safetyGate.acquireForRuntimeStart()
            try startupSafetyLease.validate()
        } catch {
            throw PrecisionRuntimeCompositionFailure(
                phase: .configurationValidation,
                underlying: error,
                deviceCloseReturn: nil
            )
        }
        let endpoint = try acquire(
            configuration.plan,
            configuration.binding,
            configuration.operationLease
        )
        do {
            try Task.checkCancellation()
            try await endpoint.start()
        } catch {
            await endpoint.shutdownAndDrain()
            throw PrecisionRuntimeCompositionFailure(
                phase: .endpointStart, underlying: error,
                deviceCloseReturn: endpoint.deviceCloseReturn
            )
        }
        do {
            try await verifyConnection(configuration, endpoint)
            try Task.checkCancellation()
            try endpoint.validateActiveConnection()
            try startupSafetyLease.validate()
        } catch {
            endpoint.disconnected()
            await endpoint.shutdownAndDrain()
            throw PrecisionRuntimeCompositionFailure(
                phase: .connectionVerification, underlying: error,
                deviceCloseReturn: endpoint.deviceCloseReturn
            )
        }
        let transport: any PrecisionTransportSession
        do {
            try Task.checkCancellation()
            transport = try makeTransport(configuration, endpoint)
        } catch {
            await endpoint.shutdownAndDrain()
            throw PrecisionRuntimeCompositionFailure(
                phase: .transportConstruction,
                underlying: error,
                deviceCloseReturn: endpoint.deviceCloseReturn
            )
        }

        let coordinator = DeviceTransactionCoordinator(
            repository: configuration.journalContext.source,
            transport: transport
        )
        let lifecycle = PrecisionTemporaryDiversionLifecycle(
            coordinator: coordinator,
            plan: configuration.plan,
            safetyGate: safetyGate
        )
        do {
            try Task.checkCancellation()
            if let handler = configuration.unsolicitedHIDPPHandler {
                endpoint.setUnsolicitedHIDPPHandler { frame in
                    handler(frame.bytes)
                }
            }
            try Task.checkCancellation()
            try startupSafetyLease.validate()
        } catch {
            await transport.disconnected()
            await endpoint.shutdownAndDrain()
            throw PrecisionRuntimeCompositionFailure(
                phase: .endpointStart,
                underlying: error,
                deviceCloseReturn: endpoint.deviceCloseReturn
            )
        }
        let composition = PrecisionRuntimeComposition(
            endpoint: endpoint,
            transport: transport,
            lifecycle: lifecycle,
            operationLease: configuration.operationLease,
            pointerInspectionBinding: configuration.binding,
            pointerInspectionProbe: configuration.competitorProbe
        )
        endpoint.setDisconnectHandler {
            configuration.deviceDisconnectHandler?()
            Task { await composition.noteDeviceDisconnected() }
        }
        return composition
    }

    private static func validate(
        snapshot: PrecisionRuntimeJournalSnapshot,
        configuration: PrecisionRuntimeCompositionConfiguration
    ) throws {
        try snapshot.envelope.validate()
        let sha256Bytes = snapshot.sha256.utf8
        guard sha256Bytes.count == 64,
              sha256Bytes.allSatisfy({ byte in
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                      || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
              }),
              snapshot == configuration.journalContext.snapshot,
              snapshot.envelope.isSafeSessionMatch(
                configuration.binding.session
              ),
              snapshot.envelope.device == configuration.plan.device,
              snapshot.envelope.featureVersion
                == configuration.plan.featureVersion,
              snapshot.envelope.featureIndex
                == configuration.plan.featureIndex,
              try snapshot.envelope.control(
                PrecisionTemporaryDiversionPlan.controlID
              ).baseline == configuration.plan.baseline else {
            throw PrecisionRuntimeConfigurationError.invalidDurableSnapshot
        }
    }
}

extension PrecisionRuntimeControlling {
    /// Diagnostics are evidence, not a capability. A runtime that cannot
    /// produce them is valid; it simply reports nothing.
    package func inputDiagnostics() async -> PrecisionInputDiagnostics? { nil }
    package func inspectPointerScaling() async throws -> PrecisionPointerScalingObservation {
        throw PrecisionPointerInspectionError.unavailable
    }
}

package protocol PrecisionRuntimeControlling: AnyObject, Sendable {
    func lifecycleState() async throws -> PrecisionTemporaryDiversionLifecycleState
    func activate() async throws -> DeviceTransactionEnvelope
    func resumeVerified() async throws -> DeviceTransactionEnvelope
    func deactivate() async throws -> DeviceTransactionEnvelope
    func recoverExplicitly() async throws -> DeviceTransactionRecoveryReport
    func shutdown() async -> PrecisionRuntimeShutdownReport
    /// Read-only evidence about the input path. Never gates an operation.
    func inputDiagnostics() async -> PrecisionInputDiagnostics?
    func inspectPointerScaling() async throws -> PrecisionPointerScalingObservation
}

/// Productless, package-only owner of the complete precision runtime graph.
/// No acquired endpoint, transport, coordinator, or lifecycle reference can
/// escape independently. Shutdown closes admission, disconnects transport,
/// waits for an in-flight coordinator operation to settle its persistence,
/// classifies durable state, and only then drains/quiesces/closes the device.
package actor PrecisionRuntimeComposition: PrecisionRuntimeControlling {
    private enum State {
        case running
        case shuttingDown
        case stopped(PrecisionRuntimeShutdownReport)
    }

    private let endpoint: any PrecisionIOHIDAcquiredEndpoint
    private let transport: any PrecisionTransportSession
    private let lifecycle: PrecisionTemporaryDiversionLifecycle
    private var retainedOperationLease: MXErgoDeviceOperationLease?
    private var state: State = .running
    private var activeOperationToken: UUID?
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters:
        [CheckedContinuation<PrecisionRuntimeShutdownReport, Never>] = []
    private var deviceDisconnected = false
    private let pointerInspectionBinding: PrecisionTransportBinding?
    private let pointerInspectionProbe: @Sendable () throws -> [String]
    private var pointerInspectionAttempted = false

    init(
        endpoint: any PrecisionIOHIDAcquiredEndpoint,
        transport: any PrecisionTransportSession,
        lifecycle: PrecisionTemporaryDiversionLifecycle,
        operationLease: MXErgoDeviceOperationLease,
        pointerInspectionBinding: PrecisionTransportBinding? = nil,
        pointerInspectionProbe: @escaping @Sendable () throws -> [String] = { throw PrecisionPointerInspectionError.unavailable }
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.lifecycle = lifecycle
        retainedOperationLease = operationLease
        self.pointerInspectionBinding = pointerInspectionBinding
        self.pointerInspectionProbe = pointerInspectionProbe
    }

    package func inspectPointerScaling() async throws -> PrecisionPointerScalingObservation {
        let token = try beginOperation()
        guard !pointerInspectionAttempted, let binding = pointerInspectionBinding,
              retainedOperationLease != nil else {
            endOperation(token)
            throw PrecisionPointerInspectionError.alreadyAttempted
        }
        pointerInspectionAttempted = true
        do {
            let observation = try await PrecisionConnectionVerificationDriver.inspectPointerScaling(
                endpoint: endpoint, binding: binding, competitorProbe: pointerInspectionProbe)
            // Shutdown/removal during an awaited read cannot publish a result.
            guard case .running = state, !deviceDisconnected else {
                throw PrecisionPointerInspectionError.unavailable
            }
            endOperation(token)
            return observation
        } catch {
            endOperation(token)
            _ = await shutdown()
            throw error
        }
    }

    package func lifecycleState()
        async throws -> PrecisionTemporaryDiversionLifecycleState {
        let token = try beginOperation()
        defer { endOperation(token) }
        return try await lifecycle.state()
    }

    package func activate() async throws -> DeviceTransactionEnvelope {
        let token = try beginOperation()
        defer { endOperation(token) }
        return try await lifecycle.activate()
    }

    package func resumeVerified() async throws -> DeviceTransactionEnvelope {
        let token = try beginOperation()
        defer { endOperation(token) }
        return try await lifecycle.resumeVerified()
    }

    package func deactivate() async throws -> DeviceTransactionEnvelope {
        let token = try beginOperation()
        defer { endOperation(token) }
        return try await lifecycle.deactivate()
    }

    package func recoverExplicitly()
        async throws -> DeviceTransactionRecoveryReport {
        let token = try beginOperation()
        defer { endOperation(token) }
        return try await lifecycle.recoverExplicitly()
    }

    /// Records a physical disconnect without sending SET, retry, or restore.
    /// In-flight transport waits are woken; durable classification happens on
    /// the existing ordered shutdown path.
    package func noteDeviceDisconnected() async {
        deviceDisconnected = true
        endpoint.setUnsolicitedHIDPPHandler(nil)
        await transport.disconnected()
    }

    package func inputDiagnostics() -> PrecisionInputDiagnostics? {
        endpoint.inputDiagnostics()
    }

    package func shutdown() async -> PrecisionRuntimeShutdownReport {
        switch state {
        case let .stopped(report):
            return report
        case .shuttingDown:
            return await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
        case .running:
            state = .shuttingDown
        }

        await transport.disconnected()
        await waitForActiveOperation()
        let disposition = await shutdownDisposition()
        await endpoint.shutdownAndDrain()
        retainedOperationLease = nil
        let report = PrecisionRuntimeShutdownReport(
            disposition: disposition,
            deviceCloseReturn: endpoint.deviceCloseReturn
        )
        state = .stopped(report)
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: report) }
        return report
    }

    private func beginOperation() throws -> UUID {
        switch state {
        case .shuttingDown:
            throw PrecisionRuntimeOperationError.shuttingDown
        case .stopped:
            throw PrecisionRuntimeOperationError.permanentlyStopped
        case .running:
            break
        }
        if deviceDisconnected {
            throw PrecisionRuntimeOperationError.deviceDisconnected
        }
        guard activeOperationToken == nil else {
            throw PrecisionRuntimeOperationError.operationAlreadyInProgress
        }
        let token = UUID()
        activeOperationToken = token
        return token
    }

    private func endOperation(_ token: UUID) {
        guard activeOperationToken == token else { return }
        activeOperationToken = nil
        let waiters = operationWaiters
        operationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForActiveOperation() async {
        guard activeOperationToken != nil else { return }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func shutdownDisposition() async -> PrecisionRuntimeShutdownDisposition {
        do {
            let lifecycleState = try await lifecycle.state()
            switch lifecycleState {
            case .inactive, .restored:
                return .clean(lifecycleState)
            case .active, .recoveryRequired, .conflicted:
                return .recoveryRequired(lifecycleState)
            }
        } catch {
            return .stateUnavailable(String(describing: error))
        }
    }
}
