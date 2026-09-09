import Foundation
import Testing
@testable import MXErgoHIDPP

@Test func durableTransactionRepositoryCommitsWithCASAndReopensExactly() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("transaction-v3.json")
    let repository = DurableDeviceTransactionFileRepository(fileURL: fileURL)
    let envelope = try transactionEnvelope()

    let initialReceipt = try await repository.commit(envelope, expectedRevision: nil)
    #expect(initialReceipt.transactionID == envelope.transactionID)
    #expect(initialReceipt.revision == 0)
    #expect(initialReceipt.sha256.count == 64)

    let intended = try intendedState(for: envelope, controlID: 0x0050)
    let reduction = try DeviceTransactionReducer.reduce(
        envelope,
        event: .armApply(
            controlID: 0x0050,
            intended: intended,
            attemptID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            now: Date(timeIntervalSince1970: 2_000)
        )
    )
    let receipt = try await repository.commit(
        reduction.envelope,
        expectedRevision: reduction.previousRevision
    )
    #expect(receipt.revision == 1)

    let reopened = DurableDeviceTransactionFileRepository(fileURL: fileURL)
    #expect(try await reopened.loadValidated() == reduction.envelope)
    await #expect(throws: DeviceTransactionRepositoryError.compareAndSwapMismatch(
        expected: 0,
        actual: 1
    )) {
        try await reopened.commit(reduction.envelope, expectedRevision: 0)
    }
}

@Test func decodedSchemaThreeJournalRejectsImpossiblePhaseEvidence() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("transaction-v3.json")
    let repository = DurableDeviceTransactionFileRepository(fileURL: fileURL)
    _ = try await repository.commit(try transactionEnvelope(), expectedRevision: nil)

    let data = try Data(contentsOf: fileURL)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var controls = try #require(object["controls"] as? [[String: Any]])
    controls[0]["phase"] = DeviceTransactionControlPhase.appliedVerified.rawValue
    object["controls"] = controls
    try JSONSerialization.data(withJSONObject: object).write(to: fileURL, options: .atomic)

    await #expect(throws: DeviceTransactionModelError.invalidPhaseState(0x0050)) {
        try await repository.loadValidated()
    }
}

@Test func durableRepositoryFaultsAtEveryCommitBoundaryWithoutProducingInvalidJSON() async throws {
    enum InjectedFailure: Error { case boundary(DeviceTransactionCommitBoundary) }

    for boundary in DeviceTransactionCommitBoundary.allCases {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("transaction-v3.json")
        let initialRepository = DurableDeviceTransactionFileRepository(fileURL: fileURL)
        let envelope = try transactionEnvelope()
        _ = try await initialRepository.commit(envelope, expectedRevision: nil)

        let intended = try intendedState(for: envelope, controlID: 0x0050)
        let reduction = try DeviceTransactionReducer.reduce(
            envelope,
            event: .armApply(
                controlID: 0x0050,
                intended: intended,
                attemptID: UUID(),
                now: Date(timeIntervalSince1970: 3_000)
            )
        )
        let faultingRepository = DurableDeviceTransactionFileRepository(
            fileURL: fileURL
        ) { reachedBoundary in
            if reachedBoundary == boundary {
                throw InjectedFailure.boundary(boundary)
            }
        }

        do {
            _ = try await faultingRepository.commit(
                reduction.envelope,
                expectedRevision: reduction.previousRevision
            )
            Issue.record("Expected injected failure at \(boundary.rawValue)")
        } catch {}

        let reopened = DurableDeviceTransactionFileRepository(fileURL: fileURL)
        let durable = try #require(try await reopened.loadValidated())
        let replacementWasVisible: Bool
        switch boundary {
        case .beforeTemporaryWrite, .afterTemporaryWrite, .afterTemporaryFullSync:
            replacementWasVisible = false
        case .afterAtomicReplace, .afterDirectorySync, .beforeReceiptReturn:
            replacementWasVisible = true
        }
        #expect(durable.revision == (replacementWasVisible ? 1 : 0))
        #expect(try durable.control(0x0050).phase == (
            replacementWasVisible ? .applyMayHaveOccurred : .baselineVerified
        ))

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }
}

@Test(.enabled(if: crashHarnessIsAvailable, missingCrashHarness))
func hardKilledWriterLeavesRecoverableWriteAheadJournalForFreshCoordinator() async throws {
    let harnessPath = try #require(crashHarnessPath)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let baselineURL = directory.appendingPathComponent("baseline-v2.json")
    let transactionURL = directory.appendingPathComponent("transaction-v3.json")
    let baseline = try transactionBaselineJournal(controlCount: 9)
    try DeviceStateJournalStore(fileURL: baselineURL).save(baseline)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: harnessPath)
    process.arguments = [
        "crash-after-apply-wal",
        baselineURL.path,
        transactionURL.path,
    ]
    let completion = TestProcessExit.observe(process)
    try process.run()
    await completion.wait()

    #expect(process.terminationReason == .uncaughtSignal)
    #expect(process.terminationStatus == SIGKILL)

    let repository = DurableDeviceTransactionFileRepository(fileURL: transactionURL)
    let crashedEnvelope = try #require(try await repository.loadValidated())
    #expect(crashedEnvelope.revision == 1)
    #expect(crashedEnvelope.status == .recoveryRequired)
    #expect(crashedEnvelope.dirtyControlIDs == [0x0050])
    #expect(try crashedEnvelope.control(0x0050).phase == .applyMayHaveOccurred)

    let transport = ScriptedTransactionTransport(
        repository: repository,
        session: transactionSession(),
        initialStates: transactionStates(crashedEnvelope)
    )
    let restartedCoordinator = DeviceTransactionCoordinator(
        repository: repository,
        transport: transport
    )
    let report = try await restartedCoordinator.recoverExplicitly()

    #expect(report.inspectedControlIDs == [0x0050])
    #expect(report.restoredControlIDs.isEmpty)
    #expect(report.finalStatus == .abortedClean)
    #expect(await transport.invocationRecords().isEmpty)
    let recovered = try #require(try await repository.loadValidated())
    #expect(recovered.status == .abortedClean)
    #expect(try recovered.control(0x0050).phase == .baselineVerified)
}

