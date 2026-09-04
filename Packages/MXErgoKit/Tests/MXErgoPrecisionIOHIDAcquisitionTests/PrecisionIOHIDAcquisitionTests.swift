import Foundation
import MXErgoHIDPP
import Testing
@testable import MXErgoPrecisionIOHIDAcquisition
@testable import MXErgoPrecisionIOHIDOwnership
@testable import MXErgoPrecisionTransport
@testable import MXErgoPrecisionWriteLifecycle

@Test func acquisitionClosesManagerBeforeAssemblyAndDeviceAfterShutdown() async throws {
    let fixture = try acquisitionFixture()
    let events = AcquisitionEventRecorder()
    let target = FakeAcquisitionDevice(name: "target")
    let other = FakeAcquisitionDevice(name: "other")
    let session = try PrecisionIOHIDAcquiredSession(
        plan: fixture.plan,
        binding: fixture.binding,
        calls: acquisitionCalls(
            events: events,
            devices: [other, target],
            matchingNames: ["target"]
        )
    )

    #expect(events.values == [
        "manager-create",
        "manager-configure",
        "manager-open",
        "devices-copy",
        "device-match-other",
        "device-match-target",
        "device-open-target",
        "manager-close",
        "assembly-make-target",
    ])
    #expect(session.deviceCloseReturn == nil)

    try await session.start()
    await session.shutdownAndDrain()
    await session.shutdownAndDrain()

    #expect(session.deviceCloseReturn == 0)
    #expect(events.count("device-close-target") == 1)
    #expect(events.values.suffix(4) == [
        "endpoint-start",
        "endpoint-shutdown",
        "device-close-target",
        "endpoint-shutdown",
    ])
}

@Test func quarantinedCloseAnchorRetainsCanonicalLeaseUntilDeviceClose()
    async throws {
    let fixture = try acquisitionFixture()
    let events = AcquisitionEventRecorder()
    let target = FakeAcquisitionDevice(name: "target")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "acquisition-retained-lease-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let journalURL = directory.appendingPathComponent("runtime.json")
    let session: PrecisionIOHIDAcquiredSession
    do {
        let operationLease = try MXErgoDeviceOperationLease.acquire(
            beside: journalURL
        )
        session = try PrecisionIOHIDAcquiredSession(
            plan: fixture.plan,
            binding: fixture.binding,
            calls: acquisitionCalls(
                events: events,
                devices: [target],
                matchingNames: ["target"]
            ),
            retainedOperationLease: operationLease
        )
    }

    #expect(throws: MXErgoDeviceOperationLeaseError.unavailable) {
        _ = try MXErgoDeviceOperationLease.acquire(beside: journalURL)
    }
    await session.shutdownAndDrain()
    #expect(events.values.suffix(2) == [
        "endpoint-shutdown",
        "device-close-target",
    ])
    let reacquired = try MXErgoDeviceOperationLease.acquire(
        beside: journalURL
    )
    #expect(reacquired.protects(journalURL: journalURL))
}

@Test func invalidBindingFailsBeforeManagerCreation() throws {
    let fixture = try acquisitionFixture()
    let events = AcquisitionEventRecorder()
    let invalidSession = DeviceTransactionSession(
        device: fixture.binding.session.device,
        featureID: ReprogControlsV4.featureID,
        featureVersion: 3,
        featureIndex: fixture.binding.session.featureIndex &+ 1,
        connectionEpoch: fixture.binding.session.connectionEpoch
    )
    let invalidBinding = PrecisionTransportBinding(
        session: invalidSession,
        rootGeneration: fixture.binding.rootGeneration
    )

    #expect(throws: PrecisionIOHIDAcquisitionError.invalidBinding) {
        try PrecisionIOHIDAcquiredSession(
            plan: fixture.plan,
            binding: invalidBinding,
            calls: acquisitionCalls(events: events)
        )
    }
    #expect(events.values.isEmpty)
}

@Test func managerOpenFailureClosesManagerAndPerformsNoLaterWork() throws {
    let fixture = try acquisitionFixture()
    let events = AcquisitionEventRecorder()
    #expect(throws: PrecisionIOHIDAcquisitionError.managerOpenFailed(
        71,
        managerCloseReturn: 0
    )) {
        try PrecisionIOHIDAcquiredSession(
            plan: fixture.plan,
            binding: fixture.binding,
            calls: acquisitionCalls(events: events, managerOpenReturn: 71)
        )
    }
    #expect(events.values == [
        "manager-create",
        "manager-configure",
        "manager-open",
        "manager-close",
    ])
}

