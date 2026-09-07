import Foundation
import MXErgoHIDPP
import Testing
@testable import MXErgoPrecisionIOHIDOwnership
@testable import MXErgoPrecisionTransport
@testable import MXErgoPrecisionWriteLifecycle

@Test func mismatchedEndpointOwnershipIsRejectedBeforeLifecycleWork() throws {
    let events = OwnershipEventRecorder()
    let firstToken = ownershipToken(events: events)
    let secondToken = ownershipToken(events: events)
    let input = FakeOwnedInput(token: firstToken, events: events)
    let output = FakeOwnedOutput(token: secondToken, events: events)

    #expect(throws: PrecisionIOHIDOwnershipError.deviceOwnershipMismatch) {
        try PrecisionIOHIDOwnershipCoordinator(input: input, output: output)
    }
    #expect(events.values.isEmpty)
    #expect(!firstToken.isReleased)
    #expect(!secondToken.isReleased)
}

@Test func admissionRemainsClosedUntilStartAndInitializedShutdownIsOrdered() async throws {
    let events = OwnershipEventRecorder()
    let token = ownershipToken(events: events)
    let input = FakeOwnedInput(token: token, events: events)
    let output = FakeOwnedOutput(token: token, events: events)
    let coordinator = try PrecisionIOHIDOwnershipCoordinator(
        input: input,
        output: output
    )
    let frame = outputFrame(requestID: UUID())

    await #expect(throws: PrecisionIOHIDOwnershipError.notStarted) {
        try await coordinator.write(frame)
    }
    #expect(throws: PrecisionIOHIDOwnershipError.notStarted) {
        try coordinator.beginRequest(frame)
    }

    await coordinator.shutdownAndDrain()

    #expect(events.values == [
        "output-drain-begin",
        "output-drain-end",
        "input-shutdown-begin",
        "input-shutdown-end",
        "release",
    ])
    #expect(coordinator.ownershipWasReleased)
    #expect(coordinator.ownershipReleaseCount == 1)
    #expect(await coordinator.isStopped)
}

@Test func activeCoordinatorForwardsOnlyThroughItsOwnedEndpoints() async throws {
    let events = OwnershipEventRecorder()
    let token = ownershipToken(events: events)
    let input = FakeOwnedInput(token: token, events: events)
    let output = FakeOwnedOutput(
        token: token,
        events: events,
        writeReturnCode: 27
    )
    let coordinator = try PrecisionIOHIDOwnershipCoordinator(
        input: input,
        output: output
    )
    let requestID = UUID()
    let frame = outputFrame(requestID: requestID)

    try await coordinator.start()
    #expect(coordinator.isAcceptingRequests)
    #expect(try await coordinator.write(frame) == 27)
    try coordinator.beginRequest(frame)
    _ = try await coordinator.read(for: requestID)
    coordinator.endRequest(requestID)
    coordinator.cancelRequest(requestID, reason: .cancelled)
    coordinator.cancelPendingWrite(requestID: requestID, reason: .timeout)
    coordinator.disconnected()

    #expect(events.values == [
        "input-start",
        "output-write",
        "input-begin",
        "input-read",
        "input-end",
        "input-cancel",
        "output-cancel",
        "input-disconnected",
    ])

    await coordinator.shutdownAndDrain()
    #expect(Array(events.values.suffix(5)) == [
        "output-drain-begin",
        "output-drain-end",
        "input-shutdown-begin",
        "input-shutdown-end",
        "release",
    ])
}

@Test func shutdownClosesAdmissionThenDrainsOutputThenQuiescesInputThenReleases() async throws {
    let events = OwnershipEventRecorder()
    let outputGate = AsyncOwnershipGate()
    let inputGate = BlockingOwnershipGate()
    let token = ownershipToken(events: events)
    let input = FakeOwnedInput(
        token: token,
        events: events,
        shutdownGate: inputGate
    )
    let output = FakeOwnedOutput(
        token: token,
        events: events,
        drainGate: outputGate
    )
    let coordinator = try PrecisionIOHIDOwnershipCoordinator(
        input: input,
        output: output
    )
    try await coordinator.start()
    try coordinator.validateActiveConnection()
    let shutdown = Task { await coordinator.shutdownAndDrain() }

    try await waitUntil { events.contains("output-drain-begin") }
    #expect(!coordinator.isAcceptingRequests)
    try input.validateActiveConnection()
    #expect(throws: PrecisionIOHIDOwnershipError.shuttingDown) {
        try coordinator.validateActiveConnection()
    }
    #expect(!events.contains("input-shutdown-begin"))
    #expect(!events.contains("release"))
    await #expect(throws: PrecisionIOHIDOwnershipError.shuttingDown) {
        try await coordinator.write(outputFrame(requestID: UUID()))
    }
    #expect(throws: PrecisionIOHIDOwnershipError.shuttingDown) {
        try coordinator.beginRequest(outputFrame(requestID: UUID()))
    }

    await outputGate.release()
    try await waitUntil { events.contains("input-shutdown-begin") }
    #expect(!events.contains("release"))
    inputGate.release()
    await shutdown.value

    #expect(events.values == [
        "input-start",
        "output-drain-begin",
        "output-drain-end",
        "input-shutdown-begin",
        "input-shutdown-end",
        "release",
    ])
    #expect(coordinator.ownershipWasReleased)
    #expect(await coordinator.isStopped)
}

