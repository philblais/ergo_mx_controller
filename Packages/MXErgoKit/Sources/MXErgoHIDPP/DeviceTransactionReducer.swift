import Foundation

public enum DeviceTransactionReducerEvent: Sendable, Equatable {
    case armApply(
        controlID: UInt16,
        intended: DeviceTransactionWireState,
        attemptID: UUID,
        now: Date
    )
    case armRestore(controlID: UInt16, attemptID: UUID, now: Date)
    case recordInvocationOutcome(
        controlID: UInt16,
        attemptID: UUID,
        outcome: DeviceTransactionAttemptOutcome,
        detail: String,
        now: Date
    )
    case recordInvocationEvidence(
        controlID: UInt16,
        attemptID: UUID,
        evidence: DeviceTransactionInvocationEvidence,
        now: Date
    )
    case observeApply(controlID: UInt16, state: DeviceTransactionWireState, now: Date)
    case observeRestore(controlID: UInt16, state: DeviceTransactionWireState, now: Date)
}

public struct DeviceTransactionMutation: Sendable, Equatable {
    public let transactionID: UUID
    public let controlID: UInt16
    public let attemptID: UUID
    public let kind: DeviceTransactionMutationKind
    public let state: DeviceTransactionWireState

    public init(
        transactionID: UUID,
        controlID: UInt16,
        attemptID: UUID,
        kind: DeviceTransactionMutationKind,
        state: DeviceTransactionWireState
    ) {
        self.transactionID = transactionID
        self.controlID = controlID
        self.attemptID = attemptID
        self.kind = kind
        self.state = state
    }
}

public enum DeviceTransactionReducerEffect: Sendable, Equatable {
    case none
    case invoke(DeviceTransactionMutation)
}

public struct DeviceTransactionReduction: Sendable, Equatable {
    public let previousRevision: UInt64
    public let envelope: DeviceTransactionEnvelope
    public let effect: DeviceTransactionReducerEffect

    public init(
        previousRevision: UInt64,
        envelope: DeviceTransactionEnvelope,
        effect: DeviceTransactionReducerEffect
    ) {
        self.previousRevision = previousRevision
        self.envelope = envelope
        self.effect = effect
    }
}

