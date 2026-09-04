import Foundation

public struct DeviceTransactionSimulationReport: Sendable, Equatable {
    public let controlCount: Int
    public let cleanRoundTripCount: Int
    public let interruptedRecoveryCount: Int
    public let durableCommitCount: Int
    public let abstractMutationCount: Int
    public let durableCommitBoundaryCount: Int
    public let recoveryClassificationCount: Int
    public let transportFaultScenarioCount: Int
    public let reconnectIdentityCheckCount: Int
    public let immutableWireByteCheckCount: Int
    public let finalStatus: DeviceTransactionStatus

    public init(
        controlCount: Int,
        cleanRoundTripCount: Int,
        interruptedRecoveryCount: Int,
        durableCommitCount: Int,
        abstractMutationCount: Int,
        durableCommitBoundaryCount: Int,
        recoveryClassificationCount: Int,
        transportFaultScenarioCount: Int,
        reconnectIdentityCheckCount: Int,
        immutableWireByteCheckCount: Int,
        finalStatus: DeviceTransactionStatus
    ) {
        self.controlCount = controlCount
        self.cleanRoundTripCount = cleanRoundTripCount
        self.interruptedRecoveryCount = interruptedRecoveryCount
        self.durableCommitCount = durableCommitCount
        self.abstractMutationCount = abstractMutationCount
        self.durableCommitBoundaryCount = durableCommitBoundaryCount
        self.recoveryClassificationCount = recoveryClassificationCount
        self.transportFaultScenarioCount = transportFaultScenarioCount
        self.reconnectIdentityCheckCount = reconnectIdentityCheckCount
        self.immutableWireByteCheckCount = immutableWireByteCheckCount
        self.finalStatus = finalStatus
    }
}

public enum DeviceTransactionSimulationError: Error, Sendable, Equatable {
    case invalidAuthorization
    case missingState(UInt16)
    case unexpectedFinalStatus(DeviceTransactionStatus)
    case unexpectedRecoveryResult
    case persistenceBoundaryFailed(DeviceTransactionCommitBoundary)
    case recoveryClassificationFailed(Int)
    case transportFaultScenarioFailed(String)
    case reconnectIdentityCheckFailed(Int)
    case immutableWireByteCheckFailed(Int)
}