@Test func recoveryReducerClassifiesEveryPersistedPhaseByExactWireObservation() throws {
    let baselineEnvelope = try transactionEnvelope()
    let controlID: UInt16 = 0x0050
    let baseline = try baselineEnvelope.control(controlID).baseline
    let intended = try intendedState(for: baselineEnvelope, controlID: controlID)
    let thirdParty = try reportingState(controlID: controlID, flags: 0x10)

    let applyMay = try DeviceTransactionReducer.reduce(
        baselineEnvelope,
        event: .armApply(
            controlID: controlID,
            intended: intended,
            attemptID: UUID(),
            now: Date()
        )
    ).envelope
    let applied = try DeviceTransactionReducer.reduce(
        applyMay,
        event: .observeApply(controlID: controlID, state: intended, now: Date())
    ).envelope
    let restoreMay = try DeviceTransactionReducer.reduce(
        applied,
        event: .armRestore(controlID: controlID, attemptID: UUID(), now: Date())
    ).envelope
    let restored = try DeviceTransactionReducer.reduce(
        restoreMay,
        event: .observeRestore(controlID: controlID, state: baseline, now: Date())
    ).envelope
    let conflicted = try DeviceTransactionReducer.reduce(
        applyMay,
        event: .observeApply(controlID: controlID, state: thirdParty, now: Date())
    ).envelope

    let cases: [(DeviceTransactionEnvelope, DeviceTransactionWireState, DeviceTransactionControlPhase?)] = [
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

    for (envelope, observation, expectedPhase) in cases {
        let reduction = try DeviceTransactionReducer.reduceRecoveryObservation(
            envelope,
            controlID: controlID,
            state: observation
        )
        if let expectedPhase {
            #expect(try reduction?.envelope.control(controlID).phase == expectedPhase)
        } else {
            #expect(reduction == nil)
        }
    }
    #expect(throws: DeviceTransactionModelError.transactionConflicted) {
        try DeviceTransactionReducer.reduceRecoveryObservation(
            conflicted,
            controlID: controlID,
            state: baseline
        )
    }
}

@Test func reducerRejectsEveryNonFlagWireByteMutation() throws {
    let envelope = try transactionEnvelope()
    let controlID: UInt16 = 0x0050
    let baseline = try envelope.control(controlID).baseline
    let mutableIndexes: Set<Int> = [2]

    for index in baseline.rawParameters.indices where !mutableIndexes.contains(index) {
        var raw = baseline.rawParameters
        raw[index] ^= 0xA5
        let unsafe = try DeviceTransactionWireState(rawParameters: raw)
        do {
            _ = try DeviceTransactionReducer.reduce(
                envelope,
                event: .armApply(
                    controlID: controlID,
                    intended: unsafe,
                    attemptID: UUID(),
                    now: Date()
                )
            )
            Issue.record("Reducer accepted immutable byte index \(index)")
        } catch {}
    }

    let safe = try baseline.replacingRawFlags(1, featureVersion: 3)
    #expect(safe.preservesNonFlagBytes(of: baseline, featureVersion: 3))
    let reduction = try DeviceTransactionReducer.reduce(
        envelope,
        event: .armApply(
            controlID: controlID,
            intended: safe,
            attemptID: UUID(),
            now: Date()
        )
    )
    #expect(try reduction.envelope.control(controlID).intended == safe)
}

@Test func rawFlagReplacementPreservesEveryOtherByteForFeatureVersionsThreeAndFour() throws {
    let original = try DeviceTransactionWireState(rawParameters: [
        0x00, 0x50, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66,
        0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE,
    ])
    let versionThree = try original.replacingRawFlags(0xA5C3, featureVersion: 3)
    let versionFour = try original.replacingRawFlags(0xA5C3, featureVersion: 4)

    #expect(versionThree.rawParameters[2] == 0xC3)
    #expect(versionThree.rawParameters[5] == original.rawParameters[5])
    #expect(versionThree.preservesNonFlagBytes(of: original, featureVersion: 3))
    #expect(versionFour.rawParameters[2] == 0xC3)
    #expect(versionFour.rawParameters[5] == 0xA5)
    #expect(versionFour.preservesNonFlagBytes(of: original, featureVersion: 4))
}

