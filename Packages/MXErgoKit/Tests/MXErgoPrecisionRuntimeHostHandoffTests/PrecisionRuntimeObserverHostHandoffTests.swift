import Foundation
import MXErgoCore
import MXErgoHIDPP
import Testing
@testable import MXErgoHID
@testable import MXErgoPrecisionRuntimeAdmission
@testable import MXErgoPrecisionRuntimeHostHandoff

@Test func handoffMapsOnlyFreshPostStopEvidenceIntoAdmissionReceipt()
    async throws
{
    let launchID = UUID()
    let session = handoffSession()
    let runID = UUID()
    let events = LockedHandoffEvents()
    let adapter = PrecisionRuntimeObserverHostHandoff(
        launchID: launchID,
        session: session,
        rootGeneration: 17,
        observerRunID: runID,
        evidenceProvider: {
            events.append("evidence")
            return PrecisionRuntimeObserverHostEvidence(
                session: session,
                rootGeneration: 17
            )
        },
        stopOperation: { timeout in
            events.append("stop:\(timeout)")
            return .stopped(handoffReceipt(
                runID: runID,
                pendingAtStop: 4
            ))
        }
    )

    let receipt = try await adapter.stopAndWait(
        launchID: launchID,
        expectedSession: session,
        expectedRootGeneration: 17,
        expectedObserverRunID: runID,
        timeoutNanoseconds: 91
    )

    #expect(events.values == ["stop:91", "evidence"])
    #expect(receipt.launchID == launchID)
    #expect(receipt.session == session)
    #expect(receipt.rootGeneration == 17)
    #expect(receipt.observerRunID == runID)
    #expect(receipt.pendingRequestCount == 0)
    #expect(receipt.observerWasUnscheduled)
    #expect(receipt.observerDeviceWasClosed)
}

@Test func requestBindingMismatchHasNoObserverOrEvidenceSideEffect()
    async
{
    let launchID = UUID()
    let session = handoffSession()
    let events = LockedHandoffEvents()
    let adapter = makeHandoffAdapter(
        launchID: launchID,
        session: session,
        rootGeneration: 17,
        events: events
    )

    await expectHandoffError(.requestBindingMismatch) {
        try await adapter.stopAndWait(
            launchID: UUID(),
            expectedSession: session,
            expectedRootGeneration: 17,
            expectedObserverRunID: handoffRunID,
            timeoutNanoseconds: 1
        )
    }
    await expectHandoffError(.requestBindingMismatch) {
        try await adapter.stopAndWait(
            launchID: launchID,
            expectedSession: handoffSession(connectionEpoch: 99),
            expectedRootGeneration: 17,
            expectedObserverRunID: handoffRunID,
            timeoutNanoseconds: 1
        )
    }
    await expectHandoffError(.requestBindingMismatch) {
        try await adapter.stopAndWait(
            launchID: launchID,
            expectedSession: session,
            expectedRootGeneration: 18,
            expectedObserverRunID: handoffRunID,
            timeoutNanoseconds: 1
        )
    }
    await expectHandoffError(.requestBindingMismatch) {
        try await adapter.stopAndWait(
            launchID: launchID,
            expectedSession: session,
            expectedRootGeneration: 17,
            expectedObserverRunID: UUID(),
            timeoutNanoseconds: 1
        )
    }
    #expect(events.values.isEmpty)
}

@Test func observerReceiptMustNameTheCapturedFullyDrainedQuiescedRun()
    async
{
    let expectedRunID = UUID()
    let wrongRunAdapter = makeHandoffAdapter(
        observerRunID: expectedRunID,
        stopResult: .stopped(handoffReceipt(runID: UUID()))
    )
    await expectHandoffError(.invalidObserverReceipt) {
        try await callHandoff(wrongRunAdapter, observerRunID: expectedRunID)
    }

    let pendingAdapter = makeHandoffAdapter(
        observerRunID: expectedRunID,
        stopResult: .stopped(handoffReceipt(
            runID: expectedRunID,
            finalPending: 1
        ))
    )
    await expectHandoffError(.invalidObserverReceipt) {
        try await callHandoff(pendingAdapter, observerRunID: expectedRunID)
    }

    let callbacksAdapter = makeHandoffAdapter(
        observerRunID: expectedRunID,
        stopResult: .stopped(handoffReceipt(
            runID: expectedRunID,
            callbackDeliveryQuiesced: false
        ))
    )
    await expectHandoffError(.invalidObserverReceipt) {
        try await callHandoff(callbacksAdapter, observerRunID: expectedRunID)
    }
}

