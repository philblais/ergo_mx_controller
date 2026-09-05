import Foundation
import MXErgoHIDPP
import Testing
@testable import MXErgoPrecisionIOHIDAssembly
@testable import MXErgoPrecisionIOHIDOwnership
@testable import MXErgoPrecisionTransport
@testable import MXErgoPrecisionWriteLifecycle

@Test func sourceAssemblyReleasesExplicitAnchorOnlyAfterBothBarriers() async throws {
    let events = AssemblyEventRecorder()
    let identities = HandleIdentityRecorder()
    let outputGate = AsyncAssemblyGate()
    let inputGate = BlockingAssemblyGate()
    let retention = AssemblyRetentionProbe()
    let assembly: PrecisionIOHIDDeviceAssembly

    do {
        let handle = AssemblyLifetimeAnchor()
        let input = FakeAssemblyInput(
            events: events,
            shutdownGate: inputGate
        )
        let output = FakeAssemblyOutput(
            events: events,
            drainGate: outputGate
        )
        retention.store(anchor: handle, input: input, output: output)
        assembly = try PrecisionIOHIDDeviceAssembly(
            testingTransferredHandle: handle,
            makeInput: { received in
                identities.record("input", handle: received)
                return input
            },
            makeOutput: { received in
                identities.record("output", handle: received)
                return output
            },
            makeQuiescentReleaseAnchor: { received in
                FakeAssemblyReleaseAnchor(
                    retaining: received,
                    events: events
                )
            }
        )
    }

    #expect(events.values.isEmpty)
    #expect(identities.sameHandleReachedBothFactories)
    #expect(retention.allAlive)
    try await assembly.start()

    let shutdown = Task { await assembly.shutdownAndDrain() }
    try await waitUntil { events.contains("output-drain-begin") }
    shutdown.cancel()
    #expect(retention.allAlive)
    await #expect(throws: PrecisionIOHIDOwnershipError.shuttingDown) {
        try await assembly.write(outputFrame(requestID: UUID()))
    }

    await outputGate.release()
    try await waitUntil { events.contains("input-shutdown-begin") }
    try await waitUntil { !retention.outputIsAlive }
    #expect(retention.inputIsAlive)
    #expect(retention.anchorIsAlive)

    inputGate.release()
    await shutdown.value
    try await waitUntil { !retention.inputIsAlive }
    try await waitUntil { !retention.anchorIsAlive }

    #expect(events.values == [
        "input-start",
        "output-drain-begin",
        "output-drain-end",
        "output-deinit",
        "input-shutdown-begin",
        "input-shutdown-end",
        "input-deinit",
        "anchor-release",
    ])
    await assembly.shutdownAndDrain()
    #expect(events.count("output-drain-begin") == 1)
    #expect(events.count("input-shutdown-begin") == 1)
    #expect(events.count("anchor-release") == 1)
}

@Test func sourceAssemblyStartFailureUsesTheSameOrderedReleasePath() async throws {
    let events = AssemblyEventRecorder()
    let retention = AssemblyRetentionProbe()
    let assembly: PrecisionIOHIDDeviceAssembly

    do {
        let handle = AssemblyLifetimeAnchor()
        let input = FakeAssemblyInput(
            events: events,
            startError: AssemblyFailure.start
        )
        let output = FakeAssemblyOutput(events: events)
        retention.store(anchor: handle, input: input, output: output)
        assembly = try PrecisionIOHIDDeviceAssembly(
            testingTransferredHandle: handle,
            makeInput: { _ in input },
            makeOutput: { _ in output },
            makeQuiescentReleaseAnchor: { received in
                FakeAssemblyReleaseAnchor(
                    retaining: received,
                    events: events
                )
            }
        )
    }

    await #expect(throws: AssemblyFailure.start) {
        try await assembly.start()
    }
    try await waitUntil { !retention.inputIsAlive }
    try await waitUntil { !retention.outputIsAlive }
    try await waitUntil { !retention.anchorIsAlive }

    #expect(events.values == [
        "input-start",
        "output-drain-begin",
        "output-drain-end",
        "output-deinit",
        "input-shutdown-begin",
        "input-shutdown-end",
        "input-deinit",
        "anchor-release",
    ])
}

@Test func inputConstructionFailureCreatesNoOutputOrOwnershipBundle() throws {
    let calls = ConstructionCallRecorder()
    let retention = AssemblyRetentionProbe()
    do {
        let handle = AssemblyLifetimeAnchor()
        retention.store(anchor: handle)
        #expect(throws: AssemblyFailure.inputConstruction) {
            try PrecisionIOHIDDeviceAssembly(
                testingTransferredHandle: handle,
                makeInput: { received in
                    calls.record("input", handle: received)
                    throw AssemblyFailure.inputConstruction
                },
                makeOutput: { received in
                    calls.record("output", handle: received)
                    return FakeAssemblyOutput(events: AssemblyEventRecorder())
                }
            )
        }
    }

    #expect(calls.events == ["input"])
    #expect(!retention.anchorIsAlive)
}

