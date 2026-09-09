import CryptoKit
import Foundation
import MXErgoHIDPP
import Testing
@testable import MXErgoPrecisionTransport

@Test func testTransportActivatesAndRestoresWithExactAcknowledgementsAndIndependentGets() async throws {
    let fixture = try precisionFixture()
    let reader = ScriptedPrecisionReader(steps: [
        .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
        .frame(inputFrame(fixture.plan.applySetRequest.bytes, fixture: fixture)),
        .frame(try reportingFrame(fixture.plan.activeState, fixture: fixture)),
        .frame(try reportingFrame(fixture.plan.activeState, fixture: fixture)),
        .frame(inputFrame(fixture.plan.restoreSetRequest.bytes, fixture: fixture)),
        .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
    ])
    let writer = ScriptedPrecisionWriter(steps: Array(repeating: .returnCode(0), count: 6))
    let harness = try await makeHarness(fixture: fixture, writer: writer, reader: reader)

    let active = try await harness.lifecycle.activate()
    let activeControl = try active.control(0x00ED)
    #expect(activeControl.phase == .appliedVerified)
    #expect(activeControl.attempts.last?.invocationEvidence?.responseKind == .exactEcho)

    let restored = try await harness.lifecycle.deactivate()
    let restoredControl = try restored.control(0x00ED)
    #expect(restoredControl.phase == .restoredVerified)
    #expect(restoredControl.attempts.map(\.kind) == [.apply, .restore])
    #expect(restoredControl.attempts.allSatisfy {
        $0.invocationEvidence?.responseKind == .exactEcho
    })

    let frames = writer.frames()
    #expect(frames.map(\.bytes) == [
        fixture.plan.verificationRequest.bytes,
        fixture.plan.applySetRequest.bytes,
        fixture.plan.verificationRequest.bytes,
        fixture.plan.verificationRequest.bytes,
        fixture.plan.restoreSetRequest.bytes,
        fixture.plan.verificationRequest.bytes,
    ])
    #expect(Set(frames.map(\.requestID)).count == frames.count)
    #expect(frames.allSatisfy {
        $0.reportType == .output
            && $0.reportID == HIDPP20LongMessage.reportID
            && $0.device == fixture.session.device
            && $0.connectionEpoch == fixture.session.connectionEpoch
            && $0.rootGeneration == fixture.rootGeneration
    })
}

@Test func correlatedNonEchoEvidenceNeverOverridesTheSeparateGet() async throws {
    let fixture = try precisionFixture()
    var nonEcho = fixture.plan.applySetRequest.bytes
    nonEcho[8] = 0x7A
    let reader = ScriptedPrecisionReader(steps: [
        .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
        .frame(inputFrame(nonEcho, fixture: fixture)),
        // The acknowledgement is deliberately followed by an authoritative
        // baseline GET, proving that SET evidence cannot establish activation.
        .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
    ])
    let writer = ScriptedPrecisionWriter(steps: Array(repeating: .returnCode(0), count: 3))
    let harness = try await makeHarness(fixture: fixture, writer: writer, reader: reader)

    await #expect(throws: DeviceTransactionCoordinatorError.applyNotObserved(0x00ED)) {
        try await harness.lifecycle.activate()
    }
    let durable = try #require(try await harness.repository.loadValidated())
    let control = try durable.control(0x00ED)
    #expect(control.phase == .baselineVerified)
    #expect(control.attempts.last?.outcome == .observedNoMutation)
    #expect(control.attempts.last?.invocationEvidence?.responseKind == .correlatedNonEcho)
    #expect(control.attempts.last?.invocationEvidence?.responseBytes == nonEcho)
}

@Test func unrelatedValidFrameIsIgnoredUntilTheMatchingReplyArrives() async throws {
    let fixture = try precisionFixture()
    let unrelated = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: fixture.session.featureIndex,
        functionID: 1,
        softwareID: 0x0E,
        parameters: padded([0x00, 0xED])
    )
    let reader = ScriptedPrecisionReader(steps: [
        .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
        .frame(inputFrame(unrelated.bytes, fixture: fixture)),
        .frame(inputFrame(fixture.plan.applySetRequest.bytes, fixture: fixture)),
        .frame(try reportingFrame(fixture.plan.activeState, fixture: fixture)),
    ])
    let writer = ScriptedPrecisionWriter(
        steps: Array(repeating: .returnCode(0), count: 3)
    )
    let harness = try await makeHarness(fixture: fixture, writer: writer, reader: reader)

    let active = try await harness.lifecycle.activate()

    #expect(try active.control(0x00ED).phase == .appliedVerified)
    #expect(writer.frames().map(\.bytes) == [
        fixture.plan.verificationRequest.bytes,
        fixture.plan.applySetRequest.bytes,
        fixture.plan.verificationRequest.bytes,
    ])
    #expect(!(await harness.adapter.isPoisoned))
}

@Test func callbackWindowArmsBeforeSynchronousWriterReplyAndSupportsReuse() async throws {
    let fixture = try precisionFixture()
    let channel = PrecisionCallbackInputChannel(
        expectedDevice: fixture.session.device,
        expectedConnectionEpoch: fixture.session.connectionEpoch,
        expectedRootGeneration: fixture.rootGeneration
    )
    let unrelated = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: fixture.session.featureIndex,
        functionID: 1,
        softwareID: 0x0E,
        parameters: padded([0x00, 0xED])
    )
    let writer = CallbackEmittingPrecisionWriter(
        channel: channel,
        batches: [
            [try reportingFrame(fixture.plan.baseline, fixture: fixture)],
            [
                inputFrame(unrelated.bytes, fixture: fixture),
                inputFrame(fixture.plan.applySetRequest.bytes, fixture: fixture),
            ],
            [try reportingFrame(fixture.plan.activeState, fixture: fixture)],
        ]
    )
    let harness = try await makeHarness(
        fixture: fixture,
        writer: writer,
        reader: channel
    )

    let active = try await harness.lifecycle.activate()

    #expect(try active.control(0x00ED).phase == .appliedVerified)
    #expect(channel.acceptedCount == 4)
    #expect(channel.finishCount == 3)
    #expect(channel.cancelCount == 0)
    #expect(!channel.hasActiveRequest)
    #expect(writer.frames().map(\.bytes) == [
        fixture.plan.verificationRequest.bytes,
        fixture.plan.applySetRequest.bytes,
        fixture.plan.verificationRequest.bytes,
    ])
}

@Test func concurrentDisconnectWakesABlockedReplyReadAndPoisonsTheAttempt() async throws {
    let fixture = try precisionFixture()
    let reader = BlockingPrecisionReader(
        initialFrames: [try reportingFrame(fixture.plan.baseline, fixture: fixture)]
    )
    let writer = ScriptedPrecisionWriter(steps: [.returnCode(0), .returnCode(0)])
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let journalURL = directory.appendingPathComponent("disconnect-wakeup-v3.json")
    let repository = DurableDeviceTransactionFileRepository(fileURL: journalURL)
    let adapter = try makeAdapter(
        fixture: fixture,
        journalURL: journalURL,
        writer: writer,
        reader: reader,
        competitorProbe: { [] },
        operationTimeoutNanoseconds: 1_000_000_000
    )
    let coordinator = DeviceTransactionCoordinator(
        repository: repository,
        transport: adapter
    )
    _ = try await coordinator.installPreparedEnvelope(
        DeviceTransactionEnvelope(baselineJournal: fixture.journal)
    )
    let lifecycle = PrecisionTemporaryDiversionLifecycle(
        coordinator: coordinator,
        plan: fixture.plan,
        safetyGate: AlwaysAllowingTestSafetyGate()
    )
    let task = Task {
        defer { reader.pendingReadEntry.finish() }
        return try await lifecycle.activate()
    }
    try await reader.pendingReadEntry.wait()
    await adapter.disconnected()

    await #expect(throws: PrecisionTransportError.poisoned) {
        try await task.value
    }
    #expect(await adapter.isPoisoned)
    #expect(reader.cancelCount == 1)
    #expect(writer.frames().filter {
        $0.bytes == fixture.plan.applySetRequest.bytes
    }.count == 1)
    let durable = try #require(try await repository.loadValidated())
    #expect(try durable.control(0x00ED).phase == .applyMayHaveOccurred)
}

