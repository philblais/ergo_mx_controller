import Foundation
import Testing
@testable import MXErgoHID

@Test func observerTeardownCancelsQueuedAndActiveRequestsInAcceptanceOrder()
throws {
    let coordinator = MXErgoObserverHandoffCoordinator()
    let events = LockedObserverEvents()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))

    let queued = try #require(coordinator.registerRequest(runID: runID) {
        events.append("cancel queued")
    })
    let active = try #require(coordinator.registerRequest(runID: runID) {
        events.append("cancel active")
    })
    #expect(coordinator.activateRequest(active))
    #expect(coordinator.beginStop(runID: runID))

    let receipt = try #require(coordinator.performTeardown(
        runID: runID,
        managerWasAcquired: true,
        calls: MXErgoObserverTeardownCalls(
            clearRequestState: { events.append("clear") },
            unscheduleManager: { events.append("unschedule") },
            closeManager: {
                events.append("close")
                return 0
            },
            didQuiesceCallbacks: { events.append("stopped") }
        )
    ))

    #expect(events.values == [
        "clear",
        "unschedule",
        "close",
        "cancel queued",
        "cancel active",
        "stopped",
    ])
    #expect(receipt.runID == runID)
    #expect(receipt.pendingRequestCountAtStop == 2)
    #expect(receipt.finalPendingRequestCount == 0)
    #expect(receipt.callbackDeliveryQuiesced)
    #expect(receipt.ownershipDisposition == .managerClosed)
    #expect(!coordinator.completeRequest(queued))
    #expect(!coordinator.completeRequest(active))
    #expect(coordinator.performTeardown(
        runID: runID,
        managerWasAcquired: true,
        calls: noOpObserverTeardownCalls()
    ) == nil)
}

@Test func aNormalCompletionWinsExactlyOnceBeforeTeardown() throws {
    let coordinator = MXErgoObserverHandoffCoordinator()
    let cancellations = LockedObserverEvents()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    let ticket = try #require(coordinator.registerRequest(runID: runID) {
        cancellations.append("cancel")
    })
    #expect(coordinator.activateRequest(ticket))
    #expect(coordinator.completeRequest(ticket))
    #expect(!coordinator.completeRequest(ticket))
    #expect(coordinator.beginStop(runID: runID))

    let receipt = try #require(coordinator.performTeardown(
        runID: runID,
        managerWasAcquired: true,
        calls: noOpObserverTeardownCalls()
    ))
    #expect(cancellations.values.isEmpty)
    #expect(receipt.pendingRequestCountAtStop == 0)
    #expect(receipt.finalPendingRequestCount == 0)
}

@Test func stopBeforeRunLoopAcquisitionCancelsWorkAndAllowsRestart() throws {
    let coordinator = MXErgoObserverHandoffCoordinator()
    let events = LockedObserverEvents()
    let firstRunID = try #require(coordinator.beginRun())
    _ = try #require(coordinator.registerRequest(runID: firstRunID) {
        events.append("cancel")
    })
    #expect(coordinator.beginStop(runID: firstRunID))
    #expect(coordinator.beginRun() == nil)

    let receipt = try #require(coordinator.performTeardown(
        runID: firstRunID,
        managerWasAcquired: false,
        calls: MXErgoObserverTeardownCalls(
            clearRequestState: { events.append("clear") },
            unscheduleManager: { events.append("unexpected unschedule") },
            closeManager: {
                events.append("unexpected close")
                return 0
            },
            didQuiesceCallbacks: { events.append("stopped") }
        )
    ))

    #expect(receipt.ownershipDisposition == .neverAcquired)
    #expect(events.values == ["clear", "cancel", "stopped"])
    let secondRunID = try #require(coordinator.beginRun())
    #expect(secondRunID != firstRunID)
    #expect(coordinator.performTeardown(
        runID: secondRunID,
        managerWasAcquired: false,
        calls: noOpObserverTeardownCalls()
    ) != nil)
}

