import Foundation
import Testing
@testable import MXErgoHIDPP

@Test func precisionDiversionPlanBuildsOnlyApplyRestoreAndIndependentGetPackets() throws {
    let journal = try precisionJournal()
    let plan = try PrecisionTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: journal.feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )

    #expect(plan.baseline.rawFlags(featureVersion: 3) == 0)
    #expect(plan.activeState.rawFlags(featureVersion: 3) == 1)
    #expect(plan.applySetRequest.bytes == precisionPacket(
        header: [0x11, 0x00, 0x0A, 0x3E],
        parameters: [0x00, 0xED, 0x03, 0x00, 0x00]
    ))
    #expect(plan.restoreSetRequest.bytes == precisionPacket(
        header: [0x11, 0x00, 0x0A, 0x3E],
        parameters: [0x00, 0xED, 0x02, 0x00, 0x00]
    ))
    #expect(plan.verificationRequest.bytes == precisionPacket(
        header: [0x11, 0x00, 0x0A, 0x2E],
        parameters: [0x00, 0xED]
    ))
}

@Test func precisionLifecycleRetainsNonEchoEvidenceButUsesOnlyGetForState() async throws {
    let journal = try precisionJournal()
    let plan = try PrecisionTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: journal.feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repository = DurableDeviceTransactionFileRepository(
        fileURL: directory.appendingPathComponent("precision-transaction-v3.json")
    )
    let transport = PrecisionLifecycleTransport(
        repository: repository,
        plan: plan,
        session: precisionSession(),
        initialState: plan.baseline
    )
    let coordinator = DeviceTransactionCoordinator(
        repository: repository,
        transport: transport
    )
    let envelope = try DeviceTransactionEnvelope(
        transactionID: UUID(),
        baselineJournal: journal
    )
    _ = try await coordinator.installPreparedEnvelope(envelope)
    let lifecycle = PrecisionTemporaryDiversionLifecycle(
        coordinator: coordinator,
        plan: plan,
        safetyGate: AlwaysAllowingPrecisionSafetyGate()
    )

    #expect(try await lifecycle.state() == .inactive)
    let active = try await lifecycle.activate()
    #expect(try active.control(0x00ED).phase == .appliedVerified)
    #expect(try active.control(0x00ED).attempts.last?.invocationEvidence?.responseKind
        == .correlatedNonEcho)
    let firstResponse = await transport.responses().first
    #expect(try active.control(0x00ED).attempts.last?.invocationEvidence?.responseBytes
        == firstResponse)
    #expect(try await lifecycle.state() == .active)

    let restored = try await lifecycle.deactivate()
    let control = try restored.control(0x00ED)
    #expect(control.phase == .restoredVerified)
    #expect(control.attempts.count == 2)
    #expect(control.attempts.allSatisfy { $0.outcome == .verified })
    #expect(control.attempts.allSatisfy {
        $0.invocationEvidence?.responseKind == .correlatedNonEcho
    })
    #expect(try await lifecycle.state() == .restored)
    #expect(await transport.invocationCount() == 2)
    #expect(await transport.readCount() == 4)
}

@Test func precisionApplyPreflightPersistsDriftWithoutInvokingTransport() async throws {
    let journal = try precisionJournal()
    let plan = try PrecisionTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: journal.feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repository = DurableDeviceTransactionFileRepository(
        fileURL: directory.appendingPathComponent("precision-drift-v3.json")
    )
    var driftBytes = plan.baseline.rawParameters
    driftBytes[15] = 0x80
    let drift = try DeviceTransactionWireState(rawParameters: driftBytes)
    let transport = PrecisionLifecycleTransport(
        repository: repository,
        plan: plan,
        session: precisionSession(),
        initialState: drift
    )
    let coordinator = DeviceTransactionCoordinator(repository: repository, transport: transport)
    _ = try await coordinator.installPreparedEnvelope(
        DeviceTransactionEnvelope(baselineJournal: journal)
    )
    let lifecycle = PrecisionTemporaryDiversionLifecycle(
        coordinator: coordinator,
        plan: plan,
        safetyGate: AlwaysAllowingPrecisionSafetyGate()
    )

    await #expect(throws: DeviceTransactionCoordinatorError.conflicted(0x00ED)) {
        try await lifecycle.activate()
    }
    #expect(await transport.invocationCount() == 0)
    #expect(try await lifecycle.state() == .conflicted)
}

