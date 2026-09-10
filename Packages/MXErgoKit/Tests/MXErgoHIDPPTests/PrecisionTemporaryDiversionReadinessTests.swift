import Foundation
import Testing
@testable import MXErgoHIDPP

@Test func precisionCompetitorClassifierIsDeterministicAndExcludesOnlySelf() {
    let snapshots = [
        readinessProcess(70, "com.logitech.ghub", "Logitech G HUB"),
        readinessProcess(42, "com.phib.MXErgoController", "MX Ergo Controller"),
        readinessProcess(11, "com.hegenberg.BetterTouchTool", "BetterTouchTool"),
        readinessProcess(11, "com.hegenberg.BetterTouchTool.helper", "BTT Helper"),
        readinessProcess(19, "com.logi.optionsplus.agent", "Logi Options+ Agent"),
        readinessProcess(23, "com.phib.MXErgoRestoreTrialProbe", "Restore Probe"),
    ]

    let result = PrecisionCompetingProcessClassifier.competitors(
        in: snapshots.reversed(),
        excludingProcessIdentifier: 42
    )

    #expect(result.map(\.processIdentifier) == [11, 19, 23])
    #expect(result.map(\.displayName) == [
        "BetterTouchTool", "Logi Options+ Agent", "Restore Probe",
    ])
    #expect(!result.contains { $0.processIdentifier == 70 })
}

@Test func precisionCompetitorClassifierRecognizesHelpersWithoutGenericLogitechFalsePositives() {
    let result = PrecisionCompetingProcessClassifier.competitors(
        in: [
            readinessProcess(1, nil, "BTT Helper"),
            readinessProcess(2, "com.logitech.options.daemon", nil),
            readinessProcess(3, nil, "Logitech Options Helper"),
            readinessProcess(4, "com.logitech.gaming", "Logitech Gaming Software"),
            readinessProcess(5, "com.example.mxergonomics", "MX Ergonomics Notes"),
        ],
        excludingProcessIdentifier: 999
    )

    #expect(result.map(\.processIdentifier) == [1, 2, 3])
}

@Test func precisionCompetitorScannerFailsClosedWhenItsProviderFails() {
    enum ProviderFailure: Error { case unavailable }
    let scanner = PrecisionCompetingProcessScanner {
        throw ProviderFailure.unavailable
    }

    #expect(throws: ProviderFailure.self) {
        _ = try scanner.scan(excludingProcessIdentifier: 42)
    }
}

private let systemThemeHelperBundle = "com.apple.appkit.xpc.ThemeWidgetControlViewService"
private let systemThemeHelperPath = "/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/ThemeWidgetControlViewService.xpc/Contents/MacOS/ThemeWidgetControlViewService"

@Test func precisionCompetitorClassifierIgnoresOnlyTheIdentifiedSystemThemeHelper() {
    let snapshots = ["MX Ergo Controller", "BetterTouchTool", "Logi Options+"].enumerated().map { index, host in
        readinessProcess(Int32(index + 1), systemThemeHelperBundle,
            "ThemeWidgetControlViewService (\(host))", executablePath: systemThemeHelperPath)
    }
    #expect(PrecisionCompetingProcessClassifier.competitors(
        in: snapshots, excludingProcessIdentifier: 999).isEmpty)
}

