import CryptoKit
import Darwin
import Foundation
@preconcurrency import IOKit.hid

enum ProbeError: Error, LocalizedError, Sendable {
    case explicitConfirmationMissing
    case missingJournal
    case missingBackup
    case nonRegularFile(String)
    case invalidBaseline(String)
    case observerFailed(Int32)
    case deviceReadinessTimedOut
    case physicalIdentityMismatch
    case requestAlreadyAttempted
    case connectionPoisoned
    case requestRegistrationFailed
    case outputFailed(Int32)
    case requestTimedOut
    case deviceDisconnected
    case protocolError(UInt8)
    case malformedResponse
    case featureMismatch
    case firmwareMismatch
    case precisionMismatch
    case synchronousShutdownTimedOut
    case journalChanged
    case backupChanged
    case leaseUnavailable
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .explicitConfirmationMissing:
            "The fixed read-only probe argument was not supplied"
        case .missingJournal:
            "The firmware-bound device-state journal is missing"
        case .missingBackup:
            "The original-byte firmware migration backup is missing"
        case let .nonRegularFile(path):
            "A required path is not a regular file: \(path)"
        case let .invalidBaseline(detail):
            "The live recovery baseline is not eligible: \(detail)"
        case let .observerFailed(code):
            "The isolated IOHID observer failed with code \(code)"
        case .deviceReadinessTimedOut:
            "Exactly one matching MX Ergo with a 0x11/20-byte output report was not ready"
        case .physicalIdentityMismatch:
            "The connected physical MX Ergo did not match the recovery identity"
        case .requestAlreadyAttempted:
            "A fixed read-only operation was requested more than once"
        case .connectionPoisoned:
            "A prior sent request timed out; this connection is no longer eligible"
        case .requestRegistrationFailed:
            "The fixed read-only request could not be registered"
        case let .outputFailed(code):
            "IOHID rejected the fixed read-only request with code \(code)"
        case .requestTimedOut:
            "The fixed read-only request timed out"
        case .deviceDisconnected:
            "The MX Ergo disconnected during the read-only probe"
        case let .protocolError(code):
            String(format: "The device returned HID++ protocol error 0x%02X", code)
        case .malformedResponse:
            "A read-only response did not match its exact request"
        case .featureMismatch:
            "The live REPROG_CONTROLS_V4 descriptor did not match the journal"
        case .firmwareMismatch:
            "The live firmware fingerprint did not match the journal"
        case .precisionMismatch:
            "The one Precision GET did not match the exact saved baseline"
        case .synchronousShutdownTimedOut:
            "The isolated IOHID observer did not close synchronously"
        case .journalChanged:
            "The live device-state journal changed during the probe"
        case .backupChanged:
            "The original-byte backup changed during the probe"
        case .leaseUnavailable:
            "Another process holds the live device-operation lease"
        case let .posix(operation, code):
            "\(operation) failed with POSIX code \(code)"
        }
    }
}

private struct ProbeResult: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let succeeded: Bool
    let completedAt: Date
    let detail: String
    let journalSHA256Before: String?
    let journalSHA256After: String?
    let backupSHA256Before: String?
    let backupSHA256After: String?
    let precisionRequest: [UInt8]?
    let precisionResponse: [UInt8]?
    let connectionEpoch: UInt64?

    static func failure(_ error: Error) -> ProbeResult {
        ProbeResult(
            schemaVersion: currentSchemaVersion,
            succeeded: false,
            completedAt: Date(),
            detail: error.localizedDescription,
            journalSHA256Before: nil,
            journalSHA256After: nil,
            backupSHA256Before: nil,
            backupSHA256After: nil,
            precisionRequest: nil,
            precisionResponse: nil,
            connectionEpoch: nil
        )
    }
}

private struct ProbeEvidence {
    let journalBefore: String
    let journalAfter: String
    let backupBefore: String
    let backupAfter: String
    let request: [UInt8]
    let response: [UInt8]
    let connectionEpoch: UInt64
    let matchesBaseline: Bool
}