@Test func observerManagerMustHaveBeenAcquiredAndDefinitelyClosed()
    async
{
    let runID = UUID()
    let neverAcquired = makeHandoffAdapter(
        observerRunID: runID,
        stopResult: .stopped(handoffReceipt(
            runID: runID,
            ownership: .neverAcquired
        ))
    )
    await expectHandoffError(.observerWasNeverAcquired) {
        try await callHandoff(neverAcquired, observerRunID: runID)
    }

    let releaseUncertain = makeHandoffAdapter(
        observerRunID: runID,
        stopResult: .stopped(handoffReceipt(
            runID: runID,
            ownership: .releaseUncertain(closeReturn: -7)
        ))
    )
    await expectHandoffError(.observerReleaseUncertain(closeReturn: -7)) {
        try await callHandoff(releaseUncertain, observerRunID: runID)
    }
}

@Test func observerStopOutcomesPreserveRunSpecificFailureEvidence()
    async
{
    let runID = UUID()
    let actualRunID = UUID()
    let cases: [(
        MXErgoObserverHandoffWaitResult,
        PrecisionRuntimeObserverHostHandoffError
    )] = [
        (.timedOut(runID: runID), .observerStopTimedOut(runID: runID)),
        (.cancelled(runID: runID), .observerStopCancelled(runID: runID)),
        (.notRunning, .observerNotRunning),
        (
            .runMismatch(
                expectedRunID: runID,
                actualRunID: actualRunID
            ),
            .observerRunMismatch(
                expectedRunID: runID,
                actualRunID: actualRunID
            )
        ),
    ]

    for (result, expectedError) in cases {
        let events = LockedHandoffEvents()
        let adapter = makeHandoffAdapter(
            observerRunID: runID,
            stopResult: result,
            events: events
        )
        await expectHandoffError(expectedError) {
            try await callHandoff(adapter, observerRunID: runID)
        }
        #expect(events.values == ["stop"])
    }
}

@Test func evidenceIsReadAfterStopAndMustRemainExact() async {
    let session = handoffSession()
    let changedSession = makeHandoffAdapter(
        session: session,
        evidenceProvider: {
            PrecisionRuntimeObserverHostEvidence(
                session: handoffSession(connectionEpoch: 99),
                rootGeneration: 17
            )
        }
    )
    await expectHandoffError(.evidenceChangedAfterStop) {
        try await callHandoff(changedSession)
    }

    let changedGeneration = makeHandoffAdapter(
        session: session,
        evidenceProvider: {
            PrecisionRuntimeObserverHostEvidence(
                session: session,
                rootGeneration: 18
            )
        }
    )
    await expectHandoffError(.evidenceChangedAfterStop) {
        try await callHandoff(changedGeneration)
    }

    let unavailable = makeHandoffAdapter(
        session: session,
        evidenceProvider: { throw HandoffTestError.evidence }
    )
    await expectHandoffError(.evidenceUnavailable) {
        try await callHandoff(unavailable)
    }
}

@Test func concurrentCallersShareUncancelledPhysicalStopAndStickyReceipt()
    async throws
{
    let events = LockedHandoffEvents()
    let gate = HandoffAsyncGate()
    let adapter = makeHandoffAdapter(
        events: events,
        stopOperation: { _ in
            events.append("stop")
            await gate.wait()
            return .stopped(handoffReceipt(runID: handoffRunID))
        },
        evidenceProvider: {
            events.append("evidence")
            return PrecisionRuntimeObserverHostEvidence(
                session: handoffSession(),
                rootGeneration: 17
            )
        }
    )

    let first = Task { try await callHandoff(adapter) }
    await waitForHandoffEvent("stop", in: events)
    let second = Task { try await callHandoff(adapter) }
    first.cancel()
    await gate.open()

    let firstReceipt = try await first.value
    let secondReceipt = try await second.value
    let replayedReceipt = try await callHandoff(adapter)
    #expect(firstReceipt == secondReceipt)
    #expect(secondReceipt == replayedReceipt)
    #expect(events.values == ["stop", "evidence"])
}