@Test func adapterOwnedDeadlineCancelsABlockedPreflightReadWithoutWriteAhead() async throws {
    let fixture = try precisionFixture()
    let reader = BlockingPrecisionReader(initialFrames: [])
    let writer = ScriptedPrecisionWriter(steps: [.returnCode(0)])
    let harness = try await makeHarness(
        fixture: fixture,
        writer: writer,
        reader: reader,
        operationTimeoutNanoseconds: 30_000_000
    )
    let before = try #require(try await harness.repository.loadValidated())

    await #expect(throws: PrecisionTransportError.timeout) {
        try await harness.lifecycle.activate()
    }

    #expect(reader.cancelCount == 1)
    #expect(await harness.adapter.isPoisoned)
    let after = try #require(try await harness.repository.loadValidated())
    #expect(after == before)
    #expect(try after.control(0x00ED).attempts.isEmpty)
    #expect(writer.frames().map(\.bytes)
        == [fixture.plan.verificationRequest.bytes])
}

@Test func externalCancellationUnblocksANonCooperativeReaderThroughItsCancellationSeam() async throws {
    let fixture = try precisionFixture()
    let reader = NonCooperativePrecisionReader()
    let writer = ScriptedPrecisionWriter(steps: [.returnCode(0)])
    let harness = try await makeHarness(
        fixture: fixture,
        writer: writer,
        reader: reader,
        operationTimeoutNanoseconds: 1_000_000_000
    )
    let task = Task {
        try await harness.adapter.readReporting(
            controlID: 0x00ED,
            expectedSession: fixture.session
        )
    }
    try await waitUntil(nanoseconds: 1_000_000_000) {
        reader.hasPendingRead
    }

    task.cancel()

    await #expect(throws: PrecisionTransportError.cancelled) {
        try await task.value
    }
    #expect(reader.cancelCount == 1)
    #expect(await harness.adapter.isPoisoned)
    #expect(writer.frames().map(\.bytes)
        == [fixture.plan.verificationRequest.bytes])
}

@Test func externalCancellationUnblocksANonCooperativeWriterThroughItsCancellationSeam() async throws {
    let fixture = try precisionFixture()
    let reader = ScriptedPrecisionReader(steps: [])
    let writer = NonCooperativePrecisionWriter()
    let harness = try await makeHarness(
        fixture: fixture,
        writer: writer,
        reader: reader,
        operationTimeoutNanoseconds: 1_000_000_000
    )
    let task = Task {
        try await harness.adapter.readReporting(
            controlID: 0x00ED,
            expectedSession: fixture.session
        )
    }
    try await waitUntil(nanoseconds: 1_000_000_000) {
        writer.hasPendingWrite
    }

    task.cancel()

    await #expect(throws: PrecisionTransportError.cancelled) {
        try await task.value
    }
    #expect(writer.cancelCount == 1)
    #expect(await harness.adapter.isPoisoned)
    #expect(writer.frameCount == 1)
}

@Test func cancellationBeforeWriterWaiterInstallationIsStickyAndBounded() async throws {
    let fixture = try precisionFixture()
    let gate = TestSuspensionGate()
    let writer = GatedEntryPrecisionWriter(gate: gate)
    let reader = ScriptedPrecisionReader(steps: [])
    let harness = try await makeHarness(
        fixture: fixture,
        writer: writer,
        reader: reader,
        operationTimeoutNanoseconds: 1_000_000_000
    )
    await gate.arm()
    let task = Task {
        try await harness.adapter.readReporting(
            controlID: 0x00ED,
            expectedSession: fixture.session
        )
    }
    try await waitUntil(nanoseconds: 1_000_000_000) {
        await gate.isWaiting
    }

    task.cancel()
    await gate.release()

    await #expect(throws: PrecisionTransportError.cancelled) {
        try await task.value
    }
    #expect(writer.cancelCount == 1)
    #expect(await harness.adapter.isPoisoned)
}

@Test func cancellationBeforeReaderWaiterInstallationIsStickyAndBounded() async throws {
    let fixture = try precisionFixture()
    let gate = TestSuspensionGate()
    let reader = GatedEntryPrecisionReader(gate: gate)
    let writer = ScriptedPrecisionWriter(steps: [.returnCode(0)])
    let harness = try await makeHarness(
        fixture: fixture,
        writer: writer,
        reader: reader,
        operationTimeoutNanoseconds: 1_000_000_000
    )
    await gate.arm()
    let task = Task {
        try await harness.adapter.readReporting(
            controlID: 0x00ED,
            expectedSession: fixture.session
        )
    }
    try await waitUntil(nanoseconds: 1_000_000_000) {
        await gate.isWaiting
    }

    task.cancel()
    await gate.release()

    await #expect(throws: PrecisionTransportError.cancelled) {
        try await task.value
    }
    #expect(reader.cancelCount == 1)
    #expect(await harness.adapter.isPoisoned)
}

@Test func disconnectDuringPreparationCannotResurrectPreparedState() async throws {
    let fixture = try precisionFixture()
    let gate = TestSuspensionGate()
    let writer = ScriptedPrecisionWriter(steps: [])
    let reader = ScriptedPrecisionReader(steps: [])
    let harness = try await makeHarness(
        fixture: fixture,
        writer: writer,
        reader: reader,
        sessionProvider: {
            await gate.waitIfArmed()
            return fixture.session
        }
    )
    let durable = try #require(try await harness.repository.loadValidated())
    let mutation = DeviceTransactionMutation(
        transactionID: durable.transactionID,
        controlID: 0x00ED,
        attemptID: UUID(),
        kind: .apply,
        state: fixture.plan.activeState
    )
    await gate.arm()
    let preparation = Task {
        try await harness.adapter.prepare(
            mutation,
            expectedSession: fixture.session,
            expectedCommittedRevision: durable.revision + 1
        )
    }
    try await waitUntil(nanoseconds: 1_000_000_000) {
        await gate.isWaiting
    }

    await harness.adapter.disconnected()
    await gate.release()

    await #expect(throws: PrecisionTransportError.poisoned) {
        try await preparation.value
    }
    await #expect(throws: PrecisionTransportError.poisoned) {
        try await harness.adapter.currentSession()
    }
    #expect(await harness.adapter.isPoisoned)
    #expect(writer.frames().isEmpty)
}

@Test func preparationDisposalIsReusableOnlyWhenWriteAheadWasDefinitelyNotAttempted() async throws {
    let fixture = try precisionFixture()
    let reader = ScriptedPrecisionReader(steps: [
        .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
    ])
    let writer = ScriptedPrecisionWriter(steps: [.returnCode(0)])
    let harness = try await makeHarness(fixture: fixture, writer: writer, reader: reader)
    let durable = try #require(try await harness.repository.loadValidated())
    let proposed = DeviceTransactionMutation(
        transactionID: durable.transactionID,
        controlID: 0x00ED,
        attemptID: UUID(),
        kind: .apply,
        state: fixture.plan.activeState
    )
    let first = try await harness.adapter.prepare(
        proposed,
        expectedSession: fixture.session,
        expectedCommittedRevision: durable.revision + 1
    )

    await harness.adapter.abandon(
        first,
        disposition: .discardedBeforeWriteAhead
    )
    #expect(try await harness.adapter.readReporting(
        controlID: 0x00ED,
        expectedSession: fixture.session
    ) == fixture.plan.baseline)

    let second = try await harness.adapter.prepare(
        proposed,
        expectedSession: fixture.session,
        expectedCommittedRevision: durable.revision + 1
    )
    await harness.adapter.abandon(
        second,
        disposition: .writeAheadVisibilityUnknown
    )
    #expect(await harness.adapter.isPoisoned)
    await #expect(throws: PrecisionTransportError.poisoned) {
        try await harness.adapter.readReporting(
            controlID: 0x00ED,
            expectedSession: fixture.session
        )
    }
    let firstFrames = writer.frames()
    #expect(!firstFrames.contains {
        $0.bytes == fixture.plan.applySetRequest.bytes
    })
}

