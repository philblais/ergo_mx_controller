import Foundation
import MXErgoHIDPP
import Testing
@testable import MXErgoPrecisionIOHIDAcquisition
@testable import MXErgoPrecisionRuntimeComposition
@testable import MXErgoPrecisionRuntimeJournal
@testable import MXErgoPrecisionTransport
@testable import MXErgoPrecisionWriteLifecycle

@Test func compositionStartsBeforePublishingAndShutsDownExactlyOnce() async throws {
    let snapshotReads = RuntimeCounter()
    let fixture = try runtimeFixture(snapshotReadCounter: snapshotReads)
    let events = RuntimeEventRecorder()
    let endpoint = FakeRuntimeEndpoint(events: events, closeReturn: 0)
    let transport = FakeRuntimeTransport(
        session: fixture.binding.session,
        events: events
    )

    let runtime = try await PrecisionRuntimeCompositionFactory.make(
        configuration: fixture.configuration,
        acquire: { plan, binding, operationLease in
            #expect(plan == fixture.plan)
            #expect(binding == fixture.binding)
            #expect(operationLease.protects(
                journalURL: fixture.configuration.journalContext.source.journalURL
            ))
            events.record("acquire")
            return endpoint
        },
        makeTransport: { configuration, acquired in
            #expect(configuration.binding == fixture.binding)
            #expect(acquired === endpoint)
            events.record("transport-make")
            return transport
        }
    )

    #expect(events.values == ["acquire", "transport-make", "endpoint-start"])
    #expect(snapshotReads.value == 1)
    #expect(try await runtime.lifecycleState() == .inactive)

    async let first = runtime.shutdown()
    async let second = runtime.shutdown()
    let reports = await [first, second]

    #expect(reports[0] == reports[1])
    #expect(reports[0] == PrecisionRuntimeShutdownReport(
        disposition: .clean(.inactive),
        deviceCloseReturn: 0
    ))
    #expect(events.count("transport-disconnect") == 1)
    #expect(events.count("endpoint-shutdown") == 1)
    #expect(events.index(of: "transport-disconnect")! <
        events.index(of: "endpoint-shutdown")!)
    await #expect(throws: PrecisionRuntimeOperationError.permanentlyStopped) {
        try await runtime.lifecycleState()
    }
}

@Test func disconnectFailsClosedWithoutSETAndClassifiesRecoveryOnShutdown()
    async throws
{
    let fixture = try runtimeFixture(active: true)
    let events = RuntimeEventRecorder()
    let endpoint = FakeRuntimeEndpoint(events: events, closeReturn: 0)
    let transport = FakeRuntimeTransport(
        session: fixture.binding.session,
        events: events
    )
    let notifications = RuntimeCounter()
    let configuration = PrecisionRuntimeCompositionConfiguration(
        journalContext: fixture.configuration.journalContext,
        operationLease: fixture.configuration.operationLease,
        sessionProvider: fixture.configuration.sessionProvider,
        rootGenerationProvider: fixture.configuration.rootGenerationProvider,
        competitorProbe: fixture.configuration.competitorProbe,
        deviceDisconnectHandler: { notifications.increment() }
    )

    let runtime = try await PrecisionRuntimeCompositionFactory.make(
        configuration: configuration,
        acquire: { _, _, _ in
            events.record("acquire")
            return endpoint
        },
        makeTransport: { _, _ in
            events.record("transport-make")
            return transport
        }
    )

    endpoint.fireDisconnect()
    await waitUntil { notifications.value == 1 }
    await waitUntil {
        do {
            _ = try await runtime.lifecycleState()
            return false
        } catch PrecisionRuntimeOperationError.deviceDisconnected {
            return true
        } catch {
            return false
        }
    }
    await #expect(throws: PrecisionRuntimeOperationError.deviceDisconnected) {
        _ = try await runtime.activate()
    }
    await #expect(throws: PrecisionRuntimeOperationError.deviceDisconnected) {
        _ = try await runtime.deactivate()
    }
    let report = await runtime.shutdown()
    #expect(report.disposition == .recoveryRequired(.active))
    #expect(!events.values.contains("activate"))
    #expect(!events.values.contains("deactivate"))
    #expect(events.count("transport-disconnect") >= 1)
}

