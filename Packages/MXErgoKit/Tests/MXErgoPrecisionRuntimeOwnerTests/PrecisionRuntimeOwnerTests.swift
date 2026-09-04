import Foundation
import MXErgoCore
import MXErgoHIDPP
import Testing
@testable import MXErgoHID
@testable import MXErgoPrecisionRuntimeAdmission
@testable import MXErgoPrecisionRuntimeComposition
@testable import MXErgoPrecisionRuntimeHostHandoff
@testable import MXErgoPrecisionRuntimeLifecycle
@testable import MXErgoPrecisionRuntimeOwner

@Test func bindWithoutARunningObserverFailsClosed() {
    let observer = MXErgoObserver()
    #expect(throws: PrecisionRuntimeOwnerError.observerNotRunning) {
        _ = try PrecisionRuntimeOwner.bind(
            observer: observer,
            launchID: UUID(),
            readiness: ownerReadiness(),
            session: ownerSession(),
            rootGeneration: 1,
            sourceBaselineURL: URL(fileURLWithPath: "/tmp/owner-source.json"),
            runtimeJournalURL: URL(fileURLWithPath: "/tmp/owner-runtime.json"),
            evidenceProvider: {
                PrecisionRuntimeOwnerEvidence(
                    session: ownerSession(),
                    rootGeneration: 1
                )
            }
        )
    }
}

@Test func quitKeepsTheRestartFenceAndRolloverReleasesIt() async throws {
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    let fenceID = try #require(
        coordinator.installRestartFence(capturedRunID: runID)
    )
    let events = LockedOwnerEvents()
    let lifecycle = PrecisionRuntimeLifecycle(
        intent: ownerLifecycleIntent(observerRunID: runID),
        fence: MXErgoObserverRestartFence(
            fenceID: fenceID,
            capturedRunID: runID,
            observerID: UUID()
        ),
        hostHandoff: OwnerStubHandoff(events: events),
        releaseFence: { token in
            events.append("release")
            return coordinator.releaseRestartFence(fenceID: token.fenceID)
        }
    )
    let owner = PrecisionRuntimeOwner(
        launchID: UUID(),
        observerRunID: runID,
        intent: ownerLifecycleIntent(observerRunID: runID),
        lifecycle: lifecycle
    )

    #expect(await owner.phase == .bound)
    #expect(await owner.blocksObserverRestart)
    await owner.prepareForQuit()
    #expect(await owner.phase == .bound)
    #expect(events.values.isEmpty)
    #expect(coordinator.beginStop(runID: runID))
    #expect(coordinator.performTeardown(
        runID: runID,
        managerWasAcquired: true,
        calls: noOpOwnerTeardownCalls()
    ) != nil)
    #expect(coordinator.beginRun() == nil)

    try await owner.completeSessionRollover()
    #expect(await owner.phase == .released)
    #expect(await owner.blocksObserverRestart == false)
    #expect(events.values == ["release"])
    #expect(coordinator.beginRun() != nil)
}

@Test func rolloverIsRejectedWhileTheRuntimeStillOwnsTheDevice() async throws {
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    let fenceID = try #require(
        coordinator.installRestartFence(capturedRunID: runID)
    )
    let events = LockedOwnerEvents()
    let lifecycle = PrecisionRuntimeLifecycle(
        intent: ownerLifecycleIntent(observerRunID: runID),
        fence: MXErgoObserverRestartFence(
            fenceID: fenceID,
            capturedRunID: runID,
            observerID: UUID()
        ),
        hostHandoff: OwnerStubHandoff(events: events),
        releaseFence: { token in
            events.append("release")
            return coordinator.releaseRestartFence(fenceID: token.fenceID)
        }
    )
    try await lifecycle.admit(
        authorization: ownerAuthorization(),
        competitorProbe: { [] },
        sessionProvider: { ownerSession() },
        rootGenerationProvider: { 1 },
        admit: { _ in OwnerFakeSession(events: events) }
    )
    let owner = PrecisionRuntimeOwner(
        launchID: UUID(),
        observerRunID: runID,
        intent: ownerLifecycleIntent(observerRunID: runID),
        lifecycle: lifecycle
    )

    #expect(await owner.phase == .admitted)
    await #expect(throws: PrecisionRuntimeOwnerError.stillOwningRuntime) {
        try await owner.completeSessionRollover()
    }
    #expect(events.values == ["admit"])
    await owner.prepareForQuit()
    #expect(await owner.phase == .shutDown)
    #expect(events.values == ["admit", "shutdown"])
    try await owner.completeSessionRollover()
    #expect(events.values == ["admit", "shutdown", "release"])
}

