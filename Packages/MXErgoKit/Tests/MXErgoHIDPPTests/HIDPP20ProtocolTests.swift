import Foundation
import Testing
@testable import MXErgoHIDPP

@Test func longMessageEncodesTheHIDPP20HeaderAndPadsParameters() throws {
    let message = try HIDPP20LongMessage(
        deviceIndex: 0x00,
        featureIndex: 0x0B,
        functionID: 0x02,
        softwareID: 0x0E,
        parameters: [0x00, 0xED]
    )

    #expect(message.bytes.count == 20)
    #expect(Array(message.bytes.prefix(6)) == [0x11, 0x00, 0x0B, 0x2E, 0x00, 0xED])
    #expect(message.bytes.suffix(14).allSatisfy { $0 == 0 })
    #expect(try HIDPP20LongMessage(bytes: message.bytes) == message)
}

@Test func requestMessagesRequireANonzeroSoftwareID() {
    #expect(throws: HIDPP20CodecError.softwareIDMustBeNonzero) {
        try HIDPP20LongMessage(
            deviceIndex: 0,
            featureIndex: 0,
            functionID: 0,
            softwareID: 0
        )
    }
}

@Test func rootFeatureRequestMatchesKnownWireShape() throws {
    let request = try HIDPP20Root.getFeatureRequest(
        ReprogControlsV4.featureID,
        deviceIndex: 0xFF,
        softwareID: 0x08
    )

    #expect(Array(request.bytes.prefix(6)) == [0x11, 0xFF, 0x00, 0x08, 0x1B, 0x04])
}

@Test func deviceInformationReadOnlyRequestsAndDecodersMatchWireShape() throws {
    let infoRequest = try HIDPP20DeviceInformation.getDeviceInfoRequest(
        featureIndex: 0x02,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    #expect(Array(infoRequest.bytes.prefix(4)) == [0x11, 0x00, 0x02, 0x0E])

    let infoResponse = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: 0x02,
        functionID: 0,
        softwareID: 0x0E,
        parameters: [
            0x02, 0x01, 0x02, 0x03, 0x04, 0x00, 0x02,
            0xB0, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        ]
    )
    let info = try HIDPP20DeviceInformation.decodeDeviceInfo(
        from: infoResponse,
        featureIndex: 0x02
    )
    #expect(info.entityCount == 2)
    #expect(info.unitID == [1, 2, 3, 4])
    #expect(info.transportFlags == 0x02)
    #expect(info.modelIDs == [0xB01D, 0, 0])
    #expect(info.extendedModelID == 1)
    #expect(!info.supportsSerialNumber)

    let firmwareRequest = try HIDPP20DeviceInformation.getFirmwareInfoRequest(
        entityIndex: 1,
        featureIndex: 0x02,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    #expect(Array(firmwareRequest.bytes.prefix(5)) == [0x11, 0x00, 0x02, 0x1E, 0x01])

    let firmwareResponse = try firmwareResponse(
        buildLow: 0x34,
        active: 1,
        transportPID: 0xB01D
    )
    let entity = try HIDPP20DeviceInformation.decodeFirmwareInfo(
        entityIndex: 0,
        from: firmwareResponse,
        featureIndex: 0x02
    )
    #expect(entity.type == .mainApplication)
    #expect(entity.prefix == "MPL")
    #expect(entity.number == 1)
    #expect(entity.revision == 2)
    #expect(entity.build == 34)
    #expect(entity.isActive)
    #expect(entity.transportPID == 0xB01D)
    #expect(entity.versionDescription == "MPL 01.02.B0034")
}

@Test func firmwareDecodingRejectsUnboundedCountsAndPreservesOpaqueVersions() throws {
    let zeroCount = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: 2,
        functionID: 0,
        softwareID: 0x0E,
        parameters: [0]
    )
    #expect(throws: HIDPP20CodecError.firmwareEntityCountOutOfRange(0)) {
        try HIDPP20DeviceInformation.decodeDeviceInfo(from: zeroCount, featureIndex: 2)
    }
    #expect(throws: HIDPP20CodecError.firmwareEntityIndexOutOfRange(16)) {
        try HIDPP20DeviceInformation.getFirmwareInfoRequest(
            entityIndex: 16,
            featureIndex: 2,
            deviceIndex: 0,
            softwareID: 0x0E
        )
    }

    let opaque = try HIDPP20DeviceInformation.decodeFirmwareInfo(
        entityIndex: 2,
        from: firmwareResponse(
            buildLow: 0x5A,
            active: 0,
            transportPID: 0,
            type: 5,
            prefix: [0, 0, 0]
        ),
        featureIndex: 2
    )
    #expect(opaque.type == .softDevice)
    #expect(opaque.number == 1)
    #expect(opaque.revision == 2)
    #expect(opaque.build == nil)
    #expect(opaque.versionDescription == "??? raw 01.02.005A")
}