@Test func restartFenceBlocksBeginRunAfterCleanStopUntilMatchingRelease()
throws {
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    let fenceID = try #require(
        coordinator.installRestartFence(capturedRunID: runID)
    )
    #expect(coordinator.installRestartFence(capturedRunID: runID) == nil)
    #expect(coordinator.installRestartFence(capturedRunID: UUID()) == nil)
    #expect(coordinator.beginStop(runID: runID))

    let receipt = try #require(coordinator.performTeardown(
        runID: runID,
        managerWasAcquired: true,
        calls: noOpObserverTeardownCalls()
    ))
    #expect(receipt.ownershipDisposition == .managerClosed)
    #expect(coordinator.restartFenceCapturedRunID == runID)
    #expect(coordinator.beginRun() == nil)
    #expect(!coordinator.releaseRestartFence(fenceID: UUID()))
    #expect(coordinator.beginRun() == nil)
    #expect(coordinator.releaseRestartFence(fenceID: fenceID))
    #expect(coordinator.restartFenceCapturedRunID == nil)
    let nextRunID = try #require(coordinator.beginRun())
    #expect(nextRunID != runID)
}

@Test func restartFenceCannotBeInstalledForADifferentOrMissingRun() throws {
    let coordinator = MXErgoObserverHandoffCoordinator()
    #expect(coordinator.installRestartFence(capturedRunID: UUID()) == nil)

    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    #expect(coordinator.installRestartFence(capturedRunID: UUID()) == nil)
    #expect(coordinator.beginStop(runID: runID))
    #expect(coordinator.performTeardown(
        runID: runID,
        managerWasAcquired: false,
        calls: noOpObserverTeardownCalls()
    ) != nil)
    #expect(coordinator.installRestartFence(capturedRunID: UUID()) == nil)
    let fenceID = try #require(
        coordinator.installRestartFence(capturedRunID: runID)
    )
    #expect(coordinator.beginRun() == nil)
    #expect(coordinator.releaseRestartFence(fenceID: fenceID))
}

@Test func foreignObserverRestartFenceCannotReleaseOrInstall() {
    let observer = MXErgoObserver()
    let foreignRun = MXErgoObserverHandoffRun(
        observerID: UUID(),
        runID: UUID()
    )
    #expect(observer.installRestartFence(for: foreignRun) == nil)
    #expect(!observer.releaseRestartFence(
        MXErgoObserverRestartFence(
            fenceID: UUID(),
            capturedRunID: UUID(),
            observerID: UUID()
        )
    ))
}

@Test func closeFailureIsTerminalAndPermanentlyBlocksRestart() throws {
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    #expect(coordinator.beginStop(runID: runID))

    let receipt = try #require(coordinator.performTeardown(
        runID: runID,
        managerWasAcquired: true,
        calls: MXErgoObserverTeardownCalls(
            clearRequestState: {},
            unscheduleManager: {},
            closeManager: { -7 },
            didQuiesceCallbacks: {}
        )
    ))

    #expect(receipt.ownershipDisposition == .releaseUncertain(closeReturn: -7))
    #expect(coordinator.lifecycleState == .releaseUncertain(
        runID: runID,
        closeReturn: -7
    ))
    #expect(coordinator.beginRun() == nil)
}

@Test func concurrentHandoffWaitersReceiveTheSameReceipt() async throws {
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    #expect(coordinator.beginStop(runID: runID))

    async let first = coordinator.waitForStop(
        runID: runID,
        timeoutNanoseconds: 1_000_000_000
    )
    async let second = coordinator.waitForStop(
        runID: runID,
        timeoutNanoseconds: 1_000_000_000
    )
    await Task.yield()
    let receipt = try #require(coordinator.performTeardown(
        runID: runID,
        managerWasAcquired: true,
        calls: noOpObserverTeardownCalls()
    ))

    #expect(await first == .stopped(receipt))
    #expect(await second == .stopped(receipt))
}