@Test func terminalFailureIsStickyAndDoesNotRepeatPhysicalStop() async {
    let runID = UUID()
    let events = LockedHandoffEvents()
    let adapter = makeHandoffAdapter(
        observerRunID: runID,
        stopResult: .timedOut(runID: runID),
        events: events
    )

    await expectHandoffError(.observerStopTimedOut(runID: runID)) {
        try await callHandoff(adapter, observerRunID: runID)
    }
    await expectHandoffError(.observerStopTimedOut(runID: runID)) {
        try await callHandoff(adapter, observerRunID: runID)
    }
    #expect(events.values == ["stop"])
}

@Test func adapterTargetIsProductlessIOKitFreeAndAbsentFromExecutables()
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
    let source = try String(
        contentsOf: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionRuntimeHostHandoff/" +
                "PrecisionRuntimeObserverHostHandoff.swift"
        ),
        encoding: .utf8
    )
    let admissionSource = try String(
        contentsOf: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionRuntimeAdmission/" +
                "PrecisionRuntimeAdmission.swift"
        ),
        encoding: .utf8
    )
    let projectYAML = try String(
        contentsOf: projectRoot.appendingPathComponent("project.yml"),
        encoding: .utf8
    )
    let projectFile = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "MXErgoController.xcodeproj/project.pbxproj"
        ),
        encoding: .utf8
    )

    #expect(manifest.contains("name: \"MXErgoPrecisionRuntimeHostHandoff\""))
    #expect(!manifest.contains(
        ".library(name: \"MXErgoPrecisionRuntimeHostHandoff\""
    ))
    #expect(!admissionSource.components(separatedBy: .newlines).contains(
        "import MXErgoHID"
    ))
    #expect(!admissionSource.contains("MXErgoPrecisionRuntimeHostHandoff"))
    #expect(!projectYAML.contains("MXErgoPrecisionRuntimeHostHandoff"))
    #expect(!projectFile.contains("MXErgoPrecisionRuntimeHostHandoff"))
    #expect(source.contains("restart fence"))
    for forbidden in [
        "import IOKit",
        "IOHID",
        "public ",
        "@main",
        "UserDefaults",
        ": Codable",
        "Process(",
    ] {
        #expect(!source.contains(forbidden))
    }
}

private let handoffLaunchID = UUID(
    uuidString: "11111111-1111-1111-1111-111111111111"
)!
private let handoffRunID = UUID(
    uuidString: "22222222-2222-2222-2222-222222222222"
)!

private func handoffSession(
    connectionEpoch: UInt64 = 41
) -> DeviceTransactionSession {
    DeviceTransactionSession(
        device: JournalDeviceIdentity(
            deviceID: "1133-45085-29-1-2",
            vendorID: 0x046D,
            productID: 0xB01D,
            transport: "Bluetooth Low Energy",
            serialNumber: "HOST-HANDOFF-TEST",
            locationID: 29,
            firmwareIdentity: "host-handoff-test-firmware"
        ),
        featureID: 0x1B04,
        featureVersion: 4,
        featureIndex: 7,
        connectionEpoch: connectionEpoch
    )
}

private func handoffReceipt(
    runID: UUID,
    pendingAtStop: Int = 0,
    finalPending: Int = 0,
    callbackDeliveryQuiesced: Bool = true,
    ownership: MXErgoObserverOwnershipDisposition = .managerClosed
) -> MXErgoObserverHandoffReceipt {
    MXErgoObserverHandoffReceipt(
        runID: runID,
        pendingRequestCountAtStop: pendingAtStop,
        finalPendingRequestCount: finalPending,
        callbackDeliveryQuiesced: callbackDeliveryQuiesced,
        ownershipDisposition: ownership
    )
}

