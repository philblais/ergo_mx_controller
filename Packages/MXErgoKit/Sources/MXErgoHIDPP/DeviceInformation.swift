import Foundation

/// Read-only HID++ 2.0 Device Information feature (0x0003).
///
/// Only functions 0 (GetDeviceInfo) and 1 (GetFwInfo) are represented here.
/// This type has no SET function and performs no I/O by itself.
public enum HIDPP20DeviceInformation {
    public static let featureID: UInt16 = 0x0003
    public static let maximumEntityCount: UInt8 = 16

    public static func getDeviceInfoRequest(
        featureIndex: UInt8,
        deviceIndex: UInt8,
        softwareID: UInt8
    ) throws -> HIDPP20LongMessage {
        try HIDPP20LongMessage(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: 0,
            softwareID: softwareID
        )
    }

    public static func getFirmwareInfoRequest(
        entityIndex: UInt8,
        featureIndex: UInt8,
        deviceIndex: UInt8,
        softwareID: UInt8
    ) throws -> HIDPP20LongMessage {
        guard entityIndex < maximumEntityCount else {
            throw HIDPP20CodecError.firmwareEntityIndexOutOfRange(entityIndex)
        }
        return try HIDPP20LongMessage(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: 1,
            softwareID: softwareID,
            parameters: [entityIndex]
        )
    }

    public static func decodeDeviceInfo(
        from response: HIDPP20LongMessage,
        featureIndex: UInt8
    ) throws -> HIDPP20DeviceInfo {
        guard response.featureIndex == featureIndex,
              response.functionID == 0 else {
            throw HIDPP20CodecError.unexpectedResponse
        }
        let count = response.parameters[0]
        guard count > 0, count <= maximumEntityCount else {
            throw HIDPP20CodecError.firmwareEntityCountOutOfRange(count)
        }
        return HIDPP20DeviceInfo(
            entityCount: count,
            unitID: Array(response.parameters[1...4]),
            transportFlags: response.parameters[6],
            modelIDs: [
                uint16(response.parameters[7], response.parameters[8]),
                uint16(response.parameters[9], response.parameters[10]),
                uint16(response.parameters[11], response.parameters[12]),
            ],
            extendedModelID: response.parameters[13],
            capabilities: response.parameters[14],
            rawParameters: response.parameters
        )
    }

    public static func decodeFirmwareInfo(
        entityIndex: UInt8,
        from response: HIDPP20LongMessage,
        featureIndex: UInt8
    ) throws -> HIDPP20FirmwareEntity {
        guard entityIndex < maximumEntityCount else {
            throw HIDPP20CodecError.firmwareEntityIndexOutOfRange(entityIndex)
        }
        guard response.featureIndex == featureIndex,
              response.functionID == 1 else {
            throw HIDPP20CodecError.unexpectedResponse
        }

        // Main/bootloader versions normally use packed BCD. Real MX Ergo
        // SoftDevice entities can expose opaque values such as build 0x005A,
        // so invalid BCD must remain readable raw data rather than rejecting
        // the complete fingerprint.
        let number = decodePackedBCDIfValid([response.parameters[4]])
        let revision = decodePackedBCDIfValid([response.parameters[5]])
        let build = decodePackedBCDIfValid(Array(response.parameters[6...7]))
        return HIDPP20FirmwareEntity(
            index: entityIndex,
            rawType: response.parameters[0],
            prefixBytes: Array(response.parameters[1...3]),
            number: number,
            revision: revision,
            build: build,
            isActive: response.parameters[8] & 0x01 != 0,
            transportPID: uint16(response.parameters[9], response.parameters[10]),
            extraVersion: Array(response.parameters[11...15]),
            rawParameters: response.parameters
        )
    }

    private static func uint16(_ high: UInt8, _ low: UInt8) -> UInt16 {
        UInt16(high) << 8 | UInt16(low)
    }