@Test func outputConstructionFailureStopsInactiveInputBeforeRelease() throws {
    let calls = ConstructionCallRecorder()
    let events = AssemblyEventRecorder()
    let retention = AssemblyRetentionProbe()
    do {
        let handle = AssemblyLifetimeAnchor()
        let input = FakeAssemblyInput(events: events)
        retention.store(anchor: handle, input: input)
        #expect(throws: AssemblyFailure.outputConstruction) {
            try PrecisionIOHIDDeviceAssembly(
                testingTransferredHandle: handle,
                makeInput: { received in
                    calls.record("input", handle: received)
                    return input
                },
                makeOutput: { received in
                    calls.record("output", handle: received)
                    throw AssemblyFailure.outputConstruction
                }
            )
        }
    }

    #expect(calls.events == ["input", "output"])
    #expect(calls.sameHandleReachedBothFactories)
    #expect(events.values == [
        "input-shutdown-begin",
        "input-shutdown-end",
        "input-deinit",
    ])
    #expect(!retention.inputIsAlive)
    #expect(!retention.anchorIsAlive)
}

@Test func abandoningActiveSourceAssemblyQuarantinesTheCompleteBundle() async throws {
    let events = AssemblyEventRecorder()
    let retention = AssemblyRetentionProbe()
    do {
        let handle = AssemblyLifetimeAnchor()
        let input = FakeAssemblyInput(events: events)
        let output = FakeAssemblyOutput(events: events)
        retention.store(anchor: handle, input: input, output: output)
        let assembly = try PrecisionIOHIDDeviceAssembly(
            testingTransferredHandle: handle,
            makeInput: { _ in input },
            makeOutput: { _ in output },
            makeQuiescentReleaseAnchor: { received in
                FakeAssemblyReleaseAnchor(
                    retaining: received,
                    events: events
                )
            }
        )
        try await assembly.start()
    }

    #expect(retention.anchorIsAlive)
    #expect(retention.inputIsAlive)
    #expect(retention.outputIsAlive)
    #expect(!events.contains("anchor-release"))
    #expect(events.values == ["input-start"])
}

@Test func assemblySourceIsProductlessUnwiredAndCapabilityMinimal() throws {
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
    #expect(!products.contains("MXErgoPrecisionIOHIDAssembly"))
    #expect(manifest.components(
        separatedBy: "\"MXErgoPrecisionIOHIDAssembly\""
    ).count - 1 == 3)
    #expect(manifest.components(
        separatedBy: "\"MXErgoPrecisionIOHIDAssemblyTests\""
    ).count - 1 == 1)

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
    #expect(!projectYAML.contains("MXErgoPrecisionIOHIDAssembly"))
    #expect(!projectFile.contains("MXErgoPrecisionIOHIDAssembly"))

    let assemblySource = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionIOHIDAssembly"
        )
    )
    let forbiddenAssemblyTokens = [
        "IOHID" + "Manager",
        "IOHIDDevice" + "Open",
        "IOHIDDevice" + "Close",
        "IOHIDDevice" + "SetReport",
        "@" + "main",
        "ProcessInfo.processInfo." + "environment",
        "public ",
        "@_spi",
    ]
    for forbidden in forbiddenAssemblyTokens {
        #expect(!assemblySource.contains(forbidden))
    }
    #expect(packageDeclarationLines(in: assemblySource) == [
        "package enum PrecisionIOHIDAssemblyFactory {",
        "package static func make(",
        // Read-only input diagnostics, added 2026-09-04 so a hardware
        // session can tell "the device sent nothing" from "the runtime
        // refused what it sent". They gate nothing.
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
    let ownershipSource = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionIOHIDOwnership"
        )
    )
    #expect(packageDeclarationLines(in: inputSource) == [
        // Read-only input diagnostics, added 2026-09-04 so a hardware
        // session can tell "the device sent nothing" from "the runtime
        // refused what it sent". They gate nothing.
        "package func inputDiagnostics() -> PrecisionInputDiagnostics? {",
        "package enum PrecisionIOHIDInputFactory {",
        "package static func make(",
    ])
    #expect(packageDeclarationLines(in: outputSource) == [
        "package enum PrecisionIOHIDOutputFactory {",
        "package static func make(",
    ])
    #expect(packageDeclarationLines(in: ownershipSource) == [
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
    #expect(outputSource.contains("fileprivate convenience init("))
    #expect(!outputSource.contains("package init("))
    #expect(!inputSource.contains("package init("))

    let precisionSource = [
        inputSource,
        outputSource,
        ownershipSource,
        assemblySource,
    ].joined(separator: "\n")
    let setReportSymbol = "IOHIDDevice" + "SetReport"
    #expect(precisionSource.components(
        separatedBy: setReportSymbol
    ).count - 1 == 1)
}

private enum AssemblyFailure: Error, Sendable, Equatable {
    case inputConstruction
    case outputConstruction
    case start
    case timedOut
}

