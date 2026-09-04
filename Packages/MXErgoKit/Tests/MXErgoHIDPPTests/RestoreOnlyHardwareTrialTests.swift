import Foundation
import Testing
@testable import MXErgoHIDPP

@Test func restoreOnlyHardwareTrialAcceptsTheInitialConnectionEpochZero() throws {
    let fixture = try trialFixture()
    let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 0
    )

    #expect(prepared.connectionEpoch == 0)
    try prepared.validate()
}

@Test func restoreOnlyHardwareTrialPreparesOnlyTheNarrowPrecisionPacket() throws {
    let fixture = try trialFixture()
    let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 9,
        transactionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        attemptID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        now: Date(timeIntervalSince1970: 2_000)
    )

    #expect(prepared.phase == .prepared)
    #expect(prepared.revision == 0)
    #expect(prepared.controlID == 0x00ED)
    #expect(prepared.setRequestBytes == [
        0x11, 0x00, 0x0A, 0x3E,
        0x00, 0xED, 0x02, 0x00, 0x00,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ])
    #expect(prepared.verificationRequestBytes == [
        0x11, 0x00, 0x0A, 0x2E,
        0x00, 0xED,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ])
}

@Test func restoreOnlyHardwareTrialReducerNeverTreatsAcknowledgementAsVerification() throws {
    let fixture = try trialFixture()
    let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 10
    )
    let armed = try RestoreOnlyHardwareTrialReducer.arm(prepared)
    let acknowledged = try RestoreOnlyHardwareTrialReducer.acknowledge(
        armed,
        responseBytes: armed.setRequestBytes
    )

    #expect(acknowledged.phase == .acknowledged)
    #expect(acknowledged.verificationState == nil)

    let verified = try RestoreOnlyHardwareTrialReducer.verify(
        acknowledged,
        observation: acknowledged.preflightState
    )
    #expect(verified.phase == .baselineVerified)
    #expect(verified.revision == 3)
}

@Test func restoreOnlyHardwareTrialReducerConflictsOnAnyReadBackDrift() throws {
    let fixture = try trialFixture()
    let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 11
    )
    let armed = try RestoreOnlyHardwareTrialReducer.arm(prepared)
    let acknowledged = try RestoreOnlyHardwareTrialReducer.acknowledge(
        armed,
        responseBytes: armed.setRequestBytes
    )
    var driftedBytes = acknowledged.preflightState.rawParameters
    driftedBytes[2] = 1
    let conflicted = try RestoreOnlyHardwareTrialReducer.verify(
        acknowledged,
        observation: DeviceTransactionWireState(rawParameters: driftedBytes)
    )

    #expect(conflicted.phase == .conflicted)
    #expect(conflicted.detail?.isEmpty == false)
}

@Test func restoreOnlyHardwareTrialReadOnlyReconciliationClassifiesEveryAmbiguousPhase() throws {
    let fixture = try trialFixture()
    let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 111
    )
    let armed = try RestoreOnlyHardwareTrialReducer.arm(prepared)
    let acknowledged = try RestoreOnlyHardwareTrialReducer.acknowledge(
        armed,
        responseBytes: armed.setRequestBytes
    )
    let unknownFromArmed = try RestoreOnlyHardwareTrialReducer.markOutcomeUnknown(
        armed,
        detail: "scripted timeout"
    )
    var driftedBytes = prepared.preflightState.rawParameters
    driftedBytes[2] = 0x10
    let drifted = try DeviceTransactionWireState(rawParameters: driftedBytes)

    for ambiguous in [armed, acknowledged, unknownFromArmed] {
        let recovered = try RestoreOnlyHardwareTrialReducer.reconcileReadOnly(
            ambiguous,
            observation: prepared.preflightState
        )
        #expect(recovered.phase == .baselineVerified)
        #expect(recovered.verificationState == prepared.preflightState)

        let conflicted = try RestoreOnlyHardwareTrialReducer.reconcileReadOnly(
            ambiguous,
            observation: drifted
        )
        #expect(conflicted.phase == .conflicted)
        #expect(conflicted.verificationState == drifted)
        #expect(conflicted.detail?.isEmpty == false)
    }

    #expect(throws: RestoreOnlyHardwareTrialError.invalidPhase) {
        try RestoreOnlyHardwareTrialReducer.reconcileReadOnly(
            prepared,
            observation: prepared.preflightState
        )
    }
}