@Test func transactionSessionBindingRejectsEveryReconnectIdentityMismatch() throws {
    let envelope = try transactionEnvelope()
    let exact = transactionSession()
    #expect(envelope.isSafeSessionMatch(exact))
    #expect(envelope.isSafeSessionMatch(DeviceTransactionSession(
        device: exact.device,
        featureID: exact.featureID,
        featureVersion: exact.featureVersion,
        featureIndex: 0x0A,
        connectionEpoch: exact.connectionEpoch + 1
    )))

    let wrongFirmware = JournalDeviceIdentity(
        deviceID: exact.device.deviceID,
        vendorID: exact.device.vendorID,
        productID: exact.device.productID,
        transport: exact.device.transport,
        serialNumber: exact.device.serialNumber,
        locationID: exact.device.locationID,
        firmwareIdentity: "different-firmware"
    )
    #expect(!envelope.isSafeSessionMatch(DeviceTransactionSession(
        device: wrongFirmware,
        featureID: exact.featureID,
        featureVersion: exact.featureVersion,
        featureIndex: 0x0A,
        connectionEpoch: exact.connectionEpoch
    )))

    let wrongLocation = JournalDeviceIdentity(
        deviceID: exact.device.deviceID,
        vendorID: exact.device.vendorID,
        productID: exact.device.productID,
        transport: exact.device.transport,
        serialNumber: exact.device.serialNumber,
        locationID: (exact.device.locationID ?? 0) + 1,
        firmwareIdentity: exact.device.firmwareIdentity
    )
    #expect(!envelope.isSafeSessionMatch(DeviceTransactionSession(
        device: wrongLocation,
        featureID: exact.featureID,
        featureVersion: exact.featureVersion,
        featureIndex: 0x0A,
        connectionEpoch: exact.connectionEpoch
    )))
}

@Test func coordinatorRequiresDurableWriteAheadReceiptBeforeEveryMutation() async throws {
    let envelope = try transactionEnvelope()
    let repository = ScriptedTransactionRepository()
    let transport = ScriptedTransactionTransport(
        repository: repository,
        session: transactionSession(),
        initialStates: transactionStates(envelope)
    )
    let coordinator = DeviceTransactionCoordinator(
        repository: repository,
        transport: transport
    )
    _ = try await coordinator.installPreparedEnvelope(envelope)

    let intended = try intendedState(for: envelope, controlID: 0x0050)
    let applied = try await coordinator.apply(controlID: 0x0050, intended: intended)
    #expect(try applied.control(0x0050).phase == .appliedVerified)

    let restored = try await coordinator.restore(controlID: 0x0050)
    #expect(try restored.control(0x0050).phase == .restoredVerified)
    #expect(restored.status == .completed)

    let invocations = await transport.invocationRecords()
    #expect(invocations.map(\.kind) == [.apply, .restore])
    #expect(invocations.map(\.authorizedRevision) == [1, 3])
    #expect(invocations.map(\.durablePhase) == [
        .applyMayHaveOccurred,
        .restoreMayHaveOccurred,
    ])
}

@Test func coordinatorAbandonsPreparedReservationsAccordingToWriteAheadVisibility() async throws {
    let invalid = try await transactionTestSetup()
    await invalid.transport.enqueuePreparation(.invalidRevision)
    let invalidBefore = try #require(await invalid.repository.snapshot())
    await #expect(throws: DeviceTransactionCoordinatorError.invalidPreparedInvocation) {
        try await invalid.coordinator.apply(
            controlID: 0x0050,
            intended: try intendedState(for: invalid.envelope, controlID: 0x0050)
        )
    }
    #expect(await invalid.transport.abandonmentDispositions() == [.invalidPreparation])
    #expect(await invalid.repository.snapshot() == invalidBefore)
    #expect(await invalid.transport.invocationRecords().isEmpty)

    let changedSession = try await transactionTestSetup()
    await changedSession.transport.enqueuePreparation(.changeEpochBeforeReturn)
    let sessionBefore = try #require(await changedSession.repository.snapshot())
    await #expect(throws: DeviceTransactionCoordinatorError.sessionChanged) {
        try await changedSession.coordinator.apply(
            controlID: 0x0050,
            intended: try intendedState(
                for: changedSession.envelope,
                controlID: 0x0050
            )
        )
    }
    #expect(await changedSession.transport.abandonmentDispositions()
        == [.discardedBeforeWriteAhead])
    #expect(await changedSession.repository.snapshot() == sessionBefore)
    #expect(await changedSession.transport.invocationRecords().isEmpty)

    let ambiguous = try await transactionTestSetup(failBeforeCommitCalls: [2])
    let ambiguousBefore = try #require(await ambiguous.repository.snapshot())
    await #expect(throws: ScriptedTransactionRepository.ScriptedError.failedBeforeCommit) {
        try await ambiguous.coordinator.apply(
            controlID: 0x0050,
            intended: try intendedState(for: ambiguous.envelope, controlID: 0x0050)
        )
    }
    #expect(await ambiguous.transport.abandonmentDispositions()
        == [.writeAheadVisibilityUnknown])
    #expect(await ambiguous.repository.snapshot() == ambiguousBefore)
    #expect(await ambiguous.transport.invocationRecords().isEmpty)
}

@Test func preDispatchRejectionBecomesCleanOnlyAfterExactBaselineRead() async throws {
    let setup = try await transactionTestSetup()
    await setup.transport.enqueue(.rejectBeforeDispatch("scripted rejection"))
    let intended = try intendedState(for: setup.envelope, controlID: 0x0050)

    await #expect(throws: DeviceTransactionCoordinatorError.applyNotObserved(0x0050)) {
        try await setup.coordinator.apply(controlID: 0x0050, intended: intended)
    }
    let committed = try #require(await setup.repository.snapshot())
    let control = try committed.control(0x0050)
    #expect(control.phase == .baselineVerified)
    #expect(control.appliedObservation == control.baseline)
    #expect(control.attempts.last?.outcome == .observedNoMutation)
    #expect(!committed.needsRecoveryAttention)
}

