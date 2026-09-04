import Foundation

public enum DeviceRecoveryPlanningError: Error, Sendable, Equatable {
    case deviceIdentityMismatch
    case journalAlreadyRequiresRecovery
    case controlNotAtVerifiedBaseline(UInt16)
    case finalStateNotRestored(UInt16)
}

public struct DeviceRecoveryPlanStep: Sendable, Equatable {
    public let ordinal: Int
    public let controlIndex: UInt8
    public let controlID: UInt16
    public let baselineReporting: ReprogControlReportingState

    public init(
        ordinal: Int,
        controlIndex: UInt8,
        controlID: UInt16,
        baselineReporting: ReprogControlReportingState
    ) {
        self.ordinal = ordinal
        self.controlIndex = controlIndex
        self.controlID = controlID
        self.baselineReporting = baselineReporting
    }
}

public struct DeviceRecoveryPlan: Sendable, Equatable {
    public let transactionID: UUID
    public let device: JournalDeviceIdentity
    public let featureID: UInt16
    public let featureVersion: UInt8
    public let steps: [DeviceRecoveryPlanStep]

    public init(
        transactionID: UUID,
        device: JournalDeviceIdentity,
        featureID: UInt16,
        featureVersion: UInt8,
        steps: [DeviceRecoveryPlanStep]
    ) {
        self.transactionID = transactionID
        self.device = device
        self.featureID = featureID
        self.featureVersion = featureVersion
        self.steps = steps
    }
}

public enum DeviceRecoveryPlanner {
    /// Builds the exact baseline restore sequence in physical control-index
    /// order. No packet is encoded and no mutable state is retained.
    public static func makePlan(
        journal: DeviceStateJournal,
        candidateDevice: JournalDeviceIdentity
    ) throws -> DeviceRecoveryPlan {
        try journal.validateForRecovery()
        guard journal.device.isSafeRecoveryMatch(candidateDevice) else {
            throw DeviceRecoveryPlanningError.deviceIdentityMismatch
        }

        let entries = journal.controls.sorted {
            $0.controlInfo.index < $1.controlInfo.index
        }
        let steps = entries.enumerated().map { ordinal, entry in
            DeviceRecoveryPlanStep(
                ordinal: ordinal,
                controlIndex: entry.controlInfo.index,
                controlID: entry.controlInfo.controlID,
                baselineReporting: entry.baselineReporting
            )
        }
        return DeviceRecoveryPlan(
            transactionID: journal.transactionID,
            device: journal.device,
            featureID: journal.featureID,
            featureVersion: journal.feature.version,
            steps: steps
        )
    }
}

public struct DeviceRecoveryRehearsalStep: Sendable, Equatable {
    public let plan: DeviceRecoveryPlanStep
    public let phaseSequence: [DeviceControlJournalPhase]

    public init(
        plan: DeviceRecoveryPlanStep,
        phaseSequence: [DeviceControlJournalPhase]
    ) {
        self.plan = plan
        self.phaseSequence = phaseSequence
    }
}

public struct DeviceRecoveryRehearsalReport: Sendable, Equatable {
    public let transactionID: UUID
    public let steps: [DeviceRecoveryRehearsalStep]
    public let finalStatusSummary: String

    public init(
        transactionID: UUID,
        steps: [DeviceRecoveryRehearsalStep],
        finalStatusSummary: String
    ) {
        self.transactionID = transactionID
        self.steps = steps
        self.finalStatusSummary = finalStatusSummary
    }
}

public enum DeviceRecoveryRehearsal {
    /// Exercises the complete write-ahead/apply/read-back/restore/read-back
    /// state machine on an in-memory value copy. It performs no file write and
    /// exposes no HID transport, so it cannot affect the physical device.
    public static func run(
        journal: DeviceStateJournal,
        candidateDevice: JournalDeviceIdentity
    ) throws -> DeviceRecoveryRehearsalReport {
        let plan = try DeviceRecoveryPlanner.makePlan(
            journal: journal,
            candidateDevice: candidateDevice
        )
        guard !journal.requiresRecovery else {
            throw DeviceRecoveryPlanningError.journalAlreadyRequiresRecovery
        }
        for entry in journal.controls where entry.phase != .baselineVerified {
            throw DeviceRecoveryPlanningError.controlNotAtVerifiedBaseline(
                entry.controlInfo.controlID
            )
        }

        var simulatedJournal = journal
        var rehearsedSteps: [DeviceRecoveryRehearsalStep] = []
        rehearsedSteps.reserveCapacity(plan.steps.count)

        for step in plan.steps {
            let intended = try simulatedIntendedState(
                from: step.baselineReporting,
                featureVersion: plan.featureVersion
            )
            let phases: [DeviceControlJournalPhase] = [
                .baselineVerified,
                .applyMayHaveOccurred,
                .appliedVerified,
                .restoreMayHaveOccurred,
                .restoredVerified,
            ]

            try simulatedJournal.transitionControl(
                step.controlID,
                to: .applyMayHaveOccurred,
                intendedReporting: intended
            )
            try simulatedJournal.transitionControl(
                step.controlID,
                to: .appliedVerified,
                readBackReporting: intended
            )
            try simulatedJournal.transitionControl(
                step.controlID,
                to: .restoreMayHaveOccurred
            )
            try simulatedJournal.transitionControl(
                step.controlID,
                to: .restoredVerified,
                readBackReporting: step.baselineReporting
            )

            rehearsedSteps.append(DeviceRecoveryRehearsalStep(
                plan: step,
                phaseSequence: phases
            ))
        }

        try simulatedJournal.validateForRecovery()
        for entry in simulatedJournal.controls where entry.phase != .restoredVerified {
            throw DeviceRecoveryPlanningError.finalStateNotRestored(
                entry.controlInfo.controlID
            )
        }
        guard !simulatedJournal.requiresRecovery else {
            throw DeviceRecoveryPlanningError.journalAlreadyRequiresRecovery
        }

        return DeviceRecoveryRehearsalReport(
            transactionID: plan.transactionID,
            steps: rehearsedSteps,
            finalStatusSummary: simulatedJournal.statusSummary
        )
    }

    private static func simulatedIntendedState(
        from baseline: ReprogControlReportingState,
        featureVersion: UInt8
    ) throws -> ReprogControlReportingState {
        let flags = baseline.rawFlags ^ 0x0001
        let intended = try DeviceTransactionWireState(
            rawParameters: baseline.rawParameters
        ).replacingRawFlags(flags, featureVersion: featureVersion)
        return ReprogControlReportingState(
            controlID: baseline.controlID,
            rawFlags: flags,
            rawMappedControlID: baseline.rawMappedControlID,
            rawParameters: intended.rawParameters
        )
    }
}