/// Runs the real schema-v3 reducer and actor coordinator against isolated
/// in-memory repositories and a scripted state transport. It has no dependency
/// on MXErgoHID, no packet encoder, and no path to the physical device.
public enum DeviceTransactionSimulation {
    public static func run(
        baselineJournal: DeviceStateJournal
    ) async throws -> DeviceTransactionSimulationReport {
        let cleanEnvelope = try DeviceTransactionEnvelope(
            baselineJournal: baselineJournal
        )
        let cleanRepository = SimulationJournalRepository()
        let cleanTransport = SimulationTransactionTransport(
            repository: cleanRepository,
            session: session(for: cleanEnvelope, epoch: 1),
            initialStates: states(for: cleanEnvelope)
        )
        let cleanCoordinator = DeviceTransactionCoordinator(
            repository: cleanRepository,
            transport: cleanTransport
        )
        _ = try await cleanCoordinator.installPreparedEnvelope(cleanEnvelope)

        for control in cleanEnvelope.controls {
            let intended = try simulatedIntendedState(
                control.baseline,
                featureVersion: cleanEnvelope.featureVersion
            )
            _ = try await cleanCoordinator.apply(
                controlID: control.controlID,
                intended: intended
            )
            _ = try await cleanCoordinator.restore(controlID: control.controlID)
        }
        guard let cleanFinal = try await cleanCoordinator.currentEnvelope(),
              cleanFinal.status == .completed else {
            throw DeviceTransactionSimulationError.unexpectedFinalStatus(
                try await cleanCoordinator.currentEnvelope()?.status ?? .conflicted
            )
        }

        let cleanCommitCount = await cleanRepository.commitCount()
        let cleanMutationCount = await cleanTransport.mutationCount()

        // Simulate a process stopping after the apply write-ahead commit but
        // before the abstract mutation. Recovery must observe the baseline and
        // return to an aborted-clean state without invoking any mutation.
        let beforeInvocation = try DeviceTransactionEnvelope(
            transactionID: UUID(),
            baselineJournal: baselineJournal
        )
        let beforeRepository = SimulationJournalRepository()
        let beforeTransport = SimulationTransactionTransport(
            repository: beforeRepository,
            session: session(for: beforeInvocation, epoch: 2),
            initialStates: states(for: beforeInvocation)
        )
        let beforeCoordinator = DeviceTransactionCoordinator(
            repository: beforeRepository,
            transport: beforeTransport
        )
        _ = try await beforeCoordinator.installPreparedEnvelope(beforeInvocation)
        let firstControl = try requiredFirstControl(beforeInvocation)
        let beforeReduction = try DeviceTransactionReducer.reduce(
            beforeInvocation,
            event: .armApply(
                controlID: firstControl.controlID,
                intended: try simulatedIntendedState(
                    firstControl.baseline,
                    featureVersion: beforeInvocation.featureVersion
                ),
                attemptID: UUID(),
                now: Date()
            )
        )
        _ = try await beforeRepository.commit(
            beforeReduction.envelope,
            expectedRevision: beforeReduction.previousRevision
        )
        let beforeRestart = DeviceTransactionCoordinator(
            repository: beforeRepository,
            transport: beforeTransport
        )
        let beforeReport = try await beforeRestart.recoverExplicitly()
        guard beforeReport.inspectedControlIDs == [firstControl.controlID],
              beforeReport.restoredControlIDs.isEmpty,
              beforeReport.finalStatus == .abortedClean,
              await beforeTransport.mutationCount() == 0 else {
            throw DeviceTransactionSimulationError.unexpectedRecoveryResult
        }

        // Simulate a process stopping after the authorized abstract mutation
        // but before read-back. Recovery must read intended, arm one fresh
        // restore attempt, and finish at the exact baseline.
        let afterInvocation = try DeviceTransactionEnvelope(
            transactionID: UUID(),
            baselineJournal: baselineJournal
        )
        let afterRepository = SimulationJournalRepository()
        let afterTransport = SimulationTransactionTransport(
            repository: afterRepository,
            session: session(for: afterInvocation, epoch: 3),
            initialStates: states(for: afterInvocation)
        )
        let afterCoordinator = DeviceTransactionCoordinator(
            repository: afterRepository,
            transport: afterTransport
        )
        _ = try await afterCoordinator.installPreparedEnvelope(afterInvocation)
        let afterControl = try requiredFirstControl(afterInvocation)
        let afterReduction = try DeviceTransactionReducer.reduce(
            afterInvocation,
            event: .armApply(
                controlID: afterControl.controlID,
                intended: try simulatedIntendedState(
                    afterControl.baseline,
                    featureVersion: afterInvocation.featureVersion
                ),
                attemptID: UUID(),
                now: Date()
            )
        )
        guard case let .invoke(afterMutation) = afterReduction.effect else {
            throw DeviceTransactionSimulationError.invalidAuthorization
        }
        let afterPrepared = try await afterTransport.prepare(
            afterMutation,
            expectedSession: session(for: afterInvocation, epoch: 3),
            expectedCommittedRevision: afterReduction.envelope.revision
        )
        let afterReceipt = try await afterRepository.commit(
            afterReduction.envelope,
            expectedRevision: afterReduction.previousRevision
        )
        _ = try await afterTransport.invoke(
            afterPrepared,
            authorization: afterReceipt
        )
        let afterRestart = DeviceTransactionCoordinator(
            repository: afterRepository,
            transport: afterTransport
        )
        let afterReport = try await afterRestart.recoverExplicitly()
        guard afterReport.inspectedControlIDs == [afterControl.controlID],
              afterReport.restoredControlIDs == [afterControl.controlID],
              afterReport.finalStatus == .completed,
              await afterTransport.mutationCount() == 2 else {
            throw DeviceTransactionSimulationError.unexpectedRecoveryResult
        }

        let durableCommitBoundaryCount = try await verifyDurableCommitBoundaries(
            baselineJournal: baselineJournal
        )
        let recoveryClassificationCount = try verifyRecoveryClassifications(
            baselineJournal: baselineJournal
        )
        let transportFaultScenarioCount = try await verifyTransportFaultMatrix(
            baselineJournal: baselineJournal
        )
        let reconnectIdentityCheckCount = try verifyReconnectIdentityBinding(
            baselineJournal: baselineJournal
        )
        let immutableWireByteCheckCount = try verifyImmutableWireBytes(
            baselineJournal: baselineJournal
        )

        return DeviceTransactionSimulationReport(
            controlCount: cleanEnvelope.controls.count,
            cleanRoundTripCount: cleanEnvelope.controls.count,
            interruptedRecoveryCount: 2,
            durableCommitCount: cleanCommitCount
                + (await beforeRepository.commitCount())
                + (await afterRepository.commitCount()),
            abstractMutationCount: cleanMutationCount
                + (await beforeTransport.mutationCount())
                + (await afterTransport.mutationCount()),
            durableCommitBoundaryCount: durableCommitBoundaryCount,
            recoveryClassificationCount: recoveryClassificationCount,
            transportFaultScenarioCount: transportFaultScenarioCount,
            reconnectIdentityCheckCount: reconnectIdentityCheckCount,
            immutableWireByteCheckCount: immutableWireByteCheckCount,
            finalStatus: cleanFinal.status
        )
    }

