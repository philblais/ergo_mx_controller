import Foundation
import MXErgoHIDPP
import Testing
@testable import MXErgoPrecisionIOHIDOutput
@testable import MXErgoPrecisionTransport
@testable import MXErgoPrecisionWriteLifecycle

@Test func outputWriterConstructionPerformsNoOutputCall() throws {
    let fixture = try outputFixture()
    let runtime = RecordingOutputRuntime(descriptor: validDescriptor())

    _ = try PrecisionIOHIDOutputWriter(
        plan: fixture.plan,
        binding: fixture.binding,
        runtime: runtime
    )

    #expect(runtime.calls.isEmpty)
}

@Test func exactReviewedFramesProduceOneExactCallAndReturnEachIOReturn() async throws {
    let fixture = try outputFixture()
    let runtime = RecordingOutputRuntime(
        descriptor: validDescriptor(),
        returnCodes: [0, -77, 19]
    )
    let writer = try PrecisionIOHIDOutputWriter(
        plan: fixture.plan,
        binding: fixture.binding,
        runtime: runtime
    )
    let getID = UUID()
    let applyID = UUID()
    let restoreID = UUID()

    #expect(try await writer.write(
        outputFrame(.getReporting, getID, fixture)
    ) == 0)
    #expect(try await writer.write(
        outputFrame(.applyTemporaryDiversion, applyID, fixture)
    ) == -77)
    #expect(try await writer.write(
        outputFrame(.restoreTemporaryDiversion, restoreID, fixture)
    ) == 19)

    #expect(runtime.calls == [
        RecordedOutputCall(
            reportID: HIDPP20LongMessage.reportID,
            bytes: fixture.plan.verificationRequest.bytes
        ),
        RecordedOutputCall(
            reportID: HIDPP20LongMessage.reportID,
            bytes: fixture.plan.applySetRequest.bytes
        ),
        RecordedOutputCall(
            reportID: HIDPP20LongMessage.reportID,
            bytes: fixture.plan.restoreSetRequest.bytes
        ),
    ])
    await #expect(throws: PrecisionWriteLifecycleError.duplicateRequest(getID)) {
        try await writer.write(outputFrame(.getReporting, getID, fixture))
    }
    #expect(runtime.calls.count == 3)
    await writer.shutdownAndDrain()
}

@Test func everyPhysicalIdentityAndOutputCapabilityMismatchFailsBeforeCall() throws {
    let fixture = try outputFixture()
    for mutation in DescriptorMutation.allCases {
        let runtime = RecordingOutputRuntime(
            descriptor: descriptor(mutation: mutation)
        )
        switch mutation.expectedError {
        case .invalidPhysicalIdentity:
            #expect(throws: PrecisionIOHIDOutputError.invalidPhysicalIdentity) {
                try PrecisionIOHIDOutputWriter(
                    plan: fixture.plan,
                    binding: fixture.binding,
                    runtime: runtime
                )
            }
        case .invalidOutputReportCapability:
            #expect(throws: PrecisionIOHIDOutputError.invalidOutputReportCapability) {
                try PrecisionIOHIDOutputWriter(
                    plan: fixture.plan,
                    binding: fixture.binding,
                    runtime: runtime
                )
            }
        }
        #expect(runtime.calls.isEmpty)
    }
}

@Test func invalidPlanBindingAndFramesNeverReachTheRuntime() async throws {
    let fixture = try outputFixture()
    let invalidSession = DeviceTransactionSession(
        device: fixture.binding.session.device,
        featureID: fixture.binding.session.featureID,
        featureVersion: fixture.binding.session.featureVersion,
        featureIndex: fixture.binding.session.featureIndex + 1,
        connectionEpoch: fixture.binding.session.connectionEpoch
    )
    let invalidBindingRuntime = RecordingOutputRuntime(
        descriptor: validDescriptor()
    )
    #expect(throws: PrecisionWriteLifecycleError.invalidBinding) {
        try PrecisionIOHIDOutputWriter(
            plan: fixture.plan,
            binding: PrecisionTransportBinding(
                session: invalidSession,
                rootGeneration: fixture.binding.rootGeneration
            ),
            runtime: invalidBindingRuntime
        )
    }
    #expect(invalidBindingRuntime.calls.isEmpty)

    let runtime = RecordingOutputRuntime(descriptor: validDescriptor())
    let writer = try PrecisionIOHIDOutputWriter(
        plan: fixture.plan,
        binding: fixture.binding,
        runtime: runtime
    )
    let valid = outputFrame(.applyTemporaryDiversion, UUID(), fixture)
    for index in valid.bytes.indices {
        var bytes = valid.bytes
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
            bytes: Array(valid.bytes.dropLast()),
            fixture: fixture
        ),
        outputFrame(
            requestID: UUID(),
            bytes: valid.bytes + [0],
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
    #expect(runtime.calls.isEmpty)
    await writer.shutdownAndDrain()
}

