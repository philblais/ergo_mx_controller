import Foundation
import Testing
@testable import MXErgoHIDPP

@Test func mappedReadinessBuildsAnImmutableNonAuthorizationWithoutFileIO() throws {
    let journal = try mappedJournal()
    let data = try mappedReadinessEncoded(journal)
    let untouched = data
    let absentTransactionURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("mapped-transaction-v3.json")

    let snapshot = try MappedControlsTemporaryDiversionReadinessAudit.evaluate(
        mappedReadinessInput(sourceData: data, reloadedData: data)
    )

    #expect(snapshot.authorization == .notAuthorizedForExecution)
    #expect(snapshot.plan.controls.map(\.controlID) == [
        0x0052, 0x0053, 0x0056, 0x005B, 0x005D,
    ])
    #expect(!snapshot.plan.controls.contains { $0.controlID == 0x00ED })
    #expect(snapshot.plan.featureIndex == 0x0A)
    #expect(snapshot.plan.featureVersion == 3)
    let wheelClick = try snapshot.plan.plan(for: 0x0052)
    #expect(wheelClick.applySetRequest.bytes[6] == 0x03)
    #expect(wheelClick.restoreSetRequest.bytes[6] == 0x02)
    #expect(snapshot.sourceBaselineTransactionID == journal.transactionID)
    #expect(snapshot.sourceJournalSHA256.count == 64)
    #expect(snapshot.sourceJournalSHA256 ==
        MappedControlsTemporaryDiversionReadinessAudit.sourceJournalSHA256(data))
    #expect(data == untouched)
    #expect(!FileManager.default.fileExists(atPath: absentTransactionURL.path))
}

@Test func mappedReadinessRejectsJournalChangeAndCompetitors() throws {
    let data = try mappedReadinessEncoded(mappedJournal())
    let changed = data + [0x20]

    #expect(throws: MappedControlsTemporaryDiversionReadinessError
        .journalChangedDuringReview) {
        _ = try MappedControlsTemporaryDiversionReadinessAudit.evaluate(
            mappedReadinessInput(sourceData: data, reloadedData: changed)
        )
    }

    let btt = PrecisionCompetingProcess(
        processIdentifier: 77,
        bundleIdentifier: "com.hegenberg.BetterTouchTool",
        localizedName: "BetterTouchTool"
    )
    #expect(throws: MappedControlsTemporaryDiversionReadinessError
        .competingProcesses([btt])) {
        _ = try MappedControlsTemporaryDiversionReadinessAudit.evaluate(
            mappedReadinessInput(
                sourceData: data,
                reloadedData: data,
                competitorsBefore: [btt]
            )
        )
    }
    #expect(throws: MappedControlsTemporaryDiversionReadinessError
        .competingProcesses([btt])) {
        _ = try MappedControlsTemporaryDiversionReadinessAudit.evaluate(
            mappedReadinessInput(
                sourceData: data,
                reloadedData: data,
                competitorsAfter: [btt]
            )
        )
    }
}

@Test func mappedReadinessRejectsEveryStaleGenerationAndSessionDrift() throws {
    let data = try mappedReadinessEncoded(mappedJournal())
    let staleGenerationInputs = [
        mappedReadinessInput(sourceData: data, reloadedData: data, rootGeneration: 8),
        mappedReadinessInput(sourceData: data, reloadedData: data, firmwareGeneration: 8),
    ]
    for input in staleGenerationInputs {
        #expect(throws: MappedControlsTemporaryDiversionReadinessError
            .staleConnectionEvidence) {
            _ = try MappedControlsTemporaryDiversionReadinessAudit.evaluate(input)
        }
    }

    let driftedDevice = JournalDeviceIdentity(
        deviceID: "046D-B01D-OTHER",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "MAPPED-SERIAL",
        locationID: 12,
        firmwareIdentity: "mapped-firmware"
    )
    #expect(throws: MappedControlsTemporaryDiversionReadinessError.sessionMismatch) {
        _ = try MappedControlsTemporaryDiversionReadinessAudit.evaluate(
            mappedReadinessInput(
                sourceData: data,
                reloadedData: data,
                currentSession: mappedReadinessSession(device: driftedDevice)
            )
        )
    }
}