@Test func firmwareFingerprintExcludesTransientActiveAndTransportFields() throws {
    let infoResponse = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: 2,
        functionID: 0,
        softwareID: 0x0E,
        parameters: [
            0x01, 0x01, 0x02, 0x03, 0x04, 0x00, 0x02,
            0xB0, 0x1D, 0, 0, 0, 0, 0x01, 0, 0,
        ]
    )
    let info = try HIDPP20DeviceInformation.decodeDeviceInfo(from: infoResponse, featureIndex: 2)
    let active = try HIDPP20DeviceInformation.decodeFirmwareInfo(
        entityIndex: 0,
        from: firmwareResponse(buildLow: 0x34, active: 1, transportPID: 0xB01D),
        featureIndex: 2
    )
    let inactive = try HIDPP20DeviceInformation.decodeFirmwareInfo(
        entityIndex: 0,
        from: firmwareResponse(buildLow: 0x34, active: 0, transportPID: 0),
        featureIndex: 2
    )
    let updated = try HIDPP20DeviceInformation.decodeFirmwareInfo(
        entityIndex: 0,
        from: firmwareResponse(buildLow: 0x35, active: 1, transportPID: 0xB01D),
        featureIndex: 2
    )

    let first = try HIDPP20FirmwareFingerprint(
        featureVersion: 2,
        deviceInfo: info,
        entities: [active]
    )
    let second = try HIDPP20FirmwareFingerprint(
        featureVersion: 2,
        deviceInfo: info,
        entities: [inactive]
    )
    let changed = try HIDPP20FirmwareFingerprint(
        featureVersion: 2,
        deviceInfo: info,
        entities: [updated]
    )
    #expect(first.canonicalIdentity == second.canonicalIdentity)
    #expect(first.canonicalIdentity != changed.canonicalIdentity)
}

@Test func readOnlyControlEnumerationRequestsAndDecodersMatchWireShape() throws {
    let countRequest = try ReprogControlsV4.getCountRequest(
        featureIndex: 0x0A,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    #expect(Array(countRequest.bytes.prefix(4)) == [0x11, 0x00, 0x0A, 0x0E])

    let countResponse = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: 0x0A,
        functionID: 0,
        softwareID: 0x0E,
        parameters: [0x08]
    )
    #expect(try ReprogControlsV4.decodeCount(
        from: countResponse,
        featureIndex: 0x0A
    ) == 8)

    let infoRequest = try ReprogControlsV4.getControlInfoRequest(
        index: 3,
        featureIndex: 0x0A,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    #expect(Array(infoRequest.bytes.prefix(5)) == [0x11, 0x00, 0x0A, 0x1E, 0x03])

    let infoResponse = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: 0x0A,
        functionID: 1,
        softwareID: 0x0E,
        parameters: [0x00, 0xED, 0x00, 0xED, 0x30, 0x02, 0x01, 0x03, 0x01]
    )
    let info = try ReprogControlsV4.decodeControlInfo(
        index: 3,
        from: infoResponse,
        featureIndex: 0x0A
    )
    #expect(info.index == 3)
    #expect(info.controlID == 0x00ED)
    #expect(info.taskID == 0x00ED)
    #expect(info.capabilityFlags == 0x30)
    #expect(info.position == 2)
    #expect(info.group == 1)
    #expect(info.groupMask == 3)
    #expect(info.rawXYCapability)
    #expect(info.rawParameters == infoResponse.parameters)
}

@Test func readOnlyControlEnumerationRejectsImpossibleControlCounts() throws {
    let response = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: 0x0A,
        functionID: 0,
        softwareID: 0x0E,
        parameters: [0]
    )

    #expect(throws: HIDPP20CodecError.controlCountOutOfRange(0)) {
        try ReprogControlsV4.decodeCount(from: response, featureIndex: 0x0A)
    }
}

@Test func reprogQueriesAndResponsesPreserveAllReportingBits() throws {
    let reportingRequest = try ReprogControlsV4.getReportingRequest(
        controlID: 0x00ED,
        featureIndex: 0x0B,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    #expect(Array(reportingRequest.bytes.prefix(6)) == [0x11, 0x00, 0x0B, 0x2E, 0x00, 0xED])

    let response = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: 0x0B,
        functionID: 2,
        softwareID: 0x0E,
        parameters: [0x00, 0xED, 0x15, 0x00, 0x00, 0x04]
    )
    let state = try ReprogControlsV4.decodeReporting(
        requestedControlID: 0x00ED,
        from: response,
        featureIndex: 0x0B,
        featureVersion: 4
    )
    #expect(state.controlID == 0x00ED)
    #expect(state.rawFlags == 0x0415)
    #expect(state.rawMappedControlID == 0)
    #expect(state.effectiveMappedControlID == 0x00ED)
    #expect(state.isTemporarilyDiverted)
    #expect(state.isPersistentlyDiverted)
    #expect(state.isRawXYDiverted)
}

