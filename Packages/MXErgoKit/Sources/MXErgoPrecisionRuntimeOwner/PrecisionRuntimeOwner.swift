import Foundation
import MXErgoCore
import MXErgoHID
import MXErgoHIDPP
import MXErgoPrecisionRuntimeAdmission
import MXErgoPrecisionRuntimeHostHandoff
import MXErgoPrecisionRuntimeLifecycle
import MXErgoPrecisionTransport

public struct PrecisionRuntimeOwnerEvidence: Sendable, Equatable {
    public let session: DeviceTransactionSession
    public let rootGeneration: UInt64

    public init(session: DeviceTransactionSession, rootGeneration: UInt64) {
        self.session = session
        self.rootGeneration = rootGeneration
    }
}

public enum PrecisionRuntimeOwnerError: Error, Sendable, Equatable {
    case observerNotRunning
    case observerRunMismatch(expectedRunID: UUID, actualRunID: UUID?)
    case restartFenceUnavailable
    case stillOwningRuntime
    case alreadyReleased
    case alreadyAdmitted
    case notBound
    case notAdmitted
    case invalidReadiness
    case invalidIntent
    case explicitConfirmationRequired
    case authorizationExpired
    case admissionFailed
    case recoverLockedAfterAmbiguousSET
}

public enum PrecisionRuntimeOwnerPhase: Sendable, Equatable {
    case bound
    case admitted
    case shutDown
    case released
}

/// Production-facing diversion status. Disconnect while active is classified
/// as recovery-required and never auto-retries or inverse-SETs.
public enum PrecisionRuntimeOwnerDiversionStatus: Sendable, Equatable {
    case bound
    case active
    case restored
    case recoveryRequired
    case shutDown(recoveryRequired: Bool)
    case released
}

