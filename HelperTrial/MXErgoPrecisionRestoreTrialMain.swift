import AppKit
import CryptoKit
import Darwin
import Foundation
@preconcurrency import IOKit.hid
import MXErgoHIDPP

private enum PrecisionRestoreTrialHelperError: Error, LocalizedError, Sendable {
    case explicitConfirmationMissing
    case competingSoftwareRunning([String])
    case missingJournal
    case missingBackup
    case existingTrialJournal
    case invalidBaseline
    case physicalIdentityMismatch
    case featureMismatch
    case firmwareMismatch
    case malformedResponse
    case transportNotReady
    case invalidTransportPhase
    case transportBusy
    case outputFailed(Int32)
    case requestTimedOut
    case deviceDisconnected
    case protocolError(UInt8)
    case acknowledgementMismatch
    case verificationRejected
    case synchronousShutdownTimedOut
    case journalChanged
    case backupChanged
    case nonRegularFile(String)
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .explicitConfirmationMissing:
            "The exact one-use Precision restore confirmation argument was not supplied"
        case let .competingSoftwareRunning(names):
            "Competing mouse software is still running: \(names.joined(separator: ", "))"
        case .missingJournal:
            "The firmware-bound live device-state journal is missing"
        case .missingBackup:
            "The original-byte firmware migration backup is missing"
        case .existingTrialJournal:
            "A restore-only trial journal already exists; read-only reconciliation is required"
        case .invalidBaseline:
            "The live recovery baseline is not eligible for the one-control trial"
        case .physicalIdentityMismatch:
            "The connected MX Ergo does not exactly match the recovery identity"
        case .featureMismatch:
            "The live REPROG_CONTROLS_V4 descriptor does not match the journal"
        case .firmwareMismatch:
            "The live firmware fingerprint does not match the journal"
        case .malformedResponse:
            "A HID++ response did not match the exact pending request"
        case .transportNotReady:
            "Exactly one eligible BLE MX Ergo is not ready"
        case .invalidTransportPhase:
            "The Precision transport phase is not eligible for this operation"
        case .transportBusy:
            "Another Precision request is already pending"
        case let .outputFailed(code):
            "IOHID returned \(code) after entering the one-use output boundary"
        case .requestTimedOut:
            "The one-use Precision request timed out; its outcome is unknown"
        case .deviceDisconnected:
            "The MX Ergo disconnected during the one-control trial"
        case let .protocolError(code):
            String(format: "The device returned HID++ protocol error 0x%02X", code)
        case .acknowledgementMismatch:
            "The SET response was not the exact reviewed request echo"
        case .verificationRejected:
            "The independent Precision GET could not be decoded"
        case .synchronousShutdownTimedOut:
            "The isolated IOHID session did not close synchronously"
        case .journalChanged:
            "The live device-state journal changed during the trial"
        case .backupChanged:
            "The original-byte backup changed during the trial"
        case let .nonRegularFile(path):
            "A required path is not a regular file: \(path)"
        case let .posix(operation, code):
            "\(operation) failed with POSIX code \(code)"
        }
    }
}

private struct PrecisionRestoreTrialResult: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let succeeded: Bool
    let completedAt: Date
    let detail: String
    let transactionID: UUID?
    let attemptID: UUID?
    let finalPhase: String?
    let finalRevision: UInt64?
    let setRequest: [UInt8]?
    let acknowledgement: [UInt8]?
    let verificationRequest: [UInt8]?
    let verificationState: [UInt8]?
    let journalSHA256Before: String?
    let journalSHA256After: String?
    let backupSHA256Before: String?
    let backupSHA256After: String?

    static func failure(_ error: Error) -> PrecisionRestoreTrialResult {
        PrecisionRestoreTrialResult(
            schemaVersion: currentSchemaVersion,
            succeeded: false,
            completedAt: Date(),
            detail: error.localizedDescription,
            transactionID: nil,
            attemptID: nil,
            finalPhase: nil,
            finalRevision: nil,
            setRequest: nil,
            acknowledgement: nil,
            verificationRequest: nil,
            verificationState: nil,
            journalSHA256Before: nil,
            journalSHA256After: nil,
            backupSHA256Before: nil,
            backupSHA256After: nil
        )
    }
}