private func makeHandoffAdapter(
    launchID: UUID = handoffLaunchID,
    session: DeviceTransactionSession = handoffSession(),
    rootGeneration: UInt64 = 17,
    observerRunID: UUID = handoffRunID,
    stopResult: MXErgoObserverHandoffWaitResult? = nil,
    events: LockedHandoffEvents? = nil,
    stopOperation: PrecisionRuntimeObserverHostHandoff.StopOperation? = nil,
    evidenceProvider: PrecisionRuntimeObserverHostHandoff.EvidenceProvider? = nil
) -> PrecisionRuntimeObserverHostHandoff {
    let result = stopResult ?? .stopped(handoffReceipt(runID: observerRunID))
    return PrecisionRuntimeObserverHostHandoff(
        launchID: launchID,
        session: session,
        rootGeneration: rootGeneration,
        observerRunID: observerRunID,
        evidenceProvider: evidenceProvider ?? {
            events?.append("evidence")
            return PrecisionRuntimeObserverHostEvidence(
                session: session,
                rootGeneration: rootGeneration
            )
        },
        stopOperation: stopOperation ?? { _ in
            events?.append("stop")
            return result
        }
    )
}

@discardableResult
private func callHandoff(
    _ adapter: PrecisionRuntimeObserverHostHandoff,
    observerRunID: UUID = handoffRunID
) async throws -> PrecisionRuntimeHostHandoffReceipt {
    try await adapter.stopAndWait(
        launchID: handoffLaunchID,
        expectedSession: handoffSession(),
        expectedRootGeneration: 17,
        expectedObserverRunID: observerRunID,
        timeoutNanoseconds: 1_000
    )
}

private func expectHandoffError<T>(
    _ expected: PrecisionRuntimeObserverHostHandoffError,
    operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("Expected handoff error: \(expected)")
    } catch let error as PrecisionRuntimeObserverHostHandoffError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected handoff error: \(error)")
    }
}

private enum HandoffTestError: Error, Sendable {
    case evidence
}

private final class LockedHandoffEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private actor HandoffAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private func waitForHandoffEvent(
    _ event: String,
    in recorder: LockedHandoffEvents
) async {
    for _ in 0..<10_000 {
        if recorder.values.contains(event) { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for handoff event: \(event)")
}


@Test func cachedExternalEvidenceCannotSubstituteForSealedObserverProof() async throws {
    let run = UUID()
    let session = handoffSession()
    let proof = MXErgoObserverPrecisionBinding(
        runID: run,
        properties: HIDDeviceProperties(
            id: session.device.deviceID, vendorID: 0x046D, productID: 0xB01D,
            productName: "MX Ergo", transport: session.device.transport,
            serialNumber: session.device.serialNumber, locationID: 29,
            primaryUsagePage: 1, primaryUsage: 2),
        feature: HIDPP20FeatureDescriptor(index: 7, type: 0, version: 4),
        connectionEpoch: 41
    )
    let events = LockedHandoffEvents()
    let provider: PrecisionRuntimeObserverHostHandoff.EvidenceProvider = {
        events.append("cached evidence")
        return PrecisionRuntimeObserverHostEvidence(session: session, rootGeneration: 17)
    }
    for scenario in 0..<3 {
        await expectHandoffError(.evidenceUnavailable) {
            _ = try await PrecisionRuntimeObserverHostHandoff.validatedExternalEvidence(
                proof: scenario == 0 ? nil : proof,
                expectedRunID: scenario == 1 ? UUID() : run,
                expectedSession: scenario == 2 ? handoffSession(connectionEpoch: 42) : session,
                evidenceProvider: provider
            )
        }
    }
    #expect(events.values.isEmpty)
    let evidence = try await PrecisionRuntimeObserverHostHandoff.validatedExternalEvidence(
        proof: proof, expectedRunID: run, expectedSession: session,
        evidenceProvider: provider
    )
    #expect(evidence.session == session)
    #expect(events.values == ["cached evidence"])
}