@Test func recoverBoundOwnerRejectsAdmitAndRequiresExplicitRecoveryConfirmation()
    async throws
{
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    let fenceID = try #require(
        coordinator.installRestartFence(capturedRunID: runID)
    )
    let intent = ownerLifecycleIntent(observerRunID: runID, operation: .recover)
    let events = LockedOwnerEvents()
    let owner = PrecisionRuntimeOwner(
        launchID: intent.launchID,
        observerRunID: runID,
        intent: intent,
        lifecycle: PrecisionRuntimeLifecycle(
            intent: intent,
            fence: MXErgoObserverRestartFence(
                fenceID: fenceID,
                capturedRunID: runID,
                observerID: UUID()
            ),
            hostHandoff: OwnerStubHandoff(events: events),
            releaseFence: { token in
                coordinator.releaseRestartFence(fenceID: token.fenceID)
            }
        )
    )

    #expect(await owner.boundOperation == .recover)
    await #expect(throws: PrecisionRuntimeOwnerError.invalidIntent) {
        try await owner.confirmAdmission(
            explicitlyConfirmed: true,
            competitorProbe: { [] },
            sessionProvider: { ownerSession() },
            rootGenerationProvider: { 1 }
        )
    }
    await #expect(throws: PrecisionRuntimeOwnerError.explicitConfirmationRequired) {
        try await owner.confirmRecovery(
            explicitlyConfirmed: false,
            competitorProbe: { [] },
            sessionProvider: { ownerSession() },
            rootGenerationProvider: { 1 }
        )
    }
    #expect(events.values.isEmpty)
    #expect(await owner.phase == .bound)
}

@Test func activateBoundOwnerRejectsRecoverConfirmation() async throws {
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    let fenceID = try #require(
        coordinator.installRestartFence(capturedRunID: runID)
    )
    let intent = ownerLifecycleIntent(observerRunID: runID)
    let owner = PrecisionRuntimeOwner(
        launchID: intent.launchID,
        observerRunID: runID,
        intent: intent,
        lifecycle: PrecisionRuntimeLifecycle(
            intent: intent,
            fence: MXErgoObserverRestartFence(
                fenceID: fenceID,
                capturedRunID: runID,
                observerID: UUID()
            ),
            hostHandoff: OwnerStubHandoff(events: nil),
            releaseFence: { _ in true }
        )
    )

    #expect(await owner.boundOperation == .activate)
    await #expect(throws: PrecisionRuntimeOwnerError.invalidIntent) {
        try await owner.confirmRecovery(
            explicitlyConfirmed: true,
            competitorProbe: { [] },
            sessionProvider: { ownerSession() },
            rootGenerationProvider: { 1 }
        )
    }
}

