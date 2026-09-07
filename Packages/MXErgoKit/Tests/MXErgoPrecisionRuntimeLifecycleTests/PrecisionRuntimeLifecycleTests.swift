import Foundation
import MXErgoHIDPP
import Testing
@testable import MXErgoHID
@testable import MXErgoPrecisionRuntimeAdmission
@testable import MXErgoPrecisionRuntimeComposition
@testable import MXErgoPrecisionRuntimeHostHandoff
@testable import MXErgoPrecisionRuntimeLifecycle

@Test func lifecycleHoldsRestartFenceThroughAdmitShutdownAndExplicitRollover()
    async throws
{
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    let fenceID = try #require(
        coordinator.installRestartFence(capturedRunID: runID)
    )
    let fence = MXErgoObserverRestartFence(
        fenceID: fenceID,
        capturedRunID: runID,
        observerID: UUID()
    )
    let events = LockedLifecycleEvents()
    let owner = PrecisionRuntimeLifecycle(
        intent: lifecycleIntent(observerRunID: runID),
        fence: fence,
        hostHandoff: LifecycleStubHandoff(observerRunID: runID, events: events),
        releaseFence: { token in
            events.append("release")
            return coordinator.releaseRestartFence(fenceID: token.fenceID)
        }
    )

    #expect(await owner.phase == .bound)
    #expect(coordinator.beginRun() == nil)

    try await owner.admit(
        authorization: lifecycleAuthorization(),
        competitorProbe: { [] },
        sessionProvider: { lifecycleSession() },
        rootGenerationProvider: { 1 },
        admit: { configuration in
            events.append("admit")
            #expect(configuration.intent.observerRunID == runID)
            return LifecycleFakeSession(events: events)
        }
    )
    #expect(await owner.phase == .admitted)
    await #expect(throws: PrecisionRuntimeLifecycleError.stillOwningRuntime) {
        try await owner.releaseObserverRestartFence()
    }
    #expect(coordinator.restartFenceCapturedRunID == runID)

    let report = await owner.shutdown()
    #expect(report?.disposition == .stateUnavailable("test"))
    #expect(await owner.phase == .shutDown)
    #expect(coordinator.beginStop(runID: runID))
    #expect(coordinator.performTeardown(
        runID: runID,
        managerWasAcquired: true,
        calls: noOpLifecycleTeardownCalls()
    ) != nil)
    #expect(coordinator.beginRun() == nil)
    #expect(events.values == ["admit", "shutdown"])

    #expect(try await owner.releaseObserverRestartFence())
    #expect(await owner.phase == .released)
    #expect(events.values == ["admit", "shutdown", "release"])
    let nextRunID = try #require(coordinator.beginRun())
    #expect(nextRunID != runID)
}

@Test func lifecycleAbandonFromBoundReleasesFenceWithoutAdmitting()
    async throws
{
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    let fenceID = try #require(
        coordinator.installRestartFence(capturedRunID: runID)
    )
    let events = LockedLifecycleEvents()
    let owner = PrecisionRuntimeLifecycle(
        intent: lifecycleIntent(observerRunID: runID),
        fence: MXErgoObserverRestartFence(
            fenceID: fenceID,
            capturedRunID: runID,
            observerID: UUID()
        ),
        hostHandoff: LifecycleStubHandoff(observerRunID: runID, events: events),
        releaseFence: { token in
            events.append("release")
            return coordinator.releaseRestartFence(fenceID: token.fenceID)
        }
    )

    #expect(await owner.shutdown() == nil)
    #expect(await owner.phase == .shutDown)
    #expect(try await owner.releaseObserverRestartFence())
    #expect(await owner.phase == .released)
    #expect(events.values == ["release"])
    #expect(coordinator.beginStop(runID: runID))
    #expect(coordinator.performTeardown(
        runID: runID,
        managerWasAcquired: false,
        calls: noOpLifecycleTeardownCalls()
    ) != nil)
    #expect(coordinator.beginRun() != nil)
}

