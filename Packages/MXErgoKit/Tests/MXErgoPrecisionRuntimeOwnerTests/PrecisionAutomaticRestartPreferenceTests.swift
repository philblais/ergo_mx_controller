import Foundation
import Testing
import MXErgoHIDPP
@testable import MXErgoPrecisionRuntimeOwner

private struct AutomaticPreferenceFixture {
    let directory: URL
    let source: URL
    let runtime: URL
    let sourceBytes: Data
    let baseline: DeviceStateJournal
    let preference: PrecisionAutomaticRestartPreference
    init() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        sourceBytes = try Data(contentsOf: root.appendingPathComponent("Evidence/2026-08-30/device-state-journal.json"))
        baseline = try JSONDecoder().decode(DeviceStateJournal.self, from: sourceBytes)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("automatic-preference-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("baseline.json")
        runtime = directory.appendingPathComponent("runtime.json")
        preference = PrecisionAutomaticRestartPreference(fileURL: directory.appendingPathComponent("preference.json"))
        try sourceBytes.write(to: source)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    func envelope(completed: Bool) throws -> DeviceTransactionEnvelope {
        let plan = try PrecisionTemporaryDiversionPlan.make(journal: baseline, currentFeature: baseline.feature,
            deviceIndex: 0, softwareID: 0x0E)
        let prepared = try DeviceTransactionEnvelope(baselineJournal: baseline)
        let armed = try DeviceTransactionReducer.reduce(prepared, event: .armApply(controlID: 0x00ED,
            intended: plan.activeState, attemptID: UUID(), now: Date())).envelope
        let active = try DeviceTransactionReducer.reduce(armed, event: .observeApply(controlID: 0x00ED,
            state: plan.activeState, now: Date())).envelope
        if !completed { return active }
        return try #require(try DeviceTransactionReducer.reduceRecoveryObservation(active, controlID: 0x00ED,
            state: plan.baseline)).envelope
    }
}

@Test func automaticPreferenceDefaultsOffPersistsAndRevokesWithoutTouchingBaseline() throws {
    let fixture = try AutomaticPreferenceFixture()
    defer { fixture.cleanUp() }
    #expect(!fixture.preference.isEnabled)
    try fixture.preference.enable(sourceBaselineURL: fixture.source)
    #expect(PrecisionAutomaticRestartPreference(fileURL: fixture.preference.fileURL).isEnabled)
    let run = try fixture.preference.beginRun()
    try run.validate()
    try fixture.preference.disable()
    #expect(!fixture.preference.isEnabled)
    #expect(throws: (any Error).self) { try run.validate() }
    try fixture.preference.enable(sourceBaselineURL: fixture.source)
    // A new enrollment cannot revive an older captured consent file.
    #expect(throws: (any Error).self) { try run.validate() }
    #expect(try Data(contentsOf: fixture.source) == fixture.sourceBytes)
}

@Test func automaticPreferenceMalformedOrUnknownVersionCannotStart() throws {
    let fixture = try AutomaticPreferenceFixture()
    defer { fixture.cleanUp() }
    for data in [Data("broken".utf8), Data("{\"version\":2,\"enabled\":true}".utf8)] {
        try data.write(to: fixture.preference.fileURL)
        #expect(!fixture.preference.isEnabled)
        #expect(throws: (any Error).self) { _ = try fixture.preference.beginRun() }
    }
}

@Test func automaticRotationArchivesOnlyMatchingCompletedEvidence() throws {
    let fixture = try AutomaticPreferenceFixture()
    defer { fixture.cleanUp() }
    try fixture.preference.enable(sourceBaselineURL: fixture.source)
    let run = try fixture.preference.beginRun()
    let active = try JSONEncoder().encode(fixture.envelope(completed: false))
    try active.write(to: fixture.runtime)
    #expect(try !run.archiveCompletedRuntimeIfPresent(runtimeJournalURL: fixture.runtime, sourceBaselineURL: fixture.source))
    #expect(try Data(contentsOf: fixture.runtime) == active)
    let completed = try JSONEncoder().encode(fixture.envelope(completed: true))
    try completed.write(to: fixture.runtime)
    #expect(try run.archiveCompletedRuntimeIfPresent(runtimeJournalURL: fixture.runtime, sourceBaselineURL: fixture.source))
    #expect(!FileManager.default.fileExists(atPath: fixture.runtime.path))
    let archive = try #require(FileManager.default.contentsOfDirectory(at: fixture.directory,
        includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("completed-") })
    #expect(try Data(contentsOf: archive) == completed)
    #expect(try Data(contentsOf: fixture.source) == fixture.sourceBytes)
}

@Test func automaticRotationRejectsChangedBaselineAndRevokedRun() throws {
    let fixture = try AutomaticPreferenceFixture()
    defer { fixture.cleanUp() }
    try fixture.preference.enable(sourceBaselineURL: fixture.source)
    let run = try fixture.preference.beginRun()
    let completed = try JSONEncoder().encode(fixture.envelope(completed: true))
    try completed.write(to: fixture.runtime)
    try (fixture.sourceBytes + Data(" ".utf8)).write(to: fixture.source)
    #expect(throws: (any Error).self) {
        _ = try run.archiveCompletedRuntimeIfPresent(runtimeJournalURL: fixture.runtime, sourceBaselineURL: fixture.source)
    }
    try fixture.sourceBytes.write(to: fixture.source)
    run.revoke()
    #expect(throws: (any Error).self) {
        _ = try run.archiveCompletedRuntimeIfPresent(runtimeJournalURL: fixture.runtime, sourceBaselineURL: fixture.source)
    }
    #expect(try Data(contentsOf: fixture.runtime) == completed)
}

@Test func automaticRotationRejectsConsentForAnotherBaselineEvenWithSameHash() throws {
    let fixture = try AutomaticPreferenceFixture()
    defer { fixture.cleanUp() }
    try fixture.preference.enable(sourceBaselineURL: fixture.source)
    let completed = try JSONEncoder().encode(fixture.envelope(completed: true))
    try completed.write(to: fixture.runtime)
    let original = try Data(contentsOf: fixture.preference.fileURL)
    for field in ["sourceBaselineTransactionID", "device"] {
        var consent = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        if field == "device" {
            var device = try #require(consent[field] as? [String: Any])
            device["serialNumber"] = "different"
            consent[field] = device
        } else { consent[field] = UUID().uuidString }
        try JSONSerialization.data(withJSONObject: consent).write(to: fixture.preference.fileURL)
        let run = try fixture.preference.beginRun()
        #expect(throws: (any Error).self) {
            _ = try run.archiveCompletedRuntimeIfPresent(runtimeJournalURL: fixture.runtime, sourceBaselineURL: fixture.source)
        }
        #expect(try Data(contentsOf: fixture.runtime) == completed)
    }
}