private struct ProbeJournal: Decodable {
    let schemaVersion: Int
    let featureID: UInt16
    let device: ProbeJournalDevice
    let feature: ProbeFeature
    let expectedControlCount: Int
    let controls: [ProbeJournalControl]

    func validatedPrecisionBaseline() throws -> [UInt8] {
        guard schemaVersion == 2,
              featureID == 0x1B04,
              feature.index != 0,
              feature.index != 0xFF,
              feature.version == 3,
              expectedControlCount == 9,
              controls.count == expectedControlCount,
              Set(controls.map(\.controlInfo.index)).count == expectedControlCount,
              Set(controls.map(\.controlInfo.controlID)).count == expectedControlCount,
              controls.allSatisfy({
                  $0.phase == "baselineVerified"
                      && $0.intendedReporting == nil
                      && $0.readBackReporting == nil
                      && $0.baselineReporting.controlID == $0.controlInfo.controlID
              }),
              let precision = controls.first(where: { $0.controlInfo.controlID == 0x00ED }),
              precision.baselineReporting.rawFlags == 0,
              precision.baselineReporting.rawMappedControlID == 0,
              precision.baselineReporting.rawParameters.count == 16,
              Array(precision.baselineReporting.rawParameters.prefix(5))
                == [0x00, 0xED, 0x00, 0x00, 0x00],
              precision.baselineReporting.rawParameters.dropFirst(5).allSatisfy({ $0 == 0 }),
              device.isEligible else {
            throw ProbeError.invalidBaseline("journal invariants did not match the fixed probe allowlist")
        }
        return precision.baselineReporting.rawParameters
    }
}

private struct ProbeJournalDevice: Decodable, Equatable {
    let deviceID: String
    let vendorID: Int
    let productID: Int
    let transport: String
    let serialNumber: String?
    let locationID: Int?
    let firmwareIdentity: String?

    var isEligible: Bool {
        vendorID == 0x046D
            && productID == 0xB01D
            && transport == "Bluetooth Low Energy"
            && serialNumber?.isEmpty == false
            && locationID != nil
            && firmwareIdentity?.isEmpty == false
    }

    func matches(_ device: ProbeHIDDevice) -> Bool {
        deviceID == device.deviceID
            && vendorID == device.vendorID
            && productID == device.productID
            && transport == device.transport
            && serialNumber == device.serialNumber
            && locationID == device.locationID
    }
}

private struct ProbeFeature: Decodable, Equatable {
    let index: UInt8
    let type: UInt8
    let version: UInt8
    let rawParameters: [UInt8]
}

private struct ProbeJournalControl: Decodable {
    let controlInfo: ProbeControlInfo
    let baselineReporting: ProbeReporting
    let intendedReporting: ProbeReporting?
    let readBackReporting: ProbeReporting?
    let phase: String
}

private struct ProbeControlInfo: Decodable {
    let index: UInt8
    let controlID: UInt16
}

private struct ProbeReporting: Decodable {
    let controlID: UInt16
    let rawFlags: UInt8
    let rawMappedControlID: UInt16
    let rawParameters: [UInt8]
}

struct ProbeHIDDevice: Sendable, Equatable {
    let deviceID: String
    let vendorID: Int?
    let productID: Int?
    let transport: String?
    let serialNumber: String?
    let locationID: Int?
    let hasExpectedOutputReport: Bool
}

enum ProbeObserverStatus: Sendable, Equatable {
    case starting
    case observing
    case stopped
    case failed(Int32)
}

enum ProbeHIDEvent: Sendable, Equatable {
    case status(ProbeObserverStatus)
    case connected(ProbeHIDDevice)
    case disconnected(String)
}