@Test func oldUnboundSchemaThreeEnvelopeDecodesButCannotAuthorizeASession() throws {
    let envelope = try DeviceTransactionEnvelope(baselineJournal: precisionJournal())
    let encoded = try JSONEncoder().encode(envelope)
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "featureIndex")
    let legacyBytes = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(DeviceTransactionEnvelope.self, from: legacyBytes)

    try decoded.validate()
    #expect(decoded.featureIndex == nil)
    #expect(!decoded.isSafeSessionMatch(precisionSession()))
}

@Test func runtimeFeatureIndexChangeFailsTheTransactionSessionBinding() throws {
    let envelope = try DeviceTransactionEnvelope(baselineJournal: precisionJournal())
    let current = precisionSession()
    let changed = DeviceTransactionSession(
        device: current.device,
        featureID: current.featureID,
        featureVersion: current.featureVersion,
        featureIndex: current.featureIndex + 1,
        connectionEpoch: current.connectionEpoch
    )

    #expect(envelope.isSafeSessionMatch(current))
    #expect(!envelope.isSafeSessionMatch(changed))
}

@Test func precisionSafetyGateRejectsCompetitorsBeforeTakingTheDeviceLease() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let journalURL = directory.appendingPathComponent("baseline-v2.json")
    try Data("baseline".utf8).write(to: journalURL)
    let gate = PrecisionTemporaryDiversionDeviceSafetyGate(
        journalURL: journalURL,
        competitorProbe: { ["BetterTouchTool", "Logi Options+"] }
    )

    await #expect(throws: PrecisionTemporaryDiversionSafetyGateError
        .competingProcesses(["BetterTouchTool", "Logi Options+"])) {
        try await gate.acquire(for: .activate)
    }

    // Because the competitor check happened first, a clean caller can still
    // take the canonical lease immediately.
    let clean = PrecisionTemporaryDiversionDeviceSafetyGate(
        journalURL: journalURL,
        competitorProbe: { [] }
    )
    _ = try await clean.acquire(for: .activate)
}

@Test func precisionSafetyGateHoldsCanonicalLeaseAndNeverAutoRestoresOnLateCompetitor() async throws {
    let journal = try precisionJournal()
    let plan = try PrecisionTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: journal.feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let transactionURL = directory.appendingPathComponent("precision-guarded-v3.json")
    let repository = DurableDeviceTransactionFileRepository(fileURL: transactionURL)
    let probe = CompetitorProbeSequence([
        [], // before acquiring the canonical lease
        [], // immediately after acquiring it
        [], // lifecycle validation immediately before the operation
        ["BetterTouchTool"], // post-dispatch validation
    ])
    let safetyGate = PrecisionTemporaryDiversionDeviceSafetyGate(
        journalURL: transactionURL,
        competitorProbe: probe.read
    )
    let transport = PrecisionLifecycleTransport(
        repository: repository,
        plan: plan,
        session: precisionSession(),
        initialState: plan.baseline,
        leaseProbeURL: transactionURL
    )
    let coordinator = DeviceTransactionCoordinator(repository: repository, transport: transport)
    _ = try await coordinator.installPreparedEnvelope(
        DeviceTransactionEnvelope(baselineJournal: journal)
    )
    let lifecycle = PrecisionTemporaryDiversionLifecycle(
        coordinator: coordinator,
        plan: plan,
        safetyGate: safetyGate
    )

    await #expect(throws: PrecisionTemporaryDiversionSafetyGateError
        .competingProcesses(["BetterTouchTool"])) {
        try await lifecycle.activate()
    }

    let durable = try #require(try await repository.loadValidated())
    let control = try durable.control(0x00ED)
    #expect(control.phase == .appliedVerified)
    #expect(control.attempts.count == 1)
    #expect(await transport.invocationCount() == 1)
    #expect(await transport.canonicalLeaseWasHeldDuringInvocation())
    // A late competitor is never answered with an automatic inverse SET.
    #expect(control.restoredObservation == nil)
}

