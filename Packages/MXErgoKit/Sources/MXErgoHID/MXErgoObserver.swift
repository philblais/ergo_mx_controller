import Foundation
@preconcurrency import IOKit.hid
import MXErgoCore
import MXErgoHIDPP

public final class MXErgoObserver: @unchecked Sendable {
    public typealias Handler = @Sendable (MXErgoObservation) -> Void
    public typealias RootQueryCompletion = @Sendable (MXErgoOneShotRootQueryResult) -> Void
    public typealias ControlEnumerationCompletion = @Sendable (
        MXErgoReadOnlyControlEnumerationResult
    ) -> Void
    public typealias ReportingSnapshotCompletion = @Sendable (
        MXErgoReadOnlyReportingSnapshotResult
    ) -> Void
    public typealias FirmwareFingerprintCompletion = @Sendable (
        MXErgoFirmwareFingerprintResult
    ) -> Void
    public typealias PrecisionPreflightCompletion = @Sendable (
        MXErgoReadOnlyPrecisionPreflightResult
    ) -> Void
    public typealias MappedControlPreflightCompletion = @Sendable (
        MXErgoReadOnlyMappedControlPreflightResult
    ) -> Void

    private let lock = NSLock()
    private let observerID = UUID()
    private let handoffCoordinator = MXErgoObserverHandoffCoordinator()
    private var inputLoop: InputLoop?

    public init() {}

    public func start(handler: @escaping Handler) {
        lock.lock()
        guard inputLoop == nil,
              handoffCoordinator.restartFenceCapturedRunID == nil,
              let runID = handoffCoordinator.beginRun() else {
            lock.unlock()
            return
        }
        let loop = InputLoop(
            runID: runID,
            handoffCoordinator: handoffCoordinator,
            handler: handler,
            didFinish: { [weak self] finishedRunID in
                self?.inputLoopDidFinish(runID: finishedRunID)
            }
        )
        inputLoop = loop
        lock.unlock()
        loop.start()
    }

    public func stop() {
        lock.lock()
        let loop = inputLoop
        lock.unlock()

        loop?.stop()
    }

    /// Stops the IOHID run loop and waits until the manager has been
    /// unscheduled and closed. A helper process must not be launched until
    /// this returns true.
    @discardableResult
    public func stopAndWait(timeout: TimeInterval = 5.0) -> Bool {
        lock.lock()
        let loop = inputLoop
        lock.unlock()

        guard let loop else {
            guard let receipt = handoffCoordinator.latestTerminalReceipt() else {
                return true
            }
            if case .releaseUncertain = receipt.ownershipDisposition {
                return false
            }
            return true
        }
        return loop.stopAndWait(timeout: timeout)
    }

    /// Installs a restart fence for one captured run. A clean stop then cannot
    /// start another run until the matching token is released. Abandoning the
    /// holder leaves the fence in place.
    package func installRestartFence(
        for capturedRun: MXErgoObserverHandoffRun
    ) -> MXErgoObserverRestartFence? {
        lock.withLock {
            guard capturedRun.observerID == observerID else { return nil }
            if let loop = inputLoop, loop.runID != capturedRun.runID {
                return nil
            }
            guard let fenceID = handoffCoordinator.installRestartFence(
                capturedRunID: capturedRun.runID
            ) else {
                return nil
            }
            return MXErgoObserverRestartFence(
                fenceID: fenceID,
                capturedRunID: capturedRun.runID,
                observerID: observerID
            )
        }
    }

    /// Lifts a previously installed restart fence. A foreign or already-spent
    /// token has no effect.
    @discardableResult
    package func releaseRestartFence(
        _ fence: MXErgoObserverRestartFence
    ) -> Bool {
        lock.withLock {
            guard fence.observerID == observerID,
                  fence.capturedRunID
                    == handoffCoordinator.restartFenceCapturedRunID else {
                return false
            }
            return handoffCoordinator.releaseRestartFence(fenceID: fence.fenceID)
        }
    }

    /// Captures a non-forgeable capability for the exact current observer run.
    /// A handoff must retain this capability before admission begins so it can
    /// never stop a replacement run.
    package func captureHandoffRun() -> MXErgoObserverHandoffRun? {
        lock.withLock {
            inputLoop.map {
                MXErgoObserverHandoffRun(
                    observerID: observerID,
                    runID: $0.runID
                )
            }
        }
    }

