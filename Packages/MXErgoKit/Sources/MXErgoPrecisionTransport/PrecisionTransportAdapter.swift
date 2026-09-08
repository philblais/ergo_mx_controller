import Foundation
import MXErgoHIDPP

package enum PrecisionTransportReportType: Sendable, Equatable {
    case input
    case output
}

package struct PrecisionTransportOutputFrame: Sendable, Equatable {
    package let requestID: UUID
    package let reportType: PrecisionTransportReportType
    package let reportID: UInt8
    package let bytes: [UInt8]
    package let device: JournalDeviceIdentity
    package let connectionEpoch: UInt64
    package let rootGeneration: UInt64
    package let connectionVerification: PrecisionConnectionVerificationRequest?

    package init(requestID: UUID, reportType: PrecisionTransportReportType,
                 reportID: UInt8, bytes: [UInt8], device: JournalDeviceIdentity,
                 connectionEpoch: UInt64, rootGeneration: UInt64,
                 connectionVerification: PrecisionConnectionVerificationRequest? = nil) {
        self.requestID = requestID
        self.reportType = reportType
        self.reportID = reportID
        self.bytes = bytes
        self.device = device
        self.connectionEpoch = connectionEpoch
        self.rootGeneration = rootGeneration
        self.connectionVerification = connectionVerification
    }
}

package struct PrecisionTransportInputFrame: Sendable, Equatable {
    package let reportType: PrecisionTransportReportType
    package let reportID: UInt8
    package let bytes: [UInt8]
    package let device: JournalDeviceIdentity
    package let connectionEpoch: UInt64
    package let rootGeneration: UInt64
}

package protocol PrecisionTransportReportWriter: Sendable {
    /// Zero models a successful entry into the report-writing seam. Every
    /// throw or nonzero result after this method is called is outcome-unknown.
    func write(_ frame: PrecisionTransportOutputFrame) async throws -> Int32
    /// Must be bounded, idempotent, token-specific, and sticky when it wins
    /// before `write` enters the implementation. If it wins after entry, the
    /// matching `write` must still resolve promptly; that logical completion
    /// does not prove the underlying operation is quiescent. Concrete writers
    /// must expose and honor a separate drain lifecycle before resource release.
    func cancelPendingWrite(
        requestID: UUID,
        reason: PrecisionTransportReportIOError
    )
}

package protocol PrecisionTransportReportReader: Sendable {
    /// Samples endpoint-owned lifecycle state without I/O. This attests active
    /// input ownership only, not Root/firmware identity or reconnect continuity.
    func validateActiveConnection() throws
    /// Arms a single request window before the matching writer is entered.
    func beginRequest(_ frame: PrecisionTransportOutputFrame) throws
    func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame
    func endRequest(_ requestID: UUID)
    /// Must be bounded, idempotent, token-specific, and sticky.
    func cancelRequest(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError
    )
    func disconnected()
}

extension PrecisionTransportReportReader {
    /// Readers without an explicit liveness implementation cannot attest it.
    package func validateActiveConnection() throws {
        throw PrecisionTransportReportIOError.disconnected
    }
}

package struct PrecisionTransportDurableSnapshot: Sendable, Equatable {
    package let envelope: DeviceTransactionEnvelope
    package let sha256: String

    package init(envelope: DeviceTransactionEnvelope, sha256: String) {
        self.envelope = envelope
        self.sha256 = sha256
    }
}

package struct PrecisionTransportBinding: Sendable, Equatable {
    package let session: DeviceTransactionSession
    package let rootGeneration: UInt64

    package init(session: DeviceTransactionSession, rootGeneration: UInt64) {
        self.session = session
        self.rootGeneration = rootGeneration
    }
}

package enum PrecisionTransportReportIOError: Error, Sendable, Equatable {
    case timeout
    case disconnected
    case cancelled
    case overflow
}