    /// Exercises every file-replacement boundary against unique temporary
    /// journals. A thrown commit may expose either the old or new complete
    /// revision, but never malformed JSON or a partially written envelope.
    private static func verifyDurableCommitBoundaries(
        baselineJournal: DeviceStateJournal
    ) async throws -> Int {
        enum InjectedFailure: Error { case boundary }

        var verifiedCount = 0
        for boundary in DeviceTransactionCommitBoundary.allCases {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("transaction-v3.json")
            let prepared = try DeviceTransactionEnvelope(
                transactionID: UUID(),
                baselineJournal: baselineJournal
            )
            let initialRepository = DurableDeviceTransactionFileRepository(
                fileURL: fileURL
            )
            _ = try await initialRepository.commit(prepared, expectedRevision: nil)

            let control = try requiredFirstControl(prepared)
            let reduction = try DeviceTransactionReducer.reduce(
                prepared,
                event: .armApply(
                    controlID: control.controlID,
                    intended: try simulatedIntendedState(
                        control.baseline,
                        featureVersion: prepared.featureVersion
                    ),
                    attemptID: UUID(),
                    now: Date()
                )
            )
            let faultingRepository = DurableDeviceTransactionFileRepository(
                fileURL: fileURL
            ) { reachedBoundary in
                if reachedBoundary == boundary {
                    throw InjectedFailure.boundary
                }
            }

            var didThrow = false
            do {
                _ = try await faultingRepository.commit(
                    reduction.envelope,
                    expectedRevision: reduction.previousRevision
                )
            } catch {
                didThrow = true
            }
            let reopenedRepository = DurableDeviceTransactionFileRepository(
                fileURL: fileURL
            )
            guard didThrow,
                  let durable = try await reopenedRepository.loadValidated() else {
                throw DeviceTransactionSimulationError.persistenceBoundaryFailed(boundary)
            }

            let replacementIsVisible: Bool
            switch boundary {
            case .beforeTemporaryWrite, .afterTemporaryWrite, .afterTemporaryFullSync:
                replacementIsVisible = false
            case .afterAtomicReplace, .afterDirectorySync, .beforeReceiptReturn:
                replacementIsVisible = true
            }
            let expectedRevision: UInt64 = replacementIsVisible ? 1 : 0
            let expectedPhase: DeviceTransactionControlPhase = replacementIsVisible
                ? .applyMayHaveOccurred
                : .baselineVerified
            guard durable.revision == expectedRevision,
                  try durable.control(control.controlID).phase == expectedPhase else {
                throw DeviceTransactionSimulationError.persistenceBoundaryFailed(boundary)
            }
            verifiedCount += 1
        }
        return verifiedCount
    }

