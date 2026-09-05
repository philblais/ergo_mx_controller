import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MXErgoCore
import MXErgoHID
import MXErgoHIDPP
import MXErgoPrecisionRuntimeOwner

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: ObserverStatus = .stopped
    @Published private(set) var devices: [HIDDeviceProperties] = []
    @Published private(set) var outputReportCapabilitiesByDevice: [String: [HIDOutputReportCapability]] = [:]
    @Published private(set) var inspectedOutputCapabilityDeviceIDs: Set<String> = []
    @Published private(set) var lastReport: HIDReportSnapshot?
    @Published private(set) var calibrationReports: [HIDReportSnapshot] = []
    @Published private(set) var lastIntent: ControllerIntent?
    @Published private(set) var wheelEventCount = 0
    @Published private(set) var lastWheelNotches: Int?
    @Published private(set) var tiltEventCount = 0
    @Published private(set) var lastTiltNotches: Int?
    @Published private(set) var audioExecutionEnabled = false
    @Published private(set) var audioStatus: AudioExecutionStatus = .disabled
    @Published private(set) var inputMonitoringGranted = CGPreflightListenEventAccess()
    /// Posting synthetic events needs Accessibility, a separate grant from
    /// Input Monitoring. Nothing in this build posts events yet; the gate
    /// exists so the requirement is visible before anything depends on it.
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    /// Scroll-axis diagnostics. They exist to settle one question the code
    /// cannot answer by reasoning: which sign of the horizontal CGEvent delta
    /// a *left* wheel tilt produces on this machine. Off after every launch,
    /// and they suppress nothing.
    @Published private(set) var scrollDiagnosticsEnabled = false
    @Published private(set) var scrollTapEventCount = 0
    @Published private(set) var lastScrollTapSample: ScrollTapSample?
    /// Kept separately so an ordinary vertical scroll cannot wipe the tilt
    /// sample the session is trying to read.
    @Published private(set) var lastHorizontalScrollTapSample: ScrollTapSample?
    /// Recorded with the sample: natural scrolling inverts scroll deltas, so a
    /// sign observed under one setting says nothing about the other.
    @Published private(set) var naturalScrollingEnabled =
        NaturalScrollDirection.isEnabled()
    @Published private(set) var recoveryJournalStatus = "No device changes recorded"
    @Published private(set) var recoveryJournalNeedsAttention = false
    @Published private(set) var recoveryJournalExists = false
    @Published private(set) var recoveryJournalUnreadable = false
    @Published private(set) var recoveryJournalFirmwareBound = false
    @Published private(set) var rootQueryInProgress = false
    @Published private(set) var rootQueryAttempted = false
    @Published private(set) var rootQueryStatusText = "Not sent"
    @Published private(set) var rootQueryResponseBytes: [UInt8]?
    @Published private(set) var rootQuerySucceeded = false
    @Published private(set) var firmwareFingerprintInProgress = false
    @Published private(set) var firmwareFingerprintAttempted = false
    @Published private(set) var firmwareFingerprintStatusText = "Not started"
    @Published private(set) var firmwareFingerprint: HIDPP20FirmwareFingerprint?
    @Published private(set) var firmwareMigrationDryRunAttempted = false
    @Published private(set) var firmwareMigrationDryRunStatusText = "Not run"
    @Published private(set) var firmwareMigrationPlan: FirmwareIdentityJournalMigrationPlan?
    @Published private(set) var firmwareMigrationCommitInProgress = false
    @Published private(set) var firmwareMigrationCommitAttempted = false
    @Published private(set) var firmwareMigrationCommitStatusText = "Not committed"
    @Published private(set) var firmwareMigrationCommitReceipt:
        FirmwareIdentityJournalMigrationCommitReceipt?
    @Published private(set) var restorePacketPreviewAttempted = false
    @Published private(set) var restorePacketPreviewStatusText = "Not built"
    @Published private(set) var restorePacketPlans: [RestoreOnlyReportingPlan] = []
    @Published private(set) var restoreTrialSimulationInProgress = false
    @Published private(set) var restoreTrialSimulationAttempted = false
    @Published private(set) var restoreTrialSimulationStatusText = "Not run"
    @Published private(set) var restoreTrialSimulationReport:
        RestoreOnlyHardwareTrialSimulationReport?
    @Published private(set) var precisionPreflightInProgress = false
    @Published private(set) var precisionPreflightAttempted = false
    @Published private(set) var precisionPreflightStatusText = "Not run"
    @Published private(set) var precisionPreflightSnapshot:
        MXErgoReadOnlyPrecisionPreflightSnapshot?
    @Published private(set) var precisionReadinessAttempted = false
    @Published private(set) var precisionReadinessStatusText = "Not reviewed"
    @Published private(set) var precisionReadinessSnapshot:
        PrecisionTemporaryDiversionReadinessSnapshot?
    @Published private(set) var mappedDiversionAttempted = false
    @Published private(set) var mappedDiversionStatusText = "Not reviewed"
    @Published private(set) var mappedDiversionSnapshot:
        MappedControlsTemporaryDiversionReadinessSnapshot?
    @Published private(set) var mappedActionPlan: MappedControlActionPlan?
    @Published private(set) var mappedEventDelivery: MappedControlEventDeliverySnapshot?
    @Published private(set) var mappedPreflightPlan: MappedControlsReadOnlyPreflightPlan?
    @Published private(set) var mappedLivePreflightInProgress = false
    @Published private(set) var mappedLivePreflightAttempted = false
    @Published private(set) var mappedLivePreflightStatusText = "Not run"
    @Published private(set) var mappedLivePreflightSnapshot:
        MXErgoReadOnlyMappedControlPreflightSnapshot?
    @Published private(set) var runtimeOwnerStatusText = "No dormant runtime owner"
    @Published private(set) var runtimeOwnerBlocksRestart = false
    /// Whether a dormant owner exists at all. The scroll diagnostics reuse the
    /// same wheel observer the owner takes, so the UI needs a published signal
    /// rather than reaching for the private reference.
    @Published private(set) var runtimeOwnerIsBound = false
    @Published private(set) var runtimeOwnerCanRollover = false
    @Published private(set) var runtimeOwnerBindInProgress = false
    @Published private(set) var runtimeOwnerCanAdmit = false
    @Published private(set) var runtimeOwnerCanRecover = false
    @Published private(set) var runtimeOwnerIsAdmitted = false
    /// True only while the control is genuinely diverted. A restored
    /// control still leaves the runtime admitted, so this is not the same
    /// thing as `runtimeOwnerIsAdmitted`.
    @Published private(set) var runtimeOwnerControlIsDiverted = false
    /// Set when a one-use authorization expired before it could be used.
    /// The bound intent's deadline is fixed at bind time, so retrying the
    /// same operation can never succeed; the owner must be re-bound.
    @Published private(set) var runtimeOwnerAuthorizationExpired = false
    @Published private(set) var journalRotationStatusText =
        "No completed runtime journal to retire"
    @Published private(set) var journalRotationSummary: String?
    @Published private(set) var journalRotationAvailable = false
    @Published private(set) var journalRotationInProgress = false
    @Published private(set) var inputDiagnosticsSummary: String?
    @Published private(set) var inputDiagnosticsInterpretation: String?
    @Published private(set) var inputDiagnosticsLastFrame: String?
    @Published private(set) var inputDiagnosticsLastPress: String?
    @Published private(set) var runtimeOwnerCanDeactivate = false
    @Published private(set) var runtimeOwnerNeedsRecovery = false
    @Published private(set) var runtimeOwnerDeviceDisconnected = false
    @Published private(set) var runtimeOwnerOperationInProgress = false
    @Published private(set) var controlEnumerationInProgress = false
    @Published private(set) var controlEnumerationAttempted = false
    @Published private(set) var controlEnumerationStatusText = "Not started"
    @Published private(set) var enumeratedControls: [ReprogControlInfo] = []
    @Published private(set) var reportingSnapshotInProgress = false
    @Published private(set) var reportingSnapshotAttempted = false
    @Published private(set) var reportingSnapshotStatusText = "Not started"
    @Published private(set) var baselineControls: [DeviceControlJournalEntry] = []
    @Published private(set) var recoveryRehearsalInProgress = false
    @Published private(set) var recoveryRehearsalAttempted = false
    @Published private(set) var recoveryRehearsalStatusText = "Not run"
    @Published private(set) var recoveryRehearsalSteps: [DeviceRecoveryRehearsalStep] = []
    @Published private(set) var transactionSimulationInProgress = false
    @Published private(set) var transactionSimulationAttempted = false
    @Published private(set) var transactionSimulationStatusText = "Not run"
    @Published private(set) var transactionSimulationReport: DeviceTransactionSimulationReport?

    let hidppProtocolFoundationReady = true
    let hidppDeviceOutputEnabled = true

    private let observer = MXErgoObserver()
    private let wheelObserver = MXErgoWheelObserver()
    private let launchID = UUID()
    private var runtimeOwner: PrecisionRuntimeOwner?
    private var runtimeOwnerSession: DeviceTransactionSession?
    private var runtimeOwnerRootGeneration: UInt64?
    private let journalStore = DeviceStateJournalStore(fileURL: AppModel.journalFileURL)
    private let firmwareMigrationRepository =
        DurableFirmwareIdentityJournalMigrationRepository(fileURL: AppModel.journalFileURL)
    private var calibrationReportBuffer = BoundedRingBuffer<HIDReportSnapshot>(capacity: 12)
    private var lastStandardMouseButtonMask: UInt8?
    private var intentResolver = ControllerIntentResolver()
    private var connectionGeneration: UInt64 = 0
    private var reprogFeatureDescriptor: HIDPP20FeatureDescriptor?
    private var rootEvidenceGeneration: UInt64?
    private var firmwareEvidenceGeneration: UInt64?
    private var precisionPreflightEvidenceGeneration: UInt64?
    private var firmwareMigrationPlanGeneration: UInt64?
    private var workspaceLaunchObserver: NSObjectProtocol?
    private var applicationActivateObserver: NSObjectProtocol?
    private var didBootstrap = false
    private var pendingObserverRestart = false
    private lazy var audioController = SmoothSystemAudioController { [weak self] status in
        Task { @MainActor [weak self] in
            self?.audioStatus = status
        }
    }

    init() {
        refreshRecoveryJournalStatus()
        workspaceLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.revalidatePrecisionReadinessCompetitors()
                self?.revalidateMappedControlDiversionCompetitors()
            }
        }
        applicationActivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissionStatus()
            }
        }
    }

    func bootstrapOnLaunch() {
        guard !didBootstrap else { return }
        didBootstrap = true
        requestInputMonitoringIfNeeded()
        refreshJournalRotationReview()
        start()
    }

    func start() {
        guard status == .stopped else { return }
        guard !runtimeOwnerBlocksRestart else {
            runtimeOwnerStatusText =
                "Observer restart is fenced until an explicit session rollover"
            return
        }
        pendingObserverRestart = false
        inputMonitoringGranted = CGPreflightListenEventAccess()
        observer.start { [weak self] observation in
            Task { @MainActor [weak self] in
                self?.receive(observation)
            }
        }
    }

    func stop() {
        pendingObserverRestart = false
        observer.stop()
        devices = []
        outputReportCapabilitiesByDevice = [:]
        inspectedOutputCapabilityDeviceIDs = []
        reprogFeatureDescriptor = nil
        rootEvidenceGeneration = nil
        invalidateRestorePacketPreview(reason: "Observer stopped; rebuild from fresh evidence")
        invalidatePrecisionPreflight(reason: "Observer stopped; relaunch before live preflight")
        invalidateFirmwareValidationEvidence(reason: "Observer stopped; relaunch before migration")
        lastReport = nil
        lastIntent = nil
        wheelEventCount = 0
        lastWheelNotches = nil
        lastTiltNotches = nil
        lastStandardMouseButtonMask = nil
        intentResolver = ControllerIntentResolver()
        if audioExecutionEnabled {
            setAudioExecutionEnabled(false)
        }
        clearCalibrationReports()
        status = .stopped
    }

    func clearCalibrationReports() {
        calibrationReportBuffer = BoundedRingBuffer(capacity: 12)
        calibrationReports = []
    }

    func refreshPermissionStatus() {
        let wasGranted = inputMonitoringGranted
        inputMonitoringGranted = CGPreflightListenEventAccess()
        accessibilityGranted = AXIsProcessTrusted()
        naturalScrollingEnabled = NaturalScrollDirection.isEnabled()
        refreshRecoveryJournalStatus()
        revalidatePrecisionReadinessEvidence()
        revalidateMappedControlDiversionEvidence()
        if inputMonitoringGranted, !wasGranted {
            restartObserverAfterPermissionGrant()
        }
    }

    func requestInputMonitoringIfNeeded() {
        if CGPreflightListenEventAccess() {
            inputMonitoringGranted = true
            return
        }
        inputMonitoringGranted = CGRequestListenEventAccess()
        guard inputMonitoringGranted else { return }
        restartObserverAfterPermissionGrant()
    }

    /// Runs the existing wheel tap in a non-suppressing mode so the raw scroll
    /// fields can be read.
    ///
    /// It reuses that tap rather than creating another: a third suppressing tap
    /// would be a new capability, and this needs no capability at all. The
    /// Precision runtime owns the same observer while admitted, so the two are
    /// kept mutually exclusive rather than allowed to race for it.
    func setScrollDiagnosticsEnabled(_ isEnabled: Bool) {
        guard scrollDiagnosticsGateFailureText == nil || !isEnabled else { return }
        scrollDiagnosticsEnabled = isEnabled
        guard isEnabled else {
            wheelObserver.stop()
            return
        }
        scrollTapEventCount = 0
        lastScrollTapSample = nil
        lastHorizontalScrollTapSample = nil
        naturalScrollingEnabled = NaturalScrollDirection.isEnabled()
        wheelObserver.stop()
        wheelObserver.start(
            handler: { _ in },
            shouldSuppressScroll: { false },
            scrollTapObserver: { [weak self] sample in
                Task { @MainActor in self?.record(scrollTapSample: sample) }
            }
        )
    }

    /// Nil when the toggle may be turned on.
    var scrollDiagnosticsGateFailureText: String? {
        if !accessibilityGranted {
            return "Grant Accessibility first; a scroll tap needs it"
        }
        if runtimeOwnerIsBound {
            return "Release the Precision runtime first; it owns the same tap"
        }
        return nil
    }

    private func record(scrollTapSample sample: ScrollTapSample) {
        guard scrollDiagnosticsEnabled else { return }
        scrollTapEventCount += 1
        lastScrollTapSample = sample
        if sample.isHorizontal {
            lastHorizontalScrollTapSample = sample
        }
    }

    func setAudioExecutionEnabled(_ isEnabled: Bool) {
        guard !rootQueryInProgress,
              !firmwareFingerprintInProgress,
              !controlEnumerationInProgress,
              !reportingSnapshotInProgress,
              !recoveryRehearsalInProgress,
              !transactionSimulationInProgress,
              !restoreTrialSimulationInProgress,
              !precisionPreflightInProgress,
              !mappedLivePreflightInProgress,
              !firmwareMigrationCommitInProgress else { return }
        audioExecutionEnabled = isEnabled
        if isEnabled {
            audioController.prepare()
        } else {
            audioController.cancelPendingVolumeChanges()
            audioStatus = .disabled
        }
    }

    func performOneShotRootQuery() {
        guard rootQueryGateFailureText == nil else { return }

        reprogFeatureDescriptor = nil
        rootEvidenceGeneration = nil
        invalidateRestorePacketPreview(reason: "Rebuild after the Root feature is resolved")
        rootQueryAttempted = true
        rootQueryInProgress = true
        rootQuerySucceeded = false
        rootQueryResponseBytes = nil
        rootQueryStatusText = "Waiting for the correlated Root response…"

        observer.performOneShotRootQuery { [weak self] result in
            Task { @MainActor [weak self] in
                self?.receive(rootQueryResult: result)
            }
        }
    }

    func performReadOnlyFirmwareFingerprint() {
        guard firmwareFingerprintGateFailureText == nil else { return }

        invalidateRestorePacketPreview(reason: "Rebuild after fresh firmware discovery")
        firmwareFingerprintAttempted = true
        firmwareFingerprintInProgress = true
        firmwareFingerprint = nil
        firmwareFingerprintStatusText = "Resolving Device Information 0x0003…"

        observer.performReadOnlyFirmwareFingerprint { [weak self] result in
            Task { @MainActor [weak self] in
                self?.receive(firmwareFingerprintResult: result)
            }
        }
    }

    func performFirmwareIdentityMigrationDryRun() {
        guard firmwareMigrationDryRunGateFailureText == nil,
              let firmwareFingerprint else { return }

        firmwareMigrationDryRunAttempted = true
        firmwareMigrationPlan = nil
        firmwareMigrationDryRunStatusText = "Validating a no-write journal proposal…"

        do {
            let before = try Data(contentsOf: Self.journalFileURL)
            guard let journal = try journalStore.load() else {
                throw FirmwareMigrationDryRunAppError.missingJournal
            }
            let connectedDevice = try currentJournalDeviceIdentity(
                firmwareIdentity: firmwareFingerprint.canonicalIdentity
            )
            let plan = try FirmwareIdentityJournalMigrationPlanner.makePlan(
                sourceData: before,
                connectedDevice: connectedDevice,
                discoveredFirmwareIdentity: firmwareFingerprint.canonicalIdentity
            )
            let after = try Data(contentsOf: Self.journalFileURL)
            guard before == after,
                  plan.originalJournal == journal,
                  try journalStore.load() == journal else {
                throw FirmwareMigrationDryRunAppError.journalChangedDuringDryRun
            }

            firmwareMigrationPlan = plan
            firmwareMigrationPlanGeneration = connectionGeneration
            switch plan.disposition {
            case .ready:
                firmwareMigrationDryRunStatusText =
                    "Validated one proposed field; live journal remains unchanged"
            case .alreadyApplied:
                firmwareMigrationDryRunStatusText =
                    "The same firmware identity is already present; no change is needed"
            }
        } catch {
            firmwareMigrationDryRunStatusText = firmwareMigrationDryRunFailureText(error)
        }
    }

    func performRestoreOnlyPacketPreview() {
        guard restorePacketPreviewGateFailureText == nil,
              let currentFeature = reprogFeatureDescriptor,
              let firmwareFingerprint else { return }

        restorePacketPreviewAttempted = true
        restorePacketPlans = []
        restorePacketPreviewStatusText = "Building feature-v3 packets in memory…"

        do {
            let before = try Data(contentsOf: Self.journalFileURL)
            guard let journal = try journalStore.load() else {
                throw RestorePacketPreviewAppError.missingJournal
            }
            let currentDevice = try currentJournalDeviceIdentity(
                firmwareIdentity: firmwareFingerprint.canonicalIdentity
            )
            guard journal.device.isSafeRecoveryMatch(currentDevice) else {
                throw RestorePacketPreviewAppError.deviceIdentityMismatch
            }

            let plans = try RestoreOnlyReportingPlanner.makePlans(
                journal: journal,
                currentFeature: currentFeature,
                deviceIndex: 0,
                softwareID: 0x0E
            )

            let after = try Data(contentsOf: Self.journalFileURL)
            guard before == after else {
                throw RestorePacketPreviewAppError.liveJournalChanged
            }
            guard rootEvidenceGeneration == connectionGeneration,
                  firmwareEvidenceGeneration == connectionGeneration else {
                throw RestorePacketPreviewAppError.connectionEvidenceChanged
            }

            restorePacketPlans = plans
            restorePacketPreviewStatusText =
                "Built and validated \(plans.count) physical-control restore plans without I/O"
        } catch {
            restorePacketPreviewStatusText = restorePacketPreviewFailureText(error)
        }
    }

    func commitFirmwareIdentityMigration() {
        guard firmwareMigrationCommitGateFailureText == nil,
              let plan = firmwareMigrationPlan,
              let fingerprint = firmwareFingerprint else { return }

        firmwareMigrationCommitAttempted = true
        firmwareMigrationCommitInProgress = true
        firmwareMigrationCommitReceipt = nil
        firmwareMigrationCommitStatusText = "Publishing durable backup and bound journal…"

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { firmwareMigrationCommitInProgress = false }

            do {
                let validatedGeneration = connectionGeneration
                guard firmwareMigrationPlanGeneration == connectionGeneration,
                      firmwareEvidenceGeneration == connectionGeneration,
                      fingerprint.canonicalIdentity == plan.discoveredFirmwareIdentity else {
                    throw FirmwareMigrationCommitAppError.connectionEvidenceChanged
                }
                let connectedDevice = try currentJournalDeviceIdentity(
                    firmwareIdentity: fingerprint.canonicalIdentity
                )
                guard plan.proposedJournal.device.isSafeRecoveryMatch(connectedDevice) else {
                    throw FirmwareMigrationCommitAppError.connectionEvidenceChanged
                }

                let receipt = try await firmwareMigrationRepository.commit(plan)
                guard try journalStore.load() == plan.proposedJournal else {
                    throw FirmwareMigrationCommitAppError.committedJournalVerificationFailed
                }

                firmwareMigrationCommitReceipt = receipt
                if validatedGeneration != connectionGeneration {
                    firmwareMigrationCommitStatusText =
                        "Journal committed, but the connection changed; fresh firmware discovery is required"
                    refreshRecoveryJournalStatus()
                    return
                }
                firmwareMigrationCommitStatusText = receipt.disposition == .committed
                    ? "Firmware identity committed; durable original-byte backup verified"
                    : "Previously committed target and original-byte backup verified"
                refreshRecoveryJournalStatus()
            } catch {
                firmwareMigrationCommitStatusText = firmwareMigrationCommitFailureText(error)
                refreshRecoveryJournalStatus()
            }
        }
    }

    func performReadOnlyControlEnumeration() {
        guard controlEnumerationGateFailureText == nil else { return }

        controlEnumerationAttempted = true
        controlEnumerationInProgress = true
        enumeratedControls = []
        controlEnumerationStatusText = "Reading the control count…"

        observer.performReadOnlyControlEnumeration { [weak self] result in
            Task { @MainActor [weak self] in
                self?.receive(controlEnumerationResult: result)
            }
        }
    }

    func performReadOnlyReportingSnapshot() {
        guard reportingSnapshotGateFailureText == nil else { return }

        reportingSnapshotAttempted = true
        reportingSnapshotInProgress = true
        baselineControls = []
        reportingSnapshotStatusText = "Reading current reporting states…"

        observer.performReadOnlyReportingSnapshot { [weak self] result in
            Task { @MainActor [weak self] in
                self?.receive(reportingSnapshotResult: result)
            }
        }
    }

    func performRecoveryRehearsal() {
        guard recoveryRehearsalGateFailureText == nil else { return }

        recoveryRehearsalAttempted = true
        recoveryRehearsalInProgress = true
        recoveryRehearsalSteps = []
        recoveryRehearsalStatusText = "Rehearsing recovery in memory…"
        defer { recoveryRehearsalInProgress = false }

        do {
            guard let journal = try journalStore.load() else {
                throw RecoveryRehearsalAppError.missingJournal
            }
            let before = try Data(contentsOf: Self.journalFileURL)
            let report = try DeviceRecoveryRehearsal.run(
                journal: journal,
                candidateDevice: try currentJournalDeviceIdentity(for: journal)
            )
            let after = try Data(contentsOf: Self.journalFileURL)
            guard before == after, try journalStore.load() == journal else {
                throw RecoveryRehearsalAppError.journalChangedDuringRehearsal
            }

            recoveryRehearsalSteps = report.steps
            recoveryRehearsalStatusText =
                "Rehearsed all \(report.steps.count) controls; journal unchanged and no HID output used"
        } catch {
            recoveryRehearsalStatusText = recoveryRehearsalFailureText(error)
        }
    }

    func performTransactionSimulation() {
        guard transactionSimulationGateFailureText == nil else { return }

        transactionSimulationAttempted = true
        transactionSimulationInProgress = true
        transactionSimulationReport = nil
        transactionSimulationStatusText = "Running isolated schema-v3 transactions…"

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { transactionSimulationInProgress = false }
            do {
                guard let journal = try journalStore.load() else {
                    throw TransactionSimulationAppError.missingJournal
                }
                guard journal.device.isSafeRecoveryMatch(
                    try currentJournalDeviceIdentity(for: journal)
                ) else {
                    throw TransactionSimulationAppError.deviceIdentityMismatch
                }
                let before = try Data(contentsOf: Self.journalFileURL)
                let report = try await DeviceTransactionSimulation.run(
                    baselineJournal: journal
                )
                let after = try Data(contentsOf: Self.journalFileURL)
                guard before == after, try journalStore.load() == journal else {
                    throw TransactionSimulationAppError.liveJournalChanged
                }

                transactionSimulationReport = report
                transactionSimulationStatusText =
                    "Passed \(report.transportFaultScenarioCount) transport scenarios, \(report.durableCommitBoundaryCount) commit boundaries, and \(report.interruptedRecoveryCount) restart recoveries"
            } catch {
                transactionSimulationStatusText = transactionSimulationFailureText(error)
            }
        }
    }

    func performRestoreOnlyHardwareTrialSimulation() {
        guard restoreTrialSimulationGateFailureText == nil,
              let currentFeature = reprogFeatureDescriptor else { return }

        restoreTrialSimulationAttempted = true
        restoreTrialSimulationInProgress = true
        restoreTrialSimulationReport = nil
        restoreTrialSimulationStatusText =
            "Running the dormant one-control trial against isolated transport…"

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { restoreTrialSimulationInProgress = false }
            do {
                let validatedGeneration = connectionGeneration
                let before = try Data(contentsOf: Self.journalFileURL)
                guard let journal = try journalStore.load() else {
                    throw RestoreTrialSimulationAppError.missingJournal
                }
                guard journal.device.isSafeRecoveryMatch(
                    try currentJournalDeviceIdentity(for: journal)
                ) else {
                    throw RestoreTrialSimulationAppError.deviceIdentityMismatch
                }

                let report = try await RestoreOnlyHardwareTrialSimulation.run(
                    sourceBaselineData: before,
                    currentFeature: currentFeature,
                    connectionEpoch: validatedGeneration &+ 1
                )
                let after = try Data(contentsOf: Self.journalFileURL)
                guard before == after, try journalStore.load() == journal else {
                    throw RestoreTrialSimulationAppError.liveJournalChanged
                }
                guard validatedGeneration == connectionGeneration,
                      rootEvidenceGeneration == connectionGeneration,
                      firmwareEvidenceGeneration == connectionGeneration else {
                    throw RestoreTrialSimulationAppError.connectionEvidenceChanged
                }

                restoreTrialSimulationReport = report
                restoreTrialSimulationStatusText =
                    "Passed one armed SET, exact acknowledgement, and independent baseline GET in isolation"
            } catch {
                restoreTrialSimulationStatusText =
                    "Dormant trial failed closed: \(error.localizedDescription)"
            }
        }
    }

    func performReadOnlyPrecisionPreflight() {
        guard precisionPreflightGateFailureText == nil,
              let currentFeature = reprogFeatureDescriptor else { return }

        precisionPreflightAttempted = true
        precisionPreflightInProgress = true
        precisionPreflightSnapshot = nil
        precisionPreflightEvidenceGeneration = nil
        invalidatePrecisionLifecycleReadiness(
            reason: "Precision preflight changed; review readiness again"
        )
        precisionPreflightStatusText =
            "Reading Precision CID 00ED once from the current Root epoch…"

        do {
            let validatedGeneration = connectionGeneration
            let before = try Data(contentsOf: Self.journalFileURL)
            guard let journal = try journalStore.load() else {
                throw PrecisionPreflightAppError.missingJournal
            }
            try journal.validateForRecovery()
            guard !journal.requiresRecovery,
                  journal.device.isSafeRecoveryMatch(
                    try currentJournalDeviceIdentity(for: journal)
                  ) else {
                throw PrecisionPreflightAppError.deviceIdentityMismatch
            }
            guard journal.featureID == ReprogControlsV4.featureID,
                  currentFeature.version == 3,
                  rootEvidenceGeneration == connectionGeneration,
                  firmwareEvidenceGeneration == connectionGeneration else {
                throw PrecisionPreflightAppError.connectionEvidenceChanged
            }
            guard let precision = journal.controls.first(where: {
                $0.controlInfo.controlID
                    == MXErgoReadOnlyPrecisionPreflight.controlID
            }) else {
                throw PrecisionPreflightAppError.missingPrecisionBaseline
            }
            let baseline = try DeviceTransactionWireState(
                rawParameters: precision.baselineReporting.rawParameters
            )
            let expectation = try MXErgoPrecisionPreflightExpectation(
                device: journal.device,
                feature: currentFeature,
                baseline: baseline
            )

            observer.performReadOnlyPrecisionPreflight(
                expectation: expectation
            ) { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.receive(
                        precisionPreflightResult: result,
                        expectedJournalData: before,
                        expectedJournal: journal,
                        expectedConnectionGeneration: validatedGeneration
                    )
                }
            }
        } catch {
            precisionPreflightInProgress = false
            precisionPreflightStatusText = precisionPreflightFailureText(error)
        }
    }

    func performPrecisionLifecycleReadinessReview() {
        guard precisionReadinessGateFailureText == nil,
              let currentFeature = reprogFeatureDescriptor,
              let preflight = precisionPreflightSnapshot,
              let rootEvidenceGeneration,
              let firmwareEvidenceGeneration,
              let preflightEvidenceGeneration = precisionPreflightEvidenceGeneration else {
            return
        }

        precisionReadinessAttempted = true
        precisionReadinessSnapshot = nil
        precisionReadinessStatusText =
            "Scanning competitors and validating immutable lifecycle evidence…"

        do {
            let scanner = Self.precisionCompetingProcessScanner()
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let competitorsBefore = try scanner.scan(
                excludingProcessIdentifier: ownPID
            )
            let sourceData = try Data(contentsOf: Self.journalFileURL)
            guard let journal = try journalStore.load() else {
                throw PrecisionReadinessAppError.missingJournal
            }
            let currentDevice = try currentJournalDeviceIdentity(for: journal)
            let currentSession = DeviceTransactionSession(
                device: currentDevice,
                featureID: ReprogControlsV4.featureID,
                featureVersion: currentFeature.version,
                featureIndex: currentFeature.index,
                connectionEpoch: preflight.session.connectionEpoch
            )
            let preflightSession = DeviceTransactionSession(
                device: preflight.session.device,
                featureID: ReprogControlsV4.featureID,
                featureVersion: preflight.session.featureVersion,
                featureIndex: preflight.session.featureIndex,
                connectionEpoch: preflight.session.connectionEpoch
            )
            let reloadedData = try Data(contentsOf: Self.journalFileURL)
            let competitorsAfter = try scanner.scan(
                excludingProcessIdentifier: ownPID
            )
            let input = PrecisionTemporaryDiversionReadinessInput(
                sourceJournalData: sourceData,
                reloadedJournalData: reloadedData,
                currentSession: currentSession,
                preflightSession: preflightSession,
                preflightState: preflight.state,
                currentFeature: currentFeature,
                connectionGeneration: connectionGeneration,
                rootEvidenceGeneration: rootEvidenceGeneration,
                firmwareEvidenceGeneration: firmwareEvidenceGeneration,
                preflightEvidenceGeneration: preflightEvidenceGeneration,
                competitorsBefore: competitorsBefore,
                competitorsAfter: competitorsAfter,
                deviceIndex: MXErgoReadOnlyPrecisionPreflight.deviceIndex,
                softwareID: 0x0E
            )
            if let runtimeData = try? Data(contentsOf: Self.runtimeJournalFileURL),
               let envelope = try? JSONDecoder().decode(
                DeviceTransactionEnvelope.self,
                from: runtimeData
               ),
               isReconnectRecoveryEligible(envelope) {
                let reloadedRuntime = try Data(contentsOf: Self.runtimeJournalFileURL)
                precisionReadinessSnapshot = try PrecisionTemporaryDiversionReadinessAudit
                    .evaluateReconnectRecovery(
                        input,
                        runtimeJournalData: runtimeData,
                        reloadedRuntimeJournalData: reloadedRuntime
                    )
                precisionReadinessStatusText =
                    "Reconnect-recovery inputs are ready for review only—not authorized. Confirm Recover to send one restore SET."
            } else {
                precisionReadinessSnapshot = try PrecisionTemporaryDiversionReadinessAudit
                    .evaluate(input)
                precisionReadinessStatusText =
                    "Lifecycle inputs are ready for review only—not authorized for execution"
            }
        } catch {
            precisionReadinessStatusText = precisionReadinessFailureText(error)
        }
    }

    func performMappedControlDiversionReview() {
        guard mappedDiversionGateFailureText == nil,
              let currentFeature = reprogFeatureDescriptor,
              let rootEvidenceGeneration,
              let firmwareEvidenceGeneration else { return }

        mappedDiversionAttempted = true
        mappedDiversionSnapshot = nil
        mappedActionPlan = nil
        mappedEventDelivery = nil
        mappedPreflightPlan = nil
        mappedLivePreflightSnapshot = nil
        mappedDiversionStatusText =
            "Scanning competitors and validating mapped-control diversion evidence…"

        do {
            let scanner = Self.precisionCompetingProcessScanner()
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let competitorsBefore = try scanner.scan(
                excludingProcessIdentifier: ownPID
            )
            let sourceData = try Data(contentsOf: Self.journalFileURL)
            guard let journal = try journalStore.load() else {
                throw MappedDiversionAppError.missingJournal
            }
            let currentDevice = try currentJournalDeviceIdentity(for: journal)
            let currentSession = DeviceTransactionSession(
                device: currentDevice,
                featureID: ReprogControlsV4.featureID,
                featureVersion: currentFeature.version,
                featureIndex: currentFeature.index,
                connectionEpoch: connectionGeneration
            )
            let reloadedData = try Data(contentsOf: Self.journalFileURL)
            let competitorsAfter = try scanner.scan(
                excludingProcessIdentifier: ownPID
            )
            let input = MappedControlsTemporaryDiversionReadinessInput(
                sourceJournalData: sourceData,
                reloadedJournalData: reloadedData,
                currentSession: currentSession,
                currentFeature: currentFeature,
                connectionGeneration: connectionGeneration,
                rootEvidenceGeneration: rootEvidenceGeneration,
                firmwareEvidenceGeneration: firmwareEvidenceGeneration,
                competitorsBefore: competitorsBefore,
                competitorsAfter: competitorsAfter,
                deviceIndex: 0,
                softwareID: 0x0E
            )
            let snapshot = try MappedControlsTemporaryDiversionReadinessAudit
                .evaluate(input)
            let reviewedIDs = snapshot.plan.controls.map(\.controlID)
            let actionPlan = try MappedControlActionPlan.make(
                reviewedControlIDs: reviewedIDs
            )
            let eventDelivery = try MappedControlEventDeliverySnapshot.makeUnauthorized(
                featureIndex: snapshot.plan.featureIndex,
                reviewedControlIDs: reviewedIDs
            )
            let preflightPlan = try MappedControlsReadOnlyPreflightPlan.make(
                from: snapshot.plan
            )
            mappedDiversionSnapshot = snapshot
            mappedActionPlan = actionPlan
            mappedEventDelivery = eventDelivery
            mappedPreflightPlan = preflightPlan
            mappedDiversionStatusText =
                "Mapped-control diversion, action, event-delivery, and GET-only preflight inputs are ready for review only—not authorized for SET, GET, or event synthesis"
        } catch {
            mappedDiversionStatusText = mappedDiversionFailureText(error)
        }
    }

    func performReadOnlyMappedControlPreflight() {
        guard mappedLivePreflightGateFailureText == nil,
              let currentFeature = reprogFeatureDescriptor,
              let plan = mappedPreflightPlan else { return }

        mappedLivePreflightAttempted = true
        mappedLivePreflightInProgress = true
        mappedLivePreflightSnapshot = nil
        mappedLivePreflightStatusText =
            "Reading five mapped-control CIDs sequentially from the current Root epoch…"

        do {
            let validatedGeneration = connectionGeneration
            let before = try Data(contentsOf: Self.journalFileURL)
            guard let journal = try journalStore.load() else {
                throw MappedDiversionAppError.missingJournal
            }
            let currentDevice = try currentJournalDeviceIdentity(for: journal)
            let expectation = try MXErgoMappedControlPreflightExpectation(
                device: currentDevice,
                feature: currentFeature,
                plan: plan
            )
            observer.performReadOnlyMappedControlPreflight(
                expectation: expectation
            ) { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.receive(
                        mappedLivePreflightResult: result,
                        expectedJournalData: before,
                        expectedJournal: journal,
                        expectedConnectionGeneration: validatedGeneration
                    )
                }
            }
        } catch {
            mappedLivePreflightInProgress = false
            mappedLivePreflightStatusText = mappedDiversionFailureText(error)
        }
    }

    func bindDormantRuntimeOwner() async {
        guard !runtimeOwnerBindInProgress,
              runtimeOwner == nil,
              status == .observing,
              let snapshot = precisionReadinessSnapshot,
              snapshot.authorization == .notAuthorizedForExecution,
              let currentFeature = reprogFeatureDescriptor,
              let preflight = precisionPreflightSnapshot else {
            return
        }

        runtimeOwnerBindInProgress = true
        runtimeOwnerStatusText = "Binding dormant runtime owner…"
        defer { runtimeOwnerBindInProgress = false }

        do {
            guard let journal = try journalStore.load() else {
                runtimeOwnerStatusText = "Bind failed: recovery journal is missing"
                return
            }
            let currentDevice = try currentJournalDeviceIdentity(for: journal)
            let session = DeviceTransactionSession(
                device: currentDevice,
                featureID: ReprogControlsV4.featureID,
                featureVersion: currentFeature.version,
                featureIndex: currentFeature.index,
                connectionEpoch: preflight.session.connectionEpoch
            )
            let rootGeneration = connectionGeneration
            let owner = try PrecisionRuntimeOwner.bind(
                observer: observer,
                launchID: launchID,
                readiness: snapshot,
                session: session,
                rootGeneration: rootGeneration,
                sourceBaselineURL: Self.journalFileURL,
                runtimeJournalURL: Self.runtimeJournalFileURL,
                evidenceProvider: {
                    PrecisionRuntimeOwnerEvidence(
                        session: session,
                        rootGeneration: rootGeneration
                    )
                }
            )
            runtimeOwner = owner
            runtimeOwnerSession = session
            runtimeOwnerRootGeneration = rootGeneration
            await owner.setControlEventHandler { [weak self] intent in
                Task { @MainActor in
                    self?.record([intent])
                }
            }
            await owner.setDiversionStatusHandler { [weak self] status in
                Task { @MainActor in
                    self?.applyRuntimeOwnerDiversionStatus(status)
                }
            }
            await refreshRuntimeOwnerFlags()
            if await owner.boundOperation == .recover {
                runtimeOwnerStatusText =
                    "Dormant owner bound for reconnect recovery; confirm Recover to send one restore SET. This does not re-admit or retry automatically."
            } else {
                runtimeOwnerStatusText =
                    "Dormant owner bound for this observer run; confirm admission to stop the observer and open Precision"
            }
        } catch {
            runtimeOwnerStatusText = "Bind failed: \(error)"
        }
    }

    /// Re-reads the runtime's input evidence on demand.
    ///
    /// The counters only otherwise refresh when owner state changes, so if no
    /// control event is being delivered — precisely the case under
    /// investigation — the panel would sit at stale zeros and appear to confirm
    /// whatever the reader already believed.
    func refreshInputDiagnostics() async {
        await refreshRuntimeOwnerFlags()
    }

    /// Records that a one-use authorization expired. Its deadline is minted in
    /// `bind()`, so the bound intent is permanently dead and the only way
    /// forward is a session rollover followed by a fresh bind.
    private func noteAuthorizationExpiry(_ error: Error) -> Bool {
        guard let ownerError = error as? PrecisionRuntimeOwnerError,
              ownerError == .authorizationExpired else {
            return false
        }
        runtimeOwnerAuthorizationExpired = true
        runtimeOwnerCanAdmit = false
        runtimeOwnerCanRecover = false
        return true
    }

    /// A spent runtime journal blocks every later operation, because activate
    /// needs `prepared`/`baselineVerified` and recover needs evidence a
    /// completed journal no longer has. Reviewing costs nothing and is safe at
    /// any time, so it runs whenever the runtime owner is idle.
    func refreshJournalRotationReview() {
        guard runtimeOwner == nil, !journalRotationInProgress else { return }
        do {
            guard let review = try PrecisionRuntimeJournalRotator.review(
                runtimeJournalURL: Self.runtimeJournalFileURL
            ) else {
                journalRotationAvailable = false
                journalRotationSummary = nil
                journalRotationStatusText =
                    "No runtime journal on disk; the next admission creates one"
                return
            }
            journalRotationAvailable = true
            journalRotationSummary = review.summary
            journalRotationStatusText =
                "A completed runtime journal is blocking further operations. Retiring it archives the file and lets a fresh journal bootstrap from the unchanged baseline."
        } catch {
            journalRotationAvailable = false
            journalRotationSummary = nil
            journalRotationStatusText = journalRotationFailureText(error)
        }
    }

    var journalRotationGateFailureText: String? {
        if runtimeOwner != nil {
            return "Release the runtime owner for session rollover before retiring its journal"
        }
        if journalRotationInProgress {
            return "Retiring the completed runtime journal…"
        }
        guard journalRotationAvailable else {
            return journalRotationStatusText
        }
        return nil
    }

    func confirmJournalRotation() {
        guard journalRotationGateFailureText == nil else { return }
        journalRotationInProgress = true
        defer { journalRotationInProgress = false }
        do {
            guard let review = try PrecisionRuntimeJournalRotator.review(
                runtimeJournalURL: Self.runtimeJournalFileURL
            ) else {
                journalRotationAvailable = false
                journalRotationStatusText =
                    "No runtime journal on disk; nothing was retired"
                return
            }
            let receipt = try PrecisionRuntimeJournalRotator.rotate(review)
            journalRotationAvailable = false
            journalRotationSummary = nil
            journalRotationStatusText =
                "Retired transaction \(receipt.archivedTransactionID.uuidString) to \(receipt.archiveURL.lastPathComponent). SHA-256 \(receipt.archivedSHA256). No HID command was sent and the recovery baseline is unchanged."
        } catch {
            journalRotationStatusText = journalRotationFailureText(error)
        }
        refreshJournalRotationReview()
    }

    private func journalRotationFailureText(_ error: Error) -> String {
        guard let rotationError = error as? PrecisionRuntimeJournalRotationError else {
            return "Journal rotation failed closed: \(error)"
        }
        switch rotationError {
        case .notRotatable:
            return "This runtime journal still holds active, ambiguous, conflicted, or recovery-required evidence. It will not be retired."
        case .archiveAlreadyExists:
            return "An archive for this transaction already exists; nothing was changed."
        case .changedAfterReview:
            return "The journal changed after it was reviewed; nothing was changed."
        case .notARegularFile:
            return "The runtime journal is not a regular file; nothing was changed."
        case .leaseUnavailable:
            return "Another process holds the device-operation lease; nothing was changed."
        case let .failed(detail):
            return "Journal rotation failed closed: \(detail)"
        }
    }

    func confirmRuntimeOwnerAdmission() async {
        guard runtimeOwnerCanAdmit,
              !runtimeOwnerOperationInProgress,
              let owner = runtimeOwner,
              let session = runtimeOwnerSession,
              let rootGeneration = runtimeOwnerRootGeneration else {
            return
        }

        runtimeOwnerOperationInProgress = true
        runtimeOwnerStatusText =
            "Admitting Precision runtime; BetterTouchTool and Logi Options must stay quit…"
        defer { runtimeOwnerOperationInProgress = false }

        do {
            try await owner.confirmAdmission(
                explicitlyConfirmed: true,
                competitorProbe: {
                    Self.precisionCompetitorDisplayNames()
                },
                sessionProvider: { session },
                rootGenerationProvider: { rootGeneration }
            )
            await refreshRuntimeOwnerFlags()
            startWheelObserver(owner: owner)
            runtimeOwnerStatusText =
                "Precision diverted (active). Precision tap mutes; hold Precision and scroll for volume when Audio test is on. Deactivate before quit if you need the button restored. Disconnect classifies recovery-required and does not send a restore SET."
        } catch {
            await refreshRuntimeOwnerFlags()
            if noteAuthorizationExpiry(error) {
                runtimeOwnerStatusText =
                    "Admission authorization expired before it was used. Nothing was sent: the observer was not stopped, no lease was taken, and no journal was written. The deadline is fixed when the owner is bound, so admitting again cannot succeed. Select Release for session rollover, bind again, and confirm admission without pausing."
            } else {
                runtimeOwnerStatusText = "Admission failed: \(error)"
            }
        }
    }

    func confirmRuntimeOwnerRecovery() async {
        guard runtimeOwnerCanRecover,
              !runtimeOwnerOperationInProgress,
              let owner = runtimeOwner,
              let session = runtimeOwnerSession,
              let rootGeneration = runtimeOwnerRootGeneration else {
            return
        }

        runtimeOwnerOperationInProgress = true
        runtimeOwnerStatusText =
            "Recovering Precision on this connection; BetterTouchTool and Logi Options must stay quit…"
        defer { runtimeOwnerOperationInProgress = false }

        do {
            try await owner.confirmRecovery(
                explicitlyConfirmed: true,
                competitorProbe: {
                    Self.precisionCompetitorDisplayNames()
                },
                sessionProvider: { session },
                rootGenerationProvider: { rootGeneration }
            )
            await refreshRuntimeOwnerFlags()
            runtimeOwnerStatusText =
                "Precision recover completed. Deactivate is not required if restore verified; quit still does not send an inverse SET."
        } catch {
            await refreshRuntimeOwnerFlags()
            if let ownerError = error as? PrecisionRuntimeOwnerError,
               ownerError == .recoverLockedAfterAmbiguousSET {
                runtimeOwnerStatusText =
                    "Recover is locked: a restore SET had an unknown outcome and will not be retried. Use a GET-only probe; do not send another SET."
            } else if noteAuthorizationExpiry(error) {
                runtimeOwnerStatusText =
                    "Recovery authorization expired before it was used. No restore SET was sent. The deadline is fixed when the owner is bound, so recovering again cannot succeed. Select Release for session rollover, bind again, and confirm recovery without pausing."
            } else {
                runtimeOwnerStatusText = "Recovery failed: \(error)"
            }
        }
    }

    func confirmRuntimeOwnerDeactivation() async {
        guard runtimeOwnerCanDeactivate,
              !runtimeOwnerOperationInProgress,
              let owner = runtimeOwner else {
            return
        }

        runtimeOwnerOperationInProgress = true
        runtimeOwnerStatusText = "Deactivating Precision diversion…"
        defer { runtimeOwnerOperationInProgress = false }

        do {
            try await owner.confirmDeactivation(explicitlyConfirmed: true)
            stopWheelObserver()
            await refreshRuntimeOwnerFlags()
            runtimeOwnerStatusText =
                "Precision restored. The runtime still owns the device until quit or disconnect; session rollover stays blocked while admitted."
        } catch {
            await refreshRuntimeOwnerFlags()
            runtimeOwnerStatusText = "Deactivation failed: \(error)"
        }
    }

    func completeRuntimeOwnerSessionRollover() async {
        guard runtimeOwnerCanRollover, let owner = runtimeOwner else { return }
        do {
            try await owner.completeSessionRollover()
            stopWheelObserver()
            runtimeOwner = nil
            runtimeOwnerSession = nil
            runtimeOwnerRootGeneration = nil
            refreshJournalRotationReview()
            await refreshRuntimeOwnerFlags()
            runtimeOwnerStatusText =
                "Session rollover released the restart fence; the observer may start again"
        } catch {
            runtimeOwnerStatusText = "Rollover failed: \(error)"
        }
    }

    func quit() {
        Task { @MainActor in
            if let owner = runtimeOwner {
                await owner.prepareForQuit()
                await refreshRuntimeOwnerFlags()
            }
            stopWheelObserver()
            stop()
            NSApplication.shared.terminate(nil)
        }
    }

    /// Opens the Accessibility pane. Deliberately does not use
    /// `AXIsProcessTrustedWithOptions` with the prompt option: a permission
    /// dialog the user did not ask for is the wrong shape for this app, and the
    /// grant is only needed once event posting exists.
    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    var menuBarIcon: String {
        if !devices.isEmpty { return "computermouse.fill" }
        if case .failed = status { return "exclamationmark.triangle.fill" }
        return "computermouse"
    }

    var hidppLongOutputReportAdvertised: Bool? {
        guard let device = devices.first,
              inspectedOutputCapabilityDeviceIDs.contains(device.id) else {
            return nil
        }
        return outputReportCapabilitiesByDevice[device.id, default: []]
            .contains { $0.isHIDPP20LongReport }
    }

    var hidppOutputReportStatusText: String {
        guard let advertised = hidppLongOutputReportAdvertised else {
            return "Waiting for output-report descriptor inspection"
        }
        if advertised {
            return "Output report 0x11 advertises the expected 20-byte wire size"
        }

        guard let device = devices.first else { return "MX Ergo is not connected" }
        let found = outputReportCapabilitiesByDevice[device.id, default: []]
            .map { String(format: "0x%02X/%d", $0.reportID, $0.wireByteCount) }
            .joined(separator: ", ")
        return found.isEmpty
            ? "No output reports were exposed by macOS"
            : "Expected 0x11/20; descriptor exposed \(found)"
    }

    var stableRecoveryIdentityAvailable: Bool? {
        guard devices.count == 1, let device = devices.first else {
            return devices.isEmpty ? nil : false
        }
        return device.serialNumber?.isEmpty == false || device.locationID != nil
    }

    var recoveryIdentityStatusText: String {
        guard let available = stableRecoveryIdentityAvailable else {
            return devices.isEmpty
                ? "Waiting for recovery identity inspection"
                : "Exactly one MX Ergo interface is required"
        }
        guard available, let device = devices.first else {
            return "No stable serial or location identifier is exposed"
        }
        if let serial = device.serialNumber, !serial.isEmpty {
            return "Recovery identity available (serial \(serial))"
        }
        return String(format: "Recovery identity available (location 0x%08X)", device.locationID ?? 0)
    }

    var rootQueryRequestBytes: [UInt8] {
        (try? MXErgoOneShotRootQuery.makeRequest().bytes) ?? []
    }

    var rootQueryRequestText: String {
        hexBytes(rootQueryRequestBytes)
    }

    var rootQueryResponseText: String? {
        rootQueryResponseBytes.map(hexBytes)
    }

    var mappedLivePreflightRequestText: String {
        guard let plan = mappedPreflightPlan else {
            return "Unavailable until mapped-control diversion is reviewed"
        }
        return plan.controls.map { control in
            hexBytes(control.verificationRequest.bytes)
        }.joined(separator: "\n")
    }

    var precisionPreflightRequestText: String {
        guard let plan = restorePacketPlans.first(where: {
            $0.controlID == MXErgoReadOnlyPrecisionPreflight.controlID
        }) else { return "Unavailable until the restore-only packet preview is built" }
        return hexBytes(plan.verificationRequest.bytes)
    }

    var rootQueryGateFailureText: String? {
        guard !precisionPreflightInProgress else { return "Precision preflight is in progress" }
        guard !firmwareMigrationCommitInProgress else { return "Journal commit is in progress" }
        guard !rootQueryAttempted else { return "The one-shot query was already attempted in this app run" }
        guard !rootQueryInProgress else { return "The one-shot query is already in progress" }
        guard !firmwareFingerprintInProgress else { return "Firmware discovery is already in progress" }
        guard !controlEnumerationInProgress else { return "Control enumeration is already in progress" }
        guard !reportingSnapshotInProgress else { return "Baseline snapshot is already in progress" }
        guard !recoveryRehearsalInProgress else { return "Recovery rehearsal is already in progress" }
        guard !transactionSimulationInProgress else { return "Transaction simulation is already in progress" }
        guard status == .observing else { return "The observer must be running" }
        guard inputMonitoringGranted else { return "Input Monitoring permission is required" }
        guard devices.count == 1 else { return "Exactly one MX Ergo interface must be connected" }
        guard hidppLongOutputReportAdvertised == true else {
            return "The expected 0x11/20-byte output report must be advertised"
        }
        guard stableRecoveryIdentityAvailable == true else {
            return "A stable serial or location identity is required"
        }
        guard !recoveryJournalNeedsAttention else {
            return "Resolve the recovery journal before any output"
        }
        guard !audioExecutionEnabled else { return "Turn off the Audio test before sending" }
        return nil
    }

    var controlEnumerationGateFailureText: String? {
        guard !precisionPreflightInProgress else { return "Precision preflight is in progress" }
        guard !firmwareMigrationCommitInProgress else { return "Journal commit is in progress" }
        guard !controlEnumerationAttempted else {
            return "Control enumeration was already attempted in this app run"
        }
        guard !controlEnumerationInProgress else { return "Control enumeration is already in progress" }
        guard !firmwareFingerprintInProgress else { return "Firmware discovery is already in progress" }
        guard !reportingSnapshotInProgress else { return "Baseline snapshot is already in progress" }
        guard !recoveryRehearsalInProgress else { return "Recovery rehearsal is already in progress" }
        guard !transactionSimulationInProgress else { return "Transaction simulation is already in progress" }
        guard rootQuerySucceeded else {
            return "Resolve REPROG_CONTROLS_V4 with the Root query first"
        }
        guard status == .observing else { return "The observer must be running" }
        guard inputMonitoringGranted else { return "Input Monitoring permission is required" }
        guard devices.count == 1 else { return "Exactly one MX Ergo interface must be connected" }
        guard hidppLongOutputReportAdvertised == true else {
            return "The expected 0x11/20-byte output report must be advertised"
        }
        guard stableRecoveryIdentityAvailable == true else {
            return "A stable serial or location identity is required"
        }
        guard !recoveryJournalNeedsAttention else {
            return "Resolve the recovery journal before any output"
        }
        guard !audioExecutionEnabled else { return "Turn off the Audio test before enumerating" }
        return nil
    }

    var reportingSnapshotGateFailureText: String? {
        guard !precisionPreflightInProgress else { return "Precision preflight is in progress" }
        guard !firmwareMigrationCommitInProgress else { return "Journal commit is in progress" }
        guard !reportingSnapshotAttempted else {
            return "The reporting-state snapshot was already attempted in this app run"
        }
        guard !reportingSnapshotInProgress else { return "The baseline snapshot is already in progress" }
        guard !firmwareFingerprintInProgress else { return "Firmware discovery is already in progress" }
        guard !recoveryRehearsalInProgress else { return "Recovery rehearsal is already in progress" }
        guard !transactionSimulationInProgress else { return "Transaction simulation is already in progress" }
        guard enumeratedControls.count == 9 else {
            return "Complete the expected 9-control metadata enumeration first"
        }
        guard status == .observing else { return "The observer must be running" }
        guard inputMonitoringGranted else { return "Input Monitoring permission is required" }
        guard devices.count == 1 else { return "Exactly one MX Ergo interface must be connected" }
        guard hidppLongOutputReportAdvertised == true else {
            return "The expected 0x11/20-byte output report must be advertised"
        }
        guard stableRecoveryIdentityAvailable == true else {
            return "A stable serial or location identity is required"
        }
        guard !recoveryJournalNeedsAttention else {
            return "Resolve the recovery journal before any output"
        }
        guard !recoveryJournalExists else {
            return "A baseline journal already exists and will not be overwritten"
        }
        guard !audioExecutionEnabled else { return "Turn off the Audio test before snapshotting" }
        return nil
    }

    var recoveryRehearsalGateFailureText: String? {
        guard !precisionPreflightInProgress else { return "Precision preflight is in progress" }
        guard !firmwareMigrationCommitInProgress else { return "Journal commit is in progress" }
        guard !recoveryRehearsalAttempted else {
            return "The recovery rehearsal was already run in this app session"
        }
        guard !recoveryRehearsalInProgress else { return "The recovery rehearsal is in progress" }
        guard !transactionSimulationInProgress else { return "The transaction simulation is in progress" }
        guard !rootQueryInProgress,
              !firmwareFingerprintInProgress,
              !controlEnumerationInProgress,
              !reportingSnapshotInProgress else {
            return "Wait for the current HID++ discovery operation to finish"
        }
        guard status == .observing else { return "The observer must be running" }
        guard devices.count == 1 else { return "Exactly one MX Ergo interface must be connected" }
        guard stableRecoveryIdentityAvailable == true else {
            return "A stable serial or location identity is required"
        }
        guard recoveryJournalExists else { return "A verified baseline journal is required" }
        guard !recoveryJournalNeedsAttention else {
            return "The journal already requires recovery; rehearsal is locked"
        }
        guard !recoveryJournalFirmwareBound || firmwareFingerprint != nil else {
            return "Run fresh firmware discovery before using the bound journal"
        }
        guard !audioExecutionEnabled else { return "Turn off the Audio test before rehearsing" }
        return nil
    }

    var transactionSimulationGateFailureText: String? {
        guard !precisionPreflightInProgress else { return "Precision preflight is in progress" }
        guard !firmwareMigrationCommitInProgress else { return "Journal commit is in progress" }
        guard !transactionSimulationAttempted else {
            return "The transaction simulation was already run in this app session"
        }
        guard !transactionSimulationInProgress else {
            return "The transaction simulation is in progress"
        }
        guard !rootQueryInProgress,
              !firmwareFingerprintInProgress,
              !controlEnumerationInProgress,
              !reportingSnapshotInProgress,
              !mappedLivePreflightInProgress,
              !recoveryRehearsalInProgress else {
            return "Wait for the current validation operation to finish"
        }
        guard status == .observing else { return "The observer must be running" }
        guard devices.count == 1 else { return "Exactly one MX Ergo interface must be connected" }
        guard devices.first?.serialNumber?.isEmpty == false else {
            return "A stable serial identity is required"
        }
        guard recoveryJournalExists else { return "A verified baseline journal is required" }
        guard !recoveryJournalNeedsAttention else {
            return "The live journal requires attention; simulation is locked"
        }
        guard !recoveryJournalFirmwareBound || firmwareFingerprint != nil else {
            return "Run fresh firmware discovery before using the bound journal"
        }
        guard !audioExecutionEnabled else { return "Turn off the Audio test before simulating" }
        return nil
    }

    var restoreTrialSimulationGateFailureText: String? {
        guard !precisionPreflightInProgress else { return "Precision preflight is in progress" }
        guard !firmwareMigrationCommitInProgress else { return "Journal commit is in progress" }
        guard !restoreTrialSimulationAttempted else {
            return "The dormant trial self-test was already run in this app session"
        }
        guard !restoreTrialSimulationInProgress else {
            return "The dormant trial self-test is in progress"
        }
        guard !rootQueryInProgress,
              !firmwareFingerprintInProgress,
              !controlEnumerationInProgress,
              !reportingSnapshotInProgress,
              !mappedLivePreflightInProgress,
              !recoveryRehearsalInProgress,
              !transactionSimulationInProgress else {
            return "Wait for the current discovery or validation operation to finish"
        }
        guard let feature = reprogFeatureDescriptor,
              feature.version == 3,
              rootEvidenceGeneration == connectionGeneration else {
            return "Resolve REPROG_CONTROLS_V4 version 3 on this connection first"
        }
        guard firmwareFingerprint != nil,
              firmwareEvidenceGeneration == connectionGeneration else {
            return "Run fresh firmware discovery on this connection first"
        }
        guard restorePacketPlans.contains(where: {
            $0.controlID == RestoreOnlyHardwareTrialRecord.precisionControlID
                && $0.setFlags == RestoreOnlyHardwareTrialRecord.requiredSetFlags
                && $0.setMappedControlID
                    == RestoreOnlyHardwareTrialRecord.requiredMappedControlID
        }) else {
            return "Build the narrowed restore-only packet preview first"
        }
        guard status == .observing else { return "The observer must be running" }
        guard devices.count == 1 else { return "Exactly one MX Ergo interface must be connected" }
        guard hidppLongOutputReportAdvertised == true else {
            return "The expected 0x11/20-byte output report must be advertised"
        }
        guard recoveryJournalExists, recoveryJournalFirmwareBound,
              !recoveryJournalUnreadable,
              !recoveryJournalNeedsAttention else {
            return "A clean firmware-bound baseline journal is required"
        }
        guard !audioExecutionEnabled else {
            return "Turn off the Audio test before running the self-test"
        }
        return nil
    }

    var precisionPreflightGateFailureText: String? {
        guard !precisionPreflightAttempted else {
            return "The live Precision preflight was already attempted in this app session"
        }
        guard !precisionPreflightInProgress else {
            return "The live Precision preflight is in progress"
        }
        guard !firmwareMigrationCommitInProgress else {
            return "Journal commit is in progress"
        }
        guard !rootQueryInProgress,
              !firmwareFingerprintInProgress,
              !controlEnumerationInProgress,
              !reportingSnapshotInProgress,
              !mappedLivePreflightInProgress,
              !recoveryRehearsalInProgress,
              !transactionSimulationInProgress,
              !restoreTrialSimulationInProgress else {
            return "Wait for the current discovery or validation operation to finish"
        }
        guard restoreTrialSimulationReport != nil else {
            return "Complete the dormant Precision trial self-test first"
        }
        guard let feature = reprogFeatureDescriptor,
              feature.version == 3,
              rootQuerySucceeded,
              rootEvidenceGeneration == connectionGeneration else {
            return "Resolve REPROG_CONTROLS_V4 version 3 on this connection first"
        }
        guard let fingerprint = firmwareFingerprint,
              !fingerprint.canonicalIdentity.isEmpty,
              firmwareEvidenceGeneration == connectionGeneration else {
            return "Run fresh firmware discovery on this connection first"
        }
        guard restorePacketPlans.contains(where: {
            $0.controlID == MXErgoReadOnlyPrecisionPreflight.controlID
                && $0.setFlags == RestoreOnlyHardwareTrialRecord.requiredSetFlags
                && $0.setMappedControlID
                    == RestoreOnlyHardwareTrialRecord.requiredMappedControlID
        }) else {
            return "Build the narrowed restore-only packet preview first"
        }
        guard status == .observing else { return "The observer must be running" }
        guard inputMonitoringGranted else { return "Input Monitoring permission is required" }
        guard devices.count == 1 else {
            return "Exactly one MX Ergo interface must be connected"
        }
        guard hidppLongOutputReportAdvertised == true else {
            return "The expected 0x11/20-byte output report must be advertised"
        }
        guard stableRecoveryIdentityAvailable == true else {
            return "A stable serial or location identity is required"
        }
        guard recoveryJournalExists, recoveryJournalFirmwareBound,
              !recoveryJournalUnreadable,
              !recoveryJournalNeedsAttention else {
            return "A clean firmware-bound baseline journal is required"
        }
        guard !audioExecutionEnabled else {
            return "Turn off the Audio test before the live read-only preflight"
        }
        return nil
    }

    var precisionReadinessGateFailureText: String? {
        guard !precisionPreflightInProgress else {
            return "Precision preflight is in progress"
        }
        guard !firmwareMigrationCommitInProgress else {
            return "Journal commit is in progress"
        }
        guard !rootQueryInProgress,
              !firmwareFingerprintInProgress,
              !controlEnumerationInProgress,
              !reportingSnapshotInProgress,
              !mappedLivePreflightInProgress,
              !recoveryRehearsalInProgress,
              !transactionSimulationInProgress,
              !restoreTrialSimulationInProgress else {
            return "Wait for the current discovery or validation operation to finish"
        }
        guard status == .observing else { return "The observer must be running" }
        guard devices.count == 1 else {
            return "Exactly one MX Ergo interface must be connected"
        }
        guard let feature = reprogFeatureDescriptor,
              feature.version == 3,
              rootQuerySucceeded,
              rootEvidenceGeneration == connectionGeneration else {
            return "Resolve REPROG_CONTROLS_V4 version 3 on this connection first"
        }
        guard firmwareFingerprint != nil,
              firmwareEvidenceGeneration == connectionGeneration else {
            return "Run fresh firmware discovery on this connection first"
        }
        guard precisionPreflightSnapshot != nil,
              precisionPreflightEvidenceGeneration == connectionGeneration else {
            return "Complete the exact-baseline Precision preflight first"
        }
        guard recoveryJournalExists, recoveryJournalFirmwareBound,
              !recoveryJournalUnreadable,
              !recoveryJournalNeedsAttention else {
            return "A clean firmware-bound baseline journal is required"
        }
        guard !audioExecutionEnabled else {
            return "Turn off the Audio test before reviewing lifecycle readiness"
        }
        return nil
    }

    var mappedDiversionGateFailureText: String? {
        guard !runtimeOwnerIsAdmitted else {
            return "Deactivate or recover Precision before reviewing mapped-control diversion"
        }
        guard !precisionPreflightInProgress else { return "Precision preflight is in progress" }
        guard !firmwareMigrationCommitInProgress else { return "Journal commit is in progress" }
        guard !rootQueryInProgress,
              !firmwareFingerprintInProgress,
              !controlEnumerationInProgress,
              !reportingSnapshotInProgress,
              !mappedLivePreflightInProgress,
              !recoveryRehearsalInProgress,
              !transactionSimulationInProgress,
              !restoreTrialSimulationInProgress else {
            return "Wait for the current discovery or validation operation to finish"
        }
        guard status == .observing else { return "The observer must be running" }
        guard devices.count == 1 else {
            return "Exactly one MX Ergo interface must be connected"
        }
        guard let feature = reprogFeatureDescriptor,
              feature.version == 3,
              rootQuerySucceeded,
              rootEvidenceGeneration == connectionGeneration else {
            return "Resolve REPROG_CONTROLS_V4 version 3 on this connection first"
        }
        guard firmwareFingerprint != nil,
              firmwareEvidenceGeneration == connectionGeneration else {
            return "Run fresh firmware discovery on this connection first"
        }
        guard recoveryJournalExists, recoveryJournalFirmwareBound,
              !recoveryJournalUnreadable,
              !recoveryJournalNeedsAttention else {
            return "A clean firmware-bound baseline journal is required"
        }
        guard !audioExecutionEnabled else {
            return "Turn off the Audio test before reviewing mapped-control diversion"
        }
        return nil
    }

    var mappedLivePreflightGateFailureText: String? {
        guard !mappedLivePreflightAttempted else {
            return "The live mapped-control GET preflight was already attempted in this app session"
        }
        guard !mappedLivePreflightInProgress else {
            return "The live mapped-control GET preflight is in progress"
        }
        guard mappedPreflightPlan != nil, mappedDiversionSnapshot != nil else {
            return "Review mapped-control diversion first"
        }
        if let diversionGate = mappedDiversionGateFailureText {
            return diversionGate
        }
        return nil
    }

    var firmwareFingerprintGateFailureText: String? {
        guard !precisionPreflightInProgress else { return "Precision preflight is in progress" }
        guard !firmwareMigrationCommitInProgress else { return "Journal commit is in progress" }
        guard !firmwareFingerprintAttempted else {
            return "Firmware discovery was already attempted in this app session"
        }
        guard !firmwareFingerprintInProgress else { return "Firmware discovery is in progress" }
        guard !rootQueryInProgress,
              !controlEnumerationInProgress,
              !reportingSnapshotInProgress,
              !mappedLivePreflightInProgress,
              !recoveryRehearsalInProgress,
              !transactionSimulationInProgress else {
            return "Wait for the current discovery or validation operation to finish"
        }
        guard status == .observing else { return "The observer must be running" }
        guard inputMonitoringGranted else { return "Input Monitoring permission is required" }
        guard devices.count == 1 else { return "Exactly one MX Ergo interface must be connected" }
        guard hidppLongOutputReportAdvertised == true else {
            return "The expected 0x11/20-byte output report must be advertised"
        }
        guard stableRecoveryIdentityAvailable == true else {
            return "A stable serial or location identity is required"
        }
        guard !recoveryJournalUnreadable else {
            return "The recovery journal is unreadable; firmware discovery remains locked"
        }
        guard !audioExecutionEnabled else { return "Turn off the Audio test before discovering firmware" }
        return nil
    }

    var firmwareMigrationDryRunGateFailureText: String? {
        guard !precisionPreflightInProgress else { return "Precision preflight is in progress" }
        guard !firmwareMigrationCommitInProgress else { return "Journal commit is in progress" }
        guard !firmwareMigrationDryRunAttempted else {
            return "The migration dry-run was already performed in this app session"
        }
        guard firmwareFingerprint != nil else {
            return "Complete firmware discovery on this connection first"
        }
        guard !rootQueryInProgress,
              !firmwareFingerprintInProgress,
              !controlEnumerationInProgress,
              !reportingSnapshotInProgress,
              !mappedLivePreflightInProgress,
              !recoveryRehearsalInProgress,
              !transactionSimulationInProgress else {
            return "Wait for the current validation operation to finish"
        }
        guard status == .observing else { return "The observer must be running" }
        guard devices.count == 1 else { return "Exactly one MX Ergo interface must be connected" }
        guard recoveryJournalExists else { return "A verified baseline journal is required" }
        guard !recoveryJournalNeedsAttention else {
            return "The live journal requires recovery; migration planning is locked"
        }
        guard !audioExecutionEnabled else { return "Turn off the Audio test before planning" }
        return nil
    }

    var firmwareMigrationCommitGateFailureText: String? {
        guard !precisionPreflightInProgress else { return "Precision preflight is in progress" }
        guard !firmwareMigrationCommitAttempted else {
            return "The commit was already attempted in this app session"
        }
        guard !firmwareMigrationCommitInProgress else {
            return "The firmware identity commit is in progress"
        }
        guard let plan = firmwareMigrationPlan, plan.changesExactlyFirmwareIdentity else {
            return "Complete a ready migration dry-run first"
        }
        guard let fingerprint = firmwareFingerprint,
              fingerprint.canonicalIdentity == plan.discoveredFirmwareIdentity,
              firmwareEvidenceGeneration == connectionGeneration,
              firmwareMigrationPlanGeneration == connectionGeneration else {
            return "The current connection no longer matches the validated dry-run"
        }
        guard status == .observing else { return "The observer must be running" }
        guard devices.count == 1 else { return "Exactly one MX Ergo interface must be connected" }
        guard recoveryJournalExists else { return "The baseline journal is missing" }
        guard !recoveryJournalUnreadable else { return "The recovery journal is unreadable" }
        guard !recoveryJournalNeedsAttention else {
            return "The live journal requires recovery; identity binding is locked"
        }
        guard !audioExecutionEnabled else { return "Turn off the Audio test before committing" }
        return nil
    }

    var firmwareMigrationCommitConfirmationText: String {
        guard let plan = firmwareMigrationPlan else {
            return "No validated migration plan is available."
        }
        return """
        Live journal: \(Self.journalFileURL.path)

        Source SHA-256: \(plan.sourceSHA256)
        Transaction: \(plan.originalJournal.transactionID.uuidString)
        Schema: v\(plan.originalJournal.schemaVersion) (unchanged)
        Sole field: device.firmwareIdentity
        Backup: \(Self.firmwareMigrationBackupURL.path)

        This writes only the recovery journal metadata and its original-byte backup. It sends no HID command. After a restart, recovery remains locked until a fresh firmware discovery matches exactly.
        """
    }

    var restorePacketPreviewGateFailureText: String? {
        guard !precisionPreflightInProgress else { return "Precision preflight is in progress" }
        guard !restorePacketPreviewAttempted else {
            return "The offline restore preview was already built in this app session"
        }
        guard !firmwareMigrationCommitInProgress else { return "Journal commit is in progress" }
        guard !rootQueryInProgress,
              !firmwareFingerprintInProgress,
              !controlEnumerationInProgress,
              !reportingSnapshotInProgress,
              !mappedLivePreflightInProgress,
              !recoveryRehearsalInProgress,
              !transactionSimulationInProgress else {
            return "Wait for the current discovery or validation operation to finish"
        }
        guard let feature = reprogFeatureDescriptor,
              rootQuerySucceeded,
              rootEvidenceGeneration == connectionGeneration else {
            return "Resolve REPROG_CONTROLS_V4 on this connection first"
        }
        guard feature.version == 3 else {
            return "Restore planning is locked to validated feature version 3"
        }
        guard let fingerprint = firmwareFingerprint,
              !fingerprint.canonicalIdentity.isEmpty,
              firmwareEvidenceGeneration == connectionGeneration else {
            return "Run fresh firmware discovery on this connection first"
        }
        guard status == .observing else { return "The observer must be running" }
        guard devices.count == 1 else { return "Exactly one MX Ergo interface must be connected" }
        guard hidppLongOutputReportAdvertised == true else {
            return "The expected 0x11/20-byte output report must be advertised"
        }
        guard stableRecoveryIdentityAvailable == true else {
            return "A stable serial or location identity is required"
        }
        guard recoveryJournalExists, recoveryJournalFirmwareBound else {
            return "A firmware-bound baseline journal is required"
        }
        guard !recoveryJournalUnreadable else { return "The recovery journal is unreadable" }
        guard !recoveryJournalNeedsAttention else {
            return "The live journal requires recovery; packet planning is locked"
        }
        guard !audioExecutionEnabled else { return "Turn off the Audio test before planning" }
        return nil
    }

    private static var journalFileURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("com.phib.MXErgoController", isDirectory: true)
        .appendingPathComponent("device-state-journal.json")
    }

    private static var runtimeJournalFileURL: URL {
        journalFileURL.deletingLastPathComponent()
            .appendingPathComponent("precision-runtime-v3.json")
    }

    private func startWheelObserver(owner: PrecisionRuntimeOwner) {
        let held = owner.precisionHeld
        // The diagnostic mode holds the same observer. Clearing the flag here
        // keeps the UI honest about which mode the single tap is in.
        scrollDiagnosticsEnabled = false
        wheelObserver.stop()
        wheelObserver.start(
            handler: { notches in
                Task { await owner.noteVerticalScroll(
                    notches: notches,
                    at: ProcessInfo.processInfo.systemUptime
                ) }
            },
            shouldSuppressScroll: { held.isHeld }
        )
    }

    private func stopWheelObserver() {
        wheelObserver.stop()
    }

    private func applyRuntimeOwnerDiversionStatus(
        _ status: PrecisionRuntimeOwnerDiversionStatus
    ) {
        switch status {
        case .bound:
            break
        case .active:
            runtimeOwnerNeedsRecovery = false
            runtimeOwnerDeviceDisconnected = false
        case .restored:
            runtimeOwnerNeedsRecovery = false
            stopWheelObserver()
        case .recoveryRequired:
            runtimeOwnerNeedsRecovery = true
            runtimeOwnerDeviceDisconnected = true
            stopWheelObserver()
            runtimeOwnerStatusText =
                "MX Ergo disconnected while Precision was diverted. No restore SET was sent. Reconnect does not re-admit. Release for session rollover, then power-cycle the trackball; a later authorized recover is required if diversion remains."
        case let .shutDown(recoveryRequired):
            runtimeOwnerNeedsRecovery = recoveryRequired
            stopWheelObserver()
            if recoveryRequired {
                runtimeOwnerStatusText =
                    "Precision runtime shut down and recovery is required. No automatic SET was sent. Release for session rollover before starting the observer again."
            }
        case .released:
            runtimeOwnerNeedsRecovery = false
        }
        Task { await refreshRuntimeOwnerFlags() }
    }

    private func refreshRuntimeOwnerFlags() async {
        guard let owner = runtimeOwner else {
            inputDiagnosticsSummary = nil
            inputDiagnosticsInterpretation = nil
            inputDiagnosticsLastFrame = nil
            inputDiagnosticsLastPress = nil
            runtimeOwnerBlocksRestart = false
            runtimeOwnerIsBound = false
            runtimeOwnerCanRollover = false
            runtimeOwnerCanAdmit = false
            runtimeOwnerCanRecover = false
            runtimeOwnerIsAdmitted = false
            runtimeOwnerControlIsDiverted = false
            runtimeOwnerAuthorizationExpired = false
            runtimeOwnerCanDeactivate = false
            runtimeOwnerNeedsRecovery = false
            runtimeOwnerDeviceDisconnected = false
            return
        }
        let phase = await owner.phase
        let diversion = await owner.diversionStatus
        let disconnected = await owner.deviceWasDisconnected
        let operation = await owner.boundOperation
        let recoverLocked = await owner.isRecoverLockedAfterAmbiguousSET
        runtimeOwnerBlocksRestart = await owner.blocksObserverRestart
        runtimeOwnerIsBound = true
        runtimeOwnerIsAdmitted = phase == .admitted
        // The runtime stays admitted after a verified restore, so read the
        // diversion status rather than inferring it from admission.
        runtimeOwnerControlIsDiverted = phase == .admitted && diversion == .active
        runtimeOwnerCanAdmit = phase == .bound
            && operation == .activate
            && !runtimeOwnerAuthorizationExpired
        runtimeOwnerCanRecover = phase == .bound
            && operation == .recover
            && !recoverLocked
            && !runtimeOwnerAuthorizationExpired
        // Deactivating a control that is already restored would offer a
        // no-op SET path. Same conflation as the status label: admitted
        // is not the same as diverted.
        runtimeOwnerCanDeactivate = phase == .admitted
            && !disconnected
            && runtimeOwnerControlIsDiverted
        runtimeOwnerCanRollover = phase == .bound || phase == .shutDown
        runtimeOwnerDeviceDisconnected = disconnected
        if let diagnostics = await owner.inputDiagnostics() {
            inputDiagnosticsSummary = diagnostics.summary
            inputDiagnosticsInterpretation = diagnostics.interpretation
            inputDiagnosticsLastFrame = diagnostics.lastObservedFrameHex
            inputDiagnosticsLastPress = diagnostics.lastPressFrameHex
        } else {
            inputDiagnosticsSummary = nil
            inputDiagnosticsInterpretation = nil
            inputDiagnosticsLastFrame = nil
            inputDiagnosticsLastPress = nil
        }
        switch diversion {
        case .recoveryRequired, .shutDown(recoveryRequired: true):
            runtimeOwnerNeedsRecovery = true
        default:
            if phase != .shutDown {
                runtimeOwnerNeedsRecovery = false
            }
        }
    }

    private static var firmwareMigrationBackupURL: URL {
        journalFileURL.deletingLastPathComponent()
            .appendingPathComponent("device-state-journal.pre-firmware-identity.json")
    }

    private func refreshRecoveryJournalStatus() {
        do {
            guard let journal = try journalStore.load() else {
                recoveryJournalStatus = "No device changes recorded"
                recoveryJournalNeedsAttention = false
                recoveryJournalExists = false
                recoveryJournalUnreadable = false
                recoveryJournalFirmwareBound = false
                baselineControls = []
                return
            }

            recoveryJournalExists = true
            recoveryJournalUnreadable = false
            recoveryJournalNeedsAttention = journal.requiresRecovery
            recoveryJournalFirmwareBound = journal.device.firmwareIdentity?.isEmpty == false
            baselineControls = journal.controls.sorted {
                $0.controlInfo.index < $1.controlInfo.index
            }
            if !reportingSnapshotAttempted {
                reportingSnapshotStatusText =
                    "Loaded and verified all \(journal.expectedControlCount) saved baseline reporting states"
            }
            if journal.requiresRecovery {
                recoveryJournalStatus =
                    "Recovery required from transaction \(journal.transactionID.uuidString.prefix(8))"
            } else {
                recoveryJournalStatus = recoveryJournalFirmwareBound
                    ? "Last journal state: \(journal.statusSummary) • firmware bound"
                    : "Last journal state: \(journal.statusSummary)"
            }
        } catch {
            recoveryJournalStatus = "Recovery journal unreadable—output remains locked"
            recoveryJournalNeedsAttention = true
            recoveryJournalExists = true
            recoveryJournalUnreadable = true
            recoveryJournalFirmwareBound = false
            baselineControls = []
        }
    }

    private func restartObserverAfterPermissionGrant() {
        guard !runtimeOwnerBlocksRestart else { return }
        switch status {
        case .stopped:
            if didBootstrap {
                start()
            }
        case .starting, .observing, .failed:
            pendingObserverRestart = true
            observer.stop()
        }
    }

    private func receive(_ observation: MXErgoObservation) {
        switch observation {
        case let .status(newStatus):
            status = newStatus
            if newStatus == .stopped, pendingObserverRestart {
                pendingObserverRestart = false
                start()
            }
        case let .connected(device):
            guard device.isBluetooth else { return }
            let wasKnown = devices.contains { $0.id == device.id }
            if !wasKnown, firmwareFingerprint != nil {
                connectionGeneration &+= 1
                invalidateFirmwareValidationEvidence(
                    reason: "Connection changed; relaunch and rediscover firmware"
                )
            }
            devices.removeAll { $0.id == device.id }
            devices.append(device)
            devices.sort { $0.id < $1.id }
        case let .disconnected(deviceID):
            connectionGeneration &+= 1
            invalidateFirmwareValidationEvidence(
                reason: "MX Ergo disconnected; relaunch and rediscover firmware"
            )
            devices.removeAll { $0.id == deviceID }
            outputReportCapabilitiesByDevice.removeValue(forKey: deviceID)
            inspectedOutputCapabilityDeviceIDs.remove(deviceID)
        case let .outputReportCapabilities(deviceID, capabilities):
            outputReportCapabilitiesByDevice[deviceID] = capabilities
            inspectedOutputCapabilityDeviceIDs.insert(deviceID)
        case let .report(report):
            lastReport = report
            var shouldRecordForCalibration = report.isLogitechVendorReport
            let now = ProcessInfo.processInfo.systemUptime

            if let event = LogitechControlEventDecoder.decode(report) {
                switch event {
                case let .pressed(controlID):
                    if let control = MXErgoControl(rawValue: controlID) {
                        record(intentResolver.process(.controlPressed(control), at: now))
                    }
                case .released:
                    record(intentResolver.process(.controlsReleased, at: now))
                }
            }

            if let buttonMask = report.standardMouseButtonMask {
                if let previousMask = lastStandardMouseButtonMask {
                    shouldRecordForCalibration = previousMask != buttonMask
                    if shouldRecordForCalibration {
                        record(intentResolver.process(
                            .standardMouseButtonsChanged(previous: previousMask, current: buttonMask),
                            at: now
                        ))
                    }
                }
                lastStandardMouseButtonMask = buttonMask
            }

            if shouldRecordForCalibration {
                calibrationReportBuffer.append(report)
                calibrationReports = calibrationReportBuffer.elements
            }
        case let .verticalScroll(notches):
            wheelEventCount += 1
            lastWheelNotches = notches
            record(intentResolver.process(
                .verticalScroll(notches: notches),
                at: ProcessInfo.processInfo.systemUptime
            ))
        case let .horizontalScroll(notches):
            // Observation only. macOS already delivers wheel tilt as horizontal
            // scroll, so nothing is suppressed and no intent is resolved.
            tiltEventCount += 1
            lastTiltNotches = notches
        }
    }

    private func receive(rootQueryResult result: MXErgoOneShotRootQueryResult) {
        rootQueryInProgress = false
        reprogFeatureDescriptor = nil
        rootEvidenceGeneration = nil

        switch result {
        case let .success(_, responseBytes, descriptor):
            rootQueryResponseBytes = responseBytes
            rootQuerySucceeded = descriptor.isSupported
            if descriptor.isSupported {
                reprogFeatureDescriptor = descriptor
                rootEvidenceGeneration = connectionGeneration
            }
            rootQueryStatusText = descriptor.isSupported
                ? String(
                    format: "0x1B04 resolved to index 0x%02X, type 0x%02X, version %d",
                    descriptor.index,
                    descriptor.type,
                    descriptor.version
                )
                : "The device reported that REPROG_CONTROLS_V4 is unsupported"

        case let .protocolError(_, responseBytes, code):
            rootQueryResponseBytes = responseBytes
            rootQueryStatusText = String(format: "Device returned HID++ error 0x%02X", code)

        case let .malformedResponse(_, responseBytes):
            rootQueryResponseBytes = responseBytes
            rootQueryStatusText = "A correlated response arrived but its Root payload was malformed"

        case let .outputFailed(_, code):
            rootQueryStatusText = String(format: "macOS rejected the output report (0x%08X)", code)

        case .timedOut:
            rootQueryStatusText = "Timed out; this connection is poisoned and no retry will be attempted"

        case .disconnected:
            rootQueryStatusText = "The MX Ergo disconnected while the query was pending; no retry will be attempted"

        case .observerStopped:
            rootQueryStatusText = "The query was cancelled because the observer stopped"

        case let .rejected(reason):
            rootQueryStatusText = rejectionText(reason)
        }
    }

    private func receive(
        firmwareFingerprintResult result: MXErgoFirmwareFingerprintResult
    ) {
        firmwareFingerprintInProgress = false

        switch result {
        case let .success(fingerprint):
            invalidateRestorePacketPreview(reason: "Fresh firmware evidence is ready")
            firmwareFingerprint = fingerprint
            firmwareEvidenceGeneration = connectionGeneration
            firmwareMigrationPlan = nil
            firmwareMigrationPlanGeneration = nil
            firmwareFingerprintStatusText =
                "Read and validated \(fingerprint.entities.count) firmware entities (feature v\(fingerprint.featureVersion))"

        case .unsupportedFeature:
            firmwareFingerprintStatusText = "The device reported that Device Information 0x0003 is unsupported"

        case let .protocolError(stage, _, _, code):
            firmwareFingerprintStatusText = String(
                format: "Device error 0x%02X while reading %@",
                code,
                stage.description
            )

        case let .malformedResponse(stage, _, _):
            firmwareFingerprintStatusText =
                "Malformed response while reading \(stage.description); nothing was saved"

        case let .outputFailed(stage, _, code):
            firmwareFingerprintStatusText = String(
                format: "macOS rejected the %@ request (0x%08X)",
                stage.description,
                code
            )

        case let .timedOut(stage, _):
            firmwareFingerprintStatusText =
                "Timed out reading \(stage.description); this connection is poisoned"

        case let .disconnected(stage, _):
            firmwareFingerprintStatusText =
                "The MX Ergo disconnected while reading \(stage.description)"

        case .observerStopped:
            firmwareFingerprintStatusText =
                "Firmware discovery was cancelled because the observer stopped"

        case let .rejected(reason):
            firmwareFingerprintStatusText = rejectionText(reason)
        }
    }

    private func receive(
        controlEnumerationResult result: MXErgoReadOnlyControlEnumerationResult
    ) {
        controlEnumerationInProgress = false

        switch result {
        case let .success(snapshot):
            enumeratedControls = snapshot.controls.sorted { $0.index < $1.index }
            controlEnumerationStatusText =
                "Read all \(snapshot.expectedControlCount) control metadata records"

        case let .protocolError(stage, _, _, code):
            controlEnumerationStatusText = String(
                format: "Device error 0x%02X while reading %@",
                code,
                stage.description
            )

        case let .malformedResponse(stage, _, _):
            controlEnumerationStatusText =
                "Malformed response while reading \(stage.description)"

        case let .outputFailed(stage, _, code):
            controlEnumerationStatusText = String(
                format: "macOS rejected the %@ request (0x%08X)",
                stage.description,
                code
            )

        case let .timedOut(stage, _):
            controlEnumerationStatusText =
                "Timed out reading \(stage.description); this connection is poisoned"

        case let .disconnected(stage, _):
            controlEnumerationStatusText =
                "The MX Ergo disconnected while reading \(stage.description)"

        case .observerStopped:
            controlEnumerationStatusText =
                "Control enumeration was cancelled because the observer stopped"

        case let .rejected(reason):
            controlEnumerationStatusText = rejectionText(reason)
        }
    }

    private func receive(
        reportingSnapshotResult result: MXErgoReadOnlyReportingSnapshotResult
    ) {
        reportingSnapshotInProgress = false

        switch result {
        case let .success(snapshot):
            do {
                guard !FileManager.default.fileExists(atPath: Self.journalFileURL.path) else {
                    throw BaselinePersistenceError.journalAlreadyExists
                }

                let identity = try currentJournalDeviceIdentity()
                guard identity.hasStableDiscriminator else {
                    throw BaselinePersistenceError.missingStableIdentity
                }

                let journal = try DeviceStateJournal(
                    appBuild: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleVersion"
                    ) as? String ?? "development",
                    device: identity,
                    feature: snapshot.feature,
                    expectedControlCount: snapshot.expectedControlCount,
                    controls: snapshot.controls
                )
                try journalStore.save(journal)
                refreshRecoveryJournalStatus()
                reportingSnapshotStatusText =
                    "Saved and verified all \(journal.expectedControlCount) baseline reporting states"
            } catch {
                reportingSnapshotStatusText =
                    "Baseline was not saved: \(error.localizedDescription)"
                refreshRecoveryJournalStatus()
            }

        case let .protocolError(stage, _, _, code):
            reportingSnapshotStatusText = String(
                format: "Device error 0x%02X while reading %@",
                code,
                stage.description
            )

        case let .malformedResponse(stage, _, _):
            reportingSnapshotStatusText =
                "Malformed response while reading \(stage.description); no baseline was saved"

        case let .outputFailed(stage, _, code):
            reportingSnapshotStatusText = String(
                format: "macOS rejected the %@ request (0x%08X)",
                stage.description,
                code
            )

        case let .timedOut(stage, _):
            reportingSnapshotStatusText =
                "Timed out reading \(stage.description); this connection is poisoned"

        case let .disconnected(stage, _):
            reportingSnapshotStatusText =
                "The MX Ergo disconnected while reading \(stage.description)"

        case .observerStopped:
            reportingSnapshotStatusText =
                "Baseline capture was cancelled because the observer stopped"

        case let .rejected(reason):
            reportingSnapshotStatusText = rejectionText(reason)
        }
    }

    private func receive(
        precisionPreflightResult result: MXErgoReadOnlyPrecisionPreflightResult,
        expectedJournalData: Data,
        expectedJournal: DeviceStateJournal,
        expectedConnectionGeneration: UInt64
    ) {
        precisionPreflightInProgress = false

        switch result {
        case let .success(snapshot):
            do {
                let after = try Data(contentsOf: Self.journalFileURL)
                guard after == expectedJournalData,
                      try journalStore.load() == expectedJournal else {
                    throw PrecisionPreflightAppError.liveJournalChanged
                }
                guard expectedConnectionGeneration == connectionGeneration,
                      rootEvidenceGeneration == connectionGeneration,
                      firmwareEvidenceGeneration == connectionGeneration,
                      reprogFeatureDescriptor?.index == snapshot.session.featureIndex,
                      reprogFeatureDescriptor?.version == snapshot.session.featureVersion,
                      expectedJournal.device.isSafeRecoveryMatch(snapshot.session.device),
                      let precision = expectedJournal.controls.first(where: {
                        $0.controlInfo.controlID
                            == MXErgoReadOnlyPrecisionPreflight.controlID
                      }),
                      precision.baselineReporting.rawParameters
                        == snapshot.state.rawParameters else {
                    throw PrecisionPreflightAppError.connectionEvidenceChanged
                }

                precisionPreflightSnapshot = snapshot
                precisionPreflightEvidenceGeneration = connectionGeneration
                precisionPreflightStatusText =
                    "Live Precision state exactly matches the firmware-bound baseline"
            } catch {
                precisionPreflightStatusText = precisionPreflightFailureText(error)
            }

        case let .baselineMismatch(requestBytes, responseBytes, expected, actual, session):
            let flags = actual.rawFlags(featureVersion: 3)
            let isRecoverableLiveState = actual.controlID
                == MXErgoReadOnlyPrecisionPreflight.controlID
                && actual.mappedControlID == 0
                && (flags == 0 || flags == 0x01)
            if isRecoverableLiveState,
               expectedConnectionGeneration == connectionGeneration,
               rootEvidenceGeneration == connectionGeneration,
               firmwareEvidenceGeneration == connectionGeneration {
                precisionPreflightSnapshot = MXErgoReadOnlyPrecisionPreflightSnapshot(
                    session: session,
                    requestBytes: requestBytes,
                    responseBytes: responseBytes,
                    state: actual
                )
                precisionPreflightEvidenceGeneration = connectionGeneration
                precisionPreflightStatusText =
                    "Live Precision differs from baseline (expected \(hexBytes(expected.rawParameters)); found \(hexBytes(actual.rawParameters))). Review reconnect recovery if the runtime journal is recovery-required."
            } else {
                precisionPreflightStatusText =
                    "Locked: live Precision bytes differ from baseline (expected \(hexBytes(expected.rawParameters)); found \(hexBytes(actual.rawParameters)))"
            }

        case let .protocolError(_, _, code):
            precisionPreflightStatusText = String(
                format: "Device returned HID++ error 0x%02X during Precision preflight",
                code
            )

        case .malformedResponse:
            precisionPreflightStatusText =
                "Malformed correlated Precision response; live trial remains locked"

        case let .outputFailed(_, code):
            precisionPreflightStatusText = String(
                format: "macOS rejected the read-only Precision request (0x%08X)",
                code
            )

        case .timedOut:
            precisionPreflightStatusText =
                "Timed out; this Root epoch is poisoned and no retry will be attempted"

        case .disconnected:
            precisionPreflightStatusText =
                "The MX Ergo disconnected during Precision preflight; no retry will be attempted"

        case .observerStopped:
            precisionPreflightStatusText =
                "Precision preflight was cancelled because the observer stopped"

        case let .rejected(reason):
            precisionPreflightStatusText = precisionPreflightRejectionText(reason)
        }
    }

    private func receive(
        mappedLivePreflightResult result: MXErgoReadOnlyMappedControlPreflightResult,
        expectedJournalData: Data,
        expectedJournal: DeviceStateJournal,
        expectedConnectionGeneration: UInt64
    ) {
        mappedLivePreflightInProgress = false

        switch result {
        case let .success(snapshot):
            do {
                let after = try Data(contentsOf: Self.journalFileURL)
                guard after == expectedJournalData,
                      try journalStore.load() == expectedJournal else {
                    mappedLivePreflightStatusText =
                        "Locked: the baseline journal changed during mapped GET"
                    return
                }
                guard expectedConnectionGeneration == connectionGeneration,
                      rootEvidenceGeneration == connectionGeneration,
                      firmwareEvidenceGeneration == connectionGeneration,
                      reprogFeatureDescriptor?.index == snapshot.featureIndex,
                      reprogFeatureDescriptor?.version == snapshot.featureVersion,
                      snapshot.observations.count
                        == MappedControlsReadOnlyPreflightPlan.maximumPacketCount,
                      snapshot.authorization == .notAuthorizedForExecution else {
                    mappedLivePreflightStatusText =
                        "Locked: mapped GET evidence changed before it could be accepted"
                    return
                }
                for observation in snapshot.observations {
                    guard let entry = expectedJournal.controls.first(where: {
                        $0.controlInfo.controlID == observation.controlID
                    }),
                    entry.baselineReporting.rawParameters == observation.state.rawParameters
                    else {
                        mappedLivePreflightStatusText = String(
                            format: "Locked: CID 0x%04X live GET does not match the saved baseline",
                            observation.controlID
                        )
                        return
                    }
                }
                mappedLivePreflightSnapshot = snapshot
                mappedLivePreflightStatusText =
                    "Live mapped-control GET matches the firmware-bound baseline for all five CIDs; not authorized for SET"
            } catch {
                mappedLivePreflightStatusText = mappedDiversionFailureText(error)
            }

        case let .baselineMismatch(controlID, _, _, expected, actual):
            mappedLivePreflightStatusText = String(
                format: "Locked: CID 0x%04X live GET differs from baseline (expected %@; found %@); no retry",
                controlID,
                hexBytes(expected.rawParameters),
                hexBytes(actual.rawParameters)
            )

        case let .protocolError(controlID, _, _, code):
            mappedLivePreflightStatusText = String(
                format: "Device returned HID++ error 0x%02X while reading CID 0x%04X; no retry",
                code,
                controlID
            )

        case let .malformedResponse(controlID, _, _):
            mappedLivePreflightStatusText = String(
                format: "Malformed correlated GET for CID 0x%04X; no retry",
                controlID
            )

        case let .outputFailed(controlID, _, code):
            mappedLivePreflightStatusText = String(
                format: "macOS rejected the CID 0x%04X GET (0x%08X); no retry",
                controlID,
                code
            )

        case let .timedOut(controlID, _):
            mappedLivePreflightStatusText = String(
                format: "Timed out reading CID 0x%04X; this Root epoch is poisoned and no retry will be attempted",
                controlID
            )

        case let .disconnected(controlID, _):
            mappedLivePreflightStatusText = String(
                format: "The MX Ergo disconnected while reading CID 0x%04X; no retry",
                controlID
            )

        case .observerStopped:
            mappedLivePreflightStatusText =
                "Mapped-control GET preflight was cancelled because the observer stopped"

        case let .rejected(reason):
            mappedLivePreflightStatusText = mappedLivePreflightRejectionText(reason)
        }
    }

    private func rejectionText(_ rejection: MXErgoOneShotRootQueryRejection) -> String {
        switch rejection {
        case .observerNotRunning:
            return "Query rejected because the observer is not running"
        case .alreadyAttempted:
            return "Query rejected because this app run already attempted it"
        case let .matchingDeviceCount(count):
            return "Query rejected: expected one matching device, found \(count)"
        case .missingExpectedOutputReport:
            return "Query rejected: output report 0x11/20 was not advertised"
        case .missingStableIdentity:
            return "Query rejected: the device has no stable recovery identity"
        case .requestRegistrationFailed:
            return "Query rejected by the single-flight correlation guard"
        }
    }

    private func rejectionText(
        _ rejection: MXErgoFirmwareFingerprintRejection
    ) -> String {
        switch rejection {
        case .observerNotRunning:
            return "Firmware discovery rejected because the observer is not running"
        case .alreadyAttempted:
            return "Firmware discovery rejected because this app run already attempted it"
        case let .matchingDeviceCount(count):
            return "Firmware discovery rejected: expected one matching device, found \(count)"
        case .missingExpectedOutputReport:
            return "Firmware discovery rejected: output report 0x11/20 was not advertised"
        case .missingStableIdentity:
            return "Firmware discovery rejected: the device has no stable recovery identity"
        case .requestRegistrationFailed:
            return "Firmware discovery rejected by the single-flight correlation guard"
        }
    }

    private func rejectionText(
        _ rejection: MXErgoReadOnlyControlEnumerationRejection
    ) -> String {
        switch rejection {
        case .observerNotRunning:
            return "Enumeration rejected because the observer is not running"
        case .alreadyAttempted:
            return "Enumeration rejected because this app run already attempted it"
        case let .matchingDeviceCount(count):
            return "Enumeration rejected: expected one matching device, found \(count)"
        case .missingExpectedOutputReport:
            return "Enumeration rejected: output report 0x11/20 was not advertised"
        case .missingStableIdentity:
            return "Enumeration rejected: the device has no stable recovery identity"
        case .featureNotResolvedForCurrentConnection:
            return "Enumeration rejected: resolve 0x1B04 on this connection first"
        case .requestRegistrationFailed:
            return "Enumeration rejected by the single-flight correlation guard"
        }
    }

    private func rejectionText(
        _ rejection: MXErgoReadOnlyReportingSnapshotRejection
    ) -> String {
        switch rejection {
        case .observerNotRunning:
            return "Snapshot rejected because the observer is not running"
        case .alreadyAttempted:
            return "Snapshot rejected because this app run already attempted it"
        case let .matchingDeviceCount(count):
            return "Snapshot rejected: expected one matching device, found \(count)"
        case .missingExpectedOutputReport:
            return "Snapshot rejected: output report 0x11/20 was not advertised"
        case .missingStableIdentity:
            return "Snapshot rejected: the device has no stable recovery identity"
        case .metadataNotEnumeratedForCurrentConnection:
            return "Snapshot rejected: enumerate controls on this connection first"
        case .requestRegistrationFailed:
            return "Snapshot rejected by the single-flight correlation guard"
        }
    }

    private func precisionPreflightRejectionText(
        _ rejection: MXErgoReadOnlyPrecisionPreflightRejection
    ) -> String {
        switch rejection {
        case .observerNotRunning:
            return "Precision preflight rejected because the observer is not running"
        case .alreadyAttempted:
            return "Precision preflight rejected because this app run already attempted it"
        case let .matchingDeviceCount(count):
            return "Precision preflight rejected: expected one matching device, found \(count)"
        case .missingExpectedOutputReport:
            return "Precision preflight rejected: output report 0x11/20 was not advertised"
        case .missingStableIdentity:
            return "Precision preflight rejected: the device has no stable recovery identity"
        case .deviceIdentityMismatch:
            return "Precision preflight locked: the physical device differs from the bound journal"
        case .featureNotResolvedForCurrentConnection:
            return "Precision preflight rejected: resolve 0x1B04 on this connection first"
        case .requestRegistrationFailed:
            return "Precision preflight rejected by the single-flight correlation guard"
        }
    }

    private func mappedLivePreflightRejectionText(
        _ rejection: MXErgoReadOnlyMappedControlPreflightRejection
    ) -> String {
        switch rejection {
        case .observerNotRunning:
            return "Mapped GET rejected because the observer is not running"
        case .alreadyAttempted:
            return "Mapped GET rejected because this app run already attempted it"
        case let .matchingDeviceCount(count):
            return "Mapped GET rejected: expected one matching device, found \(count)"
        case .missingExpectedOutputReport:
            return "Mapped GET rejected: output report 0x11/20 was not advertised"
        case .missingStableIdentity:
            return "Mapped GET rejected: the device has no stable recovery identity"
        case .deviceIdentityMismatch:
            return "Mapped GET locked: the physical device differs from the bound journal"
        case .featureNotResolvedForCurrentConnection:
            return "Mapped GET rejected: resolve 0x1B04 on this connection first"
        case .requestRegistrationFailed:
            return "Mapped GET rejected by the single-flight correlation guard"
        }
    }

    private func hexBytes(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func currentJournalDeviceIdentity(
        firmwareIdentity: String? = nil
    ) throws -> JournalDeviceIdentity {
        guard devices.count == 1,
              let device = devices.first,
              device.isMXErgo,
              device.isBluetooth,
              let vendorID = device.vendorID,
              let productID = device.productID,
              let transport = device.transport,
              device.serialNumber?.isEmpty == false || device.locationID != nil else {
            throw BaselinePersistenceError.deviceIdentityChanged
        }
        return JournalDeviceIdentity(
            deviceID: device.id,
            vendorID: vendorID,
            productID: productID,
            transport: transport,
            serialNumber: device.serialNumber,
            locationID: device.locationID,
            firmwareIdentity: firmwareIdentity
        )
    }

    private func currentJournalDeviceIdentity(
        for journal: DeviceStateJournal
    ) throws -> JournalDeviceIdentity {
        guard journal.device.firmwareIdentity?.isEmpty == false else {
            return try currentJournalDeviceIdentity()
        }
        guard let firmwareFingerprint,
              firmwareEvidenceGeneration == connectionGeneration else {
            throw BaselinePersistenceError.firmwareDiscoveryRequired
        }
        return try currentJournalDeviceIdentity(
            firmwareIdentity: firmwareFingerprint.canonicalIdentity
        )
    }

    private func invalidateFirmwareValidationEvidence(reason: String) {
        invalidateRestorePacketPreview(reason: reason)
        guard firmwareFingerprint != nil || firmwareMigrationPlan != nil else { return }
        firmwareFingerprint = nil
        firmwareEvidenceGeneration = nil
        firmwareMigrationPlan = nil
        firmwareMigrationPlanGeneration = nil
        firmwareFingerprintStatusText = reason
        firmwareMigrationDryRunStatusText = reason
        if firmwareMigrationCommitReceipt == nil, !firmwareMigrationCommitInProgress {
            firmwareMigrationCommitStatusText = reason
        }
    }

    private func firmwareMigrationDryRunFailureText(_ error: Error) -> String {
        if let migrationError = error as? FirmwareIdentityJournalMigrationError {
            switch migrationError {
            case .emptyFirmwareIdentity:
                return "Dry-run rejected: the discovered firmware identity is empty"
            case .journalRequiresRecovery:
                return "Dry-run rejected: the journal contains an unresolved transaction"
            case .deviceIdentityMismatch:
                return "Dry-run rejected: the connected MX Ergo does not match the saved baseline"
            case let .firmwareIdentityConflict(_, discovered):
                return "Dry-run locked: a different firmware identity is already saved (discovered \(discovered))"
            case .malformedSourceJSON:
                return "Dry-run failed closed: the source journal JSON is not eligible for exact-field migration"
            case .invariantViolation:
                return "Dry-run failed closed: the proposal changed more than the firmware identity"
            }
        }
        if let appError = error as? FirmwareMigrationDryRunAppError {
            return "Dry-run failed closed: \(appError.localizedDescription)"
        }
        return "Dry-run failed closed: \(error.localizedDescription)"
    }

    private func firmwareMigrationCommitFailureText(_ error: Error) -> String {
        if let commitError = error as? FirmwareIdentityJournalMigrationCommitError {
            switch commitError {
            case .planNotReady:
                return "Commit rejected: the exact-byte plan is not ready"
            case .sourceBytesMismatch:
                return "Commit locked: the live journal no longer matches the reviewed source bytes"
            case .backupConflict:
                return "Commit locked: an existing backup does not match the reviewed original bytes"
            case .lockUnavailable:
                return "Commit locked: another journal writer holds the migration lock"
            case .nonRegularFile:
                return "Commit locked: the journal or backup is not a regular file"
            case .durableVerificationFailed:
                return "Commit indeterminate: durable read-back verification failed; do not run HID actions"
            case let .posix(operation, code):
                return "Commit indeterminate: \(operation) failed with POSIX code \(code)"
            }
        }
        if let appError = error as? FirmwareMigrationCommitAppError {
            return "Commit rejected: \(appError.localizedDescription)"
        }
        return "Commit failed closed: \(error.localizedDescription)"
    }

    private func invalidateRestorePacketPreview(reason: String) {
        restorePacketPreviewAttempted = false
        restorePacketPlans = []
        restorePacketPreviewStatusText = reason
        restoreTrialSimulationAttempted = false
        restoreTrialSimulationReport = nil
        if !restoreTrialSimulationInProgress {
            restoreTrialSimulationStatusText = reason
        }
        invalidatePrecisionPreflight(reason: reason)
        invalidateMappedControlDiversion(reason: reason)
    }

    private func invalidatePrecisionPreflight(reason: String) {
        precisionPreflightSnapshot = nil
        precisionPreflightEvidenceGeneration = nil
        if !precisionPreflightInProgress {
            precisionPreflightStatusText = reason
        }
        invalidatePrecisionLifecycleReadiness(reason: reason)
        invalidateMappedControlDiversion(reason: reason)
    }

    private func invalidateMappedControlDiversion(reason: String) {
        let hadReview = mappedDiversionAttempted
            || mappedDiversionSnapshot != nil
            || mappedActionPlan != nil
            || mappedEventDelivery != nil
            || mappedPreflightPlan != nil
            || mappedLivePreflightSnapshot != nil
        mappedDiversionSnapshot = nil
        mappedActionPlan = nil
        mappedEventDelivery = nil
        mappedPreflightPlan = nil
        mappedLivePreflightSnapshot = nil
        if hadReview {
            mappedDiversionStatusText = reason
        }
    }

    private func revalidateMappedControlDiversionCompetitors() {
        guard mappedDiversionSnapshot != nil else { return }
        do {
            let competitors = try Self.precisionCompetingProcessScanner().scan(
                excludingProcessIdentifier: ProcessInfo.processInfo.processIdentifier
            )
            guard competitors.isEmpty else {
                invalidateMappedControlDiversion(
                    reason: "Mapped diversion invalidated: competing software launched (\(competitors.map(\.displayName).joined(separator: ", ")))"
                )
                return
            }
        } catch {
            invalidateMappedControlDiversion(
                reason: "Mapped diversion invalidated: the running-application scan failed closed"
            )
        }
    }

    private func revalidateMappedControlDiversionEvidence() {
        guard let snapshot = mappedDiversionSnapshot else { return }
        do {
            let journalData = try Data(contentsOf: Self.journalFileURL)
            guard MappedControlsTemporaryDiversionReadinessAudit
                    .sourceJournalSHA256(journalData)
                    == snapshot.sourceJournalSHA256,
                  snapshot.connectionGeneration == connectionGeneration,
                  rootEvidenceGeneration == connectionGeneration,
                  firmwareEvidenceGeneration == connectionGeneration,
                  reprogFeatureDescriptor?.index == snapshot.plan.featureIndex,
                  reprogFeatureDescriptor?.version == snapshot.plan.featureVersion else {
                invalidateMappedControlDiversion(
                    reason: "Mapped diversion invalidated: journal or connection evidence changed"
                )
                return
            }
            revalidateMappedControlDiversionCompetitors()
        } catch {
            invalidateMappedControlDiversion(
                reason: "Mapped diversion invalidated: the baseline journal could not be revalidated"
            )
        }
    }

    private func invalidatePrecisionLifecycleReadiness(reason: String) {
        let hadReview = precisionReadinessAttempted
            || precisionReadinessSnapshot != nil
        precisionReadinessSnapshot = nil
        if hadReview {
            precisionReadinessStatusText = reason
        }
    }

    private func revalidatePrecisionReadinessCompetitors() {
        guard precisionReadinessSnapshot != nil else { return }
        do {
            let competitors = try Self.precisionCompetingProcessScanner().scan(
                excludingProcessIdentifier: ProcessInfo.processInfo.processIdentifier
            )
            guard competitors.isEmpty else {
                invalidatePrecisionLifecycleReadiness(
                    reason: "Readiness invalidated: competing software launched (\(competitors.map(\.displayName).joined(separator: ", ")))"
                )
                return
            }
        } catch {
            invalidatePrecisionLifecycleReadiness(
                reason: "Readiness invalidated: the running-application scan failed closed"
            )
        }
    }

    private func revalidatePrecisionReadinessEvidence() {
        guard let snapshot = precisionReadinessSnapshot else { return }
        do {
            let journalData = try Data(contentsOf: Self.journalFileURL)
            guard PrecisionTemporaryDiversionReadinessAudit
                    .sourceJournalSHA256(journalData)
                    == snapshot.sourceJournalSHA256,
                  rootEvidenceGeneration == connectionGeneration,
                  firmwareEvidenceGeneration == connectionGeneration,
                  precisionPreflightEvidenceGeneration == connectionGeneration,
                  reprogFeatureDescriptor?.index == snapshot.plan.featureIndex,
                  reprogFeatureDescriptor?.version == snapshot.plan.featureVersion,
                  precisionPreflightSnapshot?.state == snapshot.plan.baseline else {
                invalidatePrecisionLifecycleReadiness(
                    reason: "Readiness invalidated: journal or connection evidence changed"
                )
                return
            }
            revalidatePrecisionReadinessCompetitors()
        } catch {
            invalidatePrecisionLifecycleReadiness(
                reason: "Readiness invalidated: the baseline journal could not be revalidated"
            )
        }
    }

    nonisolated private static func precisionCompetitorDisplayNames() -> [String] {
        let snapshots = NSWorkspace.shared.runningApplications.map { application in
            PrecisionRunningApplicationSnapshot(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                localizedName: application.localizedName
            )
        }
        return PrecisionCompetingProcessClassifier.competitors(
            in: snapshots,
            excludingProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        ).map(\.displayName)
    }

    private static func precisionCompetingProcessScanner()
        -> PrecisionCompetingProcessScanner {
        PrecisionCompetingProcessScanner {
            NSWorkspace.shared.runningApplications.map { application in
                PrecisionRunningApplicationSnapshot(
                    processIdentifier: application.processIdentifier,
                    bundleIdentifier: application.bundleIdentifier,
                    localizedName: application.localizedName
                )
            }
        }
    }

    private func mappedDiversionFailureText(_ error: Error) -> String {
        if let mapped = error as? MappedControlTemporaryDiversionError {
            switch mapped {
            case .unsupportedDevice:
                return "Mapped diversion locked: the journal is not the BLE MX Ergo"
            case .unstableRecoveryIdentity:
                return "Mapped diversion locked: a stable serial, location, and firmware identity are required"
            case .journalRequiresRecovery:
                return "Mapped diversion locked: the baseline journal requires recovery"
            case .featureMismatch:
                return "Mapped diversion locked: REPROG_CONTROLS_V4 index or version changed"
            case let .unsupportedFeatureVersion(version):
                return String(
                    format: "Mapped diversion locked: feature version %d is not the reviewed v3",
                    version
                )
            case let .missingMappedControl(controlID):
                return String(
                    format: "Mapped diversion locked: CID 0x%04X is missing from the baseline",
                    controlID
                )
            case let .unexpectedMappedControl(controlID):
                return String(
                    format: "Mapped diversion locked: unexpected divertable CID 0x%04X",
                    controlID
                )
            case let .controlNotEligible(controlID):
                return String(
                    format: "Mapped diversion locked: CID 0x%04X is not physical, reprogrammable, and divertable",
                    controlID
                )
            case let .baselineNotClean(controlID):
                return String(
                    format: "Mapped diversion locked: CID 0x%04X is not at a clean temporary-diversion baseline",
                    controlID
                )
            case .invalidMutation:
                return "Mapped diversion locked: the reviewed packet projection was inconsistent"
            }
        }
        if let readiness = error as? MappedControlsTemporaryDiversionReadinessError {
            switch readiness {
            case let .competingProcesses(processes):
                return "Mapped diversion locked: quit competing software (\(processes.map(\.displayName).joined(separator: ", ")))"
            case .journalChangedDuringReview:
                return "Mapped diversion locked: the baseline journal changed during review"
            case .journalRequiresRecovery:
                return "Mapped diversion locked: the baseline journal requires recovery"
            case .staleConnectionEvidence:
                return "Mapped diversion locked: Root or firmware evidence is stale"
            case .sessionMismatch:
                return "Mapped diversion locked: the physical device or connection epoch changed"
            case .featureMismatch:
                return "Mapped diversion locked: REPROG_CONTROLS_V4 index or version changed"
            }
        }
        if let preflight = error as? MappedControlReadOnlyPreflightError {
            switch preflight {
            case .precisionControlExcluded:
                return "Mapped diversion locked: Precision CID 00ED is not a mapped-control GET"
            case let .missingMappedControl(controlID):
                return String(
                    format: "Mapped diversion locked: GET preflight is missing CID 0x%04X",
                    controlID
                )
            case let .unexpectedMappedControl(controlID):
                return String(
                    format: "Mapped diversion locked: unexpected GET CID 0x%04X",
                    controlID
                )
            case let .verificationRequestMismatch(controlID):
                return String(
                    format: "Mapped diversion locked: CID 0x%04X GET packet is not the reviewed verification request",
                    controlID
                )
            case let .unexpectedResponse(controlID):
                return String(
                    format: "Mapped diversion locked: CID 0x%04X GET response was not the requested control",
                    controlID
                )
            case let .baselineMismatch(controlID):
                return String(
                    format: "Mapped diversion locked: CID 0x%04X live GET does not match the saved baseline",
                    controlID
                )
            case .sequenceAlreadyComplete:
                return "Mapped diversion locked: the GET sequence is already complete"
            case .sequenceAlreadyFailed:
                return "Mapped diversion locked: the GET sequence already failed closed"
            }
        }
        if let validation = error as? MXErgoMappedControlPreflightValidationError {
            switch validation {
            case .invalidDeviceIdentity:
                return "Mapped GET locked: the connected MX Ergo identity is not firmware-bound"
            case .unsupportedFeature:
                return "Mapped GET locked: REPROG_CONTROLS_V4 index or version changed"
            case .invalidPlan:
                return "Mapped GET locked: the reviewed GET preflight is not eligible"
            }
        }
        if let actions = error as? MappedControlActionPlanError {
            switch actions {
            case .precisionControlExcluded:
                return "Mapped diversion locked: Precision CID 00ED is not a mapped-control action"
            case let .missingMappedControl(controlID):
                return String(
                    format: "Mapped diversion locked: action plan is missing CID 0x%04X",
                    controlID
                )
            case let .unexpectedMappedControl(controlID):
                return String(
                    format: "Mapped diversion locked: unexpected action CID 0x%04X",
                    controlID
                )
            }
        }
        if let appError = error as? MappedDiversionAppError {
            return "Mapped diversion locked: \(appError.localizedDescription)"
        }
        return "Mapped diversion review failed closed: \(error.localizedDescription)"
    }

    private func precisionReadinessFailureText(_ error: Error) -> String {
        if let readiness = error as? PrecisionTemporaryDiversionReadinessError {
            switch readiness {
            case let .competingProcesses(processes):
                return "Readiness locked: quit competing software (\(processes.map(\.displayName).joined(separator: ", ")))"
            case .journalChangedDuringReview:
                return "Readiness locked: the baseline journal changed during review"
            case .journalRequiresRecovery:
                return "Readiness locked: the baseline journal requires recovery"
            case .staleConnectionEvidence:
                return "Readiness locked: Root, firmware, or preflight evidence is stale"
            case .sessionMismatch:
                return "Readiness locked: the physical device or connection epoch changed"
            case .featureMismatch:
                return "Readiness locked: REPROG_CONTROLS_V4 index or version changed"
            case .precisionPreflightMismatch:
                return "Readiness locked: live Precision is not a reviewed baseline or active state"
            case .runtimeJournalChangedDuringReview:
                return "Readiness locked: the runtime journal changed during recover review"
            case .runtimeJournalNotEligible:
                return "Readiness locked: the runtime journal is not eligible for reconnect recovery"
            }
        }
        if let appError = error as? PrecisionReadinessAppError {
            return "Readiness locked: \(appError.localizedDescription)"
        }
        return "Readiness scan failed closed: \(error.localizedDescription)"
    }

    private func isReconnectRecoveryEligible(
        _ envelope: DeviceTransactionEnvelope
    ) -> Bool {
        guard !envelope.controls.contains(where: { $0.phase == .conflicted }),
              envelope.dirtyControlIDs.allSatisfy({
                  $0 == PrecisionTemporaryDiversionPlan.controlID
              }),
              let control = try? envelope.control(
                PrecisionTemporaryDiversionPlan.controlID
              ) else {
            return false
        }
        switch (envelope.status, control.phase) {
        case (.running, .appliedVerified),
             (.recoveryRequired, .applyMayHaveOccurred),
             (.recoveryRequired, .restoreMayHaveOccurred):
            return !envelope.hasAmbiguousRestoreSET
        default:
            return false
        }
    }

    private func precisionPreflightFailureText(_ error: Error) -> String {
        if let validation = error as? MXErgoPrecisionPreflightValidationError {
            switch validation {
            case .invalidDeviceIdentity:
                return "Precision preflight locked: the firmware-bound device identity is invalid"
            case .unsupportedFeature:
                return "Precision preflight locked: only REPROG_CONTROLS version 3 is validated"
            case .invalidBaseline:
                return "Precision preflight locked: CID 00ED is not at the exact clean baseline"
            case .unexpectedResponse:
                return "Precision preflight locked: the correlated response addressed another control"
            }
        }
        if let appError = error as? PrecisionPreflightAppError {
            return "Precision preflight failed closed: \(appError.localizedDescription)"
        }
        return "Precision preflight failed closed: \(error.localizedDescription)"
    }

    private func restorePacketPreviewFailureText(_ error: Error) -> String {
        if let planningError = error as? RestoreOnlyReportingPlanError {
            switch planningError {
            case .journalRequiresRecovery:
                return "Preview locked: the baseline journal requires recovery"
            case let .unsupportedFeatureVersion(version):
                return "Preview locked: REPROG_CONTROLS version \(version) is not validated"
            case let .featureVersionMismatch(saved, current):
                return "Preview locked: saved feature v\(saved) does not match current v\(current)"
            case let .controlIsNotPhysical(controlID):
                return String(format: "Preview rejected virtual CID 0x%04X", controlID)
            case let .controlIsNotReprogrammable(controlID):
                return String(format: "Preview rejected non-reprogrammable CID 0x%04X", controlID)
            case let .controlIsNotDivertable(controlID):
                return String(format: "Preview rejected non-divertable CID 0x%04X", controlID)
            case let .unsupportedBaselineFlags(controlID, flags):
                return String(
                    format: "Preview rejected unknown flags 0x%04X for CID 0x%04X",
                    flags,
                    controlID
                )
            case let .baselineFieldMismatch(controlID):
                return String(format: "Preview rejected inconsistent CID 0x%04X baseline", controlID)
            case let .unsupportedPersistentState(controlID):
                return String(format: "Preview rejected unsupported persistent state for CID 0x%04X", controlID)
            case let .unsupportedRawXYState(controlID):
                return String(format: "Preview rejected unsupported raw-XY state for CID 0x%04X", controlID)
            case let .mappedControlUnavailable(controlID, mappedControlID):
                return String(
                    format: "Preview rejected CID 0x%04X mapping to unknown CID 0x%04X",
                    controlID,
                    mappedControlID
                )
            case let .mappedControlOutsideGroupMask(controlID, mappedControlID):
                return String(
                    format: "Preview rejected CID 0x%04X mapping to disallowed CID 0x%04X",
                    controlID,
                    mappedControlID
                )
            case .noEligiblePhysicalControls:
                return "Preview rejected: the baseline has no physical divertable controls"
            case .unexpectedSetAcknowledgement:
                return "Preview self-check rejected a non-exact SET acknowledgement"
            }
        }
        if let appError = error as? RestorePacketPreviewAppError {
            return "Preview failed closed: \(appError.localizedDescription)"
        }
        return "Preview failed closed: \(error.localizedDescription)"
    }

    private func recoveryRehearsalFailureText(_ error: Error) -> String {
        if let planningError = error as? DeviceRecoveryPlanningError {
            switch planningError {
            case .deviceIdentityMismatch:
                return "Rehearsal rejected: the connected MX Ergo does not match the saved baseline"
            case .journalAlreadyRequiresRecovery:
                return "Rehearsal rejected: the journal already contains an unresolved transaction"
            case let .controlNotAtVerifiedBaseline(controlID):
                return String(
                    format: "Rehearsal rejected: CID 0x%04X is not at a verified baseline",
                    controlID
                )
            case let .finalStateNotRestored(controlID):
                return String(
                    format: "Rehearsal failed closed: CID 0x%04X did not reach restored-verified",
                    controlID
                )
            }
        }
        return "Rehearsal failed closed: \(error.localizedDescription)"
    }

    private func transactionSimulationFailureText(_ error: Error) -> String {
        if let appError = error as? TransactionSimulationAppError {
            return "Simulation failed closed: \(appError.localizedDescription)"
        }
        return "Simulation failed closed: \(error.localizedDescription)"
    }

    private func record(_ intents: [ControllerIntent]) {
        guard let intent = intents.last else { return }
        lastIntent = intent

        guard audioExecutionEnabled else { return }
        switch intent {
        case .toggleMute:
            audioController.toggleMute()
        case let .volumeUp(steps):
            audioController.enqueueVolumeSteps(steps)
        case let .volumeDown(steps):
            audioController.enqueueVolumeSteps(-steps)
        case .desktopLeft, .desktopRight, .navigateBack, .navigateForward, .missionControl:
            break
        }
    }
}