@Test func failedInputStartRunsTheSameRollbackBeforeRethrowing() async throws {
    let events = OwnershipEventRecorder()
    let token = ownershipToken(events: events)
    let input = FakeOwnedInput(
        token: token,
        events: events,
        startError: EndpointFailure.start
    )
    let output = FakeOwnedOutput(token: token, events: events)
    let coordinator = try PrecisionIOHIDOwnershipCoordinator(
        input: input,
        output: output
    )

    await #expect(throws: EndpointFailure.start) {
        try await coordinator.start()
    }

    #expect(events.values == [
        "input-start",
        "output-drain-begin",
        "output-drain-end",
        "input-shutdown-begin",
        "input-shutdown-end",
        "release",
    ])
    #expect(coordinator.ownershipReleaseCount == 1)
    #expect(await coordinator.isStopped)
    await #expect(throws: PrecisionIOHIDOwnershipError.permanentlyStopped) {
        try await coordinator.start()
    }
}

@Test func concurrentShutdownCallersShareOneStickyTeardown() async throws {
    let events = OwnershipEventRecorder()
    let outputGate = AsyncOwnershipGate()
    let token = ownershipToken(events: events)
    let input = FakeOwnedInput(token: token, events: events)
    let output = FakeOwnedOutput(
        token: token,
        events: events,
        drainGate: outputGate
    )
    let coordinator = try PrecisionIOHIDOwnershipCoordinator(
        input: input,
        output: output
    )
    try await coordinator.start()

    let first = Task { await coordinator.shutdownAndDrain() }
    let second = Task { await coordinator.shutdownAndDrain() }
    let third = Task { await coordinator.shutdownAndDrain() }
    try await waitUntil { events.count("output-drain-begin") == 1 }
    await outputGate.release()
    await first.value
    await second.value
    await third.value
    await coordinator.shutdownAndDrain()

    #expect(events.count("output-drain-begin") == 1)
    #expect(events.count("input-shutdown-begin") == 1)
    #expect(events.count("release") == 1)
    #expect(coordinator.ownershipReleaseCount == 1)
}

@Test func retainedAnchorSurvivesBothQuiescenceBoundariesAndReleasesAfterInput() async throws {
    let events = OwnershipEventRecorder()
    let outputGate = AsyncOwnershipGate()
    let inputGate = BlockingOwnershipGate()
    let retention = OwnershipRetentionProbe()
    let token: PrecisionIOHIDOwnershipToken
    do {
        let anchor = OwnershipLifetimeAnchor()
        retention.store(anchor)
        token = PrecisionIOHIDOwnershipToken(
            retainedAnchor: anchor,
            releaseHook: { events.record("release") }
        )
    }
    let input = FakeOwnedInput(
        token: token,
        events: events,
        shutdownGate: inputGate
    )
    let output = FakeOwnedOutput(
        token: token,
        events: events,
        drainGate: outputGate
    )
    let coordinator = try PrecisionIOHIDOwnershipCoordinator(
        input: input,
        output: output
    )
    try await coordinator.start()
    let shutdown = Task { await coordinator.shutdownAndDrain() }

    try await waitUntil { events.contains("output-drain-begin") }
    #expect(retention.isAlive)
    await outputGate.release()
    try await waitUntil { events.contains("input-shutdown-begin") }
    #expect(retention.isAlive)

    inputGate.release()
    await shutdown.value
    try await waitUntil { !retention.isAlive }
    #expect(events.values.last == "release")
}

