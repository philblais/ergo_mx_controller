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
