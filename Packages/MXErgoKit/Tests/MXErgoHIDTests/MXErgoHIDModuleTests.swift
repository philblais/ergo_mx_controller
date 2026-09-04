import MXErgoCore
import MXErgoHIDPP
import Testing
@testable import MXErgoHID

@Test func observerCanBeCreatedWithoutStartingHardwareAccess() {
    _ = MXErgoObserver()
}

@Test func wheelObserverCanBeCreatedWithoutStartingHardwareAccess() {
    let observer = MXErgoWheelObserver()
    observer.stop()
}

@Test func oneShotRootQueryIsTheSingleExpectedReadOnlyPacket() throws {
    let request = try MXErgoOneShotRootQuery.makeRequest()

    #expect(MXErgoOneShotRootQuery.featureID == 0x1B04)
    #expect(request.bytes == [
        0x11, 0x00, 0x00, 0x0E, 0x1B, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])
}

@Test func firmwareFingerprintDiscoveryStartsWithOneBoundedRootRequest() throws {
    let request = try MXErgoFirmwareFingerprintDiscovery.makeRootRequest()

    #expect(MXErgoFirmwareFingerprintDiscovery.featureID == 0x0003)
    #expect(MXErgoFirmwareFingerprintDiscovery.maximumPacketCount == 18)
    #expect(request.bytes == [
        0x11, 0x00, 0x00, 0x0E, 0x00, 0x03,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])
}

@Test func mappedControlPreflightIsFiveGetOnlyPackets() {
    #expect(MXErgoReadOnlyMappedControlPreflight.maximumPacketCount == 5)
    #expect(MXErgoReadOnlyMappedControlPreflight.timeout == 2)
}

@Test func precisionPreflightBuildsTheSingleExactReadOnlyRequest() throws {
    let expectation = try precisionPreflightExpectation()
    let request = try MXErgoReadOnlyPrecisionPreflight.makeRequest(
        expectation: expectation
    )

    #expect(MXErgoReadOnlyPrecisionPreflight.maximumPacketCount == 1)
    #expect(request.bytes == [
        0x11, 0x00, 0x0A, 0x2E, 0x00, 0xED,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])
}

@Test func isolatedHelperPrecisionProbeUsesADistinctReadOnlySoftwareID() throws {
    let menu = try precisionPreflightExpectation()
    let helper = try MXErgoPrecisionPreflightExpectation(
        device: menu.device,
        feature: menu.feature,
        baseline: menu.baseline,
        purpose: .isolatedHelperProbe
    )
    let request = try MXErgoReadOnlyPrecisionPreflight.makeRequest(
        expectation: helper
    )

    #expect(request.functionID == 2)
    #expect(request.softwareID == 0x0D)
    #expect(request.bytes[3] == 0x2D)
    #expect(Array(request.parameters.prefix(2)) == [0x00, 0xED])
    #expect(request.parameters.dropFirst(2).allSatisfy { $0 == 0 })
}

@Test func precisionPreflightDecodesAndPreservesTheExactBaselineBytes() throws {
    let expectation = try precisionPreflightExpectation()
    let response = try HIDPP20LongMessage(
        deviceIndex: 0,
        featureIndex: expectation.feature.index,
        functionID: 2,
        softwareID: 0x0E,
        parameters: expectation.baseline.rawParameters
    )

    #expect(try MXErgoReadOnlyPrecisionPreflight.decodeResponse(
        response,
        expectation: expectation
    ) == expectation.baseline)
}

@Test func precisionPreflightFailsClosedForDirtyBaselineAndPhysicalMismatch() throws {
    let clean = try precisionPreflightExpectation()
    var dirtyBytes = clean.baseline.rawParameters
    dirtyBytes[2] = 0x02
    #expect(throws: MXErgoPrecisionPreflightValidationError.invalidBaseline) {
        try MXErgoPrecisionPreflightExpectation(
            device: clean.device,
            feature: clean.feature,
            baseline: DeviceTransactionWireState(rawParameters: dirtyBytes)
        )
    }

    let exactProperties = precisionPreflightDeviceProperties()
    #expect(MXErgoReadOnlyPrecisionPreflight.matchesPhysicalDevice(
        exactProperties,
        expectation: clean
    ))
    let wrongLocation = HIDDeviceProperties(
        id: exactProperties.id,
        vendorID: exactProperties.vendorID,
        productID: exactProperties.productID,
        productName: exactProperties.productName,
        transport: exactProperties.transport,
        serialNumber: exactProperties.serialNumber,
        locationID: (exactProperties.locationID ?? 0) + 1,
        primaryUsagePage: exactProperties.primaryUsagePage,
        primaryUsage: exactProperties.primaryUsage
    )
    #expect(!MXErgoReadOnlyPrecisionPreflight.matchesPhysicalDevice(
        wrongLocation,
        expectation: clean
    ))
}

@Test func genericDesktopWheelValuesDecodeToNotches() {
    #expect(HIDElementValueDecoder.verticalScrollNotches(
        usagePage: 0x01,
        usage: 0x38,
        integerValue: 1
    ) == 1)
    #expect(HIDElementValueDecoder.verticalScrollNotches(
        usagePage: 0x01,
        usage: 0x38,
        integerValue: -2
    ) == -2)
}

@Test func unrelatedOrStationaryHIDValuesAreIgnored() {
    #expect(HIDElementValueDecoder.verticalScrollNotches(
        usagePage: 0x01,
        usage: 0x30,
        integerValue: 1
    ) == nil)
    #expect(HIDElementValueDecoder.verticalScrollNotches(
        usagePage: 0x01,
        usage: 0x38,
        integerValue: 0
    ) == nil)
}

private func precisionPreflightExpectation() throws
    -> MXErgoPrecisionPreflightExpectation {
    try MXErgoPrecisionPreflightExpectation(
        device: JournalDeviceIdentity(
            deviceID: "mx-ergo",
            vendorID: 0x046D,
            productID: 0xB01D,
            transport: "Bluetooth Low Energy",
            serialNumber: "7865BCA9046ED9FF",
            locationID: 1,
            firmwareIdentity: "firmware-bound"
        ),
        feature: HIDPP20FeatureDescriptor(
            index: 0x0A,
            type: 0,
            version: 3
        ),
        baseline: DeviceTransactionWireState(
            rawParameters: [
                0x00, 0xED, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            ]
        )
    )
}

private func precisionPreflightDeviceProperties() -> HIDDeviceProperties {
    HIDDeviceProperties(
        id: "mx-ergo",
        vendorID: 0x046D,
        productID: 0xB01D,
        productName: "MX Ergo",
        transport: "Bluetooth Low Energy",
        serialNumber: "7865BCA9046ED9FF",
        locationID: 1,
        primaryUsagePage: 1,
        primaryUsage: 2
    )
}
