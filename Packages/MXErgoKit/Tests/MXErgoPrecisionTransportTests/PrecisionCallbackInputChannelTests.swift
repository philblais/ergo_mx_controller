import Foundation
import MXErgoHIDPP
import Testing
@testable import MXErgoPrecisionTransport

@Test func callbackChannelCopiesEphemeralBytesBeforeTheCallbackReturns() async throws {
    let fixture = callbackFixture()
    let channel = fixture.channel
    let requestID = UUID()
    try channel.beginRequest(callbackOutputFrame(requestID, fixture: fixture))
    var callbackBytes = callbackMessageBytes()

    let accepted = callbackBytes.withUnsafeBytes { bytes in
        channel.receiveCallback(
            reportType: .input,
            reportID: HIDPP20LongMessage.reportID,
            bytes: bytes,
            device: fixture.device,
            connectionEpoch: fixture.connectionEpoch,
            rootGeneration: fixture.rootGeneration
        )
    }
    callbackBytes = Array(repeating: 0xFF, count: callbackBytes.count)

    #expect(accepted)
    let frame = try await channel.read(for: requestID)
    #expect(frame.bytes == callbackMessageBytes())
    #expect(frame.bytes != callbackBytes)
    #expect(channel.acceptedCount == 1)
    #expect(channel.resumeCount == 1)
}

@Test func callbackChannelKeepsWindowOpenForUnrelatedThenMatchingFrames() async throws {
    let fixture = callbackFixture()
    let channel = fixture.channel
    let requestID = UUID()
    try channel.beginRequest(callbackOutputFrame(requestID, fixture: fixture))
    var unrelated = callbackMessageBytes()
    unrelated[3] = 0x1E
    let matching = callbackMessageBytes()

    #expect(unrelated.withUnsafeBytes { pointer in
        channel.receiveCallback(
            reportType: .input,
            reportID: HIDPP20LongMessage.reportID,
            bytes: pointer,
            device: fixture.device,
            connectionEpoch: fixture.connectionEpoch,
            rootGeneration: fixture.rootGeneration
        )
    })
    #expect(try await channel.read(for: requestID).bytes == unrelated)

    #expect(matching.withUnsafeBytes { pointer in
        channel.receiveCallback(
            reportType: .input,
            reportID: HIDPP20LongMessage.reportID,
            bytes: pointer,
            device: fixture.device,
            connectionEpoch: fixture.connectionEpoch,
            rootGeneration: fixture.rootGeneration
        )
    })
    #expect(try await channel.read(for: requestID).bytes == matching)
    channel.endRequest(requestID)
    #expect(!channel.hasActiveRequest)
}

@Test func callbackChannelFiltersForeignMetadataAndSuppressesDuplicates() async throws {
    let fixture = callbackFixture()
    let channel = fixture.channel
    let requestID = UUID()
    try channel.beginRequest(callbackOutputFrame(requestID, fixture: fixture))
    let bytes = callbackMessageBytes()
    let otherDevice = JournalDeviceIdentity(
        deviceID: "foreign",
        vendorID: fixture.device.vendorID,
        productID: fixture.device.productID,
        transport: fixture.device.transport,
        serialNumber: "FOREIGN",
        locationID: 999,
        firmwareIdentity: fixture.device.firmwareIdentity
    )

    #expect(!bytes.withUnsafeBytes { pointer in
        channel.receiveCallback(
            reportType: .input,
            reportID: HIDPP20LongMessage.reportID,
            bytes: pointer,
            device: otherDevice,
            connectionEpoch: fixture.connectionEpoch,
            rootGeneration: fixture.rootGeneration
        )
    })
    #expect(!bytes.withUnsafeBytes { pointer in
        channel.receiveCallback(
            reportType: .output,
            reportID: HIDPP20LongMessage.reportID,
            bytes: pointer,
            device: fixture.device,
            connectionEpoch: fixture.connectionEpoch,
            rootGeneration: fixture.rootGeneration
        )
    })
    #expect(bytes.withUnsafeBytes { pointer in
        channel.receiveCallback(
            reportType: .input,
            reportID: HIDPP20LongMessage.reportID,
            bytes: pointer,
            device: fixture.device,
            connectionEpoch: fixture.connectionEpoch,
            rootGeneration: fixture.rootGeneration
        )
    })
    #expect(!bytes.withUnsafeBytes { pointer in
        channel.receiveCallback(
            reportType: .input,
            reportID: HIDPP20LongMessage.reportID,
            bytes: pointer,
            device: fixture.device,
            connectionEpoch: fixture.connectionEpoch,
            rootGeneration: fixture.rootGeneration
        )
    })

    #expect(try await channel.read(for: requestID).bytes == bytes)
    #expect(channel.acceptedCount == 1)
    #expect(channel.droppedCount == 3)
    #expect(channel.resumeCount == 1)
}