@Test func unavailableAndNonUniqueEnumerationCloseTheManager() throws {
    let fixture = try acquisitionFixture()

    do {
        let events = AcquisitionEventRecorder()
        #expect(throws: PrecisionIOHIDAcquisitionError
            .deviceEnumerationUnavailable(managerCloseReturn: 0)) {
            try PrecisionIOHIDAcquiredSession(
                plan: fixture.plan,
                binding: fixture.binding,
                calls: acquisitionCalls(
                    events: events,
                    enumerationAvailable: false
                )
            )
        }
        #expect(events.values.suffix(2) == ["devices-copy", "manager-close"])
        #expect(events.values.allSatisfy { !$0.hasPrefix("device-open") })
    }

    do {
        let events = AcquisitionEventRecorder()
        let device = FakeAcquisitionDevice(name: "other")
        #expect(throws: PrecisionIOHIDAcquisitionError
            .noMatchingDevice(managerCloseReturn: 0)) {
            try PrecisionIOHIDAcquiredSession(
                plan: fixture.plan,
                binding: fixture.binding,
                calls: acquisitionCalls(
                    events: events,
                    devices: [device],
                    matchingNames: []
                )
            )
        }
        #expect(events.values.suffix(2) == [
            "device-match-other",
            "manager-close",
        ])
    }

    do {
        let events = AcquisitionEventRecorder()
        let first = FakeAcquisitionDevice(name: "first")
        let second = FakeAcquisitionDevice(name: "second")
        #expect(throws: PrecisionIOHIDAcquisitionError
            .multipleMatchingDevices(count: 2, managerCloseReturn: 0)) {
            try PrecisionIOHIDAcquiredSession(
                plan: fixture.plan,
                binding: fixture.binding,
                calls: acquisitionCalls(
                    events: events,
                    devices: [first, second],
                    matchingNames: ["first", "second"]
                )
            )
        }
        #expect(events.values.last == "manager-close")
        #expect(events.values.allSatisfy { !$0.hasPrefix("device-open") })
    }
}

@Test func deviceOpenFailureClosesManagerWithoutClosingUnopenedDevice() throws {
    let fixture = try acquisitionFixture()
    let events = AcquisitionEventRecorder()
    let target = FakeAcquisitionDevice(name: "target")

    #expect(throws: PrecisionIOHIDAcquisitionError.deviceOpenFailed(
        72,
        managerCloseReturn: 0
    )) {
        try PrecisionIOHIDAcquiredSession(
            plan: fixture.plan,
            binding: fixture.binding,
            calls: acquisitionCalls(
                events: events,
                devices: [target],
                matchingNames: ["target"],
                deviceOpenReturn: 72
            )
        )
    }
    #expect(events.values.suffix(2) == ["device-open-target", "manager-close"])
    #expect(events.count("device-close-target") == 0)
}

@Test func managerCloseFailureClosesDirectlyOpenedDeviceAndBuildsNoAssembly() throws {
    let fixture = try acquisitionFixture()
    let events = AcquisitionEventRecorder()
    let target = FakeAcquisitionDevice(name: "target")

    #expect(throws: PrecisionIOHIDAcquisitionError.managerCloseFailed(
        73,
        deviceCloseReturn: 74
    )) {
        try PrecisionIOHIDAcquiredSession(
            plan: fixture.plan,
            binding: fixture.binding,
            calls: acquisitionCalls(
                events: events,
                devices: [target],
                matchingNames: ["target"],
                managerCloseReturn: 73,
                deviceCloseReturn: 74
            )
        )
    }
    #expect(events.values.suffix(3) == [
        "device-open-target",
        "manager-close",
        "device-close-target",
    ])
    #expect(!events.contains("assembly-make-target"))
}