@Test func invalidSnapshotFailsBeforeAcquisition() async throws {
    let fixture = try runtimeFixture()
    let events = RuntimeEventRecorder()
    let currentContext = fixture.configuration.journalContext
    let invalidSnapshot = PrecisionRuntimeJournalSnapshot(
        data: currentContext.snapshot.data,
        envelope: currentContext.snapshot.envelope,
        sha256: "not-a-sha256"
    )
    let invalidContext = PrecisionRuntimeJournalContext(
        plan: currentContext.plan,
        session: currentContext.session,
        rootGeneration: currentContext.rootGeneration,
        sourceBaselineSHA256: currentContext.sourceBaselineSHA256,
        sourceBaselineTransactionID: currentContext.sourceBaselineTransactionID,
        source: currentContext.source,
        snapshot: invalidSnapshot,
        disposition: currentContext.disposition
    )
    let invalidConfiguration = PrecisionRuntimeCompositionConfiguration(
        journalContext: invalidContext,
        operationLease: fixture.configuration.operationLease,
        sessionProvider: fixture.configuration.sessionProvider,
        rootGenerationProvider:
            fixture.configuration.rootGenerationProvider,
        competitorProbe: fixture.configuration.competitorProbe
    )

    do {
        _ = try await PrecisionRuntimeCompositionFactory.make(
            configuration: invalidConfiguration,
            acquire: { _, _, _ in
                events.record("acquire")
                throw RuntimeTestError.unused
            },
            makeTransport: { _, _ in
                events.record("transport-make")
                throw RuntimeTestError.unused
            }
        )
        Issue.record("Expected configuration validation failure")
    } catch let failure as PrecisionRuntimeCompositionFailure {
        #expect(failure.phase == .configurationValidation)
        #expect(failure.underlying as? PrecisionRuntimeConfigurationError ==
            .invalidDurableSnapshot)
        #expect(failure.deviceCloseReturn == nil)
    }
    #expect(events.values.isEmpty)
}

@Test func operationLeaseMustProtectTheCanonicalRuntimeJournalBeforeAcquisition()
    async throws {
    let fixture = try runtimeFixture()
    let events = RuntimeEventRecorder()
    let wrongURL = URL(
        fileURLWithPath: "/private/tmp/wrong-runtime-lease-\(UUID().uuidString)",
        isDirectory: true
    ).appendingPathComponent("runtime.json")
    let wrongLease = try MXErgoDeviceOperationLease.acquire(beside: wrongURL)
    let invalidConfiguration = PrecisionRuntimeCompositionConfiguration(
        journalContext: fixture.configuration.journalContext,
        operationLease: wrongLease,
        sessionProvider: fixture.configuration.sessionProvider,
        rootGenerationProvider:
            fixture.configuration.rootGenerationProvider,
        competitorProbe: fixture.configuration.competitorProbe
    )

    do {
        _ = try await PrecisionRuntimeCompositionFactory.make(
            configuration: invalidConfiguration,
            acquire: { _, _, _ in
                events.record("acquire")
                throw RuntimeTestError.unused
            },
            makeTransport: { _, _ in
                events.record("transport-make")
                throw RuntimeTestError.unused
            }
        )
        Issue.record("Expected operation-lease validation failure")
    } catch let failure as PrecisionRuntimeCompositionFailure {
        #expect(failure.phase == .configurationValidation)
        #expect(failure.underlying as? PrecisionRuntimeConfigurationError ==
            .operationLeaseMismatch)
        #expect(failure.deviceCloseReturn == nil)
    }
    #expect(events.values.isEmpty)
}

@Test func transportConstructionFailureDrainsAndReportsCloseResult() async throws {
    let fixture = try runtimeFixture()
    let events = RuntimeEventRecorder()
    let endpoint = FakeRuntimeEndpoint(events: events, closeReturn: 81)

    do {
        _ = try await PrecisionRuntimeCompositionFactory.make(
            configuration: fixture.configuration,
            acquire: { _, _, _ in endpoint },
            makeTransport: { _, acquired in
                #expect(acquired === endpoint)
                events.record("transport-make")
                throw RuntimeTestError.transportConstruction
            }
        )
        Issue.record("Expected transport construction failure")
    } catch let failure as PrecisionRuntimeCompositionFailure {
        #expect(failure.phase == .transportConstruction)
        #expect(failure.underlying as? RuntimeTestError == .transportConstruction)
        #expect(failure.deviceCloseReturn == 81)
    }

    #expect(events.values == ["transport-make", "endpoint-shutdown"])
    #expect(events.count("endpoint-start") == 0)
}