@Test func precisionCompetitorClassifierDoesNotTrustThemeHelperNamesOrPartialIdentity() {
    let identities: [(String?, String?)] = [
        (systemThemeHelperBundle, nil),
        (nil, systemThemeHelperPath),
        (nil, nil),
        (systemThemeHelperBundle, "/tmp/ThemeWidgetControlViewService"),
        (systemThemeHelperBundle, "/Applications/ThemeWidgetControlViewService.app/Contents/MacOS/ThemeWidgetControlViewService"),
        (systemThemeHelperBundle, systemThemeHelperPath + "-copy"),
        (systemThemeHelperBundle, "/System/Library/Other/ThemeWidgetControlViewService"),
        (systemThemeHelperBundle, systemThemeHelperPath.replacingOccurrences(of: "/Versions/C/", with: "/Versions/Current/")),
        (systemThemeHelperBundle.uppercased(), systemThemeHelperPath),
        (systemThemeHelperBundle + ".copy", systemThemeHelperPath),
        ("com.phib.MXErgoController", systemThemeHelperPath),
    ]
    for (bundle, path) in identities {
        let result = PrecisionCompetingProcessClassifier.competitors(
            in: [readinessProcess(7, bundle, "ThemeWidgetControlViewService (MX Ergo Controller)", executablePath: path)],
            excludingProcessIdentifier: 999)
        #expect(result.map(\.processIdentifier) == [7])
    }
}

@Test func precisionCompetitorClassifierKeepsRealCompetitorsBesideSystemHelpers() {
    let snapshots = [
        readinessProcess(42, "com.phib.MXErgoController", "MX Ergo Controller"),
        readinessProcess(43, "com.phib.MXErgoController", "MX Ergo Controller", executablePath: "/Applications/Other Controller.app/Contents/MacOS/MX Ergo Controller"),
        readinessProcess(44, systemThemeHelperBundle, "ThemeWidgetControlViewService (MX Ergo Controller)", executablePath: systemThemeHelperPath),
        readinessProcess(45, "com.hegenberg.BetterTouchTool", "BetterTouchTool"),
        readinessProcess(46, "com.logi.optionsplus.agent", "Logi Options+ Agent"),
        readinessProcess(47, "com.phib.MXErgoRestoreTrialProbe", "Restore Probe"),
    ]
    let result = PrecisionCompetingProcessClassifier.competitors(in: snapshots, excludingProcessIdentifier: 42)
    #expect(Set(result.map(\.processIdentifier)) == [43, 45, 46, 47])
}

@Test func precisionCompetitorClassifierRetainsConflictingDuplicateHelperEvidence() {
    let trusted = readinessProcess(7, systemThemeHelperBundle, "ThemeWidgetControlViewService (MX Ergo Controller)", executablePath: systemThemeHelperPath)
    let conflicting = readinessProcess(7, systemThemeHelperBundle, "ThemeWidgetControlViewService (MX Ergo Controller)", executablePath: "/tmp/copied-helper")
    for snapshots in [[trusted, conflicting], [conflicting, trusted]] {
        #expect(PrecisionCompetingProcessClassifier.competitors(in: snapshots,
            excludingProcessIdentifier: 999).map(\.processIdentifier) == [7])
    }
}

@Test func precisionReadinessBuildsAnImmutableNonAuthorizationWithoutFileIO() throws {
    let journal = try readinessJournal()
    let data = try readinessEncoded(journal)
    let untouched = data
    let absentTransactionURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("precision-transaction-v3.json")

    let snapshot = try PrecisionTemporaryDiversionReadinessAudit.evaluate(
        readinessInput(sourceData: data, reloadedData: data)
    )

    #expect(snapshot.authorization == .notAuthorizedForExecution)
    #expect(snapshot.plan.baseline == readinessBaseline())
    #expect(snapshot.plan.activeState.rawFlags(featureVersion: 3) == 0x01)
    #expect(snapshot.plan.applySetRequest.bytes[6] == 0x03)
    #expect(snapshot.plan.restoreSetRequest.bytes[6] == 0x02)
    #expect(snapshot.sourceBaselineTransactionID == journal.transactionID)
    #expect(snapshot.sourceJournalSHA256.count == 64)
    #expect(data == untouched)
    #expect(!FileManager.default.fileExists(atPath: absentTransactionURL.path))
}