@Test func restoreAlreadyAtBaselineCompletesWithoutANewAttemptOrSet() async throws {
    let fixture = try precisionFixture()
    let reader = ScriptedPrecisionReader(steps: [
        .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
        .frame(inputFrame(fixture.plan.applySetRequest.bytes, fixture: fixture)),
        .frame(try reportingFrame(fixture.plan.activeState, fixture: fixture)),
        .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
    ])
    let writer = ScriptedPrecisionWriter(
        steps: Array(repeating: .returnCode(0), count: 4)
    )
    let harness = try await makeHarness(fixture: fixture, writer: writer, reader: reader)
    _ = try await harness.lifecycle.activate()

    let restored = try await harness.lifecycle.deactivate()

    let control = try restored.control(0x00ED)
    #expect(control.phase == .restoredVerified)
    #expect(control.attempts.map(\.kind) == [.apply])
    let frames = writer.frames()
    #expect(!frames.contains {
        $0.bytes == fixture.plan.restoreSetRequest.bytes
    })
}

@Test func preparationCompetitorRejectionLeavesExactJournalBytesUnchangedAndSendsNoSet() async throws {
    let fixture = try precisionFixture()
    let competitors = ScriptedCompetitorProbe([
        [], // load the bound coordinator session
        [], [], [], // exact-baseline GET around its awaits
        [], // coordinator session recheck after the GET
        ["BetterTouchTool"], // prepare, before any WAL mutation
    ])
    let reader = ScriptedPrecisionReader(steps: [
        .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
    ])
    let writer = ScriptedPrecisionWriter(steps: [.returnCode(0)])
    let harness = try await makeHarness(
        fixture: fixture,
        writer: writer,
        reader: reader,
        competitorProbe: { await competitors.scan() }
    )
    let before = try Data(contentsOf: harness.journalURL)

    await #expect(throws: PrecisionTransportError
        .competingProcesses(["BetterTouchTool"])) {
        try await harness.lifecycle.activate()
    }

    let after = try Data(contentsOf: harness.journalURL)
    #expect(after == before)
    #expect(sha256(after) == sha256(before))
    let frames = writer.frames()
    #expect(frames.map(\.bytes) == [fixture.plan.verificationRequest.bytes])
    #expect(!frames.contains { $0.bytes == fixture.plan.applySetRequest.bytes })
}

@Test func ordinaryRestorePreflightPersistsThirdPartyConflictWithoutRestoreSet() async throws {
    let fixture = try precisionFixture()
    var driftBytes = fixture.plan.activeState.rawParameters
    driftBytes[15] = 0x80
    let drift = try DeviceTransactionWireState(rawParameters: driftBytes)
    let reader = ScriptedPrecisionReader(steps: [
        .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
        .frame(inputFrame(fixture.plan.applySetRequest.bytes, fixture: fixture)),
        .frame(try reportingFrame(fixture.plan.activeState, fixture: fixture)),
        .frame(try reportingFrame(drift, fixture: fixture)),
    ])
    let writer = ScriptedPrecisionWriter(steps: Array(repeating: .returnCode(0), count: 4))
    let harness = try await makeHarness(fixture: fixture, writer: writer, reader: reader)

    _ = try await harness.lifecycle.activate()
    await #expect(throws: DeviceTransactionCoordinatorError.conflicted(0x00ED)) {
        try await harness.lifecycle.deactivate()
    }

    let durable = try #require(try await harness.repository.loadValidated())
    let control = try durable.control(0x00ED)
    #expect(control.phase == .conflicted)
    #expect(control.conflictingObservation == drift)
    let frames = writer.frames()
    #expect(!frames.contains { $0.bytes == fixture.plan.restoreSetRequest.bytes })
}

@Test func setAcknowledgementTimeoutPoisonsTheEpochAndNeverRetriesOrInverts() async throws {
    let fixture = try precisionFixture()
    let reader = ScriptedPrecisionReader(steps: [
        .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
        .failure(.timeout),
    ])
    let writer = ScriptedPrecisionWriter(steps: [.returnCode(0), .returnCode(0)])
    let harness = try await makeHarness(fixture: fixture, writer: writer, reader: reader)

    await #expect(throws: PrecisionTransportError.poisoned) {
        try await harness.lifecycle.activate()
    }

    #expect(await harness.adapter.isPoisoned)
    let frames = writer.frames()
    #expect(frames.map(\.bytes) == [
        fixture.plan.verificationRequest.bytes,
        fixture.plan.applySetRequest.bytes,
    ])
    let durable = try #require(try await harness.repository.loadValidated())
    let control = try durable.control(0x00ED)
    #expect(control.phase == .applyMayHaveOccurred)
    #expect(control.attempts.count == 1)
    #expect(control.attempts.last?.outcome == .outcomeUnknown)
}

@Test func disconnectAfterSetPoisonsTheAdapterAndIgnoresAnyRecoveryShortcut() async throws {
    let fixture = try precisionFixture()
    let reader = ScriptedPrecisionReader(steps: [
        .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
        .failure(.disconnected),
    ])
    let writer = ScriptedPrecisionWriter(steps: [.returnCode(0), .returnCode(0)])
    let harness = try await makeHarness(fixture: fixture, writer: writer, reader: reader)

    await #expect(throws: PrecisionTransportError.poisoned) {
        try await harness.lifecycle.activate()
    }

    #expect(await harness.adapter.isPoisoned)
    let frames = writer.frames()
    #expect(frames.filter { $0.bytes == fixture.plan.applySetRequest.bytes }.count == 1)
    #expect(!frames.contains { $0.bytes == fixture.plan.restoreSetRequest.bytes })
    let durable = try #require(try await harness.repository.loadValidated())
    #expect(try durable.control(0x00ED).phase == .applyMayHaveOccurred)
}

@Test func cancellationInsideTheWriterBoundaryConsumesOneAttemptAndPoisons() async throws {
    let fixture = try precisionFixture()
    let entry = TestEntrySignal()
    let gate = TestSuspensionGate()
    await gate.arm()
    let reader = ScriptedPrecisionReader(steps: [
        .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
    ])
    let writer = ScriptedPrecisionWriter(steps: [
        .returnCode(0),
        .pause(entry: entry, gate: gate),
    ])
    let harness = try await makeHarness(fixture: fixture, writer: writer, reader: reader)
    let task = Task {
        defer { entry.finish() }
        return try await harness.lifecycle.activate()
    }
    try await entry.wait()
    task.cancel()
    await gate.release()
    await #expect(throws: CancellationError.self) {
        try await task.value
    }

    #expect(await harness.adapter.isPoisoned)
    let frames = writer.frames()
    #expect(frames.filter { $0.bytes == fixture.plan.applySetRequest.bytes }.count == 1)
    let durable = try #require(try await harness.repository.loadValidated())
    let control = try durable.control(0x00ED)
    #expect(control.phase == .applyMayHaveOccurred)
    #expect(control.attempts.count == 1)
}

