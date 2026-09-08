import Foundation
import Testing
@testable import MXErgoHIDPP

private struct ConnectionVerificationFixture {
    let session: DeviceTransactionSession
    let info: [UInt8]
    let entities: [[UInt8]]

    init(count: UInt8 = 3) throws {
        info = [count, 1, 2, 3, 4, 0, 3, 0xB0, 0x1D, 0, 0, 0, 0, 1, 1, 0]
        entities = (0..<count).map { index in
            [index % 7, 77, 80, 77, 6, 3, 0, index + 1, 1, 0xB0, 0x1D, 0, 0, 0, 0, 0]
        }
        let deviceInfo = try HIDPP20DeviceInformation.decodeDeviceInfo(
            from: HIDPP20LongMessage(deviceIndex: 0, featureIndex: 9, functionID: 0,
                                    softwareID: 1, parameters: info), featureIndex: 9
        )
        let firmware = try entities.enumerated().map { index, parameters in
            try HIDPP20DeviceInformation.decodeFirmwareInfo(
                entityIndex: UInt8(index),
                from: HIDPP20LongMessage(deviceIndex: 0, featureIndex: 9, functionID: 1,
                                        softwareID: 1, parameters: parameters), featureIndex: 9
            )
        }
        let fingerprint = try HIDPP20FirmwareFingerprint(
            featureVersion: 1, deviceInfo: deviceInfo, entities: firmware
        )
        session = DeviceTransactionSession(
            device: JournalDeviceIdentity(deviceID: "read-only-sequence", vendorID: 0x046D,
                productID: 0xB01D, transport: "Bluetooth Low Energy", serialNumber: "fixture",
                locationID: 29, firmwareIdentity: fingerprint.canonicalIdentity),
            featureID: 0x1B04, featureVersion: 3, featureIndex: 7, connectionEpoch: 41
        )
    }

    func reply(to request: HIDPP20LongMessage, parameters: [UInt8]? = nil) throws -> HIDPP20LongMessage {
        let payload: [UInt8]
        if let parameters { payload = parameters }
        else if request.featureIndex == 0 {
            payload = request.parameters[0] == 0x1B ? [7, 0, 3] : [9, 0, 1]
        } else if request.functionID == 0 { payload = info }
        else { payload = entities[Int(request.parameters[0])] }
        return try HIDPP20LongMessage(deviceIndex: request.deviceIndex,
            featureIndex: request.featureIndex, functionID: request.functionID,
            softwareID: request.softwareID, parameters: payload)
    }
}

private func advance(_ sequence: inout PrecisionReadOnlyConnectionVerification,
                     fixture: ConnectionVerificationFixture, count: Int) throws {
    for _ in 0..<count {
        let request = try sequence.beginRequest()
        #expect(try sequence.observe(fixture.reply(to: request)))
    }
}

@Test func connectionVerificationCompletesWithUniqueReadOnlyKeysAtBothEntityBounds() throws {
    for count: UInt8 in [1, 3, 15] {
        let fixture = try ConnectionVerificationFixture(count: count)
        var sequence = try PrecisionReadOnlyConnectionVerification(expectedSession: fixture.session)
        var requests: [HIDPP20LongMessage] = []
        while sequence.observation == nil {
            let request = try sequence.beginRequest()
            requests.append(request)
            #expect(request.deviceIndex == 0)
            #expect(request.functionID <= 1)
            #expect(request.softwareID != 0)
            #expect(try sequence.observe(fixture.reply(to: request)))
        }
        let observation = try #require(sequence.observation)
        #expect(observation.firmware.canonicalIdentity == fixture.session.device.firmwareIdentity)
        #expect(observation.requestCount == Int(count) + 4)
        #expect(requests.count <= PrecisionReadOnlyConnectionVerification.maximumRequestCount)
        #expect(Set(requests.map(\.requestKey)).count == requests.count)
        #expect(requests.first?.softwareID == 1)
        #expect(requests.last?.softwareID == 3)
        #expect(throws: PrecisionConnectionVerificationError.alreadyFinished) {
            try sequence.beginRequest()
        }
    }
}

@Test func delayedFirmwareReplyCannotSatisfyTheNextEntityRequest() throws {
    let fixture = try ConnectionVerificationFixture()
    var sequence = try PrecisionReadOnlyConnectionVerification(expectedSession: fixture.session)
    try advance(&sequence, fixture: fixture, count: 3)
    let firstRequest = try sequence.beginRequest()
    let firstResponse = try fixture.reply(to: firstRequest)
    #expect(try sequence.observe(firstResponse))
    let secondRequest = try sequence.beginRequest()
    #expect(firstRequest.softwareID != secondRequest.softwareID)
    #expect(try sequence.observe(firstResponse) == false)
    #expect(sequence.observation == nil)
    #expect(try sequence.observe(fixture.reply(to: secondRequest)))
    try advance(&sequence, fixture: fixture, count: 2)
    #expect(sequence.observation?.firmware.canonicalIdentity == fixture.session.device.firmwareIdentity)
}