@Test func abandoningActiveCoordinatorQuarantinesTheCompleteEndpointBundle() async throws {
    let events = OwnershipEventRecorder()
    let retention = OwnershipBundleRetentionProbe()
    do {
        let anchor = OwnershipLifetimeAnchor()
        let token = PrecisionIOHIDOwnershipToken(
            retainedAnchor: anchor,
            releaseHook: { events.record("release") }
        )
        let input = FakeOwnedInput(token: token, events: events)
        let output = FakeOwnedOutput(token: token, events: events)
        retention.store(anchor: anchor, input: input, output: output)
        let coordinator = try PrecisionIOHIDOwnershipCoordinator(
            input: input,
            output: output
        )
        try await coordinator.start()
    }

    #expect(retention.anchorIsAlive)
    #expect(retention.inputIsAlive)
    #expect(retention.outputIsAlive)
    #expect(!events.contains("release"))
    #expect(events.values == ["input-start"])
}

@Test func oneOwnershipTokenCannotBindASecondEndpointPair() throws {
    let events = OwnershipEventRecorder()
    let token = ownershipToken(events: events)
    let firstInput = FakeOwnedInput(token: token, events: events)
    let firstOutput = FakeOwnedOutput(token: token, events: events)
    _ = try PrecisionIOHIDOwnershipCoordinator(
        input: firstInput,
        output: firstOutput
    )

    #expect(throws: PrecisionIOHIDOwnershipError.ownershipTokenAlreadyBound) {
        try PrecisionIOHIDOwnershipCoordinator(
            input: FakeOwnedInput(token: token, events: events),
            output: FakeOwnedOutput(token: token, events: events)
        )
    }
}

@Test func ownershipTargetRemainsPureProductlessAndCapabilityMinimal() throws {
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
    #expect(!products.contains("MXErgoPrecisionIOHIDOwnership"))
    #expect(manifest.components(
        separatedBy: "\"MXErgoPrecisionIOHIDOwnership\""
    ).count - 1 == 7)

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
    #expect(!projectYAML.contains("MXErgoPrecisionIOHIDOwnership"))
    #expect(!projectFile.contains("MXErgoPrecisionIOHIDOwnership"))

    let source = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionIOHIDOwnership"
        )
    )
    for forbidden in [
        "import IOKit",
        "IOHIDDevice",
        "IOHIDManager",
        "SetReport",
        "@main",
        "ProcessInfo.processInfo.environment",
        "public ",
    ] {
        #expect(!source.contains(forbidden))
    }
    let packageLines = source.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("package ") }
    #expect(packageLines == [
        "package protocol PrecisionIOHIDInputLifetime:",
        "package protocol PrecisionIOHIDQuiescentReleaseAnchor: AnyObject, Sendable {",
        "package protocol PrecisionIOHIDAssembledEndpoint:",
        // Read-only input diagnostics, added 2026-09-04 so a hardware
        // session can tell "the device sent nothing" from "the runtime
        // refused what it sent". They gate nothing.
        "package func inputDiagnostics() -> PrecisionInputDiagnostics? { nil }",
        "package func inputDiagnostics() -> PrecisionInputDiagnostics? { nil }",
        "package enum PrecisionIOHIDOwnershipFactory {",
        "package static func make(",
        "package func inputDiagnostics() -> PrecisionInputDiagnostics? {",
        "package func inputDiagnostics() -> PrecisionInputDiagnostics? {",
    ])

    let inputSource = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionIOHIDInput"
        )
    )
    let outputSource = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionIOHIDOutput"
        )
    )
    #expect(!inputSource.contains("package init("))
    #expect(!outputSource.contains("package init("))
    #expect(outputSource.contains("fileprivate convenience init("))
    #expect(!outputSource.contains("\n    private convenience init("))
}

private enum EndpointFailure: Error, Sendable, Equatable {
    case start
}

private final class FakeOwnedInput:
    PrecisionIOHIDOwnedInputEndpoint,
    @unchecked Sendable {
    let ownershipToken: PrecisionIOHIDOwnershipToken
    private let events: OwnershipEventRecorder
    private let startError: EndpointFailure?
    private let shutdownGate: BlockingOwnershipGate?

    init(
        token: PrecisionIOHIDOwnershipToken,
        events: OwnershipEventRecorder,
        startError: EndpointFailure? = nil,
        shutdownGate: BlockingOwnershipGate? = nil
    ) {
        ownershipToken = token
        self.events = events
        self.startError = startError
        self.shutdownGate = shutdownGate
    }

    func start() throws {
        events.record("input-start")
        if let startError { throw startError }
    }

    func shutdownAndWait() {
        events.record("input-shutdown-begin")
        shutdownGate?.wait()
        events.record("input-shutdown-end")
    }

    func validateActiveConnection() throws {
        guard events.contains("input-start"), !events.contains("input-shutdown-begin") else {
            throw PrecisionTransportReportIOError.disconnected
        }
    }

    func beginRequest(_ frame: PrecisionTransportOutputFrame) throws {
        _ = frame
        events.record("input-begin")
    }

    func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame {
        _ = requestID
        events.record("input-read")
        return inputFrame()
    }

    func endRequest(_ requestID: UUID) {
        _ = requestID
        events.record("input-end")
    }

    func cancelRequest(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        _ = requestID
        _ = reason
        events.record("input-cancel")
    }

    func disconnected() {
        events.record("input-disconnected")
    }
}

