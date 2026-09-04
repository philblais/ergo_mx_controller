import Foundation
import Testing
@testable import MXErgoHIDPP

@Test func restoreOnlyPlannerBuildsExactFeatureV3SetAndVerificationPackets() throws {
    let journal = try restoreJournal(entries: [
        try restoreEntry(
            index: 5,
            controlID: 0x00ED,
            capabilityFlags: 0x71,
            group: 2,
            groupMask: 3,
            rawXYCapability: true
        ),
    ])

    let plans = try RestoreOnlyReportingPlanner.makePlans(
        journal: journal,
        currentFeature: restoreFeature(),
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let plan = try #require(plans.first)

    #expect(plans.count == 1)
    #expect(plan.controlID == 0x00ED)
    #expect(plan.setFlags == 0x02)
    #expect(plan.setMappedControlID == 0x0000)
    #expect(plan.setRequest.bytes == [
        0x11, 0x00, 0x0A, 0x3E,
        0x00, 0xED, 0x02, 0x00, 0x00,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ])
    #expect(plan.verificationRequest.bytes == [
        0x11, 0x00, 0x0A, 0x2E,
        0x00, 0xED,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ])
}

@Test func restoreOnlyPlannerChangesOnlyTemporaryDiversionAndLeavesMappingUntouched() throws {
    let journal = try restoreJournal(entries: [
        try restoreEntry(
            index: 2,
            controlID: 0x0052,
            capabilityFlags: 0x71,
            group: 2,
            groupMask: 3,
            rawXYCapability: true,
            baselineFlags: 0x0001
        ),
        try restoreEntry(
            index: 3,
            controlID: 0x0053,
            capabilityFlags: 0x71,
            group: 2,
            groupMask: 3,
            rawXYCapability: true,
            mappedControlID: 0x0052
        ),
    ])

    let diverted = try RestoreOnlyReportingPlanner.makePlan(
        for: 0x0052,
        journal: journal,
        currentFeature: restoreFeature(),
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let mapped = try RestoreOnlyReportingPlanner.makePlan(
        for: 0x0053,
        journal: journal,
        currentFeature: restoreFeature(),
        deviceIndex: 0,
        softwareID: 0x0E
    )

    #expect(diverted.setFlags == 0x03)
    #expect(diverted.setMappedControlID == 0)
    #expect(mapped.setMappedControlID == 0)
    #expect(Array(mapped.setRequest.parameters.prefix(5)) == [0x00, 0x53, 0x02, 0x00, 0x00])
}

@Test func restoreOnlyPlannerRefusesPersistentAndRawXYBaselines() throws {
    let persistent = try restoreJournal(entries: [
        try restoreEntry(
            index: 5,
            controlID: 0x00ED,
            capabilityFlags: 0x71,
            group: 2,
            groupMask: 3,
            rawXYCapability: true,
            baselineFlags: 0x0004
        ),
    ])
    #expect(throws: RestoreOnlyReportingPlanError.unsupportedPersistentState(0x00ED)) {
        try RestoreOnlyReportingPlanner.makePlans(
            journal: persistent,
            currentFeature: restoreFeature(),
            deviceIndex: 0,
            softwareID: 0x0E
        )
    }

    let rawXY = try restoreJournal(entries: [
        try restoreEntry(
            index: 5,
            controlID: 0x00ED,
            capabilityFlags: 0x71,
            group: 2,
            groupMask: 3,
            rawXYCapability: true,
            baselineFlags: 0x0010
        ),
    ])
    #expect(throws: RestoreOnlyReportingPlanError.unsupportedRawXYState(0x00ED)) {
        try RestoreOnlyReportingPlanner.makePlans(
            journal: rawXY,
            currentFeature: restoreFeature(),
            deviceIndex: 0,
            softwareID: 0x0E
        )
    }
}

@Test func restoreOnlyPlannerOmitsNonDivertableAndVirtualControls() throws {
    let journal = try restoreJournal(entries: [
        try restoreEntry(
            index: 0,
            controlID: 0x0050,
            capabilityFlags: 0x11,
            group: 1,
            groupMask: 1,
            rawXYCapability: false
        ),
        try restoreEntry(
            index: 5,
            controlID: 0x00ED,
            capabilityFlags: 0x71,
            group: 2,
            groupMask: 3,
            rawXYCapability: true
        ),
        try restoreEntry(
            index: 8,
            controlID: 0x00D7,
            capabilityFlags: 0xA0,
            group: 3,
            groupMask: 0,
            rawXYCapability: true
        ),
    ])

    let plans = try RestoreOnlyReportingPlanner.makePlans(
        journal: journal,
        currentFeature: restoreFeature(),
        deviceIndex: 0,
        softwareID: 0x0E
    )
    #expect(plans.map(\.controlID) == [0x00ED])
}

