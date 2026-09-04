import Foundation
@preconcurrency import IOKit
import MXErgoHIDPP
import Testing
@testable import MXErgoRestoreTrialIOHID

@Test func dormantAdapterAcceptsTheCorrelatorInitialEpochZero() async throws {
    let original = dormantSession()
    let session = RestoreOnlyHardwareTrialSession(
        device: original.device,
        featureIndex: original.featureIndex,
        featureVersion: original.featureVersion,
        connectionEpoch: 0,
        matchingDeviceCount: original.matchingDeviceCount,
        outputReportByteCount: original.outputReportByteCount
    )
    let writer = DormantWriterProbe(results: [kIOReturnSuccess])
    let adapter = try DormantPrecisionTrialIOHIDAdapter(
        session: session,
        writer: writer.write
    )

    _ = try await adapter.beginSet(
        request: dormantSetRequest(session),
        expectedSession: session
    )
    #expect(writer.requests.count == 1)
}

@Test func dormantAdapterCompletesExactSetAckAndIndependentVerification() async throws {
    let session = dormantSession()
    let writer = DormantWriterProbe(results: [kIOReturnSuccess, kIOReturnSuccess])
    let adapter = try DormantPrecisionTrialIOHIDAdapter(
        session: session,
        writer: writer.write
    )
    let set = try dormantSetRequest(session)
    let setID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    let setReceipt = try await adapter.beginSet(
        request: set,
        expectedSession: session,
        requestID: setID
    )
    #expect(setReceipt.requestID == setID)
    #expect(setReceipt.kind == .setTemporaryDiversionOff)
    #expect(setReceipt.requestBytes == set.bytes)
    #expect(setReceipt.ioReturn == Int32(kIOReturnSuccess))
    #expect(setReceipt.classification == .mayHaveDispatched)
    #expect(await adapter.status == .awaitingSetAcknowledgement)
    #expect(writer.requests == [set.bytes])

    #expect(await adapter.consumeInputReport(
        set.bytes,
        device: session.device,
        connectionEpoch: session.connectionEpoch
    ) == .exactSetAcknowledgement(requestID: setID))
    #expect(await adapter.status == .setAcknowledged)

    let get = try dormantVerificationRequest(session)
    let getID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let getReceipt = try await adapter.beginVerification(
        request: get,
        expectedSession: session,
        requestID: getID
    )
    #expect(getReceipt.kind == .getReportingVerification)
    #expect(getReceipt.requestBytes == get.bytes)
    #expect(writer.requests == [set.bytes, get.bytes])

    let response = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: session.featureIndex,
        functionID: 2,
        softwareID: 0x0E,
        parameters: [0x00, 0xED, 0x00, 0x00, 0x00]
    )
    let result = await adapter.consumeInputReport(
        response.bytes,
        device: session.device,
        connectionEpoch: session.connectionEpoch
    )
    guard case let .verification(requestID, state) = result else {
        Issue.record("Expected exact verification result")
        return
    }
    #expect(requestID == getID)
    #expect(state.rawParameters == response.parameters)
    #expect(await adapter.status == .terminalVerified)
}

@Test func dormantAdapterRejectsEveryCallerSelectedSetMutationBeforeIOHID() async throws {
    let session = dormantSession()
    let exact = try dormantSetRequest(session)

    for byteIndex in exact.bytes.indices {
        if byteIndex == 2 { continue } // Dynamic feature index is session-bound below.
        var mutatedBytes = exact.bytes
        mutatedBytes[byteIndex] ^= 0x01
        guard let mutated = try? HIDPP20LongMessage(bytes: mutatedBytes) else { continue }
        let writer = DormantWriterProbe(results: [kIOReturnSuccess])
        let adapter = try DormantPrecisionTrialIOHIDAdapter(
            session: session,
            writer: writer.write
        )
        await #expect(throws: DormantPrecisionTrialIOHIDError.invalidSetRequest) {
            try await adapter.beginSet(request: mutated, expectedSession: session)
        }
        #expect(writer.requests.isEmpty)
        #expect(await adapter.status == .ready)
    }

    var wrongFeatureBytes = exact.bytes
    wrongFeatureBytes[2] = session.featureIndex &+ 1
    let wrongFeature = try HIDPP20LongMessage(bytes: wrongFeatureBytes)
    let writer = DormantWriterProbe(results: [kIOReturnSuccess])
    let adapter = try DormantPrecisionTrialIOHIDAdapter(
        session: session,
        writer: writer.write
    )
    await #expect(throws: DormantPrecisionTrialIOHIDError.invalidSetRequest) {
        try await adapter.beginSet(request: wrongFeature, expectedSession: session)
    }
    #expect(writer.requests.isEmpty)
}