@Test func mutationThenTransportErrorIsResolvedOnlyByExactReadBack() async throws {
    let setup = try await transactionTestSetup()
    await setup.transport.enqueue(.mutateThenThrow("reply lost"))
    let intended = try intendedState(for: setup.envelope, controlID: 0x0050)

    let committed = try await setup.coordinator.apply(
        controlID: 0x0050,
        intended: intended
    )
    let control = try committed.control(0x0050)
    #expect(control.phase == .appliedVerified)
    #expect(control.appliedObservation == intended)
}

@Test func unresolvedApplySurvivesRestartAndExplicitRecoveryOnlyRestoresDirtyControl() async throws {
    let setup = try await transactionTestSetup(controlCount: 2)
    await setup.transport.enqueue(.mutateAndReturn)
    await setup.transport.failNextReads(1, afterSuccessfulReads: 1)
    let intended = try intendedState(for: setup.envelope, controlID: 0x0050)

    do {
        _ = try await setup.coordinator.apply(controlID: 0x0050, intended: intended)
        Issue.record("Expected the injected read-back failure")
    } catch let error as DeviceTransactionCoordinatorError {
        guard case .readBackUnresolved(0x0050, _) = error else {
            Issue.record("Unexpected coordinator error: \(error)")
            return
        }
    }
    let dirty = try #require(await setup.repository.snapshot())
    #expect(dirty.dirtyControlIDs == [0x0050])
    #expect(try dirty.control(0x0051).phase == .baselineVerified)

    // A fresh coordinator represents a process restart. Recovery reads the
    // dirty control, classifies the intended state, and arms one restore only.
    let restarted = DeviceTransactionCoordinator(
        repository: setup.repository,
        transport: setup.transport
    )
    let report = try await restarted.recoverExplicitly()
    #expect(report.inspectedControlIDs == [0x0050])
    #expect(report.restoredControlIDs == [0x0050])
    #expect(report.finalStatus == .completed)

    let invocations = await setup.transport.invocationRecords()
    #expect(invocations.map(\.kind) == [.apply, .restore])
    #expect(invocations.allSatisfy { $0.controlID == 0x0050 })
}

@Test func ambiguousCommitAfterWriteAheadNeverAuthorizesTransport() async throws {
    let envelope = try transactionEnvelope()
    let repository = ScriptedTransactionRepository(failAfterCommitCalls: [2])
    let transport = ScriptedTransactionTransport(
        repository: repository,
        session: transactionSession(),
        initialStates: transactionStates(envelope)
    )
    let coordinator = DeviceTransactionCoordinator(
        repository: repository,
        transport: transport
    )
    _ = try await coordinator.installPreparedEnvelope(envelope)
    let intended = try intendedState(for: envelope, controlID: 0x0050)

    do {
        _ = try await coordinator.apply(controlID: 0x0050, intended: intended)
        Issue.record("Expected the ambiguous commit failure")
    } catch {}

    #expect(await transport.invocationRecords().isEmpty)
    let committed = try #require(await repository.snapshot())
    #expect(try committed.control(0x0050).phase == .applyMayHaveOccurred)
}

@Test func repositoryFailureBeforeWriteAheadNeverAuthorizesTransportOrDirtiesJournal() async throws {
    let envelope = try transactionEnvelope()
    let repository = ScriptedTransactionRepository(failBeforeCommitCalls: [2])
    let transport = ScriptedTransactionTransport(
        repository: repository,
        session: transactionSession(),
        initialStates: transactionStates(envelope)
    )
    let coordinator = DeviceTransactionCoordinator(
        repository: repository,
        transport: transport
    )
    _ = try await coordinator.installPreparedEnvelope(envelope)

    do {
        _ = try await coordinator.apply(
            controlID: 0x0050,
            intended: intendedState(for: envelope, controlID: 0x0050)
        )
        Issue.record("Expected the pre-commit repository failure")
    } catch {}

    #expect(await transport.invocationRecords().isEmpty)
    #expect(await repository.snapshot() == envelope)
}

@Test func crashedRestoreAttemptIsObservedAndNeverInvokedTwice() async throws {
    let setup = try await transactionTestSetup()
    let intended = try intendedState(for: setup.envelope, controlID: 0x0050)
    let applied = try await setup.coordinator.apply(controlID: 0x0050, intended: intended)
    let abandonedAttemptID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    let armedRestore = try DeviceTransactionReducer.reduce(
        applied,
        event: .armRestore(
            controlID: 0x0050,
            attemptID: abandonedAttemptID,
            now: Date(timeIntervalSince1970: 4_000)
        )
    )
    _ = try await setup.repository.commit(
        armedRestore.envelope,
        expectedRevision: armedRestore.previousRevision
    )

    let restarted = DeviceTransactionCoordinator(
        repository: setup.repository,
        transport: setup.transport
    )
    let report = try await restarted.recoverExplicitly()
    #expect(report.restoredControlIDs == [0x0050])
    let invocations = await setup.transport.invocationRecords()
    #expect(invocations.map(\.kind) == [.apply, .restore])
    #expect(!invocations.map(\.attemptID).contains(abandonedAttemptID))

    let final = try #require(await setup.repository.snapshot())
    let restoreAttempts = try final.control(0x0050).attempts.filter { $0.kind == .restore }
    #expect(restoreAttempts.count == 2)
    #expect(restoreAttempts[0].id == abandonedAttemptID)
    #expect(restoreAttempts[0].outcome == .observedNoMutation)
    #expect(restoreAttempts[1].outcome == .verified)
}