@Test func recoverStaysLockedAfterAnAmbiguousRestoreSET() async throws {
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    let fenceID = try #require(
        coordinator.installRestartFence(capturedRunID: runID)
    )
    let intent = ownerLifecycleIntent(observerRunID: runID, operation: .recover)
    let owner = PrecisionRuntimeOwner(
        launchID: intent.launchID,
        observerRunID: runID,
        intent: intent,
        lifecycle: PrecisionRuntimeLifecycle(
            intent: intent,
            fence: MXErgoObserverRestartFence(
                fenceID: fenceID,
                capturedRunID: runID,
                observerID: UUID()
            ),
            hostHandoff: OwnerStubHandoff(events: nil),
            releaseFence: { _ in true }
        )
    )
    await owner.lockRecoverAfterAmbiguousSET()
    #expect(await owner.isRecoverLockedAfterAmbiguousSET)
    await #expect(throws: PrecisionRuntimeOwnerError.recoverLockedAfterAmbiguousSET) {
        try await owner.confirmRecovery(
            explicitlyConfirmed: true,
            competitorProbe: { [] },
            sessionProvider: { ownerSession() },
            rootGenerationProvider: { 1 }
        )
    }
}

@Test func confirmAdmissionRequiresExplicitConfirmationAndRejectsExpiry()
    async throws
{
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    let fenceID = try #require(
        coordinator.installRestartFence(capturedRunID: runID)
    )
    let intent = ownerLifecycleIntent(observerRunID: runID, deadline: 10)
    let events = LockedOwnerEvents()
    let owner = PrecisionRuntimeOwner(
        launchID: intent.launchID,
        observerRunID: runID,
        intent: intent,
        lifecycle: PrecisionRuntimeLifecycle(
            intent: intent,
            fence: MXErgoObserverRestartFence(
                fenceID: fenceID,
                capturedRunID: runID,
                observerID: UUID()
            ),
            hostHandoff: OwnerStubHandoff(events: events),
            releaseFence: { token in
                coordinator.releaseRestartFence(fenceID: token.fenceID)
            }
        )
    )

    await #expect(throws: PrecisionRuntimeOwnerError.explicitConfirmationRequired) {
        try await owner.confirmAdmission(
            explicitlyConfirmed: false,
            competitorProbe: { [] },
            sessionProvider: { ownerSession() },
            rootGenerationProvider: { 1 }
        )
    }
    #expect(events.values.isEmpty)
    #expect(await owner.phase == .bound)

    await #expect(throws: PrecisionRuntimeOwnerError.authorizationExpired) {
        try await owner.confirmAdmission(
            explicitlyConfirmed: true,
            competitorProbe: { [] },
            sessionProvider: { ownerSession() },
            rootGenerationProvider: { 1 },
            nowUptimeNanoseconds: 11
        )
    }
    #expect(events.values.isEmpty)
}

@Test func confirmAdmissionIsRejectedOnceTheRuntimeAlreadyOwnsTheDevice()
    async throws
{
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    let fenceID = try #require(
        coordinator.installRestartFence(capturedRunID: runID)
    )
    let events = LockedOwnerEvents()
    let lifecycle = PrecisionRuntimeLifecycle(
        intent: ownerLifecycleIntent(observerRunID: runID),
        fence: MXErgoObserverRestartFence(
            fenceID: fenceID,
            capturedRunID: runID,
            observerID: UUID()
        ),
        hostHandoff: OwnerStubHandoff(events: events),
        releaseFence: { token in
            coordinator.releaseRestartFence(fenceID: token.fenceID)
        }
    )
    try await lifecycle.admit(
        authorization: ownerAuthorization(),
        competitorProbe: { [] },
        sessionProvider: { ownerSession() },
        rootGenerationProvider: { 1 },
        admit: { _ in OwnerFakeSession(events: events) }
    )
    let owner = PrecisionRuntimeOwner(
        launchID: UUID(),
        observerRunID: runID,
        intent: ownerLifecycleIntent(observerRunID: runID),
        lifecycle: lifecycle
    )

    await #expect(throws: PrecisionRuntimeOwnerError.alreadyAdmitted) {
        try await owner.confirmAdmission(
            explicitlyConfirmed: true,
            competitorProbe: { [] },
            sessionProvider: { ownerSession() },
            rootGenerationProvider: { 1 }
        )
    }
}

