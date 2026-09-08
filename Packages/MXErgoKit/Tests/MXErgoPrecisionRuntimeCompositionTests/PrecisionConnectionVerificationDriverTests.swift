import Foundation
import Testing
import MXErgoHIDPP
@testable import MXErgoPrecisionTransport
@testable import MXErgoPrecisionIOHIDAcquisition
@testable import MXErgoPrecisionRuntimeComposition

private struct DriverFixture {
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


private final class DriverEndpoint: PrecisionIOHIDAcquiredEndpoint, @unchecked Sendable {
    enum Mode: Sendable { case normal, delayed, firmwareDrift, foreignSource, disconnect, silent }
    let fixture: DriverFixture
    let mode: Mode
    let lock = NSLock()
    private var active = true
    private var window: UUID?
    private var queue: [PrecisionTransportInputFrame] = []
    private var previous: PrecisionTransportInputFrame?
    private var waiter: CheckedContinuation<PrecisionTransportInputFrame, Error>?
    private var cancelled: PrecisionTransportReportIOError?
    private var frames: [PrecisionTransportOutputFrame] = []
    private var ends = 0
    private var cancellations = 0
    init(_ mode: Mode = .normal) throws { fixture = try DriverFixture(count: 2); self.mode = mode }
    var binding: PrecisionTransportBinding { .init(session: fixture.session, rootGeneration: 17) }
    var counts: (writes: Int, ends: Int, cancellations: Int, open: Bool) {
        lock.withLock { (frames.count, ends, cancellations, window != nil) }
    }
    var output: [PrecisionTransportOutputFrame] { lock.withLock { frames } }
    var deviceCloseReturn: Int32? { nil }
    func start() async throws {}
    func shutdownAndDrain() async { disconnected() }
    func validateActiveConnection() throws {
        try lock.withLock { if !active { throw PrecisionTransportReportIOError.disconnected } }
    }
    func disconnected() { lock.withLock { active = false } }
    func beginRequest(_ frame: PrecisionTransportOutputFrame) throws {
        try lock.withLock {
            guard window == nil else { throw PrecisionTransportReportIOError.cancelled }
            window = frame.requestID; cancelled = nil
        }
    }
    func write(_ frame: PrecisionTransportOutputFrame) async throws -> Int32 {
        try lock.withLock {
            #expect(window == frame.requestID)
            frames.append(frame)
            let request = try #require(frame.connectionVerification).message
            if mode == .disconnect { active = false }
            if mode == .silent { return 0 }
            var payload: [UInt8]? = nil
            if mode == .firmwareDrift && request.featureIndex == 9 && request.functionID == 1 {
                var changed = fixture.entities[Int(request.parameters[0])]; changed[7] += 1; payload = changed
            }
            let response = try fixture.reply(to: request, parameters: payload)
            let input = PrecisionTransportInputFrame(reportType: .input, reportID: 0x11,
                bytes: response.bytes, device: binding.session.device,
                connectionEpoch: binding.session.connectionEpoch,
                rootGeneration: mode == .foreignSource ? 18 : 17)
            if mode == .delayed, let previous { queue.append(previous) }
            queue.append(input); previous = input
            return 0
        }
    }
    func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let cancelled { continuation.resume(throwing: cancelled) }
                else if !queue.isEmpty { continuation.resume(returning: queue.removeFirst()) }
                else { waiter = continuation }
            }
        }
    }
    func cancelPendingWrite(requestID: UUID, reason: PrecisionTransportReportIOError) {
        lock.withLock { cancellations += 1 }
    }
    func cancelRequest(_ requestID: UUID, reason: PrecisionTransportReportIOError) {
        let pending = lock.withLock {
            cancelled = reason
            let pending = waiter; waiter = nil; return pending
        }
        pending?.resume(throwing: reason)
    }
    func endRequest(_ requestID: UUID) {
        lock.withLock { window = nil; queue = []; ends += 1 }
    }
}

private func runDriver(_ endpoint: DriverEndpoint, timeout: UInt64 = 2_000_000_000,
    probe: @escaping @Sendable () throws -> [String] = { [] }) async throws -> PrecisionConnectionVerificationObservation {
    try await PrecisionConnectionVerificationDriver.verify(endpoint: endpoint,
        binding: endpoint.binding, competitorProbe: probe, requestTimeoutNanoseconds: timeout)
}

