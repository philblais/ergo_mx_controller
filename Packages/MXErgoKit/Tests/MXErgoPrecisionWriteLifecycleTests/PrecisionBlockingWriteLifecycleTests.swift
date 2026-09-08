import CryptoKit
import Foundation
import MXErgoHIDPP
import Testing
@testable import MXErgoPrecisionTransport
@testable import MXErgoPrecisionWriteLifecycle

@Test func cancellationBeforeSchedulingGuaranteesZeroBlockingCalls() async throws {
    let fixture = try writeFixture()
    let scheduler = ManualScheduler()
    let calls = LockedCounter()
    let writer = try makeWriter(fixture: fixture, scheduler: scheduler) { _ in
        calls.increment()
        return 0
    }
    let requestID = UUID()
    let task = Task {
        try await writer.write(outputFrame(.applyTemporaryDiversion, requestID, fixture))
    }

    try await waitUntil { scheduler.count == 1 }
    writer.cancelPendingWrite(requestID: requestID, reason: .cancelled)
    await #expect(throws: PrecisionTransportReportIOError.cancelled) {
        try await task.value
    }

    scheduler.runNext()
    #expect(calls.value == 0)
    #expect(writer.entryCount == 0)
    #expect(writer.resumeCount == 1)
    await writer.shutdownAndDrain()
    #expect(writer.isStopped)
}

@Test func stickyCancellationBeforeWriteNeverSchedulesTheRequest() async throws {
    let fixture = try writeFixture()
    let scheduler = ManualScheduler()
    let calls = LockedCounter()
    let writer = try makeWriter(fixture: fixture, scheduler: scheduler) { _ in
        calls.increment()
        return 0
    }
    let requestID = UUID()

    writer.cancelPendingWrite(requestID: requestID, reason: .timeout)

    await #expect(throws: PrecisionTransportReportIOError.timeout) {
        try await writer.write(
            outputFrame(.getReporting, requestID, fixture)
        )
    }
    #expect(scheduler.count == 0)
    #expect(calls.value == 0)
    await writer.shutdownAndDrain()
}

@Test func cancellationAfterEntryResolvesPromptlyButDrainWaitsForReturn() async throws {
    let fixture = try writeFixture()
    let gate = BlockingCallGate(returnCode: -77)
    let writer = try makeWriter(fixture: fixture, blockingCall: gate.invoke)
    let requestID = UUID()
    let writeFinished = LockedFlag()
    let task = Task {
        defer { writeFinished.set() }
        return try await writer.write(
            outputFrame(.applyTemporaryDiversion, requestID, fixture)
        )
    }

    try await waitUntil { gate.entryCount == 1 }
    writer.cancelPendingWrite(requestID: requestID, reason: .timeout)
    writer.cancelPendingWrite(requestID: requestID, reason: .disconnected)
    try await waitUntil { writeFinished.value }
    await #expect(throws: PrecisionTransportReportIOError.timeout) {
        try await task.value
    }

    #expect(writer.isDraining)
    #expect(writer.entryCount == 1)
    #expect(writer.resumeCount == 1)
    let drainFinished = LockedFlag()
    let drain = Task {
        await writer.shutdownAndDrain()
        drainFinished.set()
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(!drainFinished.value)

    gate.release()
    await drain.value
    #expect(drainFinished.value)
    #expect(writer.lateDrainCount == 1)
    #expect(writer.isStopped)
}

@Test func exactReturnIsForwardedOnceAndDuplicateRequestIsRejected() async throws {
    let fixture = try writeFixture()
    let calls = LockedCounter()
    let writer = try makeWriter(fixture: fixture) { record in
        calls.increment()
        #expect(record.kind == .getReporting)
        return -123
    }
    let requestID = UUID()
    let frame = outputFrame(.getReporting, requestID, fixture)

    #expect(try await writer.write(frame) == -123)
    await #expect(throws: PrecisionWriteLifecycleError.duplicateRequest(requestID)) {
        try await writer.write(frame)
    }
    #expect(calls.value == 1)
    #expect(writer.entryCount == 1)
    #expect(writer.resumeCount == 1)
    await writer.shutdownAndDrain()
}