@Test func callbackChannelFinishRejectsLateInputAndPermitsANewRequest() async throws {
    let fixture = callbackFixture()
    let firstID = UUID()
    try fixture.channel.beginRequest(callbackOutputFrame(firstID, fixture: fixture))
    fixture.channel.endRequest(firstID)
    fixture.channel.endRequest(firstID)
    let bytes = callbackMessageBytes()
    #expect(!bytes.withUnsafeBytes { pointer in
        fixture.channel.receiveCallback(
            reportType: .input,
            reportID: HIDPP20LongMessage.reportID,
            bytes: pointer,
            device: fixture.device,
            connectionEpoch: fixture.connectionEpoch,
            rootGeneration: fixture.rootGeneration
        )
    })

    let secondID = UUID()
    try fixture.channel.beginRequest(callbackOutputFrame(secondID, fixture: fixture))
    #expect(fixture.channel.hasActiveRequest)
    #expect(fixture.channel.finishCount == 1)
}

@Test func callbackChannelCancellationIsStickyAndTokenSpecific() async throws {
    let fixture = callbackFixture()
    let requestID = UUID()
    try fixture.channel.beginRequest(callbackOutputFrame(requestID, fixture: fixture))
    fixture.channel.cancelRequest(UUID(), reason: .timeout)
    #expect(fixture.channel.hasActiveRequest)

    fixture.channel.cancelRequest(requestID, reason: .timeout)
    fixture.channel.cancelRequest(requestID, reason: .cancelled)

    await #expect(throws: PrecisionTransportReportIOError.timeout) {
        try await fixture.channel.read(for: requestID)
    }
    #expect(!fixture.channel.hasActiveRequest)
    #expect(fixture.channel.cancelCount == 1)
}

@Test func callbackChannelCancellationBeforeBeginCannotBeErased() throws {
    let fixture = callbackFixture()
    let requestID = UUID()
    fixture.channel.cancelRequest(requestID, reason: .timeout)

    #expect(throws: PrecisionTransportReportIOError.timeout) {
        try fixture.channel.beginRequest(
            callbackOutputFrame(requestID, fixture: fixture)
        )
    }
    #expect(!fixture.channel.hasActiveRequest)
}

@Test func callbackChannelOverflowFailsClosedWithoutSilentEviction() async throws {
    let fixture = callbackFixture(capacity: 1)
    let requestID = UUID()
    try fixture.channel.beginRequest(callbackOutputFrame(requestID, fixture: fixture))
    let first = callbackMessageBytes()
    var second = first
    second[3] = 0x1E

    #expect(first.withUnsafeBytes { pointer in
        fixture.channel.receiveCallback(
            reportType: .input,
            reportID: HIDPP20LongMessage.reportID,
            bytes: pointer,
            device: fixture.device,
            connectionEpoch: fixture.connectionEpoch,
            rootGeneration: fixture.rootGeneration
        )
    })
    #expect(!second.withUnsafeBytes { pointer in
        fixture.channel.receiveCallback(
            reportType: .input,
            reportID: HIDPP20LongMessage.reportID,
            bytes: pointer,
            device: fixture.device,
            connectionEpoch: fixture.connectionEpoch,
            rootGeneration: fixture.rootGeneration
        )
    })

    await #expect(throws: PrecisionTransportReportIOError.overflow) {
        try await fixture.channel.read(for: requestID)
    }
    #expect(!fixture.channel.hasActiveRequest)
    #expect(fixture.channel.acceptedCount == 1)
    #expect(fixture.channel.droppedCount == 1)
}