enum PrecisionTransportError: Error, Sendable, Equatable {
    case invalidPlanBinding
    case invalidSession
    case staleRootGeneration
    case competingProcesses([String])
    case invalidMutation
    case invalidPreparation
    case preparationAlreadyPending
    case attemptAlreadyConsumed(UUID)
    case invalidAuthorization
    case singleFlightViolation
    case writerFailed(Int32)
    case malformedInput
    case inputOverflow
    case protocolError(UInt8)
    case timeout
    case disconnected
    case cancelled
    case poisoned
}

/// Opaque lifecycle capability used by the productless runtime owner. The
/// concrete adapter never escapes that owner.
package protocol PrecisionTransportSession: DeviceTransactionEffectTransport {
    func disconnected() async
}

package enum PrecisionTransportFactory {
    package typealias SessionProvider =
        @Sendable () async throws -> DeviceTransactionSession
    package typealias RootGenerationProvider =
        @Sendable () async throws -> UInt64
    package typealias CompetitorProbe =
        @Sendable () async throws -> [String]
    package typealias DurableSnapshotLoader =
        @Sendable () async throws -> PrecisionTransportDurableSnapshot

    package static func make(
        plan: PrecisionTemporaryDiversionPlan,
        binding: PrecisionTransportBinding,
        writer: any PrecisionTransportReportWriter,
        reader: any PrecisionTransportReportReader,
        sessionProvider: @escaping SessionProvider,
        rootGenerationProvider: @escaping RootGenerationProvider,
        competitorProbe: @escaping CompetitorProbe,
        durableSnapshotLoader: @escaping DurableSnapshotLoader,
        connectionValidator: @escaping @Sendable () throws -> Void,
        operationTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) throws -> any PrecisionTransportSession {
        try PrecisionTransportAdapter(
            plan: plan,
            binding: binding,
            writer: writer,
            reader: reader,
            sessionProvider: sessionProvider,
            rootGenerationProvider: rootGenerationProvider,
            competitorProbe: competitorProbe,
            durableSnapshotLoader: durableSnapshotLoader,
            connectionValidator: connectionValidator,
            operationTimeoutNanoseconds: operationTimeoutNanoseconds
        )
    }
}

