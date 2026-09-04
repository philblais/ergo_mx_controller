import Foundation
import Testing

@Test(.enabled(if: preservedEvidenceIsAvailable, missingPreservedEvidence))
func preservedPrecisionEvidencePassesTheOfflineAudit() throws {
    let directory = try #require(preservedEvidenceDirectoryURL)

    let report = try PrecisionForensicEvidenceAudit.audit(
        locations: PrecisionForensicEvidenceLocations(directory: directory),
        profile: .preservedAugust2026
    )

    #expect(report.sourceTransactionID
        == PrecisionForensicEvidenceProfile.preservedAugust2026.sourceTransactionID)
    #expect(report.trialTransactionID
        == PrecisionForensicEvidenceProfile.preservedAugust2026.trialTransactionID)
    #expect(report.attemptID
        == PrecisionForensicEvidenceProfile.preservedAugust2026.attemptID)
    #expect(report.observation
        == [0x00, 0xED] + Array(repeating: 0, count: 14))
    #expect(report.probeCompletedAt < report.reconciliationCompletedAt)
}

@Test(.enabled(if: preservedEvidenceIsAvailable, missingPreservedEvidence))
func forensicAuditRejectsEveryCriticalFieldMutationEvenWhenItsFileHashIsRepinned() throws {
    let source = try #require(preservedEvidenceDirectoryURL)

    let mutations: [(String, (inout [String: Any]) -> Void)] = [
        ("probe-function", { json in
            mutateByteArray(&json, key: "precisionRequest", index: 3, to: 0x3D)
        }),
        ("probe-cid", { json in
            mutateByteArray(&json, key: "precisionResponse", index: 5, to: 0xEE)
        }),
        ("probe-feature-index", { json in
            mutateByteArray(&json, key: "precisionRequest", index: 2, to: 0x0B)
        }),
        ("probe-epoch", { json in
            json.removeValue(forKey: "connectionEpoch")
        }),
        ("probe-hash", { json in
            json["journalSHA256After"] = String(repeating: "0", count: 64)
        }),
        ("probe-timestamp", { json in
            json["completedAt"] = "2001-01-01T00:00:00Z"
        }),
    ]

    for (name, mutation) in mutations {
        let fixture = try copiedEvidenceFixture(source: source, name: name)
        let locations = PrecisionForensicEvidenceLocations(directory: fixture)
        try mutateJSON(at: locations.probeResult, mutation)
        let profile = repinnedProfile(
            .preservedAugust2026,
            probeResult: locations.probeResult
        )
        #expect(throws: PrecisionForensicEvidenceError.self) {
            _ = try PrecisionForensicEvidenceAudit.audit(
                locations: locations,
                profile: profile
            )
        }
    }

    try verifyTrialMutation(source: source, name: "trial-phase") { json in
        json["phase"] = "outcomeUnknown"
    }
    try verifyTrialMutation(source: source, name: "trial-revision") { json in
        json["revision"] = 4
    }
    try verifyTrialMutation(source: source, name: "trial-device") { json in
        var device = json["device"] as! [String: Any]
        device["firmwareIdentity"] = "tampered-firmware"
        json["device"] = device
    }
    try verifyTrialMutation(source: source, name: "trial-set-byte") { json in
        mutateByteArray(&json, key: "setRequestBytes", index: 3, to: 0x2E)
    }

    let reconciliationFixture = try copiedEvidenceFixture(
        source: source,
        name: "reconciliation-attempt"
    )
    let reconciliationLocations = PrecisionForensicEvidenceLocations(
        directory: reconciliationFixture
    )
    try mutateJSON(at: reconciliationLocations.reconciliationResult) { json in
        json["attemptID"] = UUID().uuidString
    }
    let reconciliationProfile = repinnedProfile(
        .preservedAugust2026,
        reconciliationResult: reconciliationLocations.reconciliationResult
    )
    #expect(throws: PrecisionForensicEvidenceError.self) {
        _ = try PrecisionForensicEvidenceAudit.audit(
            locations: reconciliationLocations,
            profile: reconciliationProfile
        )
    }
}

@Test(.enabled(if: preservedEvidenceIsAvailable, missingPreservedEvidence))
func forensicAuditRejectsSymlinkedEvidence() throws {
    let source = try #require(preservedEvidenceDirectoryURL)
    let fixture = try copiedEvidenceFixture(source: source, name: "symlink")
    let locations = PrecisionForensicEvidenceLocations(directory: fixture)
    let original = fixture.appendingPathComponent("live-original.json")
    try FileManager.default.moveItem(at: locations.liveJournal, to: original)
    try FileManager.default.createSymbolicLink(
        at: locations.liveJournal,
        withDestinationURL: original
    )

    #expect(throws: PrecisionForensicEvidenceError
        .missingOrNonRegularFile("device-state-journal.json")) {
        _ = try PrecisionForensicEvidenceAudit.audit(
            locations: locations,
            profile: .preservedAugust2026
        )
    }
}