@Test func crashRestartRecoveryReadsFirstAndNeverReplaysTheOldApplyAttempt() async throws {
    let fixture = try precisionFixture()
    let firstReader = ScriptedPrecisionReader(steps: [
        .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
        .frame(inputFrame(fixture.plan.applySetRequest.bytes, fixture: fixture)),
        .failure(.timeout), // crash-equivalent loss before authoritative GET
    ])
    let firstWriter = ScriptedPrecisionWriter(
        steps: Array(repeating: .returnCode(0), count: 3)
    )
    let first = try await makeHarness(
        fixture: fixture,
        writer: firstWriter,
        reader: firstReader
    )
    await #expect(throws: DeviceTransactionCoordinatorError.self) {
        try await first.lifecycle.activate()
    }
    let dirty = try #require(try await first.repository.loadValidated())
    let oldAttemptID = try #require(try dirty.control(0x00ED).attempts.last?.id)

    let restartedSession = DeviceTransactionSession(
        device: fixture.session.device,
        featureID: fixture.session.featureID,
        featureVersion: fixture.session.featureVersion,
        featureIndex: fixture.session.featureIndex,
        connectionEpoch: fixture.session.connectionEpoch + 1
    )
    let restartedFixture = PrecisionFixture(
        journal: fixture.journal,
        plan: fixture.plan,
        session: restartedSession,
        rootGeneration: fixture.rootGeneration + 1
    )
    let restartedReader = ScriptedPrecisionReader(steps: [
        .frame(try reportingFrame(fixture.plan.activeState, fixture: restartedFixture)),
        .frame(inputFrame(fixture.plan.restoreSetRequest.bytes, fixture: restartedFixture)),
        .frame(try reportingFrame(fixture.plan.baseline, fixture: restartedFixture)),
    ])
    let restartedWriter = ScriptedPrecisionWriter(
        steps: Array(repeating: .returnCode(0), count: 3)
    )
    let restartedAdapter = try makeAdapter(
        fixture: restartedFixture,
        journalURL: first.journalURL,
        writer: restartedWriter,
        reader: restartedReader,
        competitorProbe: { [] }
    )
    let restartedCoordinator = DeviceTransactionCoordinator(
        repository: first.repository,
        transport: restartedAdapter
    )
    let restartedLifecycle = PrecisionTemporaryDiversionLifecycle(
        coordinator: restartedCoordinator,
        plan: fixture.plan,
        safetyGate: AlwaysAllowingTestSafetyGate()
    )

    let report = try await restartedLifecycle.recoverExplicitly()
    #expect(report.restoredControlIDs == [0x00ED])
    #expect(report.finalStatus == .completed)
    let frames = restartedWriter.frames()
    #expect(frames.map(\.bytes) == [
        fixture.plan.verificationRequest.bytes,
        fixture.plan.restoreSetRequest.bytes,
        fixture.plan.verificationRequest.bytes,
    ])
    let final = try #require(try await first.repository.loadValidated())
    let attempts = try final.control(0x00ED).attempts
    #expect(attempts.first?.id == oldAttemptID)
    #expect(attempts.map(\.kind) == [.apply, .restore])
    #expect(attempts[1].id != oldAttemptID)
}

@Test func lateCompetitorAfterWalBeforeSetPoisonsWithoutSetRetryOrInverse() async throws {
    let fixture = try precisionFixture()
    let competitors = ScriptedCompetitorProbe([
        [],         // load the bound coordinator session
        [], [], [], // read preflight
        [],         // coordinator session recheck after preflight
        [], [],     // preparation around durable snapshot
        [],         // coordinator session recheck after preparation
        [],         // coordinator session recheck after WAL
        [], [],     // invocation around durable authorization snapshot
        ["BetterTouchTool"], // final check immediately before writer
    ])
    let reader = ScriptedPrecisionReader(steps: [
        .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
    ])
    let writer = ScriptedPrecisionWriter(steps: [.returnCode(0)])
    let harness = try await makeHarness(
        fixture: fixture,
        writer: writer,
        reader: reader,
        competitorProbe: { await competitors.scan() }
    )

    await #expect(throws: PrecisionTransportError.poisoned) {
        try await harness.lifecycle.activate()
    }

    let frames = writer.frames()
    #expect(frames.map(\.bytes) == [fixture.plan.verificationRequest.bytes])
    #expect(!frames.contains { $0.bytes == fixture.plan.applySetRequest.bytes })
    #expect(!frames.contains { $0.bytes == fixture.plan.restoreSetRequest.bytes })
    let durable = try #require(try await harness.repository.loadValidated())
    #expect(try durable.control(0x00ED).phase == .applyMayHaveOccurred)
    #expect(try durable.control(0x00ED).attempts.last?.outcome == .outcomeUnknown)
}

@Test func exactAllowlistRejectsCallerSelectedMutationBeforeAnySet() async throws {
    let fixture = try precisionFixture()
    let reader = ScriptedPrecisionReader(steps: [])
    let writer = ScriptedPrecisionWriter(steps: [])
    let harness = try await makeHarness(fixture: fixture, writer: writer, reader: reader)
    let invalidState = try fixture.plan.baseline.replacingRawFlags(
        0x02,
        featureVersion: 3
    )
    let proposed = DeviceTransactionMutation(
        transactionID: try #require(try await harness.repository.loadValidated()).transactionID,
        controlID: 0x00ED,
        attemptID: UUID(),
        kind: .apply,
        state: invalidState
    )

    await #expect(throws: PrecisionTransportError.invalidMutation) {
        try await harness.adapter.prepare(
            proposed,
            expectedSession: fixture.session,
            expectedCommittedRevision: 1
        )
    }
    #expect(writer.frames().isEmpty)
}

@Test func authorizationTamperingIsRejectedBeforeWriterEntryAndPoisonsTheAttempt() async throws {
    for tampering in AuthorizationTampering.allCases {
        let fixture = try precisionFixture()
        let reader = ScriptedPrecisionReader(steps: [])
        let writer = ScriptedPrecisionWriter(steps: [])
        let harness = try await makeHarness(
            fixture: fixture,
            writer: writer,
            reader: reader
        )
        let durable = try #require(try await harness.repository.loadValidated())
        let attemptID = UUID()
        let mutation = DeviceTransactionMutation(
            transactionID: durable.transactionID,
            controlID: 0x00ED,
            attemptID: attemptID,
            kind: .apply,
            state: fixture.plan.activeState
        )
        let prepared = try await harness.adapter.prepare(
            mutation,
            expectedSession: fixture.session,
            expectedCommittedRevision: durable.revision + 1
        )
        let durableAttemptID = tampering == .activeAttempt ? UUID() : attemptID
        let reduction = try DeviceTransactionReducer.reduce(
            durable,
            event: .armApply(
                controlID: 0x00ED,
                intended: fixture.plan.activeState,
                attemptID: durableAttemptID,
                now: Date(timeIntervalSince1970: 10)
            )
        )
        let receipt = try await harness.repository.commit(
            reduction.envelope,
            expectedRevision: reduction.previousRevision
        )
        let authorization: DeviceTransactionDurableCommitReceipt
        switch tampering {
        case .transaction:
            authorization = DeviceTransactionDurableCommitReceipt(
                transactionID: UUID(),
                revision: receipt.revision,
                sha256: receipt.sha256
            )
        case .revision:
            authorization = DeviceTransactionDurableCommitReceipt(
                transactionID: receipt.transactionID,
                revision: receipt.revision + 1,
                sha256: receipt.sha256
            )
        case .sha256:
            authorization = DeviceTransactionDurableCommitReceipt(
                transactionID: receipt.transactionID,
                revision: receipt.revision,
                sha256: String(repeating: "0", count: 64)
            )
        case .activeAttempt:
            authorization = receipt
        }

        await #expect(throws: DeviceTransactionTransportInvocationError.self) {
            try await harness.adapter.invoke(
                prepared,
                authorization: authorization
            )
        }
        #expect(await harness.adapter.isPoisoned)
        #expect(writer.frames().isEmpty)
    }
}