@Test func ownerResolvesPrecisionTapMuteAndIgnoresOtherCIDs() async throws {
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    let fenceID = try #require(
        coordinator.installRestartFence(capturedRunID: runID)
    )
    let intent = ownerLifecycleIntent(observerRunID: runID)
    let owner = PrecisionRuntimeOwner(
        launchID: intent.launchID,
        observerRunID: runID,
        intent: intent,
        lifecycle: PrecisionRuntimeLifecycle(
            intent: intent,
            fence: MXErgoObserverRestartFence(
                fenceID: fenceID,
                capturedRunID: runID,
                observerID: UUID()
            ),
            hostHandoff: OwnerStubHandoff(events: nil),
            releaseFence: { _ in true }
        )
    )
    let recorder = LockedOwnerIntents()
    await owner.setControlEventHandler { intent in
        recorder.append(intent)
    }

    let otherCID: [UInt8] = [
        0x11, 0xFF, 0x0A, 0x00, 0x00, 0x56,
    ] + Array(repeating: 0, count: 14)
    let press: [UInt8] = [
        0x11, 0xFF, 0x0A, 0x00, 0x00, 0xED,
    ] + Array(repeating: 0, count: 14)
    let release: [UInt8] = [
        0x11, 0xFF, 0x0A, 0x00, 0x00, 0x00,
    ] + Array(repeating: 0, count: 14)

    await owner.deliverUnsolicitedHIDPP(otherCID)
    await owner.deliverUnsolicitedHIDPP(press)
    await owner.deliverUnsolicitedHIDPP(release)
    #expect(recorder.values == [.toggleMute])
}

@Test func ownerConvertsPrecisionHeldWheelNotchesIntoVolume() async throws {
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    let fenceID = try #require(
        coordinator.installRestartFence(capturedRunID: runID)
    )
    let intent = ownerLifecycleIntent(observerRunID: runID)
    let owner = PrecisionRuntimeOwner(
        launchID: intent.launchID,
        observerRunID: runID,
        intent: intent,
        lifecycle: PrecisionRuntimeLifecycle(
            intent: intent,
            fence: MXErgoObserverRestartFence(
                fenceID: fenceID,
                capturedRunID: runID,
                observerID: UUID()
            ),
            hostHandoff: OwnerStubHandoff(events: nil),
            releaseFence: { _ in true }
        )
    )
    let recorder = LockedOwnerIntents()
    await owner.setControlEventHandler { intent in
        recorder.append(intent)
    }
    let press: [UInt8] = [
        0x11, 0xFF, 0x0A, 0x00, 0x00, 0xED,
    ] + Array(repeating: 0, count: 14)
    await owner.noteVerticalScroll(notches: 1, at: 1)
    #expect(recorder.values.isEmpty)
    #expect(!owner.precisionHeld.isHeld)
    await owner.deliverUnsolicitedHIDPP(press)
    #expect(owner.precisionHeld.isHeld)
    await owner.noteVerticalScroll(notches: 1, at: 10.1)
    #expect(recorder.values == [.volumeUp(steps: 2)])
}