@Test func failedAdmitLeavesFenceInstalledAndDoesNotCreateASession()
    async throws
{
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    let fenceID = try #require(
        coordinator.installRestartFence(capturedRunID: runID)
    )
    let events = LockedLifecycleEvents()
    let owner = PrecisionRuntimeLifecycle(
        intent: lifecycleIntent(observerRunID: runID),
        fence: MXErgoObserverRestartFence(
            fenceID: fenceID,
            capturedRunID: runID,
            observerID: UUID()
        ),
        hostHandoff: LifecycleStubHandoff(observerRunID: runID, events: events),
        releaseFence: { token in
            events.append("release")
            return coordinator.releaseRestartFence(fenceID: token.fenceID)
        }
    )

    await #expect(throws: LifecycleTestError.admit) {
        try await owner.admit(
            authorization: lifecycleAuthorization(),
            competitorProbe: { [] },
            sessionProvider: { lifecycleSession() },
            rootGenerationProvider: { 1 },
            admit: { _ in
                events.append("admit")
                throw LifecycleTestError.admit
            }
        )
    }
    #expect(await owner.phase == .bound)
    #expect(coordinator.beginRun() == nil)
    await #expect(throws: PrecisionRuntimeLifecycleError.notAdmitted) {
        _ = try await owner.reviewIntent(
            for: .deactivate,
            expiresAtUptimeNanoseconds: 1
        )
    }
    #expect(try await owner.releaseObserverRestartFence())
    #expect(events.values == ["admit", "release"])
}

@Test func subsequentOperationsRemainBoundToTheCapturedObserverRun()
    async throws
{
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    let fenceID = try #require(
        coordinator.installRestartFence(capturedRunID: runID)
    )
    let events = LockedLifecycleEvents()
    let owner = PrecisionRuntimeLifecycle(
        intent: lifecycleIntent(observerRunID: runID),
        fence: MXErgoObserverRestartFence(
            fenceID: fenceID,
            capturedRunID: runID,
            observerID: UUID()
        ),
        hostHandoff: LifecycleStubHandoff(observerRunID: runID, events: events),
        releaseFence: { token in
            coordinator.releaseRestartFence(fenceID: token.fenceID)
        }
    )
    try await owner.admit(
        authorization: lifecycleAuthorization(),
        competitorProbe: { [] },
        sessionProvider: { lifecycleSession() },
        rootGenerationProvider: { 1 },
        admit: { _ in
            LifecycleFakeSession(events: events, observerRunID: runID)
        }
    )

    let reviewed = try await owner.reviewIntent(
        for: .deactivate,
        expiresAtUptimeNanoseconds: 99
    )
    #expect(reviewed.observerRunID == runID)
    try await owner.perform(
        reviewed,
        authorization: lifecycleAuthorization()
    )
    let foreign = lifecycleIntent(observerRunID: UUID())
    await #expect(throws: PrecisionRuntimeLifecycleError
        .invalidAuthorizationBinding)
    {
        try await owner.perform(
            foreign,
            authorization: lifecycleAuthorization()
        )
    }
    #expect(events.values == ["review", "perform"])
}

@Test func bindRequiresAMatchingCapturedRunBeforeInstallingTheFence() {
    let observer = MXErgoObserver()
    #expect(throws: PrecisionRuntimeLifecycleError.observerNotRunning) {
        _ = try PrecisionRuntimeLifecycle.bind(
            observer: observer,
            intent: lifecycleIntent(observerRunID: UUID()),
            evidenceProvider: {
                PrecisionRuntimeObserverHostEvidence(
                    session: lifecycleSession(),
                    rootGeneration: 1
                )
            }
        )
    }
}

@Test func lifecycleTargetIsProductlessUnwiredAndAbsentFromExecutables()
    throws
{
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
    #expect(!products.contains("MXErgoPrecisionRuntimeLifecycle"))
    #expect(!manifest.contains(
        ".library(name: \"MXErgoPrecisionRuntimeLifecycle\""
    ))

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
    #expect(!projectYAML.contains("MXErgoPrecisionRuntimeLifecycle"))
    #expect(!projectFile.contains("MXErgoPrecisionRuntimeLifecycle"))

    let source = try String(
        contentsOf: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionRuntimeLifecycle/" +
                "PrecisionRuntimeLifecycle.swift"
        ),
        encoding: .utf8
    )
    for required in [
        "installRestartFence",
        "releaseRestartFence",
        "intent.observerRunID",
        "PrecisionRuntimeAdmissionFactory.admit(",
        "stillOwningRuntime",
        "deviceDisconnectHandler",
        "shutdownRequiresRecovery",
    ] {
        #expect(source.contains(required))
    }
    for forbidden in [
        "import IOKit",
        "IOHID",
        "public ",
        "@main",
        "UserDefaults",
        ": Codable",
        "SetReport",
        "Process(",
    ] {
        #expect(!source.contains(forbidden))
    }
}