@Test func cancellationBeforeWriteIsStickyAndProducesZeroCalls() async throws {
    let fixture = try outputFixture()
    let runtime = RecordingOutputRuntime(descriptor: validDescriptor())
    let writer = try PrecisionIOHIDOutputWriter(
        plan: fixture.plan,
        binding: fixture.binding,
        runtime: runtime
    )
    let requestID = UUID()

    writer.cancelPendingWrite(requestID: requestID, reason: .cancelled)

    await #expect(throws: PrecisionTransportReportIOError.cancelled) {
        try await writer.write(
            outputFrame(.applyTemporaryDiversion, requestID, fixture)
        )
    }
    #expect(runtime.calls.isEmpty)
    await writer.shutdownAndDrain()
}

@Test func enteredCancellationIsPromptAndShutdownWaitsForPhysicalReturn() async throws {
    let fixture = try outputFixture()
    let gate = BlockingOutputGate()
    let runtime = RecordingOutputRuntime(
        descriptor: validDescriptor(),
        gate: gate
    )
    let writer = try PrecisionIOHIDOutputWriter(
        plan: fixture.plan,
        binding: fixture.binding,
        runtime: runtime
    )
    let requestID = UUID()
    let writeFinished = LockedFlag()
    let write = Task {
        defer { writeFinished.set() }
        return try await writer.write(
            outputFrame(.applyTemporaryDiversion, requestID, fixture)
        )
    }

    try await waitUntil { runtime.calls.count == 1 }
    writer.cancelPendingWrite(requestID: requestID, reason: .timeout)
    try await waitUntil { writeFinished.value }
    await #expect(throws: PrecisionTransportReportIOError.timeout) {
        try await write.value
    }

    let drainFinished = LockedFlag()
    let drain = Task {
        await writer.shutdownAndDrain()
        drainFinished.set()
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(!drainFinished.value)
    #expect(runtime.calls.count == 1)

    gate.release()
    await drain.value
    #expect(drainFinished.value)
    #expect(runtime.calls.count == 1)
    await writer.shutdownAndDrain()
}

@Test func concurrentAndDuplicateRequestsCannotProduceASecondRuntimeCall() async throws {
    let fixture = try outputFixture()
    let gate = BlockingOutputGate()
    let runtime = RecordingOutputRuntime(
        descriptor: validDescriptor(),
        gate: gate
    )
    let writer = try PrecisionIOHIDOutputWriter(
        plan: fixture.plan,
        binding: fixture.binding,
        runtime: runtime
    )
    let firstID = UUID()
    let first = Task {
        try await writer.write(
            outputFrame(.getReporting, firstID, fixture)
        )
    }
    try await waitUntil { runtime.calls.count == 1 }

    await #expect(throws: PrecisionWriteLifecycleError.singleFlightViolation) {
        try await writer.write(
            outputFrame(.restoreTemporaryDiversion, UUID(), fixture)
        )
    }
    #expect(runtime.calls.count == 1)

    gate.release()
    #expect(try await first.value == 0)
    await #expect(throws: PrecisionWriteLifecycleError.duplicateRequest(firstID)) {
        try await writer.write(
            outputFrame(.getReporting, firstID, fixture)
        )
    }
    #expect(runtime.calls.count == 1)
    await writer.shutdownAndDrain()
}

@Test func shutdownIsStickyIdempotentAndRejectsFutureWrites() async throws {
    let fixture = try outputFixture()
    let runtime = RecordingOutputRuntime(descriptor: validDescriptor())
    let writer = try PrecisionIOHIDOutputWriter(
        plan: fixture.plan,
        binding: fixture.binding,
        runtime: runtime
    )

    await writer.shutdownAndDrain()
    await writer.shutdownAndDrain()

    await #expect(throws: PrecisionWriteLifecycleError.shuttingDown) {
        try await writer.write(
            outputFrame(.getReporting, UUID(), fixture)
        )
    }
    #expect(runtime.calls.isEmpty)
}

