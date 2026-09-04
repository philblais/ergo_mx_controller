import Foundation

public enum HIDPP20CodecError: Error, Sendable, Equatable {
    case invalidLength(expected: Int, actual: Int)
    case invalidReportID(UInt8)
    case functionIDOutOfRange(UInt8)
    case softwareIDOutOfRange(UInt8)
    case softwareIDMustBeNonzero
    case tooManyParameters(maximum: Int, actual: Int)
    case unexpectedResponse
    case controlCountOutOfRange(UInt8)
    case responseControlMismatch(expected: UInt16, actual: UInt16)
    case firmwareEntityCountOutOfRange(UInt8)
    case firmwareEntityIndexOutOfRange(UInt8)
}

/// The 20-byte HID++ 2.0 long-message shape used by the MX Ergo BLE interface.
///
/// This type only describes bytes. Creating a message never sends it to hardware.
public struct HIDPP20LongMessage: Sendable, Equatable {
    public static let reportID: UInt8 = 0x11
    public static let byteCount = 20
    public static let parameterCount = 16

    public let deviceIndex: UInt8
    public let featureIndex: UInt8
    /// The original combined function/software byte, retained verbatim.
    public let address: UInt8
    public let parameters: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else {
            throw HIDPP20CodecError.invalidLength(expected: Self.byteCount, actual: bytes.count)
        }
        guard bytes[0] == Self.reportID else {
            throw HIDPP20CodecError.invalidReportID(bytes[0])
        }

        deviceIndex = bytes[1]
        featureIndex = bytes[2]
        address = bytes[3]
        parameters = Array(bytes[4...])
    }

    public init(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        functionID: UInt8,
        softwareID: UInt8,
        parameters: [UInt8] = [],
        requireRequestSoftwareID: Bool = true
    ) throws {
        guard functionID <= 0x0F else {
            throw HIDPP20CodecError.functionIDOutOfRange(functionID)
        }
        guard softwareID <= 0x0F else {
            throw HIDPP20CodecError.softwareIDOutOfRange(softwareID)
        }
        if requireRequestSoftwareID, softwareID == 0 {
            throw HIDPP20CodecError.softwareIDMustBeNonzero
        }
        guard parameters.count <= Self.parameterCount else {
            throw HIDPP20CodecError.tooManyParameters(
                maximum: Self.parameterCount,
                actual: parameters.count
            )
        }

        self.deviceIndex = deviceIndex
        self.featureIndex = featureIndex
        address = functionID << 4 | softwareID
        self.parameters = parameters + Array(
            repeating: 0,
            count: Self.parameterCount - parameters.count
        )
    }

    public var functionID: UInt8 { address >> 4 }
    public var softwareID: UInt8 { address & 0x0F }

    public var bytes: [UInt8] {
        [Self.reportID, deviceIndex, featureIndex, address] + parameters
    }

    public var requestKey: HIDPP20RequestKey {
        HIDPP20RequestKey(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            address: address
        )
    }
}

public struct HIDPP20RequestKey: Sendable, Hashable, Codable {
    public let deviceIndex: UInt8
    public let featureIndex: UInt8
    public let address: UInt8

    public init(deviceIndex: UInt8, featureIndex: UInt8, address: UInt8) {
        self.deviceIndex = deviceIndex
        self.featureIndex = featureIndex
        self.address = address
    }
}

public enum HIDPP20ProtocolErrorCode: UInt8, Sendable, Equatable, Codable {
    case unknown = 0x01
    case invalidArguments = 0x02
    case outOfRange = 0x03
    case hardwareError = 0x04
    case notAllowed = 0x05
    case invalidFeatureIndex = 0x06
    case invalidFunctionID = 0x07
    case busy = 0x08
    case unsupported = 0x09
}

public struct HIDPP20ErrorResponse: Sendable, Equatable {
    public let deviceIndex: UInt8
    public let originalFeatureIndex: UInt8
    public let originalAddress: UInt8
    public let rawErrorCode: UInt8
    public let rawMessageBytes: [UInt8]

    public init?(message: HIDPP20LongMessage) {
        guard message.featureIndex == 0xFF else { return nil }
        deviceIndex = message.deviceIndex
        // HID++ 2.0 errors place the rejected feature index in byte 3 and the
        // rejected function/client address in parameter byte zero.
        originalFeatureIndex = message.address
        originalAddress = message.parameters[0]
        rawErrorCode = message.parameters[1]
        rawMessageBytes = message.bytes
    }

    public var code: HIDPP20ProtocolErrorCode? {
        HIDPP20ProtocolErrorCode(rawValue: rawErrorCode)
    }

    public var requestKey: HIDPP20RequestKey {
        HIDPP20RequestKey(
            deviceIndex: deviceIndex,
            featureIndex: originalFeatureIndex,
            address: originalAddress
        )
    }
}