private func lifecycleCanonicalURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/tmp/\(name)")
        .standardizedFileURL
        .resolvingSymlinksInPath()
}

private func lifecycleIntent(
    observerRunID: UUID
) -> PrecisionRuntimeAdmissionIntent {
    let device = JournalDeviceIdentity(
        deviceID: "1133-45085-29-1-2",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "LIFECYCLE-TEST",
        locationID: 29,
        firmwareIdentity: "lifecycle-test-firmware"
    )
    let session = DeviceTransactionSession(
        device: device,
        featureID: ReprogControlsV4.featureID,
        featureVersion: 3,
        featureIndex: 0x0A,
        connectionEpoch: 1
    )
    let sourceURL = lifecycleCanonicalURL("lifecycle-source.json")
    let runtimeURL = lifecycleCanonicalURL("lifecycle-runtime.json")
    return PrecisionRuntimeAdmissionIntent(
        launchID: UUID(
            uuidString: "11111111-1111-1111-1111-111111111111"
        )!,
        observerRunID: observerRunID,
        operation: .activate,
        readiness: lifecycleReadiness(device: device, session: session),
        session: session,
        rootGeneration: 1,
        sourceBaselineURL: sourceURL,
        runtimeJournalURL: runtimeURL,
        sourceBaselineCanonicalPath: sourceURL.path,
        runtimeJournalCanonicalPath: runtimeURL.path,
        expectedRuntimeSnapshot: nil,
        expiresAtUptimeNanoseconds: 1_000
    )
}

private func lifecycleReadiness(
    device: JournalDeviceIdentity,
    session: DeviceTransactionSession
) -> PrecisionTemporaryDiversionReadinessSnapshot {
    let controlInfo = ReprogControlInfo(
        index: 5,
        controlID: 0x00ED,
        taskID: 0x00C4,
        capabilityFlags: 0x71,
        position: 0,
        group: 1,
        groupMask: 1,
        rawXYCapability: false,
        rawParameters: lifecyclePadded([0x00, 0xED])
    )
    let baseline = ReprogControlReportingState(
        controlID: 0x00ED,
        rawFlags: 0,
        rawMappedControlID: 0,
        rawParameters: lifecyclePadded([0x00, 0xED, 0, 0, 0])
    )
    let plan: PrecisionTemporaryDiversionPlan
    do {
        let entry = try DeviceControlJournalEntry(
            controlInfo: controlInfo,
            baselineReporting: baseline
        )
        let journal = try DeviceStateJournal(
            transactionID: UUID(),
            appBuild: "lifecycle-test",
            device: device,
            feature: HIDPP20FeatureDescriptor(
                index: 0x0A,
                type: 0,
                version: 3,
                rawParameters: lifecyclePadded([0x0A, 0, 3])
            ),
            expectedControlCount: 1,
            controls: [entry]
        )
        plan = try PrecisionTemporaryDiversionPlan.make(
            journal: journal,
            currentFeature: journal.feature,
            deviceIndex: 0,
            softwareID: 0x0E
        )
        return PrecisionTemporaryDiversionReadinessSnapshot(
            plan: plan,
            sourceJournalSHA256: String(repeating: "a", count: 64),
            sourceBaselineTransactionID: journal.transactionID,
            connectionGeneration: 1,
            connectionEpoch: session.connectionEpoch,
            authorization: .notAuthorizedForExecution
        )
    } catch {
        fatalError("lifecycle readiness fixture failed: \(error)")
    }
}

private func lifecycleSession() -> DeviceTransactionSession {
    DeviceTransactionSession(
        device: JournalDeviceIdentity(
            deviceID: "1133-45085-29-1-2",
            vendorID: 0x046D,
            productID: 0xB01D,
            transport: "Bluetooth Low Energy",
            serialNumber: "LIFECYCLE-TEST",
            locationID: 29,
            firmwareIdentity: "lifecycle-test-firmware"
        ),
        featureID: ReprogControlsV4.featureID,
        featureVersion: 3,
        featureIndex: 0x0A,
        connectionEpoch: 1
    )
}

private func lifecycleAuthorization() -> PrecisionRuntimeAdmissionAuthorization {
    // Tests inject admit() and never consume this capability.
    let intent = lifecycleIntent(observerRunID: UUID())
    return try! PrecisionRuntimeAdmissionAuthorizationFactory.issue(
        for: intent,
        explicitlyConfirmed: true,
        nowUptimeNanoseconds: 0
    )
}