@Test func precisionExplicitRecoveryRunsUnderTheSameGuardAndRestoresOnlyPrecision() async throws {
    let journal = try precisionJournal()
    let plan = try PrecisionTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: journal.feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let transactionURL = directory.appendingPathComponent("precision-recovery-v3.json")
    let repository = DurableDeviceTransactionFileRepository(fileURL: transactionURL)
    let baselineEnvelope = try DeviceTransactionEnvelope(baselineJournal: journal)
    let interrupted = try DeviceTransactionReducer.reduce(
        baselineEnvelope,
        event: .armApply(
            controlID: 0x00ED,
            intended: plan.activeState,
            attemptID: UUID(),
            now: Date()
        )
    ).envelope
    _ = try await repository.commit(baselineEnvelope, expectedRevision: nil)
    _ = try await repository.commit(interrupted, expectedRevision: baselineEnvelope.revision)

    let transport = PrecisionLifecycleTransport(
        repository: repository,
        plan: plan,
        session: precisionSession(),
        initialState: plan.activeState,
        leaseProbeURL: transactionURL
    )
    let coordinator = DeviceTransactionCoordinator(repository: repository, transport: transport)
    let gate = PrecisionTemporaryDiversionDeviceSafetyGate(
        journalURL: transactionURL,
        competitorProbe: { [] }
    )
    let lifecycle = PrecisionTemporaryDiversionLifecycle(
        coordinator: coordinator,
        plan: plan,
        safetyGate: gate
    )

    #expect(try await lifecycle.state() == .recoveryRequired)
    let report = try await lifecycle.recoverExplicitly()
    #expect(report.inspectedControlIDs == [0x00ED])
    #expect(report.restoredControlIDs == [0x00ED])
    #expect(report.finalStatus == .completed)
    #expect(try await lifecycle.state() == .restored)
    #expect(await transport.invocationCount() == 1)
    #expect(await transport.canonicalLeaseWasHeldDuringInvocation())
    let final = try #require(try await repository.loadValidated())
    #expect(try final.control(0x00ED).phase == .restoredVerified)
}

private struct AlwaysAllowingPrecisionSafetyGate:
    PrecisionTemporaryDiversionSafetyGate {
    func acquire(
        for operation: PrecisionTemporaryDiversionOperation
    ) async throws -> any PrecisionTemporaryDiversionSafetyLease {
        _ = operation
        return AlwaysAllowingPrecisionSafetyLease()
    }
}

private final class AlwaysAllowingPrecisionSafetyLease:
    PrecisionTemporaryDiversionSafetyLease, @unchecked Sendable {
    func validate() throws {}
}

private final class CompetitorProbeSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String]]

    init(_ values: [[String]]) {
        self.values = values
    }

    func read() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return [] }
        return values.removeFirst()
    }
}

private actor PrecisionLifecycleTransport: DeviceTransactionEffectTransport {
    private let repository: any DeviceTransactionJournalRepository
    private let plan: PrecisionTemporaryDiversionPlan
    private let session: DeviceTransactionSession
    private var state: DeviceTransactionWireState
    private var invocations = 0
    private var reads = 0
    private var rawResponses: [[UInt8]] = []
    private let leaseProbeURL: URL?
    private var deviceLeaseWasHeld = false

    init(
        repository: any DeviceTransactionJournalRepository,
        plan: PrecisionTemporaryDiversionPlan,
        session: DeviceTransactionSession,
        initialState: DeviceTransactionWireState,
        leaseProbeURL: URL? = nil
    ) {
        self.repository = repository
        self.plan = plan
        self.session = session
        state = initialState
        self.leaseProbeURL = leaseProbeURL
    }

    func currentSession() -> DeviceTransactionSession { session }

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
              durable.transactionID == authorization.transactionID,
              durable.revision == authorization.revision else {
            throw DeviceTransactionTransportInvocationError.rejectedBeforeDispatch(
                "authorization mismatch"
            )
        }
        let request = try plan.request(for: mutation)
        if let leaseProbeURL {
            do {
                let unexpected = try MXErgoDeviceOperationLease.acquire(
                    beside: leaseProbeURL
                )
                withExtendedLifetime(unexpected) {}
                deviceLeaseWasHeld = false
            } catch MXErgoDeviceOperationLeaseError.unavailable {
                deviceLeaseWasHeld = true
            }
        }
        var response = request.bytes
        response[8] ^= UInt8(invocations + 1)
        state = mutation.state
        invocations += 1
        rawResponses.append(response)
        return try plan.invocationEvidence(
            for: mutation,
            responseBytes: response,
            ioReturn: 0,
            connectionEpoch: session.connectionEpoch
        )
    }

    func readReporting(
        controlID: UInt16,
        expectedSession: DeviceTransactionSession
    ) throws -> DeviceTransactionWireState {
        guard expectedSession == session, controlID == state.controlID else {
            throw DeviceTransactionTransportInvocationError.rejectedBeforeDispatch(
                "read mismatch"
            )
        }
        reads += 1
        return state
    }

    func invocationCount() -> Int { invocations }
    func readCount() -> Int { reads }
    func responses() -> [[UInt8]] { rawResponses }
    func canonicalLeaseWasHeldDuringInvocation() -> Bool { deviceLeaseWasHeld }
}

