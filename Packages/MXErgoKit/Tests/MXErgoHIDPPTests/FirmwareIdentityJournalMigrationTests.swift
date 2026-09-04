import Foundation
import Testing
@testable import MXErgoHIDPP

@Test func firmwareMigrationPlanChangesExactlyOneJSONPathAndPreservesUnknownFields() throws {
    let firmwareIdentity = "hidpp-device-info-v1|feature=02|unit=45D2D92E"
    let sourceData = try migrationSourceData(unknownTopLevelField: true)
    let plan = try FirmwareIdentityJournalMigrationPlanner.makePlan(
        sourceData: sourceData,
        connectedDevice: migrationDevice(),
        discoveredFirmwareIdentity: firmwareIdentity
    )

    #expect(plan.disposition == .ready)
    #expect(plan.changesExactlyFirmwareIdentity)
    #expect(plan.proposedJournal.schemaVersion == 2)
    #expect(plan.proposedJournal.transactionID == plan.originalJournal.transactionID)
    #expect(plan.proposedJournal.createdAt == plan.originalJournal.createdAt)
    #expect(plan.proposedJournal.updatedAt == plan.originalJournal.updatedAt)
    #expect(plan.proposedJournal.device.firmwareIdentity == firmwareIdentity)
    #expect(plan.sourceSHA256 != plan.targetSHA256)

    let targetObject = try #require(
        JSONSerialization.jsonObject(with: plan.targetData) as? [String: Any]
    )
    #expect(targetObject["futureSchema2Metadata"] as? String == "preserved")
}

@Test func firmwareMigrationPlanIsIdempotentForTheSameFingerprint() throws {
    let fingerprint = "same-firmware"
    let firstPlan = try FirmwareIdentityJournalMigrationPlanner.makePlan(
        sourceData: try migrationSourceData(),
        connectedDevice: migrationDevice(),
        discoveredFirmwareIdentity: fingerprint
    )
    let secondPlan = try FirmwareIdentityJournalMigrationPlanner.makePlan(
        sourceData: firstPlan.targetData,
        connectedDevice: migrationDevice(),
        discoveredFirmwareIdentity: fingerprint
    )

    #expect(secondPlan.disposition == .alreadyApplied)
    #expect(secondPlan.changedPaths.isEmpty)
    #expect(secondPlan.originalJournal == secondPlan.proposedJournal)
    #expect(secondPlan.sourceData == secondPlan.targetData)
}

@Test func firmwareMigrationPlanFailsClosedForConflictsAndDeviceMismatch() throws {
    let source = try migrationSourceData()
    let firstPlan = try FirmwareIdentityJournalMigrationPlanner.makePlan(
        sourceData: source,
        connectedDevice: migrationDevice(),
        discoveredFirmwareIdentity: "saved-firmware"
    )

    #expect(throws: FirmwareIdentityJournalMigrationError.firmwareIdentityConflict(
        saved: "saved-firmware",
        discovered: "different-firmware"
    )) {
        try FirmwareIdentityJournalMigrationPlanner.makePlan(
            sourceData: firstPlan.targetData,
            connectedDevice: migrationDevice(),
            discoveredFirmwareIdentity: "different-firmware"
        )
    }

    #expect(throws: FirmwareIdentityJournalMigrationError.deviceIdentityMismatch) {
        try FirmwareIdentityJournalMigrationPlanner.makePlan(
            sourceData: source,
            connectedDevice: migrationDevice(serialNumber: "OTHER-DEVICE"),
            discoveredFirmwareIdentity: "firmware"
        )
    }

    #expect(throws: FirmwareIdentityJournalMigrationError.emptyFirmwareIdentity) {
        try FirmwareIdentityJournalMigrationPlanner.makePlan(
            sourceData: source,
            connectedDevice: migrationDevice(),
            discoveredFirmwareIdentity: "  \n"
        )
    }
}

@Test func firmwareMigrationPlanRejectsARecoveryJournal() throws {
    var journal = try migrationJournal()
    let intended = migrationReporting(flags: 1)
    try journal.transitionControl(
        0x00ED,
        to: .applyMayHaveOccurred,
        intendedReporting: intended
    )
    let sourceData = try encodeMigrationJournal(journal)

    #expect(throws: FirmwareIdentityJournalMigrationError.journalRequiresRecovery) {
        try FirmwareIdentityJournalMigrationPlanner.makePlan(
            sourceData: sourceData,
            connectedDevice: migrationDevice(),
            discoveredFirmwareIdentity: "firmware"
        )
    }
}