actor ProbeObservationState {
    private var status: ProbeObserverStatus = .stopped
    private var devices: [String: ProbeHIDDevice] = [:]

    func receive(_ event: ProbeHIDEvent) {
        switch event {
        case let .status(next):
            status = next
        case let .connected(device):
            devices[device.deviceID] = device
        case let .disconnected(deviceID):
            devices.removeValue(forKey: deviceID)
        }
    }

    func waitForSingleReadyDevice() async throws -> ProbeHIDDevice {
        for _ in 0..<160 {
            if case let .failed(code) = status {
                throw ProbeError.observerFailed(code)
            }
            if devices.count == 1,
               let device = devices.values.first,
               device.hasExpectedOutputReport {
                return device
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ProbeError.deviceReadinessTimedOut
    }
}

/// Every possible output packet is generated by this closed enum. There is no
/// raw-byte send API and no HID++ function-3 (SET) case.
enum FixedReadOnlyOperation: Hashable, Sendable {
    case resolveReprog
    case resolveDeviceInformation
    case readDeviceInformation(featureIndex: UInt8)
    case readFirmwareEntity(featureIndex: UInt8, entityIndex: UInt8)
    case readPrecision(featureIndex: UInt8)
    case trialPreflight(featureIndex: UInt8)

    var request: [UInt8] {
        switch self {
        case .resolveReprog:
            makeMessage(featureIndex: 0, address: 0x0E, parameters: [0x1B, 0x04])
        case .resolveDeviceInformation:
            makeMessage(featureIndex: 0, address: 0x0E, parameters: [0x00, 0x03])
        case let .readDeviceInformation(featureIndex):
            makeMessage(featureIndex: featureIndex, address: 0x0E, parameters: [])
        case let .readFirmwareEntity(featureIndex, entityIndex):
            makeMessage(featureIndex: featureIndex, address: 0x1E, parameters: [entityIndex])
        case let .readPrecision(featureIndex):
            makeMessage(featureIndex: featureIndex, address: 0x2D, parameters: [0x00, 0xED])
        case let .trialPreflight(featureIndex):
            makeMessage(featureIndex: featureIndex, address: 0x2E, parameters: [0x00, 0xED])
        }
    }

    private func makeMessage(
        featureIndex: UInt8,
        address: UInt8,
        parameters: [UInt8]
    ) -> [UInt8] {
        [0x11, 0x00, featureIndex, address]
            + parameters
            + Array(repeating: 0, count: 16 - parameters.count)
    }
}

final class StandaloneReadOnlyHIDSession: @unchecked Sendable {
    typealias Handler = @Sendable (ProbeHIDEvent) -> Void
    typealias Completion = @Sendable (Result<[UInt8], ProbeError>) -> Void
    typealias TrialReportHandler = @Sendable ([UInt8], ProbeHIDDevice, UInt64) -> Void
    typealias TrialDisconnectHandler = @Sendable (UInt64) -> Void

    private struct Pending {
        let id: UUID
        let deviceID: String
        let request: [UInt8]
        let completion: Completion
    }

    private let handler: Handler
    private let stateLock = NSLock()
    private let lifecycleCondition = NSCondition()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var manager: IOHIDManager?
    private var stopRequested = false
    private var finished = false
    private var devices: [String: IOHIDDevice] = [:]
    private var deviceSnapshots: [String: ProbeHIDDevice] = [:]
    private var pending: Pending?
    private var attempted: Set<FixedReadOnlyOperation> = []
    private var connectionPoisoned = false
    private var trialReportHandler: TrialReportHandler?
    private var trialDisconnectHandler: TrialDisconnectHandler?
    private(set) var connectionEpoch: UInt64 = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() {
        stateLock.lock()
        guard thread == nil else {
            stateLock.unlock()
            return
        }
        let next = Thread { [weak self] in self?.run() }
        next.name = "MX Ergo isolated read-only probe"
        thread = next
        stateLock.unlock()
        handler(.status(.starting))
        next.start()
    }

    func perform(_ operation: FixedReadOnlyOperation, completion: @escaping Completion) {
        stateLock.lock()
        let loop = runLoop
        stateLock.unlock()
        guard let loop else {
            completion(.failure(.requestRegistrationFailed))
            return
        }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.send(operation, completion: completion)
        }
        CFRunLoopWakeUp(loop)
    }

    func installTrialHandlers(
        report: @escaping TrialReportHandler,
        disconnected: @escaping TrialDisconnectHandler
    ) {
        stateLock.lock()
        trialReportHandler = report
        trialDisconnectHandler = disconnected
        stateLock.unlock()
    }

    func singleReadyDevice() -> (IOHIDDevice, ProbeHIDDevice, UInt64)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard devices.count == 1,
              let entry = devices.first,
              let snapshot = deviceSnapshots[entry.key],
              snapshot.hasExpectedOutputReport else {
            return nil
        }
        return (entry.value, snapshot, connectionEpoch)
    }

    @discardableResult
    func stopAndWait(timeout: TimeInterval) -> Bool {
        stateLock.lock()
        stopRequested = true
        let loop = runLoop
        stateLock.unlock()
        if let loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
                CFRunLoopStop(loop)
            }
            CFRunLoopWakeUp(loop)
        }

        lifecycleCondition.lock()
        defer { lifecycleCondition.unlock() }
        let deadline = Date(timeIntervalSinceNow: max(0, timeout))
        while !finished {
            guard lifecycleCondition.wait(until: deadline) else { return false }
        }
        return true
    }

    private func run() {
        defer {
            lifecycleCondition.lock()
            finished = true
            lifecycleCondition.broadcast()
            lifecycleCondition.unlock()
        }
        autoreleasepool {
            guard let currentRunLoop = CFRunLoopGetCurrent() else {
                handler(.status(.failed(kIOReturnError)))
                return
            }
            stateLock.lock()
            runLoop = currentRunLoop
            let shouldStop = stopRequested
            stateLock.unlock()
            guard !shouldStop else {
                handler(.status(.stopped))
                return
            }

            let nextManager = IOHIDManagerCreate(
                kCFAllocatorDefault,
                IOOptionBits(kIOHIDOptionsTypeNone)
            )
            manager = nextManager
            IOHIDManagerSetDeviceMatching(nextManager, [
                kIOHIDVendorIDKey: 0x046D,
                kIOHIDProductIDKey: 0xB01D,
            ] as CFDictionary)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(
                nextManager,
                standaloneProbeDeviceMatched,
                context
            )
            IOHIDManagerRegisterDeviceRemovalCallback(
                nextManager,
                standaloneProbeDeviceRemoved,
                context
            )
            IOHIDManagerRegisterInputReportCallback(
                nextManager,
                standaloneProbeInputReport,
                context
            )
            IOHIDManagerScheduleWithRunLoop(
                nextManager,
                currentRunLoop,
                CFRunLoopMode.defaultMode.rawValue
            )
            let result = IOHIDManagerOpen(
                nextManager,
                IOOptionBits(kIOHIDOptionsTypeNone)
            )
            guard result == kIOReturnSuccess else {
                handler(.status(.failed(result)))
                cleanup(manager: nextManager, runLoop: currentRunLoop)
                return
            }
            handler(.status(.observing))
            CFRunLoopRun()
            if let pending {
                self.pending = nil
                pending.completion(.failure(.deviceDisconnected))
            }
            cleanup(manager: nextManager, runLoop: currentRunLoop)
            handler(.status(.stopped))
        }
    }

    private func cleanup(manager: IOHIDManager, runLoop: CFRunLoop) {
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            runLoop,
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        stateLock.lock()
        self.manager = nil
        self.runLoop = nil
        stateLock.unlock()
    }

    fileprivate func deviceMatched(_ device: IOHIDDevice, result: IOReturn) {
        guard result == kIOReturnSuccess else { return }
        let snapshot = Self.decode(device)
        stateLock.lock()
        devices[snapshot.deviceID] = device
        deviceSnapshots[snapshot.deviceID] = snapshot
        stateLock.unlock()
        handler(.connected(snapshot))
    }

    fileprivate func deviceRemoved(_ device: IOHIDDevice) {
        let snapshot = Self.decode(device)
        stateLock.lock()
        devices.removeValue(forKey: snapshot.deviceID)
        deviceSnapshots.removeValue(forKey: snapshot.deviceID)
        connectionEpoch &+= 1
        connectionPoisoned = false
        let nextEpoch = connectionEpoch
        let disconnectHandler = trialDisconnectHandler
        stateLock.unlock()
        if let pending, pending.deviceID == snapshot.deviceID {
            self.pending = nil
            pending.completion(.failure(.deviceDisconnected))
        }
        disconnectHandler?(nextEpoch)
        handler(.disconnected(snapshot.deviceID))
    }

    fileprivate func receivedReport(
        result: IOReturn,
        sourceDevice: IOHIDDevice?,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>,
        length: CFIndex
    ) {
        guard result == kIOReturnSuccess,
              reportID == 0x11,
              length == 20 else { return }
        let response = Array(UnsafeBufferPointer(start: report, count: length))
        guard response.count == 20, response[0] == 0x11 else { return }
        let sourceSnapshot = sourceDevice.map(Self.decode)
        if let pending {
            if let sourceSnapshot, sourceSnapshot.deviceID != pending.deviceID { return }
            if response[1] == pending.request[1],
               response[2] == 0xFF,
               response[3] == pending.request[2],
               response[4] == pending.request[3] {
                self.pending = nil
                pending.completion(.failure(.protocolError(response[5])))
                return
            }
            if Array(response[1...3]) == Array(pending.request[1...3]) {
                self.pending = nil
                pending.completion(.success(response))
                return
            }
        }

        stateLock.lock()
        let reportHandler = trialReportHandler
        let epoch = connectionEpoch
        let fallbackSnapshot = deviceSnapshots.values.first
        stateLock.unlock()
        if let reportHandler, let snapshot = sourceSnapshot ?? fallbackSnapshot {
            reportHandler(response, snapshot, epoch)
        }
    }

    private func send(_ operation: FixedReadOnlyOperation, completion: @escaping Completion) {
        guard !attempted.contains(operation) else {
            completion(.failure(.requestAlreadyAttempted))
            return
        }
        attempted.insert(operation)
        guard !connectionPoisoned else {
            completion(.failure(.connectionPoisoned))
            return
        }
        stateLock.lock()
        let entry = devices.count == 1 ? devices.first : nil
        let hasExpectedReport = entry.flatMap { deviceSnapshots[$0.key] }?
            .hasExpectedOutputReport == true
        stateLock.unlock()
        guard pending == nil,
              let entry,
              hasExpectedReport else {
            completion(.failure(.requestRegistrationFailed))
            return
        }
        let request = operation.request
        guard request.count == 20,
              request[0] == 0x11,
              request[1] == 0,
              request[3] >> 4 != 3 else {
            completion(.failure(.requestRegistrationFailed))
            return
        }
        let requestID = UUID()
        pending = Pending(
            id: requestID,
            deviceID: entry.key,
            request: request,
            completion: completion
        )

        var bytes = request
        let byteCount = bytes.count
        let outputResult = bytes.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceSetReport(
                entry.value,
                kIOHIDReportTypeOutput,
                CFIndex(0x11),
                base,
                byteCount
            )
        }
        guard outputResult == kIOReturnSuccess else {
            pending = nil
            completion(.failure(.outputFailed(outputResult)))
            return
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) {
            [weak self] in
            self?.scheduleTimeout(id: requestID)
        }
    }

    private func scheduleTimeout(id: UUID) {
        stateLock.lock()
        let loop = runLoop
        stateLock.unlock()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self, let pending = self.pending, pending.id == id else { return }
            self.pending = nil
            self.connectionPoisoned = true
            pending.completion(.failure(.requestTimedOut))
        }
        CFRunLoopWakeUp(loop)
    }

    private static func decode(_ device: IOHIDDevice) -> ProbeHIDDevice {
        let vendor = integer(kIOHIDVendorIDKey, device)
        let product = integer(kIOHIDProductIDKey, device)
        let location = integer(kIOHIDLocationIDKey, device)
        let usagePage = integer(kIOHIDPrimaryUsagePageKey, device)
        let usage = integer(kIOHIDPrimaryUsageKey, device)
        let transport = string(kIOHIDTransportKey, device)
        let serial = string(kIOHIDSerialNumberKey, device)
        let components = [vendor, product, location, usagePage, usage].map {
            $0.map(String.init) ?? "unknown"
        }
        return ProbeHIDDevice(
            deviceID: components.joined(separator: "-"),
            vendorID: vendor,
            productID: product,
            transport: transport,
            serialNumber: serial,
            locationID: location,
            hasExpectedOutputReport: hasExpectedOutputReport(device)
        )
    }

    private static func hasExpectedOutputReport(_ device: IOHIDDevice) -> Bool {
        guard let elements = IOHIDDeviceCopyMatchingElements(
            device,
            nil,
            IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else { return false }
        let reportIDs = Set(elements.compactMap { element -> UInt32? in
            guard IOHIDElementGetType(element) == kIOHIDElementTypeOutput else { return nil }
            return IOHIDElementGetReportID(element)
        })
        let maximum = (
            IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString)
                as? NSNumber
        )?.intValue
        return reportIDs == [0x11] && maximum == 20
    }

    private static func integer(_ key: String, _ device: IOHIDDevice) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private static func string(_ key: String, _ device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}