@Test func restoreOnlyHardwareTrialRepositoryExecutesRestartReconciliationWithoutOriginalEpoch() async throws {
    let fixture = try trialFixture()
    let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 7
    )
    let armed = try RestoreOnlyHardwareTrialReducer.arm(prepared)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "restore-trial-reconcile-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = DurableRestoreOnlyHardwareTrialRepository(
        fileURL: directory.appendingPathComponent("trial.json")
    )
    _ = try await repository.commit(prepared, expectedRevision: nil)
    _ = try await repository.commit(armed, expectedRevision: prepared.revision)
    let freshSession = RestoreOnlyHardwareTrialSession(
        device: armed.device,
        featureIndex: armed.featureIndex,
        featureVersion: armed.featureVersion,
        connectionEpoch: 0,
        matchingDeviceCount: 1,
        outputReportByteCount: HIDPP20LongMessage.byteCount
    )

    let reconciled = try await repository.reconcileRestartReadOnly(
        observation: armed.preflightState,
        freshSession: freshSession,
        sourceBaselineData: fixture.data,
        liveJournalURL: directory.appendingPathComponent(
            "device-state-journal.json"
        )
    )

    #expect(reconciled.phase == .baselineVerified)
    #expect(reconciled.revision == armed.revision + 1)
    #expect(try await repository.loadValidated() == reconciled)
}

@Test func restoreOnlyHardwareTrialRepositoryRestartReconciliationConflictsOnDrift() async throws {
    let fixture = try trialFixture()
    let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 21
    )
    let unknown = try RestoreOnlyHardwareTrialReducer.markOutcomeUnknown(
        RestoreOnlyHardwareTrialReducer.arm(prepared),
        detail: "interrupted transport"
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "restore-trial-reconcile-drift-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = DurableRestoreOnlyHardwareTrialRepository(
        fileURL: directory.appendingPathComponent("trial.json")
    )
    _ = try await repository.commit(prepared, expectedRevision: nil)
    let armed = try RestoreOnlyHardwareTrialReducer.arm(prepared)
    _ = try await repository.commit(armed, expectedRevision: prepared.revision)
    _ = try await repository.commit(unknown, expectedRevision: armed.revision)
    var driftedBytes = unknown.preflightState.rawParameters
    driftedBytes[2] = 0x10
    let drifted = try DeviceTransactionWireState(rawParameters: driftedBytes)
    let freshSession = RestoreOnlyHardwareTrialSession(
        device: unknown.device,
        featureIndex: unknown.featureIndex,
        featureVersion: unknown.featureVersion,
        connectionEpoch: 99,
        matchingDeviceCount: 1,
        outputReportByteCount: HIDPP20LongMessage.byteCount
    )

    let reconciled = try await repository.reconcileRestartReadOnly(
        observation: drifted,
        freshSession: freshSession,
        sourceBaselineData: fixture.data,
        liveJournalURL: directory.appendingPathComponent(
            "device-state-journal.json"
        )
    )

    #expect(reconciled.phase == .conflicted)
    #expect(reconciled.verificationState == drifted)
    #expect(try await repository.loadValidated() == reconciled)
}

