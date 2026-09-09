import Foundation
import Testing
@testable import MXErgoCore

private func logFixture(byteCap: Int = 1024) throws -> (URL, URL, BoundedDiagnosticsLog) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("diagnostics.log")
    return (directory, url, BoundedDiagnosticsLog(url: url, byteCap: byteCap))
}

@Test func diagnosticsConstructionAndDisabledAppendsCreateNoFile() async throws {
    let (directory, url, log) = try logFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    log.append("disabled")
    log.stop()
    await log.waitForPendingWrites()
    #expect(log.path == url.path)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func diagnosticsCommandsPreserveOrderAndIgnoreAppendsAfterStop() async throws {
    let (directory, url, log) = try logFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    log.start()
    log.append("first-event")
    log.append("second-event")
    log.stop()
    log.append("after-stop")
    await log.waitForPendingWrites()
    let text = try String(contentsOf: url, encoding: .utf8)
    let lines = text.split(separator: "\n")
    try #require(lines.count == 4)
    #expect(lines[0].contains("log opened"))
    #expect(lines[1].hasSuffix("first-event"))
    #expect(lines[2].hasSuffix("second-event"))
    #expect(lines[3].contains("log closed"))
    #expect(!text.contains("after-stop"))
}

@Test func diagnosticsRestartReplacesTheOldSession() async throws {
    let (directory, url, log) = try logFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    log.start()
    log.append("old-session")
    log.stop()
    log.start()
    log.append("new-session")
    log.stop()
    await log.waitForPendingWrites()
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains("old-session"))
    #expect(text.contains("new-session"))
    #expect(text.split(separator: "\n").count == 3)
}

@Test func diagnosticsRepeatedWrapsStayWithinTheCapWithoutSparseGaps() async throws {
    let (directory, url, log) = try logFixture(byteCap: 256)
    defer { try? FileManager.default.removeItem(at: directory) }
    log.start()
    for index in 0..<30 {
        log.append("event-\(index) " + String(repeating: "x", count: 100))
        await log.waitForPendingWrites()
        let data = try Data(contentsOf: url)
        #expect(data.count <= 256)
        #expect(!data.contains(0))
        #expect(String(data: data, encoding: .utf8)?.contains("event-\(index) ") == true)
    }
    log.stop()
    await log.waitForPendingWrites()
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("log wrapped"))
    #expect(text.utf8.count <= 256)
}

@Test func diagnosticsOversizedUnicodeEntryIsMarkedAndRemainsValidUTF8() async throws {
    let (directory, url, log) = try logFixture(byteCap: 256)
    defer { try? FileManager.default.removeItem(at: directory) }
    log.start()
    log.append(String(repeating: "🖱é", count: 1000))
    await log.waitForPendingWrites()
    let data = try Data(contentsOf: url)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(data.count <= 256)
    #expect(text.hasSuffix(" [truncated]\n"))
    #expect(text.contains("🖱é"))
    log.stop()
    await log.waitForPendingWrites()
}

@Test func diagnosticsEntryLimitIncludesTheWrapMarker() async throws {
    let (directory, url, log) = try logFixture(byteCap: 128)
    defer { try? FileManager.default.removeItem(at: directory) }
    log.start()
    for length in [1, 40, 80, 110, 128, 500, 1] {
        log.append(String(repeating: "x", count: length))
        await log.waitForPendingWrites()
        #expect(try Data(contentsOf: url).count <= 128)
    }
    log.stop()
    await log.waitForPendingWrites()
    #expect(try Data(contentsOf: url).count <= 128)
}

@Test func diagnosticsConcurrentProducersWriteCompleteUniqueEntries() async throws {
    let (directory, url, log) = try logFixture(byteCap: 64 * 1024)
    defer { try? FileManager.default.removeItem(at: directory) }
    log.start()
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<200 {
            group.addTask { log.append("event-\(index)") }
        }
    }
    log.stop()
    await log.waitForPendingWrites()
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    let events = lines.filter { $0.contains("event-") }.compactMap { $0.split(separator: " ").last }
    #expect(events.count == 200)
    #expect(Set(events.map(String.init)) == Set((0..<200).map { "event-\($0)" }))
    #expect(lines.last?.contains("log closed") == true)
}

@Test func diagnosticsUnavailablePathFailsOpenAndCanStartAfterItBecomesAvailable() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("diagnostics.log")
    let log = BoundedDiagnosticsLog(url: url)
    log.start()
    log.append("unavailable")
    log.stop()
    await log.waitForPendingWrites()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    log.start()
    log.append("available")
    log.stop()
    await log.waitForPendingWrites()
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("available"))
    #expect(!text.contains("unavailable"))
}

private func backlogFixture(bytes: Int = 4096, entries: Int = 2) throws
    -> (URL, URL, BoundedDiagnosticsLog, DispatchQueue) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("diagnostics.log")
    let queue = DispatchQueue(label: "diagnostics.backlog.test")
    let log = BoundedDiagnosticsLog(url: url, byteCap: 4096,
        pendingByteCap: bytes, pendingEntryCap: entries, queue: queue)
    return (directory, url, log, queue)
}