private struct PrecisionRestoreTrialEvidence {
    let record: RestoreOnlyHardwareTrialRecord
    let journalBefore: String
    let journalAfter: String
    let backupBefore: String
    let backupAfter: String
}

private struct LiveBaselineReader: RestoreOnlyHardwareTrialBaselineReader {
    let fileURL: URL

    func readLiveBaseline() async throws -> Data {
        try TrialFileIO.readRegularFile(fileURL)
    }
}

private actor LivePrecisionRestoreTransport: RestoreOnlyHardwareTrialTransport {
    private enum Phase {
        case awaitingPreflight
        case readyForSet
        case awaitingSet
        case setAcknowledged
        case awaitingVerification
        case terminal
    }

    private enum Pending {
        case set(UUID, CheckedContinuation<HIDPP20LongMessage, any Error>)
        case verification(UUID, CheckedContinuation<DeviceTransactionWireState, any Error>)

        var requestID: UUID {
            switch self {
            case let .set(id, _), let .verification(id, _): id
            }
        }
    }

    private let session: RestoreOnlyHardwareTrialSession
    private let hidSession: StandaloneReadOnlyHIDSession
    private let adapter: DormantPrecisionTrialIOHIDAdapter
    private var phase: Phase = .awaitingPreflight
    private var pending: Pending?

    static func make(
        hidSession: StandaloneReadOnlyHIDSession,
        session: RestoreOnlyHardwareTrialSession
    ) throws -> LivePrecisionRestoreTransport {
        guard let (device, snapshot, epoch) = hidSession.singleReadyDevice(),
              epoch == session.connectionEpoch,
              Self.matches(snapshot, expected: session.device) else {
            throw PrecisionRestoreTrialHelperError.transportNotReady
        }
        let adapter = try DormantPrecisionTrialIOHIDAdapter(
            device: device,
            session: session
        )
        let transport = LivePrecisionRestoreTransport(
            session: session,
            hidSession: hidSession,
            adapter: adapter
        )
        hidSession.installTrialHandlers(
            report: { [weak transport] bytes, snapshot, connectionEpoch in
                Task {
                    await transport?.consumeReport(
                        bytes,
                        snapshot: snapshot,
                        connectionEpoch: connectionEpoch
                    )
                }
            },
            disconnected: { [weak transport] _ in
                Task { await transport?.disconnected() }
            }
        )
        return transport
    }

    private init(
        session: RestoreOnlyHardwareTrialSession,
        hidSession: StandaloneReadOnlyHIDSession,
        adapter: DormantPrecisionTrialIOHIDAdapter
    ) {
        self.session = session
        self.hidSession = hidSession
        self.adapter = adapter
    }

    func currentSession() async throws -> RestoreOnlyHardwareTrialSession {
        guard let (_, snapshot, epoch) = hidSession.singleReadyDevice(),
              epoch == session.connectionEpoch,
              Self.matches(snapshot, expected: session.device) else {
            throw PrecisionRestoreTrialHelperError.deviceDisconnected
        }
        return session
    }

    func readPrecisionReporting(
        request: HIDPP20LongMessage,
        expectedSession: RestoreOnlyHardwareTrialSession
    ) async throws -> DeviceTransactionWireState {
        guard expectedSession == session else {
            throw PrecisionRestoreTrialHelperError.physicalIdentityMismatch
        }
        switch phase {
        case .awaitingPreflight:
            let operation = FixedReadOnlyOperation.trialPreflight(
                featureIndex: session.featureIndex
            )
            guard request.bytes == operation.request else {
                throw PrecisionRestoreTrialHelperError.malformedResponse
            }
            let response = try await performReadOnly(operation)
            let state = try Self.decodeReporting(
                response,
                session: session
            )
            phase = .readyForSet
            return state
        case .setAcknowledged:
            return try await beginVerification(request: request)
        case .readyForSet, .awaitingSet, .awaitingVerification, .terminal:
            throw PrecisionRestoreTrialHelperError.invalidTransportPhase
        }
    }

    func setPrecisionTemporaryDiversionOff(
        request: HIDPP20LongMessage,
        expectedSession: RestoreOnlyHardwareTrialSession
    ) async throws -> HIDPP20LongMessage {
        guard expectedSession == session, phase == .readyForSet else {
            throw PrecisionRestoreTrialHelperError.invalidTransportPhase
        }
        guard pending == nil else {
            throw PrecisionRestoreTrialHelperError.transportBusy
        }
        phase = .awaitingSet
        let requestID = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pending = .set(requestID, continuation)
            Task {
                do {
                    let receipt = try await adapter.beginSet(
                        request: request,
                        expectedSession: expectedSession,
                        requestID: requestID
                    )
                    recordDispatch(receipt)
                } catch {
                    fail(requestID: requestID, error: error)
                }
            }
        }
    }

    private func beginVerification(
        request: HIDPP20LongMessage
    ) async throws -> DeviceTransactionWireState {
        guard pending == nil else {
            throw PrecisionRestoreTrialHelperError.transportBusy
        }
        phase = .awaitingVerification
        let requestID = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pending = .verification(requestID, continuation)
            Task {
                do {
                    let receipt = try await adapter.beginVerification(
                        request: request,
                        expectedSession: session,
                        requestID: requestID
                    )
                    recordDispatch(receipt)
                } catch {
                    fail(requestID: requestID, error: error)
                }
            }
        }
    }

    private func recordDispatch(
        _ receipt: DormantPrecisionTrialIOHIDDispatchReceipt
    ) {
        guard pending?.requestID == receipt.requestID else { return }
        guard receipt.ioReturn == Int32(kIOReturnSuccess) else {
            fail(
                requestID: receipt.requestID,
                error: PrecisionRestoreTrialHelperError.outputFailed(receipt.ioReturn)
            )
            return
        }
        let requestID = receipt.requestID
        Task {
            try? await Task.sleep(for: .seconds(2))
            await timeout(requestID: requestID)
        }
    }

    private func consumeReport(
        _ bytes: [UInt8],
        snapshot: ProbeHIDDevice,
        connectionEpoch: UInt64
    ) async {
        guard connectionEpoch == session.connectionEpoch,
              Self.matches(snapshot, expected: session.device) else {
            return
        }
        let result = await adapter.consumeInputReport(
            bytes,
            device: session.device,
            connectionEpoch: connectionEpoch
        )
        switch result {
        case .ignored:
            return
        case let .exactSetAcknowledgement(requestID):
            guard case let .set(expectedID, continuation) = pending,
                  expectedID == requestID,
                  let message = try? HIDPP20LongMessage(bytes: bytes) else {
                return
            }
            pending = nil
            phase = .setAcknowledged
            continuation.resume(returning: message)
        case let .acknowledgementMismatch(requestID, _):
            fail(
                requestID: requestID,
                error: PrecisionRestoreTrialHelperError.acknowledgementMismatch
            )
        case let .verification(requestID, state):
            guard case let .verification(expectedID, continuation) = pending,
                  expectedID == requestID else { return }
            pending = nil
            phase = .terminal
            continuation.resume(returning: state)
        case let .verificationRejected(requestID):
            fail(
                requestID: requestID,
                error: PrecisionRestoreTrialHelperError.verificationRejected
            )
        case let .protocolError(requestID, rawCode):
            fail(
                requestID: requestID,
                error: PrecisionRestoreTrialHelperError.protocolError(rawCode)
            )
        }
    }

    private func disconnected() async {
        await adapter.disconnected()
        guard let requestID = pending?.requestID else {
            phase = .terminal
            return
        }
        fail(
            requestID: requestID,
            error: PrecisionRestoreTrialHelperError.deviceDisconnected
        )
    }

    private func timeout(requestID: UUID) async {
        guard pending?.requestID == requestID else { return }
        await adapter.timeout(
            requestID: requestID,
            connectionEpoch: session.connectionEpoch
        )
        fail(
            requestID: requestID,
            error: PrecisionRestoreTrialHelperError.requestTimedOut
        )
    }

    private func fail(requestID: UUID, error: any Error) {
        guard let pending, pending.requestID == requestID else { return }
        self.pending = nil
        phase = .terminal
        switch pending {
        case let .set(_, continuation):
            continuation.resume(throwing: error)
        case let .verification(_, continuation):
            continuation.resume(throwing: error)
        }
    }

    private func performReadOnly(
        _ operation: FixedReadOnlyOperation
    ) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            hidSession.perform(operation) { continuation.resume(with: $0) }
        }
    }

    private static func decodeReporting(
        _ bytes: [UInt8],
        session: RestoreOnlyHardwareTrialSession
    ) throws -> DeviceTransactionWireState {
        let message = try HIDPP20LongMessage(bytes: bytes)
        let reporting = try ReprogControlsV4.decodeReporting(
            requestedControlID: RestoreOnlyHardwareTrialRecord.precisionControlID,
            from: message,
            featureIndex: session.featureIndex,
            featureVersion: session.featureVersion
        )
        return try DeviceTransactionWireState(
            rawParameters: reporting.rawParameters
        )
    }

    private static func matches(
        _ snapshot: ProbeHIDDevice,
        expected: JournalDeviceIdentity
    ) -> Bool {
        guard snapshot.deviceID == expected.deviceID,
              snapshot.vendorID == expected.vendorID,
              snapshot.productID == expected.productID,
              snapshot.transport == expected.transport,
              snapshot.locationID == expected.locationID,
              snapshot.hasExpectedOutputReport else {
            return false
        }
        if let serial = expected.serialNumber, !serial.isEmpty {
            return snapshot.serialNumber == serial
        }
        return snapshot.locationID == expected.locationID
    }
}