@Test func duplicateInvokeCannotCrossTheWriterBoundaryTwice() async throws {
    let fixture = try precisionFixture()
    let reader = ScriptedPrecisionReader(steps: [
        .frame(inputFrame(fixture.plan.applySetRequest.bytes, fixture: fixture)),
    ])
    let writer = ScriptedPrecisionWriter(steps: [.returnCode(0)])
    let harness = try await makeHarness(fixture: fixture, writer: writer, reader: reader)
    let durable = try #require(try await harness.repository.loadValidated())
    let mutation = DeviceTransactionMutation(
        transactionID: durable.transactionID,
        controlID: 0x00ED,
        attemptID: UUID(),
        kind: .apply,
        state: fixture.plan.activeState
    )
    let prepared = try await harness.adapter.prepare(
        mutation,
        expectedSession: fixture.session,
        expectedCommittedRevision: durable.revision + 1
    )
    let reduction = try DeviceTransactionReducer.reduce(
        durable,
        event: .armApply(
            controlID: 0x00ED,
            intended: fixture.plan.activeState,
            attemptID: mutation.attemptID,
            now: Date(timeIntervalSince1970: 11)
        )
    )
    let receipt = try await harness.repository.commit(
        reduction.envelope,
        expectedRevision: reduction.previousRevision
    )

    _ = try await harness.adapter.invoke(prepared, authorization: receipt)
    await #expect(throws: DeviceTransactionTransportInvocationError.self) {
        try await harness.adapter.invoke(prepared, authorization: receipt)
    }

    #expect(await harness.adapter.isPoisoned)
    #expect(writer.frames().filter {
        $0.bytes == fixture.plan.applySetRequest.bytes
    }.count == 1)
}

@Test func writerThrowAndNonzeroReturnAreOutcomeUnknownWithoutRetryOrInverse() async throws {
    let writerFailures: [ScriptedPrecisionWriter.Step] = [
        .returnCode(-536_870_212),
        .failure(.disconnected),
    ]
    for failure in writerFailures {
        let fixture = try precisionFixture()
        let reader = ScriptedPrecisionReader(steps: [
            .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
        ])
        let writer = ScriptedPrecisionWriter(steps: [.returnCode(0), failure])
        let harness = try await makeHarness(
            fixture: fixture,
            writer: writer,
            reader: reader
        )

        await #expect(throws: PrecisionTransportError.poisoned) {
            try await harness.lifecycle.activate()
        }

        #expect(await harness.adapter.isPoisoned)
        let frames = writer.frames()
        #expect(frames.filter {
            $0.bytes == fixture.plan.applySetRequest.bytes
        }.count == 1)
        #expect(!frames.contains {
            $0.bytes == fixture.plan.restoreSetRequest.bytes
        })
        let durable = try #require(try await harness.repository.loadValidated())
        #expect(try durable.control(0x00ED).phase == .applyMayHaveOccurred)
        #expect(try durable.control(0x00ED).attempts.last?.outcome == .outcomeUnknown)
    }
}

@Test func setProtocolErrorIsEvidenceOnlyAndIndependentGetRemainsAuthoritative() async throws {
    let fixture = try precisionFixture()
    let error = try protocolErrorFrame(
        for: fixture.plan.applySetRequest,
        fixture: fixture,
        code: .busy
    )
    let reader = ScriptedPrecisionReader(steps: [
        .frame(try reportingFrame(fixture.plan.baseline, fixture: fixture)),
        .frame(error),
        .frame(try reportingFrame(fixture.plan.activeState, fixture: fixture)),
    ])
    let writer = ScriptedPrecisionWriter(
        steps: Array(repeating: .returnCode(0), count: 3)
    )
    let harness = try await makeHarness(fixture: fixture, writer: writer, reader: reader)

    let active = try await harness.lifecycle.activate()

    let control = try active.control(0x00ED)
    #expect(control.phase == .appliedVerified)
    #expect(control.attempts.last?.invocationEvidence?.responseKind == .protocolError)
    #expect(control.attempts.last?.invocationEvidence?.responseBytes == error.bytes)
}

@Test func getProtocolErrorFailsBeforeWriteAheadAndPoisonsTheReadEpoch() async throws {
    let fixture = try precisionFixture()
    let error = try protocolErrorFrame(
        for: fixture.plan.verificationRequest,
        fixture: fixture,
        code: .busy
    )
    let reader = ScriptedPrecisionReader(steps: [.frame(error)])
    let writer = ScriptedPrecisionWriter(steps: [.returnCode(0)])
    let harness = try await makeHarness(fixture: fixture, writer: writer, reader: reader)
    let before = try #require(try await harness.repository.loadValidated())

    await #expect(throws: PrecisionTransportError
        .protocolError(HIDPP20ProtocolErrorCode.busy.rawValue)) {
        try await harness.lifecycle.activate()
    }

    #expect(await harness.adapter.isPoisoned)
    let after = try #require(try await harness.repository.loadValidated())
    #expect(after == before)
    #expect(try after.control(0x00ED).attempts.isEmpty)
    #expect(writer.frames().map(\.bytes)
        == [fixture.plan.verificationRequest.bytes])
}

private struct PrecisionHarness {
    let journalURL: URL
    let repository: DurableDeviceTransactionFileRepository
    let adapter: PrecisionTransportAdapter
    let lifecycle: PrecisionTemporaryDiversionLifecycle
}

private enum AuthorizationTampering: CaseIterable {
    case transaction
    case revision
    case sha256
    case activeAttempt
}

private struct PrecisionFixture {
    let journal: DeviceStateJournal
    let plan: PrecisionTemporaryDiversionPlan
    let session: DeviceTransactionSession
    let rootGeneration: UInt64
}

private func makeHarness(
    fixture: PrecisionFixture,
    writer: any PrecisionTransportReportWriter,
    reader: any PrecisionTransportReportReader,
    competitorProbe: @escaping PrecisionTransportAdapter.CompetitorProbe = { [] },
    sessionProvider: PrecisionTransportAdapter.SessionProvider? = nil,
    operationTimeoutNanoseconds: UInt64 = 5_000_000_000
) async throws -> PrecisionHarness {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let journalURL = directory.appendingPathComponent("precision-test-transport-v3.json")
    let repository = DurableDeviceTransactionFileRepository(fileURL: journalURL)
    let adapter = try makeAdapter(
        fixture: fixture,
        journalURL: journalURL,
        writer: writer,
        reader: reader,
        competitorProbe: competitorProbe,
        sessionProvider: sessionProvider,
        operationTimeoutNanoseconds: operationTimeoutNanoseconds
    )
    let coordinator = DeviceTransactionCoordinator(
        repository: repository,
        transport: adapter
    )
    _ = try await coordinator.installPreparedEnvelope(
        DeviceTransactionEnvelope(baselineJournal: fixture.journal)
    )
    let lifecycle = PrecisionTemporaryDiversionLifecycle(
        coordinator: coordinator,
        plan: fixture.plan,
        safetyGate: AlwaysAllowingTestSafetyGate()
    )
    return PrecisionHarness(
        journalURL: journalURL,
        repository: repository,
        adapter: adapter,
        lifecycle: lifecycle
    )
}

