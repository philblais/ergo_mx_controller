import Foundation
@preconcurrency import IOKit.hid
import MXErgoCore

public enum HIDDevicePropertyDecoder {
    public static func decode(_ device: IOHIDDevice) -> HIDDeviceProperties {
        let vendorID = integerProperty(kIOHIDVendorIDKey, from: device)
        let productID = integerProperty(kIOHIDProductIDKey, from: device)
        let locationID = integerProperty(kIOHIDLocationIDKey, from: device)
        let usagePage = integerProperty(kIOHIDPrimaryUsagePageKey, from: device)
        let usage = integerProperty(kIOHIDPrimaryUsageKey, from: device)
        let productName = stringProperty(kIOHIDProductKey, from: device)
        let transport = stringProperty(kIOHIDTransportKey, from: device)
        let serialNumber = stringProperty(kIOHIDSerialNumberKey, from: device)

        let vendorComponent = vendorID.map { String($0) } ?? "unknown-vendor"
        let productComponent = productID.map { String($0) } ?? "unknown-product"
        let locationComponent = locationID.map { String($0) } ?? "unknown-location"
        let usagePageComponent = usagePage.map { String($0) } ?? "unknown-page"
        let usageComponent = usage.map { String($0) } ?? "unknown-usage"
        let identifierParts: [String] = [
            vendorComponent,
            productComponent,
            locationComponent,
            usagePageComponent,
            usageComponent,
        ]

        return HIDDeviceProperties(
            id: identifierParts.joined(separator: "-"),
            vendorID: vendorID,
            productID: productID,
            productName: productName,
            transport: transport,
            serialNumber: serialNumber,
            locationID: locationID,
            primaryUsagePage: usagePage,
            primaryUsage: usage
        )
    }

    private static func integerProperty(_ key: String, from device: IOHIDDevice) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private static func stringProperty(_ key: String, from device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
