import Foundation

public enum DeviceTransactionTransportInvocationError: Error, Sendable, Equatable {
    case rejectedBeforeDispatch(String)
    case outcomeUnknown(String)
}

/// Bound, one-operation preparation returned before the coordinator mutates
/// durable state. Concrete transports must retain private in-memory state
/// keyed by `id`; the coordinator validates these public bindings again before
/// consuming the preparation after the write-ahead commit.
public struct DeviceTransactionPreparedInvocation: Sendable, Equatable {
    public let id: UUID
    public let mutation: DeviceTransactionMutation
    public let expectedSession: DeviceTransactionSession
    public let expectedCommittedRevision: UInt64

    public init(
        id: UUID = UUID(),
        mutation: DeviceTransactionMutation,
        expectedSession: DeviceTransactionSession,
        expectedCommittedRevision: UInt64
    ) {
        self.id = id
        self.mutation = mutation
        self.expectedSession = expectedSession
        self.expectedCommittedRevision = expectedCommittedRevision
    }
}

/// Tells a transport why a prepared, memory-only reservation will never be
/// invoked. Only a failure proved to precede every durable write-ahead attempt
/// may make the transport reusable. Every other disposition is terminal for
/// the prepared attempt and must require journal reload/recovery.
public enum DeviceTransactionPreparationDisposition: Sendable, Equatable {
    case discardedBeforeWriteAhead
    case invalidPreparation
    case writeAheadVisibilityUnknown
}

public protocol DeviceTransactionEffectTransport: Sendable {
    func currentSession() async throws -> DeviceTransactionSession
    func prepare(
        _ proposed: DeviceTransactionMutation,
        expectedSession: DeviceTransactionSession,
        expectedCommittedRevision: UInt64
    ) async throws -> DeviceTransactionPreparedInvocation
    func invoke(
        _ prepared: DeviceTransactionPreparedInvocation,
        authorization: DeviceTransactionDurableCommitReceipt
    ) async throws -> DeviceTransactionInvocationEvidence?
    func abandon(
        _ prepared: DeviceTransactionPreparedInvocation,
        disposition: DeviceTransactionPreparationDisposition
    ) async
    func readReporting(
        controlID: UInt16,
        expectedSession: DeviceTransactionSession
    ) async throws -> DeviceTransactionWireState
}

public enum DeviceTransactionCoordinatorError: Error, Sendable, Equatable {
    case operationAlreadyInProgress
    case missingTransactionJournal
    case sessionChanged
    case invalidCommitReceipt
    case invalidPreparedInvocation
    case baselinePreflightMismatch(UInt16)
    case restorePreflightMismatch(UInt16)
    case applyNotObserved(UInt16)
    case restoreNotObserved(UInt16)
    case readBackUnresolved(UInt16, String)
    case conflicted(UInt16)
    case ambiguousRestoreSET(UInt16)
}

public struct DeviceTransactionRecoveryReport: Sendable, Equatable {
    public let transactionID: UUID
    public let inspectedControlIDs: [UInt16]
    public let restoredControlIDs: [UInt16]
    public let finalStatus: DeviceTransactionStatus

    public init(
        transactionID: UUID,
        inspectedControlIDs: [UInt16],
        restoredControlIDs: [UInt16],
        finalStatus: DeviceTransactionStatus
    ) {
        self.transactionID = transactionID
        self.inspectedControlIDs = inspectedControlIDs
        self.restoredControlIDs = restoredControlIDs
        self.finalStatus = finalStatus
    }
}