@Test func dormantAdapterTreatsEveryIOHIDReturnAsPotentiallyDispatchedAndNeverRetries() async throws {
    let session = dormantSession()
    let writer = DormantWriterProbe(results: [kIOReturnNoDevice])
    let adapter = try DormantPrecisionTrialIOHIDAdapter(
        session: session,
        writer: writer.write
    )
    let set = try dormantSetRequest(session)
    let receipt = try await adapter.beginSet(
        request: set,
        expectedSession: session
    )

    #expect(receipt.ioReturn == Int32(kIOReturnNoDevice))
    #expect(receipt.classification == .mayHaveDispatched)
    #expect(await adapter.status == .terminalUnknown)
    await #expect(throws: DormantPrecisionTrialIOHIDError.setAlreadyAttempted) {
        try await adapter.beginSet(request: set, expectedSession: session)
    }
    #expect(writer.requests.count == 1)
    #expect(await adapter.consumeInputReport(
        set.bytes,
        device: session.device,
        connectionEpoch: session.connectionEpoch
    ) == .ignored)
}

@Test func dormantAdapterIgnoresWrongDeviceEpochAndRequestAddress() async throws {
    let session = dormantSession()
    let writer = DormantWriterProbe(results: [kIOReturnSuccess])
    let adapter = try DormantPrecisionTrialIOHIDAdapter(
        session: session,
        writer: writer.write
    )
    let set = try dormantSetRequest(session)
    let requestID = UUID()
    _ = try await adapter.beginSet(
        request: set,
        expectedSession: session,
        requestID: requestID
    )

    #expect(await adapter.consumeInputReport(
        set.bytes,
        device: dormantOtherDevice(session.device),
        connectionEpoch: session.connectionEpoch
    ) == .ignored)
    #expect(await adapter.consumeInputReport(
        set.bytes,
        device: session.device,
        connectionEpoch: session.connectionEpoch &+ 1
    ) == .ignored)
    let wrongAddress = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: session.featureIndex,
        functionID: 3,
        softwareID: 0x0D,
        parameters: [0x00, 0xED, 0x02, 0x00, 0x00]
    )
    #expect(await adapter.consumeInputReport(
        wrongAddress.bytes,
        device: session.device,
        connectionEpoch: session.connectionEpoch
    ) == .ignored)
    #expect(await adapter.status == .awaitingSetAcknowledgement)

    #expect(await adapter.consumeInputReport(
        set.bytes,
        device: session.device,
        connectionEpoch: session.connectionEpoch
    ) == .exactSetAcknowledgement(requestID: requestID))
}

@Test func dormantAdapterMakesSameAddressWrongPayloadTerminalUnknown() async throws {
    let session = dormantSession()
    let writer = DormantWriterProbe(results: [kIOReturnSuccess])
    let adapter = try DormantPrecisionTrialIOHIDAdapter(
        session: session,
        writer: writer.write
    )
    let set = try dormantSetRequest(session)
    let requestID = UUID()
    _ = try await adapter.beginSet(
        request: set,
        expectedSession: session,
        requestID: requestID
    )
    var wrongPayload = set.bytes
    wrongPayload[8] = 1

    #expect(await adapter.consumeInputReport(
        wrongPayload,
        device: session.device,
        connectionEpoch: session.connectionEpoch
    ) == .acknowledgementMismatch(
        requestID: requestID,
        responseBytes: wrongPayload
    ))
    #expect(await adapter.status == .terminalUnknown)
    await #expect(throws: DormantPrecisionTrialIOHIDError.invalidPhase) {
        try await adapter.beginVerification(
            request: dormantVerificationRequest(session),
            expectedSession: session
        )
    }
}

@Test func dormantAdapterPoisonsTimedOutEpochAndRejectsLateAcknowledgement() async throws {
    let session = dormantSession()
    let writer = DormantWriterProbe(results: [kIOReturnSuccess])
    let adapter = try DormantPrecisionTrialIOHIDAdapter(
        session: session,
        writer: writer.write
    )
    let set = try dormantSetRequest(session)
    let requestID = UUID()
    _ = try await adapter.beginSet(
        request: set,
        expectedSession: session,
        requestID: requestID
    )
    await adapter.timeout(
        requestID: requestID,
        connectionEpoch: session.connectionEpoch
    )

    #expect(await adapter.status == .terminalUnknown)
    #expect(await adapter.consumeInputReport(
        set.bytes,
        device: session.device,
        connectionEpoch: session.connectionEpoch
    ) == .ignored)
    await #expect(throws: DormantPrecisionTrialIOHIDError.invalidPhase) {
        try await adapter.beginVerification(
            request: dormantVerificationRequest(session),
            expectedSession: session
        )
    }
}