/// Dormant, unexported transport boundary with injected report I/O.
///
/// This target has no package product or application/helper dependency. It
/// imports no IOKit API and can reach output only through an injected writer.
/// SET acknowledgement is retained as evidence; a separate reporting GET is
/// the only source of authoritative state.
actor PrecisionTransportAdapter: PrecisionTransportSession {
    typealias SessionProvider = @Sendable () async throws -> DeviceTransactionSession
    typealias RootGenerationProvider = @Sendable () async throws -> UInt64
    typealias CompetitorProbe = @Sendable () async throws -> [String]
    typealias DurableSnapshotLoader = @Sendable () async throws -> PrecisionTransportDurableSnapshot

    private enum PendingKind: Sendable, Equatable {
        case set(DeviceTransactionMutationKind)
        case get
    }

    private enum State: Sendable, Equatable {
        case idle
        case preparing(UUID)
        case prepared(DeviceTransactionPreparedInvocation)
        case opening(requestID: UUID, kind: PendingKind)
        case pending(requestID: UUID, kind: PendingKind)
        case awaitingVerification(attemptID: UUID, kind: DeviceTransactionMutationKind)
        case poisoned

        var requestID: UUID? {
            switch self {
            case let .opening(requestID, _), let .pending(requestID, _):
                return requestID
            default:
                return nil
            }
        }
    }

    private enum StateToken: Sendable, Equatable {
        case preparing(UUID)
        case opening(UUID)
        case pending(UUID)
    }

    private let plan: PrecisionTemporaryDiversionPlan
    private let binding: PrecisionTransportBinding
    private let writer: any PrecisionTransportReportWriter
    private let reader: any PrecisionTransportReportReader
    private let sessionProvider: SessionProvider
    private let rootGenerationProvider: RootGenerationProvider
    private let competitorProbe: CompetitorProbe
    private let durableSnapshotLoader: DurableSnapshotLoader
    private let connectionValidator: @Sendable () throws -> Void
    private let operationTimeoutNanoseconds: UInt64
    private var correlator: HIDPP20RequestCorrelator
    private var state: State = .idle
    private var consumedAttemptIDs: Set<UUID> = []

    init(
        plan: PrecisionTemporaryDiversionPlan,
        binding: PrecisionTransportBinding,
        writer: any PrecisionTransportReportWriter,
        reader: any PrecisionTransportReportReader,
        sessionProvider: @escaping SessionProvider,
        rootGenerationProvider: @escaping RootGenerationProvider,
        competitorProbe: @escaping CompetitorProbe,
        durableSnapshotLoader: @escaping DurableSnapshotLoader,
        connectionValidator: @escaping @Sendable () throws -> Void = {},
        operationTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) throws {
        guard plan.device == binding.session.device,
              binding.session.featureID == ReprogControlsV4.featureID,
              binding.session.featureVersion == 3,
              binding.session.featureIndex == plan.featureIndex,
              plan.featureVersion == 3,
              try Self.hasExactAllowlist(plan) else {
            throw PrecisionTransportError.invalidPlanBinding
        }
        self.plan = plan
        self.binding = binding
        self.writer = writer
        self.reader = reader
        self.sessionProvider = sessionProvider
        self.rootGenerationProvider = rootGenerationProvider
        self.competitorProbe = competitorProbe
        self.durableSnapshotLoader = durableSnapshotLoader
        self.connectionValidator = connectionValidator
        self.operationTimeoutNanoseconds = operationTimeoutNanoseconds
        correlator = HIDPP20RequestCorrelator(
            connectionEpoch: binding.session.connectionEpoch
        )
    }

    func currentSession() async throws -> DeviceTransactionSession {
        try Task.checkCancellation()
        try requireNotPoisoned()
        try await validateEnvironment(expectedSession: binding.session)
        try requireNotPoisoned()
        return binding.session
    }

    func prepare(
        _ proposed: DeviceTransactionMutation,
        expectedSession: DeviceTransactionSession,
        expectedCommittedRevision: UInt64
    ) async throws -> DeviceTransactionPreparedInvocation {
        try Task.checkCancellation()
        guard case .idle = state else {
            throw PrecisionTransportError.preparationAlreadyPending
        }
        guard !consumedAttemptIDs.contains(proposed.attemptID) else {
            throw PrecisionTransportError.attemptAlreadyConsumed(proposed.attemptID)
        }
        let preparationToken = UUID()
        state = .preparing(preparationToken)
        do {
            try await validateEnvironment(
                expectedSession: expectedSession,
                stateToken: .preparing(preparationToken)
            )
            _ = try exactSetRequest(for: proposed)
            try requireStateToken(.preparing(preparationToken))

            let durable = try await durableSnapshotLoader()
            try requireStateToken(.preparing(preparationToken))
            try await validateEnvironment(
                expectedSession: expectedSession,
                stateToken: .preparing(preparationToken)
            )
            guard durable.envelope.transactionID == proposed.transactionID,
                  durable.envelope.revision < .max,
                  durable.envelope.revision + 1 == expectedCommittedRevision,
                  durable.envelope.isSafeSessionMatch(expectedSession) else {
                throw PrecisionTransportError.invalidPreparation
            }
            let control = try durable.envelope.control(proposed.controlID)
            switch proposed.kind {
            case .apply:
                guard control.phase == .baselineVerified,
                      control.activeAttemptID == nil,
                      control.intended == nil,
                      proposed.state == plan.activeState else {
                    throw PrecisionTransportError.invalidPreparation
                }
            case .restore:
                guard control.phase == .appliedVerified,
                      control.activeAttemptID == nil,
                      control.intended == plan.activeState,
                      control.appliedObservation == plan.activeState,
                      proposed.state == plan.baseline else {
                    throw PrecisionTransportError.invalidPreparation
                }
            }

            let prepared = DeviceTransactionPreparedInvocation(
                mutation: proposed,
                expectedSession: expectedSession,
                expectedCommittedRevision: expectedCommittedRevision
            )
            try requireStateToken(.preparing(preparationToken))
            state = .prepared(prepared)
            return prepared
        } catch {
            if case .preparing(preparationToken) = state { state = .idle }
            if case .poisoned = state { throw PrecisionTransportError.poisoned }
            throw error
        }
    }

    func abandon(
        _ prepared: DeviceTransactionPreparedInvocation,
        disposition: DeviceTransactionPreparationDisposition
    ) async {
        guard case let .prepared(stored) = state, stored == prepared else {
            consumedAttemptIDs.insert(prepared.mutation.attemptID)
            state = .poisoned
            return
        }
        switch disposition {
        case .discardedBeforeWriteAhead:
            state = .idle
        case .invalidPreparation, .writeAheadVisibilityUnknown:
            consumedAttemptIDs.insert(prepared.mutation.attemptID)
            state = .poisoned
        }
    }

    func invoke(
        _ prepared: DeviceTransactionPreparedInvocation,
        authorization: DeviceTransactionDurableCommitReceipt
    ) async throws -> DeviceTransactionInvocationEvidence? {
        guard case let .prepared(stored) = state, stored == prepared else {
            consumedAttemptIDs.insert(prepared.mutation.attemptID)
            state = .poisoned
            throw DeviceTransactionTransportInvocationError.outcomeUnknown(
                String(describing: PrecisionTransportError.invalidPreparation)
            )
        }
        let mutation = prepared.mutation
        guard consumedAttemptIDs.insert(mutation.attemptID).inserted else {
            state = .poisoned
            throw DeviceTransactionTransportInvocationError.outcomeUnknown(
                String(describing:
                    PrecisionTransportError.attemptAlreadyConsumed(mutation.attemptID))
            )
        }

        do {
            try Task.checkCancellation()
            try await validateEnvironment(expectedSession: prepared.expectedSession)
            try requirePrepared(prepared)
            let request = try exactSetRequest(for: mutation)
            let durable = try await durableSnapshotLoader()
            try requirePrepared(prepared)
            try await validateEnvironment(expectedSession: prepared.expectedSession)
            try requirePrepared(prepared)
            try validateAuthorization(
                durable,
                prepared: prepared,
                authorization: authorization
            )
            let evidence = try await performSetRoundTrip(
                request: request,
                mutation: mutation,
                expectedSession: prepared.expectedSession
            )
            return evidence
        } catch let error as DeviceTransactionTransportInvocationError {
            state = .poisoned
            throw error
        } catch {
            state = .poisoned
            throw DeviceTransactionTransportInvocationError.outcomeUnknown(
                String(describing: error)
            )
        }
    }

    func readReporting(
        controlID: UInt16,
        expectedSession: DeviceTransactionSession
    ) async throws -> DeviceTransactionWireState {
        try Task.checkCancellation()
        switch state {
        case .idle, .awaitingVerification:
            break
        default:
            if case .poisoned = state {
                throw PrecisionTransportError.poisoned
            }
            throw PrecisionTransportError.singleFlightViolation
        }
        guard controlID == PrecisionTemporaryDiversionPlan.controlID else {
            throw PrecisionTransportError.invalidMutation
        }
        let requestID = UUID()
        state = .opening(requestID: requestID, kind: .get)
        do {
            try await validateEnvironment(
                expectedSession: expectedSession,
                stateToken: .opening(requestID)
            )
            let request = plan.verificationRequest
            let expectedGet = try Self.exactGetRequest(
                featureIndex: binding.session.featureIndex
            )
            guard request.bytes == expectedGet.bytes else {
                throw PrecisionTransportError.invalidPlanBinding
            }
            try correlator.register(
                request,
                connectionEpoch: expectedSession.connectionEpoch,
                id: requestID
            )
            let output = outputFrame(requestID: requestID, request: request)
            try reader.beginRequest(output)
            try requireStateToken(.opening(requestID))
            state = .pending(requestID: requestID, kind: .get)
            let ioReturn = try await writeWithDeadline(output)
            try requirePending(requestID, kind: .get)
            guard ioReturn == 0 else {
                throw PrecisionTransportError.writerFailed(ioReturn)
            }
            try Task.checkCancellation()
            try await validateEnvironment(
                expectedSession: expectedSession,
                stateToken: .pending(requestID)
            )
            let reply = try await matchingReply(
                requestID: requestID,
                kind: .get,
                expectedSession: expectedSession
            )
            switch reply {
            case let .protocolError(_, error):
                throw PrecisionTransportError.protocolError(error.rawErrorCode)
            case let .response(id, response):
                guard id == requestID else {
                    throw PrecisionTransportError.malformedInput
                }
                let reporting = try ReprogControlsV4.decodeReporting(
                    requestedControlID: controlID,
                    from: response,
                    featureIndex: binding.session.featureIndex,
                    featureVersion: binding.session.featureVersion
                )
                let result = try DeviceTransactionWireState(
                    rawParameters: reporting.rawParameters
                )
                reader.endRequest(requestID)
                state = .idle
                return result
            }
        } catch {
            poisonRequest(
                requestID,
                expectedSession: expectedSession,
                cause: error
            )
            throw Self.classifyReadError(error)
        }
    }

    func disconnected() async {
        let activeRequestID = state.requestID
        correlator.disconnected()
        state = .poisoned
        let writer = self.writer
        let reader = self.reader
        await withTaskGroup(of: Void.self) { group in
            if let activeRequestID {
                group.addTask {
                    writer.cancelPendingWrite(
                        requestID: activeRequestID,
                        reason: .disconnected
                    )
                }
            }
            group.addTask {
                if let activeRequestID {
                    reader.cancelRequest(activeRequestID, reason: .disconnected)
                }
                reader.disconnected()
            }
        }
    }

    var isPoisoned: Bool {
        if case .poisoned = state { return true }
        return false
    }

    private func performSetRoundTrip(
        request: HIDPP20LongMessage,
        mutation: DeviceTransactionMutation,
        expectedSession: DeviceTransactionSession
    ) async throws -> DeviceTransactionInvocationEvidence {
        let requestID = UUID()
        state = .opening(requestID: requestID, kind: .set(mutation.kind))

        // Crossing this injected seam consumes the durable attempt forever.
        let ioReturn: Int32
        do {
            try await validateEnvironment(
                expectedSession: expectedSession,
                stateToken: .opening(requestID)
            )
            try correlator.register(
                request,
                connectionEpoch: expectedSession.connectionEpoch,
                id: requestID
            )
            let output = outputFrame(requestID: requestID, request: request)
            try reader.beginRequest(output)
            try requireStateToken(.opening(requestID))
            state = .pending(requestID: requestID, kind: .set(mutation.kind))
            ioReturn = try await writeWithDeadline(output)
            try requirePending(requestID, kind: .set(mutation.kind))
        } catch {
            poisonRequest(
                requestID,
                expectedSession: expectedSession,
                cause: error
            )
            throw DeviceTransactionTransportInvocationError.outcomeUnknown(
                String(describing: error)
            )
        }
        guard ioReturn == 0 else {
            poisonRequest(
                requestID,
                expectedSession: expectedSession,
                cause: PrecisionTransportError.writerFailed(ioReturn)
            )
            throw DeviceTransactionTransportInvocationError.outcomeUnknown(
                String(describing: PrecisionTransportError.writerFailed(ioReturn))
            )
        }

        do {
            try Task.checkCancellation()
            try await validateEnvironment(
                expectedSession: expectedSession,
                stateToken: .pending(requestID)
            )
            let reply = try await matchingReply(
                requestID: requestID,
                kind: .set(mutation.kind),
                expectedSession: expectedSession
            )
            let evidence: DeviceTransactionInvocationEvidence
            switch reply {
            case let .protocolError(id, error):
                guard id == requestID else {
                    throw PrecisionTransportError.malformedInput
                }
                evidence = DeviceTransactionInvocationEvidence(
                    attemptID: mutation.attemptID,
                    requestBytes: request.bytes,
                    ioReturn: ioReturn,
                    responseKind: .protocolError,
                    responseBytes: error.rawMessageBytes,
                    connectionEpoch: expectedSession.connectionEpoch
                )
            case let .response(id, response):
                guard id == requestID else {
                    throw PrecisionTransportError.malformedInput
                }
                evidence = try plan.invocationEvidence(
                    for: mutation,
                    responseBytes: response.bytes,
                    ioReturn: ioReturn,
                    connectionEpoch: expectedSession.connectionEpoch
                )
            }
            state = .awaitingVerification(
                attemptID: mutation.attemptID,
                kind: mutation.kind
            )
            reader.endRequest(requestID)
            return evidence
        } catch {
            poisonRequest(
                requestID,
                expectedSession: expectedSession,
                cause: error
            )
            throw DeviceTransactionTransportInvocationError.outcomeUnknown(
                String(describing: error)
            )
        }
    }

    private func exactSetRequest(
        for mutation: DeviceTransactionMutation
    ) throws -> HIDPP20LongMessage {
        guard mutation.controlID == PrecisionTemporaryDiversionPlan.controlID else {
            throw PrecisionTransportError.invalidMutation
        }
        let request: HIDPP20LongMessage
        do {
            request = try plan.request(for: mutation)
        } catch {
            throw PrecisionTransportError.invalidMutation
        }
        let expected: HIDPP20LongMessage
        switch mutation.kind {
        case .apply:
            expected = try Self.exactApplyRequest(
                featureIndex: binding.session.featureIndex
            )
        case .restore:
            expected = try Self.exactRestoreRequest(
                featureIndex: binding.session.featureIndex
            )
        }
        guard request.bytes == expected.bytes else {
            throw PrecisionTransportError.invalidMutation
        }
        return request
    }

    private func validateAuthorization(
        _ durable: PrecisionTransportDurableSnapshot,
        prepared: DeviceTransactionPreparedInvocation,
        authorization: DeviceTransactionDurableCommitReceipt
    ) throws {
        let mutation = prepared.mutation
        guard authorization.transactionID == mutation.transactionID,
              authorization.revision == prepared.expectedCommittedRevision,
              !authorization.sha256.isEmpty,
              authorization.sha256 == durable.sha256,
              durable.envelope.transactionID == mutation.transactionID,
              durable.envelope.revision == authorization.revision,
              durable.envelope.isSafeSessionMatch(prepared.expectedSession) else {
            throw PrecisionTransportError.invalidAuthorization
        }
        let control = try durable.envelope.control(mutation.controlID)
        let requiredPhase: DeviceTransactionControlPhase =
            mutation.kind == .apply ? .applyMayHaveOccurred : .restoreMayHaveOccurred
        guard control.phase == requiredPhase,
              control.activeAttemptID == mutation.attemptID,
              control.attempts.last?.id == mutation.attemptID,
              control.attempts.last?.outcome == .armed else {
            throw PrecisionTransportError.invalidAuthorization
        }
    }

    private func validateEnvironment(
        expectedSession: DeviceTransactionSession,
        stateToken: StateToken? = nil
    ) async throws {
        try connectionValidator()
        let current = try await sessionProvider()
        try requireStateTokenIfNeeded(stateToken)
        try connectionValidator()
        guard current == binding.session, current == expectedSession else {
            throw PrecisionTransportError.invalidSession
        }
        let rootGeneration = try await rootGenerationProvider()
        try requireStateTokenIfNeeded(stateToken)
        try connectionValidator()
        guard rootGeneration == binding.rootGeneration else {
            throw PrecisionTransportError.staleRootGeneration
        }
        let competitors = try await competitorProbe()
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted()
        try requireStateTokenIfNeeded(stateToken)
        try connectionValidator()
        guard competitors.isEmpty else {
            throw PrecisionTransportError.competingProcesses(competitors)
        }
    }

    private func validate(
        _ input: PrecisionTransportInputFrame,
        expectedSession: DeviceTransactionSession
    ) throws {
        guard input.reportType == .input,
              input.reportID == HIDPP20LongMessage.reportID,
              input.bytes.count == HIDPP20LongMessage.byteCount,
              input.bytes.first == HIDPP20LongMessage.reportID,
              input.device == expectedSession.device,
              input.connectionEpoch == expectedSession.connectionEpoch,
              input.rootGeneration == binding.rootGeneration else {
            throw PrecisionTransportError.malformedInput
        }
    }

    private func matchingReply(
        requestID: UUID,
        kind: PendingKind,
        expectedSession: DeviceTransactionSession
    ) async throws -> HIDPP20CorrelatedReply {
        let started = DispatchTime.now().uptimeNanoseconds
        while true {
            let elapsed = DispatchTime.now().uptimeNanoseconds &- started
            guard elapsed < operationTimeoutNanoseconds else {
                throw PrecisionTransportReportIOError.timeout
            }
            let input = try await readWithDeadline(
                operationTimeoutNanoseconds - elapsed,
                requestID: requestID
            )
            try requirePending(requestID, kind: kind)
            try Task.checkCancellation()
            try validate(input, expectedSession: expectedSession)
            try await validateEnvironment(
                expectedSession: expectedSession,
                stateToken: .pending(requestID)
            )
            guard let message = try? HIDPP20LongMessage(bytes: input.bytes) else {
                throw PrecisionTransportError.malformedInput
            }
            if let reply = correlator.consume(
                message,
                connectionEpoch: expectedSession.connectionEpoch
            ) {
                return reply
            }
        }
    }

    private func requirePrepared(
        _ prepared: DeviceTransactionPreparedInvocation
    ) throws {
        guard case let .prepared(stored) = state, stored == prepared else {
            if case .poisoned = state {
                throw PrecisionTransportError.poisoned
            }
            throw PrecisionTransportError.invalidPreparation
        }
    }

    private func requireNotPoisoned() throws {
        if case .poisoned = state { throw PrecisionTransportError.poisoned }
    }

    private func requireStateTokenIfNeeded(_ token: StateToken?) throws {
        guard let token else { return }
        try requireStateToken(token)
    }

    private func requireStateToken(_ token: StateToken) throws {
        let matches: Bool
        switch (token, state) {
        case let (.preparing(expected), .preparing(current)):
            matches = expected == current
        case let (.opening(expected), .opening(current, _)):
            matches = expected == current
        case let (.pending(expected), .pending(current, _)):
            matches = expected == current
        default:
            matches = false
        }
        guard matches else {
            if case .poisoned = state { throw PrecisionTransportError.poisoned }
            throw PrecisionTransportError.singleFlightViolation
        }
    }

    private func requirePending(
        _ requestID: UUID,
        kind: PendingKind
    ) throws {
        guard case let .pending(current, currentKind) = state,
              current == requestID,
              currentKind == kind else {
            if case .poisoned = state {
                throw PrecisionTransportError.poisoned
            }
            throw PrecisionTransportError.singleFlightViolation
        }
    }

    private func writeWithDeadline(
        _ frame: PrecisionTransportOutputFrame
    ) async throws -> Int32 {
        let writer = self.writer
        let timeout = operationTimeoutNanoseconds
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask { try await writer.write(frame) }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout)
                    writer.cancelPendingWrite(
                        requestID: frame.requestID,
                        reason: .timeout
                    )
                    throw PrecisionTransportReportIOError.timeout
                }
                guard let result = try await group.next() else {
                    throw PrecisionTransportReportIOError.cancelled
                }
                group.cancelAll()
                return result
            }
        } onCancel: {
            writer.cancelPendingWrite(
                requestID: frame.requestID,
                reason: .cancelled
            )
        }
    }

    private func readWithDeadline(
        _ timeout: UInt64,
        requestID: UUID
    ) async throws -> PrecisionTransportInputFrame {
        let reader = self.reader
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(
                of: PrecisionTransportInputFrame.self
            ) { group in
                group.addTask { try await reader.read(for: requestID) }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout)
                    reader.cancelRequest(requestID, reason: .timeout)
                    throw PrecisionTransportReportIOError.timeout
                }
                guard let result = try await group.next() else {
                    throw PrecisionTransportReportIOError.cancelled
                }
                group.cancelAll()
                return result
            }
        } onCancel: {
            reader.cancelRequest(requestID, reason: .cancelled)
        }
    }

    private func outputFrame(
        requestID: UUID,
        request: HIDPP20LongMessage
    ) -> PrecisionTransportOutputFrame {
        PrecisionTransportOutputFrame(
            requestID: requestID,
            reportType: .output,
            reportID: HIDPP20LongMessage.reportID,
            bytes: request.bytes,
            device: binding.session.device,
            connectionEpoch: binding.session.connectionEpoch,
            rootGeneration: binding.rootGeneration
        )
    }

    private func poisonRequest(
        _ requestID: UUID,
        expectedSession: DeviceTransactionSession,
        cause: Error
    ) {
        correlator.timeout(
            id: requestID,
            connectionEpoch: expectedSession.connectionEpoch
        )
        let reason = Self.cancellationReason(for: cause)
        writer.cancelPendingWrite(requestID: requestID, reason: reason)
        reader.cancelRequest(requestID, reason: reason)
        state = .poisoned
    }

    private static func cancellationReason(
        for error: Error
    ) -> PrecisionTransportReportIOError {
        if error is CancellationError { return .cancelled }
        if let ioError = error as? PrecisionTransportReportIOError {
            return ioError
        }
        return .cancelled
    }

    private static func classifyReadError(_ error: Error) -> Error {
        if error is CancellationError {
            return PrecisionTransportError.cancelled
        }
        if let ioError = error as? PrecisionTransportReportIOError {
            switch ioError {
            case .timeout: return PrecisionTransportError.timeout
            case .disconnected: return PrecisionTransportError.disconnected
            case .cancelled: return PrecisionTransportError.cancelled
            case .overflow: return PrecisionTransportError.inputOverflow
            }
        }
        return error
    }

    private static func hasExactAllowlist(
        _ plan: PrecisionTemporaryDiversionPlan
    ) throws -> Bool {
        let apply = try exactApplyRequest(
            featureIndex: plan.featureIndex
        )
        let restore = try exactRestoreRequest(
            featureIndex: plan.featureIndex
        )
        let get = try exactGetRequest(featureIndex: plan.featureIndex)
        return plan.applySetRequest.bytes == apply.bytes
            && plan.restoreSetRequest.bytes == restore.bytes
            && plan.verificationRequest.bytes == get.bytes
    }

    private static func exactApplyRequest(
        featureIndex: UInt8
    ) throws -> HIDPP20LongMessage {
        try HIDPP20LongMessage(
            deviceIndex: 0,
            featureIndex: featureIndex,
            functionID: 3,
            softwareID: 0x0E,
            parameters: [0x00, 0xED, 0x03, 0x00, 0x00]
        )
    }

    private static func exactRestoreRequest(
        featureIndex: UInt8
    ) throws -> HIDPP20LongMessage {
        try HIDPP20LongMessage(
            deviceIndex: 0,
            featureIndex: featureIndex,
            functionID: 3,
            softwareID: 0x0E,
            parameters: [0x00, 0xED, 0x02, 0x00, 0x00]
        )
    }

    private static func exactGetRequest(
        featureIndex: UInt8
    ) throws -> HIDPP20LongMessage {
        try ReprogControlsV4.getReportingRequest(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            featureIndex: featureIndex,
            deviceIndex: 0,
            softwareID: 0x0E
        )
    }
}