@Test func restoreOnlyHardwareTrialRepositoryRestartReconciliationRejectsChangedSession() async throws {
    let fixture = try trialFixture()
    let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 33
    )
    let armed = try RestoreOnlyHardwareTrialReducer.arm(prepared)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "restore-trial-reconcile-session-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = DurableRestoreOnlyHardwareTrialRepository(
        fileURL: directory.appendingPathComponent("trial.json")
    )
    _ = try await repository.commit(prepared, expectedRevision: nil)
    _ = try await repository.commit(armed, expectedRevision: prepared.revision)
    let changedSession = RestoreOnlyHardwareTrialSession(
        device: armed.device,
        featureIndex: armed.featureIndex,
        featureVersion: armed.featureVersion,
        connectionEpoch: 34,
        matchingDeviceCount: 2,
        outputReportByteCount: HIDPP20LongMessage.byteCount
    )

    await #expect(throws: RestoreOnlyHardwareTrialError.sessionChanged) {
        try await repository.reconcileRestartReadOnly(
            observation: armed.preflightState,
            freshSession: changedSession,
            sourceBaselineData: fixture.data,
            liveJournalURL: directory.appendingPathComponent(
                "device-state-journal.json"
            )
        )
    }
    #expect(try await repository.loadValidated() == armed)
}

@Test func restoreOnlyHardwareTrialRestartReconciliationHonorsTheLiveDeviceLease() async throws {
    let fixture = try trialFixture()
    let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 41
    )
    let armed = try RestoreOnlyHardwareTrialReducer.arm(prepared)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "restore-trial-reconcile-device-lease-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = DurableRestoreOnlyHardwareTrialRepository(
        fileURL: directory.appendingPathComponent("trial.json")
    )
    _ = try await repository.commit(prepared, expectedRevision: nil)
    _ = try await repository.commit(armed, expectedRevision: prepared.revision)
    let liveJournalURL = directory.appendingPathComponent(
        "device-state-journal.json"
    )
    let competingLease = try MXErgoDeviceOperationLease.acquire(
        beside: liveJournalURL
    )
    defer { withExtendedLifetime(competingLease) {} }

    await #expect(throws: MXErgoDeviceOperationLeaseError.unavailable) {
        try await repository.reconcileRestartReadOnly(
            observation: armed.preflightState,
            freshSession: trialSession(for: armed),
            sourceBaselineData: fixture.data,
            liveJournalURL: liveJournalURL
        )
    }
    #expect(try await repository.loadValidated() == armed)
}

@Test func restoreOnlyHardwareTrialRefusesChangedLiveBaselineBeforeArming() async throws {
    let fixture = try trialFixture()
    let setup = try await trialRunnerSetup(
        fixture: fixture,
        baselineReader: TrialBaselineReader(
            responses: [Data(fixture.data + Data([0x20]))]
        )
    )
    defer { try? FileManager.default.removeItem(at: setup.directory) }

    await #expect(throws: RestoreOnlyHardwareTrialError.liveBaselineMismatch) {
        try await setup.runner.runExplicitlyConfirmed()
    }
    #expect(await setup.transport.setCount == 0)
    #expect(try await setup.repository.loadValidated()?.phase == .prepared)
}

@Test func restoreOnlyHardwareTrialRunnerHonorsTheLiveDeviceLeaseBeforeSET() async throws {
    let fixture = try trialFixture()
    let setup = try await trialRunnerSetup(fixture: fixture)
    defer { try? FileManager.default.removeItem(at: setup.directory) }
    let liveJournalURL = setup.directory.appendingPathComponent(
        "device-state-journal.json"
    )
    let competingLease = try MXErgoDeviceOperationLease.acquire(
        beside: liveJournalURL
    )
    defer { withExtendedLifetime(competingLease) {} }

    await #expect(throws: MXErgoDeviceOperationLeaseError.unavailable) {
        try await setup.runner.runExplicitlyConfirmed()
    }
    #expect(await setup.transport.setCount == 0)
    #expect(try await setup.repository.loadValidated()?.phase == .prepared)
}

