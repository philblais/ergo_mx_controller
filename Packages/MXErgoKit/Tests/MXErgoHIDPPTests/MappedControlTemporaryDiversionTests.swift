import Foundation
import Testing
@testable import MXErgoHIDPP

@Test func mappedDiversionPlanBuildsApplyRestoreAndGetForTheFiveBTTControls() throws {
    let journal = try mappedJournal()
    let plan = try MappedControlsTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: journal.feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )

    #expect(plan.controls.map(\.controlID) == [
        0x0052, 0x0053, 0x0056, 0x005B, 0x005D,
    ])
    #expect(!plan.controls.contains { $0.controlID == 0x00ED })
    #expect(plan.featureIndex == 0x0A)
    #expect(plan.featureVersion == 3)

    let wheelClick = try plan.plan(for: 0x0052)
    #expect(wheelClick.baseline.rawFlags(featureVersion: 3) == 0)
    #expect(wheelClick.activeState.rawFlags(featureVersion: 3) == 1)
    #expect(wheelClick.applySetRequest.bytes == mappedPacket(
        address: 0x3E,
        parameters: [0x00, 0x52, 0x03, 0x00, 0x00]
    ))
    #expect(wheelClick.restoreSetRequest.bytes == mappedPacket(
        address: 0x3E,
        parameters: [0x00, 0x52, 0x02, 0x00, 0x00]
    ))
    #expect(wheelClick.verificationRequest.bytes == mappedPacket(
        address: 0x2E,
        parameters: [0x00, 0x52]
    ))

    let tiltRight = try plan.plan(for: 0x005D)
    #expect(Array(tiltRight.applySetRequest.parameters.prefix(5)) == [
        0x00, 0x5D, 0x03, 0x00, 0x00,
    ])
}

@Test func mappedDiversionPlanRejectsMissingIneligibleAndDirtyControls() throws {
    let missingThumb = try mappedJournal(omitting: 0x0053)
    #expect(throws: MappedControlTemporaryDiversionError.missingMappedControl(0x0053)) {
        try MappedControlsTemporaryDiversionPlan.make(
            journal: missingThumb,
            currentFeature: missingThumb.feature,
            deviceIndex: 0,
            softwareID: 0x0E
        )
    }

    let notDivertable = try mappedJournal(capabilityOverride: [0x0052: 0x11])
    #expect(throws: MappedControlTemporaryDiversionError.controlNotEligible(0x0052)) {
        try MappedControlsTemporaryDiversionPlan.make(
            journal: notDivertable,
            currentFeature: notDivertable.feature,
            deviceIndex: 0,
            softwareID: 0x0E
        )
    }

    let dirty = try mappedJournal(baselineFlags: [0x0056: 0x0001])
    #expect(throws: MappedControlTemporaryDiversionError.baselineNotClean(0x0056)) {
        try MappedControlsTemporaryDiversionPlan.make(
            journal: dirty,
            currentFeature: dirty.feature,
            deviceIndex: 0,
            softwareID: 0x0E
        )
    }
}

@Test func mappedDiversionPlanRejectsAnUnexpectedExtraDivertableControl() throws {
    let extra = try mappedJournal(extraDivertableID: 0x00C8)
    #expect(throws: MappedControlTemporaryDiversionError.unexpectedMappedControl(0x00C8)) {
        try MappedControlsTemporaryDiversionPlan.make(
            journal: extra,
            currentFeature: extra.feature,
            deviceIndex: 0,
            softwareID: 0x0E
        )
    }
}