@Test func singleFlightAndWrongTokenCancellationDoNotAffectTheQueuedOwner() async throws {
    let fixture = try writeFixture()
    let scheduler = ManualScheduler()
    let writer = try makeWriter(fixture: fixture, scheduler: scheduler) { _ in 41 }
    let firstID = UUID()
    let cancelledFutureID = UUID()
    let first = Task {
        try await writer.write(
            outputFrame(.getReporting, firstID, fixture)
        )
    }

    try await waitUntil { scheduler.count == 1 }
    writer.cancelPendingWrite(
        requestID: cancelledFutureID,
        reason: .disconnected
    )
    await #expect(throws: PrecisionWriteLifecycleError.singleFlightViolation) {
        try await writer.write(
            outputFrame(.restoreTemporaryDiversion, UUID(), fixture)
        )
    }

    scheduler.runNext()
    #expect(try await first.value == 41)
    await #expect(throws: PrecisionTransportReportIOError.disconnected) {
        try await writer.write(
            outputFrame(.applyTemporaryDiversion, cancelledFutureID, fixture)
        )
    }
    #expect(writer.entryCount == 1)
    await writer.shutdownAndDrain()
}

@Test func shutdownCancelsQueuedWorkAndPermanentlyRejectsNewWrites() async throws {
    let fixture = try writeFixture()
    let scheduler = ManualScheduler()
    let calls = LockedCounter()
    let writer = try makeWriter(fixture: fixture, scheduler: scheduler) { _ in
        calls.increment()
        return 0
    }
    let task = Task {
        try await writer.write(
            outputFrame(.applyTemporaryDiversion, UUID(), fixture)
        )
    }
    try await waitUntil { scheduler.count == 1 }

    await writer.shutdownAndDrain()
    await #expect(throws: PrecisionTransportReportIOError.cancelled) {
        try await task.value
    }
    scheduler.runNext()
    #expect(calls.value == 0)
    #expect(writer.isStopped)
    await writer.shutdownAndDrain()
    await #expect(throws: PrecisionWriteLifecycleError.shuttingDown) {
        try await writer.write(
            outputFrame(.getReporting, UUID(), fixture)
        )
    }
}

@Test func tombstoneCapacityExhaustionFailsClosedWithoutDispatch() async throws {
    let fixture = try writeFixture()
    let scheduler = ManualScheduler()
    let calls = LockedCounter()
    let writer = try PrecisionBlockingWriteLifecycle(
        plan: fixture.plan,
        binding: fixture.binding,
        tombstoneLimit: 2,
        scheduler: scheduler.schedule
    ) { _ in
        calls.increment()
        return 0
    }

    writer.cancelPendingWrite(requestID: UUID(), reason: .cancelled)
    writer.cancelPendingWrite(requestID: UUID(), reason: .timeout)
    writer.cancelPendingWrite(requestID: UUID(), reason: .disconnected)

    #expect(writer.isStopped)
    await #expect(throws: PrecisionWriteLifecycleError.tombstoneCapacityExceeded) {
        try await writer.write(
            outputFrame(.getReporting, UUID(), fixture)
        )
    }
    #expect(scheduler.count == 0)
    #expect(calls.value == 0)
}

@Test func tombstoneOverflowCannotStrandAnAlreadyQueuedWrite() async throws {
    let fixture = try writeFixture()
    let scheduler = ManualScheduler()
    let calls = LockedCounter()
    let writer = try PrecisionBlockingWriteLifecycle(
        plan: fixture.plan,
        binding: fixture.binding,
        tombstoneLimit: 2,
        scheduler: scheduler.schedule
    ) { _ in
        calls.increment()
        return 0
    }
    let queued = Task {
        try await writer.write(
            outputFrame(.applyTemporaryDiversion, UUID(), fixture)
        )
    }
    try await waitUntil { scheduler.count == 1 }

    writer.cancelPendingWrite(requestID: UUID(), reason: .cancelled)
    writer.cancelPendingWrite(requestID: UUID(), reason: .timeout)
    writer.cancelPendingWrite(requestID: UUID(), reason: .disconnected)

    await #expect(throws: PrecisionWriteLifecycleError.tombstoneCapacityExceeded) {
        try await queued.value
    }
    #expect(writer.isStopped)
    #expect(writer.resumeCount == 1)
    scheduler.runNext()
    #expect(calls.value == 0)
    #expect(writer.entryCount == 0)
    await writer.shutdownAndDrain()
}