private func precisionJournal() throws -> DeviceStateJournal {
    let raw = precisionPadded([0x00, 0xED, 0x00, 0x00, 0x00])
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
            rawParameters: precisionPadded([0x00, 0xED])
        ),
        baselineReporting: ReprogControlReportingState(
            controlID: 0x00ED,
            rawFlags: 0,
            rawMappedControlID: 0,
            rawParameters: raw
        )
    )
    return try DeviceStateJournal(
        transactionID: UUID(),
        appBuild: "precision-lifecycle-test",
        device: precisionDevice(),
        feature: HIDPP20FeatureDescriptor(
            index: 0x0A,
            type: 0,
            version: 3,
            rawParameters: precisionPadded([0x0A, 0x00, 0x03])
        ),
        expectedControlCount: 1,
        controls: [entry]
    )
}

private func precisionSession() -> DeviceTransactionSession {
    DeviceTransactionSession(
        device: precisionDevice(),
        featureID: ReprogControlsV4.featureID,
        featureVersion: 3,
        featureIndex: 0x0A,
        connectionEpoch: 42
    )
}

private func precisionDevice() -> JournalDeviceIdentity {
    JournalDeviceIdentity(
        deviceID: "046D-B01D-PRECISION-TEST",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "PRECISION-TEST",
        locationID: 7,
        firmwareIdentity: "precision-firmware"
    )
}

private func precisionPadded(_ prefix: [UInt8]) -> [UInt8] {
    prefix + Array(repeating: 0, count: HIDPP20LongMessage.parameterCount - prefix.count)
}

private func precisionPacket(header: [UInt8], parameters: [UInt8]) -> [UInt8] {
    let prefix = header + parameters
    return prefix + Array(repeating: 0, count: HIDPP20LongMessage.byteCount - prefix.count)
}


@Test(arguments: [ResumeReadScenario.active, .baseline, .unexpected, .timeout, .cancelled, .disconnected])
func precisionResumeClassifiesOneFreshReadWithoutPreparingOrInvokingSET(
    scenario: ResumeReadScenario
) async throws {
    let fixture = try await precisionResumeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let before = try Data(contentsOf: fixture.url)
    let spy = ResumeReadOnlyTransport(plan: fixture.plan, scenario: scenario)
    let lifecycle = PrecisionTemporaryDiversionLifecycle(
        coordinator: DeviceTransactionCoordinator(repository: fixture.repository, transport: spy),
        plan: fixture.plan, safetyGate: AlwaysAllowingPrecisionSafetyGate()
    )
    do {
        let result = try await lifecycle.resumeVerified()
        #expect(scenario == .active || scenario == .baseline)
        #expect(try result.control(0x00ED).phase == (scenario == .active ? .appliedVerified : .restoredVerified))
        #expect(try result.control(0x00ED).attempts == fixture.applied.control(0x00ED).attempts)
        #expect(result.status == (scenario == .active ? .running : .completed))
    } catch {
        #expect(scenario != .active && scenario != .baseline)
        if scenario == .unexpected {
            #expect(error as? DeviceTransactionCoordinatorError == .conflicted(0x00ED))
            #expect(try await fixture.repository.loadValidated()?.status == .conflicted)
        }
    }
    #expect(await spy.readCount == 1)
    #expect(await spy.prepareCount == 0)
    #expect(await spy.invokeCount == 0)
    if scenario != .baseline && scenario != .unexpected {
        #expect(try Data(contentsOf: fixture.url) == before)
    }
}