private func makeAdapter(
    fixture: PrecisionFixture,
    journalURL: URL,
    writer: any PrecisionTransportReportWriter,
    reader: any PrecisionTransportReportReader,
    competitorProbe: @escaping PrecisionTransportAdapter.CompetitorProbe,
    sessionProvider: PrecisionTransportAdapter.SessionProvider? = nil,
    connectionValidator: @escaping @Sendable () throws -> Void = {},
    operationTimeoutNanoseconds: UInt64 = 5_000_000_000
) throws -> PrecisionTransportAdapter {
    try PrecisionTransportAdapter(
        plan: fixture.plan,
        binding: PrecisionTransportBinding(
            session: fixture.session,
            rootGeneration: fixture.rootGeneration
        ),
        writer: writer,
        reader: reader,
        sessionProvider: sessionProvider ?? { fixture.session },
        rootGenerationProvider: { fixture.rootGeneration },
        competitorProbe: competitorProbe,
        durableSnapshotLoader: {
            let data = try Data(contentsOf: journalURL)
            let envelope = try JSONDecoder().decode(
                DeviceTransactionEnvelope.self,
                from: data
            )
            try envelope.validate()
            return PrecisionTransportDurableSnapshot(
                envelope: envelope,
                sha256: sha256(data)
            )
        },
        connectionValidator: connectionValidator,
        operationTimeoutNanoseconds: operationTimeoutNanoseconds
    )
}

// Buffered entry evidence survives an early callback. Finishing without an
// entry makes a failed operation fail its observer instead of leaving it stuck.
private struct TestEntrySignal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func signal() { continuation.yield(()); continuation.finish() }
    func finish() { continuation.finish() }
    func wait() async throws {
        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() != nil else {
            throw PrecisionTransportWaitError.operationEndedBeforeEntry
        }
    }
}