    /// Verifies exact baseline/intended/third-party classification for every
    /// recoverable phase, plus the rule that a persisted conflict is terminal.
    private static func verifyRecoveryClassifications(
        baselineJournal: DeviceStateJournal
    ) throws -> Int {
        let baselineEnvelope = try DeviceTransactionEnvelope(
            transactionID: UUID(),
            baselineJournal: baselineJournal
        )
        let control = try requiredFirstControl(baselineEnvelope)
        let baseline = control.baseline
        let intended = try simulatedIntendedState(
            baseline,
            featureVersion: baselineEnvelope.featureVersion
        )
        var thirdPartyBytes = baseline.rawParameters
        thirdPartyBytes[2] ^= 0x80
        let thirdParty = try DeviceTransactionWireState(rawParameters: thirdPartyBytes)

        let applyMay = try DeviceTransactionReducer.reduce(
            baselineEnvelope,
            event: .armApply(
                controlID: control.controlID,
                intended: intended,
                attemptID: UUID(),
                now: Date()
            )
        ).envelope
        let applied = try DeviceTransactionReducer.reduce(
            applyMay,
            event: .observeApply(
                controlID: control.controlID,
                state: intended,
                now: Date()
            )
        ).envelope
        let restoreMay = try DeviceTransactionReducer.reduce(
            applied,
            event: .armRestore(
                controlID: control.controlID,
                attemptID: UUID(),
                now: Date()
            )
        ).envelope
        let restored = try DeviceTransactionReducer.reduce(
            restoreMay,
            event: .observeRestore(
                controlID: control.controlID,
                state: baseline,
                now: Date()
            )
        ).envelope
        let conflicted = try DeviceTransactionReducer.reduce(
            applyMay,
            event: .observeApply(
                controlID: control.controlID,
                state: thirdParty,
                now: Date()
            )
        ).envelope

        let cases: [(
            DeviceTransactionEnvelope,
            DeviceTransactionWireState,
            DeviceTransactionControlPhase?
        )] = [
            (baselineEnvelope, baseline, nil),
            (baselineEnvelope, intended, .conflicted),
            (applyMay, baseline, .baselineVerified),
            (applyMay, intended, .appliedVerified),
            (applyMay, thirdParty, .conflicted),
            (applied, baseline, .restoredVerified),
            (applied, intended, nil),
            (applied, thirdParty, .conflicted),
            (restoreMay, baseline, .restoredVerified),
            (restoreMay, intended, .appliedVerified),
            (restoreMay, thirdParty, .conflicted),
            (restored, baseline, nil),
            (restored, intended, .conflicted),
        ]

        var verifiedCount = 0
        for (index, testCase) in cases.enumerated() {
            let reduction = try DeviceTransactionReducer.reduceRecoveryObservation(
                testCase.0,
                controlID: control.controlID,
                state: testCase.1
            )
            if let expectedPhase = testCase.2 {
                guard try reduction?.envelope.control(control.controlID).phase
                        == expectedPhase else {
                    throw DeviceTransactionSimulationError.recoveryClassificationFailed(index)
                }
            } else if reduction != nil {
                throw DeviceTransactionSimulationError.recoveryClassificationFailed(index)
            }
            verifiedCount += 1
        }

        do {
            _ = try DeviceTransactionReducer.reduceRecoveryObservation(
                conflicted,
                controlID: control.controlID,
                state: baseline
            )
            throw DeviceTransactionSimulationError.recoveryClassificationFailed(
                verifiedCount
            )
        } catch DeviceTransactionModelError.transactionConflicted {
            verifiedCount += 1
        }
        return verifiedCount
    }

    /// Runs apply and restore through every transport outcome class. Each case
    /// gets a fresh repository and transport so no state can leak between
    /// scenarios, and exact read-back remains the sole authority.
    private static func verifyTransportFaultMatrix(
        baselineJournal: DeviceStateJournal
    ) async throws -> Int {
        var verifiedCount = 0
        for scenario in SimulationFaultScenario.allCases {
            let envelope = try DeviceTransactionEnvelope(
                transactionID: UUID(),
                baselineJournal: baselineJournal
            )
            let repository = SimulationJournalRepository()
            let transport = SimulationTransactionTransport(
                repository: repository,
                session: session(for: envelope, epoch: UInt64(100 + verifiedCount)),
                initialStates: states(for: envelope)
            )
            let coordinator = DeviceTransactionCoordinator(
                repository: repository,
                transport: transport
            )
            _ = try await coordinator.installPreparedEnvelope(envelope)
            let control = try requiredFirstControl(envelope)
            let intended = try simulatedIntendedState(
                control.baseline,
                featureVersion: envelope.featureVersion
            )

            if scenario.isRestore {
                _ = try await coordinator.apply(
                    controlID: control.controlID,
                    intended: intended
                )
            }
            try await configure(
                scenario,
                transport: transport,
                baseline: control.baseline
            )

            var caughtError: Error?
            do {
                if scenario.isRestore {
                    _ = try await coordinator.restore(controlID: control.controlID)
                } else {
                    _ = try await coordinator.apply(
                        controlID: control.controlID,
                        intended: intended
                    )
                }
            } catch {
                caughtError = error
            }

            guard let final = try await coordinator.currentEnvelope(),
                  try scenario.matches(
                    error: caughtError,
                    control: final.control(control.controlID)
                  ) else {
                throw DeviceTransactionSimulationError.transportFaultScenarioFailed(
                    scenario.rawValue
                )
            }
            let expectedInvocationCount: Int
            if scenario == .applyThirdPartyConflict {
                // The exact-baseline preflight detects and durably records the
                // drift before an apply mutation can be armed.
                expectedInvocationCount = 0
            } else if scenario == .restoreThirdPartyConflict {
                // The exact intended-state restore preflight detects drift
                // after the initial apply and never emits a restore mutation.
                expectedInvocationCount = 1
            } else {
                expectedInvocationCount = scenario.isRestore ? 2 : 1
            }
            guard await transport.invocationCount() == expectedInvocationCount else {
                throw DeviceTransactionSimulationError.transportFaultScenarioFailed(
                    scenario.rawValue
                )
            }
            verifiedCount += 1
        }
        return verifiedCount
    }