@Test func reentrantCancellationFromInsideTheInjectedCallDoesNotDeadlock() async throws {
    let fixture = try writeFixture()
    let box = WeakWriterBox()
    let writer = try makeWriter(fixture: fixture) { record in
        box.writer?.cancelPendingWrite(
            requestID: record.requestID,
            reason: .disconnected
        )
        return 0
    }
    box.writer = writer

    await #expect(throws: PrecisionTransportReportIOError.disconnected) {
        try await writer.write(
            outputFrame(.applyTemporaryDiversion, UUID(), fixture)
        )
    }
    try await waitUntil { writer.lateDrainCount == 1 }
    #expect(writer.entryCount == 1)
    #expect(writer.resumeCount == 1)
    await writer.shutdownAndDrain()
}

@Test func enteredCallRetainsWriterAndCapturedResourcesUntilPhysicalDrain() async throws {
    let fixture = try writeFixture()
    let gate = BlockingCallGate(returnCode: 0)
    let retention = RetentionProbe()
    var writer: PrecisionBlockingWriteLifecycle?
    do {
        let anchor = LifetimeAnchor()
        retention.store(anchor: anchor)
        writer = try makeWriter(fixture: fixture) { [anchor] record in
            _ = anchor
            return gate.invoke(record)
        }
    }
    retention.store(writer: writer)
    let requestID = UUID()
    let frame = outputFrame(.applyTemporaryDiversion, requestID, fixture)
    let task = Task { [weak writer] in
        guard let writer else { throw PrecisionWriteLifecycleError.shuttingDown }
        return try await writer.write(frame)
    }

    try await waitUntil { gate.entryCount == 1 }
    writer?.cancelPendingWrite(requestID: requestID, reason: .cancelled)
    await #expect(throws: PrecisionTransportReportIOError.cancelled) {
        try await task.value
    }
    writer = nil
    #expect(retention.bothAlive)

    gate.release()
    try await waitUntil { retention.bothReleased }
}

@Test func everyByteMutationAndBindingMutationIsRejectedBeforeEntry() async throws {
    let fixture = try writeFixture()
    let calls = LockedCounter()
    let writer = try makeWriter(fixture: fixture) { _ in
        calls.increment()
        return 0
    }
    let valid = outputFrame(.applyTemporaryDiversion, UUID(), fixture)

    for index in valid.bytes.indices {
        var bytes = valid.bytes
        // A low-bit change at the diversion-flags byte intentionally turns
        // APPLY into the separately reviewed RESTORE packet. Flip a bit that
        // cannot alias another member of the three-packet allowlist instead.
        bytes[index] ^= 0x80
        await #expect(throws: PrecisionWriteLifecycleError.invalidFrame) {
            try await writer.write(outputFrame(
                requestID: UUID(),
                bytes: bytes,
                fixture: fixture
            ))
        }
    }

    let otherDevice = JournalDeviceIdentity(
        deviceID: "different-device",
        vendorID: fixture.binding.session.device.vendorID,
        productID: fixture.binding.session.device.productID,
        transport: fixture.binding.session.device.transport,
        serialNumber: fixture.binding.session.device.serialNumber,
        locationID: fixture.binding.session.device.locationID,
        firmwareIdentity: fixture.binding.session.device.firmwareIdentity
    )
    let invalidFrames = [
        outputFrame(
            requestID: UUID(),
            reportType: .input,
            bytes: valid.bytes,
            fixture: fixture
        ),
        outputFrame(
            requestID: UUID(),
            reportID: 0x10,
            bytes: valid.bytes,
            fixture: fixture
        ),
        outputFrame(
            requestID: UUID(),
            bytes: valid.bytes,
            device: otherDevice,
            fixture: fixture
        ),
        outputFrame(
            requestID: UUID(),
            bytes: valid.bytes,
            connectionEpoch: fixture.binding.session.connectionEpoch + 1,
            fixture: fixture
        ),
        outputFrame(
            requestID: UUID(),
            bytes: valid.bytes,
            rootGeneration: fixture.binding.rootGeneration + 1,
            fixture: fixture
        ),
    ]
    for frame in invalidFrames {
        await #expect(throws: PrecisionWriteLifecycleError.invalidFrame) {
            try await writer.write(frame)
        }
    }

    #expect(calls.value == 0)
    #expect(writer.entryCount == 0)
    await writer.shutdownAndDrain()
}