    /// Initiates the same physical teardown as `stop()`, but only when the
    /// retained capability still names this observer's exact run. Timeout or
    /// task cancellation releases only that waiter; physical teardown keeps
    /// running on the owning run loop.
    package func stopForHandoff(
        expectedRun: MXErgoObserverHandoffRun,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async -> MXErgoObserverHandoffWaitResult {
        let selection: (
            loop: InputLoop?,
            result: MXErgoObserverHandoffWaitResult?
        ) = lock.withLock {
            guard expectedRun.observerID == observerID else {
                let actualRunID = inputLoop?.runID
                    ?? handoffCoordinator.latestTerminalReceipt()?.runID
                return (nil, .runMismatch(
                    expectedRunID: expectedRun.runID,
                    actualRunID: actualRunID
                ))
            }
            guard let loop = inputLoop else {
                guard let receipt = handoffCoordinator
                    .latestTerminalReceipt() else {
                    return (nil, .notRunning)
                }
                guard receipt.runID == expectedRun.runID else {
                    return (nil, .runMismatch(
                        expectedRunID: expectedRun.runID,
                        actualRunID: receipt.runID
                    ))
                }
                return (nil, .stopped(receipt))
            }
            guard loop.runID == expectedRun.runID else {
                return (nil, .runMismatch(
                    expectedRunID: expectedRun.runID,
                    actualRunID: loop.runID
                ))
            }
            // Linearize the stop request while `start()` and did-finish
            // cleanup are excluded by the observer lock.
            loop.stop()
            return (loop, nil)
        }
        if let result = selection.result { return result }
        guard let loop = selection.loop else { return .notRunning }
        return await handoffCoordinator.waitForStop(
            runID: loop.runID,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    /// Sends the one read-only Root query allowed for this InputLoop lifetime.
    /// The InputLoop enforces a single attempt for its entire lifetime.
    public func performOneShotRootQuery(completion: @escaping RootQueryCompletion) {
        lock.lock()
        let loop = inputLoop
        lock.unlock()

        guard let loop else {
            completion(.rejected(.observerNotRunning))
            return
        }
        loop.performOneShotRootQuery(completion: completion)
    }

    /// Enumerates REPROG_CONTROLS_V4 metadata after a successful Root query.
    /// Every packet is read-only, single-flight, and attempted at most once for
    /// the InputLoop lifetime.
    public func performReadOnlyControlEnumeration(
        completion: @escaping ControlEnumerationCompletion
    ) {
        lock.lock()
        let loop = inputLoop
        lock.unlock()

        guard let loop else {
            completion(.rejected(.observerNotRunning))
            return
        }
        loop.performReadOnlyControlEnumeration(completion: completion)
    }

    /// Reads the current reporting state for every previously enumerated
    /// control. This sequence contains no SET request and cannot alter the
    /// device; the caller persists the completed snapshot as its baseline.
    public func performReadOnlyReportingSnapshot(
        completion: @escaping ReportingSnapshotCompletion
    ) {
        lock.lock()
        let loop = inputLoop
        lock.unlock()

        guard let loop else {
            completion(.rejected(.observerNotRunning))
            return
        }
        loop.performReadOnlyReportingSnapshot(completion: completion)
    }

    /// Resolves Device Information (0x0003), reads its static device record,
    /// and reads each bounded firmware entity exactly once. The sequence has
    /// no SET function, no automatic retry, and no journal write.
    public func performReadOnlyFirmwareFingerprint(
        completion: @escaping FirmwareFingerprintCompletion
    ) {
        lock.lock()
        let loop = inputLoop
        lock.unlock()

        guard let loop else {
            completion(.rejected(.observerNotRunning))
            return
        }
        loop.performReadOnlyFirmwareFingerprint(completion: completion)
    }

    /// Reads only Precision CID 0x00ED after checking the caller's exact
    /// firmware-bound device, feature, and baseline expectation. This is one
    /// GET request, with no SET function and no automatic retry.
    public func performReadOnlyPrecisionPreflight(
        expectation: MXErgoPrecisionPreflightExpectation,
        completion: @escaping PrecisionPreflightCompletion
    ) {
        lock.lock()
        let loop = inputLoop
        lock.unlock()

        guard let loop else {
            completion(.rejected(.observerNotRunning))
            return
        }
        loop.performReadOnlyPrecisionPreflight(
            expectation: expectation,
            completion: completion
        )
    }

    /// Reads the five reviewed mapped-control CIDs sequentially with
    /// GetCidReporting. This sequence contains no SET and no automatic retry.
    public func performReadOnlyMappedControlPreflight(
        expectation: MXErgoMappedControlPreflightExpectation,
        completion: @escaping MappedControlPreflightCompletion
    ) {
        lock.lock()
        let loop = inputLoop
        lock.unlock()

        guard let loop else {
            completion(.rejected(.observerNotRunning))
            return
        }
        loop.performReadOnlyMappedControlPreflight(
            expectation: expectation,
            completion: completion
        )
    }

    private func inputLoopDidFinish(runID: UUID) {
        lock.lock()
        if inputLoop?.runID == runID {
            inputLoop = nil
        }
        lock.unlock()
    }
}

private final class InputLoop: @unchecked Sendable {
    let runID: UUID
    private let handoffCoordinator: MXErgoObserverHandoffCoordinator
    private let handler: MXErgoObserver.Handler
    private let didFinish: @Sendable (UUID) -> Void
    private let stateLock = NSLock()
    private let lifecycleCondition = NSCondition()
    private var finished = false
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var stopRequested = false
    private var reportCount: UInt64 = 0
    private var lastReportEmissionTime: TimeInterval = 0
    private var lastStandardMouseButtonMask: UInt8?
    private var matchingDevices: [String: IOHIDDevice] = [:]
    private var matchingDeviceProperties: [String: HIDDeviceProperties] = [:]
    private var outputCapabilitiesByDevice: [String: [HIDOutputReportCapability]] = [:]
    private var rootQueryCorrelator = HIDPP20RequestCorrelator()
    private var rootQueryAttempted = false
    private var pendingRootQuery: PendingRootQuery?
    private var resolvedFeature: ResolvedFeature?
    private var controlEnumerationAttempted = false
    private var pendingControlEnumeration: PendingControlEnumeration?
    private var enumeratedControlSnapshot: MXErgoReadOnlyControlSnapshot?
    private var reportingSnapshotAttempted = false
    private var pendingReportingSnapshot: PendingReportingSnapshot?
    private var firmwareFingerprintAttempted = false
    private var pendingFirmwareFingerprint: PendingFirmwareFingerprint?
    private var precisionPreflightAttempted = false
    private var pendingPrecisionPreflight: PendingPrecisionPreflight?
    private var mappedControlPreflightAttempted = false
    private var pendingMappedControlPreflight: PendingMappedControlPreflight?

    private struct PendingRootQuery {
        let id: UUID
        let epoch: UInt64
        let deviceID: String
        let request: HIDPP20LongMessage
        let completion: MXErgoObserver.RootQueryCompletion
    }

    private struct ResolvedFeature {
        let epoch: UInt64
        let deviceID: String
        let descriptor: HIDPP20FeatureDescriptor
    }

    private struct PendingControlEnumeration {
        let id: UUID
        let epoch: UInt64
        let deviceID: String
        let request: HIDPP20LongMessage
        let stage: MXErgoControlEnumerationStage
        let feature: HIDPP20FeatureDescriptor
        let expectedControlCount: Int?
        let controls: [ReprogControlInfo]
        let completion: MXErgoObserver.ControlEnumerationCompletion
    }

    private struct PendingReportingSnapshot {
        let id: UUID
        let epoch: UInt64
        let deviceID: String
        let request: HIDPP20LongMessage
        let stage: MXErgoReportingSnapshotStage
        let metadata: MXErgoReadOnlyControlSnapshot
        let controls: [DeviceControlJournalEntry]
        let completion: MXErgoObserver.ReportingSnapshotCompletion
    }

    private struct PendingFirmwareFingerprint {
        let id: UUID
        let epoch: UInt64
        let deviceID: String
        let request: HIDPP20LongMessage
        let stage: MXErgoFirmwareFingerprintStage
        let feature: HIDPP20FeatureDescriptor?
        let deviceInfo: HIDPP20DeviceInfo?
        let entities: [HIDPP20FirmwareEntity]
        let completion: MXErgoObserver.FirmwareFingerprintCompletion
    }

    private struct PendingPrecisionPreflight {
        let id: UUID
        let epoch: UInt64
        let deviceID: String
        let request: HIDPP20LongMessage
        let expectation: MXErgoPrecisionPreflightExpectation
        let completion: MXErgoObserver.PrecisionPreflightCompletion
    }

    private struct PendingMappedControlPreflight {
        var id: UUID
        let epoch: UInt64
        let deviceID: String
        var request: HIDPP20LongMessage
        var sequence: MappedControlReadOnlyPreflightSequence
        let expectation: MXErgoMappedControlPreflightExpectation
        let completion: MXErgoObserver.MappedControlPreflightCompletion
    }

    init(
        runID: UUID,
        handoffCoordinator: MXErgoObserverHandoffCoordinator,
        handler: @escaping MXErgoObserver.Handler,
        didFinish: @escaping @Sendable (UUID) -> Void
    ) {
        self.runID = runID
        self.handoffCoordinator = handoffCoordinator
        self.handler = handler
        self.didFinish = didFinish
    }

    func start() {
        handler(.status(.starting))

        let thread = Thread { [weak self] in
            self?.run()
        }
        thread.name = "com.phib.MXErgoController.InputLoop"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        _ = handoffCoordinator.beginStop(runID: runID)
        stateLock.lock()
        stopRequested = true
        let loop = runLoop
        stateLock.unlock()

        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            CFRunLoopStop(loop)
        }
        CFRunLoopWakeUp(loop)
    }

    func stopAndWait(timeout: TimeInterval) -> Bool {
        stop()
        let deadline = Date().addingTimeInterval(max(0, timeout))
        lifecycleCondition.lock()
        defer { lifecycleCondition.unlock() }
        while !finished {
            guard lifecycleCondition.wait(until: deadline) else { return false }
        }
        guard let receipt = handoffCoordinator.latestTerminalReceipt(),
              receipt.runID == runID else {
            return false
        }
        if case .releaseUncertain = receipt.ownershipDisposition {
            return false
        }
        return true
    }

    func performOneShotRootQuery(completion: @escaping MXErgoObserver.RootQueryCompletion) {
        enqueueRequest(
            observerNotRunning: .rejected(.observerNotRunning),
            observerStopped: .observerStopped,
            completion: completion
        ) { inputLoop, deliver in
            inputLoop.sendOneShotRootQuery(completion: deliver)
        }
    }

    func performReadOnlyControlEnumeration(
        completion: @escaping MXErgoObserver.ControlEnumerationCompletion
    ) {
        enqueueRequest(
            observerNotRunning: .rejected(.observerNotRunning),
            observerStopped: .observerStopped,
            completion: completion
        ) { inputLoop, deliver in
            inputLoop.startReadOnlyControlEnumeration(completion: deliver)
        }
    }

    func performReadOnlyReportingSnapshot(
        completion: @escaping MXErgoObserver.ReportingSnapshotCompletion
    ) {
        enqueueRequest(
            observerNotRunning: .rejected(.observerNotRunning),
            observerStopped: .observerStopped,
            completion: completion
        ) { inputLoop, deliver in
            inputLoop.startReadOnlyReportingSnapshot(completion: deliver)
        }
    }

    func performReadOnlyFirmwareFingerprint(
        completion: @escaping MXErgoObserver.FirmwareFingerprintCompletion
    ) {
        enqueueRequest(
            observerNotRunning: .rejected(.observerNotRunning),
            observerStopped: .observerStopped,
            completion: completion
        ) { inputLoop, deliver in
            inputLoop.startReadOnlyFirmwareFingerprint(completion: deliver)
        }
    }

    func performReadOnlyPrecisionPreflight(
        expectation: MXErgoPrecisionPreflightExpectation,
        completion: @escaping MXErgoObserver.PrecisionPreflightCompletion
    ) {
        enqueueRequest(
            observerNotRunning: .rejected(.observerNotRunning),
            observerStopped: .observerStopped,
            completion: completion
        ) { inputLoop, deliver in
            inputLoop.startReadOnlyPrecisionPreflight(
                expectation: expectation,
                completion: deliver
            )
        }
    }

    func performReadOnlyMappedControlPreflight(
        expectation: MXErgoMappedControlPreflightExpectation,
        completion: @escaping MXErgoObserver.MappedControlPreflightCompletion
    ) {
        enqueueRequest(
            observerNotRunning: .rejected(.observerNotRunning),
            observerStopped: .observerStopped,
            completion: completion
        ) { inputLoop, deliver in
            inputLoop.startReadOnlyMappedControlPreflight(
                expectation: expectation,
                completion: deliver
            )
        }
    }

    private func enqueueRequest<Result: Sendable>(
        observerNotRunning: Result,
        observerStopped: Result,
        completion: @escaping @Sendable (Result) -> Void,
        operation: @escaping @Sendable (
            InputLoop,
            @escaping @Sendable (Result) -> Void
        ) -> Void
    ) {
        stateLock.lock()
        let loop = runLoop
        stateLock.unlock()

        guard let loop else {
            completion(observerNotRunning)
            return
        }

        guard let ticket = handoffCoordinator.registerRequest(
            runID: runID,
            cancel: { completion(observerStopped) }
        ) else {
            completion(observerStopped)
            return
        }
        let deliver: @Sendable (Result) -> Void = {
            [handoffCoordinator] result in
            guard handoffCoordinator.completeRequest(ticket) else { return }
            completion(result)
        }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self,
                  self.handoffCoordinator.activateRequest(ticket) else {
                return
            }
            operation(self, deliver)
        }
        CFRunLoopWakeUp(loop)
    }

    private func run() {
        defer {
            lifecycleCondition.lock()
            finished = true
            lifecycleCondition.broadcast()
            lifecycleCondition.unlock()
        }
        autoreleasepool {
            guard let currentRunLoop = CFRunLoopGetCurrent() else {
                handler(.status(.failed(code: kIOReturnError)))
                cleanupWithoutManager()
                return
            }
            stateLock.lock()
            runLoop = currentRunLoop
            let shouldStop = stopRequested
            stateLock.unlock()

            guard !shouldStop else {
                cleanupWithoutManager()
                return
            }

            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

            let matching: [String: Any] = [
                kIOHIDVendorIDKey: DeviceIdentity.mxErgo.vendorID,
                kIOHIDProductIDKey: DeviceIdentity.mxErgo.productID,
            ]
            IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatchedCallback, context)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, context)
            IOHIDManagerRegisterInputReportCallback(manager, inputReportCallback, context)
            // Both scroll axes. Tilt arrives as AC Pan on the Consumer page
            // rather than as a button, so a single matching dictionary would
            // silently miss it.
            IOHIDManagerSetInputValueMatchingMultiple(manager, [
                [
                    kIOHIDElementUsagePageKey: kHIDPage_GenericDesktop,
                    kIOHIDElementUsageKey: kHIDUsage_GD_Wheel,
                ],
                [
                    kIOHIDElementUsagePageKey: kHIDPage_Consumer,
                    kIOHIDElementUsageKey: kHIDUsage_Csmr_ACPan,
                ],
            ] as CFArray)
            IOHIDManagerRegisterInputValueCallback(manager, inputValueCallback, context)
            IOHIDManagerScheduleWithRunLoop(manager, currentRunLoop, CFRunLoopMode.defaultMode.rawValue)

            let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            guard result == kIOReturnSuccess else {
                handler(.status(.failed(code: result)))
                cleanup(manager: manager, runLoop: currentRunLoop)
                return
            }

            guard handoffCoordinator.markRunning(runID: runID) else {
                cleanup(manager: manager, runLoop: currentRunLoop)
                return
            }
            handler(.status(.observing))
            CFRunLoopRun()
            cleanup(manager: manager, runLoop: currentRunLoop)
        }
    }

    private func cleanup(manager: IOHIDManager, runLoop: CFRunLoop) {
        _ = handoffCoordinator.performTeardown(
            runID: runID,
            managerWasAcquired: true,
            calls: MXErgoObserverTeardownCalls(
                clearRequestState: { [self] in
                    clearRequestStateForShutdown()
                },
                unscheduleManager: {
                    IOHIDManagerUnscheduleFromRunLoop(
                        manager,
                        runLoop,
                        CFRunLoopMode.defaultMode.rawValue
                    )
                },
                closeManager: { [self] in
                    let result = IOHIDManagerClose(
                        manager,
                        IOOptionBits(kIOHIDOptionsTypeNone)
                    )
                    clearSystemReferences()
                    return result
                },
                didQuiesceCallbacks: { [handler, didFinish, runID] in
                    handler(.status(.stopped))
                    didFinish(runID)
                }
            )
        )
    }

    private func cleanupWithoutManager() {
        _ = handoffCoordinator.performTeardown(
            runID: runID,
            managerWasAcquired: false,
            calls: MXErgoObserverTeardownCalls(
                clearRequestState: { [self] in
                    clearRequestStateForShutdown()
                    clearSystemReferences()
                },
                unscheduleManager: {},
                closeManager: { kIOReturnSuccess },
                didQuiesceCallbacks: { [handler, didFinish, runID] in
                    handler(.status(.stopped))
                    didFinish(runID)
                }
            )
        )
    }

    private func clearRequestStateForShutdown() {
        pendingRootQuery = nil
        pendingControlEnumeration = nil
        pendingReportingSnapshot = nil
        pendingFirmwareFingerprint = nil
        pendingPrecisionPreflight = nil
        pendingMappedControlPreflight = nil
        resolvedFeature = nil
        enumeratedControlSnapshot = nil
        matchingDevices.removeAll()
        matchingDeviceProperties.removeAll()
        outputCapabilitiesByDevice.removeAll()
        rootQueryCorrelator.disconnected()
    }

    private func clearSystemReferences() {
        stateLock.lock()
        runLoop = nil
        stateLock.unlock()
    }

    private func sendOneShotRootQuery(
        completion: @escaping MXErgoObserver.RootQueryCompletion
    ) {
        guard !rootQueryAttempted else {
            completion(.rejected(.alreadyAttempted))
            return
        }
        guard matchingDevices.count == 1,
              let entry = matchingDevices.first,
              let properties = matchingDeviceProperties[entry.key] else {
            completion(.rejected(.matchingDeviceCount(matchingDevices.count)))
            return
        }
        guard outputCapabilitiesByDevice[entry.key, default: []]
            .contains(where: \.isHIDPP20LongReport) else {
            completion(.rejected(.missingExpectedOutputReport))
            return
        }
        guard properties.serialNumber?.isEmpty == false || properties.locationID != nil else {
            completion(.rejected(.missingStableIdentity))
            return
        }
        rootQueryAttempted = true

        let request: HIDPP20LongMessage
        do {
            request = try MXErgoOneShotRootQuery.makeRequest()
        } catch {
            completion(.rejected(.requestRegistrationFailed))
            return
        }

        let epoch = rootQueryCorrelator.connectionEpoch
        let requestID: UUID
        do {
            requestID = try rootQueryCorrelator.register(
                request,
                connectionEpoch: epoch
            )
        } catch {
            completion(.rejected(.requestRegistrationFailed))
            return
        }

        pendingRootQuery = PendingRootQuery(
            id: requestID,
            epoch: epoch,
            deviceID: entry.key,
            request: request,
            completion: completion
        )

        var bytes = request.bytes
        let byteCount = bytes.count
        let outputResult = bytes.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(
                entry.value,
                kIOHIDReportTypeOutput,
                CFIndex(HIDPP20LongMessage.reportID),
                baseAddress,
                byteCount
            )
        }

        guard outputResult == kIOReturnSuccess else {
            pendingRootQuery = nil
            rootQueryCorrelator.cancelBeforeSend(id: requestID)
            completion(.outputFailed(requestBytes: request.bytes, code: outputResult))
            return
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + MXErgoOneShotRootQuery.timeout
        ) { [weak self] in
            self?.scheduleRootQueryTimeout(id: requestID, epoch: epoch)
        }
    }

    private func startReadOnlyFirmwareFingerprint(
        completion: @escaping MXErgoObserver.FirmwareFingerprintCompletion
    ) {
        guard !firmwareFingerprintAttempted else {
            completion(.rejected(.alreadyAttempted))
            return
        }
        guard matchingDevices.count == 1,
              let entry = matchingDevices.first,
              let properties = matchingDeviceProperties[entry.key] else {
            completion(.rejected(.matchingDeviceCount(matchingDevices.count)))
            return
        }
        guard outputCapabilitiesByDevice[entry.key, default: []]
            .contains(where: \.isHIDPP20LongReport) else {
            completion(.rejected(.missingExpectedOutputReport))
            return
        }
        guard properties.serialNumber?.isEmpty == false || properties.locationID != nil else {
            completion(.rejected(.missingStableIdentity))
            return
        }
        firmwareFingerprintAttempted = true

        let request: HIDPP20LongMessage
        do {
            request = try MXErgoFirmwareFingerprintDiscovery.makeRootRequest()
        } catch {
            completion(.rejected(.requestRegistrationFailed))
            return
        }
        sendFirmwareFingerprintRequest(
            request,
            stage: .featureResolution,
            feature: nil,
            deviceInfo: nil,
            entities: [],
            deviceID: entry.key,
            device: entry.value,
            completion: completion
        )
    }

    private func sendFirmwareFingerprintRequest(
        _ request: HIDPP20LongMessage,
        stage: MXErgoFirmwareFingerprintStage,
        feature: HIDPP20FeatureDescriptor?,
        deviceInfo: HIDPP20DeviceInfo?,
        entities: [HIDPP20FirmwareEntity],
        deviceID: String,
        device: IOHIDDevice,
        completion: @escaping MXErgoObserver.FirmwareFingerprintCompletion
    ) {
        let epoch = rootQueryCorrelator.connectionEpoch
        let requestID: UUID
        do {
            requestID = try rootQueryCorrelator.register(
                request,
                connectionEpoch: epoch
            )
        } catch {
            completion(.rejected(.requestRegistrationFailed))
            return
        }

        pendingFirmwareFingerprint = PendingFirmwareFingerprint(
            id: requestID,
            epoch: epoch,
            deviceID: deviceID,
            request: request,
            stage: stage,
            feature: feature,
            deviceInfo: deviceInfo,
            entities: entities,
            completion: completion
        )

        var bytes = request.bytes
        let byteCount = bytes.count
        let outputResult = bytes.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(HIDPP20LongMessage.reportID),
                baseAddress,
                byteCount
            )
        }

        guard outputResult == kIOReturnSuccess else {
            pendingFirmwareFingerprint = nil
            rootQueryCorrelator.cancelBeforeSend(id: requestID)
            completion(.outputFailed(
                stage: stage,
                requestBytes: request.bytes,
                code: outputResult
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + MXErgoFirmwareFingerprintDiscovery.timeout
        ) { [weak self] in
            self?.scheduleFirmwareFingerprintTimeout(id: requestID, epoch: epoch)
        }
    }

    private func scheduleFirmwareFingerprintTimeout(id: UUID, epoch: UInt64) {
        stateLock.lock()
        let loop = runLoop
        stateLock.unlock()
        guard let loop else { return }

        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.firmwareFingerprintTimedOut(id: id, epoch: epoch)
        }
        CFRunLoopWakeUp(loop)
    }

    private func firmwareFingerprintTimedOut(id: UUID, epoch: UInt64) {
        guard let pending = pendingFirmwareFingerprint,
              pending.id == id,
              pending.epoch == epoch else { return }

        pendingFirmwareFingerprint = nil
        rootQueryCorrelator.timeout(id: id, connectionEpoch: epoch)
        pending.completion(.timedOut(
            stage: pending.stage,
            requestBytes: pending.request.bytes
        ))
    }

    private func startReadOnlyControlEnumeration(
        completion: @escaping MXErgoObserver.ControlEnumerationCompletion
    ) {
        guard !controlEnumerationAttempted else {
            completion(.rejected(.alreadyAttempted))
            return
        }
        guard matchingDevices.count == 1,
              let entry = matchingDevices.first,
              let properties = matchingDeviceProperties[entry.key] else {
            completion(.rejected(.matchingDeviceCount(matchingDevices.count)))
            return
        }
        guard outputCapabilitiesByDevice[entry.key, default: []]
            .contains(where: \.isHIDPP20LongReport) else {
            completion(.rejected(.missingExpectedOutputReport))
            return
        }
        guard properties.serialNumber?.isEmpty == false || properties.locationID != nil else {
            completion(.rejected(.missingStableIdentity))
            return
        }
        guard let resolvedFeature,
              resolvedFeature.deviceID == entry.key,
              resolvedFeature.epoch == rootQueryCorrelator.connectionEpoch,
              resolvedFeature.descriptor.isSupported else {
            completion(.rejected(.featureNotResolvedForCurrentConnection))
            return
        }
        controlEnumerationAttempted = true

        let request: HIDPP20LongMessage
        do {
            request = try ReprogControlsV4.getCountRequest(
                featureIndex: resolvedFeature.descriptor.index,
                deviceIndex: MXErgoOneShotRootQuery.deviceIndex,
                softwareID: MXErgoOneShotRootQuery.softwareID
            )
        } catch {
            completion(.rejected(.requestRegistrationFailed))
            return
        }

        sendControlEnumerationRequest(
            request,
            stage: .controlCount,
            feature: resolvedFeature.descriptor,
            expectedControlCount: nil,
            controls: [],
            deviceID: entry.key,
            device: entry.value,
            completion: completion
        )
    }

    private func sendControlEnumerationRequest(
        _ request: HIDPP20LongMessage,
        stage: MXErgoControlEnumerationStage,
        feature: HIDPP20FeatureDescriptor,
        expectedControlCount: Int?,
        controls: [ReprogControlInfo],
        deviceID: String,
        device: IOHIDDevice,
        completion: @escaping MXErgoObserver.ControlEnumerationCompletion
    ) {
        let epoch = rootQueryCorrelator.connectionEpoch
        let requestID: UUID
        do {
            requestID = try rootQueryCorrelator.register(
                request,
                connectionEpoch: epoch
            )
        } catch {
            completion(.rejected(.requestRegistrationFailed))
            return
        }

        pendingControlEnumeration = PendingControlEnumeration(
            id: requestID,
            epoch: epoch,
            deviceID: deviceID,
            request: request,
            stage: stage,
            feature: feature,
            expectedControlCount: expectedControlCount,
            controls: controls,
            completion: completion
        )

        var bytes = request.bytes
        let byteCount = bytes.count
        let outputResult = bytes.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(HIDPP20LongMessage.reportID),
                baseAddress,
                byteCount
            )
        }

        guard outputResult == kIOReturnSuccess else {
            pendingControlEnumeration = nil
            rootQueryCorrelator.cancelBeforeSend(id: requestID)
            completion(.outputFailed(
                stage: stage,
                requestBytes: request.bytes,
                code: outputResult
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + MXErgoOneShotRootQuery.timeout
        ) { [weak self] in
            self?.scheduleControlEnumerationTimeout(id: requestID, epoch: epoch)
        }
    }

    private func scheduleControlEnumerationTimeout(id: UUID, epoch: UInt64) {
        stateLock.lock()
        let loop = runLoop
        stateLock.unlock()
        guard let loop else { return }

        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.controlEnumerationTimedOut(id: id, epoch: epoch)
        }
        CFRunLoopWakeUp(loop)
    }

    private func controlEnumerationTimedOut(id: UUID, epoch: UInt64) {
        guard let pending = pendingControlEnumeration,
              pending.id == id,
              pending.epoch == epoch else { return }

        pendingControlEnumeration = nil
        rootQueryCorrelator.timeout(id: id, connectionEpoch: epoch)
        pending.completion(.timedOut(
            stage: pending.stage,
            requestBytes: pending.request.bytes
        ))
    }

    private func startReadOnlyPrecisionPreflight(
        expectation: MXErgoPrecisionPreflightExpectation,
        completion: @escaping MXErgoObserver.PrecisionPreflightCompletion
    ) {
        guard !precisionPreflightAttempted else {
            completion(.rejected(.alreadyAttempted))
            return
        }
        guard matchingDevices.count == 1,
              let entry = matchingDevices.first,
              let properties = matchingDeviceProperties[entry.key] else {
            completion(.rejected(.matchingDeviceCount(matchingDevices.count)))
            return
        }
        guard outputCapabilitiesByDevice[entry.key, default: []]
            .contains(where: \.isHIDPP20LongReport) else {
            completion(.rejected(.missingExpectedOutputReport))
            return
        }
        guard properties.serialNumber?.isEmpty == false || properties.locationID != nil else {
            completion(.rejected(.missingStableIdentity))
            return
        }
        guard MXErgoReadOnlyPrecisionPreflight.matchesPhysicalDevice(
            properties,
            expectation: expectation
        ) else {
            completion(.rejected(.deviceIdentityMismatch))
            return
        }
        guard let resolvedFeature,
              resolvedFeature.deviceID == entry.key,
              resolvedFeature.epoch == rootQueryCorrelator.connectionEpoch,
              resolvedFeature.descriptor == expectation.feature else {
            completion(.rejected(.featureNotResolvedForCurrentConnection))
            return
        }
        precisionPreflightAttempted = true

        let request: HIDPP20LongMessage
        do {
            request = try MXErgoReadOnlyPrecisionPreflight.makeRequest(
                expectation: expectation
            )
        } catch {
            completion(.rejected(.requestRegistrationFailed))
            return
        }

        let epoch = rootQueryCorrelator.connectionEpoch
        let requestID: UUID
        do {
            requestID = try rootQueryCorrelator.register(
                request,
                connectionEpoch: epoch
            )
        } catch {
            completion(.rejected(.requestRegistrationFailed))
            return
        }

        pendingPrecisionPreflight = PendingPrecisionPreflight(
            id: requestID,
            epoch: epoch,
            deviceID: entry.key,
            request: request,
            expectation: expectation,
            completion: completion
        )

        var bytes = request.bytes
        let byteCount = bytes.count
        let outputResult = bytes.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(
                entry.value,
                kIOHIDReportTypeOutput,
                CFIndex(HIDPP20LongMessage.reportID),
                baseAddress,
                byteCount
            )
        }

        guard outputResult == kIOReturnSuccess else {
            pendingPrecisionPreflight = nil
            rootQueryCorrelator.cancelBeforeSend(id: requestID)
            completion(.outputFailed(
                requestBytes: request.bytes,
                code: outputResult
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + MXErgoReadOnlyPrecisionPreflight.timeout
        ) { [weak self] in
            self?.schedulePrecisionPreflightTimeout(id: requestID, epoch: epoch)
        }
    }

    private func schedulePrecisionPreflightTimeout(id: UUID, epoch: UInt64) {
        stateLock.lock()
        let loop = runLoop
        stateLock.unlock()
        guard let loop else { return }

        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.precisionPreflightTimedOut(id: id, epoch: epoch)
        }
        CFRunLoopWakeUp(loop)
    }

    private func precisionPreflightTimedOut(id: UUID, epoch: UInt64) {
        guard let pending = pendingPrecisionPreflight,
              pending.id == id,
              pending.epoch == epoch else { return }

        pendingPrecisionPreflight = nil
        rootQueryCorrelator.timeout(id: id, connectionEpoch: epoch)
        pending.completion(.timedOut(requestBytes: pending.request.bytes))
    }

    private func startReadOnlyMappedControlPreflight(
        expectation: MXErgoMappedControlPreflightExpectation,
        completion: @escaping MXErgoObserver.MappedControlPreflightCompletion
    ) {
        guard !mappedControlPreflightAttempted else {
            completion(.rejected(.alreadyAttempted))
            return
        }
        guard matchingDevices.count == 1,
              let entry = matchingDevices.first,
              let properties = matchingDeviceProperties[entry.key] else {
            completion(.rejected(.matchingDeviceCount(matchingDevices.count)))
            return
        }
        guard outputCapabilitiesByDevice[entry.key, default: []]
            .contains(where: \.isHIDPP20LongReport) else {
            completion(.rejected(.missingExpectedOutputReport))
            return
        }
        guard properties.serialNumber?.isEmpty == false || properties.locationID != nil else {
            completion(.rejected(.missingStableIdentity))
            return
        }
        guard MXErgoReadOnlyMappedControlPreflight.matchesPhysicalDevice(
            properties,
            expectation: expectation
        ) else {
            completion(.rejected(.deviceIdentityMismatch))
            return
        }
        guard let resolvedFeature,
              resolvedFeature.deviceID == entry.key,
              resolvedFeature.epoch == rootQueryCorrelator.connectionEpoch,
              resolvedFeature.descriptor == expectation.feature else {
            completion(.rejected(.featureNotResolvedForCurrentConnection))
            return
        }
        mappedControlPreflightAttempted = true
        let sequence = MappedControlReadOnlyPreflightSequence(plan: expectation.plan)
        sendMappedControlPreflightRequest(
            sequence: sequence,
            expectation: expectation,
            deviceID: entry.key,
            device: entry.value,
            completion: completion
        )
    }

    private func sendMappedControlPreflightRequest(
        sequence: MappedControlReadOnlyPreflightSequence,
        expectation: MXErgoMappedControlPreflightExpectation,
        deviceID: String,
        device: IOHIDDevice,
        completion: @escaping MXErgoObserver.MappedControlPreflightCompletion
    ) {
        let request: HIDPP20LongMessage
        do {
            request = try sequence.nextRequest()
        } catch {
            completion(.rejected(.requestRegistrationFailed))
            return
        }
        let controlID = sequence.currentControlID ?? 0
        let epoch = rootQueryCorrelator.connectionEpoch
        let requestID: UUID
        do {
            requestID = try rootQueryCorrelator.register(
                request,
                connectionEpoch: epoch
            )
        } catch {
            completion(.rejected(.requestRegistrationFailed))
            return
        }

        pendingMappedControlPreflight = PendingMappedControlPreflight(
            id: requestID,
            epoch: epoch,
            deviceID: deviceID,
            request: request,
            sequence: sequence,
            expectation: expectation,
            completion: completion
        )

        var bytes = request.bytes
        let byteCount = bytes.count
        let outputResult = bytes.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(HIDPP20LongMessage.reportID),
                baseAddress,
                byteCount
            )
        }

        guard outputResult == kIOReturnSuccess else {
            pendingMappedControlPreflight = nil
            rootQueryCorrelator.cancelBeforeSend(id: requestID)
            completion(.outputFailed(
                controlID: controlID,
                requestBytes: request.bytes,
                code: outputResult
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + MXErgoReadOnlyMappedControlPreflight.timeout
        ) { [weak self] in
            self?.scheduleMappedControlPreflightTimeout(id: requestID, epoch: epoch)
        }
    }

    private func scheduleMappedControlPreflightTimeout(id: UUID, epoch: UInt64) {
        stateLock.lock()
        let loop = runLoop
        stateLock.unlock()
        guard let loop else { return }

        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.mappedControlPreflightTimedOut(id: id, epoch: epoch)
        }
        CFRunLoopWakeUp(loop)
    }

    private func mappedControlPreflightTimedOut(id: UUID, epoch: UInt64) {
        guard let pending = pendingMappedControlPreflight,
              pending.id == id,
              pending.epoch == epoch else { return }

        pendingMappedControlPreflight = nil
        rootQueryCorrelator.timeout(id: id, connectionEpoch: epoch)
        pending.completion(.timedOut(
            controlID: pending.sequence.currentControlID ?? 0,
            requestBytes: pending.request.bytes
        ))
    }

    private func startReadOnlyReportingSnapshot(
        completion: @escaping MXErgoObserver.ReportingSnapshotCompletion
    ) {
        guard !reportingSnapshotAttempted else {
            completion(.rejected(.alreadyAttempted))
            return
        }
        guard matchingDevices.count == 1,
              let entry = matchingDevices.first,
              let properties = matchingDeviceProperties[entry.key] else {
            completion(.rejected(.matchingDeviceCount(matchingDevices.count)))
            return
        }
        guard outputCapabilitiesByDevice[entry.key, default: []]
            .contains(where: \.isHIDPP20LongReport) else {
            completion(.rejected(.missingExpectedOutputReport))
            return
        }
        guard properties.serialNumber?.isEmpty == false || properties.locationID != nil else {
            completion(.rejected(.missingStableIdentity))
            return
        }
        guard let resolvedFeature,
              resolvedFeature.deviceID == entry.key,
              resolvedFeature.epoch == rootQueryCorrelator.connectionEpoch,
              let metadata = enumeratedControlSnapshot,
              metadata.feature == resolvedFeature.descriptor,
              metadata.controls.count == metadata.expectedControlCount,
              let firstControl = metadata.controls.sorted(by: { $0.index < $1.index }).first else {
            completion(.rejected(.metadataNotEnumeratedForCurrentConnection))
            return
        }
        reportingSnapshotAttempted = true

        sendReportingSnapshotRequest(
            for: firstControl,
            metadata: metadata,
            completedControls: [],
            deviceID: entry.key,
            device: entry.value,
            completion: completion
        )
    }

    private func sendReportingSnapshotRequest(
        for control: ReprogControlInfo,
        metadata: MXErgoReadOnlyControlSnapshot,
        completedControls: [DeviceControlJournalEntry],
        deviceID: String,
        device: IOHIDDevice,
        completion: @escaping MXErgoObserver.ReportingSnapshotCompletion
    ) {
        let stage = MXErgoReportingSnapshotStage(
            index: control.index,
            controlID: control.controlID
        )
        let request: HIDPP20LongMessage
        do {
            request = try ReprogControlsV4.getReportingRequest(
                controlID: control.controlID,
                featureIndex: metadata.feature.index,
                deviceIndex: MXErgoOneShotRootQuery.deviceIndex,
                softwareID: MXErgoOneShotRootQuery.softwareID
            )
        } catch {
            completion(.rejected(.requestRegistrationFailed))
            return
        }

        let epoch = rootQueryCorrelator.connectionEpoch
        let requestID: UUID
        do {
            requestID = try rootQueryCorrelator.register(
                request,
                connectionEpoch: epoch
            )
        } catch {
            completion(.rejected(.requestRegistrationFailed))
            return
        }

        pendingReportingSnapshot = PendingReportingSnapshot(
            id: requestID,
            epoch: epoch,
            deviceID: deviceID,
            request: request,
            stage: stage,
            metadata: metadata,
            controls: completedControls,
            completion: completion
        )

        var bytes = request.bytes
        let byteCount = bytes.count
        let outputResult = bytes.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(HIDPP20LongMessage.reportID),
                baseAddress,
                byteCount
            )
        }

        guard outputResult == kIOReturnSuccess else {
            pendingReportingSnapshot = nil
            rootQueryCorrelator.cancelBeforeSend(id: requestID)
            completion(.outputFailed(
                stage: stage,
                requestBytes: request.bytes,
                code: outputResult
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + MXErgoOneShotRootQuery.timeout
        ) { [weak self] in
            self?.scheduleReportingSnapshotTimeout(id: requestID, epoch: epoch)
        }
    }

    private func scheduleReportingSnapshotTimeout(id: UUID, epoch: UInt64) {
        stateLock.lock()
        let loop = runLoop
        stateLock.unlock()
        guard let loop else { return }

        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.reportingSnapshotTimedOut(id: id, epoch: epoch)
        }
        CFRunLoopWakeUp(loop)
    }

    private func reportingSnapshotTimedOut(id: UUID, epoch: UInt64) {
        guard let pending = pendingReportingSnapshot,
              pending.id == id,
              pending.epoch == epoch else { return }

        pendingReportingSnapshot = nil
        rootQueryCorrelator.timeout(id: id, connectionEpoch: epoch)
        pending.completion(.timedOut(
            stage: pending.stage,
            requestBytes: pending.request.bytes
        ))
    }

    private func scheduleRootQueryTimeout(id: UUID, epoch: UInt64) {
        stateLock.lock()
        let loop = runLoop
        stateLock.unlock()
        guard let loop else { return }

        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.rootQueryTimedOut(id: id, epoch: epoch)
        }
        CFRunLoopWakeUp(loop)
    }

    private func rootQueryTimedOut(id: UUID, epoch: UInt64) {
        guard let pending = pendingRootQuery,
              pending.id == id,
              pending.epoch == epoch else { return }

        pendingRootQuery = nil
        rootQueryCorrelator.timeout(id: id, connectionEpoch: epoch)
        pending.completion(.timedOut(requestBytes: pending.request.bytes))
    }

    fileprivate func deviceMatched(_ device: IOHIDDevice, result: IOReturn) {
        guard result == kIOReturnSuccess else { return }
        let properties = HIDDevicePropertyDecoder.decode(device)
        guard properties.isMXErgo else { return }
        let capabilities = HIDReportCapabilityInspector.outputCapabilities(for: device)
        matchingDevices[properties.id] = device
        matchingDeviceProperties[properties.id] = properties
        outputCapabilitiesByDevice[properties.id] = capabilities
        handler(.connected(properties))
        handler(.outputReportCapabilities(
            deviceID: properties.id,
            capabilities: capabilities
        ))
    }

    fileprivate func deviceRemoved(_ device: IOHIDDevice) {
        let properties = HIDDevicePropertyDecoder.decode(device)
        matchingDevices.removeValue(forKey: properties.id)
        matchingDeviceProperties.removeValue(forKey: properties.id)
        outputCapabilitiesByDevice.removeValue(forKey: properties.id)
        resolvedFeature = nil
        enumeratedControlSnapshot = nil

        if let pending = pendingRootQuery {
            pendingRootQuery = nil
            pending.completion(.disconnected(requestBytes: pending.request.bytes))
        }
        if let pending = pendingControlEnumeration {
            pendingControlEnumeration = nil
            pending.completion(.disconnected(
                stage: pending.stage,
                requestBytes: pending.request.bytes
            ))
        }
        if let pending = pendingReportingSnapshot {
            pendingReportingSnapshot = nil
            pending.completion(.disconnected(
                stage: pending.stage,
                requestBytes: pending.request.bytes
            ))
        }
        if let pending = pendingFirmwareFingerprint {
            pendingFirmwareFingerprint = nil
            pending.completion(.disconnected(
                stage: pending.stage,
                requestBytes: pending.request.bytes
            ))
        }
        if let pending = pendingPrecisionPreflight {
            pendingPrecisionPreflight = nil
            pending.completion(.disconnected(requestBytes: pending.request.bytes))
        }
        if let pending = pendingMappedControlPreflight {
            pendingMappedControlPreflight = nil
            pending.completion(.disconnected(
                controlID: pending.sequence.currentControlID ?? 0,
                requestBytes: pending.request.bytes
            ))
        }
        rootQueryCorrelator.disconnected()
        handler(.disconnected(deviceID: properties.id))
    }

    fileprivate func receivedReport(
        result: IOReturn,
        sourceDevice: IOHIDDevice?,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>,
        length: CFIndex
    ) {
        guard result == kIOReturnSuccess, length >= 0 else { return }
        reportCount &+= 1

        let previewLength = min(Int(length), 20)
        let preview = Array(UnsafeBufferPointer(start: report, count: previewLength))
        let snapshot = HIDReportSnapshot(
            count: reportCount,
            reportID: reportID,
            length: Int(length),
            preview: preview
        )

        // Correlate the raw report before any presentation-rate throttling.
        if let pending = pendingRootQuery,
           let sourceDevice,
           HIDDevicePropertyDecoder.decode(sourceDevice).id == pending.deviceID,
           reportID == UInt32(HIDPP20LongMessage.reportID),
           preview.count == HIDPP20LongMessage.byteCount,
           let message = try? HIDPP20LongMessage(bytes: preview),
           let reply = rootQueryCorrelator.consume(
               message,
               connectionEpoch: rootQueryCorrelator.connectionEpoch
           ) {
            finishRootQuery(with: reply)
        }

        if let pending = pendingControlEnumeration,
           let sourceDevice,
           HIDDevicePropertyDecoder.decode(sourceDevice).id == pending.deviceID,
           reportID == UInt32(HIDPP20LongMessage.reportID),
           preview.count == HIDPP20LongMessage.byteCount,
           let message = try? HIDPP20LongMessage(bytes: preview),
           let reply = rootQueryCorrelator.consume(
               message,
               connectionEpoch: rootQueryCorrelator.connectionEpoch
           ) {
            finishControlEnumeration(with: reply)
        }

        if let pending = pendingReportingSnapshot,
           let sourceDevice,
           HIDDevicePropertyDecoder.decode(sourceDevice).id == pending.deviceID,
           reportID == UInt32(HIDPP20LongMessage.reportID),
           preview.count == HIDPP20LongMessage.byteCount,
           let message = try? HIDPP20LongMessage(bytes: preview),
           let reply = rootQueryCorrelator.consume(
               message,
               connectionEpoch: rootQueryCorrelator.connectionEpoch
           ) {
            finishReportingSnapshot(with: reply)
        }

        if let pending = pendingFirmwareFingerprint,
           let sourceDevice,
           HIDDevicePropertyDecoder.decode(sourceDevice).id == pending.deviceID,
           reportID == UInt32(HIDPP20LongMessage.reportID),
           preview.count == HIDPP20LongMessage.byteCount,
           let message = try? HIDPP20LongMessage(bytes: preview),
           let reply = rootQueryCorrelator.consume(
               message,
               connectionEpoch: rootQueryCorrelator.connectionEpoch
           ) {
            finishFirmwareFingerprint(with: reply)
        }

        if let pending = pendingPrecisionPreflight,
           let sourceDevice,
           HIDDevicePropertyDecoder.decode(sourceDevice).id == pending.deviceID,
           reportID == UInt32(HIDPP20LongMessage.reportID),
           preview.count == HIDPP20LongMessage.byteCount,
           let message = try? HIDPP20LongMessage(bytes: preview),
           let reply = rootQueryCorrelator.consume(
               message,
               connectionEpoch: rootQueryCorrelator.connectionEpoch
           ) {
            finishPrecisionPreflight(with: reply)
        }

        if let pending = pendingMappedControlPreflight,
           let sourceDevice,
           HIDDevicePropertyDecoder.decode(sourceDevice).id == pending.deviceID,
           reportID == UInt32(HIDPP20LongMessage.reportID),
           preview.count == HIDPP20LongMessage.byteCount,
           let message = try? HIDPP20LongMessage(bytes: preview),
           let reply = rootQueryCorrelator.consume(
               message,
               connectionEpoch: rootQueryCorrelator.connectionEpoch
           ) {
            finishMappedControlPreflight(with: reply)
        }

        var isStandardButtonTransition = false
        if let buttonMask = snapshot.standardMouseButtonMask {
            if let previousMask = lastStandardMouseButtonMask {
                isStandardButtonTransition = previousMask != buttonMask
            }
            lastStandardMouseButtonMask = buttonMask
        }

        let now = ProcessInfo.processInfo.systemUptime
        if reportID != 0x11, !isStandardButtonTransition {
            guard now - lastReportEmissionTime >= 0.1 else { return }
            lastReportEmissionTime = now
        }

        handler(.report(snapshot))
    }

    private func finishRootQuery(with reply: HIDPP20CorrelatedReply) {
        guard let pending = pendingRootQuery else { return }

        switch reply {
        case let .response(id, response):
            guard id == pending.id else { return }
            pendingRootQuery = nil
            do {
                let descriptor = try HIDPP20Root.decodeFeatureDescriptor(from: response)
                resolvedFeature = ResolvedFeature(
                    epoch: pending.epoch,
                    deviceID: pending.deviceID,
                    descriptor: descriptor
                )
                pending.completion(.success(
                    requestBytes: pending.request.bytes,
                    responseBytes: response.bytes,
                    descriptor: descriptor
                ))
            } catch {
                pending.completion(.malformedResponse(
                    requestBytes: pending.request.bytes,
                    responseBytes: response.bytes
                ))
            }

        case let .protocolError(id, error):
            guard id == pending.id else { return }
            pendingRootQuery = nil
            pending.completion(.protocolError(
                requestBytes: pending.request.bytes,
                responseBytes: error.rawMessageBytes,
                code: error.rawErrorCode
            ))
        }
    }

    private func finishFirmwareFingerprint(with reply: HIDPP20CorrelatedReply) {
        guard let pending = pendingFirmwareFingerprint else { return }

        switch reply {
        case let .response(id, response):
            guard id == pending.id else { return }
            pendingFirmwareFingerprint = nil
            consumeFirmwareFingerprintResponse(response, pending: pending)

        case let .protocolError(id, error):
            guard id == pending.id else { return }
            pendingFirmwareFingerprint = nil
            pending.completion(.protocolError(
                stage: pending.stage,
                requestBytes: pending.request.bytes,
                responseBytes: error.rawMessageBytes,
                code: error.rawErrorCode
            ))
        }
    }

    private func consumeFirmwareFingerprintResponse(
        _ response: HIDPP20LongMessage,
        pending: PendingFirmwareFingerprint
    ) {
        do {
            switch pending.stage {
            case .featureResolution:
                let feature = try HIDPP20Root.decodeFeatureDescriptor(from: response)
                guard feature.isSupported else {
                    pending.completion(.unsupportedFeature(
                        requestBytes: pending.request.bytes,
                        responseBytes: response.bytes
                    ))
                    return
                }
                try continueFirmwareFingerprint(
                    request: HIDPP20DeviceInformation.getDeviceInfoRequest(
                        featureIndex: feature.index,
                        deviceIndex: MXErgoFirmwareFingerprintDiscovery.deviceIndex,
                        softwareID: MXErgoFirmwareFingerprintDiscovery.softwareID
                    ),
                    stage: .deviceInformation,
                    feature: feature,
                    deviceInfo: nil,
                    entities: [],
                    pending: pending
                )

            case .deviceInformation:
                guard let feature = pending.feature else {
                    throw HIDPP20CodecError.unexpectedResponse
                }
                let info = try HIDPP20DeviceInformation.decodeDeviceInfo(
                    from: response,
                    featureIndex: feature.index
                )
                try continueFirmwareFingerprint(
                    request: HIDPP20DeviceInformation.getFirmwareInfoRequest(
                        entityIndex: 0,
                        featureIndex: feature.index,
                        deviceIndex: MXErgoFirmwareFingerprintDiscovery.deviceIndex,
                        softwareID: MXErgoFirmwareFingerprintDiscovery.softwareID
                    ),
                    stage: .firmwareEntity(0),
                    feature: feature,
                    deviceInfo: info,
                    entities: [],
                    pending: pending
                )

            case let .firmwareEntity(index):
                guard let feature = pending.feature,
                      let info = pending.deviceInfo,
                      Int(index) == pending.entities.count,
                      index < info.entityCount else {
                    throw HIDPP20CodecError.unexpectedResponse
                }
                var entities = pending.entities
                entities.append(try HIDPP20DeviceInformation.decodeFirmwareInfo(
                    entityIndex: index,
                    from: response,
                    featureIndex: feature.index
                ))

                let nextIndex = Int(index) + 1
                if nextIndex == Int(info.entityCount) {
                    pending.completion(.success(try HIDPP20FirmwareFingerprint(
                        featureVersion: feature.version,
                        deviceInfo: info,
                        entities: entities
                    )))
                    return
                }
                let next = UInt8(nextIndex)
                try continueFirmwareFingerprint(
                    request: HIDPP20DeviceInformation.getFirmwareInfoRequest(
                        entityIndex: next,
                        featureIndex: feature.index,
                        deviceIndex: MXErgoFirmwareFingerprintDiscovery.deviceIndex,
                        softwareID: MXErgoFirmwareFingerprintDiscovery.softwareID
                    ),
                    stage: .firmwareEntity(next),
                    feature: feature,
                    deviceInfo: info,
                    entities: entities,
                    pending: pending
                )
            }
        } catch {
            pending.completion(.malformedResponse(
                stage: pending.stage,
                requestBytes: pending.request.bytes,
                responseBytes: response.bytes
            ))
        }
    }

    private func continueFirmwareFingerprint(
        request: HIDPP20LongMessage,
        stage: MXErgoFirmwareFingerprintStage,
        feature: HIDPP20FeatureDescriptor,
        deviceInfo: HIDPP20DeviceInfo?,
        entities: [HIDPP20FirmwareEntity],
        pending: PendingFirmwareFingerprint
    ) throws {
        guard let device = matchingDevices[pending.deviceID],
              rootQueryCorrelator.connectionEpoch == pending.epoch else {
            pending.completion(.disconnected(
                stage: pending.stage,
                requestBytes: pending.request.bytes
            ))
            return
        }
        sendFirmwareFingerprintRequest(
            request,
            stage: stage,
            feature: feature,
            deviceInfo: deviceInfo,
            entities: entities,
            deviceID: pending.deviceID,
            device: device,
            completion: pending.completion
        )
    }

    private func finishPrecisionPreflight(with reply: HIDPP20CorrelatedReply) {
        guard let pending = pendingPrecisionPreflight else { return }

        switch reply {
        case let .response(id, response):
            guard id == pending.id else { return }
            pendingPrecisionPreflight = nil
            do {
                let state = try MXErgoReadOnlyPrecisionPreflight.decodeResponse(
                    response,
                    expectation: pending.expectation
                )
                let session = RestoreOnlyHardwareTrialSession(
                    device: pending.expectation.device,
                    featureIndex: pending.expectation.feature.index,
                    featureVersion: pending.expectation.feature.version,
                    connectionEpoch: pending.epoch,
                    matchingDeviceCount: 1,
                    outputReportByteCount: HIDPP20LongMessage.byteCount
                )
                guard state == pending.expectation.baseline else {
                    pending.completion(.baselineMismatch(
                        requestBytes: pending.request.bytes,
                        responseBytes: response.bytes,
                        expected: pending.expectation.baseline,
                        actual: state,
                        session: session
                    ))
                    return
                }
                pending.completion(.success(MXErgoReadOnlyPrecisionPreflightSnapshot(
                    session: session,
                    requestBytes: pending.request.bytes,
                    responseBytes: response.bytes,
                    state: state
                )))
            } catch {
                pending.completion(.malformedResponse(
                    requestBytes: pending.request.bytes,
                    responseBytes: response.bytes
                ))
            }

        case let .protocolError(id, error):
            guard id == pending.id else { return }
            pendingPrecisionPreflight = nil
            pending.completion(.protocolError(
                requestBytes: pending.request.bytes,
                responseBytes: error.rawMessageBytes,
                code: error.rawErrorCode
            ))
        }
    }

    private func finishMappedControlPreflight(with reply: HIDPP20CorrelatedReply) {
        guard var pending = pendingMappedControlPreflight else { return }

        switch reply {
        case let .response(id, response):
            guard id == pending.id else { return }
            pendingMappedControlPreflight = nil
            do {
                _ = try pending.sequence.observe(response)
                if pending.sequence.isComplete {
                    pending.completion(.success(
                        MXErgoReadOnlyMappedControlPreflightSnapshot(
                            observations: pending.sequence.observations,
                            connectionEpoch: pending.epoch,
                            featureIndex: pending.expectation.plan.featureIndex,
                            featureVersion: pending.expectation.plan.featureVersion,
                            authorization: .notAuthorizedForExecution
                        )
                    ))
                    return
                }
                guard let device = matchingDevices[pending.deviceID],
                      rootQueryCorrelator.connectionEpoch == pending.epoch else {
                    pending.completion(.disconnected(
                        controlID: pending.sequence.currentControlID ?? 0,
                        requestBytes: pending.request.bytes
                    ))
                    return
                }
                sendMappedControlPreflightRequest(
                    sequence: pending.sequence,
                    expectation: pending.expectation,
                    deviceID: pending.deviceID,
                    device: device,
                    completion: pending.completion
                )
            } catch let MappedControlReadOnlyPreflightError.baselineMismatch(controlID) {
                guard let control = try? pending.expectation.plan.preflight(for: controlID),
                      let actual = try? control.decodeResponse(
                        response,
                        featureIndex: pending.expectation.plan.featureIndex,
                        featureVersion: pending.expectation.plan.featureVersion
                      ) else {
                    pending.completion(.malformedResponse(
                        controlID: controlID,
                        requestBytes: pending.request.bytes,
                        responseBytes: response.bytes
                    ))
                    return
                }
                pending.completion(.baselineMismatch(
                    controlID: controlID,
                    requestBytes: pending.request.bytes,
                    responseBytes: response.bytes,
                    expected: control.baseline,
                    actual: actual
                ))
            } catch {
                pending.completion(.malformedResponse(
                    controlID: pending.sequence.currentControlID ?? 0,
                    requestBytes: pending.request.bytes,
                    responseBytes: response.bytes
                ))
            }

        case let .protocolError(id, error):
            guard id == pending.id else { return }
            pendingMappedControlPreflight = nil
            pending.completion(.protocolError(
                controlID: pending.sequence.currentControlID ?? 0,
                requestBytes: pending.request.bytes,
                responseBytes: error.rawMessageBytes,
                code: error.rawErrorCode
            ))
        }
    }

    private func finishControlEnumeration(with reply: HIDPP20CorrelatedReply) {
        guard let pending = pendingControlEnumeration else { return }

        switch reply {
        case let .response(id, response):
            guard id == pending.id else { return }
            pendingControlEnumeration = nil
            consumeControlEnumerationResponse(response, pending: pending)

        case let .protocolError(id, error):
            guard id == pending.id else { return }
            pendingControlEnumeration = nil
            pending.completion(.protocolError(
                stage: pending.stage,
                requestBytes: pending.request.bytes,
                responseBytes: error.rawMessageBytes,
                code: error.rawErrorCode
            ))
        }
    }

    private func consumeControlEnumerationResponse(
        _ response: HIDPP20LongMessage,
        pending: PendingControlEnumeration
    ) {
        do {
            switch pending.stage {
            case .controlCount:
                let count = Int(try ReprogControlsV4.decodeCount(
                    from: response,
                    featureIndex: pending.feature.index
                ))
                try sendNextControlInfo(
                    index: 0,
                    expectedControlCount: count,
                    controls: [],
                    pending: pending
                )

            case let .controlInfo(index):
                var controls = pending.controls
                controls.append(try ReprogControlsV4.decodeControlInfo(
                    index: index,
                    from: response,
                    featureIndex: pending.feature.index
                ))

                guard let expectedControlCount = pending.expectedControlCount else {
                    throw HIDPP20CodecError.unexpectedResponse
                }
                let nextIndex = Int(index) + 1
                if nextIndex == expectedControlCount {
                    let snapshot = MXErgoReadOnlyControlSnapshot(
                        feature: pending.feature,
                        expectedControlCount: expectedControlCount,
                        controls: controls
                    )
                    enumeratedControlSnapshot = snapshot
                    pending.completion(.success(snapshot))
                } else {
                    try sendNextControlInfo(
                        index: UInt8(nextIndex),
                        expectedControlCount: expectedControlCount,
                        controls: controls,
                        pending: pending
                    )
                }
            }
        } catch {
            pending.completion(.malformedResponse(
                stage: pending.stage,
                requestBytes: pending.request.bytes,
                responseBytes: response.bytes
            ))
        }
    }

    private func sendNextControlInfo(
        index: UInt8,
        expectedControlCount: Int,
        controls: [ReprogControlInfo],
        pending: PendingControlEnumeration
    ) throws {
        guard let device = matchingDevices[pending.deviceID],
              rootQueryCorrelator.connectionEpoch == pending.epoch else {
            pending.completion(.disconnected(
                stage: pending.stage,
                requestBytes: pending.request.bytes
            ))
            return
        }

        let request = try ReprogControlsV4.getControlInfoRequest(
            index: index,
            featureIndex: pending.feature.index,
            deviceIndex: MXErgoOneShotRootQuery.deviceIndex,
            softwareID: MXErgoOneShotRootQuery.softwareID
        )
        sendControlEnumerationRequest(
            request,
            stage: .controlInfo(index: index),
            feature: pending.feature,
            expectedControlCount: expectedControlCount,
            controls: controls,
            deviceID: pending.deviceID,
            device: device,
            completion: pending.completion
        )
    }

    private func finishReportingSnapshot(with reply: HIDPP20CorrelatedReply) {
        guard let pending = pendingReportingSnapshot else { return }

        switch reply {
        case let .response(id, response):
            guard id == pending.id else { return }
            pendingReportingSnapshot = nil
            consumeReportingSnapshotResponse(response, pending: pending)

        case let .protocolError(id, error):
            guard id == pending.id else { return }
            pendingReportingSnapshot = nil
            pending.completion(.protocolError(
                stage: pending.stage,
                requestBytes: pending.request.bytes,
                responseBytes: error.rawMessageBytes,
                code: error.rawErrorCode
            ))
        }
    }

    private func consumeReportingSnapshotResponse(
        _ response: HIDPP20LongMessage,
        pending: PendingReportingSnapshot
    ) {
        do {
            let orderedMetadata = pending.metadata.controls.sorted { $0.index < $1.index }
            guard pending.controls.count < orderedMetadata.count else {
                throw HIDPP20CodecError.unexpectedResponse
            }
            let controlInfo = orderedMetadata[pending.controls.count]
            guard controlInfo.index == pending.stage.index,
                  controlInfo.controlID == pending.stage.controlID else {
                throw HIDPP20CodecError.unexpectedResponse
            }

            let reporting = try ReprogControlsV4.decodeReporting(
                requestedControlID: controlInfo.controlID,
                from: response,
                featureIndex: pending.metadata.feature.index,
                featureVersion: pending.metadata.feature.version
            )
            var completedControls = pending.controls
            completedControls.append(try DeviceControlJournalEntry(
                controlInfo: controlInfo,
                baselineReporting: reporting
            ))

            if completedControls.count == pending.metadata.expectedControlCount {
                pending.completion(.success(MXErgoReadOnlyReportingSnapshot(
                    feature: pending.metadata.feature,
                    expectedControlCount: pending.metadata.expectedControlCount,
                    controls: completedControls
                )))
                return
            }

            guard completedControls.count < orderedMetadata.count,
                  let device = matchingDevices[pending.deviceID],
                  rootQueryCorrelator.connectionEpoch == pending.epoch else {
                pending.completion(.disconnected(
                    stage: pending.stage,
                    requestBytes: pending.request.bytes
                ))
                return
            }
            sendReportingSnapshotRequest(
                for: orderedMetadata[completedControls.count],
                metadata: pending.metadata,
                completedControls: completedControls,
                deviceID: pending.deviceID,
                device: device,
                completion: pending.completion
            )
        } catch {
            pending.completion(.malformedResponse(
                stage: pending.stage,
                requestBytes: pending.request.bytes,
                responseBytes: response.bytes
            ))
        }
    }

    fileprivate func receivedValue(result: IOReturn, value: IOHIDValue) {
        guard result == kIOReturnSuccess else { return }
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let integerValue = IOHIDValueGetIntegerValue(value)
        if let horizontal = HIDElementValueDecoder.horizontalScrollNotches(
            usagePage: usagePage,
            usage: usage,
            integerValue: integerValue
        ) {
            handler(.horizontalScroll(notches: horizontal))
            return
        }
        guard let notches = HIDElementValueDecoder.verticalScrollNotches(
            usagePage: IOHIDElementGetUsagePage(element),
            usage: IOHIDElementGetUsage(element),
            integerValue: IOHIDValueGetIntegerValue(value)
        ) else {
            return
        }
        handler(.verticalScroll(notches: notches))
    }
}

private let deviceMatchedCallback: IOHIDDeviceCallback = { context, result, _, device in
    guard let context else { return }
    Unmanaged<InputLoop>.fromOpaque(context).takeUnretainedValue().deviceMatched(device, result: result)
}

private let deviceRemovedCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    Unmanaged<InputLoop>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
}

private let inputReportCallback: IOHIDReportCallback = { context, result, sender, _, reportID, report, reportLength in
    guard let context else { return }
    let sourceDevice = sender.map {
        Unmanaged<IOHIDDevice>.fromOpaque($0).takeUnretainedValue()
    }
    Unmanaged<InputLoop>.fromOpaque(context).takeUnretainedValue().receivedReport(
        result: result,
        sourceDevice: sourceDevice,
        reportID: reportID,
        report: report,
        length: reportLength
    )
}

private let inputValueCallback: IOHIDValueCallback = { context, result, _, value in
    guard let context else { return }
    Unmanaged<InputLoop>.fromOpaque(context).takeUnretainedValue().receivedValue(
        result: result,
        value: value
    )
}