@Test func mappedReadinessRejectsFeatureMismatch() throws {
    let data = try mappedReadinessEncoded(mappedJournal())
    let changedFeature = HIDPP20FeatureDescriptor(
        index: 0x0B,
        type: 0,
        version: 3,
        rawParameters: mappedPadded([0x0B, 0x00, 0x03])
    )
    #expect(throws: MappedControlsTemporaryDiversionReadinessError.featureMismatch) {
        _ = try MappedControlsTemporaryDiversionReadinessAudit.evaluate(
            mappedReadinessInput(
                sourceData: data,
                reloadedData: data,
                currentFeature: changedFeature
            )
        )
    }

    let wrongVersion = HIDPP20FeatureDescriptor(
        index: 0x0A,
        type: 0,
        version: 2,
        rawParameters: mappedPadded([0x0A, 0x00, 0x02])
    )
    #expect(throws: MappedControlsTemporaryDiversionReadinessError.featureMismatch) {
        _ = try MappedControlsTemporaryDiversionReadinessAudit.evaluate(
            mappedReadinessInput(
                sourceData: data,
                reloadedData: data,
                currentSession: mappedReadinessSession(featureVersion: 2),
                currentFeature: wrongVersion
            )
        )
    }
}

@Test func mappedReadinessRejectsDirtyBaselineJournal() throws {
    var journal = try mappedJournal()
    let active = ReprogControlReportingState(
        controlID: 0x0052,
        rawFlags: 0x01,
        rawMappedControlID: 0,
        rawParameters: mappedPadded([0x00, 0x52, 0x01, 0x00, 0x00])
    )
    try journal.transitionControl(
        0x0052,
        to: .applyMayHaveOccurred,
        intendedReporting: active
    )
    let data = try mappedReadinessEncoded(journal)

    #expect(throws: MappedControlsTemporaryDiversionReadinessError
        .journalRequiresRecovery) {
        _ = try MappedControlsTemporaryDiversionReadinessAudit.evaluate(
            mappedReadinessInput(sourceData: data, reloadedData: data)
        )
    }
}

private func mappedReadinessInput(
    sourceData: Data,
    reloadedData: Data,
    currentSession: DeviceTransactionSession = mappedReadinessSession(),
    currentFeature: HIDPP20FeatureDescriptor = mappedReadinessFeature(),
    connectionGeneration: UInt64 = 9,
    rootGeneration: UInt64 = 9,
    firmwareGeneration: UInt64 = 9,
    competitorsBefore: [PrecisionCompetingProcess] = [],
    competitorsAfter: [PrecisionCompetingProcess] = []
) -> MappedControlsTemporaryDiversionReadinessInput {
    MappedControlsTemporaryDiversionReadinessInput(
        sourceJournalData: sourceData,
        reloadedJournalData: reloadedData,
        currentSession: currentSession,
        currentFeature: currentFeature,
        connectionGeneration: connectionGeneration,
        rootEvidenceGeneration: rootGeneration,
        firmwareEvidenceGeneration: firmwareGeneration,
        competitorsBefore: competitorsBefore,
        competitorsAfter: competitorsAfter,
        deviceIndex: 0,
        softwareID: 0x0E
    )
}

private func mappedReadinessEncoded(_ journal: DeviceStateJournal) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(journal)
}

private func mappedReadinessFeature() -> HIDPP20FeatureDescriptor {
    HIDPP20FeatureDescriptor(
        index: 0x0A,
        type: 0,
        version: 3,
        rawParameters: mappedPadded([0x0A, 0x00, 0x03])
    )
}

private func mappedReadinessSession(
    device: JournalDeviceIdentity? = nil,
    featureVersion: UInt8 = 3,
    connectionEpoch: UInt64 = 43
) -> DeviceTransactionSession {
    DeviceTransactionSession(
        device: device ?? JournalDeviceIdentity(
            deviceID: "046D-B01D-MAPPED",
            vendorID: 0x046D,
            productID: 0xB01D,
            transport: "Bluetooth Low Energy",
            serialNumber: "MAPPED-SERIAL",
            locationID: 12,
            firmwareIdentity: "mapped-firmware"
        ),
        featureID: ReprogControlsV4.featureID,
        featureVersion: featureVersion,
        featureIndex: 0x0A,
        connectionEpoch: connectionEpoch
    )
}