private actor TestSuspensionGate {
    private var armed = false
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func arm() {
        precondition(continuation == nil)
        armed = true
    }

    func waitIfArmed() async {
        guard armed else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        armed = false
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private final class CallbackEmittingPrecisionWriter:
    PrecisionTransportReportWriter,
    @unchecked Sendable {
    private let channel: PrecisionCallbackInputChannel
    private let lock = NSLock()
    private var batches: [[PrecisionTransportInputFrame]]
    private var recordedFrames: [PrecisionTransportOutputFrame] = []
    private var cancelled: [UUID: PrecisionTransportReportIOError] = [:]

    init(
        channel: PrecisionCallbackInputChannel,
        batches: [[PrecisionTransportInputFrame]]
    ) {
        self.channel = channel
        self.batches = batches
    }

    func write(_ frame: PrecisionTransportOutputFrame) async throws -> Int32 {
        let batch: [PrecisionTransportInputFrame] = try lock.withLock {
            if let reason = cancelled.removeValue(forKey: frame.requestID) {
                throw reason
            }
            recordedFrames.append(frame)
            guard !batches.isEmpty else {
                throw PrecisionTransportReportIOError.timeout
            }
            return batches.removeFirst()
        }
        for input in batch {
            let accepted = input.bytes.withUnsafeBytes { pointer in
                channel.receiveCallback(
                    reportType: input.reportType,
                    reportID: input.reportID,
                    bytes: pointer,
                    device: input.device,
                    connectionEpoch: input.connectionEpoch,
                    rootGeneration: input.rootGeneration
                )
            }
            guard accepted else {
                throw PrecisionCallbackChannelError.requestNotActive
            }
        }
        return 0
    }

    func cancelPendingWrite(
        requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        lock.withLock { cancelled[requestID] = reason }
    }

    func frames() -> [PrecisionTransportOutputFrame] {
        lock.withLock { recordedFrames }
    }
}

private final class GatedEntryPrecisionWriter:
    PrecisionTransportReportWriter,
    @unchecked Sendable {
    private let gate: TestSuspensionGate
    private let lock = NSLock()
    private var cancelled: [UUID: PrecisionTransportReportIOError] = [:]
    private var cancelledTokens: Set<UUID> = []
    private var cancelCountStorage = 0

    init(gate: TestSuspensionGate) {
        self.gate = gate
    }

    var cancelCount: Int { lock.withLock { cancelCountStorage } }

    func write(_ frame: PrecisionTransportOutputFrame) async throws -> Int32 {
        await gate.waitIfArmed()
        return try lock.withLock {
            if let reason = cancelled.removeValue(forKey: frame.requestID) {
                throw reason
            }
            return 0
        }
    }

    func cancelPendingWrite(
        requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        lock.withLock {
            if cancelledTokens.insert(requestID).inserted {
                cancelCountStorage += 1
            }
            cancelled[requestID] = reason
        }
    }
}

private final class GatedEntryPrecisionReader:
    PrecisionTransportReportReader,
    @unchecked Sendable {
    private let gate: TestSuspensionGate
    private let lock = NSLock()
    private var activeRequestID: UUID?
    private var closed: [UUID: PrecisionTransportReportIOError] = [:]
    private var cancelledTokens: Set<UUID> = []
    private var cancelCountStorage = 0

    init(gate: TestSuspensionGate) {
        self.gate = gate
    }

    var cancelCount: Int { lock.withLock { cancelCountStorage } }

    func beginRequest(_ frame: PrecisionTransportOutputFrame) throws {
        try lock.withLock {
            guard activeRequestID == nil else {
                throw PrecisionCallbackChannelError.requestAlreadyActive
            }
            activeRequestID = frame.requestID
        }
    }

    func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame {
        await gate.waitIfArmed()
        return try lock.withLock {
            if let reason = closed.removeValue(forKey: requestID) { throw reason }
            guard activeRequestID == requestID else {
                throw PrecisionCallbackChannelError.requestNotActive
            }
            throw PrecisionTransportReportIOError.timeout
        }
    }

    func endRequest(_ requestID: UUID) {
        lock.withLock {
            if activeRequestID == requestID { activeRequestID = nil }
        }
    }

    func cancelRequest(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        lock.withLock {
            if cancelledTokens.insert(requestID).inserted {
                cancelCountStorage += 1
            }
            closed[requestID] = reason
            if activeRequestID == requestID { activeRequestID = nil }
        }
    }

    func disconnected() {
        let requestID = lock.withLock { activeRequestID }
        if let requestID { cancelRequest(requestID, reason: .disconnected) }
    }
}

private final class ScriptedPrecisionWriter:
    PrecisionTransportReportWriter,
    @unchecked Sendable {
    enum Step: Sendable {
        case returnCode(Int32)
        case pause(entry: TestEntrySignal, gate: TestSuspensionGate)
        case failure(PrecisionTransportReportIOError)
    }

    private var steps: [Step]
    private var recordedFrames: [PrecisionTransportOutputFrame] = []
    private var cancelled: [UUID: PrecisionTransportReportIOError] = [:]
    private let lock = NSLock()

    init(steps: [Step]) {
        self.steps = steps
    }

    func write(_ frame: PrecisionTransportOutputFrame) async throws -> Int32 {
        let result: Result<Step, PrecisionTransportReportIOError> = lock.withLock {
            if let reason = cancelled.removeValue(forKey: frame.requestID) {
                return .failure(reason)
            }
            recordedFrames.append(frame)
            guard !steps.isEmpty else { return .success(.returnCode(-1)) }
            return .success(steps.removeFirst())
        }
        let step = try result.get()
        switch step {
        case let .returnCode(code):
            return code
        case let .pause(entry, gate):
            entry.signal()
            await gate.waitIfArmed()
            try Task.checkCancellation()
            return 0
        case let .failure(error):
            throw error
        }
    }

    func frames() -> [PrecisionTransportOutputFrame] {
        lock.withLock { recordedFrames }
    }

    func frameCount() -> Int { lock.withLock { recordedFrames.count } }

    func cancelPendingWrite(
        requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        lock.withLock { cancelled[requestID] = reason }
    }
}

private final class ScriptedPrecisionReader:
    PrecisionTransportReportReader,
    @unchecked Sendable {
    enum Step: Sendable {
        case frame(PrecisionTransportInputFrame)
        case failure(PrecisionTransportReportIOError)
    }

    private var steps: [Step]
    private var activeRequestID: UUID?
    private var closed: [UUID: PrecisionTransportReportIOError] = [:]
    private let lock = NSLock()

    init(steps: [Step]) {
        self.steps = steps
    }

    func beginRequest(_ frame: PrecisionTransportOutputFrame) throws {
        try lock.withLock {
            guard activeRequestID == nil else {
                throw PrecisionCallbackChannelError.requestAlreadyActive
            }
            activeRequestID = frame.requestID
        }
    }

    func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame {
        let step: Step = try lock.withLock {
            if let reason = closed.removeValue(forKey: requestID) { throw reason }
            guard activeRequestID == requestID else {
                throw PrecisionCallbackChannelError.requestNotActive
            }
            guard !steps.isEmpty else { throw PrecisionTransportReportIOError.timeout }
            return steps.removeFirst()
        }
        switch step {
        case let .frame(frame): return frame
        case let .failure(error): throw error
        }
    }

    func endRequest(_ requestID: UUID) {
        lock.withLock {
            if activeRequestID == requestID { activeRequestID = nil }
        }
    }

    func cancelRequest(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        lock.withLock {
            closed[requestID] = reason
            if activeRequestID == requestID { activeRequestID = nil }
        }
    }

    func disconnected() {
        lock.withLock {
            if let requestID = activeRequestID {
                closed[requestID] = .disconnected
                activeRequestID = nil
            }
        }
    }
}

private final class BlockingPrecisionReader:
    PrecisionTransportReportReader,
    @unchecked Sendable {
    private var initialFrames: [PrecisionTransportInputFrame]
    private var continuation:
        CheckedContinuation<PrecisionTransportInputFrame, any Error>?
    private var activeRequestID: UUID?
    private var closed: [UUID: PrecisionTransportReportIOError] = [:]
    private var cancelCountStorage = 0
    private let lock = NSLock()
    let pendingReadEntry = TestEntrySignal()

    init(initialFrames: [PrecisionTransportInputFrame]) {
        self.initialFrames = initialFrames
    }

    var hasPendingRead: Bool { lock.withLock { continuation != nil } }
    var cancelCount: Int { lock.withLock { cancelCountStorage } }

    func beginRequest(_ frame: PrecisionTransportOutputFrame) throws {
        try lock.withLock {
            guard activeRequestID == nil else {
                throw PrecisionCallbackChannelError.requestAlreadyActive
            }
            activeRequestID = frame.requestID
        }
    }

    func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame {
        try await withCheckedThrowingContinuation { continuation in
            var immediate: Result<PrecisionTransportInputFrame, any Error>?
            var entered = false
            lock.withLock {
                if let reason = closed.removeValue(forKey: requestID) {
                    immediate = .failure(reason)
                } else if activeRequestID != requestID {
                    immediate = .failure(PrecisionCallbackChannelError.requestNotActive)
                } else if !initialFrames.isEmpty {
                    immediate = .success(initialFrames.removeFirst())
                } else if self.continuation != nil {
                    immediate = .failure(PrecisionCallbackChannelError.concurrentRead)
                } else {
                    self.continuation = continuation
                    entered = true
                }
            }
            if entered { pendingReadEntry.signal() }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    func endRequest(_ requestID: UUID) {
        close(requestID, reason: nil)
    }

    func cancelRequest(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        close(requestID, reason: reason)
    }

    func disconnected() {
        let requestID = lock.withLock { activeRequestID }
        if let requestID { close(requestID, reason: .disconnected) }
    }

    private func close(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError?
    ) {
        var pending:
            CheckedContinuation<PrecisionTransportInputFrame, any Error>?
        lock.withLock {
            guard activeRequestID == requestID else {
                if let reason { closed[requestID] = reason }
                return
            }
            pending = continuation
            continuation = nil
            activeRequestID = nil
            if let reason {
                closed[requestID] = reason
                cancelCountStorage += 1
            }
        }
        if let pending {
            pending.resume(throwing: reason ?? PrecisionTransportReportIOError.cancelled)
        }
    }
}

private final class NonCooperativePrecisionReader:
    PrecisionTransportReportReader,
    @unchecked Sendable {
    private var continuation:
        CheckedContinuation<PrecisionTransportInputFrame, any Error>?
    private var activeRequestID: UUID?
    private var closed: [UUID: PrecisionTransportReportIOError] = [:]
    private var cancelCountStorage = 0
    private let lock = NSLock()

    var hasPendingRead: Bool { lock.withLock { continuation != nil } }
    var cancelCount: Int { lock.withLock { cancelCountStorage } }

    func beginRequest(_ frame: PrecisionTransportOutputFrame) throws {
        try lock.withLock {
            guard activeRequestID == nil else {
                throw PrecisionCallbackChannelError.requestAlreadyActive
            }
            activeRequestID = frame.requestID
        }
    }

    func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame {
        try await withCheckedThrowingContinuation { continuation in
            var immediate: (any Error)?
            lock.withLock {
                if let reason = closed.removeValue(forKey: requestID) {
                    immediate = reason
                } else if activeRequestID != requestID {
                    immediate = PrecisionCallbackChannelError.requestNotActive
                } else {
                    self.continuation = continuation
                }
            }
            if let immediate { continuation.resume(throwing: immediate) }
        }
    }

    func endRequest(_ requestID: UUID) {
        close(requestID, reason: nil)
    }

    func cancelRequest(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        close(requestID, reason: reason)
    }

    func disconnected() {
        let requestID = lock.withLock { activeRequestID }
        if let requestID { close(requestID, reason: .disconnected) }
    }

    private func close(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError?
    ) {
        var pending:
            CheckedContinuation<PrecisionTransportInputFrame, any Error>?
        lock.withLock {
            guard activeRequestID == requestID else {
                if let reason { closed[requestID] = reason }
                return
            }
            pending = continuation
            continuation = nil
            activeRequestID = nil
            if let reason {
                closed[requestID] = reason
                cancelCountStorage += 1
            }
        }
        if let pending {
            pending.resume(throwing: reason ?? PrecisionTransportReportIOError.cancelled)
        }
    }
}

private final class NonCooperativePrecisionWriter:
    PrecisionTransportReportWriter,
    @unchecked Sendable {
    private var continuation: CheckedContinuation<Int32, any Error>?
    private var pendingRequestID: UUID?
    private var cancelled: [UUID: PrecisionTransportReportIOError] = [:]
    private var cancelCountStorage = 0
    private var frameCountStorage = 0
    private let lock = NSLock()

    var hasPendingWrite: Bool { lock.withLock { continuation != nil } }
    var cancelCount: Int { lock.withLock { cancelCountStorage } }
    var frameCount: Int { lock.withLock { frameCountStorage } }

    func write(_ frame: PrecisionTransportOutputFrame) async throws -> Int32 {
        return try await withCheckedThrowingContinuation { continuation in
            var immediate: PrecisionTransportReportIOError?
            lock.withLock {
                frameCountStorage += 1
                if let reason = cancelled.removeValue(forKey: frame.requestID) {
                    immediate = reason
                } else {
                    pendingRequestID = frame.requestID
                    self.continuation = continuation
                }
            }
            if let immediate { continuation.resume(throwing: immediate) }
        }
    }

    func cancelPendingWrite(
        requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        var pending: CheckedContinuation<Int32, any Error>?
        lock.withLock {
            cancelled[requestID] = reason
            guard pendingRequestID == requestID else { return }
            pending = continuation
            continuation = nil
            pendingRequestID = nil
            cancelCountStorage += 1
        }
        pending?.resume(throwing: reason)
    }
}

private actor ScriptedCompetitorProbe {
    private var snapshots: [[String]]

    init(_ snapshots: [[String]]) {
        self.snapshots = snapshots
    }

    func scan() -> [String] {
        guard snapshots.count > 1 else { return snapshots.first ?? [] }
        return snapshots.removeFirst()
    }
}

private struct AlwaysAllowingTestSafetyGate:
    PrecisionTemporaryDiversionSafetyGate {
    func acquire(
        for operation: PrecisionTemporaryDiversionOperation
    ) async throws -> any PrecisionTemporaryDiversionSafetyLease {
        _ = operation
        return AlwaysAllowingTestSafetyLease()
    }
}

private final class AlwaysAllowingTestSafetyLease:
    PrecisionTemporaryDiversionSafetyLease, @unchecked Sendable {
    func validate() throws {}
}

private func precisionFixture() throws -> PrecisionFixture {
    let device = JournalDeviceIdentity(
        deviceID: "046D-B01D-PRECISION-TRANSPORT-TEST",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "PRECISION-TRANSPORT-TEST",
        locationID: 9,
        firmwareIdentity: "precision-transport-firmware"
    )
    let raw = padded([0x00, 0xED, 0x00, 0x00, 0x00])
    let entry = try DeviceControlJournalEntry(
        controlInfo: ReprogControlInfo(
            index: 5,
            controlID: 0x00ED,
            taskID: 0x00C4,
            capabilityFlags: 0x71,
            position: 0,
            group: 1,
            groupMask: 1,
            rawXYCapability: false,
            rawParameters: padded([0x00, 0xED])
        ),
        baselineReporting: ReprogControlReportingState(
            controlID: 0x00ED,
            rawFlags: 0,
            rawMappedControlID: 0,
            rawParameters: raw
        )
    )
    let journal = try DeviceStateJournal(
        transactionID: UUID(),
        appBuild: "precision-test-transport",
        device: device,
        feature: HIDPP20FeatureDescriptor(
            index: 0x0A,
            type: 0,
            version: 3,
            rawParameters: padded([0x0A, 0x00, 0x03])
        ),
        expectedControlCount: 1,
        controls: [entry]
    )
    let plan = try PrecisionTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: journal.feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let session = DeviceTransactionSession(
        device: device,
        featureID: ReprogControlsV4.featureID,
        featureVersion: 3,
        featureIndex: 0x0A,
        connectionEpoch: 42
    )
    return PrecisionFixture(
        journal: journal,
        plan: plan,
        session: session,
        rootGeneration: 700
    )
}

private func reportingFrame(
    _ state: DeviceTransactionWireState,
    fixture: PrecisionFixture
) throws -> PrecisionTransportInputFrame {
    let response = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: fixture.session.featureIndex,
        functionID: 2,
        softwareID: 0x0E,
        parameters: state.rawParameters
    )
    return inputFrame(response.bytes, fixture: fixture)
}

private func inputFrame(
    _ bytes: [UInt8],
    fixture: PrecisionFixture
) -> PrecisionTransportInputFrame {
    PrecisionTransportInputFrame(
        reportType: .input,
        reportID: HIDPP20LongMessage.reportID,
        bytes: bytes,
        device: fixture.session.device,
        connectionEpoch: fixture.session.connectionEpoch,
        rootGeneration: fixture.rootGeneration
    )
}

private func protocolErrorFrame(
    for request: HIDPP20LongMessage,
    fixture: PrecisionFixture,
    code: HIDPP20ProtocolErrorCode
) throws -> PrecisionTransportInputFrame {
    let error = try HIDPP20LongMessage(
        deviceIndex: request.deviceIndex,
        featureIndex: 0xFF,
        functionID: 0,
        softwareID: request.featureIndex,
        parameters: [request.address, code.rawValue],
        requireRequestSoftwareID: false
    )
    return inputFrame(error.bytes, fixture: fixture)
}

private func padded(_ prefix: [UInt8]) -> [UInt8] {
    prefix + Array(
        repeating: 0,
        count: HIDPP20LongMessage.parameterCount - prefix.count
    )
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private enum PrecisionTransportWaitError: Error {
    case timedOut
    case operationEndedBeforeEntry
}

private func waitUntil(
    nanoseconds: UInt64,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let started = DispatchTime.now().uptimeNanoseconds
    while !(await condition()) {
        guard DispatchTime.now().uptimeNanoseconds &- started < nanoseconds else {
            throw PrecisionTransportWaitError.timedOut
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

@Test func transportTargetHasNoProductAndIsNamedByNoRunnableTarget() throws {
    // Added 2026-09-05. This was the one productless target with no
    // build-graph isolation test at all, which went unnoticed because the
    // shared products-section check was truncating to two lines of manifest.
    //
    // Like the Precision runtime's other layers, it is productless but
    // reachable through the MXErgoPrecisionRuntimeOwner product. What must
    // stay true is that nothing links against it directly.
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectRoot = packageRoot
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let manifest = try String(
        contentsOf: packageRoot.appendingPathComponent("Package.swift"),
        encoding: .utf8
    )
    // The boundary is line-anchored. Splitting on a bare "targets: ["
    // truncates at the first *product's* targets list, which left this
    // check scanning two lines of the manifest.
    let products = try #require(
        manifest.split(separator: "\n    targets: [", maxSplits: 1).first
    )
    #expect(!products.contains("MXErgoPrecisionTransport"))
    // Its own declaration, ten dependency edges from source targets, and
    // eight from test targets. A pinned integer so a new edge has to be
    // noticed by a person rather than absorbed silently.
    #expect(manifest.components(
        separatedBy: "\"MXErgoPrecisionTransport\""
    ).count - 1 == 19)

    let projectYAML = try String(
        contentsOf: projectRoot.appendingPathComponent("project.yml"),
        encoding: .utf8
    )
    let projectFile = try String(
        contentsOf: projectRoot
            .appendingPathComponent("MXErgoController.xcodeproj")
            .appendingPathComponent("project.pbxproj"),
        encoding: .utf8
    )
    #expect(!projectYAML.contains("MXErgoPrecisionTransport"))
    #expect(!projectFile.contains("MXErgoPrecisionTransport"))

    let appRoot = projectRoot.appendingPathComponent("App")
    let appText = try FileManager.default.contentsOfDirectory(
        at: appRoot,
        includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "swift" }
    .map { try String(contentsOf: $0, encoding: .utf8) }
    .joined(separator: "\n")
    #expect(!appText.contains("MXErgoPrecisionTransport"))
}


private final class TestConnectionValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func disconnect() { lock.withLock { active = false } }
    func validate() throws {
        try lock.withLock {
            guard active else { throw PrecisionTransportReportIOError.disconnected }
        }
    }
}

@Test func connectionRemovalDuringCompetitorProbeCannotReturnACurrentSession() async throws {
    let fixture = try precisionFixture()
    let gate = TestSuspensionGate()
    await gate.arm()
    let connection = TestConnectionValidity()
    let adapter = try makeAdapter(
        fixture: fixture,
        journalURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
        writer: ScriptedPrecisionWriter(steps: []),
        reader: BlockingPrecisionReader(initialFrames: []),
        competitorProbe: { await gate.waitIfArmed(); return [] },
        connectionValidator: { try connection.validate() }
    )
    let read = Task { try await adapter.currentSession() }
    try await waitUntil(nanoseconds: 5_000_000_000) { await gate.isWaiting }
    connection.disconnect()
    await gate.release()
    await #expect(throws: PrecisionTransportReportIOError.disconnected) {
        try await read.value
    }
}