private func verifyTrialMutation(
    source: URL,
    name: String,
    _ mutation: (inout [String: Any]) -> Void
) throws {
    let fixture = try copiedEvidenceFixture(source: source, name: name)
    let locations = PrecisionForensicEvidenceLocations(directory: fixture)
    try mutateJSON(at: locations.trialJournal, mutation)
    let profile = repinnedProfile(
        .preservedAugust2026,
        trialJournal: locations.trialJournal
    )
    #expect(throws: PrecisionForensicEvidenceError.self) {
        _ = try PrecisionForensicEvidenceAudit.audit(
            locations: locations,
            profile: profile
        )
    }
}

/// Resolves the directory the forensic audit runs against.
///
/// `MX_ERGO_FORENSIC_EVIDENCE_DIRECTORY` overrides everything, so the audit can
/// be pointed at the live Application Support directory. Otherwise it falls back
/// to the tracked `Evidence/2026-08-30` fixtures, which are byte-identical
/// copies of that directory taken while its hashes still matched this profile.
///
/// The fallback is what makes this audit real coverage on every machine. When
/// the only source was the environment variable, all three tests returned early
/// and reported as passing without verifying anything.
private let preservedEvidenceDirectoryURL: URL? = {
    if let path = ProcessInfo.processInfo.environment[
        "MX_ERGO_FORENSIC_EVIDENCE_DIRECTORY"
    ], !path.isEmpty {
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MXErgoPrecisionTransportTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // MXErgoKit
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repository root
    let tracked = repositoryRoot
        .appendingPathComponent("Evidence", isDirectory: true)
        .appendingPathComponent("2026-08-30", isDirectory: true)

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
        atPath: tracked.path,
        isDirectory: &isDirectory
    ), isDirectory.boolValue else {
        return nil
    }
    return tracked
}()

private let preservedEvidenceIsAvailable = preservedEvidenceDirectoryURL != nil

private let missingPreservedEvidence: Comment = """
No preserved evidence directory. Restore Evidence/2026-08-30 or set \
MX_ERGO_FORENSIC_EVIDENCE_DIRECTORY to the live Application Support directory.
"""

private func copiedEvidenceFixture(source: URL, name: String) throws -> URL {
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("precision-forensic-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: destination,
        withIntermediateDirectories: true
    )
    for file in [
        "device-state-journal.json",
        "device-state-journal.pre-firmware-identity.json",
        "restore-trial-probe-result.json",
        "restore-only-precision-trial.json",
        "restore-only-precision-reconciliation-result.json",
    ] {
        try FileManager.default.copyItem(
            at: source.appendingPathComponent(file),
            to: destination.appendingPathComponent(file)
        )
    }
    return destination
}

private func mutateJSON(
    at url: URL,
    _ mutation: (inout [String: Any]) -> Void
) throws {
    var json = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url))
            as? [String: Any]
    )
    mutation(&json)
    let data = try JSONSerialization.data(
        withJSONObject: json,
        options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: url)
}

private func mutateByteArray(
    _ json: inout [String: Any],
    key: String,
    index: Int,
    to value: UInt8
) {
    var bytes = json[key] as! [Int]
    bytes[index] = Int(value)
    json[key] = bytes
}

private func repinnedProfile(
    _ profile: PrecisionForensicEvidenceProfile,
    probeResult: URL? = nil,
    trialJournal: URL? = nil,
    reconciliationResult: URL? = nil
) -> PrecisionForensicEvidenceProfile {
    PrecisionForensicEvidenceProfile(
        liveJournalSHA256: profile.liveJournalSHA256,
        backupJournalSHA256: profile.backupJournalSHA256,
        probeResultSHA256: probeResult.map(fileHash)
            ?? profile.probeResultSHA256,
        reconciledTrialSHA256: trialJournal.map(fileHash)
            ?? profile.reconciledTrialSHA256,
        reconciliationResultSHA256: reconciliationResult.map(fileHash)
            ?? profile.reconciliationResultSHA256,
        preReconciliationTrialSHA256:
            profile.preReconciliationTrialSHA256,
        sourceTransactionID: profile.sourceTransactionID,
        trialTransactionID: profile.trialTransactionID,
        attemptID: profile.attemptID
    )
}

private func fileHash(_ url: URL) -> String {
    let data = try! Data(contentsOf: url)
    return PrecisionForensicEvidenceAudit.sha256(data)
}