@Test func endpointStartFailureDisconnectsThenDrainsAndReportsCloseResult() async throws {
    let fixture = try runtimeFixture()
    let events = RuntimeEventRecorder()
    let endpoint = FakeRuntimeEndpoint(
        events: events,
        startError: .endpointStart,
        closeReturn: 82
    )
    let transport = FakeRuntimeTransport(
        session: fixture.binding.session,
        events: events
    )

    do {
        _ = try await PrecisionRuntimeCompositionFactory.make(
            configuration: fixture.configuration,
            acquire: { _, _, _ in endpoint },
            makeTransport: { _, _ in transport }
        )
        Issue.record("Expected endpoint start failure")
    } catch let failure as PrecisionRuntimeCompositionFailure {
        #expect(failure.phase == .endpointStart)
        #expect(failure.underlying as? RuntimeTestError == .endpointStart)
        #expect(failure.deviceCloseReturn == 82)
    }

    #expect(events.values == [
        "endpoint-start",
        "transport-disconnect",
        "endpoint-shutdown",
    ])
}

@Test func shutdownCancelsAndSettlesOperationBeforeEndpointDrain() async throws {
    let fixture = try runtimeFixture()
    let events = RuntimeEventRecorder()
    let endpoint = FakeRuntimeEndpoint(events: events, closeReturn: 0)
    let transport = FakeRuntimeTransport(
        session: fixture.binding.session,
        events: events,
        blockCurrentSessionUntilDisconnect: true
    )
    let runtime = try await PrecisionRuntimeCompositionFactory.make(
        configuration: fixture.configuration,
        acquire: { _, _, _ in endpoint },
        makeTransport: { _, _ in transport }
    )

    let operation = Task { try await runtime.activate() }
    await waitUntil { await transport.isCurrentSessionWaiting }
    let report = await runtime.shutdown()

    await #expect(throws: RuntimeTestError.disconnected) {
        try await operation.value
    }
    #expect(report.disposition == .clean(.inactive))
    #expect(events.index(of: "transport-disconnect")! <
        events.index(of: "transport-operation-ended")!)
    #expect(events.index(of: "transport-operation-ended")! <
        events.index(of: "endpoint-shutdown")!)
}

@Test func activeDiversionShutdownIsReportedAsRecoveryRequired() async throws {
    let fixture = try runtimeFixture(active: true)
    let events = RuntimeEventRecorder()
    let endpoint = FakeRuntimeEndpoint(events: events, closeReturn: 0)
    let transport = FakeRuntimeTransport(
        session: fixture.binding.session,
        events: events
    )
    let runtime = try await PrecisionRuntimeCompositionFactory.make(
        configuration: fixture.configuration,
        acquire: { _, _, _ in endpoint },
        makeTransport: { _, _ in transport }
    )

    let report = await runtime.shutdown()

    #expect(report.disposition == .recoveryRequired(.active))
    #expect(report.deviceCloseReturn == 0)
    #expect(events.count("endpoint-shutdown") == 1)
}

@Test func compositionTargetIsProductlessUnwiredAndCapabilityMinimal() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
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
    #expect(!products.contains("MXErgoPrecisionRuntimeComposition"))
    #expect(manifest.components(
        separatedBy: "\"MXErgoPrecisionRuntimeComposition\""
    ).count - 1 == 7)
    #expect(manifest.components(
        separatedBy: "\"MXErgoPrecisionRuntimeCompositionTests\""
    ).count - 1 == 1)

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
    #expect(!projectYAML.contains("MXErgoPrecisionRuntimeComposition"))
    #expect(!projectFile.contains("MXErgoPrecisionRuntimeComposition"))

    let source = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionRuntimeComposition"
        )
    )
    for required in [
        "PrecisionIOHIDAcquisitionFactory.make(",
        "PrecisionTransportFactory.make(",
        "DeviceTransactionCoordinator(",
        "PrecisionTemporaryDiversionLifecycle(",
        "await transport.disconnected()",
        "await endpoint.shutdownAndDrain()",
        "deviceDisconnectHandler",
        "noteDeviceDisconnected()",
        "deviceDisconnected",
    ] {
        #expect(source.contains(required))
    }
    for forbidden in [
        "import IOKit",
        "IOHIDManager",
        "IOHIDDeviceOpen(",
        "IOHIDDeviceClose(",
        "SetReport",
        "kIOHIDOptionsTypeSeizeDevice",
        "@main",
        "ProcessInfo.processInfo.environment",
        "public ",
        "@_spi",
    ] {
        #expect(!source.contains(forbidden))
    }
}