@Test func recoverDoesNotRetryAnOutcomeUnknownRestoreSET() async throws {
    let setup = try await transactionTestSetup()
    let intended = try intendedState(for: setup.envelope, controlID: 0x0050)
    _ = try await setup.coordinator.apply(controlID: 0x0050, intended: intended)
    await setup.transport.enqueue(.throwUnknownWithoutMutation("restore lost"))
    await #expect(throws: DeviceTransactionCoordinatorError.restoreNotObserved(0x0050)) {
        try await setup.coordinator.restore(controlID: 0x0050)
    }
    let interrupted = try #require(await setup.repository.snapshot())
    #expect(try interrupted.control(0x0050).phase == .restoreMayHaveOccurred)
    #expect(interrupted.hasAmbiguousRestoreSET)

    let restarted = DeviceTransactionCoordinator(
        repository: setup.repository,
        transport: setup.transport
    )
    await #expect(throws: DeviceTransactionCoordinatorError.ambiguousRestoreSET(0x0050)) {
        try await restarted.recoverExplicitly()
    }
    #expect(await setup.transport.invocationRecords().map(\.kind) == [.apply, .restore])
    let final = try #require(await setup.repository.snapshot())
    #expect(final.hasAmbiguousRestoreSET)
    #expect(try final.control(0x0050).attempts.filter { $0.kind == .restore }.count == 1)
}

@Test func connectionEpochChangeAfterInvocationLeavesDirtyJournalAndDoesNotRetry() async throws {
    let setup = try await transactionTestSetup()
    await setup.transport.enqueue(.mutateThenChangeEpoch)
    let intended = try intendedState(for: setup.envelope, controlID: 0x0050)

    await #expect(throws: DeviceTransactionCoordinatorError.sessionChanged) {
        try await setup.coordinator.apply(controlID: 0x0050, intended: intended)
    }
    let committed = try #require(await setup.repository.snapshot())
    let control = try committed.control(0x0050)
    #expect(control.phase == .applyMayHaveOccurred)
    #expect(control.attempts.last?.outcome == .outcomeUnknown)
    #expect(await setup.transport.invocationRecords().count == 1)
}

@Test func cancellationBeforeAbstractInvocationResolvesCleanOnlyAfterBaselineRead() async throws {
    let setup = try await transactionTestSetup()
    await setup.transport.pauseInvocation()
    let intended = try intendedState(for: setup.envelope, controlID: 0x0050)

    let task = Task {
        try await setup.coordinator.apply(controlID: 0x0050, intended: intended)
    }
    await setup.transport.waitForPausedInvocation()
    let boundarySnapshot = await setup.repository.snapshot()
    task.cancel()
    await setup.transport.resumeInvocation()
    let armed = try #require(boundarySnapshot)
    #expect(try armed.control(0x0050).phase == .applyMayHaveOccurred)
    do {
        _ = try await task.value
        Issue.record("Expected clean apply-not-observed result after cancellation")
    } catch let error as DeviceTransactionCoordinatorError {
        #expect(error == .applyNotObserved(0x0050))
    }

    let committed = try #require(await setup.repository.snapshot())
    #expect(try committed.control(0x0050).phase == .baselineVerified)
    #expect(!committed.needsRecoveryAttention)
    #expect(await setup.transport.invocationRecords().isEmpty)
}

@Test func recoveryOfMixedNineControlJournalTouchesOnlyDirtyControlsInIndexOrder() async throws {
    var envelope = try transactionEnvelope(controlCount: 9)
    let dirtyIDs: [UInt16] = [0x0052, 0x0055, 0x0058]
    var intendedByID: [UInt16: DeviceTransactionWireState] = [:]

    // CID 0052: appliedVerified.
    let firstIntended = try intendedState(for: envelope, controlID: dirtyIDs[0])
    intendedByID[dirtyIDs[0]] = firstIntended
    envelope = try DeviceTransactionReducer.reduce(
        envelope,
        event: .armApply(
            controlID: dirtyIDs[0],
            intended: firstIntended,
            attemptID: UUID(),
            now: Date()
        )
    ).envelope
    envelope = try DeviceTransactionReducer.reduce(
        envelope,
        event: .observeApply(
            controlID: dirtyIDs[0],
            state: firstIntended,
            now: Date()
        )
    ).envelope

    // CID 0055: applyMayHaveOccurred.
    let secondIntended = try intendedState(for: envelope, controlID: dirtyIDs[1])
    intendedByID[dirtyIDs[1]] = secondIntended
    envelope = try DeviceTransactionReducer.reduce(
        envelope,
        event: .armApply(
            controlID: dirtyIDs[1],
            intended: secondIntended,
            attemptID: UUID(),
            now: Date()
        )
    ).envelope

    // CID 0058: restoreMayHaveOccurred.
    let thirdIntended = try intendedState(for: envelope, controlID: dirtyIDs[2])
    intendedByID[dirtyIDs[2]] = thirdIntended
    envelope = try DeviceTransactionReducer.reduce(
        envelope,
        event: .armApply(
            controlID: dirtyIDs[2],
            intended: thirdIntended,
            attemptID: UUID(),
            now: Date()
        )
    ).envelope
    envelope = try DeviceTransactionReducer.reduce(
        envelope,
        event: .observeApply(
            controlID: dirtyIDs[2],
            state: thirdIntended,
            now: Date()
        )
    ).envelope
    envelope = try DeviceTransactionReducer.reduce(
        envelope,
        event: .armRestore(
            controlID: dirtyIDs[2],
            attemptID: UUID(),
            now: Date()
        )
    ).envelope

    let repository = ScriptedTransactionRepository()
    await repository.seed(envelope)
    let transport = ScriptedTransactionTransport(
        repository: repository,
        session: transactionSession(),
        initialStates: transactionStates(envelope)
    )
    for (controlID, intended) in intendedByID {
        await transport.setState(intended)
        #expect(intended.controlID == controlID)
    }
    let coordinator = DeviceTransactionCoordinator(
        repository: repository,
        transport: transport
    )

    let report = try await coordinator.recoverExplicitly()
    #expect(report.inspectedControlIDs == dirtyIDs)
    #expect(report.restoredControlIDs == dirtyIDs)
    let invocations = await transport.invocationRecords()
    #expect(invocations.map(\.controlID) == dirtyIDs)
    #expect(invocations.allSatisfy { $0.kind == .restore })

    let final = try #require(await repository.snapshot())
    for control in final.controls {
        if dirtyIDs.contains(control.controlID) {
            #expect(control.phase == .restoredVerified)
        } else {
            #expect(control.phase == .baselineVerified)
            #expect(control.intended == nil)
        }
    }
}

