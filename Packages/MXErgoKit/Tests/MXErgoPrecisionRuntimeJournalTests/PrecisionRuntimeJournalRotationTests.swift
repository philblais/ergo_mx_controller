import Foundation
import MXErgoHIDPP
import Testing
@testable import MXErgoPrecisionRuntimeJournal

// Rotation retires a spent runtime journal so a second lifecycle can begin.
// The danger it must never create is discarding a journal whose evidence a
// later recover depends on, so every non-terminal state is refused and the
// file is renamed rather than deleted.

@Test func rotationArchivesASpentJournalAndProvesTheMove() throws {
    let fixture = try rotationFixture(.spent)
    defer { fixture.cleanup() }

    let reviewed = try PrecisionRuntimeJournalRotation.review(
        runtimeJournalURL: fixture.journalURL
    )
    let review = try #require(reviewed)
    #expect(review.status == .completed)
    #expect(review.precisionPhase == .restoredVerified)
    #expect(review.sha256 == fixture.sha256)

    // Reviewing alone must not move anything.
    #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))

    let lease = try MXErgoDeviceOperationLease.acquire(beside: fixture.journalURL)
    defer { withExtendedLifetime(lease) {} }
    let receipt = try PrecisionRuntimeJournalRotation.rotate(
        review,
        operationLease: lease
    )

    #expect(receipt.archivedTransactionID == review.transactionID)
    #expect(receipt.archivedSHA256 == fixture.sha256)
    #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
    #expect(FileManager.default.fileExists(atPath: receipt.archiveURL.path))

    // The archive is the original bytes, not a re-encoding of them.
    let archived = try Data(contentsOf: receipt.archiveURL)
    #expect(archived == fixture.data)
    #expect(receipt.archiveURL.lastPathComponent.contains(
        review.transactionID.uuidString
    ))
}

@Test func rotationRefusesEveryJournalWhoseEvidenceCouldStillMatter() throws {
    // Each of these is a state a later recover may need to read.
    for state in [
        RotationFixtureState.running,
        .ambiguousApply,
        .ambiguousRestore,
        .conflicted,
        .prepared,
    ] {
        let fixture = try rotationFixture(state)
        defer { fixture.cleanup() }

        do {
            _ = try PrecisionRuntimeJournalRotation.review(
                runtimeJournalURL: fixture.journalURL
            )
            Issue.record("Expected \(state) to be refused")
        } catch let error as PrecisionRuntimeJournalError {
            #expect(error == .runtimeJournalNotRotatable)
        }

        // A refusal must leave the journal byte-identical.
        let after = try Data(contentsOf: fixture.journalURL)
        #expect(after == fixture.data)
    }
}

@Test func rotationRefusesAForeignLease() throws {
    let fixture = try rotationFixture(.spent)
    defer { fixture.cleanup() }
    let other = try rotationFixture(.spent)
    defer { other.cleanup() }

    let reviewed = try PrecisionRuntimeJournalRotation.review(
        runtimeJournalURL: fixture.journalURL
    )
    let review = try #require(reviewed)
    let foreignLease = try MXErgoDeviceOperationLease.acquire(
        beside: other.journalURL
    )
    defer { withExtendedLifetime(foreignLease) {} }

    #expect(throws: PrecisionRuntimeJournalError.operationLeaseMismatch) {
        _ = try PrecisionRuntimeJournalRotation.rotate(
            review,
            operationLease: foreignLease
        )
    }
    let unchanged = try Data(contentsOf: fixture.journalURL)
    #expect(unchanged == fixture.data)
}