@Test func restoreOnlyHardwareTrialRunnerAcceptsTheExactPreacquiredLiveLease() async throws {
    let fixture = try trialFixture()
    let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 112
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "restore-trial-preacquired-device-lease-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let liveJournalURL = directory.appendingPathComponent(
        "device-state-journal.json"
    )
    let deviceLease = try MXErgoDeviceOperationLease.acquire(
        beside: liveJournalURL
    )
    defer { withExtendedLifetime(deviceLease) {} }
    #expect(deviceLease.protects(journalURL: liveJournalURL))

    let repository = DurableRestoreOnlyHardwareTrialRepository(
        fileURL: directory.appendingPathComponent("trial.json")
    )
    let transport = TrialBoundaryTransport(
        session: trialSession(for: prepared),
        state: prepared.preflightState,
        behavior: .exact
    )
    let runner = RestoreOnlyHardwareTrialRunner(
        repository: repository,
        transport: transport,
        baselineReader: TrialBaselineReader(
            responses: [fixture.data, fixture.data]
        ),
        liveJournalURL: liveJournalURL,
        preacquiredDeviceOperationLease: deviceLease
    )
    try await runner.install(prepared)

    let final = try await runner.runExplicitlyConfirmed()
    #expect(final.phase == .baselineVerified)
    #expect(await transport.setCount == 1)
}

@Test func restoreOnlyHardwareTrialRunnerRejectsAPreacquiredLeaseForAnotherJournal() async throws {
    let fixture = try trialFixture()
    let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 112
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "restore-trial-wrong-preacquired-device-lease-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let liveJournalURL = directory.appendingPathComponent(
        "device-state-journal.json"
    )
    let wrongLease = try MXErgoDeviceOperationLease.acquire(
        beside: directory
            .appendingPathComponent("other", isDirectory: true)
            .appendingPathComponent("device-state-journal.json")
    )
    defer { withExtendedLifetime(wrongLease) {} }
    #expect(!wrongLease.protects(journalURL: liveJournalURL))

    let repository = DurableRestoreOnlyHardwareTrialRepository(
        fileURL: directory.appendingPathComponent("trial.json")
    )
    let transport = TrialBoundaryTransport(
        session: trialSession(for: prepared),
        state: prepared.preflightState,
        behavior: .exact
    )
    let runner = RestoreOnlyHardwareTrialRunner(
        repository: repository,
        transport: transport,
        baselineReader: TrialBaselineReader(
            responses: [fixture.data, fixture.data]
        ),
        liveJournalURL: liveJournalURL,
        preacquiredDeviceOperationLease: wrongLease
    )
    try await runner.install(prepared)

    await #expect(throws: RestoreOnlyHardwareTrialError.operationLeaseUnavailable) {
        try await runner.runExplicitlyConfirmed()
    }
    #expect(await transport.setCount == 0)
    #expect(try await repository.loadValidated()?.phase == .prepared)
}

@Test func restoreOnlyHardwareTrialPersistsUnknownForWrongAcknowledgement() async throws {
    let fixture = try trialFixture()
    let setup = try await trialRunnerSetup(
        fixture: fixture,
        transportBehavior: .wrongAcknowledgement
    )
    defer { try? FileManager.default.removeItem(at: setup.directory) }

    do {
        _ = try await setup.runner.runExplicitlyConfirmed()
        Issue.record("Expected wrong acknowledgement to fail closed")
    } catch let error as RestoreOnlyHardwareTrialError {
        guard case .outcomeUnknown = error else {
            Issue.record("Expected outcomeUnknown, got \(error)")
            return
        }
    }
    #expect(await setup.transport.setCount == 1)
    #expect(try await setup.repository.loadValidated()?.phase == .outcomeUnknown)
}

@Test func restoreOnlyHardwareTrialPersistsUnknownWhenVerificationReadFails() async throws {
    let fixture = try trialFixture()
    let setup = try await trialRunnerSetup(
        fixture: fixture,
        transportBehavior: .failVerificationRead
    )
    defer { try? FileManager.default.removeItem(at: setup.directory) }

    do {
        _ = try await setup.runner.runExplicitlyConfirmed()
        Issue.record("Expected verification failure to fail closed")
    } catch let error as RestoreOnlyHardwareTrialError {
        guard case .outcomeUnknown = error else {
            Issue.record("Expected outcomeUnknown, got \(error)")
            return
        }
    }
    #expect(await setup.transport.setCount == 1)
    #expect(await setup.transport.readCount == 2)
    #expect(try await setup.repository.loadValidated()?.phase == .outcomeUnknown)
}