@Test func managerCloseRollbackRetainsCanonicalLeaseThroughDeviceClose() throws {
    let fixture = try acquisitionFixture()
    let events = AcquisitionEventRecorder()
    let target = FakeAcquisitionDevice(name: "target")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "acquisition-rollback-lease-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let journalURL = directory.appendingPathComponent("runtime.json")
    let leaseWasHeldDuringClose = AcquisitionFlag()

    #expect(throws: PrecisionIOHIDAcquisitionError.managerCloseFailed(
        73,
        deviceCloseReturn: 74
    )) {
        try PrecisionIOHIDAcquiredSession(
            plan: fixture.plan,
            binding: fixture.binding,
            calls: acquisitionCalls(
                events: events,
                devices: [target],
                matchingNames: ["target"],
                managerCloseReturn: 73,
                deviceCloseReturn: 74,
                beforeDeviceClose: {
                    do {
                        _ = try MXErgoDeviceOperationLease.acquire(
                            beside: journalURL
                        )
                    } catch MXErgoDeviceOperationLeaseError.unavailable {
                        leaseWasHeldDuringClose.set()
                    } catch {
                        // The postcondition below distinguishes the expected
                        // contention result from every other outcome.
                    }
                }
            ),
            retainedOperationLease: try MXErgoDeviceOperationLease.acquire(
                beside: journalURL
            )
        )
    }

    #expect(leaseWasHeldDuringClose.value)
    let reacquired = try MXErgoDeviceOperationLease.acquire(
        beside: journalURL
    )
    #expect(reacquired.protects(journalURL: journalURL))
}

@Test func assemblyFailureReportsDirectCloseRollback() throws {
    let fixture = try acquisitionFixture()
    let events = AcquisitionEventRecorder()
    let target = FakeAcquisitionDevice(name: "target")

    do {
        _ = try PrecisionIOHIDAcquiredSession(
            plan: fixture.plan,
            binding: fixture.binding,
            calls: acquisitionCalls(
                events: events,
                devices: [target],
                matchingNames: ["target"],
                deviceCloseReturn: 75,
                assemblyError: AcquisitionTestError.assembly
            )
        )
        Issue.record("Expected assembly construction to fail")
    } catch let error as PrecisionIOHIDAssemblyRollbackError {
        #expect(error.underlying as? AcquisitionTestError == .assembly)
        #expect(error.deviceCloseReturn == 75)
    }

    #expect(events.values.suffix(3) == [
        "manager-close",
        "assembly-make-target",
        "device-close-target",
    ])
    #expect(events.count("device-close-target") == 1)
}

@Test func acquisitionTargetIsProductlessUnwiredAndCapabilityMinimal() throws {
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
    #expect(!products.contains("MXErgoPrecisionIOHIDAcquisition"))
    #expect(manifest.components(
        separatedBy: "\"MXErgoPrecisionIOHIDAcquisition\""
    ).count - 1 == 4)
    #expect(manifest.components(
        separatedBy: "\"MXErgoPrecisionIOHIDAcquisitionTests\""
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
    #expect(!projectYAML.contains("MXErgoPrecisionIOHIDAcquisition"))
    #expect(!projectFile.contains("MXErgoPrecisionIOHIDAcquisition"))

    let source = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionIOHIDAcquisition"
        )
    )
    for required in [
        "IOHIDManagerCreate(",
        "IOHIDManagerOptions.independentDevices.rawValue",
        "IOHIDManagerSetDeviceMatching(",
        "IOHIDManagerOpen(",
        "IOHIDManagerCopyDevices(",
        "IOHIDDeviceOpen(",
        "IOHIDManagerClose(",
        "IOHIDDeviceClose(",
    ] {
        #expect(source.components(separatedBy: required).count - 1 == 1)
    }
    for forbidden in [
        "kIOHIDOptionsTypeSeizeDevice",
        "IOHIDDeviceSetReport",
        "RegisterInputReportCallback",
        "RegisterRemovalCallback",
        "SetDispatchQueue",
        "IOHIDDeviceActivate",
        "IOHIDDeviceCancel",
        "@main",
        "ProcessInfo.processInfo.environment",
        "public ",
        "@_spi",
    ] {
        #expect(!source.contains(forbidden))
    }

    let assemblySource = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionIOHIDAssembly"
        )
    )
    #expect(packageDeclarationLines(in: assemblySource) == [
        "package enum PrecisionIOHIDAssemblyFactory {",
        "package static func make(",
    ])
    #expect(packageDeclarationLines(in: source) == [
        "package protocol PrecisionIOHIDAcquiredEndpoint:",
        "package enum PrecisionIOHIDAcquisitionFactory {",
        "package static func validate(",
        "package static func make(",
    ])
}

private enum AcquisitionTestError: Error, Sendable, Equatable {
    case assembly
}

private final class FakeAcquisitionManager: @unchecked Sendable {}

private final class FakeAcquisitionDevice: @unchecked Sendable {
    let name: String

    init(name: String) {
        self.name = name
    }
}