private enum RuntimeTestError: Error, Sendable, Equatable {
    case transportConstruction
    case endpointStart
    case disconnected
    case unused
}

private final class FakeRuntimeEndpoint:
    PrecisionIOHIDAcquiredEndpoint,
    @unchecked Sendable {
    private let events: RuntimeEventRecorder
    private let startError: RuntimeTestError?
    private let lock = NSLock()
    private let configuredCloseReturn: Int32
    private var closeReturnStorage: Int32?
    private var connectionActive = false
    private var disconnectHandler: (@Sendable () -> Void)?

    init(
        events: RuntimeEventRecorder,
        startError: RuntimeTestError? = nil,
        closeReturn: Int32
    ) {
        self.events = events
        self.startError = startError
        configuredCloseReturn = closeReturn
    }

    func start() async throws {
        events.record("endpoint-start")
        if let startError { throw startError }
        lock.withLock { connectionActive = true }
    }

    func shutdownAndDrain() async {
        let shouldRecord = lock.withLock { () -> Bool in
            guard closeReturnStorage == nil else { return false }
            connectionActive = false
            closeReturnStorage = configuredCloseReturn
            return true
        }
        if shouldRecord { events.record("endpoint-shutdown") }
    }

    var deviceCloseReturn: Int32? { lock.withLock { closeReturnStorage } }

    func write(_ frame: PrecisionTransportOutputFrame) async throws -> Int32 {
        _ = frame
        return 0
    }

    func cancelPendingWrite(
        requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        _ = requestID
        _ = reason
    }

    func beginRequest(_ frame: PrecisionTransportOutputFrame) throws { _ = frame }

    func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame {
        _ = requestID
        throw RuntimeTestError.unused
    }

    func endRequest(_ requestID: UUID) { _ = requestID }

    func cancelRequest(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        _ = requestID
        _ = reason
    }

    func validateActiveConnection() throws {
        try lock.withLock {
            guard connectionActive else { throw PrecisionTransportReportIOError.disconnected }
        }
    }

    func disconnected() { fireDisconnect() }

    func setDisconnectHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { disconnectHandler = handler }
    }

    func fireDisconnect() {
        let handler = lock.withLock {
            connectionActive = false
            return disconnectHandler
        }
        handler?()
    }
}

private actor FakeRuntimeTransport: PrecisionTransportSession {
    private let session: DeviceTransactionSession
    private let events: RuntimeEventRecorder
    private let blockCurrentSessionUntilDisconnect: Bool
    private var disconnectedState = false
    private var currentSessionContinuation:
        CheckedContinuation<DeviceTransactionSession, any Error>?

    init(
        session: DeviceTransactionSession,
        events: RuntimeEventRecorder,
        blockCurrentSessionUntilDisconnect: Bool = false
    ) {
        self.session = session
        self.events = events
        self.blockCurrentSessionUntilDisconnect =
            blockCurrentSessionUntilDisconnect
    }

    var isCurrentSessionWaiting: Bool { currentSessionContinuation != nil }

    func currentSession() async throws -> DeviceTransactionSession {
        guard blockCurrentSessionUntilDisconnect else { return session }
        do {
            let value = try await withCheckedThrowingContinuation {
                continuation in
                currentSessionContinuation = continuation
            }
            events.record("transport-operation-ended")
            return value
        } catch {
            events.record("transport-operation-ended")
            throw error
        }
    }

    func disconnected() async {
        guard !disconnectedState else { return }
        disconnectedState = true
        events.record("transport-disconnect")
        currentSessionContinuation?.resume(throwing: RuntimeTestError.disconnected)
        currentSessionContinuation = nil
    }

    func prepare(
        _ proposed: DeviceTransactionMutation,
        expectedSession: DeviceTransactionSession,
        expectedCommittedRevision: UInt64
    ) async throws -> DeviceTransactionPreparedInvocation {
        throw RuntimeTestError.unused
    }

    func invoke(
        _ prepared: DeviceTransactionPreparedInvocation,
        authorization: DeviceTransactionDurableCommitReceipt
    ) async throws -> DeviceTransactionInvocationEvidence? {
        throw RuntimeTestError.unused
    }

    func abandon(
        _ prepared: DeviceTransactionPreparedInvocation,
        disposition: DeviceTransactionPreparationDisposition
    ) async {
        _ = prepared
        _ = disposition
    }

    func readReporting(
        controlID: UInt16,
        expectedSession: DeviceTransactionSession
    ) async throws -> DeviceTransactionWireState {
        _ = controlID
        _ = expectedSession
        throw RuntimeTestError.unused
    }
}