@Test func restoreOnlyHardwareTrialRechecksLiveBaselineBeforeTerminalCommit() async throws {
    let fixture = try trialFixture()
    let setup = try await trialRunnerSetup(
        fixture: fixture,
        baselineReader: TrialBaselineReader(
            responses: [fixture.data, Data(fixture.data + Data([0x20]))]
        )
    )
    defer { try? FileManager.default.removeItem(at: setup.directory) }

    do {
        _ = try await setup.runner.runExplicitlyConfirmed()
        Issue.record("Expected final baseline drift to fail closed")
    } catch let error as RestoreOnlyHardwareTrialError {
        guard case .outcomeUnknown = error else {
            Issue.record("Expected outcomeUnknown, got \(error)")
            return
        }
    }
    #expect(await setup.transport.setCount == 1)
    #expect(try await setup.repository.loadValidated()?.phase == .outcomeUnknown)
}

@Test func restoreOnlyHardwareTrialCancellationDuringDispatchPersistsUnknownAndNeverRetries() async throws {
    let fixture = try trialFixture()
    let setup = try await trialRunnerSetup(
        fixture: fixture,
        transportBehavior: .suspendDuringDispatch
    )
    defer { try? FileManager.default.removeItem(at: setup.directory) }

    let task = Task {
        try await setup.runner.runExplicitlyConfirmed()
    }
    for _ in 0..<200 {
        if await setup.transport.setCount > 0 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await setup.transport.setCount == 1)
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Expected cancellation during dispatch to fail closed")
    } catch let error as RestoreOnlyHardwareTrialError {
        guard case .outcomeUnknown = error else {
            Issue.record("Expected outcomeUnknown, got \(error)")
            return
        }
    }

    #expect(try await setup.repository.loadValidated()?.phase == .outcomeUnknown)
    await #expect(throws: RestoreOnlyHardwareTrialError.invalidPhase) {
        try await setup.runner.runExplicitlyConfirmed()
    }
    #expect(await setup.transport.setCount == 1)
}

@Test func restoreOnlyHardwareTrialReconcilesAnIndeterminateAcknowledgementCommitToUnknown() async throws {
    let fixture = try trialFixture()
    let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 113
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "restore-trial-ack-commit-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fault = TrialCommitFault(failReceiptNumber: 3)
    let repository = DurableRestoreOnlyHardwareTrialRepository(
        fileURL: directory.appendingPathComponent("trial.json")
    ) { boundary in
        try fault.reach(boundary)
    }
    let transport = TrialBoundaryTransport(
        session: trialSession(for: prepared),
        state: prepared.preflightState,
        behavior: .exact
    )
    let runner = RestoreOnlyHardwareTrialRunner(
        repository: repository,
        transport: transport,
        baselineReader: TrialBaselineReader(
            responses: [fixture.data, fixture.data]
        ),
        liveJournalURL: directory.appendingPathComponent(
            "device-state-journal.json"
        )
    )
    try await runner.install(prepared)

    do {
        _ = try await runner.runExplicitlyConfirmed()
        Issue.record("Expected the acknowledgement receipt fault to fail closed")
    } catch let error as RestoreOnlyHardwareTrialError {
        guard case .outcomeUnknown = error else {
            Issue.record("Expected outcomeUnknown, got \(error)")
            return
        }
    }
    #expect(await transport.setCount == 1)
    #expect(try await repository.loadValidated()?.phase == .outcomeUnknown)
}