@Test func dormantAdapterClassifiesCorrelatedProtocolErrorAsTerminalUnknown() async throws {
    let session = dormantSession()
    let writer = DormantWriterProbe(results: [kIOReturnSuccess])
    let adapter = try DormantPrecisionTrialIOHIDAdapter(
        session: session,
        writer: writer.write
    )
    let set = try dormantSetRequest(session)
    let requestID = UUID()
    _ = try await adapter.beginSet(
        request: set,
        expectedSession: session,
        requestID: requestID
    )
    let error = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: 0xFF,
        functionID: 0,
        softwareID: session.featureIndex,
        parameters: [set.address, HIDPP20ProtocolErrorCode.busy.rawValue],
        requireRequestSoftwareID: false
    )

    #expect(await adapter.consumeInputReport(
        error.bytes,
        device: session.device,
        connectionEpoch: session.connectionEpoch
    ) == .protocolError(
        requestID: requestID,
        rawCode: HIDPP20ProtocolErrorCode.busy.rawValue
    ))
    #expect(await adapter.status == .terminalUnknown)
}

@Test func dormantAdapterDisconnectInvalidatesTheOnlyAttempt() async throws {
    let session = dormantSession()
    let writer = DormantWriterProbe(results: [kIOReturnSuccess])
    let adapter = try DormantPrecisionTrialIOHIDAdapter(
        session: session,
        writer: writer.write
    )
    let set = try dormantSetRequest(session)
    _ = try await adapter.beginSet(request: set, expectedSession: session)
    await adapter.disconnected()

    #expect(await adapter.status == .terminalUnknown)
    #expect(await adapter.consumeInputReport(
        set.bytes,
        device: session.device,
        connectionEpoch: session.connectionEpoch
    ) == .ignored)
    await #expect(throws: DormantPrecisionTrialIOHIDError.setAlreadyAttempted) {
        try await adapter.beginSet(request: set, expectedSession: session)
    }
}

@Test func dormantAdapterRejectsChangedSessionAndVerificationBytesBeforeIOHID() async throws {
    let session = dormantSession()
    let writer = DormantWriterProbe(results: [kIOReturnSuccess, kIOReturnSuccess])
    let adapter = try DormantPrecisionTrialIOHIDAdapter(
        session: session,
        writer: writer.write
    )
    let changedSession = RestoreOnlyHardwareTrialSession(
        device: dormantOtherDevice(session.device),
        featureIndex: session.featureIndex,
        featureVersion: session.featureVersion,
        connectionEpoch: session.connectionEpoch,
        matchingDeviceCount: session.matchingDeviceCount,
        outputReportByteCount: session.outputReportByteCount
    )
    await #expect(throws: DormantPrecisionTrialIOHIDError.invalidSession) {
        try await adapter.beginSet(
            request: dormantSetRequest(session),
            expectedSession: changedSession
        )
    }
    #expect(writer.requests.isEmpty)

    let set = try dormantSetRequest(session)
    _ = try await adapter.beginSet(request: set, expectedSession: session)
    _ = await adapter.consumeInputReport(
        set.bytes,
        device: session.device,
        connectionEpoch: session.connectionEpoch
    )
    var changedGetBytes = try dormantVerificationRequest(session).bytes
    changedGetBytes[5] = 0x01
    let changedGet = try HIDPP20LongMessage(bytes: changedGetBytes)
    await #expect(throws: DormantPrecisionTrialIOHIDError.invalidVerificationRequest) {
        try await adapter.beginVerification(
            request: changedGet,
            expectedSession: session
        )
    }
    #expect(writer.requests == [set.bytes])
    #expect(await adapter.status == .setAcknowledged)
}

@Test func dormantAdapterTreatsVerificationIOReturnAsPotentiallyDispatched() async throws {
    let session = dormantSession()
    let writer = DormantWriterProbe(results: [kIOReturnSuccess, kIOReturnNoDevice])
    let adapter = try DormantPrecisionTrialIOHIDAdapter(
        session: session,
        writer: writer.write
    )
    let set = try dormantSetRequest(session)
    _ = try await adapter.beginSet(request: set, expectedSession: session)
    _ = await adapter.consumeInputReport(
        set.bytes,
        device: session.device,
        connectionEpoch: session.connectionEpoch
    )

    let get = try dormantVerificationRequest(session)
    let receipt = try await adapter.beginVerification(
        request: get,
        expectedSession: session
    )
    #expect(receipt.ioReturn == Int32(kIOReturnNoDevice))
    #expect(receipt.classification == .mayHaveDispatched)
    #expect(writer.requests == [set.bytes, get.bytes])
    #expect(await adapter.status == .terminalUnknown)
}

