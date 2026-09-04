import Foundation

public struct HIDReportFieldDescriptor: Sendable, Equatable {
    public let reportID: UInt32
    public let reportSizeBits: Int
    public let reportCount: Int

    public init(reportID: UInt32, reportSizeBits: Int, reportCount: Int) {
        self.reportID = reportID
        self.reportSizeBits = reportSizeBits
        self.reportCount = reportCount
    }
}

public struct HIDOutputReportCapability: Sendable, Equatable, Identifiable {
    public let reportID: UInt32
    /// Descriptor payload bytes, excluding a non-zero report-ID prefix.
    public let payloadByteCount: Int

    public init(reportID: UInt32, payloadByteCount: Int) {
        self.reportID = reportID
        self.payloadByteCount = payloadByteCount
    }

    public var id: UInt32 { reportID }

    public var wireByteCount: Int {
        payloadByteCount + (reportID == 0 ? 0 : 1)
    }

    public var isHIDPP20LongReport: Bool {
        reportID == 0x11 && wireByteCount == 20
    }
}

public enum HIDOutputReportCapabilityAggregator {
    public static func aggregate(
        _ fields: [HIDReportFieldDescriptor]
    ) -> [HIDOutputReportCapability] {
        var bitsByReportID: [UInt32: Int] = [:]

        for field in fields {
            guard field.reportSizeBits > 0, field.reportCount > 0 else { continue }
            let (fieldBits, overflowed) = field.reportSizeBits.multipliedReportingOverflow(
                by: field.reportCount
            )
            guard !overflowed else { continue }
            let (totalBits, additionOverflowed) = bitsByReportID[
                field.reportID,
                default: 0
            ].addingReportingOverflow(fieldBits)
            guard !additionOverflowed else { continue }
            bitsByReportID[field.reportID] = totalBits
        }

        return bitsByReportID
            .map { reportID, bits in
                HIDOutputReportCapability(
                    reportID: reportID,
                    payloadByteCount: (bits + 7) / 8
                )
            }
            .sorted { $0.reportID < $1.reportID }
    }
}

/// Resolves the descriptor's authoritative maximum output size only when it
/// can be assigned unambiguously to one output report ID.
///
/// IOHID may expand one HID array field into several matching elements. Their
/// individual report counts must not be summed; `MaxOutputReportSize` is the
/// descriptor-derived wire size macOS itself uses.
public enum HIDOutputReportCapabilityResolver {
    public static func resolveSingleReport(
        reportIDs: [UInt32],
        maxOutputReportByteCount: Int?
    ) -> [HIDOutputReportCapability] {
        let uniqueReportIDs = Set(reportIDs)
        guard uniqueReportIDs.count == 1,
              let reportID = uniqueReportIDs.first,
              let maxOutputReportByteCount,
              maxOutputReportByteCount > (reportID == 0 ? 0 : 1) else {
            return []
        }

        return [HIDOutputReportCapability(
            reportID: reportID,
            payloadByteCount: maxOutputReportByteCount - (reportID == 0 ? 0 : 1)
        )]
    }
}