@Test func driverAcceptsFreshTranscriptAndIgnoresDelayedPriorReplies() async throws {
    for mode: DriverEndpoint.Mode in [.normal, .delayed] {
        let endpoint = try DriverEndpoint(mode)
        let observation = try await runDriver(endpoint)
        #expect(observation.firmware.canonicalIdentity == endpoint.fixture.session.device.firmwareIdentity)
        #expect(observation.requestCount == 6)
        #expect(endpoint.counts.writes == 6 && endpoint.counts.ends == 6)
        #expect(!endpoint.counts.open)
        #expect(endpoint.output.allSatisfy { $0.connectionVerification != nil && ($0.bytes[3] >> 4) <= 1 })
    }
}

@Test func driverRejectsChangedFirmwareAndForeignEndpointEvidence() async throws {
    for mode: DriverEndpoint.Mode in [.firmwareDrift, .foreignSource] {
        let endpoint = try DriverEndpoint(mode)
        await #expect(throws: (any Error).self) { try await runDriver(endpoint) }
        #expect(!endpoint.counts.open)
        #expect(endpoint.counts.cancellations > 0)
        #expect(endpoint.counts.ends == endpoint.counts.writes)
    }
}

@Test func driverStopsAfterDisconnectOrCompetitorArrival() async throws {
    let disconnected = try DriverEndpoint(.disconnect)
    await #expect(throws: PrecisionTransportReportIOError.disconnected) { try await runDriver(disconnected) }
    #expect(disconnected.counts.writes == 1 && !disconnected.counts.open)
    let competitor = try DriverEndpoint()
    await #expect(throws: PrecisionConnectionVerificationDriverError.competitorsPresent) {
        try await runDriver(competitor, probe: { competitor.counts.writes > 0 ? ["Logi Options"] : [] })
    }
    #expect(competitor.counts.writes == 1 && !competitor.counts.open)
}

@Test func driverTimeoutCancelsBothSidesAndEndsTheReadWindow() async throws {
    let endpoint = try DriverEndpoint(.silent)
    await #expect(throws: PrecisionTransportReportIOError.timeout) { try await runDriver(endpoint, timeout: 500_000_000) }
    #expect(endpoint.counts.writes == 1 && endpoint.counts.ends == 1)
    #expect(endpoint.counts.cancellations > 0 && !endpoint.counts.open)
}

@Test func driverCancellationEndsTheReadWindowWithoutAnotherRequest() async throws {
    let endpoint = try DriverEndpoint(.silent)
    let task = Task { try await runDriver(endpoint, timeout: 10_000_000_000) }
    let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    while endpoint.counts.writes == 0 && DispatchTime.now().uptimeNanoseconds < deadline {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(endpoint.counts.writes == 1)
    task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(endpoint.counts.ends == 1 && !endpoint.counts.open)
    #expect(endpoint.counts.cancellations > 0)
}

@Test func driverOverallDeadlineBoundsASilentRequest() async throws {
    let endpoint = try DriverEndpoint(.silent)
    await #expect(throws: PrecisionTransportReportIOError.timeout) {
        try await PrecisionConnectionVerificationDriver.verify(endpoint: endpoint,
            binding: endpoint.binding, competitorProbe: { [] },
            requestTimeoutNanoseconds: 5_000_000_000, totalTimeoutNanoseconds: 500_000_000)
    }
    #expect(endpoint.counts.writes == 1 && endpoint.counts.ends == 1)
    #expect(endpoint.counts.cancellations > 0 && !endpoint.counts.open)
}

@Test func driverRechecksCompetitorsAfterEndingTheFinalWindow() async throws {
    let endpoint = try DriverEndpoint()
    await #expect(throws: PrecisionConnectionVerificationDriverError.competitorsPresent) {
        try await runDriver(endpoint, probe: { endpoint.counts.ends == 6 ? ["Logi Options"] : [] })
    }
    #expect(endpoint.counts.writes == 6 && endpoint.counts.ends == 6)
    #expect(!endpoint.counts.open)
}

@Test func driverRejectsInvalidDeadlinesBeforeOpeningARequest() async throws {
    for deadline: UInt64 in [0, 30_000_000_001] {
        let endpoint = try DriverEndpoint()
        await #expect(throws: PrecisionConnectionVerificationDriverError.invalidDeadline) {
            try await runDriver(endpoint, timeout: deadline)
        }
        #expect(endpoint.counts.writes == 0 && !endpoint.counts.open)
    }
}