@Test func durableFirmwareMigrationRecoversAtEveryCommitBoundary() async throws {
    for boundary in FirmwareIdentityJournalMigrationCommitBoundary.allCases {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("device-state-journal.json")
        let sourceData = try migrationSourceData()
        try sourceData.write(to: fileURL)
        let plan = try FirmwareIdentityJournalMigrationPlanner.makePlan(
            sourceData: sourceData,
            connectedDevice: migrationDevice(),
            discoveredFirmwareIdentity: "stable-firmware"
        )
        let faulting = DurableFirmwareIdentityJournalMigrationRepository(
            fileURL: fileURL,
            faultInjector: { observed in
                if observed == boundary { throw InjectedMigrationFailure.triggered }
            }
        )

        do {
            _ = try await faulting.commit(plan)
            Issue.record("Expected injected failure at \(boundary.rawValue)")
        } catch InjectedMigrationFailure.triggered {
            // Expected. A fresh repository must reconcile source or target.
        }

        let retry = DurableFirmwareIdentityJournalMigrationRepository(fileURL: fileURL)
        let receipt = try await retry.commit(plan)
        #expect(receipt.transactionID == plan.originalJournal.transactionID)
        #expect(receipt.sourceSHA256 == plan.sourceSHA256)
        #expect(receipt.targetSHA256 == plan.targetSHA256)
        #expect(try Data(contentsOf: fileURL) == plan.targetData)
        #expect(try Data(contentsOf: receipt.backupURL) == plan.sourceData)
    }
}

@Test func durableFirmwareMigrationRejectsSourceAndBackupConflicts() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("device-state-journal.json")
    let sourceData = try migrationSourceData()
    let plan = try FirmwareIdentityJournalMigrationPlanner.makePlan(
        sourceData: sourceData,
        connectedDevice: migrationDevice(),
        discoveredFirmwareIdentity: "stable-firmware"
    )
    let repository = DurableFirmwareIdentityJournalMigrationRepository(fileURL: fileURL)

    try Data("changed".utf8).write(to: fileURL)
    do {
        _ = try await repository.commit(plan)
        Issue.record("Expected exact-source CAS rejection")
    } catch let error as FirmwareIdentityJournalMigrationCommitError {
        guard case .sourceBytesMismatch = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    }

    try sourceData.write(to: fileURL)
    let backupURL = directory.appendingPathComponent(
        "device-state-journal.pre-firmware-identity.json"
    )
    try Data("wrong-backup".utf8).write(to: backupURL)
    await #expect(throws: FirmwareIdentityJournalMigrationCommitError.backupConflict) {
        try await repository.commit(plan)
    }
    #expect(try Data(contentsOf: fileURL) == sourceData)
}

private enum InjectedMigrationFailure: Error {
    case triggered
}

private func migrationSourceData(unknownTopLevelField: Bool = false) throws -> Data {
    let data = try encodeMigrationJournal(migrationJournal())
    guard unknownTopLevelField else { return data }
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["futureSchema2Metadata"] = "preserved"
    return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
}

private func encodeMigrationJournal(_ journal: DeviceStateJournal) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(journal)
}

private func migrationJournal() throws -> DeviceStateJournal {
    try DeviceStateJournal(
        transactionID: UUID(uuidString: "75465823-37D5-4685-A6C8-398A9B0D72F1")!,
        appBuild: "test-build",
        device: migrationDevice(),
        feature: HIDPP20FeatureDescriptor(
            index: 0x0A,
            type: 0,
            version: 4,
            rawParameters: migrationPadded([0x0A, 0, 4])
        ),
        expectedControlCount: 1,
        controls: [try migrationEntry()],
        now: Date(timeIntervalSince1970: 1_000.25)
    )
}

private func migrationDevice(
    serialNumber: String = "7865BCA9046ED9FF",
    firmwareIdentity: String? = nil
) -> JournalDeviceIdentity {
    JournalDeviceIdentity(
        deviceID: "1133-45085-1384295475-1-2",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: serialNumber,
        locationID: 1_384_295_475,
        firmwareIdentity: firmwareIdentity
    )
}

private func migrationEntry() throws -> DeviceControlJournalEntry {
    try DeviceControlJournalEntry(
        controlInfo: ReprogControlInfo(
            index: 0,
            controlID: 0x00ED,
            taskID: 0x00C4,
            capabilityFlags: 0x71,
            position: 0,
            group: 1,
            groupMask: 1,
            rawXYCapability: false,
            rawParameters: migrationPadded([0x00, 0xED, 0x00, 0xC4, 0x71, 0, 1, 1, 0])
        ),
        baselineReporting: migrationReporting(flags: 0)
    )
}

private func migrationReporting(flags: UInt16) -> ReprogControlReportingState {
    ReprogControlReportingState(
        controlID: 0x00ED,
        rawFlags: flags,
        rawMappedControlID: 0,
        rawParameters: migrationPadded([
            0x00, 0xED, UInt8(flags & 0xFF), 0, 0, UInt8(flags >> 8)
        ])
    )
}

private func migrationPadded(_ prefix: [UInt8]) -> [UInt8] {
    prefix + Array(repeating: 0, count: HIDPP20LongMessage.parameterCount - prefix.count)
}