    private static func configure(
        _ scenario: SimulationFaultScenario,
        transport: SimulationTransactionTransport,
        baseline: DeviceTransactionWireState
    ) async throws {
        switch scenario.behavior {
        case .mutateAndReturn:
            break
        case let behavior:
            await transport.enqueue(behavior)
        }
        if scenario.injectsReadFailure {
            await transport.failNextReads(
                1,
                afterSuccessfulReads: 1
            )
        }
        if scenario.injectsThirdPartyState {
            var raw = baseline.rawParameters
            raw[raw.count - 1] ^= 0x80
            await transport.setState(
                try DeviceTransactionWireState(rawParameters: raw)
            )
        }
    }

    /// Verifies the complete reconnect binding. A connection epoch may change
    /// between sessions, but the physical identity, optional firmware
    /// fingerprint, feature ID, and feature version must remain exact.
    private static func verifyReconnectIdentityBinding(
        baselineJournal: DeviceStateJournal
    ) throws -> Int {
        let envelope = try DeviceTransactionEnvelope(
            transactionID: UUID(),
            baselineJournal: baselineJournal
        )
        let identity = envelope.device
        func candidate(
            deviceID: String? = nil,
            vendorID: Int? = nil,
            productID: Int? = nil,
            transport: String? = nil,
            serialNumber: String?? = nil,
            locationID: Int?? = nil,
            firmwareIdentity: String?? = nil
        ) -> JournalDeviceIdentity {
            JournalDeviceIdentity(
                deviceID: deviceID ?? identity.deviceID,
                vendorID: vendorID ?? identity.vendorID,
                productID: productID ?? identity.productID,
                transport: transport ?? identity.transport,
                serialNumber: serialNumber ?? identity.serialNumber,
                locationID: locationID ?? identity.locationID,
                firmwareIdentity: firmwareIdentity ?? identity.firmwareIdentity
            )
        }

        let unexpectedFirmware = (identity.firmwareIdentity ?? "missing") + "-changed"
        let checks: [(DeviceTransactionSession, Bool)] = [
            (session(for: envelope, epoch: 1), true),
            (session(for: envelope, epoch: .max), true),
            (DeviceTransactionSession(
                device: candidate(deviceID: identity.deviceID + "-other"),
                featureID: envelope.featureID,
                featureVersion: envelope.featureVersion,
                featureIndex: 0x0A,
                connectionEpoch: 1
            ), false),
            (DeviceTransactionSession(
                device: candidate(vendorID: identity.vendorID ^ 1),
                featureID: envelope.featureID,
                featureVersion: envelope.featureVersion,
                featureIndex: 0x0A,
                connectionEpoch: 1
            ), false),
            (DeviceTransactionSession(
                device: candidate(productID: identity.productID ^ 1),
                featureID: envelope.featureID,
                featureVersion: envelope.featureVersion,
                featureIndex: 0x0A,
                connectionEpoch: 1
            ), false),
            (DeviceTransactionSession(
                device: candidate(transport: identity.transport + "-other"),
                featureID: envelope.featureID,
                featureVersion: envelope.featureVersion,
                featureIndex: 0x0A,
                connectionEpoch: 1
            ), false),
            (DeviceTransactionSession(
                device: candidate(serialNumber: .some("ANOTHER-ERGO")),
                featureID: envelope.featureID,
                featureVersion: envelope.featureVersion,
                featureIndex: 0x0A,
                connectionEpoch: 1
            ), false),
            (DeviceTransactionSession(
                device: candidate(locationID: .some((identity.locationID ?? 0) + 1)),
                featureID: envelope.featureID,
                featureVersion: envelope.featureVersion,
                featureIndex: 0x0A,
                connectionEpoch: 1
            ), false),
            (DeviceTransactionSession(
                device: candidate(firmwareIdentity: .some(unexpectedFirmware)),
                featureID: envelope.featureID,
                featureVersion: envelope.featureVersion,
                featureIndex: 0x0A,
                connectionEpoch: 1
            ), false),
            (DeviceTransactionSession(
                device: identity,
                featureID: envelope.featureID ^ 1,
                featureVersion: envelope.featureVersion,
                featureIndex: 0x0A,
                connectionEpoch: 1
            ), false),
            (DeviceTransactionSession(
                device: identity,
                featureID: envelope.featureID,
                featureVersion: envelope.featureVersion &+ 1,
                featureIndex: 0x0A,
                connectionEpoch: 1
            ), false),
        ]

        for (index, check) in checks.enumerated() {
            guard envelope.isSafeSessionMatch(check.0) == check.1 else {
                throw DeviceTransactionSimulationError.reconnectIdentityCheckFailed(index)
            }
        }

        let journalChecks: [(JournalDeviceIdentity, Bool)] = [
            (identity, true),
            (candidate(locationID: .some((identity.locationID ?? 0) + 1)), false),
            (candidate(firmwareIdentity: .some(unexpectedFirmware)), false),
        ]
        for (offset, check) in journalChecks.enumerated() {
            guard identity.isSafeRecoveryMatch(check.0) == check.1 else {
                throw DeviceTransactionSimulationError.reconnectIdentityCheckFailed(
                    checks.count + offset
                )
            }
        }
        return checks.count + journalChecks.count
    }

