import Foundation
import MXErgoHIDPP
import Testing
@testable import MXErgoPrecisionRuntimeJournal

@Test func firstBootstrapCreatesOneExactCanonicalJournalSource() async throws {
    let fixture = try journalFixture()
    defer { fixture.cleanup() }
    let sourceBefore = try Data(contentsOf: fixture.sourceURL)

    let context = try await PrecisionRuntimeJournalBootstrap.prepare(
        fixture.request()
    )

    #expect(context.disposition == .created)
    #expect(context.plan == fixture.plan)
    #expect(context.session == fixture.session)
    #expect(context.rootGeneration == fixture.rootGeneration)
    #expect(context.snapshot.data == (try Data(contentsOf: fixture.runtimeURL)))
    #expect(context.snapshot.sha256 ==
        PrecisionTemporaryDiversionReadinessAudit.sourceJournalSHA256(
            context.snapshot.data
        ))
    #expect(context.snapshot.envelope.sourceBaselineTransactionID
        == fixture.baseline.transactionID)
    #expect(context.snapshot.envelope.status == .prepared)
    #expect(try await context.source.loadValidatedSnapshot() == context.snapshot)
    #expect(try await context.source.loadValidated() == context.snapshot.envelope)
    #expect(try Data(contentsOf: fixture.sourceURL) == sourceBefore)
}

@Test func matchingBootstrapReusesExistingBytesAndTransactionIdentity() async throws {
    let fixture = try journalFixture()
    defer { fixture.cleanup() }
    let first = try await PrecisionRuntimeJournalBootstrap.prepare(
        fixture.request()
    )
    let bytes = try Data(contentsOf: fixture.runtimeURL)

    let second = try await PrecisionRuntimeJournalBootstrap.prepare(
        fixture.request()
    )

    #expect(second.disposition == .reused(.prepared))
    #expect(second.snapshot == first.snapshot)
    #expect(second.snapshot.envelope.transactionID
        == first.snapshot.envelope.transactionID)
    #expect(try Data(contentsOf: fixture.runtimeURL) == bytes)
}

@Test func invalidRequestAndSourceEvidenceFailBeforeRuntimeCreation() async throws {
    do {
        let fixture = try journalFixture()
        defer { fixture.cleanup() }
        let invalidSession = DeviceTransactionSession(
            device: fixture.session.device,
            featureID: fixture.session.featureID,
            featureVersion: 4,
            featureIndex: fixture.session.featureIndex,
            connectionEpoch: fixture.session.connectionEpoch
        )
        await expectBootstrapError(.invalidRequestBinding) {
            try await PrecisionRuntimeJournalBootstrap.prepare(
                fixture.request(session: invalidSession)
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.runtimeURL.path))
    }

    do {
        let fixture = try journalFixture()
        defer { fixture.cleanup() }
        await expectBootstrapError(.sourceBaselineMismatch) {
            try await PrecisionRuntimeJournalBootstrap.prepare(
                fixture.request(
                    sourceSHA256: String(repeating: "0", count: 64)
                )
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.runtimeURL.path))
    }

    do {
        let fixture = try journalFixture()
        defer { fixture.cleanup() }
        await expectBootstrapError(.sourceAndRuntimeJournalCollide) {
            try await PrecisionRuntimeJournalBootstrap.prepare(
                fixture.request(runtimeURL: fixture.sourceURL)
            )
        }
    }

    do {
        let fixture = try journalFixture()
        defer { fixture.cleanup() }
        let otherDirectory = fixture.directory
            .appendingPathComponent("other", isDirectory: true)
        let otherRuntime = otherDirectory.appendingPathComponent("runtime.json")
        await expectBootstrapError(.journalsDoNotShareCanonicalDirectory) {
            try await PrecisionRuntimeJournalBootstrap.prepare(
                fixture.request(runtimeURL: otherRuntime)
            )
        }
        #expect(!FileManager.default.fileExists(atPath: otherRuntime.path))
    }
}

