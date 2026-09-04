import Testing
@testable import MXErgoCore

@Test func outputReportFieldsAggregateByReportID() {
    let capabilities = HIDOutputReportCapabilityAggregator.aggregate([
        HIDReportFieldDescriptor(reportID: 0x11, reportSizeBits: 8, reportCount: 16),
        HIDReportFieldDescriptor(reportID: 0x11, reportSizeBits: 8, reportCount: 3),
        HIDReportFieldDescriptor(reportID: 0x10, reportSizeBits: 8, reportCount: 6),
        HIDReportFieldDescriptor(reportID: 0x12, reportSizeBits: 0, reportCount: 64),
    ])

    #expect(capabilities == [
        HIDOutputReportCapability(reportID: 0x10, payloadByteCount: 6),
        HIDOutputReportCapability(reportID: 0x11, payloadByteCount: 19),
    ])
    #expect(capabilities[1].wireByteCount == 20)
    #expect(capabilities[1].isHIDPP20LongReport)
}

@Test func authoritativeMaximumSizeResolvesRepeatedElementsForOneReport() {
    let capabilities = HIDOutputReportCapabilityResolver.resolveSingleReport(
        reportIDs: [0x11, 0x11, 0x11],
        maxOutputReportByteCount: 20
    )

    #expect(capabilities == [
        HIDOutputReportCapability(reportID: 0x11, payloadByteCount: 19),
    ])
    #expect(capabilities.first?.isHIDPP20LongReport == true)
}

@Test func authoritativeMaximumSizeFailsClosedForMultipleReportIDs() {
    #expect(HIDOutputReportCapabilityResolver.resolveSingleReport(
        reportIDs: [0x10, 0x11],
        maxOutputReportByteCount: 20
    ).isEmpty)
    #expect(HIDOutputReportCapabilityResolver.resolveSingleReport(
        reportIDs: [0x11],
        maxOutputReportByteCount: nil
    ).isEmpty)
}