@Test func dormantAdapterRejectsCorrelatedVerificationForTheWrongControl() async throws {
    let session = dormantSession()
    let writer = DormantWriterProbe(results: [kIOReturnSuccess, kIOReturnSuccess])
    let adapter = try DormantPrecisionTrialIOHIDAdapter(
        session: session,
        writer: writer.write
    )
    let set = try dormantSetRequest(session)
    _ = try await adapter.beginSet(request: set, expectedSession: session)
    _ = await adapter.consumeInputReport(
        set.bytes,
        device: session.device,
        connectionEpoch: session.connectionEpoch
    )
    let getID = UUID()
    _ = try await adapter.beginVerification(
        request: dormantVerificationRequest(session),
        expectedSession: session,
        requestID: getID
    )
    let wrongControl = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: session.featureIndex,
        functionID: 2,
        softwareID: 0x0E,
        parameters: [0x00, 0x50, 0x00, 0x00, 0x00]
    )

    #expect(await adapter.consumeInputReport(
        wrongControl.bytes,
        device: session.device,
        connectionEpoch: session.connectionEpoch
    ) == .verificationRejected(requestID: getID))
    #expect(await adapter.status == .terminalUnknown)
}

@Test func dormantAdapterPoisonsVerificationTimeoutAndIgnoresLateResponse() async throws {
    let session = dormantSession()
    let writer = DormantWriterProbe(results: [kIOReturnSuccess, kIOReturnSuccess])
    let adapter = try DormantPrecisionTrialIOHIDAdapter(
        session: session,
        writer: writer.write
    )
    let set = try dormantSetRequest(session)
    _ = try await adapter.beginSet(request: set, expectedSession: session)
    _ = await adapter.consumeInputReport(
        set.bytes,
        device: session.device,
        connectionEpoch: session.connectionEpoch
    )
    let getID = UUID()
    _ = try await adapter.beginVerification(
        request: dormantVerificationRequest(session),
        expectedSession: session,
        requestID: getID
    )
    await adapter.timeout(
        requestID: getID,
        connectionEpoch: session.connectionEpoch
    )
    let lateResponse = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: session.featureIndex,
        functionID: 2,
        softwareID: 0x0E,
        parameters: [0x00, 0xED, 0x00, 0x00, 0x00]
    )

    #expect(await adapter.consumeInputReport(
        lateResponse.bytes,
        device: session.device,
        connectionEpoch: session.connectionEpoch
    ) == .ignored)
    #expect(await adapter.status == .terminalUnknown)
}

private final class DormantWriterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingResults: [IOReturn]
    private var recordedRequests: [[UInt8]] = []

    init(results: [IOReturn]) {
        remainingResults = results
    }

    var requests: [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func write(_ bytes: [UInt8]) -> IOReturn {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(bytes)
        guard !remainingResults.isEmpty else { return kIOReturnError }
        return remainingResults.removeFirst()
    }
}

private func dormantSession() -> RestoreOnlyHardwareTrialSession {
    RestoreOnlyHardwareTrialSession(
        device: JournalDeviceIdentity(
            deviceID: "mx-ergo",
            vendorID: 0x046D,
            productID: 0xB01D,
            transport: "Bluetooth Low Energy",
            serialNumber: "7865BCA9046ED9FF",
            locationID: 1,
            firmwareIdentity: "firmware-bound"
        ),
        featureIndex: 0x0A,
        featureVersion: 3,
        connectionEpoch: 7,
        matchingDeviceCount: 1,
        outputReportByteCount: HIDPP20LongMessage.byteCount
    )
}

private func dormantSetRequest(
    _ session: RestoreOnlyHardwareTrialSession
) throws -> HIDPP20LongMessage {
    try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: session.featureIndex,
        functionID: 3,
        softwareID: 0x0E,
        parameters: [0x00, 0xED, 0x02, 0x00, 0x00]
    )
}

private func dormantVerificationRequest(
    _ session: RestoreOnlyHardwareTrialSession
) throws -> HIDPP20LongMessage {
    try ReprogControlsV4.getReportingRequest(
        controlID: 0x00ED,
        featureIndex: session.featureIndex,
        deviceIndex: 0,
        softwareID: 0x0E
    )
}

private func dormantOtherDevice(
    _ device: JournalDeviceIdentity
) -> JournalDeviceIdentity {
    JournalDeviceIdentity(
        deviceID: device.deviceID,
        vendorID: device.vendorID,
        productID: device.productID,
        transport: device.transport,
        serialNumber: device.serialNumber,
        locationID: (device.locationID ?? 0) &+ 1,
        firmwareIdentity: device.firmwareIdentity
    )
}