@Test func mappedDiversionPlanProjectsOnlyReviewedMutations() throws {
    let journal = try mappedJournal()
    let plan = try MappedControlsTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: journal.feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let wheel = try plan.plan(for: 0x0052)
    let apply = DeviceTransactionMutation(
        transactionID: journal.transactionID,
        controlID: 0x0052,
        attemptID: UUID(),
        kind: .apply,
        state: wheel.activeState
    )
    let restore = DeviceTransactionMutation(
        transactionID: journal.transactionID,
        controlID: 0x0052,
        attemptID: UUID(),
        kind: .restore,
        state: wheel.baseline
    )
    #expect(try plan.request(for: apply) == wheel.applySetRequest)
    #expect(try plan.request(for: restore) == wheel.restoreSetRequest)
    #expect(throws: MappedControlTemporaryDiversionError.invalidMutation) {
        try plan.request(
            for: DeviceTransactionMutation(
                transactionID: journal.transactionID,
                controlID: 0x00ED,
                attemptID: UUID(),
                kind: .apply,
                state: wheel.activeState
            )
        )
    }
}

func mappedJournal(
    omitting skipped: UInt16? = nil,
    capabilityOverride: [UInt16: UInt8] = [:],
    baselineFlags: [UInt16: UInt16] = [:],
    extraDivertableID: UInt16? = nil
) throws -> DeviceStateJournal {
    var specs: [(UInt8, UInt16, UInt8)] = [
        (0, 0x0050, 0x11),
        (1, 0x0051, 0x11),
        (2, 0x0052, 0x71),
        (3, 0x0053, 0x71),
        (4, 0x0056, 0x71),
        (5, 0x00ED, 0x71),
        (6, 0x005B, 0x71),
        (7, 0x005D, 0x71),
        (8, 0x00D7, 0xA0),
    ]
    if let extraDivertableID {
        specs.append((9, extraDivertableID, 0x71))
    }
    let entries = try specs.compactMap { index, controlID, flags -> DeviceControlJournalEntry? in
        if controlID == skipped { return nil }
        return try mappedEntry(
            index: index,
            controlID: controlID,
            capabilityFlags: capabilityOverride[controlID] ?? flags,
            baselineFlags: baselineFlags[controlID] ?? 0
        )
    }
    return try DeviceStateJournal(
        transactionID: UUID(),
        appBuild: "mapped-diversion-test",
        device: JournalDeviceIdentity(
            deviceID: "046D-B01D-MAPPED",
            vendorID: 0x046D,
            productID: 0xB01D,
            transport: "Bluetooth Low Energy",
            serialNumber: "MAPPED-SERIAL",
            locationID: 12,
            firmwareIdentity: "mapped-firmware"
        ),
        feature: HIDPP20FeatureDescriptor(
            index: 0x0A,
            type: 0,
            version: 3,
            rawParameters: mappedPadded([0x0A, 0x00, 0x03])
        ),
        expectedControlCount: entries.count,
        controls: entries
    )
}

func mappedEntry(
    index: UInt8,
    controlID: UInt16,
    capabilityFlags: UInt8,
    baselineFlags: UInt16
) throws -> DeviceControlJournalEntry {
    let high = UInt8(controlID >> 8)
    let low = UInt8(controlID & 0xFF)
    let flagByte = UInt8(baselineFlags & 0xFF)
    return try DeviceControlJournalEntry(
        controlInfo: ReprogControlInfo(
            index: index,
            controlID: controlID,
            taskID: controlID,
            capabilityFlags: capabilityFlags,
            position: 0,
            group: 1,
            groupMask: 1,
            rawXYCapability: false,
            rawParameters: mappedPadded([
                high, low, high, low, capabilityFlags, 0, 1, 1, 0,
            ])
        ),
        baselineReporting: ReprogControlReportingState(
            controlID: controlID,
            rawFlags: baselineFlags,
            rawMappedControlID: 0,
            rawParameters: mappedPadded([high, low, flagByte, 0, 0])
        )
    )
}

func mappedPacket(address: UInt8, parameters: [UInt8]) -> [UInt8] {
    [0x11, 0x00, 0x0A, address] + parameters
        + Array(repeating: 0, count: max(0, 16 - parameters.count))
}

func mappedPadded(_ bytes: [UInt8]) -> [UInt8] {
    bytes + Array(repeating: 0, count: max(0, 16 - bytes.count))
}