@Test func droppingFacadeRetainsRuntimeDeviceAnchorAndBytesUntilReturn() async throws {
    let fixture = try outputFixture()
    let gate = BlockingOutputGate()
    let retention = OutputRetentionProbe()
    var runtime: RecordingOutputRuntime?
    var writer: PrecisionIOHIDOutputWriter?
    do {
        let anchor = OutputLifetimeAnchor()
        runtime = RecordingOutputRuntime(
            descriptor: validDescriptor(),
            gate: gate,
            anchor: anchor
        )
        retention.store(runtime: runtime, anchor: anchor)
        writer = try PrecisionIOHIDOutputWriter(
            plan: fixture.plan,
            binding: fixture.binding,
            runtime: runtime!
        )
    }
    let requestID = UUID()
    let frame = outputFrame(
        .applyTemporaryDiversion,
        requestID,
        fixture
    )
    let write = Task { [weak writer] in
        guard let writer else {
            throw PrecisionWriteLifecycleError.shuttingDown
        }
        return try await writer.write(frame)
    }

    try await waitUntil { retention.callCount == 1 }
    writer?.cancelPendingWrite(requestID: requestID, reason: .cancelled)
    await #expect(throws: PrecisionTransportReportIOError.cancelled) {
        try await write.value
    }
    writer = nil
    runtime = nil
    #expect(retention.bothAlive)
    #expect(retention.recordedBytes == fixture.plan.applySetRequest.bytes)

    gate.release()
    try await waitUntil { retention.bothReleased }
}

@Test func outputTargetIsAClosedProductlessSingleCallSourceDoor() throws {
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
    #expect(!products.contains("MXErgoPrecisionIOHIDOutput"))
    #expect(manifest.components(
        separatedBy: "\"MXErgoPrecisionIOHIDOutput\""
    ).count - 1 == 3)

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
    #expect(!projectYAML.contains("MXErgoPrecisionIOHIDOutput"))
    #expect(!projectFile.contains("MXErgoPrecisionIOHIDOutput"))

    let outputSource = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionIOHIDOutput"
        )
    )
    #expect(outputSource.components(
        separatedBy: "IOHIDDeviceSetReport"
    ).count - 1 == 1)
    #expect(outputSource.contains("fileprivate convenience init("))
    #expect(!outputSource.contains("\n    private convenience init("))
    #expect(!outputSource.contains("package init("))
    #expect(!outputSource.contains("public "))
    for forbidden in [
        "IOHIDManager",
        "IOHIDDeviceOpen",
        "IOHIDDeviceClose",
        "IOHIDDeviceActivate",
        "IOHIDDeviceCancel",
        "IOHIDDeviceRegister",
        "IOHIDDeviceSetDispatchQueue",
        "@main",
        "ProcessInfo.processInfo.environment",
    ] {
        #expect(!outputSource.contains(forbidden))
    }

    let lifecycleSource = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionWriteLifecycle"
        )
    )
    let recordDeclaration = try #require(
        lifecycleSource.split(
            separator: "package protocol PrecisionTransportDrainingReportWriter",
            maxSplits: 1
        ).first?.split(
            separator: "package struct PrecisionReviewedOutputRecord",
            maxSplits: 1
        ).last
    )
    #expect(!recordDeclaration.contains("package init"))
    #expect(!lifecycleSource.contains("import IOKit"))
    #expect(!lifecycleSource.contains("IOHIDDevice"))

    let transportSource = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionTransport"
        )
    )
    #expect(!transportSource.contains("import IOKit"))
    #expect(!transportSource.contains("IOHIDDevice"))
    let inputSource = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionIOHIDInput"
        )
    )
    #expect(!inputSource.contains("IOHIDDeviceSetReport"))
    #expect(!inputSource.contains("kIOHIDReportTypeOutput"))

}

private struct OutputFixture: Sendable {
    let journal: DeviceStateJournal
    let plan: PrecisionTemporaryDiversionPlan
    let binding: PrecisionTransportBinding
}

