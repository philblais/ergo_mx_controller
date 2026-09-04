import Foundation
@preconcurrency import IOKit.hid
import MXErgoHIDPP

enum DormantPrecisionTrialIOHIDError: Error, Sendable, Equatable {
    case invalidSession
    case invalidSetRequest
    case invalidVerificationRequest
    case invalidPhase
    case setAlreadyAttempted
}

enum DormantPrecisionTrialIOHIDStatus: Sendable, Equatable {
    case ready
    case awaitingSetAcknowledgement
    case setAcknowledged
    case awaitingVerification
    case terminalUnknown
    case terminalVerified
}

enum DormantPrecisionTrialIOHIDRequestKind: Sendable, Equatable {
    case setTemporaryDiversionOff
    case getReportingVerification
}

enum DormantPrecisionTrialIOHIDOutcomeClassification: Sendable, Equatable {
    /// Entering IOHID makes every return value potentially dispatched. A
    /// success return is not an acknowledgement and never proves device state.
    case mayHaveDispatched
}

struct DormantPrecisionTrialIOHIDDispatchReceipt: Sendable, Equatable {
    let requestID: UUID
    let kind: DormantPrecisionTrialIOHIDRequestKind
    let requestBytes: [UInt8]
    let ioReturn: Int32
    let classification: DormantPrecisionTrialIOHIDOutcomeClassification
}

enum DormantPrecisionTrialIOHIDInputResult: Sendable, Equatable {
    case ignored
    case exactSetAcknowledgement(requestID: UUID)
    case acknowledgementMismatch(requestID: UUID, responseBytes: [UInt8])
    case verification(requestID: UUID, state: DeviceTransactionWireState)
    case verificationRejected(requestID: UUID)
    case protocolError(requestID: UUID, rawCode: UInt8)
}

typealias DormantPrecisionTrialIOHIDReportWriter = @Sendable ([UInt8]) -> IOReturn

private struct UncheckedIOHIDDevice: @unchecked Sendable {
    let value: IOHIDDevice
}