@Test func restoreOnlyHardwareTrialAuthorizationIsExactAndOneUse() async throws {
    let fixture = try trialFixture()
    let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 12
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "restore-trial-auth-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = DurableRestoreOnlyHardwareTrialRepository(
        fileURL: directory.appendingPathComponent("trial.json")
    )
    _ = try await repository.commit(prepared, expectedRevision: nil)
    let armed = try RestoreOnlyHardwareTrialReducer.arm(prepared)
    let receipt = try await repository.commit(armed, expectedRevision: 0)
    let request = try HIDPP20LongMessage(bytes: armed.setRequestBytes)
    let session = trialSession(for: armed)

    let authorized = try await repository.consumeArmedAuthorization(
        receipt,
        request: request,
        expectedSession: session
    )
    #expect(authorized == armed)

    await #expect(throws: RestoreOnlyHardwareTrialError.authorizationAlreadyConsumed) {
        try await repository.consumeArmedAuthorization(
            receipt,
            request: request,
            expectedSession: session
        )
    }
}

@Test func restoreOnlyHardwareTrialRepositoryRejectsLastMomentByteRace() async throws {
    let fixture = try trialFixture()
    let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 13
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "restore-trial-cas-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("trial.json")
    let initial = DurableRestoreOnlyHardwareTrialRepository(fileURL: fileURL)
    _ = try await initial.commit(prepared, expectedRevision: nil)
    let armed = try RestoreOnlyHardwareTrialReducer.arm(prepared)
    let racing = DurableRestoreOnlyHardwareTrialRepository(fileURL: fileURL) { boundary in
        if boundary == .beforeCompareAndSwap {
            try Data("outside-writer".utf8).write(to: fileURL)
        }
    }

    await #expect(throws: RestoreOnlyHardwareTrialError.compareAndSwapMismatch) {
        try await racing.commit(armed, expectedRevision: 0)
    }
    #expect(try Data(contentsOf: fileURL) == Data("outside-writer".utf8))
}

@Test(.enabled(if: crashHarnessIsAvailable, missingCrashHarness))
func restoreOnlyHardwareTrialOperationLeaseRejectsASecondProcess() async throws {
    let harnessPath = try #require(crashHarnessPath)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "restore-trial-operation-lock-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("trial.json")
    let lockURL = directory.appendingPathComponent(".trial.json.operation.lock")
    let readyURL = directory.appendingPathComponent("holder-ready")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: harnessPath)
    process.arguments = [
        "hold-trial-operation-lock",
        lockURL.path,
        readyURL.path,
    ]
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    for _ in 0..<200 where !FileManager.default.fileExists(atPath: readyURL.path) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(FileManager.default.fileExists(atPath: readyURL.path))

    let repository = DurableRestoreOnlyHardwareTrialRepository(fileURL: fileURL)
    await #expect(throws: RestoreOnlyHardwareTrialError.operationLeaseUnavailable) {
        _ = try await repository.acquireOperationLease()
    }
}

@Test func restoreOnlyHardwareTrialOperationLeaseRejectsASecondRepositoryInProcess() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "restore-trial-operation-lock-local-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("trial.json")
    let firstRepository = DurableRestoreOnlyHardwareTrialRepository(fileURL: fileURL)
    let secondRepository = DurableRestoreOnlyHardwareTrialRepository(fileURL: fileURL)
    let firstLease = try await firstRepository.acquireOperationLease()
    defer { withExtendedLifetime(firstLease) {} }

    await #expect(throws: RestoreOnlyHardwareTrialError.operationLeaseUnavailable) {
        _ = try await secondRepository.acquireOperationLease()
    }
}

@Test func restoreOnlyHardwareTrialRepositoryFailsClosedAtEveryDurableBoundary() async throws {
    let fixture = try trialFixture()
    let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 15
    )

    for boundary in RestoreOnlyHardwareTrialCommitBoundary.allCases {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "restore-trial-boundary-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("trial.json")
        enum Injected: Error { case failure }
        let repository = DurableRestoreOnlyHardwareTrialRepository(fileURL: fileURL) {
            reached in
            if reached == boundary { throw Injected.failure }
        }

        var threw = false
        do {
            _ = try await repository.commit(prepared, expectedRevision: nil)
        } catch {
            threw = true
        }
        #expect(threw)

        let reopened = DurableRestoreOnlyHardwareTrialRepository(fileURL: fileURL)
        let durable = try await reopened.loadValidated()
        switch boundary {
        case .afterAtomicReplace, .afterDirectorySync, .beforeReceiptReturn:
            #expect(durable == prepared)
        case .beforeTemporaryWrite, .afterTemporaryWrite,
             .afterTemporaryFullSync, .beforeCompareAndSwap:
            #expect(durable == nil)
        }
    }
}