private actor StaticRuntimeRepository: PrecisionRuntimeJournalSource {
    nonisolated let journalURL = URL(
        fileURLWithPath: "/private/tmp/fake-runtime-journal-\(UUID().uuidString)",
        isDirectory: true
    ).appendingPathComponent("runtime.json")
    private var envelope: DeviceTransactionEnvelope?
    private let snapshotReadCounter: RuntimeCounter?
    private var snapshotData: Data

    init(
        envelope: DeviceTransactionEnvelope?,
        snapshotReadCounter: RuntimeCounter? = nil
    ) {
        self.envelope = envelope
        self.snapshotReadCounter = snapshotReadCounter
        snapshotData = Data("runtime-composition-test".utf8)
    }

    func loadValidated() async throws -> DeviceTransactionEnvelope? { envelope }

    func commit(
        _ next: DeviceTransactionEnvelope,
        expectedRevision: UInt64?
    ) async throws -> DeviceTransactionDurableCommitReceipt {
        _ = expectedRevision
        envelope = next
        snapshotData = Data("runtime-composition-test-\(next.revision)".utf8)
        return DeviceTransactionDurableCommitReceipt(
            transactionID: next.transactionID,
            revision: next.revision,
            sha256: "runtime-test-\(next.revision)"
        )
    }

    func loadValidatedSnapshot() async throws -> PrecisionRuntimeJournalSnapshot {
        snapshotReadCounter?.increment()
        return PrecisionRuntimeJournalSnapshot(
            data: snapshotData,
            envelope: try #require(envelope),
            sha256: String(repeating: "a", count: 64)
        )
    }
}

private final class RuntimeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func record(_ value: String) { lock.withLock { storage.append(value) } }

    func count(_ value: String) -> Int {
        lock.withLock { storage.filter { $0 == value }.count }
    }

    func index(of value: String) -> Int? {
        lock.withLock { storage.firstIndex(of: value) }
    }
}

private final class RuntimeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() { lock.withLock { storage += 1 } }
}

private struct RuntimeFixture {
    let plan: PrecisionTemporaryDiversionPlan
    let binding: PrecisionTransportBinding
    let configuration: PrecisionRuntimeCompositionConfiguration
}

private func runtimeFixture(
    active: Bool = false,
    snapshotReadCounter: RuntimeCounter? = nil
) throws -> RuntimeFixture {
    let device = JournalDeviceIdentity(
        deviceID: "1133-45085-17-1-2",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "RUNTIME-COMPOSITION-TEST",
        locationID: 17,
        firmwareIdentity: "runtime-composition-test-firmware"
    )
    let baselineParameters = padded([0x00, 0xED, 0x00, 0x00, 0x00])
    let control = try DeviceControlJournalEntry(
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
            rawParameters: baselineParameters
        )
    )
    let feature = HIDPP20FeatureDescriptor(
        index: 0x0A,
        type: 0,
        version: 3,
        rawParameters: padded([0x0A, 0x00, 0x03])
    )
    let journal = try DeviceStateJournal(
        transactionID: UUID(),
        appBuild: "runtime-composition-test",
        device: device,
        feature: feature,
        expectedControlCount: 1,
        controls: [control]
    )
    let plan = try PrecisionTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let session = DeviceTransactionSession(
        device: device,
        featureID: ReprogControlsV4.featureID,
        featureVersion: 3,
        featureIndex: feature.index,
        connectionEpoch: 42
    )
    let binding = PrecisionTransportBinding(
        session: session,
        rootGeneration: 900
    )
    var envelope = try DeviceTransactionEnvelope(baselineJournal: journal)
    if active {
        envelope = try DeviceTransactionReducer.reduce(
            envelope,
            event: .armApply(
                controlID: PrecisionTemporaryDiversionPlan.controlID,
                intended: plan.activeState,
                attemptID: UUID(),
                now: Date()
            )
        ).envelope
        envelope = try DeviceTransactionReducer.reduce(
            envelope,
            event: .observeApply(
                controlID: PrecisionTemporaryDiversionPlan.controlID,
                state: plan.activeState,
                now: Date()
            )
        ).envelope
    }
    let repository = StaticRuntimeRepository(
        envelope: envelope,
        snapshotReadCounter: snapshotReadCounter
    )
    let initialSnapshot = PrecisionRuntimeJournalSnapshot(
        data: Data("runtime-composition-test".utf8),
        envelope: envelope,
        sha256: String(repeating: "a", count: 64)
    )
    let journalContext = PrecisionRuntimeJournalContext(
        plan: plan,
        session: session,
        rootGeneration: binding.rootGeneration,
        sourceBaselineSHA256: String(repeating: "b", count: 64),
        sourceBaselineTransactionID: envelope.sourceBaselineTransactionID,
        source: repository,
        snapshot: initialSnapshot,
        disposition: .created
    )
    let operationLease = try MXErgoDeviceOperationLease.acquire(
        beside: journalContext.source.journalURL
    )
    let configuration = PrecisionRuntimeCompositionConfiguration(
        journalContext: journalContext,
        operationLease: operationLease,
        sessionProvider: { session },
        rootGenerationProvider: { binding.rootGeneration },
        competitorProbe: { [] }
    )
    return RuntimeFixture(
        plan: plan,
        binding: binding,
        configuration: configuration
    )
}