@Test func versionThreeReportingSnapshotUsesTheDocumentedSingleFlagByte() throws {
    let request = try ReprogControlsV4.getReportingRequest(
        controlID: 0x00ED,
        featureIndex: 0x0A,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    #expect(Array(request.bytes.prefix(6)) == [0x11, 0x00, 0x0A, 0x2E, 0x00, 0xED])

    let response = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: 0x0A,
        functionID: 2,
        softwareID: 0x0E,
        parameters: [0x00, 0xED, 0x05, 0x00, 0x53, 0xA5]
    )
    let state = try ReprogControlsV4.decodeReporting(
        requestedControlID: 0x00ED,
        from: response,
        featureIndex: 0x0A,
        featureVersion: 3
    )

    #expect(state.rawFlags == 0x0005)
    #expect(state.rawMappedControlID == 0x0053)
    #expect(state.rawParameters == response.parameters)
}

@Test func requestCorrelatorMatchesNormalAndErrorReplies() throws {
    let request = try ReprogControlsV4.getCountRequest(
        featureIndex: 0x0B,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let requestID = UUID()
    var correlator = HIDPP20RequestCorrelator(connectionEpoch: 4)
    try correlator.register(request, connectionEpoch: 4, id: requestID)

    let unrelated = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: 0x0B,
        functionID: 0,
        softwareID: 0x02
    )
    #expect(correlator.consume(unrelated, connectionEpoch: 4) == nil)
    #expect(correlator.hasPendingRequest)

    let errorMessage = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: 0xFF,
        functionID: 0,
        softwareID: 0x0B,
        parameters: [0x0E, HIDPP20ProtocolErrorCode.busy.rawValue],
        requireRequestSoftwareID: false
    )
    let result = correlator.consume(errorMessage, connectionEpoch: 4)
    guard case let .protocolError(id, error) = result else {
        Issue.record("Expected the HID++ error to correlate")
        return
    }
    #expect(id == requestID)
    #expect(error.code == .busy)
    #expect(error.rawMessageBytes == errorMessage.bytes)
    #expect(!correlator.hasPendingRequest)
}

@Test func timeoutPoisonsTheEpochUntilDisconnect() throws {
    let request = try HIDPP20Root.getFeatureRequest(
        ReprogControlsV4.featureID,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let requestID = UUID()
    var correlator = HIDPP20RequestCorrelator(connectionEpoch: 10)
    try correlator.register(request, connectionEpoch: 10, id: requestID)
    correlator.timeout(id: requestID, connectionEpoch: 10)

    #expect(correlator.isConnectionEpochPoisoned)
    #expect(throws: HIDPP20RequestCorrelationError.connectionEpochPoisoned(10)) {
        try correlator.register(request, connectionEpoch: 10)
    }

    correlator.disconnected()
    #expect(correlator.connectionEpoch == 11)
    #expect(!correlator.isConnectionEpochPoisoned)
    #expect(throws: HIDPP20RequestCorrelationError.invalidConnectionEpoch(expected: 11, actual: 10)) {
        try correlator.register(request, connectionEpoch: 10)
    }
}

@Test func correlatorAllowsOnlyOneInflightRequest() throws {
    let first = try HIDPP20Root.getFeatureRequest(
        ReprogControlsV4.featureID,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let second = try ReprogControlsV4.getCountRequest(
        featureIndex: 0x0B,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    var correlator = HIDPP20RequestCorrelator()
    try correlator.register(first, connectionEpoch: 0)

    #expect(throws: HIDPP20RequestCorrelationError.requestAlreadyPending) {
        try correlator.register(second, connectionEpoch: 0)
    }
}

@Test func reportingResponseMustEchoTheRequestedControl() throws {
    let response = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: 0x0B,
        functionID: 2,
        softwareID: 0x0E,
        parameters: [0x00, 0x53, 0, 0, 0, 0]
    )

    #expect(throws: HIDPP20CodecError.responseControlMismatch(expected: 0x00ED, actual: 0x0053)) {
        try ReprogControlsV4.decodeReporting(
            requestedControlID: 0x00ED,
            from: response,
            featureIndex: 0x0B,
            featureVersion: 4
        )
    }
}

private func firmwareResponse(
    buildLow: UInt8,
    active: UInt8,
    transportPID: UInt16,
    type: UInt8 = 0,
    prefix: [UInt8] = [0x4D, 0x50, 0x4C]
) throws -> HIDPP20LongMessage {
    precondition(prefix.count == 3)
    return try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: 2,
        functionID: 1,
        softwareID: 0x0E,
        parameters: [
            type, prefix[0], prefix[1], prefix[2], 0x01, 0x02, 0x00, buildLow,
            active,
            UInt8(transportPID >> 8), UInt8(transportPID & 0xFF),
            0x00, 0x00, 0x00, 0x00, 0x00,
        ]
    )
}