@Test func isolatedSimulationExercisesEveryControlAndTwoRestartBoundaries() async throws {
    let report = try await DeviceTransactionSimulation.run(
        baselineJournal: transactionBaselineJournal(controlCount: 3)
    )
    #expect(report.controlCount == 3)
    #expect(report.cleanRoundTripCount == 3)
    #expect(report.interruptedRecoveryCount == 2)
    #expect(report.durableCommitCount > 0)
    #expect(report.abstractMutationCount == 8)
    #expect(report.durableCommitBoundaryCount == 6)
    #expect(report.recoveryClassificationCount == 14)
    #expect(report.transportFaultScenarioCount == 16)
    #expect(report.reconnectIdentityCheckCount == 14)
    #expect(report.immutableWireByteCheckCount == 15)
    #expect(report.finalStatus == .completed)
}

@Test func thirdPartyReadBackPersistsConflictAndBlocksRecovery() async throws {
    let setup = try await transactionTestSetup()
    await setup.transport.enqueue(.returnWithoutMutation)
    let intended = try intendedState(for: setup.envelope, controlID: 0x0050)
    let thirdParty = try reportingState(controlID: 0x0050, flags: 0x10)
    await setup.transport.setState(thirdParty)

    await #expect(throws: DeviceTransactionCoordinatorError.conflicted(0x0050)) {
        try await setup.coordinator.apply(controlID: 0x0050, intended: intended)
    }
    let committed = try #require(await setup.repository.snapshot())
    #expect(committed.status == .conflicted)
    #expect(try committed.control(0x0050).conflictingObservation == thirdParty)
    await #expect(throws: DeviceTransactionModelError.transactionConflicted) {
        try await setup.coordinator.recoverExplicitly()
    }
}

@Test func reentrantCoordinatorCallIsRejectedWhileMutationIsSuspended() async throws {
    let setup = try await transactionTestSetup()
    await setup.transport.pauseInvocation()
    let intended = try intendedState(for: setup.envelope, controlID: 0x0050)

    let applyTask = Task {
        try await setup.coordinator.apply(controlID: 0x0050, intended: intended)
    }
    await setup.transport.waitForPausedInvocation()
    await #expect(throws: DeviceTransactionCoordinatorError.operationAlreadyInProgress) {
        try await setup.coordinator.currentEnvelope()
    }
    await setup.transport.resumeInvocation()
    _ = try await applyTask.value
}

private struct TransactionTestSetup {
    let envelope: DeviceTransactionEnvelope
    let repository: ScriptedTransactionRepository
    let transport: ScriptedTransactionTransport
    let coordinator: DeviceTransactionCoordinator
}

private func transactionTestSetup(
    controlCount: Int = 1,
    failBeforeCommitCalls: Set<Int> = [],
    failAfterCommitCalls: Set<Int> = []
) async throws -> TransactionTestSetup {
    let envelope = try transactionEnvelope(controlCount: controlCount)
    let repository = ScriptedTransactionRepository(
        failBeforeCommitCalls: failBeforeCommitCalls,
        failAfterCommitCalls: failAfterCommitCalls
    )
    let transport = ScriptedTransactionTransport(
        repository: repository,
        session: transactionSession(),
        initialStates: transactionStates(envelope)
    )
    let coordinator = DeviceTransactionCoordinator(
        repository: repository,
        transport: transport
    )
    _ = try await coordinator.installPreparedEnvelope(envelope)
    return TransactionTestSetup(
        envelope: envelope,
        repository: repository,
        transport: transport,
        coordinator: coordinator
    )
}

private actor ScriptedTransactionRepository: DeviceTransactionJournalRepository {
    enum ScriptedError: Error {
        case failedBeforeCommit
        case failedAfterCommit
    }

    private var envelope: DeviceTransactionEnvelope?
    private var commitCall = 0
    private let failBeforeCommitCalls: Set<Int>
    private let failAfterCommitCalls: Set<Int>

    init(
        failBeforeCommitCalls: Set<Int> = [],
        failAfterCommitCalls: Set<Int> = []
    ) {
        self.failBeforeCommitCalls = failBeforeCommitCalls
        self.failAfterCommitCalls = failAfterCommitCalls
    }

    func loadValidated() async throws -> DeviceTransactionEnvelope? {
        try envelope?.validate()
        return envelope
    }

    func commit(
        _ next: DeviceTransactionEnvelope,
        expectedRevision: UInt64?
    ) async throws -> DeviceTransactionDurableCommitReceipt {
        commitCall += 1
        if failBeforeCommitCalls.contains(commitCall) {
            throw ScriptedError.failedBeforeCommit
        }
        let actual = envelope?.revision
        guard actual == expectedRevision else {
            throw DeviceTransactionRepositoryError.compareAndSwapMismatch(
                expected: expectedRevision,
                actual: actual
            )
        }
        try next.validate()
        envelope = next
        if failAfterCommitCalls.contains(commitCall) {
            throw ScriptedError.failedAfterCommit
        }
        return DeviceTransactionDurableCommitReceipt(
            transactionID: next.transactionID,
            revision: next.revision,
            sha256: "scripted-\(next.revision)"
        )
    }

    func snapshot() -> DeviceTransactionEnvelope? { envelope }
    func seed(_ seededEnvelope: DeviceTransactionEnvelope) { envelope = seededEnvelope }
}