/// Purpose-built boundary for the first Precision-only restore trial.
///
/// This target has no library product and no dependency edge from the app.
/// The adapter cannot construct packets and rejects every request except the
/// reviewed feature-v3 Precision SET and its separate GET verification. The
/// actual IOHID entry point is behind an injected writer for boundary tests.
actor DormantPrecisionTrialIOHIDAdapter {
    private enum State {
        case ready
        case awaitingSetAcknowledgement(id: UUID, request: HIDPP20LongMessage)
        case setAcknowledged
        case awaitingVerification(id: UUID)
        case terminalUnknown
        case terminalVerified
    }

    private let session: RestoreOnlyHardwareTrialSession
    private let writer: DormantPrecisionTrialIOHIDReportWriter
    private var correlator: HIDPP20RequestCorrelator
    private var state: State = .ready
    private var setAttempted = false

    init(
        device: IOHIDDevice,
        session: RestoreOnlyHardwareTrialSession
    ) throws {
        try Self.validate(session)
        let uncheckedDevice = UncheckedIOHIDDevice(value: device)
        self.session = session
        correlator = HIDPP20RequestCorrelator(
            connectionEpoch: session.connectionEpoch
        )
        writer = { bytes in
            var mutableBytes = bytes
            let byteCount = mutableBytes.count
            return mutableBytes.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return kIOReturnBadArgument
                }
                return IOHIDDeviceSetReport(
                    uncheckedDevice.value,
                    kIOHIDReportTypeOutput,
                    CFIndex(HIDPP20LongMessage.reportID),
                    baseAddress,
                    byteCount
                )
            }
        }
    }

    init(
        session: RestoreOnlyHardwareTrialSession,
        writer: @escaping DormantPrecisionTrialIOHIDReportWriter
    ) throws {
        try Self.validate(session)
        self.session = session
        self.writer = writer
        correlator = HIDPP20RequestCorrelator(
            connectionEpoch: session.connectionEpoch
        )
    }

    var status: DormantPrecisionTrialIOHIDStatus {
        switch state {
        case .ready: .ready
        case .awaitingSetAcknowledgement: .awaitingSetAcknowledgement
        case .setAcknowledged: .setAcknowledged
        case .awaitingVerification: .awaitingVerification
        case .terminalUnknown: .terminalUnknown
        case .terminalVerified: .terminalVerified
        }
    }

    func beginSet(
        request: HIDPP20LongMessage,
        expectedSession: RestoreOnlyHardwareTrialSession,
        requestID: UUID = UUID()
    ) throws -> DormantPrecisionTrialIOHIDDispatchReceipt {
        try Task.checkCancellation()
        guard expectedSession == session else {
            throw DormantPrecisionTrialIOHIDError.invalidSession
        }
        guard !setAttempted else {
            throw DormantPrecisionTrialIOHIDError.setAlreadyAttempted
        }
        guard case .ready = state else {
            throw DormantPrecisionTrialIOHIDError.invalidPhase
        }
        let exactRequest = try Self.exactSetRequest(for: session)
        guard request.bytes == exactRequest.bytes else {
            throw DormantPrecisionTrialIOHIDError.invalidSetRequest
        }

        try correlator.register(
            request,
            connectionEpoch: session.connectionEpoch,
            id: requestID
        )
        // The attempt bit is set before the seam is entered. No IOReturn,
        // cancellation, timeout, or late reply can make a second SET eligible.
        setAttempted = true
        state = .awaitingSetAcknowledgement(id: requestID, request: request)
        let ioReturn = writer(request.bytes)
        if ioReturn != kIOReturnSuccess {
            correlator.timeout(
                id: requestID,
                connectionEpoch: session.connectionEpoch
            )
            state = .terminalUnknown
        }
        return DormantPrecisionTrialIOHIDDispatchReceipt(
            requestID: requestID,
            kind: .setTemporaryDiversionOff,
            requestBytes: request.bytes,
            ioReturn: Int32(ioReturn),
            classification: .mayHaveDispatched
        )
    }

    func beginVerification(
        request: HIDPP20LongMessage,
        expectedSession: RestoreOnlyHardwareTrialSession,
        requestID: UUID = UUID()
    ) throws -> DormantPrecisionTrialIOHIDDispatchReceipt {
        try Task.checkCancellation()
        guard expectedSession == session else {
            throw DormantPrecisionTrialIOHIDError.invalidSession
        }
        guard case .setAcknowledged = state else {
            throw DormantPrecisionTrialIOHIDError.invalidPhase
        }
        let exactRequest = try Self.exactVerificationRequest(for: session)
        guard request.bytes == exactRequest.bytes else {
            throw DormantPrecisionTrialIOHIDError.invalidVerificationRequest
        }

        try correlator.register(
            request,
            connectionEpoch: session.connectionEpoch,
            id: requestID
        )
        state = .awaitingVerification(id: requestID)
        let ioReturn = writer(request.bytes)
        if ioReturn != kIOReturnSuccess {
            correlator.timeout(
                id: requestID,
                connectionEpoch: session.connectionEpoch
            )
            state = .terminalUnknown
        }
        return DormantPrecisionTrialIOHIDDispatchReceipt(
            requestID: requestID,
            kind: .getReportingVerification,
            requestBytes: request.bytes,
            ioReturn: Int32(ioReturn),
            classification: .mayHaveDispatched
        )
    }

    func consumeInputReport(
        _ bytes: [UInt8],
        device: JournalDeviceIdentity,
        connectionEpoch: UInt64
    ) -> DormantPrecisionTrialIOHIDInputResult {
        guard device == session.device,
              let message = try? HIDPP20LongMessage(bytes: bytes),
              let reply = correlator.consume(
                  message,
                  connectionEpoch: connectionEpoch
              ) else {
            return .ignored
        }

        switch reply {
        case let .protocolError(id, error):
            state = .terminalUnknown
            return .protocolError(requestID: id, rawCode: error.rawErrorCode)
        case let .response(id, response):
            switch state {
            case let .awaitingSetAcknowledgement(expectedID, request):
                guard id == expectedID else { return .ignored }
                guard response.bytes == request.bytes else {
                    state = .terminalUnknown
                    return .acknowledgementMismatch(
                        requestID: id,
                        responseBytes: response.bytes
                    )
                }
                state = .setAcknowledged
                return .exactSetAcknowledgement(requestID: id)
            case let .awaitingVerification(expectedID):
                guard id == expectedID else { return .ignored }
                guard let reporting = try? ReprogControlsV4.decodeReporting(
                    requestedControlID: 0x00ED,
                    from: response,
                    featureIndex: session.featureIndex,
                    featureVersion: session.featureVersion
                ),
                let wireState = try? DeviceTransactionWireState(
                    rawParameters: reporting.rawParameters
                ) else {
                    state = .terminalUnknown
                    return .verificationRejected(requestID: id)
                }
                state = .terminalVerified
                return .verification(requestID: id, state: wireState)
            case .ready, .setAcknowledged, .terminalUnknown, .terminalVerified:
                return .ignored
            }
        }
    }

    func timeout(requestID: UUID, connectionEpoch: UInt64) {
        let matchesPending: Bool
        switch state {
        case let .awaitingSetAcknowledgement(id, _),
             let .awaitingVerification(id):
            matchesPending = id == requestID
        case .ready, .setAcknowledged, .terminalUnknown, .terminalVerified:
            matchesPending = false
        }
        correlator.timeout(id: requestID, connectionEpoch: connectionEpoch)
        if matchesPending { state = .terminalUnknown }
    }

    func disconnected() {
        correlator.disconnected()
        state = .terminalUnknown
    }

    private static func exactSetRequest(
        for session: RestoreOnlyHardwareTrialSession
    ) throws -> HIDPP20LongMessage {
        try HIDPP20LongMessage(
            deviceIndex: 0,
            featureIndex: session.featureIndex,
            functionID: 3,
            softwareID: 0x0E,
            parameters: [0x00, 0xED, 0x02, 0x00, 0x00]
        )
    }

    private static func exactVerificationRequest(
        for session: RestoreOnlyHardwareTrialSession
    ) throws -> HIDPP20LongMessage {
        try ReprogControlsV4.getReportingRequest(
            controlID: 0x00ED,
            featureIndex: session.featureIndex,
            deviceIndex: 0,
            softwareID: 0x0E
        )
    }

    private static func validate(_ session: RestoreOnlyHardwareTrialSession) throws {
        guard session.device.vendorID == 0x046D,
              session.device.productID == 0xB01D,
              session.device.transport == "Bluetooth Low Energy",
              session.device.serialNumber?.isEmpty == false,
              session.device.locationID != nil,
              session.device.firmwareIdentity?.isEmpty == false,
              session.featureIndex != 0,
              session.featureIndex != 0xFF,
              session.featureVersion == 3,
              session.matchingDeviceCount == 1,
              session.outputReportByteCount == HIDPP20LongMessage.byteCount else {
            throw DormantPrecisionTrialIOHIDError.invalidSession
        }
    }
}