private let standaloneProbeDeviceMatched: IOHIDDeviceCallback = {
    context, result, _, device in
    guard let context else { return }
    Unmanaged<StandaloneReadOnlyHIDSession>.fromOpaque(context)
        .takeUnretainedValue()
        .deviceMatched(device, result: result)
}

private let standaloneProbeDeviceRemoved: IOHIDDeviceCallback = {
    context, _, _, device in
    guard let context else { return }
    Unmanaged<StandaloneReadOnlyHIDSession>.fromOpaque(context)
        .takeUnretainedValue()
        .deviceRemoved(device)
}

private let standaloneProbeInputReport: IOHIDReportCallback = {
    context, result, sender, _, reportID, report, reportLength in
    guard let context else { return }
    let sourceDevice = sender.map {
        Unmanaged<IOHIDDevice>.fromOpaque($0).takeUnretainedValue()
    }
    Unmanaged<StandaloneReadOnlyHIDSession>.fromOpaque(context)
        .takeUnretainedValue()
        .receivedReport(
            result: result,
            sourceDevice: sourceDevice,
            reportID: reportID,
            report: report,
            length: reportLength
        )
}

private final class ProbeDeviceOperationLease: @unchecked Sendable {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(beside journalURL: URL) throws -> ProbeDeviceOperationLease {
        let directory = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let lockURL = directory.appendingPathComponent(
            ".device-state-journal.operation.lock"
        )
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ProbeError.posix(operation: "open device-operation lease", code: errno)
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw ProbeError.posix(operation: "inspect device-operation lease", code: code)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            _ = Darwin.close(descriptor)
            throw ProbeError.nonRegularFile(lockURL.path)
        }
        var lock = flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_OFD_SETLK, &lock) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            if code == EACCES || code == EAGAIN { throw ProbeError.leaseUnavailable }
            throw ProbeError.posix(operation: "lock device-operation lease", code: code)
        }
        return ProbeDeviceOperationLease(descriptor: descriptor)
    }

    deinit {
        guard descriptor >= 0 else { return }
        var lock = flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_OFD_SETLK, &lock)
        _ = Darwin.close(descriptor)
        descriptor = -1
    }
}