@Test func everyExistingIdentityFeatureAndBaselineMismatchPreservesBytes() async throws {
    for mutation in ExistingJournalMutation.allCases {
        let fixture = try journalFixture()
        defer { fixture.cleanup() }
        _ = try await PrecisionRuntimeJournalBootstrap.prepare(fixture.request())
        let original = try Data(contentsOf: fixture.runtimeURL)
        let changed = try mutation.apply(to: original)
        try changed.write(to: fixture.runtimeURL, options: .atomic)

        do {
            _ = try await PrecisionRuntimeJournalBootstrap.prepare(
                fixture.request()
            )
            Issue.record("Expected existing journal mismatch for \(mutation)")
        } catch {
            if mutation != .schemaVersion {
                #expect(error as? PrecisionRuntimeJournalError
                    == .existingRuntimeJournalMismatch)
            }
        }
        #expect(try Data(contentsOf: fixture.runtimeURL) == changed)
        #expect(try Data(contentsOf: fixture.sourceURL) == fixture.sourceData)
    }
}

@Test func recoveryAndConflictJournalsAreReusedWithoutResettingEvidence() async throws {
    for shouldConflict in [false, true] {
        let fixture = try journalFixture()
        defer { fixture.cleanup() }
        let context = try await PrecisionRuntimeJournalBootstrap.prepare(
            fixture.request()
        )
        var changed = try DeviceTransactionReducer.reduce(
            context.snapshot.envelope,
            event: .armApply(
                controlID: PrecisionTemporaryDiversionPlan.controlID,
                intended: fixture.plan.activeState,
                attemptID: UUID(),
                now: Date()
            )
        ).envelope
        _ = try await context.source.commit(changed, expectedRevision: 0)

        let expectedStatus: DeviceTransactionStatus
        if shouldConflict {
            let thirdParty = try fixture.plan.baseline.replacingRawFlags(
                0x10,
                featureVersion: fixture.plan.featureVersion
            )
            changed = try DeviceTransactionReducer.reduce(
                changed,
                event: .observeApply(
                    controlID: PrecisionTemporaryDiversionPlan.controlID,
                    state: thirdParty,
                    now: Date()
                )
            ).envelope
            _ = try await context.source.commit(changed, expectedRevision: 1)
            expectedStatus = .conflicted
        } else {
            expectedStatus = .recoveryRequired
        }
        let before = try Data(contentsOf: fixture.runtimeURL)

        let reused = try await PrecisionRuntimeJournalBootstrap.prepare(
            fixture.request()
        )

        #expect(reused.disposition == .reused(expectedStatus))
        #expect(reused.snapshot.envelope == changed)
        #expect(try Data(contentsOf: fixture.runtimeURL) == before)
    }
}

@Test func concurrentFirstBootstrapCannotPublishCompetingJournals() async throws {
    let fixture = try journalFixture()
    defer { fixture.cleanup() }
    let request = fixture.request()

    let outcomes = await withTaskGroup(
        of: ConcurrentBootstrapOutcome.self,
        returning: [ConcurrentBootstrapOutcome].self
    ) { group in
        for _ in 0..<12 {
            group.addTask {
                do {
                    let context = try await PrecisionRuntimeJournalBootstrap
                        .prepare(request)
                    return .success(context.disposition)
                } catch MXErgoDeviceOperationLeaseError.unavailable {
                    return .leaseUnavailable
                } catch {
                    return .unexpected(String(describing: error))
                }
            }
        }
        var results: [ConcurrentBootstrapOutcome] = []
        for await result in group { results.append(result) }
        return results
    }

    #expect(outcomes.contains(.success(.created)))
    #expect(!outcomes.contains(where: {
        if case .unexpected = $0 { return true }
        return false
    }))
    let final = try await PrecisionRuntimeJournalBootstrap.prepare(request)
    #expect(final.disposition == .reused(.prepared))
    #expect(final.snapshot.envelope.revision == 0)
    #expect(final.snapshot.data == (try Data(contentsOf: fixture.runtimeURL)))
}

@Test func everyDurableCreationBoundaryRetriesWithoutResetOrCorruption() async throws {
    for boundary in DeviceTransactionCommitBoundary.allCases {
        let fixture = try journalFixture()
        defer { fixture.cleanup() }
        let repository = DurableDeviceTransactionFileRepository(
            fileURL: fixture.runtimeURL,
            faultInjector: { reached in
                if reached == boundary { throw InjectedJournalError.boundary }
            }
        )
        let source = DurablePrecisionRuntimeJournalSource(
            journalURL: fixture.runtimeURL,
            repository: repository
        )

        do {
            _ = try await PrecisionRuntimeJournalBootstrap.prepare(
                fixture.request(),
                makeSource: { _ in source }
            )
            Issue.record("Expected injected failure at \(boundary)")
        } catch InjectedJournalError.boundary {
            // The repository may have published either no file or one complete
            // valid file. Retrying must handle both states without recreation.
        }
        let retry = try await PrecisionRuntimeJournalBootstrap.prepare(
            fixture.request()
        )
        #expect(retry.snapshot.envelope.revision == 0)
        #expect(retry.snapshot.envelope.status == .prepared)
        #expect(retry.snapshot.data == (try Data(contentsOf: fixture.runtimeURL)))
        #expect(try Data(contentsOf: fixture.sourceURL) == fixture.sourceData)
    }
}

