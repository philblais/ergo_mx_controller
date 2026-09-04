import Foundation
@preconcurrency import IOKit.hid
import MXErgoHIDPP
import Testing
@testable import MXErgoPrecisionIOHIDInput
@testable import MXErgoPrecisionTransport

@Test func inputSessionInitializationPerformsNoIOHIDWorkAndStartOrdersRegistration() throws {
    let fixture = try inputFixture()
    #expect(fixture.calls.events.isEmpty)

    try fixture.session.start()
    try fixture.session.start()

    #expect(fixture.calls.events == [
        "set-dispatch-queue",
        "register-input",
        "register-removal",
        "set-cancel-handler",
        "activate",
    ])
    #expect(fixture.session.isActive)

    fixture.session.shutdownAndWait()
    fixture.session.shutdownAndWait()
    #expect(fixture.calls.events.suffix(2) == ["cancel", "cancel-handler"])
    #expect(fixture.session.isStopped)
}

@Test func inputSessionCopiesEphemeralCallbackBytesSynchronously() async throws {
    let fixture = try inputFixture()
    try fixture.session.start()
    let requestID = UUID()
    try fixture.session.beginRequest(outputFrame(requestID, fixture: fixture))
    var callbackBytes = inputMessageBytes()

    fixture.calls.fireInput(bytes: &callbackBytes)
    callbackBytes = Array(repeating: 0xFF, count: callbackBytes.count)

    let frame = try await fixture.session.read(for: requestID)
    #expect(frame.bytes == inputMessageBytes())
    #expect(frame.bytes != callbackBytes)
    #expect(fixture.session.acceptedCallbackCount == 1)
    fixture.session.endRequest(requestID)
    fixture.session.shutdownAndWait()
}

@Test func inputSessionRejectsForeignAndMalformedCallbackMetadata() async throws {
    let fixture = try inputFixture()
    try fixture.session.start()
    let requestID = UUID()
    try fixture.session.beginRequest(outputFrame(requestID, fixture: fixture))
    var bytes = inputMessageBytes()

    fixture.calls.fireInput(bytes: &bytes, senderMatches: false)
    fixture.calls.fireInput(bytes: &bytes, result: kIOReturnError)
    fixture.calls.fireInput(
        bytes: &bytes,
        reportType: kIOHIDReportTypeFeature
    )
    fixture.calls.fireInput(bytes: &bytes, reportID: 0x10)
    var short = Array(bytes.dropLast())
    fixture.calls.fireInput(bytes: &short)

    #expect(fixture.session.acceptedCallbackCount == 0)
    #expect(fixture.session.rejectedCallbackCount == 5)

    fixture.calls.fireInput(bytes: &bytes)
    #expect(try await fixture.session.read(for: requestID).bytes == bytes)
    fixture.session.endRequest(requestID)
    fixture.session.shutdownAndWait()
}

@Test func inputSessionRemovalIsTerminalAndNotifiesExactlyOnce() async throws {
    let disconnects = LockedCounter()
    let fixture = try inputFixture {
        disconnects.increment()
    }
    try fixture.session.start()
    let requestID = UUID()
    try fixture.session.beginRequest(outputFrame(requestID, fixture: fixture))
    let readTask = Task { try await fixture.session.read(for: requestID) }

    fixture.calls.fireRemoval(senderMatches: false)
    #expect(disconnects.value == 0)
    fixture.calls.fireRemoval(senderMatches: true)
    fixture.calls.fireRemoval(senderMatches: true)

    await #expect(throws: PrecisionTransportReportIOError.disconnected) {
        try await readTask.value
    }
    #expect(disconnects.value == 1)
    #expect(fixture.calls.events.filter { $0 == "cancel" }.count == 1)
    #expect(fixture.session.isStopped)
    fixture.session.shutdownAndWait()
}

@Test func inputSessionShutdownWaitsForDelayedCancelHandler() async throws {
    let fixture = try inputFixture(completeCancellationImmediately: false)
    try fixture.session.start()
    let completion = LockedFlag()
    let shutdown = Task.detached {
        fixture.session.shutdownAndWait()
        completion.set()
    }

    try await waitUntil { fixture.calls.events.contains("cancel") }
    #expect(!completion.value)
    #expect(fixture.calls.retainsBufferAndSink)

    fixture.calls.completeCancellation()
    await shutdown.value
    #expect(completion.value)
    #expect(fixture.session.isStopped)
}