private enum ScriptedMutationBehavior: Sendable {
    case mutateAndReturn
    case returnWithoutMutation
    case mutateThenThrow(String)
    case rejectBeforeDispatch(String)
    case throwUnknownWithoutMutation(String)
    case mutateThenChangeEpoch
}

private enum ScriptedPreparationBehavior: Sendable, Equatable {
    case normal
    case invalidRevision
    case changeEpochBeforeReturn
}

private struct ScriptedInvocationRecord: Sendable, Equatable {
    let controlID: UInt16
    let attemptID: UUID
    let kind: DeviceTransactionMutationKind
    let authorizedRevision: UInt64
    let durablePhase: DeviceTransactionControlPhase
}

private actor ScriptedTransactionTransport: DeviceTransactionEffectTransport {
    enum ScriptedError: Error {
        case invalidAuthorization
        case readFailed
    }

    private let repository: any DeviceTransactionJournalRepository
    private var session: DeviceTransactionSession
    private var states: [UInt16: DeviceTransactionWireState]
    private var behaviors: [ScriptedMutationBehavior] = []
    private var preparationBehaviors: [ScriptedPreparationBehavior] = []
    private var abandonments: [DeviceTransactionPreparationDisposition] = []
    private var records: [ScriptedInvocationRecord] = []
    private var readsToFail = 0
    private var successfulReadsBeforeFailure = 0
    private var invocationPaused = false
    private var invocationRelease: CheckedContinuation<Void, Never>?
    private var invocationWaiters: [CheckedContinuation<Void, Never>] = []

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
        let behavior = preparationBehaviors.isEmpty
            ? .normal
            : preparationBehaviors.removeFirst()
        let prepared = DeviceTransactionPreparedInvocation(
            mutation: proposed,
            expectedSession: expectedSession,
            expectedCommittedRevision: behavior == .invalidRevision
                ? expectedCommittedRevision + 1
                : expectedCommittedRevision
        )
        if behavior == .changeEpochBeforeReturn {
            session = DeviceTransactionSession(
                device: session.device,
                featureID: session.featureID,
                featureVersion: session.featureVersion,
                featureIndex: session.featureIndex,
                connectionEpoch: session.connectionEpoch + 1
            )
        }
        return prepared
    }

    func abandon(
        _ prepared: DeviceTransactionPreparedInvocation,
        disposition: DeviceTransactionPreparationDisposition
    ) async {
        _ = prepared
        abandonments.append(disposition)
    }

    func invoke(
        _ prepared: DeviceTransactionPreparedInvocation,
        authorization: DeviceTransactionDurableCommitReceipt
    ) async throws -> DeviceTransactionInvocationEvidence? {
        let mutation = prepared.mutation
        let expectedSession = prepared.expectedSession
        if invocationPaused {
            await withCheckedContinuation { continuation in
                invocationRelease = continuation
                let waiting = invocationWaiters
                invocationWaiters.removeAll()
                for waiter in waiting { waiter.resume() }
            }
            try Task.checkCancellation()
        }
        guard session == expectedSession,
              let durable = try await repository.loadValidated(),
              durable.transactionID == authorization.transactionID,
              durable.revision == authorization.revision else {
            throw ScriptedError.invalidAuthorization
        }
        let control = try durable.control(mutation.controlID)
        let expectedPhase: DeviceTransactionControlPhase =
            mutation.kind == .apply ? .applyMayHaveOccurred : .restoreMayHaveOccurred
        guard control.phase == expectedPhase,
              control.activeAttemptID == mutation.attemptID else {
            throw ScriptedError.invalidAuthorization
        }
        records.append(ScriptedInvocationRecord(
            controlID: mutation.controlID,
            attemptID: mutation.attemptID,
            kind: mutation.kind,
            authorizedRevision: authorization.revision,
            durablePhase: control.phase
        ))

        let behavior = behaviors.isEmpty ? .mutateAndReturn : behaviors.removeFirst()
        switch behavior {
        case .mutateAndReturn:
            states[mutation.controlID] = mutation.state
        case .returnWithoutMutation:
            break
        case let .mutateThenThrow(detail):
            states[mutation.controlID] = mutation.state
            throw DeviceTransactionTransportInvocationError.outcomeUnknown(detail)
        case let .rejectBeforeDispatch(detail):
            throw DeviceTransactionTransportInvocationError.rejectedBeforeDispatch(detail)
        case let .throwUnknownWithoutMutation(detail):
            throw DeviceTransactionTransportInvocationError.outcomeUnknown(detail)
        case .mutateThenChangeEpoch:
            states[mutation.controlID] = mutation.state
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
        guard session == expectedSession else { throw ScriptedError.invalidAuthorization }
        if readsToFail > 0, successfulReadsBeforeFailure > 0 {
            successfulReadsBeforeFailure -= 1
        } else if readsToFail > 0 {
            readsToFail -= 1
            throw ScriptedError.readFailed
        }
        guard let state = states[controlID] else { throw ScriptedError.readFailed }
        return state
    }

    func enqueue(_ behavior: ScriptedMutationBehavior) { behaviors.append(behavior) }
    func enqueuePreparation(_ behavior: ScriptedPreparationBehavior) {
        preparationBehaviors.append(behavior)
    }
    func failNextReads(_ count: Int, afterSuccessfulReads: Int = 0) {
        readsToFail = count
        successfulReadsBeforeFailure = afterSuccessfulReads
    }
    func pauseInvocation() { invocationPaused = true }
    func waitForPausedInvocation() async {
        guard invocationRelease == nil else { return }
        await withCheckedContinuation { invocationWaiters.append($0) }
    }
    func resumeInvocation() {
        invocationPaused = false
        let release = invocationRelease
        invocationRelease = nil
        release?.resume()
    }
    func setState(_ state: DeviceTransactionWireState) { states[state.controlID] = state }
    func invocationRecords() -> [ScriptedInvocationRecord] { records }
    func abandonmentDispositions() -> [DeviceTransactionPreparationDisposition] {
        abandonments
    }
}