#if MXERGO_READ_ONLY_PROBE
@main
private enum MXErgoRestoreTrialProbeMain {
    private static let confirmationArgument = "--confirmed-read-only-probe"

    static func main() async {
        let result: ProbeResult
        do {
            guard CommandLine.arguments.contains(confirmationArgument) else {
                throw ProbeError.explicitConfirmationMissing
            }
            let evidence = try await runProbe()
            result = ProbeResult(
                schemaVersion: ProbeResult.currentSchemaVersion,
                succeeded: evidence.matchesBaseline,
                completedAt: Date(),
                detail: evidence.matchesBaseline
                    ? "One isolated Precision GET matched the exact firmware-bound baseline; no SET request exists in this executable"
                    : "One isolated Precision GET differed from the exact firmware-bound baseline; raw evidence was retained only after synchronous HID shutdown and unchanged protected hashes",
                journalSHA256Before: evidence.journalBefore,
                journalSHA256After: evidence.journalAfter,
                backupSHA256Before: evidence.backupBefore,
                backupSHA256After: evidence.backupAfter,
                precisionRequest: evidence.request,
                precisionResponse: evidence.response,
                connectionEpoch: evidence.connectionEpoch
            )
        } catch {
            result = .failure(error)
        }

        do {
            try writeResult(result)
            let data = try JSONEncoder.pretty.encode(result)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            FileHandle.standardError.write(Data("Probe result write failed: \(error)\n".utf8))
            Darwin.exit(EXIT_FAILURE)
        }
        Darwin.exit(result.succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private static func runProbe() async throws -> ProbeEvidence {
        try validateClosedReadOnlyAllowlist()
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            throw ProbeError.missingJournal
        }
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            throw ProbeError.missingBackup
        }
        let lease = try ProbeDeviceOperationLease.acquire(beside: journalURL)
        defer { withExtendedLifetime(lease) {} }
        let journalBytesBefore = try readRegularFile(journalURL)
        let backupBytesBefore = try readRegularFile(backupURL)
        let journal: ProbeJournal
        do {
            journal = try JSONDecoder().decode(ProbeJournal.self, from: journalBytesBefore)
        } catch {
            throw ProbeError.invalidBaseline(String(describing: error))
        }
        let precisionBaseline = try journal.validatedPrecisionBaseline()

        let observations = ProbeObservationState()
        let session = StandaloneReadOnlyHIDSession { event in
            Task { await observations.receive(event) }
        }
        session.start()
        var sessionRunning = true
        do {
            let connected = try await observations.waitForSingleReadyDevice()
            guard journal.device.matches(connected) else {
                throw ProbeError.physicalIdentityMismatch
            }

            let reprogResponse = try await perform(.resolveReprog, on: session)
            let liveReprog = try decodeRootFeature(reprogResponse)
            guard liveReprog == journal.feature else { throw ProbeError.featureMismatch }

            let firmwareRootResponse = try await perform(
                .resolveDeviceInformation,
                on: session
            )
            let firmwareFeature = try decodeRootFeature(firmwareRootResponse)
            let liveFirmware = try await readFirmwareIdentity(
                feature: firmwareFeature,
                session: session
            )
            guard liveFirmware == journal.device.firmwareIdentity else {
                throw ProbeError.firmwareMismatch
            }

            let precisionRequest = FixedReadOnlyOperation.readPrecision(
                featureIndex: liveReprog.index
            ).request
            let precisionResponse = try await perform(
                .readPrecision(featureIndex: liveReprog.index),
                on: session
            )
            let matchesBaseline = Array(precisionResponse[4..<20]) == precisionBaseline

            guard session.stopAndWait(timeout: 5.0) else {
                throw ProbeError.synchronousShutdownTimedOut
            }
            sessionRunning = false
            let journalBytesAfter = try readRegularFile(journalURL)
            let backupBytesAfter = try readRegularFile(backupURL)
            guard journalBytesAfter == journalBytesBefore else {
                throw ProbeError.journalChanged
            }
            guard backupBytesAfter == backupBytesBefore else {
                throw ProbeError.backupChanged
            }
            return ProbeEvidence(
                journalBefore: sha256(journalBytesBefore),
                journalAfter: sha256(journalBytesAfter),
                backupBefore: sha256(backupBytesBefore),
                backupAfter: sha256(backupBytesAfter),
                request: precisionRequest,
                response: precisionResponse,
                connectionEpoch: session.connectionEpoch,
                matchesBaseline: matchesBaseline
            )
        } catch {
            if sessionRunning { _ = session.stopAndWait(timeout: 5.0) }
            throw error
        }
    }