@Test func symlinkedRuntimeJournalIsRejectedWithoutTouchingBaseline() async throws {
    let fixture = try journalFixture()
    defer { fixture.cleanup() }
    let decoyURL = fixture.directory.appendingPathComponent("decoy.json")
    try fixture.sourceData.write(to: decoyURL, options: .atomic)
    try FileManager.default.createSymbolicLink(
        at: fixture.runtimeURL,
        withDestinationURL: decoyURL
    )

    await expectBootstrapError(.runtimeJournalNotRegular) {
        try await PrecisionRuntimeJournalBootstrap.prepare(fixture.request())
    }

    #expect(try Data(contentsOf: fixture.sourceURL) == fixture.sourceData)
    let values = try fixture.runtimeURL.resourceValues(
        forKeys: [.isSymbolicLinkKey]
    )
    #expect(values.isSymbolicLink == true)
}

@Test func preacquiredLeaseMustProtectTheExactRuntimeJournal() async throws {
    let fixture = try journalFixture()
    defer { fixture.cleanup() }
    let correctLease = try MXErgoDeviceOperationLease.acquire(
        beside: fixture.runtimeURL
    )
    let context = try await PrecisionRuntimeJournalBootstrap.prepare(
        fixture.request(),
        operationLease: correctLease
    )
    #expect(context.snapshot.envelope.status == .prepared)
    #expect(correctLease.protects(journalURL: fixture.runtimeURL))

    let otherFixture = try journalFixture()
    defer { otherFixture.cleanup() }
    await #expect(throws: PrecisionRuntimeJournalError.operationLeaseMismatch) {
        try await PrecisionRuntimeJournalBootstrap.prepare(
            otherFixture.request(),
            operationLease: correctLease
        )
    }
    #expect(!FileManager.default.fileExists(
        atPath: otherFixture.runtimeURL.path
    ))
    #expect(try Data(contentsOf: otherFixture.sourceURL)
        == otherFixture.sourceData)
}

@Test func runtimeJournalTargetIsProductlessUnwiredAndCapabilityMinimal() throws {
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
    let products = try #require(
        manifest.split(separator: "targets: [", maxSplits: 1).first
    )
    #expect(!products.contains("MXErgoPrecisionRuntimeJournal"))
    #expect(manifest.components(
        separatedBy: "\"MXErgoPrecisionRuntimeJournal\""
    ).count - 1 == 6)
    #expect(manifest.components(
        separatedBy: "\"MXErgoPrecisionRuntimeJournalTests\""
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
    #expect(!projectYAML.contains("MXErgoPrecisionRuntimeJournal"))
    #expect(!projectFile.contains("MXErgoPrecisionRuntimeJournal"))

    let source = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionRuntimeJournal"
        )
    )
    for forbidden in [
        "import IOKit",
        "IOHID",
        "SetReport",
        "MXErgoPrecisionIOHIDAcquisition",
        "@main",
        "ProcessInfo.processInfo.environment",
        "public ",
        "@_spi",
    ] {
        #expect(!source.contains(forbidden))
    }
}

private enum InjectedJournalError: Error {
    case boundary
}

private enum ConcurrentBootstrapOutcome: Sendable, Equatable {
    case success(PrecisionRuntimeJournalBootstrapDisposition)
    case leaseUnavailable
    case unexpected(String)
}

private enum ExistingJournalMutation: CaseIterable, CustomStringConvertible {
    case sourceTransaction
    case deviceFirmware
    case featureIndex
    case baseline
    case schemaVersion

    var description: String {
        switch self {
        case .sourceTransaction: return "source transaction"
        case .deviceFirmware: return "device firmware"
        case .featureIndex: return "feature index"
        case .baseline: return "baseline"
        case .schemaVersion: return "schema version"
        }
    }

