import Foundation

public enum MXErgoControl: UInt16, Sendable, Equatable, CaseIterable {
    case wheelClick = 0x0052
    case lowerThumb = 0x0053
    case upperThumb = 0x0056
    case wheelTiltLeft = 0x005B
    case wheelTiltRight = 0x005D
    case precision = 0x00ED

    public var name: String {
        switch self {
        case .wheelClick: "Wheel click"
        case .lowerThumb: "Lower thumb"
        case .upperThumb: "Upper thumb"
        case .wheelTiltLeft: "Wheel tilt left"
        case .wheelTiltRight: "Wheel tilt right"
        case .precision: "Precision"
        }
    }
}

public enum StandardMouseButton: UInt8, Sendable, Equatable {
    case primary = 0x01
    case secondary = 0x02
    case wheel = 0x04

    public var name: String {
        switch self {
        case .primary: "Primary click"
        case .secondary: "Secondary click"
        case .wheel: "Wheel click"
        }
    }
}

public enum LogitechControlEvent: Sendable, Equatable {
    case pressed(controlID: UInt16)
    case released

    public var control: MXErgoControl? {
        guard case let .pressed(controlID) = self else { return nil }
        return MXErgoControl(rawValue: controlID)
    }
}

public enum LogitechControlEventDecoder {
    /// Decodes HID++ reprogrammable-control notifications observed from this MX Ergo.
    /// Responses addressed to the host use a different header and are deliberately ignored.
    public static func decode(_ report: HIDReportSnapshot) -> LogitechControlEvent? {
        decodeNotification(
            report.preview,
            featureIndex: 0x0A,
            reportID: report.reportID
        )
    }

    public static func decodeNotification(
        _ bytes: [UInt8],
        featureIndex: UInt8,
        reportID: UInt32? = nil
    ) -> LogitechControlEvent? {
        if let reportID {
            guard reportID == 0x11 else { return nil }
        }
        guard bytes.count >= 6,
              bytes[0] == 0x11,
              bytes[1] == 0xFF,
              bytes[2] == featureIndex,
              bytes[3] == 0x00 else {
            return nil
        }

        let controlID = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        return controlID == 0 ? .released : .pressed(controlID: controlID)
    }
}