@Test func precisionReadinessRejectsJournalChangeAndLateCompetitor() throws {
    let data = try readinessEncoded(readinessJournal())
    let changed = data + [0x20]

    #expect(throws: PrecisionTemporaryDiversionReadinessError
        .journalChangedDuringReview) {
        _ = try PrecisionTemporaryDiversionReadinessAudit.evaluate(
            readinessInput(sourceData: data, reloadedData: changed)
        )
    }

    let btt = PrecisionCompetingProcess(
        processIdentifier: 77,
        bundleIdentifier: "com.hegenberg.BetterTouchTool",
        localizedName: "BetterTouchTool"
    )
    #expect(throws: PrecisionTemporaryDiversionReadinessError
        .competingProcesses([btt])) {
        _ = try PrecisionTemporaryDiversionReadinessAudit.evaluate(
            readinessInput(
                sourceData: data,
                reloadedData: data,
                competitorsAfter: [btt]
            )
        )
    }
}

@Test func precisionReadinessRejectsEveryStaleGenerationAndSessionDrift() throws {
    let data = try readinessEncoded(readinessJournal())
    let staleGenerationInputs = [
        readinessInput(sourceData: data, reloadedData: data, rootGeneration: 8),
        readinessInput(sourceData: data, reloadedData: data, firmwareGeneration: 8),
        readinessInput(sourceData: data, reloadedData: data, preflightGeneration: 8),
    ]
    for input in staleGenerationInputs {
        #expect(throws: PrecisionTemporaryDiversionReadinessError
            .staleConnectionEvidence) {
            _ = try PrecisionTemporaryDiversionReadinessAudit.evaluate(input)
        }
    }

    let changedEpoch = readinessSession(connectionEpoch: 44)
    #expect(throws: PrecisionTemporaryDiversionReadinessError.sessionMismatch) {
        _ = try PrecisionTemporaryDiversionReadinessAudit.evaluate(
            readinessInput(
                sourceData: data,
                reloadedData: data,
                preflightSession: changedEpoch
            )
        )
    }
}

@Test func precisionReadinessRejectsFeatureAndPreflightDrift() throws {
    let data = try readinessEncoded(readinessJournal())
    let changedFeature = HIDPP20FeatureDescriptor(
        index: 0x0B,
        type: 0,
        version: 3,
        rawParameters: readinessPadded([0x0B, 0x00, 0x03])
    )
    #expect(throws: PrecisionTemporaryDiversionReadinessError.featureMismatch) {
        _ = try PrecisionTemporaryDiversionReadinessAudit.evaluate(
            readinessInput(
                sourceData: data,
                reloadedData: data,
                currentFeature: changedFeature
            )
        )
    }

    let drift = try readinessBaseline().replacingRawFlags(0x01, featureVersion: 3)
    #expect(throws: PrecisionTemporaryDiversionReadinessError
        .precisionPreflightMismatch) {
        _ = try PrecisionTemporaryDiversionReadinessAudit.evaluate(
            readinessInput(
                sourceData: data,
                reloadedData: data,
                preflightState: drift
            )
        )
    }
}

@Test func precisionReadinessRejectsDirtyBaselineJournal() throws {
    var journal = try readinessJournal()
    let active = ReprogControlReportingState(
        controlID: 0x00ED,
        rawFlags: 0x01,
        rawMappedControlID: 0,
        rawParameters: readinessPadded([0x00, 0xED, 0x01, 0x00, 0x00])
    )
    try journal.transitionControl(
        0x00ED,
        to: .applyMayHaveOccurred,
        intendedReporting: active
    )
    let data = try readinessEncoded(journal)

    #expect(throws: PrecisionTemporaryDiversionReadinessError
        .journalRequiresRecovery) {
        _ = try PrecisionTemporaryDiversionReadinessAudit.evaluate(
            readinessInput(sourceData: data, reloadedData: data)
        )
    }
}