@Test func writeLifecycleTargetRemainsProductlessUnwiredAndIOKitFree() throws {
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
    // The boundary is line-anchored. Splitting on a bare "targets: ["
    // truncates at the first *product's* targets list, which left this
    // check scanning two lines of the manifest.
    let products = try #require(
        manifest.split(separator: "\n    targets: [", maxSplits: 1).first
    )
    #expect(!products.contains("MXErgoPrecisionWriteLifecycle"))

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
    #expect(!projectYAML.contains("MXErgoPrecisionWriteLifecycle"))
    #expect(!projectFile.contains("MXErgoPrecisionWriteLifecycle"))

    let lifecycleSource = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionWriteLifecycle"
        )
    )
    for forbidden in [
        "import IOKit",
        "IOHIDDevice",
        "IOHIDManager",
        "SetReport",
        "kIOHIDReportTypeOutput",
        "@main",
        "ProcessInfo.processInfo.environment",
    ] {
        #expect(!lifecycleSource.contains(forbidden))
    }

    let inputSource = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionIOHIDInput"
        )
    )
    #expect(!inputSource.contains("IOHIDDeviceSetReport"))
    #expect(!inputSource.contains("kIOHIDReportTypeOutput"))
}

@Test func adapterDeadlineAfterApplyEntryIsPromptOutcomeUnknownAndStillDrains() async throws {
    let fixture = try writeFixture()
    let call = SelectiveBlockingCall(blockedKind: .applyTemporaryDiversion)
    let writer = try makeWriter(fixture: fixture, blockingCall: call.invoke)
    let reader = ScriptedLifecycleReader(frames: [
        try reportingFrame(fixture.plan.baseline, fixture: fixture),
    ])
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let journalURL = directory.appendingPathComponent(
        "write-lifecycle-adapter-v3.json"
    )
    let repository = DurableDeviceTransactionFileRepository(fileURL: journalURL)
    let adapter = try PrecisionTransportAdapter(
        plan: fixture.plan,
        binding: fixture.binding,
        writer: writer,
        reader: reader,
        sessionProvider: { fixture.binding.session },
        rootGenerationProvider: { fixture.binding.rootGeneration },
        competitorProbe: { [] },
        durableSnapshotLoader: {
            let data = try Data(contentsOf: journalURL)
            let envelope = try JSONDecoder().decode(
                DeviceTransactionEnvelope.self,
                from: data
            )
            try envelope.validate()
            return PrecisionTransportDurableSnapshot(
                envelope: envelope,
                sha256: sha256(data)
            )
        },
        operationTimeoutNanoseconds: 25_000_000
    )
    let coordinator = DeviceTransactionCoordinator(
        repository: repository,
        transport: adapter
    )
    _ = try await coordinator.installPreparedEnvelope(
        DeviceTransactionEnvelope(baselineJournal: fixture.journal)
    )
    let lifecycle = PrecisionTemporaryDiversionLifecycle(
        coordinator: coordinator,
        plan: fixture.plan,
        safetyGate: AlwaysAllowingLifecycleSafetyGate()
    )
    let activationFinished = LockedFlag()
    let activation = Task {
        defer { activationFinished.set() }
        return try await lifecycle.activate()
    }

    try await waitUntil { call.count(.applyTemporaryDiversion) == 1 }
    try await waitUntil { activationFinished.value }
    await #expect(throws: PrecisionTransportError.poisoned) {
        try await activation.value
    }

    #expect(await adapter.isPoisoned)
    #expect(writer.isDraining)
    #expect(writer.enteredKinds == [
        .getReporting,
        .applyTemporaryDiversion,
    ])
    #expect(call.count(.getReporting) == 1)
    #expect(call.count(.applyTemporaryDiversion) == 1)
    #expect(call.count(.restoreTemporaryDiversion) == 0)
    let durable = try #require(try await repository.loadValidated())
    let control = try durable.control(PrecisionTemporaryDiversionPlan.controlID)
    #expect(control.phase == .applyMayHaveOccurred)
    #expect(control.attempts.count == 1)

    let drainFinished = LockedFlag()
    let drain = Task {
        await writer.shutdownAndDrain()
        drainFinished.set()
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(!drainFinished.value)
    call.release()
    await drain.value

    #expect(drainFinished.value)
    #expect(writer.lateDrainCount == 1)
    #expect(writer.isStopped)
    #expect(call.count(.applyTemporaryDiversion) == 1)
}

