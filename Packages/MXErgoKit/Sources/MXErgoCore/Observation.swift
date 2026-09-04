import Foundation

public enum ObserverStatus: Sendable, Equatable {
    case stopped
    case starting
    case observing
    case failed(code: Int32)
}

public struct HIDReportSnapshot: Sendable, Equatable {
    public let count: UInt64
    public let reportID: UInt32
    public let length: Int
    public let preview: [UInt8]

    public init(count: UInt64, reportID: UInt32, length: Int, preview: [UInt8]) {
        self.count = count
        self.reportID = reportID
        self.length = length
        self.preview = preview
    }

    public var isLogitechVendorReport: Bool {
        reportID == 0x11
    }

    /// The button byte in the ordinary report used by this MX Ergo BLE interface.
    /// IOHID includes the report ID as byte zero in the callback buffer.
    public var standardMouseButtonMask: UInt8? {
        guard reportID == 0x02, preview.count >= 2, preview[0] == 0x02 else {
            return nil
        }
        return preview[1]
    }
}

public enum MXErgoObservation: Sendable, Equatable {
    case status(ObserverStatus)
    case connected(HIDDeviceProperties)
    case disconnected(deviceID: String)
    case outputReportCapabilities(deviceID: String, capabilities: [HIDOutputReportCapability])
    case report(HIDReportSnapshot)
    case verticalScroll(notches: Int)
    /// Wheel tilt, positive to the right. Observation only: the app does
    /// not suppress or replace the horizontal scroll macOS already
    /// delivers.
    case horizontalScroll(notches: Int)
}
