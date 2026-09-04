import Foundation
import Testing
@testable import MXErgoCore

@Test func mappedEventDeliveryUnauthorizedSnapshotAdmitsNothing() throws {
    let snapshot = try MappedControlEventDeliverySnapshot.makeUnauthorized(
        featureIndex: 0x0A,
        reviewedControlIDs: MappedControlActionPlan.controlIDs
    )
    #expect(snapshot.authorization == .notAuthorizedForExecution)
    #expect(snapshot.admittedControlIDs.isEmpty)
    #expect(snapshot.reviewedControlIDs == MappedControlActionPlan.controlIDs)
    #expect(snapshot.featureIndex == 0x0A)

    var pump = try MappedControlEventPump(
        featureIndex: 0x0A,
        reviewedControlIDs: snapshot.reviewedControlIDs
    )
    for controlID in MappedControlActionPlan.controlIDs + [MXErgoControl.precision.rawValue] {
        #expect(pump.processHIDPPNotification(
            mappedNotification(controlID: controlID),
            at: 1
        ).isEmpty)
    }
}

@Test func mappedEventPumpResolvesOnlyOneAdmittedCID() throws {
    var pump = try MappedControlEventPump(
        featureIndex: 0x0A,
        reviewedControlIDs: MappedControlActionPlan.controlIDs,
        admittedControlIDs: [MXErgoControl.upperThumb.rawValue]
    )

    #expect(pump.processHIDPPNotification(
        mappedNotification(controlID: MXErgoControl.lowerThumb.rawValue),
        at: 1
    ).isEmpty)
    #expect(pump.processHIDPPNotification(
        mappedNotification(controlID: MXErgoControl.upperThumb.rawValue),
        at: 2
    ) == [.desktopLeft])
    #expect(pump.processHIDPPNotification(
        mappedNotification(controlID: 0),
        at: 2.1
    ).isEmpty)
    #expect(pump.processHIDPPNotification(
        mappedNotification(controlID: MXErgoControl.wheelClick.rawValue),
        at: 3
    ).isEmpty)
}

@Test func mappedEventPumpRejectsPrecisionAndUnexpectedAdmission() {
    #expect(throws: MappedControlActionPlanError.precisionControlExcluded) {
        _ = try MappedControlEventPump(
            featureIndex: 0x0A,
            reviewedControlIDs: MappedControlActionPlan.controlIDs,
            admittedControlIDs: [MXErgoControl.precision.rawValue]
        )
    }
    #expect(throws: MappedControlActionPlanError.unexpectedMappedControl(0x00C8)) {
        _ = try MappedControlEventPump(
            featureIndex: 0x0A,
            reviewedControlIDs: MappedControlActionPlan.controlIDs,
            admittedControlIDs: [0x00C8]
        )
    }
    #expect(throws: MappedControlActionPlanError.missingMappedControl(0x0052)) {
        _ = try MappedControlEventDeliverySnapshot.makeUnauthorized(
            featureIndex: 0x0A,
            reviewedControlIDs: Array(MappedControlActionPlan.controlIDs.dropFirst())
        )
    }
}

@Test func mappedEventPumpAllFiveAdmittedMatchTheActionPlan() throws {
    let actions = try MappedControlActionPlan.make(
        reviewedControlIDs: MappedControlActionPlan.controlIDs
    )
    var pump = try MappedControlEventPump(
        featureIndex: 0x0A,
        reviewedControlIDs: MappedControlActionPlan.controlIDs,
        admittedControlIDs: Set(MappedControlActionPlan.controlIDs)
    )
    var timestamp: TimeInterval = 1
    for binding in actions.bindings {
        let intents = pump.processHIDPPNotification(
            mappedNotification(controlID: binding.control.rawValue),
            at: timestamp
        )
        #expect(intents == [binding.intent])
        _ = pump.processHIDPPNotification(mappedNotification(controlID: 0), at: timestamp + 0.1)
        timestamp += 1
    }
}

private func mappedNotification(controlID: UInt16) -> [UInt8] {
    [
        0x11, 0xFF, 0x0A, 0x00,
        UInt8(controlID >> 8), UInt8(controlID & 0xFF),
    ] + Array(repeating: 0, count: 14)
}