private func lifecyclePadded(_ bytes: [UInt8]) -> [UInt8] {
    bytes + Array(repeating: 0, count: max(0, 16 - bytes.count))
}

private enum LifecycleTestError: Error {
    case admit
}

private struct LifecycleStubHandoff: PrecisionRuntimeHostHandoff {
    let observerRunID: UUID
    let events: LockedLifecycleEvents?

    func stopAndWait(
        launchID: UUID,
        expectedSession: DeviceTransactionSession,
        expectedRootGeneration: UInt64,
        expectedObserverRunID: UUID,
        timeoutNanoseconds: UInt64
    ) async throws -> PrecisionRuntimeHostHandoffReceipt {
        _ = timeoutNanoseconds
        events?.append("handoff")
        return PrecisionRuntimeHostHandoffReceipt(
            launchID: launchID,
            session: expectedSession,
            rootGeneration: expectedRootGeneration,
            observerRunID: expectedObserverRunID,
            pendingRequestCount: 0,
            observerWasUnscheduled: true,
            observerDeviceWasClosed: true
        )
    }
}

private actor LifecycleFakeSession: PrecisionRuntimeLifecycleSession {
    private let events: LockedLifecycleEvents
    private let boundIntent: PrecisionRuntimeAdmissionIntent
    private let shutdownStarted: LifecycleTestGate?
    private let shutdownRelease: LifecycleTestGate?

    init(
        events: LockedLifecycleEvents, observerRunID: UUID = UUID(),
        shutdownStarted: LifecycleTestGate? = nil,
        shutdownRelease: LifecycleTestGate? = nil
    ) {
        self.shutdownStarted = shutdownStarted
        self.shutdownRelease = shutdownRelease
        self.events = events
        boundIntent = lifecycleIntent(observerRunID: observerRunID)
    }

    var state: PrecisionRuntimeAdmissionState { .active }

    func reviewIntent(
        for operation: PrecisionTemporaryDiversionOperation,
        expiresAtUptimeNanoseconds: UInt64
    ) async throws -> PrecisionRuntimeAdmissionIntent {
        events.append("review")
        return PrecisionRuntimeAdmissionIntent(
            launchID: boundIntent.launchID,
            observerRunID: boundIntent.observerRunID,
            operation: operation,
            readiness: boundIntent.readiness,
            session: boundIntent.session,
            rootGeneration: boundIntent.rootGeneration,
            sourceBaselineURL: boundIntent.sourceBaselineURL,
            runtimeJournalURL: boundIntent.runtimeJournalURL,
            sourceBaselineCanonicalPath:
                boundIntent.sourceBaselineCanonicalPath,
            runtimeJournalCanonicalPath:
                boundIntent.runtimeJournalCanonicalPath,
            expectedRuntimeSnapshot: boundIntent.expectedRuntimeSnapshot,
            expiresAtUptimeNanoseconds: expiresAtUptimeNanoseconds
        )
    }

    func perform(
        _ intent: PrecisionRuntimeAdmissionIntent,
        authorization: PrecisionRuntimeAdmissionAuthorization
    ) async throws {
        _ = intent
        _ = authorization
        events.append("perform")
    }

    func shutdown() async -> PrecisionRuntimeShutdownReport {
        events.append("shutdown")
        shutdownStarted?.open()
        await shutdownRelease?.wait()
        return PrecisionRuntimeShutdownReport(
            disposition: .stateUnavailable("test"),
            deviceCloseReturn: 0
        )
    }
}

private func noOpLifecycleTeardownCalls() -> MXErgoObserverTeardownCalls {
    MXErgoObserverTeardownCalls(
        clearRequestState: {},
        unscheduleManager: {},
        closeManager: { 0 },
        didQuiesceCallbacks: {}
    )
}

private final class LockedLifecycleEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}