@Test func disconnectWhileAdmittedShutsDownWithoutSETAllowsRolloverAndDropsEvents()
    async throws
{
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    let fenceID = try #require(
        coordinator.installRestartFence(capturedRunID: runID)
    )
    let events = LockedOwnerEvents()
    let lifecycle = PrecisionRuntimeLifecycle(
        intent: ownerLifecycleIntent(observerRunID: runID),
        fence: MXErgoObserverRestartFence(
            fenceID: fenceID,
            capturedRunID: runID,
            observerID: UUID()
        ),
        hostHandoff: OwnerStubHandoff(events: events),
        releaseFence: { token in
            events.append("release")
            return coordinator.releaseRestartFence(fenceID: token.fenceID)
        }
    )
    try await lifecycle.admit(
        authorization: ownerAuthorization(),
        competitorProbe: { [] },
        sessionProvider: { ownerSession() },
        rootGenerationProvider: { 1 },
        admit: { _ in OwnerFakeSession(events: events) }
    )
    let owner = PrecisionRuntimeOwner(
        launchID: UUID(),
        observerRunID: runID,
        intent: ownerLifecycleIntent(observerRunID: runID),
        lifecycle: lifecycle
    )
    let recorder = LockedOwnerIntents()
    await owner.setControlEventHandler { intent in
        recorder.append(intent)
    }
    let statuses = LockedOwnerStatuses()
    await owner.setDiversionStatusHandler { status in
        statuses.append(status)
    }

    let press: [UInt8] = [
        0x11, 0xFF, 0x0A, 0x00, 0x00, 0xED,
    ] + Array(repeating: 0, count: 14)
    await owner.deliverUnsolicitedHIDPP(press)
    #expect(owner.precisionHeld.isHeld)

    await owner.handleDeviceDisconnected()
    #expect(await owner.phase == .shutDown)
    #expect(await owner.diversionStatus == .recoveryRequired)
    #expect(await owner.deviceWasDisconnected)
    #expect(!owner.precisionHeld.isHeld)
    #expect(events.values == ["admit", "shutdown"])

    await owner.noteVerticalScroll(notches: 1, at: 20)
    await owner.deliverUnsolicitedHIDPP(press)
    #expect(recorder.values.isEmpty)

    await #expect(throws: PrecisionRuntimeOwnerError.notAdmitted) {
        try await owner.confirmDeactivation(explicitlyConfirmed: true)
    }

    try await owner.completeSessionRollover()
    #expect(await owner.phase == .released)
    #expect(await owner.blocksObserverRestart == false)
    #expect(events.values == ["admit", "shutdown", "release"])
    #expect(statuses.values.contains(.recoveryRequired))
}

@Test func ownerProductIsTheOnlyExecutableSurfaceAndDoesNotAdmit() throws {
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
    #expect(manifest.contains(
        "name: \"MXErgoPrecisionRuntimeOwner\",\n            targets: [\"MXErgoPrecisionRuntimeOwner\"]"
    ))
    #expect(!manifest.contains(
        ".library(name: \"MXErgoPrecisionRuntimeLifecycle\""
    ))
    #expect(!manifest.contains(
        ".library(\n            name: \"MXErgoPrecisionRuntimeLifecycle\""
    ))
    #expect(!manifest.contains(
        ".library(name: \"MXErgoPrecisionRuntimeAdmission\""
    ))
    #expect(!manifest.contains(
        ".library(name: \"MXErgoPrecisionRuntimeHostHandoff\""
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
    #expect(projectYAML.contains("MXErgoPrecisionRuntimeOwner"))
    #expect(projectFile.contains("MXErgoPrecisionRuntimeOwner"))
    #expect(!projectYAML.contains("MXErgoPrecisionRuntimeLifecycle"))
    #expect(!projectFile.contains("MXErgoPrecisionRuntimeLifecycle"))
    #expect(!projectYAML.contains("MXErgoPrecisionRuntimeAdmission"))
    #expect(!projectFile.contains("MXErgoPrecisionRuntimeAdmission"))

    let source = try String(
        contentsOf: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionRuntimeOwner/PrecisionRuntimeOwner.swift"
        ),
        encoding: .utf8
    )
    for required in [
        "public static func bind(",
        "confirmAdmission(",
        "confirmRecovery(",
        "confirmDeactivation(",
        "explicitlyConfirmed",
        "prepareForQuit()",
        "completeSessionRollover()",
        "notAuthorizedForExecution",
        "PrecisionRuntimeLifecycle.bind(",
        "lifecycle.admit(",
        "setControlEventHandler(",
        "unsolicitedHIDPPHandler",
        "deviceDisconnectHandler",
        "handleDeviceDisconnected()",
        "PrecisionRuntimeOwnerDiversionStatus",
        "recoverLockedAfterAmbiguousSET",
    ] {
        #expect(source.contains(required))
    }
    for forbidden in [
        "func admit(",
        "import IOKit",
        "IOHIDDeviceSetReport",
        "@main",
        "UserDefaults",
        ": Codable",
        "Process(",
    ] {
        #expect(!source.contains(forbidden))
    }

    let appRoot = projectRoot.appendingPathComponent("App")
    let appSources = try FileManager.default.contentsOfDirectory(
        at: appRoot,
        includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "swift" }
    let appText = try appSources.map {
        try String(contentsOf: $0, encoding: .utf8)
    }.joined(separator: "\n")
    for forbidden in [
        "PrecisionRuntimeAdmissionFactory",
        "IOHIDDeviceSetReport",
        "recoverExplicitly()",
    ] {
        #expect(!appText.contains(forbidden))
    }
    #expect(appText.contains("PrecisionRuntimeOwner"))
    #expect(appText.contains("prepareForQuit"))
    #expect(appText.contains("completeSessionRollover"))
    #expect(appText.contains("confirmAdmission"))
    #expect(appText.contains("confirmRecovery"))
    #expect(appText.contains("confirmDeactivation"))
    #expect(appText.contains("setControlEventHandler"))
    #expect(appText.contains("MXErgoWheelObserver"))
    #expect(appText.contains("noteVerticalScroll"))
    #expect(appText.contains("setDiversionStatusHandler"))
    #expect(appText.contains("recoveryRequired"))

    // Regression guard, 2026-09-04. The diverted status line was derived from
    // whether the runtime was admitted, so a control that had been restored and
    // verified back to its baseline still reported as diverted. The runtime
    // stays admitted across a restore; only the diversion status distinguishes
    // the two, so the label must be gated on that flag.
    let divertedLabel = "\"Status: Precision diverted (active)\""
    #expect(appText.contains(divertedLabel))
    let beforeLabel = try #require(
        appText.components(separatedBy: divertedLabel).first
    )
    let guardingCondition = try #require(
        beforeLabel.components(separatedBy: "if model.runtimeOwner").last
    )
    #expect(guardingCondition.hasPrefix("ControlIsDiverted"))

    // An expired one-use authorization is permanently dead, because its
    // deadline is minted at bind time. The controls it can never satisfy must
    // not stay enabled.
    #expect(appText.contains("runtimeOwnerAuthorizationExpired"))
}