@Test func failedActivationStillWaitsForCancelHandlerQuiescence() async throws {
    let fixture = try inputFixture()
    let runtime = FailingActivationInputRuntime()
    let session = try PrecisionIOHIDInputSession(
        binding: fixture.binding,
        runtime: runtime
    )

    #expect(throws: FailingInputRuntimeError.activation) {
        try session.start()
    }
    #expect(runtime.cancelCount == 1)
    #expect(!session.isStopped)

    let completion = LockedFlag()
    let shutdown = Task.detached {
        session.shutdownAndWait()
        completion.set()
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(!completion.value)

    runtime.completeCancellation()
    await shutdown.value
    #expect(completion.value)
    #expect(session.isStopped)
}

@Test func inputSessionForwardsUnrelatedFramesUntilTheRequestBudgetFailsClosed() async throws {
    let fixture = try inputFixture(queueCapacity: 1, totalCandidateLimit: 2)
    try fixture.session.start()
    let requestID = UUID()
    try fixture.session.beginRequest(outputFrame(requestID, fixture: fixture))

    for discriminator: UInt8 in 1...2 {
        var bytes = inputMessageBytes()
        bytes[6] = discriminator
        fixture.calls.fireInput(bytes: &bytes)
        #expect(try await fixture.session.read(for: requestID).bytes == bytes)
    }

    var overflow = inputMessageBytes()
    overflow[6] = 3
    fixture.calls.fireInput(bytes: &overflow)
    await #expect(throws: PrecisionTransportReportIOError.overflow) {
        try await fixture.session.read(for: requestID)
    }
    fixture.session.shutdownAndWait()
}

@Test func inputSessionDeliversASynchronousCallbackThroughTheTransportAdapter() async throws {
    let fixture = try inputFixture()
    let plan = try precisionPlan(device: fixture.device)
    let response = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: fixture.binding.session.featureIndex,
        functionID: 2,
        softwareID: 0x0E,
        parameters: plan.baseline.rawParameters
    )
    let writer = RuntimeCallbackWriter(
        calls: fixture.calls,
        responseBytes: response.bytes
    )
    let adapter = try PrecisionTransportAdapter(
        plan: plan,
        binding: fixture.binding,
        writer: writer,
        reader: fixture.session,
        sessionProvider: { fixture.binding.session },
        rootGenerationProvider: { fixture.binding.rootGeneration },
        competitorProbe: { [] },
        durableSnapshotLoader: {
            fatalError("readReporting must not load a mutation journal")
        }
    )
    try fixture.session.start()

    let observed = try await adapter.readReporting(
        controlID: PrecisionTemporaryDiversionPlan.controlID,
        expectedSession: fixture.binding.session
    )

    #expect(observed == plan.baseline)
    #expect(writer.writeCount == 1)
    #expect(fixture.session.acceptedCallbackCount == 1)
    fixture.session.shutdownAndWait()
}

@Test func precisionInputTargetRemainsProductlessUnwiredAndOutputFree() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectRoot = packageRoot
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let manifest = try String(
        contentsOf: packageRoot.appendingPathComponent("Package.swift"),
        encoding: .utf8
    )
    let products = try #require(
        manifest.split(separator: "targets: [", maxSplits: 1).first
    )
    #expect(!products.contains("MXErgoPrecisionIOHIDInput"))

    let projectYAML = try String(
        contentsOf: projectRoot.appendingPathComponent("project.yml"),
        encoding: .utf8
    )
    let projectFile = try String(
        contentsOf: projectRoot
            .appendingPathComponent("MXErgoController.xcodeproj")
            .appendingPathComponent("project.pbxproj"),
        encoding: .utf8
    )
    #expect(!projectYAML.contains("MXErgoPrecisionIOHIDInput"))
    #expect(!projectFile.contains("MXErgoPrecisionIOHIDInput"))

    let pureSource = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionTransport"
        )
    )
    #expect(!pureSource.contains("import IOKit"))
    #expect(!pureSource.contains("IOHIDDevice"))

    let inputSource = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionIOHIDInput"
        )
    )
    for forbidden in [
        "IOHIDDeviceSetReport",
        "kIOHIDReportTypeOutput",
        "IOHIDManager",
        "IOHIDDeviceOpen",
        "@main",
    ] {
        #expect(!inputSource.contains(forbidden))
    }
}

private struct InputFixture: @unchecked Sendable {
    let device: JournalDeviceIdentity
    let binding: PrecisionTransportBinding
    let calls: RecordingIOHIDCalls
    let session: PrecisionIOHIDInputSession
}

private enum FailingInputRuntimeError: Error, Sendable, Equatable {
    case activation
}

