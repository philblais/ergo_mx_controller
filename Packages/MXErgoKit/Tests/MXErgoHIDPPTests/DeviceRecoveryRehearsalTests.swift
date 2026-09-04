import Foundation
import Testing
@testable import MXErgoHIDPP

@Test func recoveryPlanIsIdentityBoundAndOrderedByPhysicalIndex() throws {
    let journal = try rehearsalJournal()
    let plan = try DeviceRecoveryPlanner.makePlan(
        journal: journal,
        candidateDevice: rehearsalDevice()
    )

    #expect(plan.featureID == ReprogControlsV4.featureID)
    #expect(plan.featureVersion == 3)
    #expect(plan.steps.map(\.controlIndex) == [0, 5])
    #expect(plan.steps.map(\.controlID) == [0x0050, 0x00ED])
    #expect(plan.steps.allSatisfy { $0.baselineReporting.rawFlags == 0 })
}

@Test func recoveryPlanRejectsAnotherPhysicalDevice() throws {
    let candidate = JournalDeviceIdentity(
        deviceID: rehearsalDevice().deviceID,
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "ANOTHER-ERGO",
        locationID: rehearsalDevice().locationID
    )

    #expect(throws: DeviceRecoveryPlanningError.deviceIdentityMismatch) {
        try DeviceRecoveryPlanner.makePlan(
            journal: rehearsalJournal(),
            candidateDevice: candidate
        )
    }
}

@Test func recoveryIdentityRequiresExactLocationAndFirmwareFingerprint() {
    let saved = JournalDeviceIdentity(
        deviceID: "device",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "SERIAL",
        locationID: 42,
        firmwareIdentity: "firmware-a"
    )
    let wrongLocation = JournalDeviceIdentity(
        deviceID: saved.deviceID,
        vendorID: saved.vendorID,
        productID: saved.productID,
        transport: saved.transport,
        serialNumber: saved.serialNumber,
        locationID: 43,
        firmwareIdentity: saved.firmwareIdentity
    )
    let wrongFirmware = JournalDeviceIdentity(
        deviceID: saved.deviceID,
        vendorID: saved.vendorID,
        productID: saved.productID,
        transport: saved.transport,
        serialNumber: saved.serialNumber,
        locationID: saved.locationID,
        firmwareIdentity: "firmware-b"
    )

    #expect(saved.isSafeRecoveryMatch(saved))
    #expect(!saved.isSafeRecoveryMatch(wrongLocation))
    #expect(!saved.isSafeRecoveryMatch(wrongFirmware))
}

@Test func recoveryRehearsalExercisesEveryWriteAheadPhaseWithoutMutatingTheBaseline() throws {
    let journal = try rehearsalJournal()
    let original = journal
    let report = try DeviceRecoveryRehearsal.run(
        journal: journal,
        candidateDevice: rehearsalDevice()
    )

    #expect(journal == original)
    #expect(report.steps.count == 2)
    #expect(report.finalStatusSummary == "restored verified")
    #expect(report.steps.allSatisfy {
        $0.phaseSequence == [
            .baselineVerified,
            .applyMayHaveOccurred,
            .appliedVerified,
            .restoreMayHaveOccurred,
            .restoredVerified,
        ]
    })
}

@Test func recoveryRehearsalRefusesToMaskAnExistingRecoveryCondition() throws {
    var journal = try rehearsalJournal()
    let first = try #require(journal.controls.first)
    let intended = ReprogControlReportingState(
        controlID: first.controlInfo.controlID,
        rawFlags: 1,
        rawMappedControlID: first.baselineReporting.rawMappedControlID,
        rawParameters: rehearsalPayload([
            UInt8(first.controlInfo.controlID >> 8),
            UInt8(first.controlInfo.controlID & 0xFF),
            1,
            0,
            0,
            0,
        ])
    )
    try journal.transitionControl(
        first.controlInfo.controlID,
        to: .applyMayHaveOccurred,
        intendedReporting: intended
    )

    #expect(throws: DeviceRecoveryPlanningError.journalAlreadyRequiresRecovery) {
        try DeviceRecoveryRehearsal.run(
            journal: journal,
            candidateDevice: rehearsalDevice()
        )
    }
}

private func rehearsalJournal() throws -> DeviceStateJournal {
    try DeviceStateJournal(
        transactionID: UUID(uuidString: "75465823-37D5-4685-A6C8-398A9B0D72F1")!,
        appBuild: "test",
        device: rehearsalDevice(),
        feature: HIDPP20FeatureDescriptor(
            index: 0x0A,
            type: 0,
            version: 3,
            rawParameters: rehearsalPayload([0x0A, 0, 3])
        ),
        expectedControlCount: 2,
        controls: [
            try rehearsalEntry(index: 5, controlID: 0x00ED),
            try rehearsalEntry(index: 0, controlID: 0x0050),
        ],
        now: Date(timeIntervalSince1970: 1_000)
    )
}

private func rehearsalEntry(
    index: UInt8,
    controlID: UInt16
) throws -> DeviceControlJournalEntry {
    let high = UInt8(controlID >> 8)
    let low = UInt8(controlID & 0xFF)
    return try DeviceControlJournalEntry(
        controlInfo: ReprogControlInfo(
            index: index,
            controlID: controlID,
            taskID: controlID,
            capabilityFlags: 0x71,
            position: 0,
            group: 2,
            groupMask: 3,
            rawXYCapability: true,
            rawParameters: rehearsalPayload([
                high, low, high, low, 0x71, 0, 2, 3, 1,
            ])
        ),
        baselineReporting: ReprogControlReportingState(
            controlID: controlID,
            rawFlags: 0,
            rawMappedControlID: 0,
            rawParameters: rehearsalPayload([high, low, 0, 0, 0, 0])
        )
    )
}

private func rehearsalDevice() -> JournalDeviceIdentity {
    JournalDeviceIdentity(
        deviceID: "1133-45085-1384295475-1-2",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "7865BCA9046ED9FF",
        locationID: 1_384_295_475
    )
}

private func rehearsalPayload(_ prefix: [UInt8]) -> [UInt8] {
    prefix + Array(
        repeating: 0,
        count: HIDPP20LongMessage.parameterCount - prefix.count
    )
}