@Test func restoreOnlyHardwareTrialSimulationCompletesOneSetAndTwoReads() async throws {
    let fixture = try trialFixture()
    let report = try await RestoreOnlyHardwareTrialSimulation.run(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 14
    )

    #expect(report.finalPhase == .baselineVerified)
    #expect(report.durableCommitCount == 4)
    #expect(report.setAttemptCount == 1)
    #expect(report.readBackCount == 2)
    #expect(report.liveBaselineReadCount == 2)
    #expect(report.operationLeaseCount == 1)
}

private enum TrialTransportBehavior: Sendable {
    case exact
    case wrongAcknowledgement
    case failVerificationRead
    case suspendDuringDispatch
}

private enum TrialBoundaryFailure: Error {
    case verificationRead
    case exhaustedBaselineResponses
}

private final class TrialCommitFault: @unchecked Sendable {
    private let lock = NSLock()
    private let failReceiptNumber: Int
    private var receiptCount = 0

    init(failReceiptNumber: Int) {
        self.failReceiptNumber = failReceiptNumber
    }

    func reach(_ boundary: RestoreOnlyHardwareTrialCommitBoundary) throws {
        guard boundary == .beforeReceiptReturn else { return }
        lock.lock()
        receiptCount += 1
        let shouldFail = receiptCount == failReceiptNumber
        lock.unlock()
        if shouldFail { throw TrialBoundaryFailure.verificationRead }
    }
}

private actor TrialBoundaryTransport: RestoreOnlyHardwareTrialTransport {
    let session: RestoreOnlyHardwareTrialSession
    let state: DeviceTransactionWireState
    let behavior: TrialTransportBehavior
    private(set) var setCount = 0
    private(set) var readCount = 0

    init(
        session: RestoreOnlyHardwareTrialSession,
        state: DeviceTransactionWireState,
        behavior: TrialTransportBehavior
    ) {
        self.session = session
        self.state = state
        self.behavior = behavior
    }

    func currentSession() -> RestoreOnlyHardwareTrialSession { session }

    func readPrecisionReporting(
        request: HIDPP20LongMessage,
        expectedSession: RestoreOnlyHardwareTrialSession
    ) throws -> DeviceTransactionWireState {
        guard expectedSession == session,
              request.functionID == 2,
              Array(request.parameters.prefix(2)) == [0, 0xED] else {
            throw RestoreOnlyHardwareTrialError.invalidPacket
        }
        readCount += 1
        if behavior == .failVerificationRead, readCount == 2 {
            throw TrialBoundaryFailure.verificationRead
        }
        return state
    }

    func setPrecisionTemporaryDiversionOff(
        request: HIDPP20LongMessage,
        expectedSession: RestoreOnlyHardwareTrialSession
    ) async throws -> HIDPP20LongMessage {
        guard expectedSession == session,
              request.functionID == 3,
              Array(request.parameters.prefix(5)) == [0, 0xED, 0x02, 0, 0] else {
            throw RestoreOnlyHardwareTrialError.invalidPacket
        }
        setCount += 1
        if behavior == .suspendDuringDispatch {
            try await Task.sleep(for: .seconds(30))
        }
        guard behavior == .wrongAcknowledgement else { return request }
        var bytes = request.bytes
        bytes[9] = 1
        return try HIDPP20LongMessage(bytes: bytes)
    }
}