private final class FailingActivationInputRuntime:
    PrecisionIOHIDInputRuntime,
    @unchecked Sendable {
    let inputReportBufferByteCount = 64
    private let lock = NSLock()
    private var sink: (any PrecisionIOHIDInputEventSink)?
    private var cancelCountStorage = 0

    var cancelCount: Int { lock.withLock { cancelCountStorage } }

    func configure(
        queue: DispatchQueue,
        reportBuffer: UnsafeMutablePointer<UInt8>,
        reportBufferLength: Int,
        sink: any PrecisionIOHIDInputEventSink
    ) throws {
        _ = queue
        _ = reportBuffer
        _ = reportBufferLength
        lock.withLock { self.sink = sink }
    }

    func activate() throws {
        throw FailingInputRuntimeError.activation
    }

    func cancel() {
        lock.withLock { cancelCountStorage += 1 }
    }

    func completeCancellation() {
        let sink = lock.withLock {
            let retained = self.sink
            self.sink = nil
            return retained
        }
        sink?.ioHIDCallbacksCancelled()
    }
}

private func inputFixture(
    queueCapacity: Int = 8,
    totalCandidateLimit: Int = 32,
    completeCancellationImmediately: Bool = true,
    disconnectHandler: @escaping @Sendable () -> Void = {}
) throws -> InputFixture {
    let device = JournalDeviceIdentity(
        deviceID: "1133-45085-42-1-2",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "INPUT-TEST",
        locationID: 42,
        firmwareIdentity: "input-test-firmware"
    )
    let binding = PrecisionTransportBinding(
        session: DeviceTransactionSession(
            device: device,
            featureID: ReprogControlsV4.featureID,
            featureVersion: 3,
            featureIndex: 0x0A,
            connectionEpoch: 9
        ),
        rootGeneration: 12
    )
    let calls = RecordingIOHIDCalls(
        completeCancellationImmediately: completeCancellationImmediately
    )
    let runtime = try SystemPrecisionIOHIDInputRuntime(
        inputReportBufferByteCount: 64,
        senderMatches: { sender in
            sender == calls.expectedSender.pointer
        },
        calls: calls.systemCalls
    )
    let session = try PrecisionIOHIDInputSession(
        binding: binding,
        runtime: runtime,
        queueCapacity: queueCapacity,
        totalCandidateLimit: totalCandidateLimit,
        disconnectHandler: disconnectHandler
    )
    return InputFixture(
        device: device,
        binding: binding,
        calls: calls,
        session: session
    )
}

private final class RecordingIOHIDCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var eventsStorage: [String] = []
    private var inputCallback: IOHIDReportCallback?
    private var inputContext: UnsafeMutableRawPointer?
    private var removalCallback: IOHIDCallback?
    private var removalContext: UnsafeMutableRawPointer?
    private var cancelHandler: (@Sendable () -> Void)?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var sinkConfigured = false
    private let completeCancellationImmediately: Bool
    let expectedSender = UncheckedPointer(
        UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    )
    let foreignSender = UncheckedPointer(
        UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    )

    init(completeCancellationImmediately: Bool) {
        self.completeCancellationImmediately = completeCancellationImmediately
    }

    deinit {
        expectedSender.pointer.deallocate()
        foreignSender.pointer.deallocate()
    }

    var systemCalls: PrecisionIOHIDInputSystemCalls {
        PrecisionIOHIDInputSystemCalls(
            setDispatchQueue: { [self] _ in record("set-dispatch-queue") },
            registerInputReport: { [self] buffer, _, callback, context in
                lock.lock()
                eventsStorage.append("register-input")
                reportBuffer = buffer
                inputCallback = callback
                inputContext = context
                sinkConfigured = true
                lock.unlock()
            },
            registerRemoval: { [self] callback, context in
                lock.lock()
                eventsStorage.append("register-removal")
                removalCallback = callback
                removalContext = context
                lock.unlock()
            },
            setCancelHandler: { [self] handler in
                lock.lock()
                eventsStorage.append("set-cancel-handler")
                cancelHandler = handler
                lock.unlock()
            },
            activate: { [self] in record("activate") },
            cancel: { [self] in
                lock.lock()
                eventsStorage.append("cancel")
                let handler = cancelHandler
                let complete = completeCancellationImmediately
                lock.unlock()
                if complete {
                    record("cancel-handler")
                    handler?()
                }
            }
        )
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return eventsStorage
    }

    var retainsBufferAndSink: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reportBuffer != nil && sinkConfigured && cancelHandler != nil
    }

    func fireInput(
        bytes: inout [UInt8],
        senderMatches: Bool = true,
        result: IOReturn = kIOReturnSuccess,
        reportType: IOHIDReportType = kIOHIDReportTypeInput,
        reportID: UInt32 = UInt32(HIDPP20LongMessage.reportID)
    ) {
        lock.lock()
        let callback = inputCallback
        let context = inputContext
        lock.unlock()
        let sender = senderMatches ? expectedSender.pointer : foreignSender.pointer
        bytes.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            callback?(
                context,
                result,
                sender,
                reportType,
                reportID,
                baseAddress,
                CFIndex(buffer.count)
            )
        }
    }

    func fireRemoval(senderMatches: Bool) {
        lock.lock()
        let callback = removalCallback
        let context = removalContext
        lock.unlock()
        callback?(
            context,
            kIOReturnSuccess,
            senderMatches ? expectedSender.pointer : foreignSender.pointer
        )
    }

    func completeCancellation() {
        lock.lock()
        let handler = cancelHandler
        lock.unlock()
        record("cancel-handler")
        handler?()
    }

    private func record(_ event: String) {
        lock.lock()
        eventsStorage.append(event)
        lock.unlock()
    }
}