@Test func reconnectRecoveryReadinessAllowsDivertedLiveStateAndNewEpoch() throws {
    let journal = try readinessJournal()
    let data = try readinessEncoded(journal)
    var envelope = try DeviceTransactionEnvelope(baselineJournal: journal)
    let plan = try PrecisionTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: readinessFeature(),
        deviceIndex: 0,
        softwareID: 0x0E
    )
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
    let runtimeData = try JSONEncoder().encode(envelope)
    let newEpoch = readinessSession(connectionEpoch: 99)
    let snapshot = try PrecisionTemporaryDiversionReadinessAudit
        .evaluateReconnectRecovery(
            readinessInput(
                sourceData: data,
                reloadedData: data,
                currentSession: newEpoch,
                preflightSession: newEpoch,
                preflightState: plan.activeState
            ),
            runtimeJournalData: runtimeData,
            reloadedRuntimeJournalData: runtimeData
        )
    #expect(snapshot.authorization == .notAuthorizedForExecution)
    #expect(snapshot.connectionEpoch == 99)
    #expect(snapshot.plan.restoreSetRequest.bytes[6] == 0x02)
}

@Test func reconnectRecoveryReadinessRejectsIneligibleRuntimeAndUnknownLiveState()
    throws
{
    let journal = try readinessJournal()
    let data = try readinessEncoded(journal)
    let prepared = try JSONEncoder().encode(
        try DeviceTransactionEnvelope(baselineJournal: journal)
    )
    #expect(throws: PrecisionTemporaryDiversionReadinessError
        .runtimeJournalNotEligible) {
        _ = try PrecisionTemporaryDiversionReadinessAudit
            .evaluateReconnectRecovery(
                readinessInput(sourceData: data, reloadedData: data),
                runtimeJournalData: prepared,
                reloadedRuntimeJournalData: prepared
            )
    }

    var envelope = try DeviceTransactionEnvelope(baselineJournal: journal)
    let plan = try PrecisionTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: readinessFeature(),
        deviceIndex: 0,
        softwareID: 0x0E
    )
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
    let runtimeData = try JSONEncoder().encode(envelope)
    let unknown = try plan.baseline.replacingRawFlags(0x00FF, featureVersion: 3)
    #expect(throws: PrecisionTemporaryDiversionReadinessError
        .precisionPreflightMismatch) {
        _ = try PrecisionTemporaryDiversionReadinessAudit
            .evaluateReconnectRecovery(
                readinessInput(
                    sourceData: data,
                    reloadedData: data,
                    preflightState: unknown
                ),
                runtimeJournalData: runtimeData,
                reloadedRuntimeJournalData: runtimeData
            )
    }
    unknownRestoreEligibility: do {
        let restoreAttemptID = UUID()
        var unknown = envelope
        unknown = try DeviceTransactionReducer.reduce(
            unknown,
            event: .armRestore(
                controlID: PrecisionTemporaryDiversionPlan.controlID,
                attemptID: restoreAttemptID,
                now: Date()
            )
        ).envelope
        unknown = try DeviceTransactionReducer.reduce(
            unknown,
            event: .recordInvocationOutcome(
                controlID: PrecisionTemporaryDiversionPlan.controlID,
                attemptID: restoreAttemptID,
                outcome: .outcomeUnknown,
                detail: "restore lost",
                now: Date()
            )
        ).envelope
        let unknownData = try JSONEncoder().encode(unknown)
        #expect(throws: PrecisionTemporaryDiversionReadinessError
            .runtimeJournalNotEligible) {
            _ = try PrecisionTemporaryDiversionReadinessAudit
                .evaluateReconnectRecovery(
                    readinessInput(
                        sourceData: data,
                        reloadedData: data,
                        preflightState: plan.activeState
                    ),
                    runtimeJournalData: unknownData,
                    reloadedRuntimeJournalData: unknownData
                )
        }
    }

    #expect(throws: PrecisionTemporaryDiversionReadinessError
        .runtimeJournalChangedDuringReview) {
        _ = try PrecisionTemporaryDiversionReadinessAudit
            .evaluateReconnectRecovery(
                readinessInput(sourceData: data, reloadedData: data),
                runtimeJournalData: runtimeData,
                reloadedRuntimeJournalData: runtimeData + [0x20]
            )
    }
}