    func apply(to data: Data) throws -> Data {
        var root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        switch self {
        case .sourceTransaction:
            root["sourceBaselineTransactionID"] = UUID().uuidString
        case .deviceFirmware:
            var device = try #require(root["device"] as? [String: Any])
            device["firmwareIdentity"] = "changed-firmware"
            root["device"] = device
        case .featureIndex:
            root["featureIndex"] = 0x0B
        case .baseline:
            var controls = try #require(root["controls"] as? [[String: Any]])
            var baseline = try #require(
                controls[0]["baseline"] as? [String: Any]
            )
            var parameters = try #require(
                baseline["rawParameters"] as? [Int]
            )
            parameters[2] = 0x10
            baseline["rawParameters"] = parameters
            controls[0]["baseline"] = baseline
            root["controls"] = controls
        case .schemaVersion:
            root["schemaVersion"] = 99
        }
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
    }
}

private final class JournalFixture: @unchecked Sendable {
    let directory: URL
    let sourceURL: URL
    let runtimeURL: URL
    let baseline: DeviceStateJournal
    let sourceData: Data
    let plan: PrecisionTemporaryDiversionPlan
    let session: DeviceTransactionSession
    let rootGeneration: UInt64 = 731

    init(
        directory: URL,
        baseline: DeviceStateJournal,
        sourceData: Data,
        plan: PrecisionTemporaryDiversionPlan,
        session: DeviceTransactionSession
    ) {
        self.directory = directory
        sourceURL = directory.appendingPathComponent("device-state-journal.json")
        runtimeURL = directory.appendingPathComponent(
            "precision-runtime-transaction.json"
        )
        self.baseline = baseline
        self.sourceData = sourceData
        self.plan = plan
        self.session = session
    }

    func request(
        session: DeviceTransactionSession? = nil,
        sourceSHA256: String? = nil,
        runtimeURL: URL? = nil
    ) -> PrecisionRuntimeJournalBootstrapRequest {
        PrecisionRuntimeJournalBootstrapRequest(
            plan: plan,
            session: session ?? self.session,
            rootGeneration: rootGeneration,
            sourceBaselineURL: sourceURL,
            sourceBaselineSHA256: sourceSHA256
                ?? PrecisionTemporaryDiversionReadinessAudit
                    .sourceJournalSHA256(sourceData),
            sourceBaselineTransactionID: baseline.transactionID,
            runtimeJournalURL: runtimeURL ?? self.runtimeURL
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func journalFixture() throws -> JournalFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "MXErgoPrecisionRuntimeJournalTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let device = JournalDeviceIdentity(
        deviceID: "1133-45085-23-1-2",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "RUNTIME-JOURNAL-TEST",
        locationID: 23,
        firmwareIdentity: "runtime-journal-test-firmware"
    )
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
            rawParameters: padded([0x00, 0xED, 0x00, 0x00, 0x00])
        )
    )
    let feature = HIDPP20FeatureDescriptor(
        index: 0x0A,
        type: 0,
        version: 3,
        rawParameters: padded([0x0A, 0x00, 0x03])
    )
    let baseline = try DeviceStateJournal(
        transactionID: UUID(),
        appBuild: "runtime-journal-test",
        device: device,
        feature: feature,
        expectedControlCount: 1,
        controls: [control]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let sourceData = try encoder.encode(baseline)
    let plan = try PrecisionTemporaryDiversionPlan.make(
        journal: baseline,
        currentFeature: feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let session = DeviceTransactionSession(
        device: device,
        featureID: ReprogControlsV4.featureID,
        featureVersion: 3,
        featureIndex: feature.index,
        connectionEpoch: 84
    )
    let fixture = JournalFixture(
        directory: directory,
        baseline: baseline,
        sourceData: sourceData,
        plan: plan,
        session: session
    )
    try sourceData.write(to: fixture.sourceURL, options: .atomic)
    return fixture
}

private func expectBootstrapError(
    _ expected: PrecisionRuntimeJournalError,
    operation: () async throws -> PrecisionRuntimeJournalContext
) async {
    do {
        _ = try await operation()
        Issue.record("Expected bootstrap error \(expected)")
    } catch let error as PrecisionRuntimeJournalError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected bootstrap error: \(error)")
    }
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
