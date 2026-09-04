import Foundation
import Testing
@testable import MXErgoHIDPP

@Test func mappedPreflightBuildsFiveUnauthorizedGetPackets() throws {
    let journal = try mappedJournal()
    let diversion = try MappedControlsTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: journal.feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let preflight = try MappedControlsReadOnlyPreflightPlan.make(from: diversion)

    #expect(preflight.authorization == .notAuthorizedForExecution)
    #expect(MappedControlsReadOnlyPreflightPlan.maximumPacketCount == 5)
    #expect(preflight.controls.map(\.controlID) == [
        0x0052, 0x0053, 0x0056, 0x005B, 0x005D,
    ])
    #expect(!preflight.controls.contains { $0.controlID == 0x00ED })
    #expect(preflight.featureIndex == 0x0A)
    #expect(preflight.featureVersion == 3)

    let wheel = try preflight.preflight(for: 0x0052)
    #expect(wheel.verificationRequest == (try diversion.plan(for: 0x0052)).verificationRequest)
    #expect(wheel.verificationRequest.functionID == 2)
    #expect(wheel.verificationRequest.bytes == mappedPacket(
        address: 0x2E,
        parameters: [0x00, 0x52]
    ))
    #expect(wheel.baseline.rawFlags(featureVersion: 3) == 0)
}

@Test func mappedPreflightAcceptsExactBaselineAndRejectsDrift() throws {
    let journal = try mappedJournal()
    let diversion = try MappedControlsTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: journal.feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let preflight = try MappedControlsReadOnlyPreflightPlan.make(from: diversion)
    let wheel = try preflight.preflight(for: 0x0052)
    let exact = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: preflight.featureIndex,
        functionID: 2,
        softwareID: 0x0E,
        parameters: wheel.baseline.rawParameters
    )
    #expect(try wheel.evaluateResponse(
        exact,
        featureIndex: preflight.featureIndex,
        featureVersion: preflight.featureVersion
    ) == wheel.baseline)

    var drifted = wheel.baseline.rawParameters
    drifted[2] = 0x01
    let dirty = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: preflight.featureIndex,
        functionID: 2,
        softwareID: 0x0E,
        parameters: drifted
    )
    #expect(throws: MappedControlReadOnlyPreflightError.baselineMismatch(0x0052)) {
        _ = try wheel.evaluateResponse(
            dirty,
            featureIndex: preflight.featureIndex,
            featureVersion: preflight.featureVersion
        )
    }
}

@Test func mappedPreflightRejectsSetShapedAndWrongControlResponses() throws {
    let journal = try mappedJournal()
    let diversion = try MappedControlsTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: journal.feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let preflight = try MappedControlsReadOnlyPreflightPlan.make(from: diversion)
    let wheel = try preflight.preflight(for: 0x0052)
    let apply = try diversion.plan(for: 0x0052).applySetRequest
    #expect(throws: HIDPP20CodecError.self) {
        _ = try wheel.decodeResponse(
            apply,
            featureIndex: preflight.featureIndex,
            featureVersion: preflight.featureVersion
        )
    }

    let thumb = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: preflight.featureIndex,
        functionID: 2,
        softwareID: 0x0E,
        parameters: mappedPadded([0x00, 0x53, 0x00, 0x00, 0x00])
    )
    #expect(throws: HIDPP20CodecError.responseControlMismatch(
        expected: 0x0052,
        actual: 0x0053
    )) {
        _ = try wheel.decodeResponse(
            thumb,
            featureIndex: preflight.featureIndex,
            featureVersion: preflight.featureVersion
        )
    }
}

@Test func mappedPreflightSequenceCompletesFiveGetsWithoutSET() throws {
    let preflight = try mappedPreflightPlan()
    var sequence = MappedControlReadOnlyPreflightSequence(plan: preflight)
    for control in preflight.controls {
        let request = try sequence.nextRequest()
        #expect(request.functionID == 2)
        #expect(request == control.verificationRequest)
        let response = try HIDPP20LongMessage(
            deviceIndex: request.deviceIndex,
            featureIndex: preflight.featureIndex,
            functionID: 2,
            softwareID: request.softwareID,
            parameters: control.baseline.rawParameters
        )
        let observation = try sequence.observe(response)
        #expect(observation.controlID == control.controlID)
        #expect(observation.state == control.baseline)
    }
    #expect(sequence.isComplete)
    #expect(sequence.authorization == .notAuthorizedForExecution)
    #expect(sequence.observations.count == 5)
    #expect(throws: MappedControlReadOnlyPreflightError.sequenceAlreadyComplete) {
        _ = try sequence.nextRequest()
    }
}

@Test func mappedPreflightSequenceStopsAfterFirstDriftAndNeverRetries() throws {
    let preflight = try mappedPreflightPlan()
    var sequence = MappedControlReadOnlyPreflightSequence(plan: preflight)
    let first = preflight.controls[0]
    let firstResponse = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: preflight.featureIndex,
        functionID: 2,
        softwareID: 0x0E,
        parameters: first.baseline.rawParameters
    )
    _ = try sequence.observe(firstResponse)

    var drifted = preflight.controls[1].baseline.rawParameters
    drifted[2] = 0x01
    let dirty = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: preflight.featureIndex,
        functionID: 2,
        softwareID: 0x0E,
        parameters: drifted
    )
    #expect(throws: MappedControlReadOnlyPreflightError.baselineMismatch(
        preflight.controls[1].controlID
    )) {
        _ = try sequence.observe(dirty)
    }
    #expect(sequence.failedControlID == preflight.controls[1].controlID)
    #expect(!sequence.isComplete)
    #expect(sequence.observations.count == 1)
    #expect(throws: MappedControlReadOnlyPreflightError.sequenceAlreadyFailed) {
        _ = try sequence.nextRequest()
    }
}

private func mappedPreflightPlan() throws -> MappedControlsReadOnlyPreflightPlan {
    let journal = try mappedJournal()
    let diversion = try MappedControlsTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: journal.feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    return try MappedControlsReadOnlyPreflightPlan.make(from: diversion)
}