public enum HIDPP20CorrelatedReply: Sendable, Equatable {
    case response(id: UUID, message: HIDPP20LongMessage)
    case protocolError(id: UUID, error: HIDPP20ErrorResponse)
}

public enum HIDPP20RequestCorrelationError: Error, Sendable, Equatable {
    case requestAlreadyPending
    case connectionEpochPoisoned(UInt64)
    case invalidConnectionEpoch(expected: UInt64, actual: UInt64)
}

/// Single-flight response correlation for one physical connection epoch.
/// A timeout poisons the epoch so that a late response can never satisfy a later request.
public struct HIDPP20RequestCorrelator: Sendable {
    private struct Pending: Sendable {
        let id: UUID
        let key: HIDPP20RequestKey
        let epoch: UInt64
    }

    public private(set) var connectionEpoch: UInt64
    public private(set) var isConnectionEpochPoisoned = false
    private var pending: Pending?

    public init(connectionEpoch: UInt64 = 0) {
        self.connectionEpoch = connectionEpoch
    }

    public var hasPendingRequest: Bool { pending != nil }

    @discardableResult
    public mutating func register(
        _ request: HIDPP20LongMessage,
        connectionEpoch: UInt64,
        id: UUID = UUID()
    ) throws -> UUID {
        guard connectionEpoch == self.connectionEpoch else {
            throw HIDPP20RequestCorrelationError.invalidConnectionEpoch(
                expected: self.connectionEpoch,
                actual: connectionEpoch
            )
        }
        guard !isConnectionEpochPoisoned else {
            throw HIDPP20RequestCorrelationError.connectionEpochPoisoned(connectionEpoch)
        }
        guard pending == nil else {
            throw HIDPP20RequestCorrelationError.requestAlreadyPending
        }
        pending = Pending(id: id, key: request.requestKey, epoch: connectionEpoch)
        return id
    }

    /// Cancelling before an output call is safe and does not poison the epoch.
    public mutating func cancelBeforeSend(id: UUID) {
        guard pending?.id == id else { return }
        pending = nil
    }

    /// A sent request that times out makes this connection unsafe for further output.
    public mutating func timeout(id: UUID, connectionEpoch: UInt64) {
        guard pending?.id == id,
              pending?.epoch == connectionEpoch,
              connectionEpoch == self.connectionEpoch else { return }
        pending = nil
        isConnectionEpochPoisoned = true
    }

    /// A disconnect invalidates every request and all cached feature indexes.
    public mutating func disconnected() {
        pending = nil
        connectionEpoch &+= 1
        isConnectionEpochPoisoned = false
    }

    public mutating func consume(
        _ message: HIDPP20LongMessage,
        connectionEpoch: UInt64
    ) -> HIDPP20CorrelatedReply? {
        guard connectionEpoch == self.connectionEpoch,
              !isConnectionEpochPoisoned,
              let pending,
              pending.epoch == connectionEpoch else {
            return nil
        }

        if let error = HIDPP20ErrorResponse(message: message),
           error.requestKey == pending.key {
            self.pending = nil
            return .protocolError(id: pending.id, error: error)
        }

        guard message.requestKey == pending.key else {
            return nil
        }
        self.pending = nil
        return .response(id: pending.id, message: message)
    }
}

public enum HIDPP20Root {
    public static let featureIndex: UInt8 = 0x00

    public static func getFeatureRequest(
        _ featureID: UInt16,
        deviceIndex: UInt8,
        softwareID: UInt8
    ) throws -> HIDPP20LongMessage {
        try HIDPP20LongMessage(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: 0x00,
            softwareID: softwareID,
            parameters: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)]
        )
    }

    public static func decodeFeatureDescriptor(
        from response: HIDPP20LongMessage
    ) throws -> HIDPP20FeatureDescriptor {
        guard response.featureIndex == featureIndex,
              response.functionID == 0x00 else {
            throw HIDPP20CodecError.unexpectedResponse
        }
        return HIDPP20FeatureDescriptor(
            index: response.parameters[0],
            type: response.parameters[1],
            version: response.parameters[2],
            rawParameters: response.parameters
        )
    }
}

public struct HIDPP20FeatureDescriptor: Sendable, Equatable, Codable {
    public let index: UInt8
    public let type: UInt8
    public let version: UInt8
    public let rawParameters: [UInt8]

    public init(
        index: UInt8,
        type: UInt8,
        version: UInt8,
        rawParameters: [UInt8] = Array(repeating: 0, count: HIDPP20LongMessage.parameterCount)
    ) {
        self.index = index
        self.type = type
        self.version = version
        self.rawParameters = rawParameters
    }

    public var isSupported: Bool { index != 0 }
}