@Test func rotationRefusesAJournalThatChangedAfterReview() throws {
    let fixture = try rotationFixture(.spent)
    defer { fixture.cleanup() }

    let reviewed = try PrecisionRuntimeJournalRotation.review(
        runtimeJournalURL: fixture.journalURL
    )
    let review = try #require(reviewed)

    // Still rotatable, but no longer the reviewed bytes.
    try mutateRuntimeJournal(at: fixture.journalURL) { object in
        object["revision"] = (object["revision"] as! Int) + 1
    }

    let lease = try MXErgoDeviceOperationLease.acquire(beside: fixture.journalURL)
    defer { withExtendedLifetime(lease) {} }
    #expect(throws: PrecisionRuntimeJournalError.rotationSourceChanged) {
        _ = try PrecisionRuntimeJournalRotation.rotate(
            review,
            operationLease: lease
        )
    }
    #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))
}

@Test func rotationRefusesToOverwriteAnExistingArchive() throws {
    let fixture = try rotationFixture(.spent)
    defer { fixture.cleanup() }

    let reviewed = try PrecisionRuntimeJournalRotation.review(
        runtimeJournalURL: fixture.journalURL
    )
    let review = try #require(reviewed)
    try Data("previous archive".utf8).write(to: review.archiveURL, options: .atomic)

    let lease = try MXErgoDeviceOperationLease.acquire(beside: fixture.journalURL)
    defer { withExtendedLifetime(lease) {} }
    #expect(throws: PrecisionRuntimeJournalError.rotationArchiveAlreadyExists) {
        _ = try PrecisionRuntimeJournalRotation.rotate(
            review,
            operationLease: lease
        )
    }
    let unchanged = try Data(contentsOf: fixture.journalURL)
    #expect(unchanged == fixture.data)
    let archive = try Data(contentsOf: review.archiveURL)
    #expect(archive == Data("previous archive".utf8))
}

@Test func reviewReturnsNilWhenThereIsNoJournalToRotate() throws {
    let fixture = try rotationFixture(.spent)
    defer { fixture.cleanup() }
    try FileManager.default.removeItem(at: fixture.journalURL)

    let reviewed = try PrecisionRuntimeJournalRotation.review(
        runtimeJournalURL: fixture.journalURL
    )
    #expect(reviewed == nil)
}

@Test func rotationRefusesASymlinkedJournal() throws {
    let fixture = try rotationFixture(.spent)
    defer { fixture.cleanup() }

    let real = fixture.journalURL
        .deletingLastPathComponent()
        .appendingPathComponent("real-journal.json")
    try FileManager.default.moveItem(at: fixture.journalURL, to: real)
    try FileManager.default.createSymbolicLink(
        at: fixture.journalURL,
        withDestinationURL: real
    )

    #expect(throws: PrecisionRuntimeJournalError.runtimeJournalNotRegular) {
        _ = try PrecisionRuntimeJournalRotation.review(
            runtimeJournalURL: fixture.journalURL
        )
    }
}

// MARK: - Fixtures

enum RotationFixtureState {
    case spent            // completed / restoredVerified
    case running          // running / appliedVerified
    case ambiguousApply   // recoveryRequired / applyMayHaveOccurred
    case ambiguousRestore // recoveryRequired / restoreMayHaveOccurred
    case conflicted       // conflicted
    case prepared         // prepared / baselineVerified
}