private func ownerSession() -> DeviceTransactionSession {
    DeviceTransactionSession(
        device: JournalDeviceIdentity(
            deviceID: "1133-45085-29-1-2",
            vendorID: 0x046D,
            productID: 0xB01D,
            transport: "Bluetooth Low Energy",
            serialNumber: "OWNER-TEST",
            locationID: 29,
            firmwareIdentity: "owner-test-firmware"
        ),
        featureID: ReprogControlsV4.featureID,
        featureVersion: 3,
        featureIndex: 0x0A,
        connectionEpoch: 1
    )
}

private func ownerCanonicalURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/tmp/\(name)")
        .standardizedFileURL
        .resolvingSymlinksInPath()
}

private func ownerReadiness() -> PrecisionTemporaryDiversionReadinessSnapshot {
    let session = ownerSession()
    let device = session.device
    do {
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
                rawParameters: ownerPadded([0x00, 0xED])
            ),
            baselineReporting: ReprogControlReportingState(
                controlID: 0x00ED,
                rawFlags: 0,
                rawMappedControlID: 0,
                rawParameters: ownerPadded([0x00, 0xED, 0, 0, 0])
            )
        )
        let journal = try DeviceStateJournal(
            transactionID: UUID(),
            appBuild: "owner-test",
            device: device,
            feature: HIDPP20FeatureDescriptor(
                index: 0x0A,
                type: 0,
                version: 3,
                rawParameters: ownerPadded([0x0A, 0, 3])
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
        return PrecisionTemporaryDiversionReadinessSnapshot(
            plan: plan,
            sourceJournalSHA256: String(repeating: "a", count: 64),
            sourceBaselineTransactionID: journal.transactionID,
            connectionGeneration: 1,
            connectionEpoch: session.connectionEpoch,
            authorization: .notAuthorizedForExecution
        )
    } catch {
        fatalError("owner readiness fixture failed: \(error)")
    }
}