@Test func restoreOnlyPlannerRefusesUnknownFeatureVersionsAndInconsistentBaseline() throws {
    let entry = try restoreEntry(
        index: 5,
        controlID: 0x00ED,
        capabilityFlags: 0x71,
        group: 2,
        groupMask: 3,
        rawXYCapability: true
    )
    let journal = try restoreJournal(entries: [entry])

    #expect(throws: RestoreOnlyReportingPlanError.unsupportedFeatureVersion(4)) {
        try RestoreOnlyReportingPlanner.makePlans(
            journal: journal,
            currentFeature: restoreFeature(version: 4),
            deviceIndex: 0,
            softwareID: 0x0E
        )
    }

    let inconsistent = try restoreJournal(entries: [
        try restoreEntry(
            index: 5,
            controlID: 0x00ED,
            capabilityFlags: 0x71,
            group: 2,
            groupMask: 3,
            rawXYCapability: true,
            baselineFlags: 0,
            rawFlagsOverride: 1
        ),
    ])
    #expect(throws: RestoreOnlyReportingPlanError.baselineFieldMismatch(0x00ED)) {
        try RestoreOnlyReportingPlanner.makePlans(
            journal: inconsistent,
            currentFeature: restoreFeature(),
            deviceIndex: 0,
            softwareID: 0x0E
        )
    }
}

@Test func restoreOnlySetAcknowledgementMustEchoEveryReviewedByte() throws {
    let journal = try restoreJournal(entries: [
        try restoreEntry(
            index: 5,
            controlID: 0x00ED,
            capabilityFlags: 0x71,
            group: 2,
            groupMask: 3,
            rawXYCapability: true
        ),
    ])
    let plan = try RestoreOnlyReportingPlanner.makePlan(
        for: 0x00ED,
        journal: journal,
        currentFeature: restoreFeature(),
        deviceIndex: 0,
        softwareID: 0x0E
    )

    try RestoreOnlyReportingPlanner.validateSetAcknowledgement(
        plan.setRequest,
        for: plan
    )

    var wrongBytes = plan.setRequest.bytes
    wrongBytes[8] = 0x52
    let wrong = try HIDPP20LongMessage(bytes: wrongBytes)
    #expect(throws: RestoreOnlyReportingPlanError.unexpectedSetAcknowledgement) {
        try RestoreOnlyReportingPlanner.validateSetAcknowledgement(wrong, for: plan)
    }
}

private func restoreJournal(
    entries: [DeviceControlJournalEntry],
    featureVersion: UInt8 = 3
) throws -> DeviceStateJournal {
    try DeviceStateJournal(
        transactionID: UUID(uuidString: "75465823-37D5-4685-A6C8-398A9B0D72F1")!,
        appBuild: "restore-plan-test",
        device: JournalDeviceIdentity(
            deviceID: "mx-ergo",
            vendorID: 0x046D,
            productID: 0xB01D,
            transport: "Bluetooth Low Energy",
            serialNumber: "TEST-SERIAL",
            locationID: 1,
            firmwareIdentity: "firmware-a"
        ),
        feature: restoreFeature(version: featureVersion),
        expectedControlCount: entries.count,
        controls: entries,
        now: Date(timeIntervalSince1970: 1_000)
    )
}

private func restoreEntry(
    index: UInt8,
    controlID: UInt16,
    capabilityFlags: UInt8,
    group: UInt8,
    groupMask: UInt8,
    rawXYCapability: Bool,
    baselineFlags: UInt16 = 0,
    mappedControlID: UInt16 = 0,
    rawFlagsOverride: UInt8? = nil
) throws -> DeviceControlJournalEntry {
    let high = UInt8(controlID >> 8)
    let low = UInt8(controlID & 0xFF)
    let mappedHigh = UInt8(mappedControlID >> 8)
    let mappedLow = UInt8(mappedControlID & 0xFF)
    let reportingByte = rawFlagsOverride ?? UInt8(baselineFlags & 0xFF)
    return try DeviceControlJournalEntry(
        controlInfo: ReprogControlInfo(
            index: index,
            controlID: controlID,
            taskID: controlID,
            capabilityFlags: capabilityFlags,
            position: 0,
            group: group,
            groupMask: groupMask,
            rawXYCapability: rawXYCapability,
            rawParameters: restorePadded([
                high, low, high, low, capabilityFlags, 0, group, groupMask,
                rawXYCapability ? 1 : 0,
            ])
        ),
        baselineReporting: ReprogControlReportingState(
            controlID: controlID,
            rawFlags: baselineFlags,
            rawMappedControlID: mappedControlID,
            rawParameters: restorePadded([
                high, low, reportingByte, mappedHigh, mappedLow,
            ])
        )
    )
}

private func restoreFeature(version: UInt8 = 3) -> HIDPP20FeatureDescriptor {
    HIDPP20FeatureDescriptor(
        index: 0x0A,
        type: 0,
        version: version,
        rawParameters: restorePadded([0x0A, 0, version])
    )
}

private func restorePadded(_ prefix: [UInt8]) -> [UInt8] {
    prefix + Array(repeating: 0, count: HIDPP20LongMessage.parameterCount - prefix.count)
}