private func readinessProcess(
    _ processIdentifier: Int32,
    _ bundleIdentifier: String?,
    _ localizedName: String?,
    executablePath: String? = nil
) -> PrecisionRunningApplicationSnapshot {
    PrecisionRunningApplicationSnapshot(
        processIdentifier: processIdentifier,
        bundleIdentifier: bundleIdentifier,
        localizedName: localizedName,
        executablePath: executablePath
    )
}

private func readinessInput(
    sourceData: Data,
    reloadedData: Data,
    currentSession: DeviceTransactionSession = readinessSession(),
    preflightSession: DeviceTransactionSession = readinessSession(),
    preflightState: DeviceTransactionWireState = readinessBaseline(),
    currentFeature: HIDPP20FeatureDescriptor = readinessFeature(),
    connectionGeneration: UInt64 = 9,
    rootGeneration: UInt64 = 9,
    firmwareGeneration: UInt64 = 9,
    preflightGeneration: UInt64 = 9,
    competitorsBefore: [PrecisionCompetingProcess] = [],
    competitorsAfter: [PrecisionCompetingProcess] = []
) -> PrecisionTemporaryDiversionReadinessInput {
    PrecisionTemporaryDiversionReadinessInput(
        sourceJournalData: sourceData,
        reloadedJournalData: reloadedData,
        currentSession: currentSession,
        preflightSession: preflightSession,
        preflightState: preflightState,
        currentFeature: currentFeature,
        connectionGeneration: connectionGeneration,
        rootEvidenceGeneration: rootGeneration,
        firmwareEvidenceGeneration: firmwareGeneration,
        preflightEvidenceGeneration: preflightGeneration,
        competitorsBefore: competitorsBefore,
        competitorsAfter: competitorsAfter,
        deviceIndex: 0,
        softwareID: 0x0E
    )
}

private func readinessJournal() throws -> DeviceStateJournal {
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
            rawParameters: readinessPadded([0x00, 0xED])
        ),
        baselineReporting: ReprogControlReportingState(
            controlID: 0x00ED,
            rawFlags: 0,
            rawMappedControlID: 0,
            rawParameters: readinessPadded([0x00, 0xED, 0x00, 0x00, 0x00])
        )
    )
    return try DeviceStateJournal(
        transactionID: UUID(),
        appBuild: "precision-readiness-test",
        device: readinessDevice(),
        feature: readinessFeature(),
        expectedControlCount: 1,
        controls: [entry]
    )
}

private func readinessEncoded(_ journal: DeviceStateJournal) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(journal)
}

private func readinessFeature() -> HIDPP20FeatureDescriptor {
    HIDPP20FeatureDescriptor(
        index: 0x0A,
        type: 0,
        version: 3,
        rawParameters: readinessPadded([0x0A, 0x00, 0x03])
    )
}

private func readinessSession(
    connectionEpoch: UInt64 = 43
) -> DeviceTransactionSession {
    DeviceTransactionSession(
        device: readinessDevice(),
        featureID: ReprogControlsV4.featureID,
        featureVersion: 3,
        featureIndex: 0x0A,
        connectionEpoch: connectionEpoch
    )
}

private func readinessDevice() -> JournalDeviceIdentity {
    JournalDeviceIdentity(
        deviceID: "046D-B01D-READINESS",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "READINESS-SERIAL",
        locationID: 9,
        firmwareIdentity: "readiness-firmware"
    )
}

private func readinessBaseline() -> DeviceTransactionWireState {
    try! DeviceTransactionWireState(
        rawParameters: readinessPadded([0x00, 0xED, 0x00, 0x00, 0x00])
    )
}

private func readinessPadded(_ prefix: [UInt8]) -> [UInt8] {
    prefix + Array(repeating: 0, count: HIDPP20LongMessage.parameterCount - prefix.count)
}