@Test func precisionResumeRejectsEveryUnverifiedPhaseBeforeReading() async throws {
    let fixture = try await precisionResumeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let restoreArmed = try DeviceTransactionReducer.reduce(
        fixture.applied,
        event: .armRestore(controlID: 0x00ED, attemptID: UUID(), now: Date())
    ).envelope
    let restored = try DeviceTransactionReducer.reduce(
        restoreArmed,
        event: .observeRestore(controlID: 0x00ED, state: fixture.plan.baseline, now: Date())
    ).envelope
    for envelope in [fixture.prepared, fixture.applyArmed, restoreArmed, restored] {
        // Each input is a validated serialized restart fixture, never live data.
        try JSONEncoder().encode(envelope).write(to: fixture.url, options: .atomic)
        let before = try Data(contentsOf: fixture.url)
        let spy = ResumeReadOnlyTransport(plan: fixture.plan, scenario: .active)
        let coordinator = DeviceTransactionCoordinator(repository: fixture.repository, transport: spy)
        await #expect(throws: DeviceTransactionCoordinatorError.resumeNotPermitted(0x00ED)) {
            try await coordinator.resumeVerified(controlID: 0x00ED)
        }
        #expect(await spy.readCount == 0)
        #expect(await spy.prepareCount == 0)
        #expect(await spy.invokeCount == 0)
        #expect(try Data(contentsOf: fixture.url) == before)
    }
}

@Test func precisionResumeRejectsCompetingSoftwareBeforeReading() async throws {
    let fixture = try await precisionResumeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let spy = ResumeReadOnlyTransport(plan: fixture.plan, scenario: .active)
    let lifecycle = PrecisionTemporaryDiversionLifecycle(
        coordinator: DeviceTransactionCoordinator(repository: fixture.repository, transport: spy),
        plan: fixture.plan,
        safetyGate: PrecisionTemporaryDiversionDeviceSafetyGate(
            journalURL: fixture.url, competitorProbe: { ["Logi Options+"] }
        )
    )
    await #expect(throws: PrecisionTemporaryDiversionSafetyGateError.competingProcesses(["Logi Options+"])) {
        try await lifecycle.resumeVerified()
    }
    #expect(await spy.readCount == 0)
    #expect(await spy.prepareCount == 0)
    #expect(await spy.invokeCount == 0)
}

@Test func precisionResumeHoldsCanonicalLeaseAndRejectsLateCompetitor() async throws {
    let fixture = try await precisionResumeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let competitor = ResumeCompetitorState()
    let spy = ResumeReadOnlyTransport(
        plan: fixture.plan, scenario: .active, duringRead: {
            #expect(throws: MXErgoDeviceOperationLeaseError.unavailable) {
                _ = try MXErgoDeviceOperationLease.acquire(beside: fixture.url)
            }
            competitor.setPresent()
        }
    )
    let lifecycle = PrecisionTemporaryDiversionLifecycle(
        coordinator: DeviceTransactionCoordinator(repository: fixture.repository, transport: spy),
        plan: fixture.plan,
        safetyGate: PrecisionTemporaryDiversionDeviceSafetyGate(
            journalURL: fixture.url, competitorProbe: { competitor.names }
        )
    )
    await #expect(throws: PrecisionTemporaryDiversionSafetyGateError.competingProcesses(["Logi Options+"])) {
        try await lifecycle.resumeVerified()
    }
    #expect(await spy.readCount == 1)
    #expect(await spy.prepareCount == 0)
    #expect(await spy.invokeCount == 0)
    let released = try MXErgoDeviceOperationLease.acquire(beside: fixture.url)
    withExtendedLifetime(released) {}
}

@Test func precisionResumeDurableCommitFailureNeverSendsACommand() async throws {
    for boundary in DeviceTransactionCommitBoundary.allCases {
        let fixture = try await precisionResumeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = DurableDeviceTransactionFileRepository(fileURL: fixture.url) { reached in
            if boundary == reached { throw ResumeTestError.commit }
        }
        let spy = ResumeReadOnlyTransport(plan: fixture.plan, scenario: .baseline)
        let coordinator = DeviceTransactionCoordinator(repository: repository, transport: spy)
        await #expect(throws: ResumeTestError.commit) {
            try await coordinator.resumeVerified(controlID: 0x00ED)
        }
        let durable = try #require(try await fixture.repository.loadValidated())
        #expect(durable.status == .running || durable.status == .completed)
        #expect(try durable.control(0x00ED).attempts == fixture.applied.control(0x00ED).attempts)
        #expect(await spy.prepareCount == 0)
        #expect(await spy.invokeCount == 0)
    }
}