private func outputFixture() throws -> OutputFixture {
    let device = JournalDeviceIdentity(
        deviceID: "1133-45085-42-1-2",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "OUTPUT-LIFECYCLE-TEST",
        locationID: 42,
        firmwareIdentity: "output-lifecycle-firmware"
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
        appBuild: "precision-iohid-output-test",
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
    return OutputFixture(
        journal: journal,
        plan: plan,
        binding: PrecisionTransportBinding(
            session: session,
            rootGeneration: 12
        )
    )
}

private func outputFrame(
    _ kind: PrecisionReviewedOutputKind,
    _ requestID: UUID,
    _ fixture: OutputFixture
) -> PrecisionTransportOutputFrame {
    let bytes: [UInt8]
    switch kind {
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
    fixture: OutputFixture
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

private struct RecordedOutputCall: Sendable, Equatable {
    let reportID: UInt8
    let bytes: [UInt8]
}

private final class RecordingOutputRuntime:
    PrecisionIOHIDOutputRuntime,
    @unchecked Sendable {
    let physicalDescriptor: PrecisionIOHIDOutputPhysicalDescriptor
    let anchor: OutputLifetimeAnchor
    private let lock = NSLock()
    private let gate: BlockingOutputGate?
    private var returnCodes: [Int32]
    private var recordedCalls: [RecordedOutputCall] = []

    init(
        descriptor: PrecisionIOHIDOutputPhysicalDescriptor,
        returnCodes: [Int32] = [0],
        gate: BlockingOutputGate? = nil,
        anchor: OutputLifetimeAnchor = OutputLifetimeAnchor()
    ) {
        physicalDescriptor = descriptor
        self.returnCodes = returnCodes
        self.gate = gate
        self.anchor = anchor
    }

    var calls: [RecordedOutputCall] {
        lock.withLock { recordedCalls }
    }

    func setOutputReport(reportID: UInt8, bytes: [UInt8]) -> Int32 {
        let returnCode = lock.withLock {
            recordedCalls.append(RecordedOutputCall(
                reportID: reportID,
                bytes: bytes
            ))
            return returnCodes.isEmpty ? 0 : returnCodes.removeFirst()
        }
        gate?.wait()
        return returnCode
    }
}

private final class BlockingOutputGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false

    func wait() {
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class OutputLifetimeAnchor: @unchecked Sendable {}

private final class OutputRetentionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var runtime: RecordingOutputRuntime?
    private weak var anchor: OutputLifetimeAnchor?
    private var bytesProvider: (@Sendable () -> [UInt8])?

    var bothAlive: Bool {
        lock.withLock { runtime != nil && anchor != nil }
    }

    var bothReleased: Bool {
        lock.withLock { runtime == nil && anchor == nil }
    }

    var recordedBytes: [UInt8] {
        let provider = lock.withLock { bytesProvider }
        return provider?() ?? []
    }

    var callCount: Int {
        let provider = lock.withLock { bytesProvider }
        return provider?().isEmpty == false ? 1 : 0
    }

    func store(
        runtime: RecordingOutputRuntime?,
        anchor: OutputLifetimeAnchor
    ) {
        lock.withLock {
            self.runtime = runtime
            self.anchor = anchor
            bytesProvider = { [weak runtime] in
                runtime?.calls.last?.bytes ?? []
            }
        }
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

private enum DescriptorMutation: CaseIterable {
    case vendor
    case product
    case transport
    case serial
    case location
    case usagePage
    case usage
    case missingReportID
    case wrongReportID
    case multipleReportIDs
    case missingMaximum
    case shortMaximum
    case longMaximum

    var expectedError: PrecisionIOHIDOutputError {
        switch self {
        case .vendor, .product, .transport, .serial, .location,
             .usagePage, .usage:
            return .invalidPhysicalIdentity
        case .missingReportID, .wrongReportID, .multipleReportIDs,
             .missingMaximum, .shortMaximum, .longMaximum:
            return .invalidOutputReportCapability
        }
    }
}

private func validDescriptor() -> PrecisionIOHIDOutputPhysicalDescriptor {
    descriptor(mutation: nil)
}

private func descriptor(
    mutation: DescriptorMutation?
) -> PrecisionIOHIDOutputPhysicalDescriptor {
    PrecisionIOHIDOutputPhysicalDescriptor(
        vendorID: mutation == .vendor ? 0x046E : 0x046D,
        productID: mutation == .product ? 0xB01E : 0xB01D,
        transport: mutation == .transport ? "USB" : "Bluetooth Low Energy",
        serialNumber: mutation == .serial
            ? "OTHER-SERIAL" : "OUTPUT-LIFECYCLE-TEST",
        locationID: mutation == .location ? 43 : 42,
        primaryUsagePage: mutation == .usagePage ? 2 : 1,
        primaryUsage: mutation == .usage ? 3 : 2,
        outputReportIDs: {
            switch mutation {
            case .missingReportID: return []
            case .wrongReportID: return [0x10]
            case .multipleReportIDs: return [0x10, 0x11]
            default: return [0x11]
            }
        }(),
        maximumOutputReportByteCount: {
            switch mutation {
            case .missingMaximum: return nil
            case .shortMaximum: return 19
            case .longMaximum: return 21
            default: return HIDPP20LongMessage.byteCount
            }
        }()
    )
}

private enum OutputWriterTestError: Error {
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
            throw OutputWriterTestError.timedOut
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