private final class LifecycleTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock {
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if immediate { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock {
            opened = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }
}

private func makeTerminationRaceLifecycle(events: LockedLifecycleEvents) -> PrecisionRuntimeLifecycle {
    let runID = UUID()
    return PrecisionRuntimeLifecycle(
        intent: lifecycleIntent(observerRunID: runID),
        fence: MXErgoObserverRestartFence(
            fenceID: UUID(), capturedRunID: runID, observerID: UUID()
        ),
        hostHandoff: LifecycleStubHandoff(observerRunID: runID, events: events),
        releaseFence: { _ in events.append("release"); return true }
    )
}

@Test func shutdownDrainsLateAdmissionOnceBeforeAnyCallerCanFinish() async throws {
    let events = LockedLifecycleEvents()
    let owner = makeTerminationRaceLifecycle(events: events)
    let started = LifecycleTestGate()
    let cancelled = LifecycleTestGate()
    let admissionRelease = LifecycleTestGate()
    let shutdownStarted = LifecycleTestGate()
    let shutdownRelease = LifecycleTestGate()
    let admitting = Task {
        try await owner.admit(
            authorization: lifecycleAuthorization(), competitorProbe: { [] },
            sessionProvider: { lifecycleSession() }, rootGenerationProvider: { 1 },
            admit: { _ in
                await withTaskCancellationHandler {
                    started.open()
                    await admissionRelease.wait()
                    return LifecycleFakeSession(
                        events: events, shutdownStarted: shutdownStarted,
                        shutdownRelease: shutdownRelease
                    )
                } onCancel: { cancelled.open() }
            }
        )
    }
    await started.wait()
    await #expect(throws: PrecisionRuntimeLifecycleError.alreadyAdmitted) {
        try await owner.admit(
            authorization: lifecycleAuthorization(), competitorProbe: { [] },
            sessionProvider: { lifecycleSession() }, rootGenerationProvider: { 1 },
            admit: { _ in Issue.record("second admission must not run"); return LifecycleFakeSession(events: events) }
        )
    }
    let firstShutdown = Task { await owner.shutdown() }
    await cancelled.wait()
    let secondShutdown = Task { await owner.shutdown() }
    await #expect(throws: PrecisionRuntimeLifecycleError.stillOwningRuntime) {
        _ = try await owner.releaseObserverRestartFence()
    }
    admissionRelease.open()
    await shutdownStarted.wait()
    #expect(await owner.phase != .admitted)
    #expect(events.values == ["shutdown"])
    await #expect(throws: PrecisionRuntimeLifecycleError.stillOwningRuntime) {
        _ = try await owner.releaseObserverRestartFence()
    }
    shutdownRelease.open()
    let firstReport = await firstShutdown.value
    let secondReport = await secondShutdown.value
    #expect(firstReport == secondReport)
    #expect(firstReport?.disposition == .stateUnavailable("test"))
    await #expect(throws: PrecisionRuntimeLifecycleError.shuttingDown) {
        try await admitting.value
    }
    #expect(await owner.phase == .shutDown)
    #expect(events.values == ["shutdown"])
    #expect(try await owner.releaseObserverRestartFence())
    #expect(events.values == ["shutdown", "release"])
}

@Test func shutdownBeforeAdmissionIsTerminalAndKeepsTheFence() async throws {
    let events = LockedLifecycleEvents()
    let owner = makeTerminationRaceLifecycle(events: events)
    #expect(await owner.shutdown() == nil)
    #expect(await owner.shutdown() == nil)
    #expect(await owner.phase == .shutDown)
    await #expect(throws: PrecisionRuntimeLifecycleError.shuttingDown) {
        try await owner.admit(
            authorization: lifecycleAuthorization(), competitorProbe: { [] },
            sessionProvider: { lifecycleSession() }, rootGenerationProvider: { 1 },
            admit: { _ in Issue.record("shutdown must close admission"); return LifecycleFakeSession(events: events) }
        )
    }
    #expect(events.values.isEmpty)
}

@Test func failedPendingAdmissionStillCompletesSharedShutdown() async throws {
    let events = LockedLifecycleEvents()
    let owner = makeTerminationRaceLifecycle(events: events)
    let started = LifecycleTestGate()
    let cancelled = LifecycleTestGate()
    let release = LifecycleTestGate()
    let admitting = Task {
        try await owner.admit(
            authorization: lifecycleAuthorization(), competitorProbe: { [] },
            sessionProvider: { lifecycleSession() }, rootGenerationProvider: { 1 },
            admit: { _ in
                try await withTaskCancellationHandler {
                    started.open()
                    await release.wait()
                    throw LifecycleTestError.admit
                } onCancel: { cancelled.open() }
            }
        )
    }
    await started.wait()
    let shutdown = Task { await owner.shutdown() }
    await cancelled.wait()
    release.open()
    #expect(await shutdown.value == nil)
    await #expect(throws: LifecycleTestError.admit) { try await admitting.value }
    #expect(await owner.phase == .shutDown)
    #expect(events.values.isEmpty)
}