@Test func delayedRootReplyCannotSatisfyTheOtherRootQuery() throws {
    let fixture = try ConnectionVerificationFixture()
    var sequence = try PrecisionReadOnlyConnectionVerification(expectedSession: fixture.session)
    let first = try sequence.beginRequest()
    let response = try fixture.reply(to: first)
    #expect(try sequence.observe(response))
    let second = try sequence.beginRequest()
    #expect(try sequence.observe(response) == false)
    #expect(try sequence.observe(fixture.reply(to: second)))
}

@Test func sixteenEntitiesFailBeforeAnyFirmwareEntityRequestIsIssued() throws {
    let fixture = try ConnectionVerificationFixture(count: 16)
    var sequence = try PrecisionReadOnlyConnectionVerification(expectedSession: fixture.session)
    try advance(&sequence, fixture: fixture, count: 2)
    let request = try sequence.beginRequest()
    #expect(request.featureIndex == 9 && request.functionID == 0)
    #expect(throws: PrecisionConnectionVerificationError.unsupportedEntityCount(16)) {
        try sequence.observe(fixture.reply(to: request))
    }
    #expect(sequence.observation == nil)
    #expect(throws: PrecisionConnectionVerificationError.failed) { try sequence.beginRequest() }
}

@Test func changedInitialOrFinalRootTerminatesConnectionVerification() throws {
    let fixture = try ConnectionVerificationFixture()
    for final in [false, true] {
        for parameters: [UInt8] in [[8, 0, 3], [7, 0, 4]] {
            var sequence = try PrecisionReadOnlyConnectionVerification(expectedSession: fixture.session)
            if final { try advance(&sequence, fixture: fixture, count: 6) }
            let request = try sequence.beginRequest()
            #expect(throws: PrecisionConnectionVerificationError.featureChanged) {
                try sequence.observe(fixture.reply(to: request, parameters: parameters))
            }
            #expect(sequence.observation == nil)
            #expect(throws: PrecisionConnectionVerificationError.failed) { try sequence.beginRequest() }
        }
    }
}

@Test func finalRootMustMatchTheEntireInitialDescriptor() throws {
    let fixture = try ConnectionVerificationFixture()
    var sequence = try PrecisionReadOnlyConnectionVerification(expectedSession: fixture.session)
    try advance(&sequence, fixture: fixture, count: 6)
    let request = try sequence.beginRequest()
    #expect(throws: PrecisionConnectionVerificationError.featureChanged) {
        try sequence.observe(fixture.reply(to: request, parameters: [7, 1, 3]))
    }
    #expect(sequence.observation == nil)
}

@Test func unsupportedOrAliasedFirmwareFeatureFailsBeforeDeviceInfo() throws {
    let fixture = try ConnectionVerificationFixture()
    for index: UInt8 in [0, 7, 0xFF] {
        var sequence = try PrecisionReadOnlyConnectionVerification(expectedSession: fixture.session)
        try advance(&sequence, fixture: fixture, count: 1)
        let request = try sequence.beginRequest()
        #expect(throws: PrecisionConnectionVerificationError.unsupportedFirmwareFeature) {
            try sequence.observe(fixture.reply(to: request, parameters: [index, 0, 1]))
        }
        #expect(throws: PrecisionConnectionVerificationError.failed) { try sequence.beginRequest() }
    }
}

@Test func changedFirmwareNeverProducesAConnectionObservation() throws {
    let fixture = try ConnectionVerificationFixture()
    var sequence = try PrecisionReadOnlyConnectionVerification(expectedSession: fixture.session)
    try advance(&sequence, fixture: fixture, count: 3)
    let request = try sequence.beginRequest()
    var changed = fixture.entities[0]
    changed[7] ^= 1
    #expect(try sequence.observe(fixture.reply(to: request, parameters: changed)))
    try advance(&sequence, fixture: fixture, count: 2)
    let final = try sequence.beginRequest()
    #expect(throws: PrecisionConnectionVerificationError.firmwareChanged) {
        try sequence.observe(fixture.reply(to: final))
    }
    #expect(sequence.observation == nil)
    #expect(throws: PrecisionConnectionVerificationError.failed) { try sequence.beginRequest() }
}

@Test func correlatedProtocolErrorsAndEchoesAreTerminal() throws {
    let fixture = try ConnectionVerificationFixture()
    for protocolError in [false, true] {
        var sequence = try PrecisionReadOnlyConnectionVerification(expectedSession: fixture.session)
        let request = try sequence.beginRequest()
        if protocolError {
            let error = try HIDPP20LongMessage(bytes: [0x11, 0, 0xFF,
                request.featureIndex, request.address, 8] + Array(repeating: 0, count: 14))
            #expect(throws: PrecisionConnectionVerificationError.protocolError(8)) {
                try sequence.observe(error)
            }
        } else {
            #expect(throws: PrecisionConnectionVerificationError.echoedRequest) {
                try sequence.observe(request)
            }
        }
        #expect(throws: PrecisionConnectionVerificationError.failed) { try sequence.beginRequest() }
    }
}