private actor TrialBaselineReader: RestoreOnlyHardwareTrialBaselineReader {
    private var responses: [Data]

    init(responses: [Data]) {
        self.responses = responses
    }

    func readLiveBaseline() throws -> Data {
        guard !responses.isEmpty else {
            throw TrialBoundaryFailure.exhaustedBaselineResponses
        }
        return responses.removeFirst()
    }
}

private func trialRunnerSetup(
    fixture: (data: Data, feature: HIDPP20FeatureDescriptor),
    transportBehavior: TrialTransportBehavior = .exact,
    baselineReader: TrialBaselineReader? = nil
) async throws -> (
    runner: RestoreOnlyHardwareTrialRunner,
    repository: DurableRestoreOnlyHardwareTrialRepository,
    transport: TrialBoundaryTransport,
    directory: URL
) {
    let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
        sourceBaselineData: fixture.data,
        currentFeature: fixture.feature,
        connectionEpoch: 112
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "restore-trial-runner-\(UUID().uuidString)",
        isDirectory: true
    )
    let repository = DurableRestoreOnlyHardwareTrialRepository(
        fileURL: directory.appendingPathComponent("trial.json")
    )
    let transport = TrialBoundaryTransport(
        session: trialSession(for: prepared),
        state: prepared.preflightState,
        behavior: transportBehavior
    )
    let reader = baselineReader ?? TrialBaselineReader(
        responses: [fixture.data, fixture.data]
    )
    let runner = RestoreOnlyHardwareTrialRunner(
        repository: repository,
        transport: transport,
        baselineReader: reader,
        liveJournalURL: directory.appendingPathComponent(
            "device-state-journal.json"
        )
    )
    try await runner.install(prepared)
    return (runner, repository, transport, directory)
}

private func trialFixture() throws -> (data: Data, feature: HIDPP20FeatureDescriptor) {
    let feature = HIDPP20FeatureDescriptor(
        index: 0x0A,
        type: 0,
        version: 3,
        rawParameters: trialPadded([0x0A, 0x00, 0x03])
    )
    let controlID: UInt16 = 0x00ED
    let entry = try DeviceControlJournalEntry(
        controlInfo: ReprogControlInfo(
            index: 5,
            controlID: controlID,
            taskID: 0x00C4,
            capabilityFlags: 0x71,
            position: 0,
            group: 2,
            groupMask: 3,
            rawXYCapability: true,
            rawParameters: trialPadded([0, 0xED, 0, 0xC4, 0x71, 0, 2, 3, 1])
        ),
        baselineReporting: ReprogControlReportingState(
            controlID: controlID,
            rawFlags: 0,
            rawMappedControlID: 0,
            rawParameters: trialPadded([0, 0xED, 0, 0, 0])
        )
    )
    let journal = try DeviceStateJournal(
        transactionID: UUID(uuidString: "75465823-37D5-4685-A6C8-398A9B0D72F1")!,
        appBuild: "trial-test",
        device: JournalDeviceIdentity(
            deviceID: "mx-ergo",
            vendorID: 0x046D,
            productID: 0xB01D,
            transport: "Bluetooth Low Energy",
            serialNumber: "7865BCA9046ED9FF",
            locationID: 1,
            firmwareIdentity: "firmware-bound"
        ),
        feature: feature,
        expectedControlCount: 1,
        controls: [entry],
        now: Date(timeIntervalSince1970: 1_000)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try encoder.encode(journal), feature)
}

private func trialSession(
    for record: RestoreOnlyHardwareTrialRecord
) -> RestoreOnlyHardwareTrialSession {
    RestoreOnlyHardwareTrialSession(
        device: record.device,
        featureIndex: record.featureIndex,
        featureVersion: record.featureVersion,
        connectionEpoch: record.connectionEpoch,
        matchingDeviceCount: 1,
        outputReportByteCount: HIDPP20LongMessage.byteCount
    )
}

private func trialPadded(_ prefix: [UInt8]) -> [UInt8] {
    prefix + Array(repeating: 0, count: HIDPP20LongMessage.parameterCount - prefix.count)
}
