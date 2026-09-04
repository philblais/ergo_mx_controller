import Testing
@testable import MXErgoCore

@Test func mxErgoIdentityMatchesOnlyTheExpectedDevice() {
    let identity = DeviceIdentity.mxErgo

    #expect(identity.matches(vendorID: 0x046D, productID: 0xB01D))
    #expect(!identity.matches(vendorID: 0x046D, productID: 0xB01E))
    #expect(!identity.matches(vendorID: nil, productID: 0xB01D))
}

@Test func transportRecognitionAcceptsBluetoothLowEnergy() {
    let properties = HIDDeviceProperties(
        id: "device",
        vendorID: 0x046D,
        productID: 0xB01D,
        productName: "MX Ergo",
        transport: "Bluetooth Low Energy",
        serialNumber: nil,
        locationID: nil,
        primaryUsagePage: 1,
        primaryUsage: 2
    )

    #expect(properties.isMXErgo)
    #expect(properties.isBluetooth)
}

@Test func reportElevenIsRecognizedAsALogitechVendorReport() {
    let vendorReport = HIDReportSnapshot(count: 1, reportID: 0x11, length: 20, preview: [])
    let pointerReport = HIDReportSnapshot(count: 2, reportID: 0x02, length: 7, preview: [])

    #expect(vendorReport.isLogitechVendorReport)
    #expect(!pointerReport.isLogitechVendorReport)
}

@Test func standardMouseButtonMaskIsExtractedFromReportTwo() {
    let pressed = HIDReportSnapshot(
        count: 1,
        reportID: 0x02,
        length: 8,
        preview: [0x02, 0x01, 0, 0, 0x10, 0, 0, 0]
    )
    let unrelated = HIDReportSnapshot(
        count: 2,
        reportID: 0x11,
        length: 20,
        preview: [0x11, 0xFF, 0x0A, 0, 0, 0]
    )

    #expect(pressed.standardMouseButtonMask == 0x01)
    #expect(unrelated.standardMouseButtonMask == nil)
}

@Test func calibratedLogitechNotificationsDecodeToNamedControls() {
    let upperThumb = HIDReportSnapshot(
        count: 1,
        reportID: 0x11,
        length: 20,
        preview: [0x11, 0xFF, 0x0A, 0x00, 0x00, 0x56, 0, 0]
    )
    let release = HIDReportSnapshot(
        count: 2,
        reportID: 0x11,
        length: 20,
        preview: [0x11, 0xFF, 0x0A, 0x00, 0x00, 0x00, 0, 0]
    )

    let pressEvent = LogitechControlEventDecoder.decode(upperThumb)
    #expect(pressEvent == .pressed(controlID: 0x0056))
    #expect(pressEvent?.control == .upperThumb)
    #expect(LogitechControlEventDecoder.decode(release) == .released)
}

@Test func hostAddressedLogitechResponsesAreNotDecodedAsControlEvents() {
    let response = HIDReportSnapshot(
        count: 1,
        reportID: 0x11,
        length: 20,
        preview: [0x11, 0x00, 0x0A, 0x2A, 0x00, 0x5B, 0x01, 0x00]
    )

    #expect(LogitechControlEventDecoder.decode(response) == nil)
}