private struct WriteFixture: Sendable {
    let journal: DeviceStateJournal
    let plan: PrecisionTemporaryDiversionPlan
    let binding: PrecisionTransportBinding
}

private func writeFixture() throws -> WriteFixture {
    let device = JournalDeviceIdentity(
        deviceID: "1133-45085-42-1-2",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "WRITE-LIFECYCLE-TEST",
        locationID: 42,
        firmwareIdentity: "write-lifecycle-firmware"
    )
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
        appBuild: "precision-write-lifecycle-test",
        device: device,
        feature: feature,
        expectedControlCount: 1,
        controls: [entry]
    )
    let plan = try PrecisionTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let session = DeviceTransactionSession(
        device: device,
        featureID: ReprogControlsV4.featureID,
        featureVersion: 3,
        featureIndex: 0x0A,
        connectionEpoch: 9
    )
    return WriteFixture(
        journal: journal,
        plan: plan,
        binding: PrecisionTransportBinding(
            session: session,
            rootGeneration: 12
        )
    )
}

private func makeWriter(
    fixture: WriteFixture,
    scheduler: ManualScheduler? = nil,
    blockingCall: @escaping PrecisionBlockingWriteLifecycle.BlockingCall
) throws -> PrecisionBlockingWriteLifecycle {
    try PrecisionBlockingWriteLifecycle(
        plan: fixture.plan,
        binding: fixture.binding,
        scheduler: scheduler?.schedule,
        blockingCall: blockingCall
    )
}

private func outputFrame(
    _ kind: PrecisionReviewedOutputKind,
    _ requestID: UUID,
    _ fixture: WriteFixture
) -> PrecisionTransportOutputFrame {
    let bytes: [UInt8]
    switch kind {
    case .connectionVerification:
        preconditionFailure("Verification frames require a sequence-issued token")
    case .getReporting:
        bytes = fixture.plan.verificationRequest.bytes
    case .applyTemporaryDiversion:
        bytes = fixture.plan.applySetRequest.bytes
    case .restoreTemporaryDiversion:
        bytes = fixture.plan.restoreSetRequest.bytes
    }
    return outputFrame(
        requestID: requestID,
        bytes: bytes,
        fixture: fixture
    )
}

private func outputFrame(
    requestID: UUID,
    reportType: PrecisionTransportReportType = .output,
    reportID: UInt8 = HIDPP20LongMessage.reportID,
    bytes: [UInt8],
    device: JournalDeviceIdentity? = nil,
    connectionEpoch: UInt64? = nil,
    rootGeneration: UInt64? = nil,
    fixture: WriteFixture
) -> PrecisionTransportOutputFrame {
    PrecisionTransportOutputFrame(
        requestID: requestID,
        reportType: reportType,
        reportID: reportID,
        bytes: bytes,
        device: device ?? fixture.binding.session.device,
        connectionEpoch: connectionEpoch
            ?? fixture.binding.session.connectionEpoch,
        rootGeneration: rootGeneration ?? fixture.binding.rootGeneration
    )
}