    private static func perform(
        _ operation: FixedReadOnlyOperation,
        on session: StandaloneReadOnlyHIDSession
    ) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            session.perform(operation) { continuation.resume(with: $0) }
        }
    }

    /// The standalone helper has no general packet builder. Rechecking the
    /// complete closed operation family before opening IOHID makes accidental
    /// addition of a function-3 request fail before any hardware access.
    private static func validateClosedReadOnlyAllowlist() throws {
        let representativeOperations: [FixedReadOnlyOperation] = [
            .resolveReprog,
            .resolveDeviceInformation,
            .readDeviceInformation(featureIndex: 0x0A),
            .readFirmwareEntity(featureIndex: 0x0A, entityIndex: 0),
            .readFirmwareEntity(featureIndex: 0x0A, entityIndex: 15),
            .readPrecision(featureIndex: 0x0A),
            .trialPreflight(featureIndex: 0x0A),
        ]
        guard representativeOperations.allSatisfy({ operation in
            let request = operation.request
            return request.count == 20
                && request[0] == 0x11
                && request[1] == 0
                && request[3] >> 4 != 3
                && request[3] & 0x0F != 0
        }),
        FixedReadOnlyOperation.readPrecision(featureIndex: 0x0A).request
            == [0x11, 0x00, 0x0A, 0x2D, 0x00, 0xED]
                + Array(repeating: 0, count: 14) else {
            throw ProbeError.requestRegistrationFailed
        }
    }

    private static func decodeRootFeature(_ bytes: [UInt8]) throws -> ProbeFeature {
        guard bytes.count == 20,
              bytes[0] == 0x11,
              bytes[1] == 0,
              bytes[2] == 0,
              bytes[3] == 0x0E,
              bytes[4] != 0,
              bytes[4] != 0xFF else {
            throw ProbeError.malformedResponse
        }
        return ProbeFeature(
            index: bytes[4],
            type: bytes[5],
            version: bytes[6],
            rawParameters: Array(bytes[4..<20])
        )
    }

    private static func readFirmwareIdentity(
        feature: ProbeFeature,
        session: StandaloneReadOnlyHIDSession
    ) async throws -> String {
        let info = try await perform(
            .readDeviceInformation(featureIndex: feature.index),
            on: session
        )
        guard info.count == 20,
              info[2] == feature.index,
              info[3] == 0x0E,
              info[4] > 0,
              info[4] <= 16 else {
            throw ProbeError.malformedResponse
        }
        let count = Int(info[4])
        let unit = hex(Array(info[5...8]))
        let models = hex(Array(info[11...16]))
        let extended = String(format: "%02X", info[17])
        var parts = [
            "hidpp0003-v\(feature.version)",
            "unit=\(unit)",
            "model=\(models)",
            "ext=\(extended)",
        ]
        for index in 0..<count {
            let response = try await perform(
                .readFirmwareEntity(
                    featureIndex: feature.index,
                    entityIndex: UInt8(index)
                ),
                on: session
            )
            guard response.count == 20,
                  response[2] == feature.index,
                  response[3] == 0x1E else {
                throw ProbeError.malformedResponse
            }
            let stable = [response[4]]
                + Array(response[5...7])
                + Array(response[8...11])
                + Array(response[15...19])
            parts.append("e\(index)=\(hex(stable))")
        }
        return parts.joined(separator: "|")
    }

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.phib.MXErgoController", isDirectory: true)
    }

    private static var journalURL: URL {
        supportDirectory.appendingPathComponent("device-state-journal.json")
    }

    private static var backupURL: URL {
        supportDirectory.appendingPathComponent(
            "device-state-journal.pre-firmware-identity.json"
        )
    }

    private static var resultURL: URL {
        supportDirectory.appendingPathComponent("restore-trial-probe-result.json")
    }

    private static func writeResult(_ result: ProbeResult) throws {
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        try JSONEncoder.pretty.encode(result).write(to: resultURL, options: .atomic)
    }

    private static func readRegularFile(_ url: URL) throws -> Data {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw ProbeError.posix(operation: "inspect \(url.lastPathComponent)", code: errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw ProbeError.nonRegularFile(url.path)
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ProbeError.posix(operation: "open \(url.lastPathComponent)", code: errno)
        }
        defer { _ = Darwin.close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ProbeError.posix(operation: "read \(url.lastPathComponent)", code: errno)
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
#endif
