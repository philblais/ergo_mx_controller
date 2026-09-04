import Foundation

public struct DeviceIdentity: Sendable, Equatable {
    public let vendorID: Int
    public let productID: Int

    public init(vendorID: Int, productID: Int) {
        self.vendorID = vendorID
        self.productID = productID
    }

    public static let mxErgo = DeviceIdentity(vendorID: 0x046D, productID: 0xB01D)

    public func matches(vendorID: Int?, productID: Int?) -> Bool {
        vendorID == self.vendorID && productID == self.productID
    }
}

public struct HIDDeviceProperties: Sendable, Equatable, Identifiable {
    public let id: String
    public let vendorID: Int?
    public let productID: Int?
    public let productName: String?
    public let transport: String?
    public let serialNumber: String?
    public let locationID: Int?
    public let primaryUsagePage: Int?
    public let primaryUsage: Int?

    public init(
        id: String,
        vendorID: Int?,
        productID: Int?,
        productName: String?,
        transport: String?,
        serialNumber: String?,
        locationID: Int?,
        primaryUsagePage: Int?,
        primaryUsage: Int?
    ) {
        self.id = id
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.transport = transport
        self.serialNumber = serialNumber
        self.locationID = locationID
        self.primaryUsagePage = primaryUsagePage
        self.primaryUsage = primaryUsage
    }

    public var isMXErgo: Bool {
        DeviceIdentity.mxErgo.matches(vendorID: vendorID, productID: productID)
    }

    public var isBluetooth: Bool {
        transport?.localizedCaseInsensitiveContains("bluetooth") == true
    }
}

