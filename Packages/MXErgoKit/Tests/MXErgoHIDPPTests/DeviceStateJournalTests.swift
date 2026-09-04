import Foundation
import Testing
@testable import MXErgoHIDPP

@Test func journalRequiresACompleteUniqueRawSnapshot() throws {
    let entry = try testJournalEntry()

    #expect(throws: DeviceStateJournalError.incompleteSnapshot(expected: 2, actual: 1)) {
        try DeviceStateJournal(
            appBuild: "test",
            device: testJournalDevice(),
            feature: testFeature(),
            expectedControlCount: 2,
            controls: [entry]
        )
    }

    #expect(throws: DeviceStateJournalError.duplicateControlID(0x00ED)) {
        try DeviceStateJournal(
            appBuild: "test",
            device: testJournalDevice(),
            feature: testFeature(),
            expectedControlCount: 2,
            controls: [entry, entry]
        )
    }
}

@Test func journalRejectsDuplicatePhysicalControlIndexes() throws {
    let first = try testJournalEntry(index: 0, controlID: 0x0050)
    let second = try testJournalEntry(index: 0, controlID: 0x00ED)

    #expect(throws: DeviceStateJournalError.duplicateControlIndex(0)) {
        try DeviceStateJournal(
            appBuild: "test",
            device: testJournalDevice(),
            feature: testFeature(),
            expectedControlCount: 2,
            controls: [first, second]
        )
    }
}

@Test func journalWriteAheadRecoveryTransitionsAreExplicit() throws {
    var journal = try testJournal()
    #expect(!journal.requiresRecovery)
    #expect(journal.statusSummary == "baseline verified")

    let intended = testReporting(flags: 0x0001)
    try journal.transitionControl(
        0x00ED,
        to: .applyMayHaveOccurred,
        intendedReporting: intended
    )
    #expect(journal.requiresRecovery)

    try journal.transitionControl(
        0x00ED,
        to: .appliedVerified,
        readBackReporting: intended
    )
    try journal.transitionControl(0x00ED, to: .restoreMayHaveOccurred)
    try journal.transitionControl(
        0x00ED,
        to: .restoredVerified,
        readBackReporting: testReporting(flags: 0)
    )
    #expect(!journal.requiresRecovery)
    #expect(journal.statusSummary == "restored verified")

    #expect(throws: DeviceStateJournalError.invalidTransition(
        controlID: 0x00ED,
        from: .restoredVerified,
        to: .applyMayHaveOccurred
    )) {
        try journal.transitionControl(
            0x00ED,
            to: .applyMayHaveOccurred,
            intendedReporting: intended
        )
    }
}

@Test func applyWriteAheadPhaseRequiresTheExactIntendedWireState() throws {
    var journal = try testJournal()

    #expect(throws: DeviceStateJournalError.intendedStateRequired(0x00ED)) {
        try journal.transitionControl(0x00ED, to: .applyMayHaveOccurred)
    }
}

@Test func journalStoreRoundTripsAtomicallyEncodedState() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = DeviceStateJournalStore(
        fileURL: temporaryDirectory.appendingPathComponent("state.json")
    )
    let journal = try testJournal()

    try store.save(journal)
    #expect(try store.load() == journal)
}

@Test func liveJournalWriterHonorsTheCanonicalDeviceOperationLease() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = temporaryDirectory.appendingPathComponent("state.json")
    let store = DeviceStateJournalStore(fileURL: fileURL)
    let lease = try MXErgoDeviceOperationLease.acquire(beside: fileURL)
    defer { withExtendedLifetime(lease) {} }

    #expect(throws: MXErgoDeviceOperationLeaseError.unavailable) {
        try store.save(try testJournal())
    }
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test func journalStoreRejectsDecodedDataThatBypassesSnapshotValidation() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = temporaryDirectory.appendingPathComponent("state.json")
    let store = DeviceStateJournalStore(fileURL: fileURL)
    try store.save(try testJournal())

    let data = try Data(contentsOf: fileURL)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["expectedControlCount"] = 2
    try JSONSerialization.data(withJSONObject: object).write(to: fileURL, options: .atomic)

    #expect(throws: DeviceStateJournalError.incompleteSnapshot(expected: 2, actual: 1)) {
        try store.load()
    }
}

private func testJournal() throws -> DeviceStateJournal {
    try DeviceStateJournal(
        transactionID: UUID(uuidString: "EBA1E596-72C8-4E7A-A951-85C3D980C5F7")!,
        appBuild: "test-build",
        device: testJournalDevice(),
        feature: testFeature(),
        expectedControlCount: 1,
        controls: [try testJournalEntry()],
        now: Date(timeIntervalSince1970: 1_000.123_456)
    )
}

private func testJournalEntry(
    index: UInt8 = 0,
    controlID: UInt16 = 0x00ED
) throws -> DeviceControlJournalEntry {
    let high = UInt8(controlID >> 8)
    let low = UInt8(controlID & 0xFF)
    return try DeviceControlJournalEntry(
        controlInfo: ReprogControlInfo(
            index: index,
            controlID: controlID,
            taskID: controlID,
            capabilityFlags: 0x30,
            position: 0,
            group: 1,
            groupMask: 1,
            rawXYCapability: false,
            rawParameters: padded([high, low, high, low, 0x30, 0, 1, 1, 0])
        ),
        baselineReporting: testReporting(controlID: controlID, flags: 0)
    )
}

private func testReporting(
    controlID: UInt16 = 0x00ED,
    flags: UInt16
) -> ReprogControlReportingState {
    let controlHigh = UInt8(controlID >> 8)
    let controlLow = UInt8(controlID & 0xFF)
    let lowFlags = UInt8(flags & 0xFF)
    let highFlags = UInt8(flags >> 8)
    return ReprogControlReportingState(
        controlID: controlID,
        rawFlags: flags,
        rawMappedControlID: 0,
        rawParameters: padded([controlHigh, controlLow, lowFlags, 0, 0, highFlags])
    )
}

private func testFeature() -> HIDPP20FeatureDescriptor {
    HIDPP20FeatureDescriptor(
        index: 0x0B,
        type: 0,
        version: 4,
        rawParameters: padded([0x0B, 0, 4])
    )
}

private func testJournalDevice() -> JournalDeviceIdentity {
    JournalDeviceIdentity(
        deviceID: "1133-45085-99-1-2",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "TEST-ERGO",
        locationID: 99
    )
}

private func padded(_ prefix: [UInt8]) -> [UInt8] {
    prefix + Array(repeating: 0, count: HIDPP20LongMessage.parameterCount - prefix.count)
}