@Test func callbackChannelBoundsTotalCandidatesEvenWhenContinuouslyDrained() async throws {
    let fixture = callbackFixture(capacity: 1, candidateLimit: 2)
    let requestID = UUID()
    try fixture.channel.beginRequest(callbackOutputFrame(requestID, fixture: fixture))

    for discriminator: UInt8 in 0..<2 {
        var bytes = callbackMessageBytes()
        bytes[6] = discriminator
        let readTask = Task { try await fixture.channel.read(for: requestID) }
        try await waitForPendingCallbackRead(fixture.channel)
        #expect(bytes.withUnsafeBytes { pointer in
            fixture.channel.receiveCallback(
                reportType: .input,
                reportID: HIDPP20LongMessage.reportID,
                bytes: pointer,
                device: fixture.device,
                connectionEpoch: fixture.connectionEpoch,
                rootGeneration: fixture.rootGeneration
            )
        })
        #expect(try await readTask.value.bytes == bytes)
    }

    var overflow = callbackMessageBytes()
    overflow[6] = 0x7F
    #expect(!overflow.withUnsafeBytes { pointer in
        fixture.channel.receiveCallback(
            reportType: .input,
            reportID: HIDPP20LongMessage.reportID,
            bytes: pointer,
            device: fixture.device,
            connectionEpoch: fixture.connectionEpoch,
            rootGeneration: fixture.rootGeneration
        )
    })
    await #expect(throws: PrecisionTransportReportIOError.overflow) {
        try await fixture.channel.read(for: requestID)
    }
    #expect(!fixture.channel.hasActiveRequest)
    #expect(fixture.channel.acceptedCount == 2)
    #expect(fixture.channel.droppedCount == 1)
}

@Test func callbackChannelRemovalWakesOneReadAndRejectsLateCallbacks() async throws {
    let fixture = callbackFixture()
    let channel = fixture.channel
    let requestID = UUID()
    try channel.beginRequest(callbackOutputFrame(requestID, fixture: fixture))
    let readTask = Task { try await channel.read(for: requestID) }
    try await waitForPendingCallbackRead(channel)

    channel.disconnected()
    channel.disconnected()

    await #expect(throws: PrecisionTransportReportIOError.disconnected) {
        try await readTask.value
    }
    let bytes = callbackMessageBytes()
    #expect(!bytes.withUnsafeBytes { pointer in
        channel.receiveCallback(
            reportType: .input,
            reportID: HIDPP20LongMessage.reportID,
            bytes: pointer,
            device: fixture.device,
            connectionEpoch: fixture.connectionEpoch,
            rootGeneration: fixture.rootGeneration
        )
    })
    #expect(channel.acceptedCount == 0)
    #expect(channel.resumeCount == 1)
}

@Test func callbackChannelShutdownIsIdempotentAndResumesExactlyOnce() async throws {
    let fixture = callbackFixture()
    let channel = fixture.channel
    let requestID = UUID()
    try channel.beginRequest(callbackOutputFrame(requestID, fixture: fixture))
    let readTask = Task { try await channel.read(for: requestID) }
    try await waitForPendingCallbackRead(channel)

    channel.shutdown()
    channel.shutdown()

    await #expect(throws: PrecisionTransportReportIOError.cancelled) {
        try await readTask.value
    }
    #expect(channel.resumeCount == 1)
    #expect(throws: PrecisionTransportReportIOError.cancelled) {
        try channel.beginRequest(callbackOutputFrame(UUID(), fixture: fixture))
    }
}