    /// Attempts a one-byte change at every immutable wire position and requires
    /// the reducer to reject it before any write-ahead effect can be produced.
    private static func verifyImmutableWireBytes(
        baselineJournal: DeviceStateJournal
    ) throws -> Int {
        let envelope = try DeviceTransactionEnvelope(
            transactionID: UUID(),
            baselineJournal: baselineJournal
        )
        let control = try requiredFirstControl(envelope)
        let mutableIndexes: Set<Int> = envelope.featureVersion >= 4 ? [2, 5] : [2]
        var verifiedCount = 0

        for index in control.baseline.rawParameters.indices
            where !mutableIndexes.contains(index) {
            var raw = control.baseline.rawParameters
            raw[index] ^= 0xA5
            let unsafeState = try DeviceTransactionWireState(rawParameters: raw)
            do {
                _ = try DeviceTransactionReducer.reduce(
                    envelope,
                    event: .armApply(
                        controlID: control.controlID,
                        intended: unsafeState,
                        attemptID: UUID(),
                        now: Date()
                    )
                )
                throw DeviceTransactionSimulationError.immutableWireByteCheckFailed(index)
            } catch DeviceTransactionSimulationError.immutableWireByteCheckFailed {
                throw DeviceTransactionSimulationError.immutableWireByteCheckFailed(index)
            } catch {
                verifiedCount += 1
            }
        }

        let safeState = try simulatedIntendedState(
            control.baseline,
            featureVersion: envelope.featureVersion
        )
        guard safeState.preservesNonFlagBytes(
            of: control.baseline,
            featureVersion: envelope.featureVersion
        ) else {
            throw DeviceTransactionSimulationError.immutableWireByteCheckFailed(-1)
        }
        return verifiedCount
    }

    private static func simulatedIntendedState(
        _ baseline: DeviceTransactionWireState,
        featureVersion: UInt8 = 3
    ) throws -> DeviceTransactionWireState {
        try baseline.replacingRawFlags(
            baseline.rawFlags(featureVersion: featureVersion) ^ 0x01,
            featureVersion: featureVersion
        )
    }

    private static func states(
        for envelope: DeviceTransactionEnvelope
    ) -> [UInt16: DeviceTransactionWireState] {
        Dictionary(uniqueKeysWithValues: envelope.controls.map {
            ($0.controlID, $0.baseline)
        })
    }

    private static func session(
        for envelope: DeviceTransactionEnvelope,
        epoch: UInt64
    ) -> DeviceTransactionSession {
        DeviceTransactionSession(
            device: envelope.device,
            featureID: envelope.featureID,
            featureVersion: envelope.featureVersion,
            featureIndex: 0x0A,
            connectionEpoch: epoch
        )
    }

    private static func requiredFirstControl(
        _ envelope: DeviceTransactionEnvelope
    ) throws -> DeviceTransactionControl {
        guard let control = envelope.controls.first else {
            throw DeviceTransactionModelError.emptyControlSet
        }
        return control
    }
}

private actor SimulationJournalRepository: DeviceTransactionJournalRepository {
    private var envelope: DeviceTransactionEnvelope?
    private var commits = 0

    func loadValidated() async throws -> DeviceTransactionEnvelope? {
        try envelope?.validate()
        return envelope
    }

    func commit(
        _ next: DeviceTransactionEnvelope,
        expectedRevision: UInt64?
    ) async throws -> DeviceTransactionDurableCommitReceipt {
        let actualRevision = envelope?.revision
        guard actualRevision == expectedRevision else {
            throw DeviceTransactionRepositoryError.compareAndSwapMismatch(
                expected: expectedRevision,
                actual: actualRevision
            )
        }
        try next.validate()
        envelope = next
        commits += 1
        return DeviceTransactionDurableCommitReceipt(
            transactionID: next.transactionID,
            revision: next.revision,
            sha256: "isolated-simulation-revision-\(next.revision)"
        )
    }

    func commitCount() -> Int { commits }
}