private final class ManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@Sendable () -> Void] = []

    var count: Int { lock.withLock { operations.count } }

    func schedule(_ operation: @escaping @Sendable () -> Void) {
        lock.withLock { operations.append(operation) }
    }

    func runNext() {
        let operation = lock.withLock {
            operations.isEmpty ? nil : operations.removeFirst()
        }
        operation?()
    }
}

private final class BlockingCallGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let returnCode: Int32
    private var records: [PrecisionReviewedOutputRecord] = []
    private var released = false

    init(returnCode: Int32) {
        self.returnCode = returnCode
    }

    var entryCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return records.count
    }

    func invoke(_ record: PrecisionReviewedOutputRecord) -> Int32 {
        condition.lock()
        records.append(record)
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
        return returnCode
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class SelectiveBlockingCall: @unchecked Sendable {
    private let condition = NSCondition()
    private let blockedKind: PrecisionReviewedOutputKind
    private var records: [PrecisionReviewedOutputRecord] = []
    private var released = false

    init(blockedKind: PrecisionReviewedOutputKind) {
        self.blockedKind = blockedKind
    }

    func invoke(_ record: PrecisionReviewedOutputRecord) -> Int32 {
        condition.lock()
        records.append(record)
        guard record.kind == blockedKind else {
            condition.unlock()
            return 0
        }
        while !released { condition.wait() }
        condition.unlock()
        return 0
    }

    func count(_ kind: PrecisionReviewedOutputKind) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return records.filter { $0.kind == kind }.count
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class ScriptedLifecycleReader:
    PrecisionTransportReportReader,
    @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [PrecisionTransportInputFrame]
    private var activeRequestID: UUID?
    private var cancelled: [UUID: PrecisionTransportReportIOError] = [:]

    init(frames: [PrecisionTransportInputFrame]) {
        self.frames = frames
    }

    func beginRequest(_ frame: PrecisionTransportOutputFrame) throws {
        try lock.withLock {
            guard activeRequestID == nil else {
                throw PrecisionWriteLifecycleError.singleFlightViolation
            }
            activeRequestID = frame.requestID
        }
    }

    func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame {
        try lock.withLock {
            if let reason = cancelled.removeValue(forKey: requestID) {
                throw reason
            }
            guard activeRequestID == requestID,
                  !frames.isEmpty else {
                throw PrecisionTransportReportIOError.timeout
            }
            return frames.removeFirst()
        }
    }

    func endRequest(_ requestID: UUID) {
        lock.withLock {
            if activeRequestID == requestID { activeRequestID = nil }
        }
    }

    func cancelRequest(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        lock.withLock {
            cancelled[requestID] = reason
            if activeRequestID == requestID { activeRequestID = nil }
        }
    }

    func disconnected() {
        lock.withLock {
            if let requestID = activeRequestID {
                cancelled[requestID] = .disconnected
            }
            activeRequestID = nil
        }
    }
}

private struct AlwaysAllowingLifecycleSafetyGate:
    PrecisionTemporaryDiversionSafetyGate {
    func acquire(
        for operation: PrecisionTemporaryDiversionOperation
    ) async throws -> any PrecisionTemporaryDiversionSafetyLease {
        _ = operation
        return AlwaysAllowingLifecycleSafetyLease()
    }
}

private final class AlwaysAllowingLifecycleSafetyLease:
    PrecisionTemporaryDiversionSafetyLease,
    @unchecked Sendable {
    func validate() throws {}
}

private final class WeakWriterBox: @unchecked Sendable {
    weak var writer: PrecisionBlockingWriteLifecycle?
}

private final class LifetimeAnchor: @unchecked Sendable {}

private final class RetentionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var anchor: LifetimeAnchor?
    private weak var writer: PrecisionBlockingWriteLifecycle?

    var bothAlive: Bool {
        lock.withLock { anchor != nil && writer != nil }
    }

    var bothReleased: Bool {
        lock.withLock { anchor == nil && writer == nil }
    }

    func store(anchor: LifetimeAnchor) {
        lock.withLock { self.anchor = anchor }
    }

    func store(writer: PrecisionBlockingWriteLifecycle?) {
        lock.withLock { self.writer = writer }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }

    func set() {
        lock.withLock { storage = true }
    }
}

