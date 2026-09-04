import Foundation
@preconcurrency import IOKit.hid
import MXErgoCore

enum HIDReportCapabilityInspector {
    static func outputCapabilities(
        for device: IOHIDDevice
    ) -> [HIDOutputReportCapability] {
        guard let elements = IOHIDDeviceCopyMatchingElements(
            device,
            nil,
            IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else {
            return []
        }

        let outputReportIDs = elements.compactMap { element -> UInt32? in
            guard IOHIDElementGetType(element) == kIOHIDElementTypeOutput else { return nil }
            return IOHIDElementGetReportID(element)
        }
        let maxOutputReportByteCount = (
            IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString)
                as? NSNumber
        )?.intValue

        return HIDOutputReportCapabilityResolver.resolveSingleReport(
            reportIDs: outputReportIDs,
            maxOutputReportByteCount: maxOutputReportByteCount
        )
    }
}