private func ownerLifecycleIntent(
    observerRunID: UUID,
    deadline: UInt64 = 1_000,
    operation: PrecisionTemporaryDiversionOperation = .activate
) -> PrecisionRuntimeAdmissionIntent {
    let session = ownerSession()
    let sourceURL = ownerCanonicalURL("owner-source.json")
    let runtimeURL = ownerCanonicalURL("owner-runtime.json")
    return PrecisionRuntimeAdmissionIntent(
        launchID: UUID(
            uuidString: "11111111-1111-1111-1111-111111111111"
        )!,
        observerRunID: observerRunID,
        operation: operation,
        readiness: ownerReadiness(),
        session: session,
        rootGeneration: 1,
        sourceBaselineURL: sourceURL,
        runtimeJournalURL: runtimeURL,
        sourceBaselineCanonicalPath: sourceURL.path,
        runtimeJournalCanonicalPath: runtimeURL.path,
        expectedRuntimeSnapshot: nil,
        expiresAtUptimeNanoseconds: deadline
    )
}

private func ownerAuthorization() -> PrecisionRuntimeAdmissionAuthorization {
    let intent = ownerLifecycleIntent(observerRunID: UUID())
    return try! PrecisionRuntimeAdmissionAuthorizationFactory.issue(
        for: intent,
        explicitlyConfirmed: true,
        nowUptimeNanoseconds: 0
    )
}

private func ownerPadded(_ bytes: [UInt8]) -> [UInt8] {
    bytes + Array(repeating: 0, count: max(0, 16 - bytes.count))
}

private func noOpOwnerTeardownCalls() -> MXErgoObserverTeardownCalls {
    MXErgoObserverTeardownCalls(
        clearRequestState: {},
        unscheduleManager: {},
        closeManager: { 0 },
        didQuiesceCallbacks: {}
    )
}

private struct OwnerStubHandoff: PrecisionRuntimeHostHandoff {
    let events: LockedOwnerEvents?

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

private actor OwnerFakeSession: PrecisionRuntimeLifecycleSession {
    private let events: LockedOwnerEvents

    init(events: LockedOwnerEvents) {
        self.events = events
        events.append("admit")
    }

    var state: PrecisionRuntimeAdmissionState { .active }

    func reviewIntent(
        for operation: PrecisionTemporaryDiversionOperation,
        expiresAtUptimeNanoseconds: UInt64
    ) async throws -> PrecisionRuntimeAdmissionIntent {
        _ = operation
        _ = expiresAtUptimeNanoseconds
        throw PrecisionRuntimeOwnerError.invalidIntent
    }

    func perform(
        _ intent: PrecisionRuntimeAdmissionIntent,
        authorization: PrecisionRuntimeAdmissionAuthorization
    ) async throws {
        _ = intent
        _ = authorization
        throw PrecisionRuntimeOwnerError.invalidIntent
    }

    func shutdown() async -> PrecisionRuntimeShutdownReport {
        events.append("shutdown")
        return PrecisionRuntimeShutdownReport(
            disposition: .stateUnavailable("test"),
            deviceCloseReturn: 0
        )
    }
}

private final class LockedOwnerStatuses: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PrecisionRuntimeOwnerDiversionStatus] = []

    var values: [PrecisionRuntimeOwnerDiversionStatus] {
        lock.withLock { storage }
    }

    func append(_ value: PrecisionRuntimeOwnerDiversionStatus) {
        lock.withLock { storage.append(value) }
    }
}

private final class LockedOwnerIntents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ControllerIntent] = []

    var values: [ControllerIntent] { lock.withLock { storage } }

    func append(_ value: ControllerIntent) {
        lock.withLock { storage.append(value) }
    }
}

private final class LockedOwnerEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}