private final class FakeAcquisitionEndpoint:
    PrecisionIOHIDAssembledEndpoint,
    @unchecked Sendable {
    private let anchor: any PrecisionIOHIDQuiescentReleaseAnchor
    private let events: AcquisitionEventRecorder

    init(
        anchor: any PrecisionIOHIDQuiescentReleaseAnchor,
        events: AcquisitionEventRecorder
    ) {
        self.anchor = anchor
        self.events = events
    }

    func start() async throws {
        events.record("endpoint-start")
    }

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
        events.record("endpoint-shutdown")
        anchor.releaseAfterEndpointQuiescence()
    }

    func beginRequest(_ frame: PrecisionTransportOutputFrame) throws {
        _ = frame
    }

    func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame {
        _ = requestID
        throw PrecisionTransportReportIOError.cancelled
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

private final class AcquisitionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func record(_ value: String) {
        lock.withLock { storage.append(value) }
    }

    func contains(_ value: String) -> Bool {
        lock.withLock { storage.contains(value) }
    }

    func count(_ value: String) -> Int {
        lock.withLock { storage.filter { $0 == value }.count }
    }
}

private final class AcquisitionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }

    func set() { lock.withLock { storage = true } }
}

private func acquisitionCalls(
    events: AcquisitionEventRecorder,
    devices: [FakeAcquisitionDevice] = [],
    matchingNames: Set<String> = [],
    managerOpenReturn: Int32 = 0,
    enumerationAvailable: Bool = true,
    deviceOpenReturn: Int32 = 0,
    managerCloseReturn: Int32 = 0,
    deviceCloseReturn: Int32 = 0,
    assemblyError: AcquisitionTestError? = nil,
    beforeDeviceClose: (() -> Void)? = nil
) -> PrecisionIOHIDAcquisitionCalls<
    FakeAcquisitionManager,
    FakeAcquisitionDevice
> {
    PrecisionIOHIDAcquisitionCalls(
        createManager: {
            events.record("manager-create")
            return FakeAcquisitionManager()
        },
        configureMatching: { _ in
            events.record("manager-configure")
        },
        openManager: { _ in
            events.record("manager-open")
            return managerOpenReturn
        },
        copyDevices: { _ in
            events.record("devices-copy")
            return enumerationAvailable ? devices : nil
        },
        matchesExpectedDevice: { device in
            events.record("device-match-\(device.name)")
            return matchingNames.contains(device.name)
        },
        openDevice: { device in
            events.record("device-open-\(device.name)")
            return deviceOpenReturn
        },
        closeManager: { _ in
            events.record("manager-close")
            return managerCloseReturn
        },
        closeDevice: { device in
            beforeDeviceClose?()
            events.record("device-close-\(device.name)")
            return deviceCloseReturn
        },
        makeAssembly: { device, anchor in
            events.record("assembly-make-\(device.name)")
            if let assemblyError { throw assemblyError }
            return FakeAcquisitionEndpoint(anchor: anchor, events: events)
        }
    )
}

private struct AcquisitionFixture {
    let plan: PrecisionTemporaryDiversionPlan
    let binding: PrecisionTransportBinding
}

private func acquisitionFixture() throws -> AcquisitionFixture {
    let device = JournalDeviceIdentity(
        deviceID: "1133-45085-9-1-2",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "ACQUISITION-TEST",
        locationID: 9,
        firmwareIdentity: "acquisition-test-firmware"
    )
    let baselineParameters = padded([0x00, 0xED, 0x00, 0x00, 0x00])
    let control = try DeviceControlJournalEntry(
        controlInfo: ReprogControlInfo(
            index: 5,
            controlID: 0x00ED,
            taskID: 0x00C4,
            capabilityFlags: 0x71,
            position: 0,
            group: 1,
            groupMask: 1,
            rawXYCapability: false,
            rawParameters: padded([0x00, 0xED])
        ),
        baselineReporting: ReprogControlReportingState(
            controlID: 0x00ED,
            rawFlags: 0,
            rawMappedControlID: 0,
            rawParameters: baselineParameters
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
        appBuild: "acquisition-test",
        device: device,
        feature: feature,
        expectedControlCount: 1,
        controls: [control]
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
        featureIndex: feature.index,
        connectionEpoch: 42
    )
    return AcquisitionFixture(
        plan: plan,
        binding: PrecisionTransportBinding(
            session: session,
            rootGeneration: 700
        )
    )
}

private func padded(_ bytes: [UInt8]) -> [UInt8] {
    bytes + Array(
        repeating: 0,
        count: HIDPP20LongMessage.parameterCount - bytes.count
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