/// Public executable façade over the dormant Precision lifecycle owner.
/// Bind installs the restart fence. Confirming admission stops that observer
/// run and opens the Precision runtime. Confirming deactivation restores
/// Precision. Quit never releases the fence. Diverted Precision notifications
/// are resolved into controller intents while admitted.
public actor PrecisionRuntimeOwner {
    public let launchID: UUID
    public let observerRunID: UUID
    private let intent: PrecisionRuntimeAdmissionIntent
    private let lifecycle: PrecisionRuntimeLifecycle
    /// Diverted notifications and wheel notches reach this synchronously, in
    /// arrival order. Per-input tasks could run a release before its press.
    private nonisolated let input: PrecisionInputSequencer
    private var diversionStatusHandler:
        (@Sendable (PrecisionRuntimeOwnerDiversionStatus) -> Void)?
    private var deviceDisconnected = false
    private var quitRequested = false
    private var recoverLockedAfterAmbiguousSET = false
    private let disconnectWitness: PrecisionRuntimeDisconnectWitness
    public nonisolated let precisionHeld: PrecisionHeldFlag

    nonisolated public static func bind(
        observer: MXErgoObserver,
        launchID: UUID,
        readiness: PrecisionTemporaryDiversionReadinessSnapshot,
        session: DeviceTransactionSession,
        rootGeneration: UInt64,
        sourceBaselineURL: URL,
        runtimeJournalURL: URL,
        resumeVerifiedSession: Bool = false,
        evidenceProvider: @escaping @Sendable () async throws
            -> PrecisionRuntimeOwnerEvidence
    ) throws -> PrecisionRuntimeOwner {
        guard readiness.authorization == .notAuthorizedForExecution else {
            throw PrecisionRuntimeOwnerError.invalidReadiness
        }
        guard let capturedRun = observer.captureHandoffRun() else {
            throw PrecisionRuntimeOwnerError.observerNotRunning
        }
        let intent: PrecisionRuntimeAdmissionIntent
        do {
            intent = try PrecisionRuntimeAdmissionReview.makeIntent(
                launchID: launchID,
                observerRunID: capturedRun.runID,
                operation: resumeVerifiedSession ? .resume : nil,
                readiness: readiness,
                session: session,
                rootGeneration: rootGeneration,
                sourceBaselineURL: sourceBaselineURL,
                runtimeJournalURL: runtimeJournalURL,
                expiresAtUptimeNanoseconds: DispatchTime.now()
                    .uptimeNanoseconds &+ Self.authorizationLifetimeNanoseconds
            )
        } catch {
            throw PrecisionRuntimeOwnerError.invalidIntent
        }
        let lifecycle: PrecisionRuntimeLifecycle
        do {
            lifecycle = try PrecisionRuntimeLifecycle.bind(
                observer: observer,
                intent: intent,
                evidenceProvider: {
                    let evidence = try await evidenceProvider()
                    return PrecisionRuntimeObserverHostEvidence(
                        session: evidence.session,
                        rootGeneration: evidence.rootGeneration
                    )
                }
            )
        } catch let error as PrecisionRuntimeLifecycleError {
            throw mapped(error)
        }
        return PrecisionRuntimeOwner(
            launchID: launchID,
            observerRunID: capturedRun.runID,
            intent: intent,
            lifecycle: lifecycle
        )
    }

    init(
        launchID: UUID,
        observerRunID: UUID,
        intent: PrecisionRuntimeAdmissionIntent,
        lifecycle: PrecisionRuntimeLifecycle,
        disconnectWitness: PrecisionRuntimeDisconnectWitness = .init()
    ) {
        self.launchID = launchID
        self.observerRunID = observerRunID
        self.intent = intent
        self.lifecycle = lifecycle
        self.disconnectWitness = disconnectWitness
        input = PrecisionInputSequencer(featureIndex: intent.session.featureIndex)
        precisionHeld = input.held
    }

    public func setControlEventHandler(
        _ handler: (@Sendable (ControllerIntent) -> Void)?
    ) {
        guard !quitRequested else { return }
        input.setIntentHandler(handler)
    }

    public func setDiversionStatusHandler(
        _ handler: (@Sendable (PrecisionRuntimeOwnerDiversionStatus) -> Void)?
    ) {
        guard !quitRequested else { return }
        diversionStatusHandler = handler
    }

    public var deviceWasDisconnected: Bool { deviceDisconnected }

    public var boundOperation: PrecisionTemporaryDiversionOperation {
        intent.operation
    }

    public var isRecoverLockedAfterAmbiguousSET: Bool {
        recoverLockedAfterAmbiguousSET
    }

    func lockRecoverAfterAmbiguousSET() {
        recoverLockedAfterAmbiguousSET = true
    }

    public var diversionStatus: PrecisionRuntimeOwnerDiversionStatus {
        get async { await currentDiversionStatus() }
    }

    /// Read-only evidence about what the input path received. Returns nil
    /// before admission, when there is no runtime to ask.
    /// Attended GET-only measurement. This does not establish native mode or
    /// authorize changing tracking speed. Each admitted runtime can inspect once.
    public func inspectPointerScaling() async throws -> PrecisionPointerScalingObservation {
        guard !quitRequested, !deviceDisconnected else { throw PrecisionRuntimeOwnerError.notAdmitted }
        do {
            let observation = try await lifecycle.inspectPointerScaling()
            guard !quitRequested, !deviceDisconnected else { throw PrecisionRuntimeOwnerError.notAdmitted }
            return observation
        } catch {
            input.reset()
            await publishDiversionStatus()
            throw error
        }
    }

    public func inputDiagnostics() async -> PrecisionInputDiagnosticsSnapshot? {
        guard let diagnostics = await lifecycle.inputDiagnostics() else {
            return nil
        }
        return PrecisionInputDiagnosticsSnapshot(diagnostics)
    }

    public var phase: PrecisionRuntimeOwnerPhase {
        get async {
            switch await lifecycle.phase {
            case .bound:
                return .bound
            case .admitted:
                return .admitted
            case .shutDown:
                return .shutDown
            case .released:
                return .released
            }
        }
    }

    public var blocksObserverRestart: Bool {
        get async {
            await lifecycle.phase != .released
        }
    }

    /// Stops the captured observer through host handoff and opens the Precision
    /// runtime. The bind-time intent's operation is activate. Requires a fresh
    /// explicit confirmation; this path can send a live SET.
    public func confirmAdmission(
        explicitlyConfirmed: Bool,
        competitorProbe: @escaping @Sendable () throws -> [String],
        sessionProvider: @escaping @Sendable () async throws
            -> DeviceTransactionSession,
        rootGenerationProvider: @escaping @Sendable () async throws -> UInt64
    ) async throws {
        try await confirmAdmission(
            explicitlyConfirmed: explicitlyConfirmed,
            competitorProbe: competitorProbe,
            sessionProvider: sessionProvider,
            rootGenerationProvider: rootGenerationProvider,
            nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    func confirmAdmission(
        explicitlyConfirmed: Bool,
        competitorProbe: @escaping @Sendable () throws -> [String],
        sessionProvider: @escaping @Sendable () async throws
            -> DeviceTransactionSession,
        rootGenerationProvider: @escaping @Sendable () async throws -> UInt64,
        nowUptimeNanoseconds: UInt64
    ) async throws {
        guard intent.operation == .activate else {
            throw PrecisionRuntimeOwnerError.invalidIntent
        }
        try await confirmBoundAdmission(
            explicitlyConfirmed: explicitlyConfirmed,
            competitorProbe: competitorProbe,
            sessionProvider: sessionProvider,
            rootGenerationProvider: rootGenerationProvider,
            nowUptimeNanoseconds: nowUptimeNanoseconds
        )
    }

    /// Reattaches with a fresh GET only. Baseline or conflict results never
    /// enable Precision and never fall back to activate or recover.
    public func confirmVerifiedResume(
        explicitlyConfirmed: Bool,
        competitorProbe: @escaping @Sendable () throws -> [String],
        sessionProvider: @escaping @Sendable () async throws -> DeviceTransactionSession,
        rootGenerationProvider: @escaping @Sendable () async throws -> UInt64
    ) async throws {
        guard intent.operation == .resume else {
            throw PrecisionRuntimeOwnerError.invalidIntent
        }
        try await confirmBoundAdmission(
            explicitlyConfirmed: explicitlyConfirmed,
            competitorProbe: competitorProbe,
            sessionProvider: sessionProvider,
            rootGenerationProvider: rootGenerationProvider,
            nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    /// Stops the captured observer and runs explicit Precision recover on a
    /// new connection. Requires a recover-bound owner and a fresh confirmation.
    /// This path can send one restore SET; it never auto-retries.
    public func confirmRecovery(
        explicitlyConfirmed: Bool,
        competitorProbe: @escaping @Sendable () throws -> [String],
        sessionProvider: @escaping @Sendable () async throws
            -> DeviceTransactionSession,
        rootGenerationProvider: @escaping @Sendable () async throws -> UInt64
    ) async throws {
        try await confirmRecovery(
            explicitlyConfirmed: explicitlyConfirmed,
            competitorProbe: competitorProbe,
            sessionProvider: sessionProvider,
            rootGenerationProvider: rootGenerationProvider,
            nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    func confirmRecovery(
        explicitlyConfirmed: Bool,
        competitorProbe: @escaping @Sendable () throws -> [String],
        sessionProvider: @escaping @Sendable () async throws
            -> DeviceTransactionSession,
        rootGenerationProvider: @escaping @Sendable () async throws -> UInt64,
        nowUptimeNanoseconds: UInt64
    ) async throws {
        guard intent.operation == .recover else {
            throw PrecisionRuntimeOwnerError.invalidIntent
        }
        guard !recoverLockedAfterAmbiguousSET else {
            throw PrecisionRuntimeOwnerError.recoverLockedAfterAmbiguousSET
        }
        try await confirmBoundAdmission(
            explicitlyConfirmed: explicitlyConfirmed,
            competitorProbe: competitorProbe,
            sessionProvider: sessionProvider,
            rootGenerationProvider: rootGenerationProvider,
            nowUptimeNanoseconds: nowUptimeNanoseconds
        )
    }

    /// Fresh one-use automatic admission from a revocable, bound preference.
    public func admitAutomatically(
        run: PrecisionAutomaticRestartRun,
        competitorProbe: @escaping @Sendable () throws -> [String],
        sessionProvider: @escaping @Sendable () async throws -> DeviceTransactionSession,
        rootGenerationProvider: @escaping @Sendable () async throws -> UInt64
    ) async throws {
        guard !quitRequested, await lifecycle.phase == .bound else { throw PrecisionRuntimeOwnerError.notBound }
        let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory.issueAutomatically(for: intent, permit: run.permit)
        try await admitBoundAuthorization(authorization, competitorProbe: competitorProbe,
            sessionProvider: sessionProvider, rootGenerationProvider: rootGenerationProvider)
    }

    /// Opens a freshly bound endpoint with the one-use GET-only authority
    /// minted by a completed pre-sleep rollover. This path cannot activate or
    /// recover and cannot carry a mutation permit into the transport.
    public func admitAfterWake(
        run: PrecisionWakeReconnectRun,
        competitorProbe: @escaping @Sendable () throws -> [String],
        sessionProvider: @escaping @Sendable () async throws -> DeviceTransactionSession,
        rootGenerationProvider: @escaping @Sendable () async throws -> UInt64
    ) async throws {
        guard !quitRequested, intent.operation == .resume,
              await lifecycle.phase == .bound else {
            throw PrecisionRuntimeOwnerError.notBound
        }
        let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory
            .issueWakeResume(for: intent, permit: run.permit)
        try await admitBoundAuthorization(
            authorization,
            competitorProbe: competitorProbe,
            sessionProvider: sessionProvider,
            rootGenerationProvider: rootGenerationProvider
        )
    }

    /// Only a verified baseline can release an admitted owner for fresh setup.
    public func releaseVerifiedRestoredSession() async throws {
        guard !quitRequested, !deviceDisconnected, await lifecycle.phase == .admitted,
              await lifecycle.admissionState == .restored else { throw PrecisionRuntimeOwnerError.stillOwningRuntime }
        input.reset()
        guard let report = await lifecycle.shutdown(), report.disposition == .clean(.restored),
              report.deviceCloseReturn == 0 else { throw PrecisionRuntimeOwnerError.stillOwningRuntime }
        guard try await lifecycle.releaseObserverRestartFence() else {
            throw PrecisionRuntimeOwnerError.restartFenceUnavailable
        }
        await publishDiversionStatus()
    }

    /// Ordered active rollover for Mac sleep. The durable state deliberately
    /// remains active/recovery-required; only exact unchanged evidence, a zero
    /// close result, and no synchronous disconnect witness may release the
    /// observer fence and mint one resume-only wake capability.
    public func prepareForSleepReconnect(
        automaticRun: PrecisionAutomaticRestartRun,
        sleepCycleID: UUID
    ) async throws -> PrecisionWakeReconnectRun {
        try automaticRun.validate()
        guard !quitRequested, !deviceDisconnected,
              !disconnectWitness.wasDisconnected,
              await lifecycle.phase == .admitted,
              await lifecycle.admissionState == .active else {
            throw PrecisionRuntimeOwnerError.stillOwningRuntime
        }
        let receipt: PrecisionRuntimeWakeResumeReceipt
        do {
            receipt = try PrecisionRuntimeAdmissionReview
                .captureWakeResumeReceipt(
                    for: intent,
                    sleepCycleID: sleepCycleID
                )
        } catch {
            throw PrecisionRuntimeOwnerError.invalidIntent
        }
        input.reset()
        guard let report = await lifecycle.shutdown(),
              report.disposition == .recoveryRequired(.active),
              report.deviceCloseReturn == 0,
              !deviceDisconnected,
              !disconnectWitness.wasDisconnected else {
            throw PrecisionRuntimeOwnerError.stillOwningRuntime
        }
        let wakePermit: PrecisionWakeResumePermit
        do {
            try automaticRun.validate()
            wakePermit = try PrecisionRuntimeAdmissionReview
                .makeWakeResumePermit(
                    from: receipt,
                    for: intent,
                    parent: automaticRun.permit,
                    disconnectWitness: disconnectWitness
                )
        } catch {
            throw PrecisionRuntimeOwnerError.invalidIntent
        }
        guard try await lifecycle.releaseObserverRestartFence() else {
            throw PrecisionRuntimeOwnerError.restartFenceUnavailable
        }
        do {
            try wakePermit.validate()
        } catch {
            throw PrecisionRuntimeOwnerError.invalidIntent
        }
        await publishDiversionStatus()
        return PrecisionWakeReconnectRun(permit: wakePermit)
    }

    private func confirmBoundAdmission(
        explicitlyConfirmed: Bool,
        competitorProbe: @escaping @Sendable () throws -> [String],
        sessionProvider: @escaping @Sendable () async throws
            -> DeviceTransactionSession,
        rootGenerationProvider: @escaping @Sendable () async throws -> UInt64,
        nowUptimeNanoseconds: UInt64
    ) async throws {
        guard !quitRequested else { throw PrecisionRuntimeOwnerError.notBound }
        guard explicitlyConfirmed else {
            throw PrecisionRuntimeOwnerError.explicitConfirmationRequired
        }
        switch await lifecycle.phase {
        case .bound:
            break
        case .admitted:
            throw PrecisionRuntimeOwnerError.alreadyAdmitted
        case .released:
            throw PrecisionRuntimeOwnerError.alreadyReleased
        case .shutDown:
            throw PrecisionRuntimeOwnerError.notBound
        }
        let authorization: PrecisionRuntimeAdmissionAuthorization
        do {
            authorization = try PrecisionRuntimeAdmissionAuthorizationFactory
                .issue(
                    for: intent,
                    explicitlyConfirmed: true,
                    nowUptimeNanoseconds: nowUptimeNanoseconds
                )
        } catch let error as PrecisionRuntimeAdmissionError {
            throw mappedAdmission(error)
        }
        try await admitBoundAuthorization(authorization, competitorProbe: competitorProbe,
            sessionProvider: sessionProvider, rootGenerationProvider: rootGenerationProvider)
    }

    private func admitBoundAuthorization(
        _ authorization: PrecisionRuntimeAdmissionAuthorization,
        competitorProbe: @escaping @Sendable () throws -> [String],
        sessionProvider: @escaping @Sendable () async throws -> DeviceTransactionSession,
        rootGenerationProvider: @escaping @Sendable () async throws -> UInt64
    ) async throws {
        do {
            try await lifecycle.admit(
                authorization: authorization,
                competitorProbe: competitorProbe,
                sessionProvider: sessionProvider,
                rootGenerationProvider: rootGenerationProvider,
                unsolicitedHIDPPHandler: { [input] bytes in
                    // On the IOHID callback queue, stamped at arrival.
                    input.receiveNotification(bytes, at: ProcessInfo.processInfo.systemUptime)
                },
                deviceDisconnectHandler: { [weak self, input] in
                    // Release suppression at removal, before the actor runs.
                    input.close()
                    Task { await self?.handleDeviceDisconnected() }
                },
                disconnectWitness: disconnectWitness
            )
            guard !quitRequested else { throw PrecisionRuntimeOwnerError.notBound }
            if deviceDisconnected {
                await handleDeviceDisconnected()
            }
            await publishDiversionStatus()
        } catch let error as PrecisionRuntimeLifecycleError {
            throw mapped(error)
        } catch {
            if intent.operation == .recover,
               journalHasAmbiguousRestoreSET(intent.runtimeJournalURL) {
                recoverLockedAfterAmbiguousSET = true
                await publishDiversionStatus()
                throw PrecisionRuntimeOwnerError.recoverLockedAfterAmbiguousSET
            }
            throw PrecisionRuntimeOwnerError.admissionFailed
        }
    }

    private func journalHasAmbiguousRestoreSET(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(
                DeviceTransactionEnvelope.self,
                from: data
              ) else {
            return false
        }
        return envelope.hasAmbiguousRestoreSET
    }

    /// Restores Precision through a subsequent authorized deactivate. Requires
    /// a fresh explicit confirmation; this path can send a live SET.
    public func confirmDeactivation(
        explicitlyConfirmed: Bool
    ) async throws {
        guard !quitRequested else { throw PrecisionRuntimeOwnerError.notBound }
        guard explicitlyConfirmed else {
            throw PrecisionRuntimeOwnerError.explicitConfirmationRequired
        }
        let nextIntent: PrecisionRuntimeAdmissionIntent
        do {
            nextIntent = try await lifecycle.reviewIntent(
                for: .deactivate,
                expiresAtUptimeNanoseconds: DispatchTime.now()
                    .uptimeNanoseconds &+ Self.authorizationLifetimeNanoseconds
            )
        } catch let error as PrecisionRuntimeLifecycleError {
            throw mapped(error)
        } catch {
            throw PrecisionRuntimeOwnerError.admissionFailed
        }
        let authorization: PrecisionRuntimeAdmissionAuthorization
        do {
            authorization = try PrecisionRuntimeAdmissionAuthorizationFactory
                .issue(
                    for: nextIntent,
                    explicitlyConfirmed: true
                )
        } catch let error as PrecisionRuntimeAdmissionError {
            throw mappedAdmission(error)
        }
        do {
            try await lifecycle.perform(
                nextIntent,
                authorization: authorization
            )
            input.reset()
            await publishDiversionStatus()
        } catch let error as PrecisionRuntimeLifecycleError {
            throw mapped(error)
        } catch {
            throw PrecisionRuntimeOwnerError.admissionFailed
        }
    }

    /// Quit path. Shuts down an admitted runtime if one exists and never
    /// releases the observer restart fence. It does not send an inverse SET.
    public func prepareForQuit() async {
        quitRequested = true
        input.close()
        diversionStatusHandler = nil
        _ = await lifecycle.shutdown()
        await publishDiversionStatus()
    }

    /// Called on the wheel observer thread with the notch's arrival time.
    /// Disconnect and quit close the sequencer, so late notches do nothing.
    public nonisolated func noteVerticalScroll(notches: Int, at timestamp: TimeInterval) {
        input.receiveVerticalScroll(notches: notches, at: timestamp)
    }

    nonisolated func deliverUnsolicitedHIDPP(
        _ bytes: [UInt8],
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        input.receiveNotification(bytes, at: timestamp)
    }

    /// Physical disconnect while diverted. Stops control-event delivery,
    /// shuts the runtime down without an inverse SET, and classifies
    /// recovery-required. Reconnect does not re-admit or retry.
    func handleDeviceDisconnected() async {
        let phase = await lifecycle.phase
        guard !deviceDisconnected || phase == .admitted else {
            return
        }
        deviceDisconnected = true
        input.close()
        _ = await lifecycle.shutdown()
        await publishDiversionStatus()
    }

    /// Session rollover. Allowed only when the runtime is not owning the
    /// device. Quit and abandonment must not call this.
    public func completeSessionRollover() async throws {
        do {
            _ = try await lifecycle.releaseObserverRestartFence()
            await publishDiversionStatus()
        } catch let error as PrecisionRuntimeLifecycleError {
            throw mapped(error)
        }
    }

    private func currentDiversionStatus() async -> PrecisionRuntimeOwnerDiversionStatus {
        switch await lifecycle.phase {
        case .bound:
            return .bound
        case .admitted:
            if deviceDisconnected { return .recoveryRequired }
            switch await lifecycle.admissionState {
            case .restored:
                return .restored
            case .recoveryRequired, .conflicted:
                return .recoveryRequired
            case .stopped:
                return .shutDown(
                    recoveryRequired: await lifecycle.shutdownRequiresRecovery
                )
            case .active, .inactive, .admitting, .stopping, .failed, .none:
                return .active
            }
        case .shutDown:
            if deviceDisconnected { return .recoveryRequired }
            return .shutDown(
                recoveryRequired: await lifecycle.shutdownRequiresRecovery
            )
        case .released:
            return .released
        }
    }

    private func publishDiversionStatus() async {
        let status = await currentDiversionStatus()
        guard !quitRequested else { return }
        diversionStatusHandler?(status)
    }
}

private func mapped(
    _ error: PrecisionRuntimeLifecycleError
) -> PrecisionRuntimeOwnerError {
    switch error {
    case .observerNotRunning:
        return .observerNotRunning
    case let .observerRunMismatch(expected, actual):
        return .observerRunMismatch(
            expectedRunID: expected,
            actualRunID: actual
        )
    case .restartFenceUnavailable:
        return .restartFenceUnavailable
    case .stillOwningRuntime:
        return .stillOwningRuntime
    case .alreadyReleased:
        return .alreadyReleased
    case .alreadyAdmitted:
        return .alreadyAdmitted
    case .notAdmitted:
        return .notAdmitted
    case .shuttingDown:
        return .notAdmitted
    case .invalidAuthorizationBinding:
        return .invalidIntent
    }
}

private func mappedAdmission(
    _ error: PrecisionRuntimeAdmissionError
) -> PrecisionRuntimeOwnerError {
    switch error {
    case .explicitConfirmationRequired:
        return .explicitConfirmationRequired
    case .authorizationExpired:
        return .authorizationExpired
    case .invalidAuthorizationBinding, .authorizationAlreadyConsumed:
        return .invalidIntent
    default:
        return .admissionFailed
    }
}

extension PrecisionRuntimeOwner {
    static let authorizationLifetimeNanoseconds: UInt64 = 600_000_000_000
}


/// Public projection of the runtime's input evidence.
///
/// The 2026-09-04 hardware session found that Precision diverted correctly and
/// yet produced no mute, no volume change, and no scroll suppression. Nothing
/// in the app could say whether the device had sent a diverted-control
/// notification that was refused, or had sent nothing at all — so the fix could
/// only have been guessed. These counts separate those cases.
public struct PrecisionInputDiagnosticsSnapshot: Sendable, Equatable {
    /// Frames from this device, on this connection, of the right report type
    /// and length — counted before any notification test.
    public let observedCount: Int
    /// The subset routed as HID++ notifications.
    public let unsolicitedCount: Int
    /// Frames matched to an outstanding request.
    public let acceptedCount: Int
    public let droppedCount: Int
    public let lastObservedFrameHex: String?
    /// Last notification carrying a payload — a press rather than a release.
    public let lastPressFrameHex: String?

    init(_ diagnostics: PrecisionInputDiagnostics) {
        observedCount = diagnostics.observedCount
        unsolicitedCount = diagnostics.unsolicitedCount
        acceptedCount = diagnostics.acceptedCount
        droppedCount = diagnostics.droppedCount
        lastObservedFrameHex = diagnostics.lastObservedFrameBytes.map { bytes in
            bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        lastPressFrameHex = diagnostics.lastPayloadNotificationBytes.map { bytes in
            bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }

    public var summary: String {
        "observed \(observedCount) · notifications \(unsolicitedCount) · "
            + "matched \(acceptedCount) · dropped \(droppedCount)"
    }

    /// States what the counts imply, so a hardware session ends with a
    /// conclusion rather than a table someone has to interpret later.
    public var interpretation: String {
        if observedCount == 0 {
            return "No input frame reached the runtime at all. The device sent nothing this connection accepted, so the notification filter is not implicated; look at diversion, the input callback registration, or whether the device reports diverted controls on this interface."
        }
        if unsolicitedCount == 0 {
            return "Frames reached the runtime but none was routed as a notification. The device is sending input this connection accepts while the unsolicited test rejects all of it. Compare the last observed frame's second byte against the device index the notification filter requires."
        }
        return "Notifications were routed. If no action followed, the fault is downstream of delivery: control-event decoding, intent resolution, or execution."
    }
}