@Test func diagnosticsFullBacklogStillAcceptsStopAndReportsLoss() async throws {
    let (directory, url, log, queue) = try backlogFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        queue.suspend()
        defer { queue.resume() }
        log.start()
        log.append("accepted-one")
        log.append("accepted-two")
        for _ in 0..<3 { log.append("discarded-entry") }
        #expect(log.pendingUsage.entries == 2)
        log.stop()
        log.append("after-stop")
    }
    await log.waitForPendingWrites()
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("accepted-one"))
    #expect(text.contains("accepted-two"))
    #expect(text.contains("dropped 3 diagnostics entries"))
    #expect(!text.contains("discarded-entry"))
    #expect(!text.contains("after-stop"))
    #expect(text.split(separator: "\n").last?.contains("log closed") == true)
    #expect(log.pendingUsage.entries == 0)
    #expect(log.pendingUsage.bytes == 0)
}

@Test func diagnosticsByteQuotaIsIndependentOfTheEntryQuota() async throws {
    let (directory, url, log, queue) = try backlogFixture(bytes: 32, entries: 100)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        queue.suspend()
        defer { queue.resume() }
        log.start()
        log.append(String(repeating: "a", count: 20))
        log.append(String(repeating: "b", count: 20))
        log.append("tiny")
        #expect(log.pendingUsage.entries == 2)
        #expect(log.pendingUsage.bytes == 24)
        log.stop()
    }
    await log.waitForPendingWrites()
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains(String(repeating: "a", count: 20)))
    #expect(!text.contains(String(repeating: "b", count: 20)))
    #expect(text.contains("dropped 1 diagnostics entries"))
    #expect(text.contains("tiny"))
    #expect(text.components(separatedBy: "dropped 1").count == 2)
}

@Test func diagnosticsOversizedQueuedPayloadIsBoundedBeforeTheWriterRuns() async throws {
    let (directory, url, log, queue) = try backlogFixture(bytes: 32)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        queue.suspend()
        defer { queue.resume() }
        log.start()
        log.append(String(repeating: "🖱é", count: 100_000))
        #expect(log.pendingUsage.entries == 1)
        #expect(log.pendingUsage.bytes <= 32)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        log.stop()
    }
    await log.waitForPendingWrites()
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("🖱é"))
    #expect(text.contains(" [truncated]"))
    #expect(log.pendingUsage.bytes == 0)
}

@Test func diagnosticsDrainingReopensCapacityAndReportsLossBeforeTheNextEntry() async throws {
    let (directory, url, log, queue) = try backlogFixture(entries: 1)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        queue.suspend()
        defer { queue.resume() }
        log.start()
        log.append("before-overload")
        log.append("discarded-entry")
    }
    await log.waitForPendingWrites()
    #expect(log.pendingUsage.entries == 0)
    #expect(log.pendingUsage.bytes == 0)
    log.append("after-drain")
    log.stop()
    await log.waitForPendingWrites()
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    let loss = try #require(lines.firstIndex { $0.contains("dropped 1") })
    let next = try #require(lines.firstIndex { $0.contains("after-drain") })
    #expect(loss < next)
    #expect(!lines.contains { $0.contains("discarded-entry") })
}

@Test func diagnosticsRestartDoesNotCarryOldLossIntoTheNewSession() async throws {
    let (directory, url, log, queue) = try backlogFixture(entries: 1)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        queue.suspend()
        defer { queue.resume() }
        log.start()
        log.append("old-entry")
        for _ in 0..<5 { log.append("old-discarded") }
        log.start()
    }
    await log.waitForPendingWrites()
    #expect(log.pendingUsage.entries == 0)
    log.append("new-entry")
    log.stop()
    await log.waitForPendingWrites()
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("new-entry"))
    #expect(!text.contains("old-entry"))
    #expect(!text.contains("dropped"))
}

@Test func diagnosticsConcurrentOverloadCannotOversubscribeTheBudget() async throws {
    let (directory, url, log, queue) = try backlogFixture(bytes: 64, entries: 8)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        queue.suspend()
        defer { queue.resume() }
        log.start()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { log.append(String(repeating: "x", count: 24)) }
            }
        }
        #expect(log.pendingUsage.entries == 2)
        #expect(log.pendingUsage.bytes == 48)
        log.stop()
    }
    await log.waitForPendingWrites()
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("dropped 98 diagnostics entries"))
    #expect(log.pendingUsage.entries == 0)
    #expect(log.pendingUsage.bytes == 0)
}

@Test func diagnosticsEmptyMessagesCannotBypassTheEntryLimit() async throws {
    let (directory, url, log, queue) = try backlogFixture(entries: 4)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        queue.suspend()
        defer { queue.resume() }
        log.start()
        for _ in 0..<1000 { log.append("") }
        #expect(log.pendingUsage.entries == 4)
        #expect(log.pendingUsage.bytes == 0)
        log.stop()
    }
    await log.waitForPendingWrites()
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("dropped 996 diagnostics entries"))
    #expect(log.pendingUsage.entries == 0)
}