public enum DeviceTransactionReducer {
    public static func reduce(
        _ current: DeviceTransactionEnvelope,
        event: DeviceTransactionReducerEvent
    ) throws -> DeviceTransactionReduction {
        try current.validate()
        guard current.status != .conflicted else {
            throw DeviceTransactionModelError.transactionConflicted
        }

        let previousRevision = current.revision
        var next = current
        var effect = DeviceTransactionReducerEffect.none

        switch event {
        case let .armApply(controlID, intended, attemptID, now):
            try intended.validate(controlID: controlID)
            let currentControl = try current.control(controlID)
            guard intended.preservesNonFlagBytes(
                of: currentControl.baseline,
                featureVersion: current.featureVersion
            ) else {
                throw DeviceTransactionModelError.unsafeIntendedPayload(controlID)
            }
            let ordinal = current.nextAttemptOrdinal
            try next.updateControl(controlID, now: now) { control in
                guard control.phase == .baselineVerified,
                      control.intended == nil,
                      control.activeAttemptID == nil else {
                    throw DeviceTransactionModelError.invalidReducerEvent(controlID)
                }
                control.intended = intended
                control.appliedObservation = nil
                control.restoredObservation = nil
                control.conflictingObservation = nil
                control.conflictReason = nil
                control.phase = .applyMayHaveOccurred
                control.attempts.append(DeviceTransactionAttempt(
                    id: attemptID,
                    ordinal: ordinal,
                    kind: .apply,
                    armedAtRevision: previousRevision + 1
                ))
                control.activeAttemptID = attemptID
            }
            effect = .invoke(DeviceTransactionMutation(
                transactionID: current.transactionID,
                controlID: controlID,
                attemptID: attemptID,
                kind: .apply,
                state: intended
            ))

        case let .armRestore(controlID, attemptID, now):
            let ordinal = current.nextAttemptOrdinal
            let control = try current.control(controlID)
            guard let intended = control.intended else {
                throw DeviceTransactionModelError.invalidReducerEvent(controlID)
            }
            try next.updateControl(controlID, now: now) { mutableControl in
                guard mutableControl.phase == .appliedVerified,
                      mutableControl.appliedObservation == intended,
                      mutableControl.activeAttemptID == nil else {
                    throw DeviceTransactionModelError.invalidReducerEvent(controlID)
                }
                mutableControl.phase = .restoreMayHaveOccurred
                mutableControl.restoredObservation = nil
                mutableControl.conflictingObservation = nil
                mutableControl.conflictReason = nil
                mutableControl.attempts.append(DeviceTransactionAttempt(
                    id: attemptID,
                    ordinal: ordinal,
                    kind: .restore,
                    armedAtRevision: previousRevision + 1
                ))
                mutableControl.activeAttemptID = attemptID
            }
            effect = .invoke(DeviceTransactionMutation(
                transactionID: current.transactionID,
                controlID: controlID,
                attemptID: attemptID,
                kind: .restore,
                state: control.baseline
            ))

        case let .recordInvocationOutcome(controlID, attemptID, outcome, detail, now):
            guard outcome == .rejectedBeforeDispatch || outcome == .outcomeUnknown else {
                throw DeviceTransactionModelError.invalidReducerEvent(controlID)
            }
            try next.updateControl(controlID, now: now) { control in
                guard control.activeAttemptID == attemptID,
                      let attemptIndex = control.attempts.firstIndex(where: { $0.id == attemptID }),
                      control.attempts[attemptIndex].outcome == .armed else {
                    throw DeviceTransactionModelError.invalidReducerEvent(controlID)
                }
                control.attempts[attemptIndex].outcome = outcome
                control.attempts[attemptIndex].detail = detail
            }

        case let .recordInvocationEvidence(controlID, attemptID, evidence, now):
            try evidence.validate(controlID: controlID, expectedAttemptID: attemptID)
            try next.updateControl(controlID, now: now) { control in
                guard control.activeAttemptID == attemptID,
                      let attemptIndex = control.attempts.firstIndex(where: { $0.id == attemptID }),
                      control.attempts[attemptIndex].invocationEvidence == nil else {
                    throw DeviceTransactionModelError.invalidReducerEvent(controlID)
                }
                control.attempts[attemptIndex].invocationEvidence = evidence
            }

        case let .observeApply(controlID, state, now):
            try state.validate(controlID: controlID)
            try next.updateControl(controlID, now: now) { control in
                try resolveApplyObservation(&control, state: state)
            }

        case let .observeRestore(controlID, state, now):
            try state.validate(controlID: controlID)
            try next.updateControl(controlID, now: now) { control in
                try resolveRestoreObservation(&control, state: state)
            }
        }

        return DeviceTransactionReduction(
            previousRevision: previousRevision,
            envelope: next,
            effect: effect
        )
    }

