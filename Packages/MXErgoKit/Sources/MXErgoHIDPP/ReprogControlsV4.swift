import Foundation

public enum ReprogControlsV4 {
    public static let featureID: UInt16 = 0x1B04

    public static func getCountRequest(
        featureIndex: UInt8,
        deviceIndex: UInt8,
        softwareID: UInt8
    ) throws -> HIDPP20LongMessage {
        try request(
            featureIndex: featureIndex,
            functionID: 0,
            deviceIndex: deviceIndex,
            softwareID: softwareID
        )
    }

    public static func getControlInfoRequest(
        index: UInt8,
        featureIndex: UInt8,
        deviceIndex: UInt8,
        softwareID: UInt8
    ) throws -> HIDPP20LongMessage {
        try request(
            featureIndex: featureIndex,
            functionID: 1,
            deviceIndex: deviceIndex,
            softwareID: softwareID,
            parameters: [index]
        )
    }

    public static func getReportingRequest(
        controlID: UInt16,
        featureIndex: UInt8,
        deviceIndex: UInt8,
        softwareID: UInt8
    ) throws -> HIDPP20LongMessage {
        try request(
            featureIndex: featureIndex,
            functionID: 2,
            deviceIndex: deviceIndex,
            softwareID: softwareID,
            parameters: bigEndianBytes(controlID)
        )
    }

    public static func decodeCount(
        from response: HIDPP20LongMessage,
        featureIndex: UInt8
    ) throws -> UInt8 {
        try validate(response, featureIndex: featureIndex, functionID: 0)
        let count = response.parameters[0]
        guard (1...64).contains(count) else {
            throw HIDPP20CodecError.controlCountOutOfRange(count)
        }
        return count
    }

    public static func decodeControlInfo(
        index: UInt8,
        from response: HIDPP20LongMessage,
        featureIndex: UInt8
    ) throws -> ReprogControlInfo {
        try validate(response, featureIndex: featureIndex, functionID: 1)
        return ReprogControlInfo(
            index: index,
            controlID: uint16(response.parameters[0], response.parameters[1]),
            taskID: uint16(response.parameters[2], response.parameters[3]),
            capabilityFlags: response.parameters[4],
            position: response.parameters[5],
            group: response.parameters[6],
            groupMask: response.parameters[7],
            rawXYCapability: response.parameters[8] & 0x01 != 0,
            rawParameters: response.parameters
        )
    }

    public static func decodeReporting(
        requestedControlID: UInt16,
        from response: HIDPP20LongMessage,
        featureIndex: UInt8,
        featureVersion: UInt8
    ) throws -> ReprogControlReportingState {
        try validate(response, featureIndex: featureIndex, functionID: 2)
        let controlID = uint16(response.parameters[0], response.parameters[1])
        guard controlID == requestedControlID else {
            throw HIDPP20CodecError.responseControlMismatch(
                expected: requestedControlID,
                actual: controlID
            )
        }
        let extensionFlags = featureVersion >= 4 ? UInt16(response.parameters[5]) << 8 : 0
        let rawFlags = UInt16(response.parameters[2]) | extensionFlags
        let rawMappedControlID = uint16(response.parameters[3], response.parameters[4])
        return ReprogControlReportingState(
            controlID: controlID,
            rawFlags: rawFlags,
            rawMappedControlID: rawMappedControlID,
            rawParameters: response.parameters
        )
    }

    private static func request(
        featureIndex: UInt8,
        functionID: UInt8,
        deviceIndex: UInt8,
        softwareID: UInt8,
        parameters: [UInt8] = []
    ) throws -> HIDPP20LongMessage {
        try HIDPP20LongMessage(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: functionID,
            softwareID: softwareID,
            parameters: parameters
        )
    }

    private static func validate(
        _ response: HIDPP20LongMessage,
        featureIndex: UInt8,
        functionID: UInt8
    ) throws {
        guard response.featureIndex == featureIndex,
              response.functionID == functionID else {
            throw HIDPP20CodecError.unexpectedResponse
        }
    }

    private static func bigEndianBytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private static func uint16(_ high: UInt8, _ low: UInt8) -> UInt16 {
        UInt16(high) << 8 | UInt16(low)
    }
}

public struct ReprogControlInfo: Sendable, Equatable, Codable {
    public let index: UInt8
    public let controlID: UInt16
    public let taskID: UInt16
    public let capabilityFlags: UInt8
    public let position: UInt8
    public let group: UInt8
    public let groupMask: UInt8
    public let rawXYCapability: Bool
    public let rawParameters: [UInt8]

    public init(
        index: UInt8,
        controlID: UInt16,
        taskID: UInt16,
        capabilityFlags: UInt8,
        position: UInt8,
        group: UInt8,
        groupMask: UInt8,
        rawXYCapability: Bool,
        rawParameters: [UInt8] = Array(repeating: 0, count: HIDPP20LongMessage.parameterCount)
    ) {
        self.index = index
        self.controlID = controlID
        self.taskID = taskID
        self.capabilityFlags = capabilityFlags
        self.position = position
        self.group = group
        self.groupMask = groupMask
        self.rawXYCapability = rawXYCapability
        self.rawParameters = rawParameters
    }
}

public struct ReprogControlReportingState: Sendable, Equatable, Codable {
    public let controlID: UInt16
    /// Both REPROG_CONTROLS_V4 reporting flag bytes, retained losslessly.
    public let rawFlags: UInt16
    /// The mapped CID exactly as returned. Zero means firmware default/self.
    public let rawMappedControlID: UInt16
    public let rawParameters: [UInt8]

    public init(
        controlID: UInt16,
        rawFlags: UInt16,
        rawMappedControlID: UInt16,
        rawParameters: [UInt8] = Array(repeating: 0, count: HIDPP20LongMessage.parameterCount)
    ) {
        self.controlID = controlID
        self.rawFlags = rawFlags
        self.rawMappedControlID = rawMappedControlID
        self.rawParameters = rawParameters
    }

    public var effectiveMappedControlID: UInt16 {
        rawMappedControlID == 0 ? controlID : rawMappedControlID
    }

    public var isTemporarilyDiverted: Bool { rawFlags & 0x0001 != 0 }
    public var isPersistentlyDiverted: Bool { rawFlags & 0x0004 != 0 }
    public var isRawXYDiverted: Bool { rawFlags & 0x0010 != 0 }
}