private enum WriteLifecycleTestError: Error {
    case timedOut
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    _ predicate: @escaping @Sendable () -> Bool
) async throws {
    let started = DispatchTime.now().uptimeNanoseconds
    while !predicate() {
        guard DispatchTime.now().uptimeNanoseconds &- started
                < timeoutNanoseconds else {
            throw WriteLifecycleTestError.timedOut
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

private func padded(_ prefix: [UInt8]) -> [UInt8] {
    prefix + Array(
        repeating: 0,
        count: HIDPP20LongMessage.parameterCount - prefix.count
    )
}

private func reportingFrame(
    _ state: DeviceTransactionWireState,
    fixture: WriteFixture
) throws -> PrecisionTransportInputFrame {
    let response = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: fixture.binding.session.featureIndex,
        functionID: 2,
        softwareID: 0x0E,
        parameters: state.rawParameters
    )
    return PrecisionTransportInputFrame(
        reportType: .input,
        reportID: HIDPP20LongMessage.reportID,
        bytes: response.bytes,
        device: fixture.binding.session.device,
        connectionEpoch: fixture.binding.session.connectionEpoch,
        rootGeneration: fixture.binding.rootGeneration
    )
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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


@Test func verificationCancellationBeforeSchedulingMakesNoBlockingCall() async throws {
    let fixture = try writeFixture()
    let scheduler = ManualScheduler()
    let calls = LockedCounter()
    let writer = try makeWriter(fixture: fixture, scheduler: scheduler) { _ in calls.increment(); return 0 }
    var sequence = try PrecisionReadOnlyConnectionVerification(expectedSession: fixture.binding.session)
    let request = try sequence.beginOutputRequest()
    let frame = PrecisionTransportOutputFrame(requestID: request.requestID, reportType: .output,
        reportID: 0x11, bytes: request.message.bytes, device: fixture.binding.session.device,
        connectionEpoch: fixture.binding.session.connectionEpoch, rootGeneration: fixture.binding.rootGeneration,
        connectionVerification: request)
    let task = Task { try await writer.write(frame) }
    try await waitUntil { scheduler.count == 1 }
    writer.cancelPendingWrite(requestID: request.requestID, reason: .timeout)
    await #expect(throws: PrecisionTransportReportIOError.timeout) { try await task.value }
    scheduler.runNext()
    #expect(calls.value == 0)
    await writer.shutdownAndDrain()
}

@Test func verificationTimeoutAfterEntryRetainsOutputUntilPhysicalDrain() async throws {
    let fixture = try writeFixture()
    let gate = BlockingCallGate(returnCode: 0)
    let writer = try makeWriter(fixture: fixture, blockingCall: gate.invoke)
    var sequence = try PrecisionReadOnlyConnectionVerification(expectedSession: fixture.binding.session)
    let request = try sequence.beginOutputRequest()
    let frame = PrecisionTransportOutputFrame(requestID: request.requestID, reportType: .output,
        reportID: 0x11, bytes: request.message.bytes, device: fixture.binding.session.device,
        connectionEpoch: fixture.binding.session.connectionEpoch, rootGeneration: fixture.binding.rootGeneration,
        connectionVerification: request)
    let task = Task { try await writer.write(frame) }
    try await waitUntil { gate.entryCount == 1 }
    writer.cancelPendingWrite(requestID: request.requestID, reason: .timeout)
    await #expect(throws: PrecisionTransportReportIOError.timeout) { try await task.value }
    #expect(writer.isDraining)
    #expect(!writer.isStopped)
    let drain = Task { await writer.shutdownAndDrain() }
    gate.release()
    await drain.value
    #expect(writer.isStopped)
    #expect(writer.entryCount == 1)
}