@Test func callbackChannelDeliversUnsolicitedNotificationsWithoutAWindow() {
    let fixture = callbackFixture()
    let recorder = LockedUnsolicitedFrames()
    fixture.channel.setUnsolicitedHIDPPHandler { frame in
        recorder.append(frame.bytes)
    }
    var bytes = callbackNotificationBytes()
    #expect(bytes.withUnsafeBytes { pointer in
        fixture.channel.receiveCallback(
            reportType: .input,
            reportID: HIDPP20LongMessage.reportID,
            bytes: pointer,
            device: fixture.device,
            connectionEpoch: fixture.connectionEpoch,
            rootGeneration: fixture.rootGeneration
        )
    } == false)
    bytes[5] = 0xFF
    #expect(recorder.values.count == 1)
    #expect(recorder.values[0][1] == 0xFF)
    #expect(fixture.channel.unsolicitedCount == 1)
    fixture.channel.shutdown()
    #expect(callbackNotificationBytes().withUnsafeBytes { pointer in
        fixture.channel.receiveCallback(
            reportType: .input,
            reportID: HIDPP20LongMessage.reportID,
            bytes: pointer,
            device: fixture.device,
            connectionEpoch: fixture.connectionEpoch,
            rootGeneration: fixture.rootGeneration
        )
    } == false)
    #expect(recorder.values.count == 1)
}

private struct CallbackFixture {
    let device: JournalDeviceIdentity
    let connectionEpoch: UInt64
    let rootGeneration: UInt64
    let channel: PrecisionCallbackInputChannel
}

private func callbackFixture(
    capacity: Int = 8,
    candidateLimit: Int = 32
) -> CallbackFixture {
    let device = JournalDeviceIdentity(
        deviceID: "callback-test-device",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "CALLBACK-TEST",
        locationID: 42,
        firmwareIdentity: "callback-test-firmware"
    )
    let connectionEpoch: UInt64 = 7
    let rootGeneration: UInt64 = 11
    return CallbackFixture(
        device: device,
        connectionEpoch: connectionEpoch,
        rootGeneration: rootGeneration,
        channel: PrecisionCallbackInputChannel(
            expectedDevice: device,
            expectedConnectionEpoch: connectionEpoch,
            expectedRootGeneration: rootGeneration,
            capacity: capacity,
            candidateLimit: candidateLimit
        )
    )
}

private func callbackMessageBytes() -> [UInt8] {
    [0x11, 0x00, 0x0A, 0x2E, 0x00, 0xED]
        + Array(repeating: 0, count: 14)
}

private func callbackNotificationBytes() -> [UInt8] {
    [0x11, 0xFF, 0x0A, 0x00, 0x00, 0xED]
        + Array(repeating: 0, count: 14)
}

private final class LockedUnsolicitedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[UInt8]] = []

    var values: [[UInt8]] { lock.withLock { storage } }

    func append(_ value: [UInt8]) {
        lock.withLock { storage.append(value) }
    }
}

private func callbackOutputFrame(
    _ requestID: UUID,
    fixture: CallbackFixture
) -> PrecisionTransportOutputFrame {
    PrecisionTransportOutputFrame(
        requestID: requestID,
        reportType: .output,
        reportID: HIDPP20LongMessage.reportID,
        bytes: callbackMessageBytes(),
        device: fixture.device,
        connectionEpoch: fixture.connectionEpoch,
        rootGeneration: fixture.rootGeneration
    )
}

private func waitForPendingCallbackRead(
    _ channel: PrecisionCallbackInputChannel
) async throws {
    for _ in 0..<100 {
        if channel.hasPendingRead { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw CallbackTestWaitError.timedOut
}

private enum CallbackTestWaitError: Error {
    case timedOut
}