// MARK: - Build-graph isolation

/// This target is the one dormant adapter with a deliberate path into a signed
/// binary: `project.yml` compiles its single source file directly into the
/// `MXErgoPrecisionRestoreTrial` helper, bypassing the package graph entirely.
///
/// Every sibling dormant target can assert flat absence from the Xcode project.
/// This one cannot, so it asserts something narrower and more useful: the file
/// reaches exactly one target, that target is the trial helper, and the menu app
/// never compiles it.
@Test func restoreTrialAdapterIsProductlessAndReachesOnlyTheTrialHelper() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectRoot = packageRoot
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    // 1. No package product, and exactly the expected manifest references.
    let manifest = try String(
        contentsOf: packageRoot.appendingPathComponent("Package.swift"),
        encoding: .utf8
    )
    let products = try #require(
        manifest.split(separator: "targets: [", maxSplits: 1).first
    )
    #expect(!products.contains("MXErgoRestoreTrialIOHID"))
    #expect(manifest.components(
        separatedBy: "\"MXErgoRestoreTrialIOHID\""
    ).count - 1 == 2)
    #expect(manifest.components(
        separatedBy: "\"MXErgoRestoreTrialIOHIDTests\""
    ).count - 1 == 1)

    // 2. The XcodeGen manifest names the source exactly once, under the trial
    //    helper and no other target.
    let projectYAML = try String(
        contentsOf: projectRoot.appendingPathComponent("project.yml"),
        encoding: .utf8
    )
    #expect(projectYAML.components(
        separatedBy: "MXErgoRestoreTrialIOHID"
    ).count - 1 == 1)
    let trialTargetBody = try #require(
        projectYAML
            .components(separatedBy: "  MXErgoPrecisionRestoreTrial:")
            .dropFirst().first?
            .components(separatedBy: "\n  MXErgo").first
    )
    #expect(trialTargetBody.contains(
        "Sources/MXErgoRestoreTrialIOHID/DormantPrecisionTrialIOHIDAdapter.swift"
    ))

    // 3. The generated project compiles it into exactly one Sources phase, and
    //    that phase is the trial helper's rather than the menu app's.
    let projectFile = try String(
        contentsOf: projectRoot
            .appendingPathComponent("MXErgoController.xcodeproj")
            .appendingPathComponent("project.pbxproj"),
        encoding: .utf8
    )
    #expect(projectFile.components(
        separatedBy: "DormantPrecisionTrialIOHIDAdapter.swift in Sources"
    ).count - 1 == 2)  // one PBXBuildFile declaration, one build-phase entry

    let sourcePhases = projectFile
        .components(separatedBy: "isa = PBXSourcesBuildPhase;")
        .dropFirst()
    let compilingPhases = sourcePhases.filter {
        $0.contains("DormantPrecisionTrialIOHIDAdapter.swift in Sources")
    }
    #expect(compilingPhases.count == 1)
    let trialPhase = try #require(compilingPhases.first)
    #expect(trialPhase.contains("MXErgoPrecisionRestoreTrialMain.swift in Sources"))
    #expect(!trialPhase.contains("AppModel.swift in Sources"))

    let menuAppPhases = sourcePhases.filter {
        $0.contains("AppModel.swift in Sources")
    }
    #expect(menuAppPhases.count == 1)
    let menuAppPhase = try #require(menuAppPhases.first)
    #expect(!menuAppPhase.contains("DormantPrecisionTrialIOHIDAdapter.swift"))

    // 4. The adapter keeps exactly one output door and no discovery, lifetime,
    //    retry, or escalation capability.
    let adapterSource = try String(
        contentsOf: packageRoot.appendingPathComponent(
            "Sources/MXErgoRestoreTrialIOHID/DormantPrecisionTrialIOHIDAdapter.swift"
        ),
        encoding: .utf8
    )
    #expect(adapterSource.components(
        separatedBy: "IOHIDDevice" + "SetReport"
    ).count - 1 == 1)
    let forbiddenAdapterTokens = [
        "IOHID" + "Manager",
        "IOHIDDevice" + "Open",
        "IOHIDDevice" + "Close",
        "IOHIDDevice" + "RegisterInputReportCallback",
        "@" + "main",
        "Process(",
        "URLSession",
        "public ",
        "package ",
        "@_spi",
    ]
    for forbidden in forbiddenAdapterTokens {
        #expect(!adapterSource.contains(forbidden))
    }
}