/// Serializes transaction effects and requires a matching durable commit
/// receipt before the abstract transport can be invoked. MXErgoHID deliberately
/// has no conformance to `DeviceTransactionEffectTransport` in this milestone.
public actor DeviceTransactionCoordinator {
    private let repository: any DeviceTransactionJournalRepository
    private let transport: any DeviceTransactionEffectTransport
    private var activeOperationToken: UUID?

    public init(
        repository: any DeviceTransactionJournalRepository,
        transport: any DeviceTransactionEffectTransport
    ) {
        self.repository = repository
        self.transport = transport
    }

    public func installPreparedEnvelope(
        _ envelope: DeviceTransactionEnvelope
    ) async throws -> DeviceTransactionDurableCommitReceipt {
        let token = try beginOperation()
        defer { endOperation(token) }

        try envelope.validate()
        let session = try await transport.currentSession()
        try requireActive(token)
        guard envelope.isSafeSessionMatch(session) else {
            throw DeviceTransactionModelError.deviceIdentityMismatch
        }
        let receipt = try await repository.commit(envelope, expectedRevision: nil)
        try requireActive(token)
        try validate(receipt, for: envelope)
        return receipt
    }

    public func apply(
        controlID: UInt16,
        intended: DeviceTransactionWireState,
        attemptID: UUID = UUID(),
        now: Date = Date()
    ) async throws -> DeviceTransactionEnvelope {
        let token = try beginOperation()
        defer { endOperation(token) }

        let (envelope, session) = try await loadBoundEnvelope(token: token)
        let baseline = try envelope.control(controlID).baseline
        let preflight = try await transport.readReporting(
            controlID: controlID,
            expectedSession: session
        )
        try requireActive(token)
        try await requireSameSession(session, token: token)
        guard preflight == baseline else {
            if let conflict = try DeviceTransactionReducer.reduceRecoveryObservation(
                envelope,
                controlID: controlID,
                state: preflight,
                now: now
            ) {
                let classified = try await commit(conflict, token: token).envelope
                if try classified.control(controlID).phase == .conflicted {
                    throw DeviceTransactionCoordinatorError.conflicted(controlID)
                }
            }
            throw DeviceTransactionCoordinatorError.baselinePreflightMismatch(controlID)
        }
        let proposed = DeviceTransactionMutation(
            transactionID: envelope.transactionID,
            controlID: controlID,
            attemptID: attemptID,
            kind: .apply,
            state: intended
        )
        let prepared = try await prepare(
            proposed,
            currentRevision: envelope.revision,
            session: session,
            token: token
        )
        let reduction: DeviceTransactionReduction
        do {
            reduction = try DeviceTransactionReducer.reduce(
                envelope,
                event: .armApply(
                    controlID: controlID,
                    intended: intended,
                    attemptID: attemptID,
                    now: now
                )
            )
        } catch {
            await transport.abandon(
                prepared,
                disposition: .discardedBeforeWriteAhead
            )
            throw error
        }
        let result = try await execute(
            reduction,
            prepared: prepared,
            session: session,
            token: token
        )
        let finalControl = try result.control(controlID)
        guard finalControl.phase == .appliedVerified else {
            if finalControl.phase == .conflicted {
                throw DeviceTransactionCoordinatorError.conflicted(controlID)
            }
            throw DeviceTransactionCoordinatorError.applyNotObserved(controlID)
        }
        return result
    }

    public func restore(
        controlID: UInt16,
        attemptID: UUID = UUID(),
        now: Date = Date()
    ) async throws -> DeviceTransactionEnvelope {
        let token = try beginOperation()
        defer { endOperation(token) }

        var envelope: DeviceTransactionEnvelope
        let session: DeviceTransactionSession
        (envelope, session) = try await loadBoundEnvelope(token: token)
        let currentControl = try envelope.control(controlID)
        guard let intended = currentControl.intended else {
            throw DeviceTransactionModelError.invalidReducerEvent(controlID)
        }
        let preflight = try await transport.readReporting(
            controlID: controlID,
            expectedSession: session
        )
        try requireActive(token)
        try await requireSameSession(session, token: token)
        guard preflight == intended else {
            if let classification = try DeviceTransactionReducer.reduceRecoveryObservation(
                envelope,
                controlID: controlID,
                state: preflight,
                now: now
            ) {
                envelope = try await commit(classification, token: token).envelope
            }
            let classified = try envelope.control(controlID)
            if classified.phase == .restoredVerified {
                return envelope
            }
            if classified.phase == .conflicted {
                throw DeviceTransactionCoordinatorError.conflicted(controlID)
            }
            throw DeviceTransactionCoordinatorError.restorePreflightMismatch(controlID)
        }
        let proposed = DeviceTransactionMutation(
            transactionID: envelope.transactionID,
            controlID: controlID,
            attemptID: attemptID,
            kind: .restore,
            state: currentControl.baseline
        )
        let prepared = try await prepare(
            proposed,
            currentRevision: envelope.revision,
            session: session,
            token: token
        )
        let reduction: DeviceTransactionReduction
        do {
            reduction = try DeviceTransactionReducer.reduce(
                envelope,
                event: .armRestore(controlID: controlID, attemptID: attemptID, now: now)
            )
        } catch {
            await transport.abandon(
                prepared,
                disposition: .discardedBeforeWriteAhead
            )
            throw error
        }
        let result = try await execute(
            reduction,
            prepared: prepared,
            session: session,
            token: token
        )
        let finalControl = try result.control(controlID)
        guard finalControl.phase == .restoredVerified else {
            if finalControl.phase == .conflicted {
                throw DeviceTransactionCoordinatorError.conflicted(controlID)
            }
            throw DeviceTransactionCoordinatorError.restoreNotObserved(controlID)
        }
        return result
    }

    /// Reads only controls that were already dirty in the durable journal. It
    /// never arms an apply operation. One explicitly invoked recovery call may
    /// arm at most one new restore attempt for each observed dirty control.
    public func recoverExplicitly(
        now: Date = Date()
    ) async throws -> DeviceTransactionRecoveryReport {
        let token = try beginOperation()
        defer { endOperation(token) }

        var (envelope, session) = try await loadBoundEnvelope(token: token)
        guard envelope.status != .conflicted else {
            throw DeviceTransactionModelError.transactionConflicted
        }

        let initiallyDirty = envelope.dirtyControlIDs
        var inspected: [UInt16] = []
        var restored: [UInt16] = []

        for controlID in initiallyDirty {
            try await requireSameSession(session, token: token)
            let observation: DeviceTransactionWireState
            do {
                observation = try await transport.readReporting(
                    controlID: controlID,
                    expectedSession: session
                )
            } catch {
                try requireActive(token)
                throw DeviceTransactionCoordinatorError.readBackUnresolved(
                    controlID,
                    String(describing: error)
                )
            }
            try requireActive(token)
            try await requireSameSession(session, token: token)
            inspected.append(controlID)

            if let reduction = try DeviceTransactionReducer.reduceRecoveryObservation(
                envelope,
                controlID: controlID,
                state: observation,
                now: now
            ) {
                envelope = try await commit(reduction, token: token).envelope
            }

            let classified = try envelope.control(controlID)
            if classified.phase == .conflicted {
                throw DeviceTransactionCoordinatorError.conflicted(controlID)
            }
            if classified.phase == .restoredVerified {
                restored.append(controlID)
                continue
            }
            if classified.phase == .baselineVerified {
                continue
            }

            // Only an explicitly requested recovery call reaches this branch.
            // It creates a fresh restore attempt; an old attempt ID is never
            // invoked twice after a restart. An outcomeUnknown restore SET is
            // never retried.
            if envelope.hasAmbiguousRestoreSET {
                throw DeviceTransactionCoordinatorError.ambiguousRestoreSET(
                    controlID
                )
            }
            guard classified.phase == .appliedVerified else {
                throw DeviceTransactionCoordinatorError.readBackUnresolved(
                    controlID,
                    "Dirty phase could not be classified"
                )
            }
            let restoreAttemptID = UUID()
            let proposed = DeviceTransactionMutation(
                transactionID: envelope.transactionID,
                controlID: controlID,
                attemptID: restoreAttemptID,
                kind: .restore,
                state: classified.baseline
            )
            let prepared = try await prepare(
                proposed,
                currentRevision: envelope.revision,
                session: session,
                token: token
            )
            let restoreReduction: DeviceTransactionReduction
            do {
                restoreReduction = try DeviceTransactionReducer.reduce(
                    envelope,
                    event: .armRestore(
                        controlID: controlID,
                        attemptID: restoreAttemptID,
                        now: now
                    )
                )
            } catch {
                await transport.abandon(
                    prepared,
                    disposition: .discardedBeforeWriteAhead
                )
                throw error
            }
            envelope = try await execute(
                restoreReduction,
                prepared: prepared,
                session: session,
                token: token
            )
            let restoredControl = try envelope.control(controlID)
            guard restoredControl.phase == .restoredVerified else {
                if restoredControl.phase == .conflicted {
                    throw DeviceTransactionCoordinatorError.conflicted(controlID)
                }
                throw DeviceTransactionCoordinatorError.restoreNotObserved(controlID)
            }
            restored.append(controlID)
            session = try await transport.currentSession()
            try requireActive(token)
            guard envelope.isSafeSessionMatch(session) else {
                throw DeviceTransactionCoordinatorError.sessionChanged
            }
        }

        return DeviceTransactionRecoveryReport(
            transactionID: envelope.transactionID,
            inspectedControlIDs: inspected,
            restoredControlIDs: restored,
            finalStatus: envelope.status
        )
    }

    public func currentEnvelope() async throws -> DeviceTransactionEnvelope? {
        let token = try beginOperation()
        defer { endOperation(token) }
        let envelope = try await repository.loadValidated()
        try requireActive(token)
        return envelope
    }

    private func execute(
        _ reduction: DeviceTransactionReduction,
        prepared: DeviceTransactionPreparedInvocation,
        session: DeviceTransactionSession,
        token: UUID
    ) async throws -> DeviceTransactionEnvelope {
        guard case let .invoke(mutation) = reduction.effect,
              mutation == prepared.mutation,
              prepared.expectedSession == session,
              prepared.expectedCommittedRevision == reduction.envelope.revision else {
            await transport.abandon(
                prepared,
                disposition: .invalidPreparation
            )
            throw DeviceTransactionCoordinatorError.invalidPreparedInvocation
        }
        do {
            try Task.checkCancellation()
        } catch {
            await transport.abandon(
                prepared,
                disposition: .discardedBeforeWriteAhead
            )
            throw error
        }
        let authorizedCommit: (
            envelope: DeviceTransactionEnvelope,
            receipt: DeviceTransactionDurableCommitReceipt
        )
        do {
            authorizedCommit = try await commit(reduction, token: token)
        } catch {
            await transport.abandon(
                prepared,
                disposition: .writeAheadVisibilityUnknown
            )
            throw error
        }
        var envelope = authorizedCommit.envelope
        let receipt = authorizedCommit.receipt
        do {
            try Task.checkCancellation()
            try await requireSameSession(session, token: token)
        } catch {
            await transport.abandon(
                prepared,
                disposition: .writeAheadVisibilityUnknown
            )
            throw error
        }

        var invocationOutcome: DeviceTransactionAttemptOutcome?
        var invocationDetail: String?
        do {
            if let evidence = try await transport.invoke(
                prepared,
                authorization: receipt
            ) {
                guard evidence.attemptID == mutation.attemptID,
                      evidence.connectionEpoch == session.connectionEpoch else {
                    throw DeviceTransactionTransportInvocationError.outcomeUnknown(
                        "Invocation evidence did not match the authorized attempt or connection epoch"
                    )
                }
                let evidenceReduction = try DeviceTransactionReducer.reduce(
                    envelope,
                    event: .recordInvocationEvidence(
                        controlID: mutation.controlID,
                        attemptID: mutation.attemptID,
                        evidence: evidence,
                        now: Date()
                    )
                )
                envelope = try await commit(evidenceReduction, token: token).envelope
            }
            try requireActive(token)
        } catch let transportError as DeviceTransactionTransportInvocationError {
            try requireActive(token)
            switch transportError {
            case let .rejectedBeforeDispatch(detail):
                invocationOutcome = .rejectedBeforeDispatch
                invocationDetail = detail
            case let .outcomeUnknown(detail):
                invocationOutcome = .outcomeUnknown
                invocationDetail = detail
            }
        } catch {
            try requireActive(token)
            invocationOutcome = .outcomeUnknown
            invocationDetail = String(describing: error)
        }

        if let invocationOutcome, let invocationDetail {
            let outcomeReduction = try DeviceTransactionReducer.reduce(
                envelope,
                event: .recordInvocationOutcome(
                    controlID: mutation.controlID,
                    attemptID: mutation.attemptID,
                    outcome: invocationOutcome,
                    detail: invocationDetail,
                    now: Date()
                )
            )
            envelope = try await commit(outcomeReduction, token: token).envelope
        }

        do {
            try await requireSameSession(session, token: token)
        } catch {
            try await recordUnknownIfArmed(
                envelope: &envelope,
                mutation: mutation,
                detail: "Connection identity or epoch changed after invocation",
                token: token
            )
            throw error
        }

        let observation: DeviceTransactionWireState
        do {
            observation = try await transport.readReporting(
                controlID: mutation.controlID,
                expectedSession: session
            )
        } catch {
            try requireActive(token)
            try await recordUnknownIfArmed(
                envelope: &envelope,
                mutation: mutation,
                detail: "Read-back failed: \(error)",
                token: token
            )
            throw DeviceTransactionCoordinatorError.readBackUnresolved(
                mutation.controlID,
                String(describing: error)
            )
        }
        try requireActive(token)
        try await requireSameSession(session, token: token)

        let observationEvent: DeviceTransactionReducerEvent
        switch mutation.kind {
        case .apply:
            observationEvent = .observeApply(
                controlID: mutation.controlID,
                state: observation,
                now: Date()
            )
        case .restore:
            observationEvent = .observeRestore(
                controlID: mutation.controlID,
                state: observation,
                now: Date()
            )
        }
        envelope = try await commit(
            DeviceTransactionReducer.reduce(envelope, event: observationEvent),
            token: token
        ).envelope
        return envelope
    }

    private func prepare(
        _ proposed: DeviceTransactionMutation,
        currentRevision: UInt64,
        session: DeviceTransactionSession,
        token: UUID
    ) async throws -> DeviceTransactionPreparedInvocation {
        guard currentRevision < .max else {
            throw DeviceTransactionModelError.invalidRevision(
                expected: currentRevision,
                actual: currentRevision
            )
        }
        let expectedCommittedRevision = currentRevision + 1
        let prepared = try await transport.prepare(
            proposed,
            expectedSession: session,
            expectedCommittedRevision: expectedCommittedRevision
        )
        do {
            try Task.checkCancellation()
            try requireActive(token)
            try await requireSameSession(session, token: token)
        } catch {
            await transport.abandon(
                prepared,
                disposition: .discardedBeforeWriteAhead
            )
            throw error
        }
        guard prepared.mutation == proposed,
              prepared.expectedSession == session,
              prepared.expectedCommittedRevision == expectedCommittedRevision else {
            await transport.abandon(
                prepared,
                disposition: .invalidPreparation
            )
            throw DeviceTransactionCoordinatorError.invalidPreparedInvocation
        }
        return prepared
    }

    private func commit(
        _ reduction: DeviceTransactionReduction,
        token: UUID
    ) async throws -> (
        envelope: DeviceTransactionEnvelope,
        receipt: DeviceTransactionDurableCommitReceipt
    ) {
        let receipt = try await repository.commit(
            reduction.envelope,
            expectedRevision: reduction.previousRevision
        )
        try requireActive(token)
        try validate(receipt, for: reduction.envelope)
        return (reduction.envelope, receipt)
    }

    private func recordUnknownIfArmed(
        envelope: inout DeviceTransactionEnvelope,
        mutation: DeviceTransactionMutation,
        detail: String,
        token: UUID
    ) async throws {
        let control = try envelope.control(mutation.controlID)
        guard control.activeAttemptID == mutation.attemptID,
              control.attempts.first(where: { $0.id == mutation.attemptID })?.outcome == .armed else {
            return
        }
        let reduction = try DeviceTransactionReducer.reduce(
            envelope,
            event: .recordInvocationOutcome(
                controlID: mutation.controlID,
                attemptID: mutation.attemptID,
                outcome: .outcomeUnknown,
                detail: detail,
                now: Date()
            )
        )
        envelope = try await commit(reduction, token: token).envelope
    }

    private func loadBoundEnvelope(
        token: UUID
    ) async throws -> (DeviceTransactionEnvelope, DeviceTransactionSession) {
        guard let envelope = try await repository.loadValidated() else {
            throw DeviceTransactionCoordinatorError.missingTransactionJournal
        }
        try requireActive(token)
        let session = try await transport.currentSession()
        try requireActive(token)
        guard envelope.isSafeSessionMatch(session) else {
            throw DeviceTransactionModelError.deviceIdentityMismatch
        }
        return (envelope, session)
    }

    private func requireSameSession(
        _ expected: DeviceTransactionSession,
        token: UUID
    ) async throws {
        let current = try await transport.currentSession()
        try requireActive(token)
        guard current == expected else {
            throw DeviceTransactionCoordinatorError.sessionChanged
        }
    }

    private func validate(
        _ receipt: DeviceTransactionDurableCommitReceipt,
        for envelope: DeviceTransactionEnvelope
    ) throws {
        guard receipt.transactionID == envelope.transactionID,
              receipt.revision == envelope.revision,
              !receipt.sha256.isEmpty else {
            throw DeviceTransactionCoordinatorError.invalidCommitReceipt
        }
    }

    private func beginOperation() throws -> UUID {
        guard activeOperationToken == nil else {
            throw DeviceTransactionCoordinatorError.operationAlreadyInProgress
        }
        let token = UUID()
        activeOperationToken = token
        return token
    }

    private func requireActive(_ token: UUID) throws {
        guard activeOperationToken == token else {
            throw DeviceTransactionCoordinatorError.operationAlreadyInProgress
        }
    }

    private func endOperation(_ token: UUID) {
        if activeOperationToken == token {
            activeOperationToken = nil
        }
    }
}