private enum SimulationMutationBehavior: Sendable {
    case mutateAndReturn
    case returnWithoutMutation
    case mutateThenThrow
    case rejectBeforeDispatch
    case throwUnknownWithoutMutation
    case mutateThenChangeEpoch
}

private enum SimulationFaultScenario: String, CaseIterable, Sendable {
    case applySuccess
    case applyNoMutation
    case applyRejectedBeforeDispatch
    case applyUnknownWithoutMutation
    case applyMutatedThenUnknown
    case applyReadBackFailure
    case applyEpochChanged
    case applyThirdPartyConflict
    case restoreSuccess
    case restoreNoMutation
    case restoreRejectedBeforeDispatch
    case restoreUnknownWithoutMutation
    case restoreMutatedThenUnknown
    case restoreReadBackFailure
    case restoreEpochChanged
    case restoreThirdPartyConflict

    var isRestore: Bool { rawValue.hasPrefix("restore") }

    var behavior: SimulationMutationBehavior {
        switch self {
        case .applySuccess, .applyReadBackFailure,
             .restoreSuccess, .restoreReadBackFailure:
            .mutateAndReturn
        case .applyNoMutation, .applyThirdPartyConflict,
             .restoreNoMutation, .restoreThirdPartyConflict:
            .returnWithoutMutation
        case .applyRejectedBeforeDispatch, .restoreRejectedBeforeDispatch:
            .rejectBeforeDispatch
        case .applyUnknownWithoutMutation, .restoreUnknownWithoutMutation:
            .throwUnknownWithoutMutation
        case .applyMutatedThenUnknown, .restoreMutatedThenUnknown:
            .mutateThenThrow
        case .applyEpochChanged, .restoreEpochChanged:
            .mutateThenChangeEpoch
        }
    }

    var injectsReadFailure: Bool {
        self == .applyReadBackFailure || self == .restoreReadBackFailure
    }

    var injectsThirdPartyState: Bool {
        self == .applyThirdPartyConflict || self == .restoreThirdPartyConflict
    }

    func matches(
        error: Error?,
        control: DeviceTransactionControl
    ) throws -> Bool {
        switch self {
        case .applySuccess, .applyMutatedThenUnknown:
            return error == nil && control.phase == .appliedVerified
        case .applyNoMutation, .applyRejectedBeforeDispatch,
             .applyUnknownWithoutMutation:
            return error as? DeviceTransactionCoordinatorError
                    == .applyNotObserved(control.controlID)
                && control.phase == .baselineVerified
        case .applyReadBackFailure:
            guard case .readBackUnresolved(control.controlID, _)
                    = error as? DeviceTransactionCoordinatorError else {
                return false
            }
            return control.phase == .applyMayHaveOccurred
                && control.attempts.last?.outcome == .outcomeUnknown
        case .applyEpochChanged:
            return error as? DeviceTransactionCoordinatorError == .sessionChanged
                && control.phase == .applyMayHaveOccurred
                && control.attempts.last?.outcome == .outcomeUnknown
        case .applyThirdPartyConflict:
            return error as? DeviceTransactionCoordinatorError
                    == .conflicted(control.controlID)
                && control.phase == .conflicted
        case .restoreSuccess, .restoreMutatedThenUnknown:
            return error == nil && control.phase == .restoredVerified
        case .restoreNoMutation, .restoreRejectedBeforeDispatch:
            return error as? DeviceTransactionCoordinatorError
                    == .restoreNotObserved(control.controlID)
                && control.phase == .appliedVerified
        case .restoreUnknownWithoutMutation:
            return error as? DeviceTransactionCoordinatorError
                    == .restoreNotObserved(control.controlID)
                && control.phase == .restoreMayHaveOccurred
                && control.attempts.last?.outcome == .outcomeUnknown
                && control.attempts.last?.kind == .restore
        case .restoreReadBackFailure:
            guard case .readBackUnresolved(control.controlID, _)
                    = error as? DeviceTransactionCoordinatorError else {
                return false
            }
            return control.phase == .restoreMayHaveOccurred
                && control.attempts.last?.outcome == .outcomeUnknown
        case .restoreEpochChanged:
            return error as? DeviceTransactionCoordinatorError == .sessionChanged
                && control.phase == .restoreMayHaveOccurred
                && control.attempts.last?.outcome == .outcomeUnknown
        case .restoreThirdPartyConflict:
            return error as? DeviceTransactionCoordinatorError
                    == .conflicted(control.controlID)
                && control.phase == .conflicted
        }
    }
}