private enum BaselinePersistenceError: LocalizedError {
    case deviceIdentityChanged
    case firmwareDiscoveryRequired
    case journalAlreadyExists
    case missingStableIdentity

    var errorDescription: String? {
        switch self {
        case .deviceIdentityChanged:
            return "the connected device identity changed before persistence"
        case .firmwareDiscoveryRequired:
            return "fresh firmware discovery is required for this bound recovery journal"
        case .journalAlreadyExists:
            return "a recovery journal already exists and was not overwritten"
        case .missingStableIdentity:
            return "the device does not expose a stable recovery identity"
        }
    }
}

private enum RecoveryRehearsalAppError: LocalizedError {
    case missingJournal
    case journalChangedDuringRehearsal

    var errorDescription: String? {
        switch self {
        case .missingJournal:
            return "the verified baseline journal is missing"
        case .journalChangedDuringRehearsal:
            return "the recovery journal changed during the no-write rehearsal"
        }
    }
}

private enum FirmwareMigrationDryRunAppError: LocalizedError {
    case missingJournal
    case journalChangedDuringDryRun

    var errorDescription: String? {
        switch self {
        case .missingJournal:
            return "the verified schema-v2 baseline journal is missing"
        case .journalChangedDuringDryRun:
            return "the live journal changed during migration planning"
        }
    }
}