private enum TrialFileIO {
    static func readRegularFile(_ url: URL) throws -> Data {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw PrecisionRestoreTrialHelperError.posix(
                operation: "inspect \(url.lastPathComponent)",
                code: errno
            )
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw PrecisionRestoreTrialHelperError.nonRegularFile(url.path)
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw PrecisionRestoreTrialHelperError.posix(
                operation: "open \(url.lastPathComponent)",
                code: errno
            )
        }
        defer { _ = Darwin.close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw PrecisionRestoreTrialHelperError.posix(
                    operation: "read \(url.lastPathComponent)",
                    code: errno
                )
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@main
private enum MXErgoPrecisionRestoreTrialMain {
    private static let confirmationArgument = "--confirmed-one-control-precision-restore"

    static func main() async {
        let result: PrecisionRestoreTrialResult
        do {
            guard Array(CommandLine.arguments.dropFirst()) == [confirmationArgument] else {
                throw PrecisionRestoreTrialHelperError.explicitConfirmationMissing
            }
            let evidence = try await runTrial()
            let record = evidence.record
            result = PrecisionRestoreTrialResult(
                schemaVersion: PrecisionRestoreTrialResult.currentSchemaVersion,
                succeeded: true,
                completedAt: Date(),
                detail: "One Precision restore-only SET was acknowledged and independently verified at the exact clean baseline",
                transactionID: record.transactionID,
                attemptID: record.attemptID,
                finalPhase: record.phase.rawValue,
                finalRevision: record.revision,
                setRequest: record.setRequestBytes,
                acknowledgement: record.acknowledgementBytes,
                verificationRequest: record.verificationRequestBytes,
                verificationState: record.verificationState?.rawParameters,
                journalSHA256Before: evidence.journalBefore,
                journalSHA256After: evidence.journalAfter,
                backupSHA256Before: evidence.backupBefore,
                backupSHA256After: evidence.backupAfter
            )
        } catch {
            result = .failure(error)
        }

        do {
            try writeResult(result)
            let data = try resultEncoder.encode(result)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            FileHandle.standardError.write(Data("Trial result write failed: \(error)\n".utf8))
            Darwin.exit(EXIT_FAILURE)
        }
        Darwin.exit(result.succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private static func runTrial() async throws -> PrecisionRestoreTrialEvidence {
        try ensureCompetingSoftwareIsStopped()
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            throw PrecisionRestoreTrialHelperError.missingJournal
        }
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            throw PrecisionRestoreTrialHelperError.missingBackup
        }
        guard !FileManager.default.fileExists(atPath: trialJournalURL.path) else {
            throw PrecisionRestoreTrialHelperError.existingTrialJournal
        }

        let deviceLease = try MXErgoDeviceOperationLease.acquire(beside: journalURL)
        defer { withExtendedLifetime(deviceLease) {} }
        let journalBytesBefore = try TrialFileIO.readRegularFile(journalURL)
        let backupBytesBefore = try TrialFileIO.readRegularFile(backupURL)
        let journal = try JSONDecoder().decode(
            DeviceStateJournal.self,
            from: journalBytesBefore
        )
        try journal.validateForRecovery()
        guard !journal.requiresRecovery,
              journal.schemaVersion == DeviceStateJournal.currentSchemaVersion,
              journal.feature.version == 3,
              journal.device.firmwareIdentity?.isEmpty == false else {
            throw PrecisionRestoreTrialHelperError.invalidBaseline
        }

        let observations = ProbeObservationState()
        let hidSession = StandaloneReadOnlyHIDSession { event in
            Task { await observations.receive(event) }
        }
        hidSession.start()
        var sessionRunning = true
        defer {
            if sessionRunning { _ = hidSession.stopAndWait(timeout: 5.0) }
        }

        let connected = try await observations.waitForSingleReadyDevice()
        guard matches(connected, expected: journal.device) else {
            throw PrecisionRestoreTrialHelperError.physicalIdentityMismatch
        }

        let reprogResponse = try await perform(.resolveReprog, on: hidSession)
        let liveReprog = try decodeRootFeature(reprogResponse)
        guard liveReprog == journal.feature else {
            throw PrecisionRestoreTrialHelperError.featureMismatch
        }

        let firmwareRoot = try await perform(
            .resolveDeviceInformation,
            on: hidSession
        )
        let firmwareFeature = try decodeRootFeature(firmwareRoot)
        let liveFirmware = try await readFirmwareIdentity(
            feature: firmwareFeature,
            session: hidSession
        )
        guard liveFirmware == journal.device.firmwareIdentity else {
            throw PrecisionRestoreTrialHelperError.firmwareMismatch
        }
        guard let (_, readySnapshot, connectionEpoch) = hidSession.singleReadyDevice(),
              matches(readySnapshot, expected: journal.device) else {
            throw PrecisionRestoreTrialHelperError.transportNotReady
        }

        let trialSession = RestoreOnlyHardwareTrialSession(
            device: journal.device,
            featureIndex: liveReprog.index,
            featureVersion: liveReprog.version,
            connectionEpoch: connectionEpoch,
            matchingDeviceCount: 1,
            outputReportByteCount: HIDPP20LongMessage.byteCount
        )
        let transport = try LivePrecisionRestoreTransport.make(
            hidSession: hidSession,
            session: trialSession
        )
        let prepared = try RestoreOnlyHardwareTrialRecord.prepare(
            sourceBaselineData: journalBytesBefore,
            currentFeature: liveReprog,
            connectionEpoch: connectionEpoch
        )
        let repository = DurableRestoreOnlyHardwareTrialRepository(
            fileURL: trialJournalURL
        )
        let runner = RestoreOnlyHardwareTrialRunner(
            repository: repository,
            transport: transport,
            baselineReader: LiveBaselineReader(fileURL: journalURL),
            liveJournalURL: journalURL,
            preacquiredDeviceOperationLease: deviceLease
        )
        try await runner.install(prepared)
        let final = try await runner.runExplicitlyConfirmed()

        guard hidSession.stopAndWait(timeout: 5.0) else {
            throw PrecisionRestoreTrialHelperError.synchronousShutdownTimedOut
        }
        sessionRunning = false
        let journalBytesAfter = try TrialFileIO.readRegularFile(journalURL)
        let backupBytesAfter = try TrialFileIO.readRegularFile(backupURL)
        guard journalBytesAfter == journalBytesBefore else {
            throw PrecisionRestoreTrialHelperError.journalChanged
        }
        guard backupBytesAfter == backupBytesBefore else {
            throw PrecisionRestoreTrialHelperError.backupChanged
        }
        return PrecisionRestoreTrialEvidence(
            record: final,
            journalBefore: TrialFileIO.sha256(journalBytesBefore),
            journalAfter: TrialFileIO.sha256(journalBytesAfter),
            backupBefore: TrialFileIO.sha256(backupBytesBefore),
            backupAfter: TrialFileIO.sha256(backupBytesAfter)
        )
    }

    /// Delegates to the canonical, unit-tested classifier in MXErgoHIDPP.
    ///
    /// This helper is the only binary in the project that can dispatch a SET,
    /// so a competitor rule that disagrees with the menu app's is the worst
    /// possible divergence. The previous inline rule never stripped
    /// punctuation, so it required the literal substring "logi options" and
    /// matched neither "LogiOptions" nor the `btt` / `btthelper` aliases, and
    /// it recognised only its own bundle plus the menu app rather than the
    /// whole com.phib.MXErgo family.
    private static func ensureCompetingSoftwareIsStopped() throws {
        let scanner = PrecisionCompetingProcessScanner {
            NSWorkspace.shared.runningApplications.map { application in
                PrecisionRunningApplicationSnapshot(
                    processIdentifier: application.processIdentifier,
                    bundleIdentifier: application.bundleIdentifier,
                    localizedName: application.localizedName,
                    executablePath: application.executableURL?.path
                )
            }
        }
        let forbidden = try scanner.scan(
            excludingProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        ).map(\.displayName)
        guard forbidden.isEmpty else {
            throw PrecisionRestoreTrialHelperError.competingSoftwareRunning(
                forbidden.sorted()
            )
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

    private static func decodeRootFeature(
        _ bytes: [UInt8]
    ) throws -> HIDPP20FeatureDescriptor {
        let message = try HIDPP20LongMessage(bytes: bytes)
        let descriptor = try HIDPP20Root.decodeFeatureDescriptor(from: message)
        guard descriptor.index != 0, descriptor.index != 0xFF else {
            throw PrecisionRestoreTrialHelperError.malformedResponse
        }
        return descriptor
    }

    private static func readFirmwareIdentity(
        feature: HIDPP20FeatureDescriptor,
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
            throw PrecisionRestoreTrialHelperError.malformedResponse
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
                throw PrecisionRestoreTrialHelperError.malformedResponse
            }
            let stable = [response[4]]
                + Array(response[5...7])
                + Array(response[8...11])
                + Array(response[15...19])
            parts.append("e\(index)=\(hex(stable))")
        }
        return parts.joined(separator: "|")
    }

    private static func matches(
        _ snapshot: ProbeHIDDevice,
        expected: JournalDeviceIdentity
    ) -> Bool {
        guard snapshot.deviceID == expected.deviceID,
              snapshot.vendorID == expected.vendorID,
              snapshot.productID == expected.productID,
              snapshot.transport == expected.transport,
              snapshot.locationID == expected.locationID,
              snapshot.hasExpectedOutputReport else {
            return false
        }
        if let serial = expected.serialNumber, !serial.isEmpty {
            return snapshot.serialNumber == serial
        }
        return snapshot.locationID == expected.locationID
    }

    private static var supportDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(
            "com.phib.MXErgoController",
            isDirectory: true
        )
    }

    private static var journalURL: URL {
        supportDirectory.appendingPathComponent("device-state-journal.json")
    }

    private static var backupURL: URL {
        supportDirectory.appendingPathComponent(
            "device-state-journal.pre-firmware-identity.json"
        )
    }

    private static var trialJournalURL: URL {
        supportDirectory.appendingPathComponent(
            "restore-only-precision-trial.json"
        )
    }

    private static var resultURL: URL {
        supportDirectory.appendingPathComponent(
            "restore-only-precision-trial-result.json"
        )
    }

    private static func writeResult(
        _ result: PrecisionRestoreTrialResult
    ) throws {
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        try resultEncoder.encode(result).write(to: resultURL, options: .atomic)
    }

    private static var resultEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}