struct RotationFixture {
    let directory: URL
    let journalURL: URL
    let data: Data
    let sha256: String

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func rotationPadded(_ bytes: [UInt8]) -> [UInt8] {
    var padded = bytes
    padded.append(
        contentsOf: [UInt8](
            repeating: 0,
            count: HIDPP20LongMessage.parameterCount - bytes.count
        )
    )
    return padded
}

private func rotationBaselineJournal() throws -> DeviceStateJournal {
    let device = JournalDeviceIdentity(
        deviceID: "1133-45085-23-1-2",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "ROTATION-TEST",
        locationID: 23,
        firmwareIdentity: "rotation-test-firmware"
    )
    let control = try DeviceControlJournalEntry(
        controlInfo: ReprogControlInfo(
            index: 5,
            controlID: 0x00ED,
            taskID: 0x00C4,
            capabilityFlags: 0x71,
            position: 0,
            group: 1,
            groupMask: 1,
            rawXYCapability: false,
            rawParameters: rotationPadded([0x00, 0xED])
        ),
        baselineReporting: ReprogControlReportingState(
            controlID: 0x00ED,
            rawFlags: 0,
            rawMappedControlID: 0,
            rawParameters: rotationPadded([0x00, 0xED, 0x00, 0x00, 0x00])
        )
    )
    return try DeviceStateJournal(
        transactionID: UUID(),
        appBuild: "rotation-test",
        device: device,
        feature: HIDPP20FeatureDescriptor(
            index: 0x0A,
            type: 0,
            version: 3,
            rawParameters: rotationPadded([0x0A, 0x00, 0x03])
        ),
        expectedControlCount: 1,
        controls: [control]
    )
}

private func rotationFixture(
    _ state: RotationFixtureState
) throws -> RotationFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "MXErgoPrecisionRuntimeJournalRotationTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let journalURL = directory.appendingPathComponent("precision-runtime-v3.json")
    let envelope = try DeviceTransactionEnvelope(
        baselineJournal: rotationBaselineJournal()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    var object = try JSONSerialization.jsonObject(
        with: encoder.encode(envelope)
    ) as! [String: Any]
    var controls = object["controls"] as! [[String: Any]]
    let baseline = controls[0]["baseline"] as! [String: Any]
    var activeParameters = baseline["rawParameters"] as! [Int]
    activeParameters[2] = 0x01
    let active: [String: Any] = ["rawParameters": activeParameters]

    switch state {
    case .prepared:
        controls[0]["phase"] = "baselineVerified"
        object["status"] = "prepared"
    case .running:
        controls[0]["phase"] = "appliedVerified"
        controls[0]["intended"] = active
        controls[0]["appliedObservation"] = active
        object["status"] = "running"
    case .spent:
        controls[0]["phase"] = "restoredVerified"
        controls[0]["intended"] = active
        controls[0]["restoredObservation"] = baseline
        object["status"] = "completed"
    case .ambiguousApply:
        controls[0]["phase"] = "applyMayHaveOccurred"
        controls[0]["intended"] = active
        let attemptID = UUID()
        controls[0]["activeAttemptID"] = attemptID.uuidString
        controls[0]["attempts"] = [attempt(id: attemptID, kind: "apply")]
        object["status"] = "recoveryRequired"
    case .ambiguousRestore:
        controls[0]["phase"] = "restoreMayHaveOccurred"
        controls[0]["intended"] = active
        controls[0]["appliedObservation"] = active
        let attemptID = UUID()
        controls[0]["activeAttemptID"] = attemptID.uuidString
        controls[0]["attempts"] = [attempt(id: attemptID, kind: "restore")]
        object["status"] = "recoveryRequired"
    case .conflicted:
        controls[0]["phase"] = "conflicted"
        controls[0]["conflictReason"] = "third-party drift"
        object["status"] = "conflicted"
    }

    object["controls"] = controls
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: journalURL, options: .atomic)

    // Everything except the deliberately invalid cases must be a journal the
    // model itself accepts, or the test would prove nothing about rotation.
    let decoded = try JSONDecoder().decode(
        DeviceTransactionEnvelope.self,
        from: data
    )
    try decoded.validate()

    return RotationFixture(
        directory: directory,
        journalURL: journalURL,
        data: data,
        sha256: sha256(data)
    )
}

private func attempt(id: UUID, kind: String) -> [String: Any] {
    [
        "id": id.uuidString,
        "ordinal": 1,
        "kind": kind,
        "outcome": "armed",
        "armedAtRevision": 1,
    ]
}

private func mutateRuntimeJournal(
    at url: URL,
    _ mutation: (inout [String: Any]) -> Void
) throws {
    var object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: url)
    ) as! [String: Any]
    mutation(&object)
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: url, options: .atomic)
}