@Test func malformedPacketsAndEntityCountsTerminateTheSequence() throws {
    let fixture = try ConnectionVerificationFixture()
    var malformed = try PrecisionReadOnlyConnectionVerification(expectedSession: fixture.session)
    _ = try malformed.beginRequest()
    #expect(throws: HIDPP20CodecError.invalidLength(expected: 20, actual: 1)) {
        try malformed.observe(bytes: [0x11])
    }
    #expect(throws: PrecisionConnectionVerificationError.failed) { try malformed.beginRequest() }
    for count: UInt8 in [0, 17] {
        var sequence = try PrecisionReadOnlyConnectionVerification(expectedSession: fixture.session)
        try advance(&sequence, fixture: fixture, count: 2)
        let request = try sequence.beginRequest()
        var info = fixture.info
        info[0] = count
        #expect(throws: HIDPP20CodecError.firmwareEntityCountOutOfRange(count)) {
            try sequence.observe(fixture.reply(to: request, parameters: info))
        }
        #expect(throws: PrecisionConnectionVerificationError.failed) { try sequence.beginRequest() }
    }
}

@Test func unrelatedInputIsBoundedWithoutAllowingAnotherPendingRequest() throws {
    let fixture = try ConnectionVerificationFixture()
    var sequence = try PrecisionReadOnlyConnectionVerification(expectedSession: fixture.session)
    _ = try sequence.beginRequest()
    #expect(throws: PrecisionConnectionVerificationError.requestAlreadyPending) {
        try sequence.beginRequest()
    }
    let foreign = try HIDPP20LongMessage(deviceIndex: 1, featureIndex: 0,
        functionID: 0, softwareID: 1, parameters: [7, 0, 3])
    for _ in 0..<PrecisionReadOnlyConnectionVerification.maximumCandidateCount {
        #expect(try sequence.observe(foreign) == false)
    }
    #expect(throws: PrecisionConnectionVerificationError.candidateLimitExceeded) {
        try sequence.observe(foreign)
    }
    #expect(throws: PrecisionConnectionVerificationError.failed) { try sequence.beginRequest() }
}

@Test func abortIsTerminalAtEveryStageIncludingAfterCompletion() throws {
    let fixture = try ConnectionVerificationFixture()
    for completed in 0...7 {
        var sequence = try PrecisionReadOnlyConnectionVerification(expectedSession: fixture.session)
        try advance(&sequence, fixture: fixture, count: completed)
        if completed < 7 { _ = try sequence.beginRequest() }
        sequence.abort()
        sequence.abort()
        #expect(sequence.observation == nil)
        #expect(throws: PrecisionConnectionVerificationError.failed) { try sequence.beginRequest() }
    }
}

@Test func connectionVerificationRejectsUnsupportedExpectedBindingsBeforeAnyRequest() throws {
    let fixture = try ConnectionVerificationFixture()
    for index: UInt8 in [0, 0xFF] {
        let session = DeviceTransactionSession(device: fixture.session.device,
            featureID: 0x1B04, featureVersion: 3, featureIndex: index, connectionEpoch: 41)
        #expect(throws: PrecisionConnectionVerificationError.invalidExpectedSession) {
            try PrecisionReadOnlyConnectionVerification(expectedSession: session)
        }
    }
    let wrongVersion = DeviceTransactionSession(device: fixture.session.device,
        featureID: 0x1B04, featureVersion: 4, featureIndex: 7, connectionEpoch: 41)
    #expect(throws: PrecisionConnectionVerificationError.invalidExpectedSession) {
        try PrecisionReadOnlyConnectionVerification(expectedSession: wrongVersion)
    }
}

@Test func connectionVerificationRemainsPackageOnlyAndUnwiredToOutput() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sourceURL = packageRoot.appendingPathComponent(
        "Sources/MXErgoHIDPP/PrecisionReadOnlyConnectionVerification.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    for token in ["public ", "import IOKit", "IOHIDDeviceSetReport", "CGEvent",
                  "FileManager", "UserDefaults", "PrecisionTransportFactory", "Codable"] {
        #expect(!source.contains(token))
    }
    let sources = try #require(FileManager.default.enumerator(
        at: packageRoot.appendingPathComponent("Sources"), includingPropertiesForKeys: nil))
    for case let file as URL in sources where file.pathExtension == "swift" && file != sourceURL {
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("PrecisionReadOnlyConnectionVerification"))
    }
}