@Test func waiterTimeoutDoesNotCancelPhysicalTeardown() async throws {
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    #expect(coordinator.beginStop(runID: runID))

    let waitResult = await coordinator.waitForStop(
        runID: runID,
        timeoutNanoseconds: 1_000_000
    )
    #expect(waitResult == .timedOut(runID: runID))
    let receipt = try #require(coordinator.performTeardown(
        runID: runID,
        managerWasAcquired: true,
        calls: noOpObserverTeardownCalls()
    ))
    #expect(coordinator.latestTerminalReceipt() == receipt)
}

@Test func waiterCancellationDoesNotCancelPhysicalTeardown() async throws {
    let coordinator = MXErgoObserverHandoffCoordinator()
    let runID = try #require(coordinator.beginRun())
    #expect(coordinator.markRunning(runID: runID))
    #expect(coordinator.beginStop(runID: runID))

    let waiter = Task {
        await coordinator.waitForStop(
            runID: runID,
            timeoutNanoseconds: 1_000_000_000
        )
    }
    await Task.yield()
    waiter.cancel()
    #expect(await waiter.value == .cancelled(runID: runID))

    let receipt = try #require(coordinator.performTeardown(
        runID: runID,
        managerWasAcquired: true,
        calls: noOpObserverTeardownCalls()
    ))
    #expect(coordinator.latestTerminalReceipt() == receipt)
}

@Test func observerHandoffRunCaptureWithoutAStartedRunRequiresNoHardware() {
    let observer = MXErgoObserver()
    #expect(observer.captureHandoffRun() == nil)
}

@Test func foreignObserverRunCapabilityCannotAuthorizeAStop() async {
    let observer = MXErgoObserver()
    let runID = UUID()
    let foreignRun = MXErgoObserverHandoffRun(
        observerID: UUID(),
        runID: runID
    )

    #expect(await observer.stopForHandoff(
        expectedRun: foreignRun,
        timeoutNanoseconds: 1
    ) == .runMismatch(expectedRunID: runID, actualRunID: nil))
}

@Test func observerHandoffRemainsInsideTheExistingHIDTarget() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let packageManifest = try String(
        contentsOf: packageRoot.appendingPathComponent("Package.swift"),
        encoding: .utf8
    )
    let sourceRoot = packageRoot.appendingPathComponent(
        "Sources/MXErgoHID"
    )
    let coordinatorSource = try String(
        contentsOf: sourceRoot.appendingPathComponent(
            "ObserverHandoffCoordinator.swift"
        ),
        encoding: .utf8
    )
    let observerSource = try String(
        contentsOf: sourceRoot.appendingPathComponent("MXErgoObserver.swift"),
        encoding: .utf8
    )

    #expect(packageManifest.contains(
        "name: \"MXErgoHID\",\n            dependencies: [\"MXErgoCore\", \"MXErgoHIDPP\"]"
    ))
    #expect(!packageManifest.contains(
        ".library(name: \"MXErgoPrecisionRuntimeAdmission\""
    ))
    #expect(!coordinatorSource.contains("import IOKit"))
    #expect(!coordinatorSource.contains("MXErgoPrecisionRuntimeAdmission"))
    #expect(!observerSource.contains("MXErgoPrecisionRuntimeAdmission"))
    #expect(!observerSource.contains("PrecisionRuntimeHostHandoff"))
    #expect(!observerSource.contains("MXErgoPrecisionRuntimeLifecycle"))
    #expect(coordinatorSource.contains("installRestartFence"))
    #expect(observerSource.contains("installRestartFence"))
    let wheelSource = try String(
        contentsOf: sourceRoot.appendingPathComponent("MXErgoWheelObserver.swift"),
        encoding: .utf8
    )
    #expect(wheelSource.contains("kHIDUsage_GD_Wheel"))
    #expect(!wheelSource.contains("IOHIDDeviceSetReport"))
    #expect(!wheelSource.contains("RegisterInputReport"))
}

private func noOpObserverTeardownCalls() -> MXErgoObserverTeardownCalls {
    MXErgoObserverTeardownCalls(
        clearRequestState: {},
        unscheduleManager: {},
        closeManager: { 0 },
        didQuiesceCallbacks: {}
    )
}

private final class LockedObserverEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}