private enum FirmwareMigrationCommitAppError: LocalizedError {
    case connectionEvidenceChanged
    case committedJournalVerificationFailed

    var errorDescription: String? {
        switch self {
        case .connectionEvidenceChanged:
            return "the connected device or firmware evidence changed after the dry-run"
        case .committedJournalVerificationFailed:
            return "the committed journal did not decode to the reviewed target"
        }
    }
}

private enum MappedDiversionAppError: LocalizedError {
    case missingJournal

    var errorDescription: String? {
        switch self {
        case .missingJournal:
            return "the verified firmware-bound baseline journal is missing"
        }
    }
}

private enum RestorePacketPreviewAppError: LocalizedError {
    case missingJournal
    case deviceIdentityMismatch
    case liveJournalChanged
    case connectionEvidenceChanged

    var errorDescription: String? {
        switch self {
        case .missingJournal:
            return "the verified firmware-bound baseline journal is missing"
        case .deviceIdentityMismatch:
            return "the connected MX Ergo does not exactly match the saved device and firmware"
        case .liveJournalChanged:
            return "the live baseline journal changed during offline planning"
        case .connectionEvidenceChanged:
            return "the connection changed while the offline plan was being built"
        }
    }
}

private enum TransactionSimulationAppError: LocalizedError {
    case missingJournal
    case deviceIdentityMismatch
    case liveJournalChanged