private final class FakeAssemblyInput:
    PrecisionIOHIDInputLifetime,
    @unchecked Sendable {
    private let events: AssemblyEventRecorder
    private let startError: AssemblyFailure?
    private let shutdownGate: BlockingAssemblyGate?

    init(
        events: AssemblyEventRecorder,
        startError: AssemblyFailure? = nil,
        shutdownGate: BlockingAssemblyGate? = nil
    ) {
        self.events = events
        self.startError = startError
        self.shutdownGate = shutdownGate
    }

    deinit { events.record("input-deinit") }

    func start() throws {
        events.record("input-start")
        if let startError { throw startError }
    }

    func shutdownAndWait() {
        events.record("input-shutdown-begin")
        shutdownGate?.wait()
        events.record("input-shutdown-end")
    }

    func beginRequest(_ frame: PrecisionTransportOutputFrame) throws {
        _ = frame
    }

    func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame {
        _ = requestID
        return inputFrame()
    }

    func endRequest(_ requestID: UUID) { _ = requestID }

    func cancelRequest(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        _ = requestID
        _ = reason
    }

    func disconnected() {}
}

private final class FakeAssemblyOutput:
    PrecisionTransportDrainingReportWriter,
    @unchecked Sendable {
    private let events: AssemblyEventRecorder
    private let drainGate: AsyncAssemblyGate?

    init(events: AssemblyEventRecorder, drainGate: AsyncAssemblyGate? = nil) {
        self.events = events
        self.drainGate = drainGate
    }

    deinit { events.record("output-deinit") }

    func write(_ frame: PrecisionTransportOutputFrame) async throws -> Int32 {
        _ = frame
        return 0
    }

    func cancelPendingWrite(
        requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        _ = requestID
        _ = reason
    }

    func shutdownAndDrain() async {
        events.record("output-drain-begin")
        await drainGate?.wait()
        events.record("output-drain-end")
    }
}

private final class AssemblyEventRecorder: @unchecked Sendable {
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

private final class HandleIdentityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [String: ObjectIdentifier] = [:]

    var sameHandleReachedBothFactories: Bool {
        lock.withLock {
            guard let input = identities["input"],
                  let output = identities["output"] else { return false }
            return input == output
        }
    }

    func record(_ phase: String, handle: AnyObject) {
        lock.withLock { identities[phase] = ObjectIdentifier(handle) }
    }
}

private final class ConstructionCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var eventStorage: [String] = []
    private var identities: [ObjectIdentifier] = []

    var events: [String] { lock.withLock { eventStorage } }
    var sameHandleReachedBothFactories: Bool {
        lock.withLock {
            identities.count == 2 && identities[0] == identities[1]
        }
    }

    func record(_ event: String, handle: AnyObject) {
        lock.withLock {
            eventStorage.append(event)
            identities.append(ObjectIdentifier(handle))
        }
    }
}

private actor AsyncAssemblyGate {
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

private final class BlockingAssemblyGate: @unchecked Sendable {
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

private final class AssemblyLifetimeAnchor: @unchecked Sendable {}

private final class FakeAssemblyReleaseAnchor:
    PrecisionIOHIDQuiescentReleaseAnchor,
    @unchecked Sendable {
    private let lock = NSLock()
    private var retainedHandle: AnyObject?
    private let events: AssemblyEventRecorder

    init(retaining handle: AnyObject, events: AssemblyEventRecorder) {
        retainedHandle = handle
        self.events = events
    }

    func releaseAfterEndpointQuiescence() {
        lock.withLock { retainedHandle = nil }
        events.record("anchor-release")
    }
}

private final class AssemblyRetentionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var anchor: AssemblyLifetimeAnchor?
    private weak var input: FakeAssemblyInput?
    private weak var output: FakeAssemblyOutput?

    var anchorIsAlive: Bool { lock.withLock { anchor != nil } }
    var inputIsAlive: Bool { lock.withLock { input != nil } }
    var outputIsAlive: Bool { lock.withLock { output != nil } }
    var allAlive: Bool {
        lock.withLock { anchor != nil && input != nil && output != nil }
    }

    func store(
        anchor: AssemblyLifetimeAnchor,
        input: FakeAssemblyInput? = nil,
        output: FakeAssemblyOutput? = nil
    ) {
        lock.withLock {
            self.anchor = anchor
            self.input = input
            self.output = output
        }
    }
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
        serialNumber: "ASSEMBLY-TEST",
        locationID: 42,
        firmwareIdentity: "assembly-test-firmware"
    )
}

private func packageDeclarationLines(in source: String) -> [String] {
    source.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("package ") }
}

private func sourceText(under directory: URL) throws -> String {
    let enumerator = try #require(
        FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        )
    )
    let files = enumerator.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
    return try files.map {
        try String(contentsOf: $0, encoding: .utf8)
    }.joined(separator: "\n")
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    _ predicate: @escaping @Sendable () -> Bool
) async throws {
    let started = DispatchTime.now().uptimeNanoseconds
    while !predicate() {
        guard DispatchTime.now().uptimeNanoseconds &- started
                < timeoutNanoseconds else {
            throw AssemblyFailure.timedOut
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
