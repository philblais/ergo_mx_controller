import Foundation
import CryptoKit
import MXErgoHIDPP

/// A separate preference file. Neither recovery baseline nor runtime history is edited.
public struct PrecisionAutomaticRestartPreference: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public var isEnabled: Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let consent = try? JSONDecoder().decode(PrecisionSeamlessRestartConsent.self, from: data) else { return false }
        return consent.version == 1 && consent.enabled
    }

    /// Called only for the user's visible opt-in. Fresh device checks still
    /// precede any automatic execution, even when this baseline was saved earlier.
    public func enable(sourceBaselineURL: URL) throws {
        let data = try Data(contentsOf: sourceBaselineURL)
        let baseline = try JSONDecoder().decode(DeviceStateJournal.self, from: data)
        try baseline.validateForRecovery()
        guard !baseline.requiresRecovery, baseline.device.hasStableDiscriminator, baseline.device.firmwareIdentity?.isEmpty == false else {
            throw PrecisionAutomaticRunError.invalidConsent
        }
        let consent = PrecisionSeamlessRestartConsent(device: baseline.device,
            sourceBaselineTransactionID: baseline.transactionID, sourceBaselineSHA256: digest(data))
        let encoded = try JSONEncoder().encode(consent)
        try encoded.write(to: fileURL, options: .atomic)
        guard try Data(contentsOf: fileURL) == encoded else { throw PrecisionAutomaticRunError.invalidConsent }
    }

    public func disable() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
    }

    public func beginRun() throws -> PrecisionAutomaticRestartRun {
        let data = try Data(contentsOf: fileURL)
        let consent = try JSONDecoder().decode(PrecisionSeamlessRestartConsent.self, from: data)
        guard consent.version == 1, consent.enabled else { throw PrecisionAutomaticRunError.invalidConsent }
        let url = fileURL
        return PrecisionAutomaticRestartRun(permit: PrecisionAutomaticRunPermit(consent: consent,
            consentIsCurrent: { (try? Data(contentsOf: url)) == data }))
    }
}

public final class PrecisionAutomaticRestartRun: Sendable {
    package let permit: PrecisionAutomaticRunPermit
    package init(permit: PrecisionAutomaticRunPermit) { self.permit = permit }
    public func validate() throws { try permit.validate() }
    @discardableResult public func revoke() -> Bool { permit.revoke() }

    /// CAS retirement of an already completed, matching transaction only.
    /// No live-state inference, HID command, or ambiguity reconciliation.
    @discardableResult public func archiveCompletedRuntimeIfPresent(
        runtimeJournalURL: URL, sourceBaselineURL: URL
    ) throws -> Bool {
        try validate()
        let baseline = try Data(contentsOf: sourceBaselineURL)
        let journal = try JSONDecoder().decode(DeviceStateJournal.self, from: baseline)
        try journal.validateForRecovery()
        guard !journal.requiresRecovery,
              journal.device == permit.consent.device,
              journal.transactionID == permit.consent.sourceBaselineTransactionID,
              digest(baseline) == permit.consent.sourceBaselineSHA256 else { throw PrecisionAutomaticRunError.invalidConsent }
        guard FileManager.default.fileExists(atPath: runtimeJournalURL.path) else { return false }
        let data = try Data(contentsOf: runtimeJournalURL)
        let envelope = try JSONDecoder().decode(DeviceTransactionEnvelope.self, from: data)
        try envelope.validate()
        guard envelope.device == permit.consent.device,
              envelope.sourceBaselineTransactionID == permit.consent.sourceBaselineTransactionID else {
            throw PrecisionAutomaticRunError.invalidConsent
        }
        guard envelope.status == .completed else { return false }
        guard let review = try PrecisionRuntimeJournalRotator.review(runtimeJournalURL: runtimeJournalURL),
              review.sha256 == digest(data) else { throw PrecisionAutomaticRunError.invalidConsent }
        try validate()
        _ = try PrecisionRuntimeJournalRotator.rotate(review)
        return true
    }
}

/// Opaque one-use authority for a single post-wake GET-only resume. It cannot
/// be used by the activation path and contains no physical mutation claim.
public final class PrecisionWakeReconnectRun: Sendable {
    package let permit: PrecisionWakeResumePermit

    package init(permit: PrecisionWakeResumePermit) {
        self.permit = permit
    }

    public var sleepCycleID: UUID { permit.sleepCycleID }
    public func validate() throws { try permit.validate() }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
