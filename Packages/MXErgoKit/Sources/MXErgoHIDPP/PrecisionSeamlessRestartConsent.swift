import Foundation

/// Persistable preference, separate from both journals. This is review input,
/// never an executable capability. Admission still needs a fresh, one-use
/// authorization and independent verification from the acquired endpoint.
package struct PrecisionSeamlessRestartConsent: Codable, Sendable, Equatable {
    package let version: Int
    package let enabled: Bool
    package let device: JournalDeviceIdentity
    package let sourceBaselineTransactionID: UUID
    package let sourceBaselineSHA256: String

    package init(
        enabled: Bool = false,
        readiness: PrecisionTemporaryDiversionReadinessSnapshot
    ) {
        version = 1
        self.enabled = enabled
        device = readiness.plan.device
        sourceBaselineTransactionID = readiness.sourceBaselineTransactionID
        sourceBaselineSHA256 = readiness.sourceJournalSHA256
    }

    package func matches(
        _ readiness: PrecisionTemporaryDiversionReadinessSnapshot
    ) -> Bool {
        version == 1
            && device.hasStableDiscriminator
            && device.firmwareIdentity?.isEmpty == false
            && device == readiness.plan.device
            && sourceBaselineTransactionID == readiness.sourceBaselineTransactionID
            && sourceBaselineSHA256 == readiness.sourceJournalSHA256
            && sourceBaselineSHA256.utf8.count == 64
            && sourceBaselineSHA256.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}