private actor SimulationTransactionTransport: DeviceTransactionEffectTransport {
    private let repository: any DeviceTransactionJournalRepository
    private var session: DeviceTransactionSession
    private var states: [UInt16: DeviceTransactionWireState]
    private var mutations = 0
    private var invocations = 0
    private var behaviors: [SimulationMutationBehavior] = []
    private var readsToFail = 0
    private var successfulReadsBeforeFailure = 0

    init(
        repository: any DeviceTransactionJournalRepository,
        session: DeviceTransactionSession,
        initialStates: [UInt16: DeviceTransactionWireState]
    ) {
        self.repository = repository
        self.session = session
        states = initialStates
    }

    func currentSession() async throws -> DeviceTransactionSession { session }

    func prepare(
        _ proposed: DeviceTransactionMutation,
        expectedSession: DeviceTransactionSession,
        expectedCommittedRevision: UInt64
    ) async throws -> DeviceTransactionPreparedInvocation {
        DeviceTransactionPreparedInvocation(
            mutation: proposed,
            expectedSession: expectedSession,
            expectedCommittedRevision: expectedCommittedRevision
        )
    }

    func abandon(
        _ prepared: DeviceTransactionPreparedInvocation,
        disposition: DeviceTransactionPreparationDisposition
    ) async {
        _ = prepared
        _ = disposition
    }

    func invoke(
        _ prepared: DeviceTransactionPreparedInvocation,
        authorization: DeviceTransactionDurableCommitReceipt
    ) async throws -> DeviceTransactionInvocationEvidence? {
        let mutation = prepared.mutation
        let expectedSession = prepared.expectedSession
        guard expectedSession == session,
              let durable = try await repository.loadValidated(),
              durable.transactionID == mutation.transactionID,
              durable.transactionID == authorization.transactionID,
              durable.revision == authorization.revision else {
            throw DeviceTransactionSimulationError.invalidAuthorization
        }
        let control = try durable.control(mutation.controlID)
        let requiredPhase: DeviceTransactionControlPhase =
            mutation.kind == .apply ? .applyMayHaveOccurred : .restoreMayHaveOccurred
        guard control.phase == requiredPhase,
              control.activeAttemptID == mutation.attemptID else {
            throw DeviceTransactionSimulationError.invalidAuthorization
        }
        invocations += 1
        let behavior = behaviors.isEmpty ? .mutateAndReturn : behaviors.removeFirst()
        switch behavior {
        case .mutateAndReturn:
            states[mutation.controlID] = mutation.state
            mutations += 1
        case .returnWithoutMutation:
            break
        case .mutateThenThrow:
            states[mutation.controlID] = mutation.state
            mutations += 1
            throw DeviceTransactionTransportInvocationError.outcomeUnknown(
                "isolated reply loss"
            )
        case .rejectBeforeDispatch:
            throw DeviceTransactionTransportInvocationError.rejectedBeforeDispatch(
                "isolated pre-dispatch rejection"
            )
        case .throwUnknownWithoutMutation:
            throw DeviceTransactionTransportInvocationError.outcomeUnknown(
                "isolated unknown outcome"
            )
        case .mutateThenChangeEpoch:
            states[mutation.controlID] = mutation.state
            mutations += 1
            session = DeviceTransactionSession(
                device: session.device,
                featureID: session.featureID,
                featureVersion: session.featureVersion,
                featureIndex: 0x0A,
                connectionEpoch: session.connectionEpoch + 1
            )
        }
        return nil
    }

    func readReporting(
        controlID: UInt16,
        expectedSession: DeviceTransactionSession
    ) async throws -> DeviceTransactionWireState {
        guard expectedSession == session else {
            throw DeviceTransactionSimulationError.invalidAuthorization
        }
        if readsToFail > 0, successfulReadsBeforeFailure > 0 {
            successfulReadsBeforeFailure -= 1
        } else if readsToFail > 0 {
            readsToFail -= 1
            throw DeviceTransactionSimulationError.missingState(controlID)
        }
        guard let state = states[controlID] else {
            throw DeviceTransactionSimulationError.missingState(controlID)
        }
        return state
    }

    func mutationCount() -> Int { mutations }
    func invocationCount() -> Int { invocations }
    func enqueue(_ behavior: SimulationMutationBehavior) { behaviors.append(behavior) }
    func failNextReads(_ count: Int, afterSuccessfulReads: Int = 0) {
        readsToFail = count
        successfulReadsBeforeFailure = afterSuccessfulReads
    }
    func setState(_ state: DeviceTransactionWireState) { states[state.controlID] = state }
}