private func transactionEnvelope(controlCount: Int = 1) throws -> DeviceTransactionEnvelope {
    try DeviceTransactionEnvelope(
        transactionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        baselineJournal: transactionBaselineJournal(controlCount: controlCount),
        now: Date(timeIntervalSince1970: 1_001)
    )
}

private func transactionBaselineJournal(
    controlCount: Int = 1
) throws -> DeviceStateJournal {
    var entries: [DeviceControlJournalEntry] = []
    for index in 0..<controlCount {
        let controlID = UInt16(0x0050 + index)
        let raw = try reportingState(controlID: controlID, flags: 0)
        entries.append(try DeviceControlJournalEntry(
            controlInfo: ReprogControlInfo(
                index: UInt8(index),
                controlID: controlID,
                taskID: controlID,
                capabilityFlags: 0x71,
                position: 0,
                group: 1,
                groupMask: 1,
                rawXYCapability: false,
                rawParameters: paddedTransactionBytes([
                    UInt8(controlID >> 8),
                    UInt8(controlID & 0xFF),
                ])
            ),
            baselineReporting: ReprogControlReportingState(
                controlID: controlID,
                rawFlags: 0,
                rawMappedControlID: 0,
                rawParameters: raw.rawParameters
            )
        ))
    }
    return try DeviceStateJournal(
        transactionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        appBuild: "transaction-test",
        device: transactionDevice(),
        feature: HIDPP20FeatureDescriptor(
            index: 0x0A,
            type: 0,
            version: 3,
            rawParameters: paddedTransactionBytes([0x0A, 0, 3])
        ),
        expectedControlCount: controlCount,
        controls: entries,
        now: Date(timeIntervalSince1970: 1_000)
    )
}

private func transactionSession() -> DeviceTransactionSession {
    DeviceTransactionSession(
        device: transactionDevice(),
        featureID: ReprogControlsV4.featureID,
        featureVersion: 3,
        featureIndex: 0x0A,
        connectionEpoch: 7
    )
}

private func transactionDevice() -> JournalDeviceIdentity {
    JournalDeviceIdentity(
        deviceID: "046D-B01D-TEST",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "TRANSACTION-TEST",
        locationID: 42,
        firmwareIdentity: "test-firmware"
    )
}

private func transactionStates(
    _ envelope: DeviceTransactionEnvelope
) -> [UInt16: DeviceTransactionWireState] {
    Dictionary(uniqueKeysWithValues: envelope.controls.map { ($0.controlID, $0.baseline) })
}

private func intendedState(
    for envelope: DeviceTransactionEnvelope,
    controlID: UInt16
) throws -> DeviceTransactionWireState {
    var raw = try envelope.control(controlID).baseline.rawParameters
    raw[2] ^= 0x01
    return try DeviceTransactionWireState(rawParameters: raw)
}

private func reportingState(
    controlID: UInt16,
    flags: UInt8
) throws -> DeviceTransactionWireState {
    try DeviceTransactionWireState(rawParameters: paddedTransactionBytes([
        UInt8(controlID >> 8),
        UInt8(controlID & 0xFF),
        flags,
        0,
        0,
    ]))
}

private func paddedTransactionBytes(_ prefix: [UInt8]) -> [UInt8] {
    prefix + Array(
        repeating: 0,
        count: HIDPP20LongMessage.parameterCount - prefix.count
    )
}

/// Path to the built `MXErgoTransactionCrashHarness` executable.
///
/// `scripts/verify.sh` builds it and exports this variable. Without it these
/// subprocess tests cannot run, so they report as skipped rather than passing
/// silently — a hard-kill durability test that quietly does nothing is worse
/// than no test at all.
let crashHarnessPath: String? = {
    guard let path = ProcessInfo.processInfo.environment[
        "MX_ERGO_CRASH_HARNESS_PATH"
    ], !path.isEmpty else {
        return nil
    }
    return path
}()

let crashHarnessIsAvailable = crashHarnessPath != nil

let missingCrashHarness: Comment = """
MX_ERGO_CRASH_HARNESS_PATH is not set. Run scripts/verify.sh, which builds \
MXErgoTransactionCrashHarness and exports its path.
"""