private final class FakeOwnedOutput:
    PrecisionIOHIDOwnedOutputEndpoint,
    @unchecked Sendable {
    let ownershipToken: PrecisionIOHIDOwnershipToken
    private let events: OwnershipEventRecorder
    private let drainGate: AsyncOwnershipGate?
    private let writeReturnCode: Int32

    init(
        token: PrecisionIOHIDOwnershipToken,
        events: OwnershipEventRecorder,
        drainGate: AsyncOwnershipGate? = nil,
        writeReturnCode: Int32 = 0
    ) {
        ownershipToken = token
        self.events = events
        self.drainGate = drainGate
        self.writeReturnCode = writeReturnCode
    }

    func write(_ frame: PrecisionTransportOutputFrame) async throws -> Int32 {
        _ = frame
        events.record("output-write")
        return writeReturnCode
    }

    func cancelPendingWrite(
        requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        _ = requestID
        _ = reason
        events.record("output-cancel")
    }

    func shutdownAndDrain() async {
        events.record("output-drain-begin")
        await drainGate?.wait()
        events.record("output-drain-end")
    }
}

private final class OwnershipEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func record(_ event: String) {
        lock.withLock { storage.append(event) }
    }

    func contains(_ event: String) -> Bool {
        lock.withLock { storage.contains(event) }
    }

    func count(_ event: String) -> Int {
        lock.withLock { storage.filter { $0 == event }.count }
    }
}

private actor AsyncOwnershipGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

private final class BlockingOwnershipGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    func wait() {
        condition.lock()
        while !isOpen { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class OwnershipLifetimeAnchor: @unchecked Sendable {}

private final class OwnershipRetentionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var anchor: OwnershipLifetimeAnchor?

    var isAlive: Bool { lock.withLock { anchor != nil } }

    func store(_ anchor: OwnershipLifetimeAnchor) {
        lock.withLock { self.anchor = anchor }
    }
}

private final class OwnershipBundleRetentionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var anchor: OwnershipLifetimeAnchor?
    private weak var input: FakeOwnedInput?
    private weak var output: FakeOwnedOutput?

    var anchorIsAlive: Bool { lock.withLock { anchor != nil } }
    var inputIsAlive: Bool { lock.withLock { input != nil } }
    var outputIsAlive: Bool { lock.withLock { output != nil } }

    func store(
        anchor: OwnershipLifetimeAnchor,
        input: FakeOwnedInput,
        output: FakeOwnedOutput
    ) {
        lock.withLock {
            self.anchor = anchor
            self.input = input
            self.output = output
        }
    }
}

private func ownershipToken(
    events: OwnershipEventRecorder
) -> PrecisionIOHIDOwnershipToken {
    PrecisionIOHIDOwnershipToken(
        retainedAnchor: OwnershipLifetimeAnchor(),
        releaseHook: { events.record("release") }
    )
}

private func outputFrame(requestID: UUID) -> PrecisionTransportOutputFrame {
    PrecisionTransportOutputFrame(
        requestID: requestID,
        reportType: .output,
        reportID: HIDPP20LongMessage.reportID,
        bytes: Array(repeating: 0, count: HIDPP20LongMessage.byteCount),
        device: testDevice(),
        connectionEpoch: 9,
        rootGeneration: 12
    )
}

private func inputFrame() -> PrecisionTransportInputFrame {
    PrecisionTransportInputFrame(
        reportType: .input,
        reportID: HIDPP20LongMessage.reportID,
        bytes: Array(repeating: 0, count: HIDPP20LongMessage.byteCount),
        device: testDevice(),
        connectionEpoch: 9,
        rootGeneration: 12
    )
}

private func testDevice() -> JournalDeviceIdentity {
    JournalDeviceIdentity(
        deviceID: "1133-45085-42-1-2",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "OWNERSHIP-TEST",
        locationID: 42,
        firmwareIdentity: "ownership-test-firmware"
    )
}

private enum OwnershipTestError: Error {
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
            throw OwnershipTestError.timedOut
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
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