enum ResumeReadScenario: Sendable { case active, baseline, unexpected, timeout, cancelled, disconnected }
private enum ResumeTestError: Error { case timeout, unexpectedMutation, commit }
private actor ResumeReadOnlyTransport: DeviceTransactionEffectTransport {
    let plan: PrecisionTemporaryDiversionPlan
    let scenario: ResumeReadScenario
    let duringRead: @Sendable () -> Void
    var readCount = 0
    var prepareCount = 0
    var invokeCount = 0
    init(plan: PrecisionTemporaryDiversionPlan, scenario: ResumeReadScenario,
         duringRead: @escaping @Sendable () -> Void = {}) {
        self.plan = plan
        self.scenario = scenario
        self.duringRead = duringRead
    }
    func currentSession() -> DeviceTransactionSession {
        let original = precisionSession()
        return DeviceTransactionSession(
            device: original.device, featureID: original.featureID,
            featureVersion: original.featureVersion, featureIndex: original.featureIndex,
            connectionEpoch: scenario == .disconnected && readCount > 0 ? 100 : 99
        )
    }
    func prepare(_ proposed: DeviceTransactionMutation, expectedSession: DeviceTransactionSession,
                 expectedCommittedRevision: UInt64) throws -> DeviceTransactionPreparedInvocation {
        prepareCount += 1
        throw ResumeTestError.unexpectedMutation
    }
    func invoke(_ prepared: DeviceTransactionPreparedInvocation,
                authorization: DeviceTransactionDurableCommitReceipt) throws -> DeviceTransactionInvocationEvidence? {
        invokeCount += 1
        throw ResumeTestError.unexpectedMutation
    }
    func abandon(_ prepared: DeviceTransactionPreparedInvocation,
                 disposition: DeviceTransactionPreparationDisposition) {}
    func readReporting(controlID: UInt16, expectedSession: DeviceTransactionSession) throws -> DeviceTransactionWireState {
        readCount += 1
        duringRead()
        switch scenario {
        case .active, .disconnected: return plan.activeState
        case .baseline: return plan.baseline
        case .unexpected:
            var raw = plan.baseline.rawParameters
            raw[15] = 0x80
            return try DeviceTransactionWireState(rawParameters: raw)
        case .timeout: throw ResumeTestError.timeout
        case .cancelled: throw CancellationError()
        }
    }
}

private final class ResumeCompetitorState: @unchecked Sendable {
    private let lock = NSLock()
    private var present = false
    func setPresent() { lock.withLock { present = true } }
    var names: [String] { lock.withLock { present ? ["Logi Options+"] : [] } }
}

private struct PrecisionResumeFixture: Sendable {
    let directory: URL
    let url: URL
    let repository: DurableDeviceTransactionFileRepository
    let plan: PrecisionTemporaryDiversionPlan
    let prepared: DeviceTransactionEnvelope
    let applyArmed: DeviceTransactionEnvelope
    let applied: DeviceTransactionEnvelope
}

private func precisionResumeFixture() async throws -> PrecisionResumeFixture {
    let journal = try precisionJournal()
    let plan = try PrecisionTemporaryDiversionPlan.make(
        journal: journal, currentFeature: journal.feature, deviceIndex: 0, softwareID: 0x0E
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent("precision-runtime-v3.json")
    let repository = DurableDeviceTransactionFileRepository(fileURL: url)
    let prepared = try DeviceTransactionEnvelope(baselineJournal: journal)
    let applyArmed = try DeviceTransactionReducer.reduce(prepared, event: .armApply(
        controlID: 0x00ED, intended: plan.activeState, attemptID: UUID(), now: Date()
    )).envelope
    let applied = try DeviceTransactionReducer.reduce(applyArmed, event: .observeApply(
        controlID: 0x00ED, state: plan.activeState, now: Date()
    )).envelope
    _ = try await repository.commit(prepared, expectedRevision: nil)
    _ = try await repository.commit(applyArmed, expectedRevision: prepared.revision)
    _ = try await repository.commit(applied, expectedRevision: applyArmed.revision)
    return PrecisionResumeFixture(directory: directory, url: url, repository: repository,
                                  plan: plan, prepared: prepared, applyArmed: applyArmed, applied: applied)
}