private final class RuntimeCallbackWriter:
    PrecisionTransportReportWriter,
    @unchecked Sendable {
    private let lock = NSLock()
    private let calls: RecordingIOHIDCalls
    private let responseBytes: [UInt8]
    private var writeCountStorage = 0

    init(calls: RecordingIOHIDCalls, responseBytes: [UInt8]) {
        self.calls = calls
        self.responseBytes = responseBytes
    }

    func write(_ frame: PrecisionTransportOutputFrame) async throws -> Int32 {
        _ = frame
        lock.withLock { writeCountStorage += 1 }
        var bytes = responseBytes
        calls.fireInput(bytes: &bytes)
        return 0
    }

    func cancelPendingWrite(
        requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        _ = requestID
        _ = reason
    }

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writeCountStorage
    }
}

private struct UncheckedPointer: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer

    init(_ pointer: UnsafeMutableRawPointer) {
        self.pointer = pointer
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

private func outputFrame(
    _ requestID: UUID,
    fixture: InputFixture
) -> PrecisionTransportOutputFrame {
    PrecisionTransportOutputFrame(
        requestID: requestID,
        reportType: .output,
        reportID: HIDPP20LongMessage.reportID,
        bytes: inputMessageBytes(),
        device: fixture.device,
        connectionEpoch: fixture.binding.session.connectionEpoch,
        rootGeneration: fixture.binding.rootGeneration
    )
}

private func inputMessageBytes() -> [UInt8] {
    [0x11, 0x00, 0x0A, 0x2E, 0x00, 0xED]
        + Array(repeating: 0, count: 14)
}

private func precisionPlan(
    device: JournalDeviceIdentity
) throws -> PrecisionTemporaryDiversionPlan {
    let entry = try DeviceControlJournalEntry(
        controlInfo: ReprogControlInfo(
            index: 5,
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            taskID: 0x00C4,
            capabilityFlags: 0x71,
            position: 0,
            group: 1,
            groupMask: 1,
            rawXYCapability: false,
            rawParameters: padded([0x00, 0xED])
        ),
        baselineReporting: ReprogControlReportingState(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            rawFlags: 0,
            rawMappedControlID: 0,
            rawParameters: padded([0x00, 0xED, 0x00, 0x00, 0x00])
        )
    )
    let feature = HIDPP20FeatureDescriptor(
        index: 0x0A,
        type: 0,
        version: 3,
        rawParameters: padded([0x0A, 0x00, 0x03])
    )
    let journal = try DeviceStateJournal(
        transactionID: UUID(),
        appBuild: "precision-input-adapter-test",
        device: device,
        feature: feature,
        expectedControlCount: 1,
        controls: [entry]
    )
    return try PrecisionTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )
}

private func padded(_ prefix: [UInt8]) -> [UInt8] {
    prefix + Array(
        repeating: 0,
        count: HIDPP20LongMessage.parameterCount - prefix.count
    )
}

private func waitUntil(
    _ predicate: @escaping @Sendable () -> Bool
) async throws {
    for _ in 0..<1_000 {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw PrecisionIOHIDInputTestError.timedOut
}

private func sourceText(under directory: URL) throws -> String {
    let enumerator = try #require(
        FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        )
    )
    var result = ""
    for case let file as URL in enumerator where file.pathExtension == "swift" {
        result += try String(contentsOf: file, encoding: .utf8)
    }
    return result
}

private enum PrecisionIOHIDInputTestError: Error {
    case timedOut
}