    var errorDescription: String? {
        switch self {
        case .missingJournal:
            return "the verified schema-v2 baseline journal is missing"
        case .deviceIdentityMismatch:
            return "the connected MX Ergo does not match the saved baseline"
        case .liveJournalChanged:
            return "the live baseline journal changed during isolated simulation"
        }
    }
}

private enum RestoreTrialSimulationAppError: LocalizedError {
    case missingJournal
    case deviceIdentityMismatch
    case liveJournalChanged
    case connectionEvidenceChanged

    var errorDescription: String? {
        switch self {
        case .missingJournal:
            return "the verified firmware-bound baseline journal is missing"
        case .deviceIdentityMismatch:
            return "the connected MX Ergo does not exactly match the saved baseline"
        case .liveJournalChanged:
            return "the live baseline journal changed during isolated trial execution"
        case .connectionEvidenceChanged:
            return "the connection evidence changed during isolated trial execution"
        }
    }
}

private enum PrecisionPreflightAppError: LocalizedError {
    case missingJournal
    case missingPrecisionBaseline
    case deviceIdentityMismatch
    case connectionEvidenceChanged
    case liveJournalChanged

    var errorDescription: String? {
        switch self {
        case .missingJournal:
            return "the verified firmware-bound baseline journal is missing"
        case .missingPrecisionBaseline:
            return "Precision CID 00ED is missing from the saved baseline"
        case .deviceIdentityMismatch:
            return "the connected MX Ergo does not exactly match the saved device and firmware"
        case .connectionEvidenceChanged:
            return "the device, Root feature, or firmware evidence changed during preflight"
        case .liveJournalChanged:
            return "the live baseline journal changed during the read-only preflight"
        }
    }
}

private enum PrecisionReadinessAppError: LocalizedError {
    case missingJournal

    var errorDescription: String? {
        switch self {
        case .missingJournal:
            return "the verified firmware-bound baseline journal is missing"
        }
    }
}