    private static func decodePackedBCDIfValid(_ bytes: [UInt8]) -> Int? {
        var value = 0
        for byte in bytes {
            let high = Int(byte >> 4)
            let low = Int(byte & 0x0F)
            guard high <= 9, low <= 9 else { return nil }
            value = value * 100 + high * 10 + low
        }
        return value
    }
}

public struct HIDPP20DeviceInfo: Sendable, Equatable, Codable {
    public let entityCount: UInt8
    public let unitID: [UInt8]
    public let transportFlags: UInt8
    public let modelIDs: [UInt16]
    public let extendedModelID: UInt8
    public let capabilities: UInt8
    public let rawParameters: [UInt8]

    public var supportsSerialNumber: Bool { capabilities & 0x01 != 0 }
}

public enum HIDPP20FirmwareEntityType: UInt8, Sendable, Codable {
    case mainApplication = 0
    case bootloader = 1
    case hardware = 2
    case touchpad = 3
    case opticalSensor = 4
    case softDevice = 5
    case radioCompanionMCU = 6
    case factoryApplication = 7
    case rgbCustomEffect = 8
    case motorDrive = 9
}

public struct HIDPP20FirmwareEntity: Sendable, Equatable, Codable {
    public let index: UInt8
    public let rawType: UInt8
    public let prefixBytes: [UInt8]
    public let number: Int?
    public let revision: Int?
    public let build: Int?
    public let isActive: Bool
    public let transportPID: UInt16
    public let extraVersion: [UInt8]
    public let rawParameters: [UInt8]

    public var type: HIDPP20FirmwareEntityType? {
        HIDPP20FirmwareEntityType(rawValue: rawType)
    }

    public var prefix: String {
        let scalars = prefixBytes.map { byte -> UnicodeScalar in
            guard byte >= 0x20, byte <= 0x7E else { return "?" }
            return UnicodeScalar(byte)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    public var versionDescription: String {
        if let number, let revision, let build {
            return String(format: "%@ %02d.%02d.B%04d", prefix, number, revision, build)
        }
        return String(
            format: "%@ raw %02X.%02X.%02X%02X",
            prefix,
            rawParameters[4],
            rawParameters[5],
            rawParameters[6],
            rawParameters[7]
        )
    }
}

/// Canonical, exact firmware identity derived only from static 0x0003 fields.
/// Active-state and transport-PID bytes are intentionally excluded because
/// they describe the current boot/transport state rather than firmware identity.
public struct HIDPP20FirmwareFingerprint: Sendable, Equatable, Codable {
    public let featureVersion: UInt8
    public let deviceInfo: HIDPP20DeviceInfo
    public let entities: [HIDPP20FirmwareEntity]

    public init(
        featureVersion: UInt8,
        deviceInfo: HIDPP20DeviceInfo,
        entities: [HIDPP20FirmwareEntity]
    ) throws {
        let ordered = entities.sorted { $0.index < $1.index }
        guard ordered.count == Int(deviceInfo.entityCount),
              ordered.enumerated().allSatisfy({ $0.offset == Int($0.element.index) }) else {
            throw HIDPP20CodecError.unexpectedResponse
        }
        self.featureVersion = featureVersion
        self.deviceInfo = deviceInfo
        self.entities = ordered
    }

    /// Suitable for exact equality binding in the recovery journal after a
    /// separate real-hardware stability validation and explicit migration.
    public var canonicalIdentity: String {
        let modelBytes = deviceInfo.modelIDs.flatMap {
            [UInt8($0 >> 8), UInt8($0 & 0xFF)]
        }
        let header = [
            "hidpp0003-v\(featureVersion)",
            "unit=\(Self.hex(deviceInfo.unitID))",
            "model=\(Self.hex(modelBytes))",
            String(format: "ext=%02X", deviceInfo.extendedModelID),
        ]
        let firmware = entities.map { entity in
            let stableBytes = [entity.rawType]
                + entity.prefixBytes
                + Array(entity.rawParameters[4...7])
                + entity.extraVersion
            return "e\(entity.index)=\(Self.hex(stableBytes))"
        }
        return (header + firmware).joined(separator: "|")
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}