private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<10_000 {
        if await predicate() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for asynchronous test condition")
}

private func padded(_ bytes: [UInt8]) -> [UInt8] {
    bytes + Array(
        repeating: 0,
        count: HIDPP20LongMessage.parameterCount - bytes.count
    )
}

private func sourceText(under directory: URL) throws -> String {
    let enumerator = try #require(
        FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        )
    )
    let files = enumerator.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
    return try files.map {
        try String(contentsOf: $0, encoding: .utf8)
    }.joined(separator: "\n")
}


private actor EndpointEvidenceGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var started = false
    func wait() async {
        started = true
        entered?.resume()
        entered = nil
        await withCheckedContinuation { waiting = $0 }
    }
    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { waiting?.resume(); waiting = nil }
}

@Test func endpointEvidenceRejectsCachedValuesAfterDisconnectDuringSuspension() async throws {
    let endpoint = FakeRuntimeEndpoint(events: RuntimeEventRecorder(), closeReturn: 0)
    try await endpoint.start()
    let gate = EndpointEvidenceGate()
    let read = Task {
        try await PrecisionRuntimeCompositionFactory.validatedEndpointEvidence(endpoint: endpoint) {
            await gate.wait()
            return UInt64(17)
        }
    }
    await gate.waitUntilStarted()
    endpoint.fireDisconnect()
    await gate.release()
    await #expect(throws: PrecisionTransportReportIOError.disconnected) {
        try await read.value
    }
    await endpoint.shutdownAndDrain()
}

@Test func endpointEvidenceRefusesToConsultProvidersWhenAlreadyDisconnected() async throws {
    let endpoint = FakeRuntimeEndpoint(events: RuntimeEventRecorder(), closeReturn: 0)
    try await endpoint.start()
    endpoint.fireDisconnect()
    let calls = RuntimeCounter()
    await #expect(throws: PrecisionTransportReportIOError.disconnected) {
        try await PrecisionRuntimeCompositionFactory.validatedEndpointEvidence(endpoint: endpoint) {
            calls.increment()
            return UInt64(17)
        }
    }
    #expect(calls.value == 0)
    await endpoint.shutdownAndDrain()
}

@Test func endpointEvidencePreservesContextOnlyWhileInputRemainsActive() async throws {
    let endpoint = FakeRuntimeEndpoint(events: RuntimeEventRecorder(), closeReturn: 0)
    try await endpoint.start()
    let value = try await PrecisionRuntimeCompositionFactory.validatedEndpointEvidence(endpoint: endpoint) {
        UInt64(17)
    }
    #expect(value == 17)
    await endpoint.shutdownAndDrain()
    await #expect(throws: PrecisionTransportReportIOError.disconnected) {
        try await PrecisionRuntimeCompositionFactory.validatedEndpointEvidence(endpoint: endpoint) {
            UInt64(17)
        }
    }
}