    /// Classifies one explicit restart-recovery read. It never arms an apply
    /// mutation. A nil result means the observed state already matches the
    /// verified phase and no durable state change is required.
    public static func reduceRecoveryObservation(
        _ current: DeviceTransactionEnvelope,
        controlID: UInt16,
        state: DeviceTransactionWireState,
        now: Date = Date()
    ) throws -> DeviceTransactionReduction? {
        try current.validate()
        try state.validate(controlID: controlID)
        let control = try current.control(controlID)

        switch control.phase {
        case .applyMayHaveOccurred:
            return try reduce(
                current,
                event: .observeApply(controlID: controlID, state: state, now: now)
            )
        case .restoreMayHaveOccurred:
            return try reduce(
                current,
                event: .observeRestore(controlID: controlID, state: state, now: now)
            )
        case .appliedVerified:
            guard let intended = control.intended else {
                throw DeviceTransactionModelError.invalidPhaseState(controlID)
            }
            if state == intended {
                return nil
            }
            var next = current
            let previousRevision = current.revision
            try next.updateControl(controlID, now: now) { mutableControl in
                if state == mutableControl.baseline {
                    mutableControl.phase = .restoredVerified
                    mutableControl.restoredObservation = state
                } else {
                    markConflict(
                        &mutableControl,
                        state: state,
                        reason: "Recovery observed neither the baseline nor intended state"
                    )
                }
            }
            return DeviceTransactionReduction(
                previousRevision: previousRevision,
                envelope: next,
                effect: .none
            )
        case .baselineVerified:
            if state == control.baseline { return nil }
            var next = current
            let previousRevision = current.revision
            try next.updateControl(controlID, now: now) { mutableControl in
                markConflict(
                    &mutableControl,
                    state: state,
                    reason: "A clean control no longer matches its saved baseline"
                )
            }
            return DeviceTransactionReduction(
                previousRevision: previousRevision,
                envelope: next,
                effect: .none
            )
        case .restoredVerified:
            if state == control.baseline { return nil }
            var next = current
            let previousRevision = current.revision
            try next.updateControl(controlID, now: now) { mutableControl in
                markConflict(
                    &mutableControl,
                    state: state,
                    reason: "A restored control no longer matches its saved baseline"
                )
            }
            return DeviceTransactionReduction(
                previousRevision: previousRevision,
                envelope: next,
                effect: .none
            )
        case .conflicted:
            throw DeviceTransactionModelError.transactionConflicted
        }
    }

    private static func resolveApplyObservation(
        _ control: inout DeviceTransactionControl,
        state: DeviceTransactionWireState
    ) throws {
        guard control.phase == .applyMayHaveOccurred,
              let intended = control.intended,
              let attemptID = control.activeAttemptID,
              let attemptIndex = control.attempts.firstIndex(where: { $0.id == attemptID }) else {
            throw DeviceTransactionModelError.invalidReducerEvent(control.controlID)
        }

        control.activeAttemptID = nil
        if state == intended {
            control.appliedObservation = state
            control.phase = .appliedVerified
            control.attempts[attemptIndex].outcome = .verified
            control.attempts[attemptIndex].detail = nil
        } else if state == control.baseline {
            control.appliedObservation = state
            control.phase = .baselineVerified
            control.attempts[attemptIndex].outcome = .observedNoMutation
        } else {
            control.attempts[attemptIndex].outcome = .conflicted
            markConflict(
                &control,
                state: state,
                reason: "Apply read-back matched neither the baseline nor intended state"
            )
        }
    }

    private static func resolveRestoreObservation(
        _ control: inout DeviceTransactionControl,
        state: DeviceTransactionWireState
    ) throws {
        guard control.phase == .restoreMayHaveOccurred,
              let intended = control.intended,
              let attemptID = control.activeAttemptID,
              let attemptIndex = control.attempts.firstIndex(where: { $0.id == attemptID }) else {
            throw DeviceTransactionModelError.invalidReducerEvent(control.controlID)
        }

        let previousOutcome = control.attempts[attemptIndex].outcome
        control.restoredObservation = state
        if state == control.baseline {
            control.activeAttemptID = nil
            control.phase = .restoredVerified
            control.attempts[attemptIndex].outcome = .verified
            control.attempts[attemptIndex].detail = nil
        } else if state == intended, previousOutcome == .outcomeUnknown {
            // Keep the unknown restore attempt. Rewriting this as a clean
            // appliedVerified would let a later recover arm another restore SET.
            control.activeAttemptID = attemptID
            control.phase = .restoreMayHaveOccurred
        } else if state == intended {
            control.activeAttemptID = nil
            control.phase = .appliedVerified
            control.attempts[attemptIndex].outcome = .observedNoMutation
        } else {
            control.activeAttemptID = nil
            control.attempts[attemptIndex].outcome = .conflicted
            markConflict(
                &control,
                state: state,
                reason: "Restore read-back matched neither the baseline nor intended state"
            )
        }
    }

    private static func markConflict(
        _ control: inout DeviceTransactionControl,
        state: DeviceTransactionWireState,
        reason: String
    ) {
        control.phase = .conflicted
        control.activeAttemptID = nil
        control.conflictingObservation = state
        control.conflictReason = reason
    }
}
