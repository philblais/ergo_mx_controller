import AppKit
import MXErgoCore
import MXErgoHIDPP
import SwiftUI

struct ObserverMenuView: View {
    @ObservedObject var model: AppModel
    @State private var showingRootQueryConfirmation = false
    @State private var showingFirmwareFingerprintConfirmation = false
    @State private var showingFirmwareMigrationDryRunConfirmation = false
    @State private var showingFirmwareMigrationCommitConfirmation = false
    @State private var showingRestorePacketPreviewConfirmation = false
    @State private var showingRestoreTrialSimulationConfirmation = false
    @State private var showingPrecisionPreflightConfirmation = false
    @State private var showingMappedPreflightConfirmation = false
    @State private var showingControlEnumerationConfirmation = false
    @State private var showingReportingSnapshotConfirmation = false
    @State private var showingRecoveryRehearsalConfirmation = false
    @State private var showingTransactionSimulationConfirmation = false
    @State private var showingRuntimeOwnerBindConfirmation = false
    @State private var showingRuntimeOwnerAdmitConfirmation = false
    @State private var showingRuntimeOwnerRecoverConfirmation = false
    @State private var showingRuntimeOwnerDeactivateConfirmation = false
    @State private var showingRuntimeOwnerRolloverConfirmation = false
    @State private var showingJournalRotationConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            permissionSection
            connectionSection
            protocolSafetySection
            reportSection
            scrollAxisSection
            calibrationSection
            intentPreviewSection
            audioTestSection

            Divider()

            HStack {
                if model.status == .stopped {
                    Button("Start observer") { model.start() }
                        .disabled(model.runtimeOwnerBlocksRestart)
                } else {
                    Button("Stop observer") { model.stop() }
                        .disabled(
                            model.rootQueryInProgress
                                || model.firmwareFingerprintInProgress
                                || model.controlEnumerationInProgress
                                || model.reportingSnapshotInProgress
                                || model.recoveryRehearsalInProgress
                                || model.transactionSimulationInProgress
                                || model.restoreTrialSimulationInProgress
                                || model.precisionPreflightInProgress
                                || model.firmwareMigrationCommitInProgress
                        )
                }

                Spacer()

                Button("Quit") {
                    model.quit()
                }
            }
        }
        .padding(16)
        .frame(width: 370)
        .onAppear { model.refreshPermissionStatus() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: model.menuBarIcon)
                    .font(.title2)
                Text("MX Ergo Controller")
                    .font(.headline)
                Spacer()
                Text("AUDIO OPT-IN")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.blue.opacity(0.14), in: Capsule())
            }

            Text("This build does not replace BetterTouchTool for thumb, tilt, or wheel-click actions. Those stay with BTT or native macOS. After Input Monitoring is granted, this window should show reports when you press buttons. Precision mute/volume only work after Bind → Admit, with Audio test on.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(model.inputMonitoringGranted ? "Input Monitoring granted" : "Input Monitoring needed")
            } icon: {
                Image(systemName: model.inputMonitoringGranted ? "checkmark.circle.fill" : "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(model.inputMonitoringGranted ? .green : .orange)
            }

            if !model.inputMonitoringGranted {
                Button("Open Input Monitoring Settings") {
                    model.openInputMonitoringSettings()
                }
                .controlSize(.small)
            }

            Label {
                Text(
                    model.accessibilityGranted
                        ? "Accessibility granted"
                        : "Accessibility not granted (not needed yet)"
                )
            } icon: {
                Image(
                    systemName: model.accessibilityGranted
                        ? "checkmark.circle.fill"
                        : "circle.dashed"
                )
                .foregroundStyle(model.accessibilityGranted ? .green : .secondary)
            }

            if !model.accessibilityGranted {
                Button("Open Accessibility Settings") {
                    model.openAccessibilitySettings()
                }
                .controlSize(.small)
                Text("Required only to post synthetic events, which this build never does. Replacing BetterTouchTool for the thumb buttons, wheel tilt and wheel click will need it; the MX Ergo itself is not affected either way.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(connectionTitle, systemImage: model.devices.isEmpty ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
                .font(.subheadline.weight(.medium))

            if let device = model.devices.first {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    detailRow("Product", device.productName ?? "Unknown")
                    detailRow("VID / PID", hexPair(device))
                    detailRow("Transport", device.transport ?? "Unknown")
                    detailRow("Interfaces", String(model.devices.count))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var reportSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Input reports")
                .font(.subheadline.weight(.medium))

            if let report = model.lastReport {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    detailRow("Observed", String(report.count))
                    detailRow("Last report", "ID \(report.reportID), \(report.length) bytes")
                    detailRow("Preview", report.preview.map { String(format: "%02X", $0) }.joined(separator: " "))
                    if let wheelNotches = model.lastWheelNotches {
                        detailRow("Wheel events", String(model.wheelEventCount))
                        detailRow("Last wheel", wheelDescription(wheelNotches))
                    }
                    if let tiltNotches = model.lastTiltNotches {
                        detailRow("Tilt events", String(model.tiltEventCount))
                        detailRow("Last tilt", tiltDescription(tiltNotches))
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text(reportPlaceholder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One measurement, deliberately kept next to the tilt counter it must be
    /// read against: the IOHID row shows the device's own AC Pan value, this
    /// one shows what macOS turned it into.
    private var scrollAxisSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { model.scrollDiagnosticsEnabled },
                set: { model.setScrollDiagnosticsEnabled($0) }
            )) {
                Text("Scroll axis diagnostics")
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(.switch)
            .disabled(model.scrollDiagnosticsGateFailureText != nil
                && !model.scrollDiagnosticsEnabled)

            if let blocked = model.scrollDiagnosticsGateFailureText,
               !model.scrollDiagnosticsEnabled {
                Text(blocked)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if model.scrollDiagnosticsEnabled {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    detailRow("Scroll events", String(model.scrollTapEventCount))
                    detailRow(
                        "Last scroll",
                        model.lastScrollTapSample?.description ?? "None yet"
                    )
                    detailRow(
                        "Last horizontal",
                        model.lastHorizontalScrollTapSample?.description ?? "None yet"
                    )
                    detailRow(
                        "Preference",
                        NaturalScrollDirection.description(
                            isEnabled: model.naturalScrollingEnabled
                        )
                    )
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                Text("Tilt the wheel left, then right, and read \"Last horizontal\". Do not use the trackpad while this is on—a trackpad's horizontal scroll is continuous, the trackball's is discrete. Nothing is suppressed and the MX Ergo is not written to.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Off. Turn on only to record which sign of the horizontal scroll delta a left tilt produces.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var protocolSafetySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("HID++ protocol foundation", systemImage: "shield.checkered")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("READ-ONLY + JOURNAL")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.14), in: Capsule())
            }

            Label(
                model.hidppProtocolFoundationReady
                    ? "Packet validation and recovery journal are ready"
                    : "Protocol foundation unavailable",
                systemImage: model.hidppProtocolFoundationReady
                    ? "checkmark.circle.fill"
                    : "xmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(model.hidppProtocolFoundationReady ? .green : .red)

            Label(
                model.recoveryJournalStatus,
                systemImage: model.recoveryJournalNeedsAttention
                    ? "exclamationmark.triangle.fill"
                    : "externaldrive.badge.checkmark"
            )
            .font(.caption)
            .foregroundStyle(model.recoveryJournalNeedsAttention ? .orange : .secondary)

            safetyGateLabel(
                model.hidppOutputReportStatusText,
                state: model.hidppLongOutputReportAdvertised
            )

            safetyGateLabel(
                model.recoveryIdentityStatusText,
                state: model.stableRecoveryIdentityAvailable
            )

            Divider()

            Text("One-shot read-only query")
                .font(.caption.weight(.semibold))

            Text("Outgoing: \(model.rootQueryRequestText)")
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                model.rootQueryStatusText,
                systemImage: model.rootQuerySucceeded
                    ? "checkmark.circle.fill"
                    : model.rootQueryInProgress
                        ? "hourglass"
                        : "lock.open"
            )
            .font(.caption)
            .foregroundStyle(model.rootQuerySucceeded ? .green : .secondary)

            if let response = model.rootQueryResponseText {
                Text("Response: \(response)")
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Review one-shot query…") {
                showingRootQueryConfirmation = true
            }
            .controlSize(.small)
            .disabled(model.rootQueryGateFailureText != nil)
            .alert("Send one read-only HID++ query?", isPresented: $showingRootQueryConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Send exactly once") { model.performOneShotRootQuery() }
            } message: {
                Text("BetterTouchTool must be fully quit and the MX Ergo must have been powered off and on. The app will send exactly these 20 bytes with no retry:\n\n\(model.rootQueryRequestText)")
            }

            if let gateFailure = model.rootQueryGateFailureText, !model.rootQueryAttempted {
                Text(gateFailure)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Read-only firmware fingerprint")
                .font(.caption.weight(.semibold))

            Label(
                model.firmwareFingerprintStatusText,
                systemImage: model.firmwareFingerprint != nil
                    ? "checkmark.shield.fill"
                    : model.firmwareFingerprintInProgress
                        ? "hourglass"
                        : "cpu"
            )
            .font(.caption)
            .foregroundStyle(model.firmwareFingerprint != nil ? .green : .secondary)

            if let fingerprint = model.firmwareFingerprint {
                VStack(alignment: .leading, spacing: 3) {
                    Text(firmwareDeviceDescription(fingerprint))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .textSelection(.enabled)
                    ForEach(fingerprint.entities, id: \.index) { entity in
                        Text(firmwareEntityDescription(entity))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                    Text("Canonical identity captured in memory only; recovery journal unchanged")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }

            Button("Review firmware discovery…") {
                showingFirmwareFingerprintConfirmation = true
            }
            .controlSize(.small)
            .disabled(model.firmwareFingerprintGateFailureText != nil)
            .alert(
                "Read the MX Ergo firmware fingerprint?",
                isPresented: $showingFirmwareFingerprintConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Discover exactly once") {
                    model.performReadOnlyFirmwareFingerprint()
                }
            } message: {
                Text("The app will resolve read-only Device Information feature 0x0003, read one static device record, then read each reported firmware entity sequentially. The sequence is capped at 18 packets, has no retry or SET function, and will not change the recovery journal or the MX Ergo.")
            }

            if let gateFailure = model.firmwareFingerprintGateFailureText,
               !model.firmwareFingerprintAttempted {
                Text(gateFailure)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Firmware identity migration dry-run")
                .font(.caption.weight(.semibold))

            Label(
                model.firmwareMigrationDryRunStatusText,
                systemImage: model.firmwareMigrationPlan != nil
                    ? "checkmark.shield.fill"
                    : "doc.badge.gearshape"
            )
            .font(.caption)
            .foregroundStyle(model.firmwareMigrationPlan != nil ? .green : .secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let plan = model.firmwareMigrationPlan {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Schema v\(plan.originalJournal.schemaVersion) • transaction preserved")
                    if plan.changesExactlyFirmwareIdentity {
                        Text("Proposed change: device.firmwareIdentity")
                    } else {
                        Text("No persistent change is required")
                    }
                    Text("No journal bytes were written and no HID request was sent")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2.monospacedDigit())
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }

            Button("Review migration dry-run…") {
                showingFirmwareMigrationDryRunConfirmation = true
            }
            .controlSize(.small)
            .disabled(model.firmwareMigrationDryRunGateFailureText != nil)
            .alert(
                "Validate the firmware identity migration?",
                isPresented: $showingFirmwareMigrationDryRunConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Run without writing") {
                    model.performFirmwareIdentityMigrationDryRun()
                }
            } message: {
                Text("The app will decode the existing recovery journal, verify the connected device and discovered firmware identity, then construct an in-memory proposal. It will fail unless device.firmwareIdentity is the only proposed difference. The journal file and MX Ergo will remain untouched.")
            }

            if let gateFailure = model.firmwareMigrationDryRunGateFailureText,
               !model.firmwareMigrationDryRunAttempted {
                Text(gateFailure)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Durable firmware identity commit")
                .font(.caption.weight(.semibold))

            Label(
                model.firmwareMigrationCommitStatusText,
                systemImage: model.firmwareMigrationCommitReceipt != nil
                    ? "checkmark.seal.fill"
                    : model.firmwareMigrationCommitInProgress
                        ? "hourglass"
                        : "externaldrive.badge.plus"
            )
            .font(.caption)
            .foregroundStyle(
                model.firmwareMigrationCommitReceipt != nil ? .green : .secondary
            )
            .fixedSize(horizontal: false, vertical: true)

            if let receipt = model.firmwareMigrationCommitReceipt {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Schema v2 • transaction \(receipt.transactionID.uuidString.prefix(8))")
                    Text("Target SHA-256: \(receipt.targetSHA256)")
                        .textSelection(.enabled)
                    Text("Original-byte backup: \(receipt.backupURL.path)")
                        .textSelection(.enabled)
                    Text("No HID command was sent")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2.monospacedDigit())
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }

            Button("Review durable identity commit…") {
                showingFirmwareMigrationCommitConfirmation = true
            }
            .controlSize(.small)
            .disabled(model.firmwareMigrationCommitGateFailureText != nil)
            .alert(
                "Commit the firmware identity to the recovery journal?",
                isPresented: $showingFirmwareMigrationCommitConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Commit journal metadata", role: .destructive) {
                    model.commitFirmwareIdentityMigration()
                }
            } message: {
                Text(model.firmwareMigrationCommitConfirmationText)
            }

            if let gateFailure = model.firmwareMigrationCommitGateFailureText,
               !model.firmwareMigrationCommitAttempted,
               model.firmwareMigrationCommitReceipt == nil {
                Text(gateFailure)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Restore-only packet preview")
                .font(.caption.weight(.semibold))

            Label(
                model.restorePacketPreviewStatusText,
                systemImage: !model.restorePacketPlans.isEmpty
                    ? "checkmark.shield.fill"
                    : "doc.text.magnifyingglass"
            )
            .font(.caption)
            .foregroundStyle(!model.restorePacketPlans.isEmpty ? .green : .secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !model.restorePacketPlans.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(model.restorePacketPlans.count) physical controls • feature v3 • no sender exists")
                        .font(.caption2.monospacedDigit().weight(.medium))
                    ForEach(model.restorePacketPlans, id: \.controlID) { plan in
                        Text(restorePacketDescription(plan))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("A SET echo would be treated only as acknowledgement; each plan requires the separate GET read-back shown above before restoration can be verified.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }

            Button("Review offline restore packets…") {
                showingRestorePacketPreviewConfirmation = true
            }
            .controlSize(.small)
            .disabled(model.restorePacketPreviewGateFailureText != nil)
            .alert(
                "Build restore packets without sending them?",
                isPresented: $showingRestorePacketPreviewConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Build without sending") {
                    model.performRestoreOnlyPacketPreview()
                }
            } message: {
                Text("The app will read the firmware-bound baseline and construct feature-v3 SetCidReporting plus GetCidReporting verification packets entirely in memory. It will not write the journal, call IOHID output, or change the MX Ergo. This build has no production SET sender.")
            }

            if let gateFailure = model.restorePacketPreviewGateFailureText,
               !model.restorePacketPreviewAttempted,
               model.restorePacketPlans.isEmpty {
                Text(gateFailure)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Dormant Precision trial self-test")
                .font(.caption.weight(.semibold))

            Label(
                model.restoreTrialSimulationStatusText,
                systemImage: model.restoreTrialSimulationReport != nil
                    ? "checkmark.shield.fill"
                    : model.restoreTrialSimulationInProgress
                        ? "hourglass"
                        : "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(
                model.restoreTrialSimulationReport != nil ? .green : .secondary
            )
            .fixedSize(horizontal: false, vertical: true)

            if let report = model.restoreTrialSimulationReport {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Precision CID 00ED • final \(report.finalPhase.rawValue)")
                    Text("\(report.durableCommitCount) durable commits • \(report.setAttemptCount) scripted SET • \(report.readBackCount) independent reads")
                    Text("\(report.liveBaselineReadCount) exact live-baseline validations • \(report.operationLeaseCount) operation-wide lease")
                    Text("SET  \(report.setRequestBytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
                    Text("GET  \(report.verificationRequestBytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
                    Text("Isolated transport only; the live journal and MX Ergo were unchanged")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }

            Button("Review dormant trial self-test…") {
                showingRestoreTrialSimulationConfirmation = true
            }
            .controlSize(.small)
            .disabled(model.restoreTrialSimulationGateFailureText != nil)
            .alert(
                "Run the isolated restore-only trial?",
                isPresented: $showingRestoreTrialSimulationConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Run isolated trial") {
                    model.performRestoreOnlyHardwareTrialSimulation()
                }
            } message: {
                Text("The app will create a separate temporary trial journal, durably arm one Precision-only SET (flags 02, mapping 0000), consume a one-use authorization, simulate one exact acknowledgement, and require a separate exact baseline GET. It uses an isolated scripted transport: it does not call IOHID, write the live baseline, or change the MX Ergo.")
            }

            if let gateFailure = model.restoreTrialSimulationGateFailureText,
               !model.restoreTrialSimulationAttempted,
               model.restoreTrialSimulationReport == nil {
                Text(gateFailure)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Live read-only Precision preflight")
                .font(.caption.weight(.semibold))

            Label(
                model.precisionPreflightStatusText,
                systemImage: model.precisionPreflightSnapshot != nil
                    ? "checkmark.shield.fill"
                    : model.precisionPreflightInProgress
                        ? "hourglass"
                        : "waveform.path.ecg.rectangle"
            )
            .font(.caption)
            .foregroundStyle(
                model.precisionPreflightSnapshot != nil ? .green : .secondary
            )
            .fixedSize(horizontal: false, vertical: true)

            if let snapshot = model.precisionPreflightSnapshot {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Precision CID 00ED • Root epoch \(snapshot.session.connectionEpoch)")
                    Text("Flags \(String(format: "%04X", snapshot.state.rawFlags(featureVersion: snapshot.session.featureVersion))) • map \(String(format: "%04X", snapshot.state.mappedControlID))")
                    Text("GET  \(snapshot.requestBytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
                    Text("RESP \(snapshot.responseBytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
                    Text("One live GET only; no SET, retry, or journal write")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }

            Button("Review live Precision preflight…") {
                showingPrecisionPreflightConfirmation = true
            }
            .controlSize(.small)
            .disabled(model.precisionPreflightGateFailureText != nil)
            .alert(
                "Read the live Precision state exactly once?",
                isPresented: $showingPrecisionPreflightConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Send one read-only GET") {
                    model.performReadOnlyPrecisionPreflight()
                }
            } message: {
                Text("BetterTouchTool must remain fully quit. The app will send exactly one GetCidReporting request for Precision CID 00ED, with no retry:\n\n\(model.precisionPreflightRequestText)\n\nIt will require the same physical device, Root epoch, firmware identity, and exact saved baseline bytes. No SET command or journal write is reachable from this action.")
            }

            if let gateFailure = model.precisionPreflightGateFailureText,
               !model.precisionPreflightAttempted,
               model.precisionPreflightSnapshot == nil {
                Text(gateFailure)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Precision lifecycle readiness (software-only)")
                .font(.caption.weight(.semibold))

            Label(
                model.precisionReadinessStatusText,
                systemImage: model.precisionReadinessSnapshot != nil
                    ? "checkmark.shield.fill"
                    : "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(
                model.precisionReadinessSnapshot != nil ? .green : .secondary
            )
            .fixedSize(horizontal: false, vertical: true)

            if let snapshot = model.precisionReadinessSnapshot {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Precision CID 00ED • feature index \(String(format: "0x%02X", snapshot.plan.featureIndex))")
                    Text("Journal SHA-256 \(snapshot.sourceJournalSHA256)")
                    Text("APPLY   \(snapshot.plan.applySetRequest.bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
                    Text("RESTORE \(snapshot.plan.restoreSetRequest.bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
                    Text("NOT AUTHORIZED • no coordinator, transaction journal, transport, or HID operation")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }

            Button("Review Precision lifecycle readiness…") {
                model.performPrecisionLifecycleReadinessReview()
            }
            .controlSize(.small)
            .disabled(model.precisionReadinessGateFailureText != nil)

            if let gateFailure = model.precisionReadinessGateFailureText,
               model.precisionReadinessSnapshot == nil {
                Text(gateFailure)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("This review only scans running apps and validates in-memory values. It cannot activate, deactivate, or recover Precision.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Mapped-control diversion (software-only)")
                .font(.caption.weight(.semibold))

            Label(
                model.mappedDiversionStatusText,
                systemImage: model.mappedDiversionSnapshot != nil
                    ? "checkmark.shield.fill"
                    : "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(model.mappedDiversionSnapshot != nil ? .green : .secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let snapshot = model.mappedDiversionSnapshot {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(snapshot.plan.controls.count) mapped CIDs • feature index \(String(format: "0x%02X", snapshot.plan.featureIndex)) • v\(snapshot.plan.featureVersion)")
                    Text("Journal SHA-256 \(snapshot.sourceJournalSHA256)")
                    ForEach(snapshot.plan.controls, id: \.controlID) { control in
                        Text(mappedControlDescription(control))
                            .textSelection(.enabled)
                    }
                    if let actions = model.mappedActionPlan {
                        ForEach(actions.bindings, id: \.control.rawValue) { binding in
                            Text(mappedActionDescription(binding))
                                .textSelection(.enabled)
                        }
                    }
                    if let delivery = model.mappedEventDelivery {
                        Text("Event delivery  \(delivery.admittedControlIDs.count) of \(delivery.reviewedControlIDs.count) CIDs admitted  feature index \(String(format: "0x%02X", delivery.featureIndex))")
                    }
                    if let preflight = model.mappedPreflightPlan {
                        Text("GET preflight  \(preflight.controls.count)/\(MappedControlsReadOnlyPreflightPlan.maximumPacketCount) packets  not sent")
                    }
                    Text("NOT AUTHORIZED • no SET, GET, coordinator, or event synthesis")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2.monospaced())
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }

            Button("Review mapped-control diversion…") {
                model.performMappedControlDiversionReview()
            }
            .controlSize(.small)
            .disabled(model.mappedDiversionGateFailureText != nil)

            if let gateFailure = model.mappedDiversionGateFailureText,
               model.mappedDiversionSnapshot == nil {
                Text(gateFailure)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("This review scans running apps, validates in-memory apply flags 03, restore flags 02, and independent GET packets, lists the BTT-replacement actions, and keeps mapped-control event delivery at zero admitted CIDs. Sending the GET preflight is a separate confirmation. It does not divert those buttons or synthesize desktop, back/forward, or Mission Control.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Live mapped-control GET preflight")
                .font(.caption.weight(.semibold))

            Label(
                model.mappedLivePreflightStatusText,
                systemImage: model.mappedLivePreflightSnapshot != nil
                    ? "checkmark.shield.fill"
                    : model.mappedLivePreflightInProgress
                        ? "hourglass"
                        : "waveform.path.ecg.rectangle"
            )
            .font(.caption)
            .foregroundStyle(
                model.mappedLivePreflightSnapshot != nil ? .green : .secondary
            )
            .fixedSize(horizontal: false, vertical: true)

            if let snapshot = model.mappedLivePreflightSnapshot {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(snapshot.observations.count)/\(MappedControlsReadOnlyPreflightPlan.maximumPacketCount) GET matches • feature index \(String(format: "0x%02X", snapshot.featureIndex)) • epoch \(snapshot.connectionEpoch)")
                    ForEach(snapshot.observations, id: \.controlID) { observation in
                        Text(String(
                            format: "CID %04X  GET %@",
                            observation.controlID,
                            observation.requestBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                        ))
                        .textSelection(.enabled)
                    }
                    Text("NOT AUTHORIZED • five live GETs only; no SET, retry, or event synthesis")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2.monospaced())
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }

            Button("Send mapped-control GET preflight…") {
                showingMappedPreflightConfirmation = true
            }
            .controlSize(.small)
            .disabled(model.mappedLivePreflightGateFailureText != nil)
            .alert(
                "Read the five mapped controls exactly once each?",
                isPresented: $showingMappedPreflightConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Send five read-only GETs") {
                    model.performReadOnlyMappedControlPreflight()
                }
            } message: {
                Text("BetterTouchTool must remain fully quit. The app will send five sequential GetCidReporting requests with no retry:\n\n\(model.mappedLivePreflightRequestText)\n\nEach reply must match the saved baseline. No SET command or event synthesis is reachable from this action.")
            }

            if let gateFailure = model.mappedLivePreflightGateFailureText,
               !model.mappedLivePreflightAttempted,
               model.mappedLivePreflightSnapshot == nil {
                Text(gateFailure)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Dormant runtime owner")
                .font(.caption.weight(.semibold))

            Label(
                model.runtimeOwnerStatusText,
                systemImage: model.runtimeOwnerNeedsRecovery
                    ? "exclamationmark.triangle.fill"
                    : model.runtimeOwnerIsAdmitted
                        ? "bolt.shield.fill"
                        : model.runtimeOwnerBlocksRestart
                            ? "lock.shield.fill"
                            : "shield"
            )
            .font(.caption)
            .foregroundStyle(
                model.runtimeOwnerNeedsRecovery
                    ? .orange
                    : model.runtimeOwnerIsAdmitted
                        ? .red
                        : model.runtimeOwnerBlocksRestart ? .orange : .secondary
            )
            .fixedSize(horizontal: false, vertical: true)

            if model.runtimeOwnerControlIsDiverted {
                Text("Status: Precision diverted (active)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
            } else if model.runtimeOwnerIsAdmitted {
                // The runtime still owns the device after a verified restore,
                // but the control is back at its baseline. Saying "diverted"
                // here misreports the one fact the user most needs.
                Text("Status: Precision restored to baseline; runtime still admitted")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            } else if model.runtimeOwnerAuthorizationExpired {
                Text("Status: authorization expired; release for session rollover and bind again")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            } else if model.runtimeOwnerNeedsRecovery {
                Text(
                    model.runtimeOwnerDeviceDisconnected
                        ? "Status: recovery required after disconnect"
                        : "Status: recovery required"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
            }

            Button("Bind dormant runtime owner…") {
                showingRuntimeOwnerBindConfirmation = true
            }
            .controlSize(.small)
            .disabled(
                model.runtimeOwnerBindInProgress
                    || model.runtimeOwnerOperationInProgress
                    || model.runtimeOwnerBlocksRestart
                    || model.precisionReadinessSnapshot == nil
                    || model.status != .observing
            )
            .confirmationDialog(
                "Bind the dormant runtime owner to this observer run?",
                isPresented: $showingRuntimeOwnerBindConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Bind without admitting") {
                    Task { await model.bindDormantRuntimeOwner() }
                }
            } message: {
                Text("This captures the current observer run, installs a restart fence, and does not send HID, admit the Precision runtime, or change the MX Ergo. After a stop, Start observer stays blocked until an explicit session rollover. Quit keeps the fence.")
            }

            Button("Admit Precision runtime…") {
                showingRuntimeOwnerAdmitConfirmation = true
            }
            .controlSize(.small)
            .disabled(
                !model.runtimeOwnerCanAdmit
                    || model.runtimeOwnerOperationInProgress
            )
            .confirmationDialog(
                "Admit the Precision runtime and send one activate SET?",
                isPresented: $showingRuntimeOwnerAdmitConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Admit and send SET", role: .destructive) {
                    Task { await model.confirmRuntimeOwnerAdmission() }
                }
            } message: {
                Text("BetterTouchTool and Logi Options must be fully quit. This stops the current observer, opens the Precision runtime, and can change CID 00ED. After admit, Precision tap mutes and hold+scroll changes volume only when Audio test is on. Other buttons stay with the OS or BetterTouchTool. Deactivate before quit if you need Precision restored; quit does not send an inverse SET.")
            }

            Button("Recover Precision…") {
                showingRuntimeOwnerRecoverConfirmation = true
            }
            .controlSize(.small)
            .disabled(
                !model.runtimeOwnerCanRecover
                    || model.runtimeOwnerOperationInProgress
            )
            .confirmationDialog(
                "Recover Precision on this connection with one restore SET?",
                isPresented: $showingRuntimeOwnerRecoverConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Recover and send SET", role: .destructive) {
                    Task { await model.confirmRuntimeOwnerRecovery() }
                }
            } message: {
                Text("BetterTouchTool and Logi Options must be fully quit. This stops the current observer and runs explicit Precision recover for CID 00ED. It can send one restore SET. It does not retry, re-admit, or inverse-SET on failure. Power-cycle first if you only needed the firmware default.")
            }

            Button("Deactivate Precision…") {
                showingRuntimeOwnerDeactivateConfirmation = true
            }
            .controlSize(.small)
            .disabled(
                !model.runtimeOwnerCanDeactivate
                    || model.runtimeOwnerOperationInProgress
            )
            .confirmationDialog(
                "Deactivate Precision and send one restore SET?",
                isPresented: $showingRuntimeOwnerDeactivateConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Deactivate and send SET", role: .destructive) {
                    Task { await model.confirmRuntimeOwnerDeactivation() }
                }
            } message: {
                Text("This sends the reviewed restore SET for Precision CID 00ED and requires an independent GET. It does not restart the observer. Precision mute and hold+scroll volume stop after deactivation.")
            }

            Button("Release for session rollover…") {
                showingRuntimeOwnerRolloverConfirmation = true
            }
            .controlSize(.small)
            .disabled(
                !model.runtimeOwnerCanRollover
                    || model.runtimeOwnerOperationInProgress
            )
            .confirmationDialog(
                "Release the observer restart fence for a new session?",
                isPresented: $showingRuntimeOwnerRolloverConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Release the fence") {
                    Task { await model.completeRuntimeOwnerSessionRollover() }
                }
            } message: {
                Text("This discards the bound runtime owner and lifts the restart fence so the observer can start on a new connection. It sends no HID command and does not restore CID 00ED. If Precision may still be diverted on the hardware, recover it on the new connection before relying on the button.")
            }

            if let summary = model.inputDiagnosticsSummary {
                Divider()
                Text("Input evidence")
                    .font(.caption.weight(.semibold))
                Text(summary)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                if let frame = model.inputDiagnosticsLastFrame {
                    Text("last frame  \(frame)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let press = model.inputDiagnosticsLastPress {
                    Text("last press   \(press)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let interpretation = model.inputDiagnosticsInterpretation {
                    Text(interpretation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Refresh input evidence") {
                    Task { await model.refreshInputDiagnostics() }
                }
                .controlSize(.small)
                Text("Read-only. These counts gate nothing and change no behaviour. They refresh only when asked or when runtime state changes, so press the control you are testing first, then refresh.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Completed runtime journal")
                .font(.caption.weight(.semibold))
            Text(model.journalRotationStatusText)
                .font(.caption2)
                .foregroundStyle(model.journalRotationAvailable ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let summary = model.journalRotationSummary {
                Text(summary)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Retire completed runtime journal…") {
                showingJournalRotationConfirmation = true
            }
            .controlSize(.small)
            .disabled(model.journalRotationGateFailureText != nil)
            .confirmationDialog(
                "Retire the completed runtime journal?",
                isPresented: $showingJournalRotationConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Archive and retire") {
                    model.confirmJournalRotation()
                }
            } message: {
                Text("This renames the completed journal so a fresh one can bootstrap from the unchanged recovery baseline. It is never deleted, sends no HID command, opens no device, and refuses any journal still holding active, ambiguous, conflicted, or recovery-required evidence.")
            }
            if let gate = model.journalRotationGateFailureText,
               model.journalRotationAvailable {
                Text(gate)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("While admitted, Precision tap mutes and hold+scroll changes volume when Audio test is on. If the trackball disconnects, this app shuts down without a restore SET and shows recovery-required. After rollover, start the observer on the new connection, review readiness, bind, then confirm Recover Precision to send one restore SET. Reconnect never auto-retries. Other buttons stay with the OS/BetterTouchTool.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Read-only control enumeration")
                .font(.caption.weight(.semibold))

            Label(
                model.controlEnumerationStatusText,
                systemImage: !model.enumeratedControls.isEmpty
                    ? "checkmark.circle.fill"
                    : model.controlEnumerationInProgress
                        ? "hourglass"
                        : "list.bullet.clipboard"
            )
            .font(.caption)
            .foregroundStyle(!model.enumeratedControls.isEmpty ? .green : .secondary)

            if !model.enumeratedControls.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.enumeratedControls, id: \.index) { control in
                        Text(controlDescription(control))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            Button("Review control enumeration…") {
                showingControlEnumerationConfirmation = true
            }
            .controlSize(.small)
            .disabled(model.controlEnumerationGateFailureText != nil)
            .alert(
                "Enumerate controls with read-only HID++ requests?",
                isPresented: $showingControlEnumerationConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Enumerate exactly once") {
                    model.performReadOnlyControlEnumeration()
                }
            } message: {
                Text("BetterTouchTool must remain fully quit. The app will send one GetCount request followed by one GetControlInfo request per reported control (at most 65 sequential read-only packets total), with no retry and no SET command.")
            }

            if let gateFailure = model.controlEnumerationGateFailureText,
               !model.controlEnumerationAttempted {
                Text(gateFailure)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Read-only baseline snapshot")
                .font(.caption.weight(.semibold))

            Label(
                model.reportingSnapshotStatusText,
                systemImage: !model.baselineControls.isEmpty
                    ? "checkmark.shield.fill"
                    : model.reportingSnapshotInProgress
                        ? "hourglass"
                        : "externaldrive.badge.plus"
            )
            .font(.caption)
            .foregroundStyle(!model.baselineControls.isEmpty ? .green : .secondary)

            if !model.baselineControls.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.baselineControls, id: \.controlInfo.index) { entry in
                        Text(baselineDescription(entry))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            Button("Review baseline snapshot…") {
                showingReportingSnapshotConfirmation = true
            }
            .controlSize(.small)
            .disabled(model.reportingSnapshotGateFailureText != nil)
            .alert(
                "Read and save the current reporting baseline?",
                isPresented: $showingReportingSnapshotConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Read and save exactly once") {
                    model.performReadOnlyReportingSnapshot()
                }
            } message: {
                Text("BetterTouchTool must remain fully quit. The app will send one GetReporting request for each of the 9 enumerated controls, sequentially and without retry. It will validate the complete set and atomically save it as the local recovery baseline. No SET command is present in this build and the MX Ergo will not be changed.")
            }

            if let gateFailure = model.reportingSnapshotGateFailureText,
               !model.reportingSnapshotAttempted {
                Text(gateFailure)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Recovery transaction rehearsal")
                .font(.caption.weight(.semibold))

            Label(
                model.recoveryRehearsalStatusText,
                systemImage: !model.recoveryRehearsalSteps.isEmpty
                    ? "checkmark.shield.fill"
                    : model.recoveryRehearsalInProgress
                        ? "hourglass"
                        : "arrow.triangle.2.circlepath"
            )
            .font(.caption)
            .foregroundStyle(!model.recoveryRehearsalSteps.isEmpty ? .green : .secondary)

            if !model.recoveryRehearsalSteps.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(model.recoveryRehearsalSteps.count) controls × 5 verified phases")
                        .font(.caption2.monospacedDigit().weight(.medium))
                    Text("baseline → apply write-ahead → applied read-back → restore write-ahead → restored read-back")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }

            Button("Review recovery rehearsal…") {
                showingRecoveryRehearsalConfirmation = true
            }
            .controlSize(.small)
            .disabled(model.recoveryRehearsalGateFailureText != nil)
            .alert(
                "Rehearse recovery without touching the MX Ergo?",
                isPresented: $showingRecoveryRehearsalConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Run in-memory rehearsal") {
                    model.performRecoveryRehearsal()
                }
            } message: {
                Text("The app will require an exact match to the saved device identity, build the nine-control restore plan, and exercise every write-ahead and verification phase on an in-memory copy. It then confirms the journal file is byte-for-byte unchanged. This sends no HID output and performs no device or journal write.")
            }

            if let gateFailure = model.recoveryRehearsalGateFailureText,
               !model.recoveryRehearsalAttempted {
                Text(gateFailure)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Schema-v3 coordinator self-test")
                .font(.caption.weight(.semibold))

            Label(
                model.transactionSimulationStatusText,
                systemImage: model.transactionSimulationReport != nil
                    ? "checkmark.shield.fill"
                    : model.transactionSimulationInProgress
                        ? "hourglass"
                        : "externaldrive.badge.checkmark"
            )
            .font(.caption)
            .foregroundStyle(model.transactionSimulationReport != nil ? .green : .secondary)

            if let report = model.transactionSimulationReport {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(report.controlCount) controls • \(report.durableCommitCount) revisioned commits")
                        .font(.caption2.monospacedDigit().weight(.medium))
                    Text("\(report.abstractMutationCount) scripted mutations • \(report.interruptedRecoveryCount) restart recoveries")
                        .font(.caption2.monospacedDigit())
                    Text("\(report.durableCommitBoundaryCount) durable boundaries • \(report.recoveryClassificationCount) exact recovery classifications")
                        .font(.caption2.monospacedDigit())
                    Text("\(report.transportFaultScenarioCount) apply/restore transport scenarios")
                        .font(.caption2.monospacedDigit())
                    Text("\(report.reconnectIdentityCheckCount) reconnect bindings • \(report.immutableWireByteCheckCount) immutable wire bytes")
                        .font(.caption2.monospacedDigit())
                    Text("Live schema-v2 baseline remained byte-for-byte unchanged")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }

            Button("Review coordinator self-test…") {
                showingTransactionSimulationConfirmation = true
            }
            .controlSize(.small)
            .disabled(model.transactionSimulationGateFailureText != nil)
            .alert(
                "Run isolated transaction and restart simulations?",
                isPresented: $showingTransactionSimulationConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Run isolated self-test") {
                    model.performTransactionSimulation()
                }
            } message: {
                Text("The app will derive a separate schema-v3 transaction from the verified baseline; run every control through the revisioned coordinator; test all 16 apply/restore transport outcomes, all six durable file-commit boundaries, exact recovery classification and reconnect binding; and reject changes to every immutable wire byte. There is no HID transport or REPROG SET command, and the live schema-v2 journal is verified unchanged afterward.")
            }

            if let gateFailure = model.transactionSimulationGateFailureText,
               !model.transactionSimulationAttempted {
                Text(gateFailure)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("This build has no production REPROG SET sender and cannot change diversion flags. Packet previews and transaction validations are isolated from HID transport.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func safetyGateLabel(_ text: String, state: Bool?) -> some View {
        Label(
            text,
            systemImage: state == true
                ? "checkmark.circle.fill"
                : state == false
                    ? "xmark.circle.fill"
                    : "clock"
        )
        .font(.caption)
        .foregroundStyle(state == true ? .green : state == false ? .orange : .secondary)
    }

    private func controlDescription(_ control: ReprogControlInfo) -> String {
        String(
            format: "[%02d] CID %04X  task %04X  flags %02X",
            control.index,
            control.controlID,
            control.taskID,
            control.capabilityFlags
        )
    }

    private func baselineDescription(_ entry: DeviceControlJournalEntry) -> String {
        String(
            format: "[%02d] CID %04X  flags %04X  map %04X",
            entry.controlInfo.index,
            entry.controlInfo.controlID,
            entry.baselineReporting.rawFlags,
            entry.baselineReporting.rawMappedControlID
        )
    }

    private func mappedControlDescription(
        _ plan: MappedControlTemporaryDiversionPlan
    ) -> String {
        let name = MXErgoControl(rawValue: plan.controlID)?.name ?? "Mapped control"
        let apply = plan.applySetRequest.bytes
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
        let verify = plan.verificationRequest.bytes
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
        return String(
            format: "%@  CID %04X  APPLY %@  VERIFY %@",
            name,
            plan.controlID,
            apply,
            verify
        )
    }

    private func mappedActionDescription(
        _ binding: MappedControlActionBinding
    ) -> String {
        String(
            format: "%@  CID %04X  %@  %@",
            binding.control.name,
            binding.control.rawValue,
            binding.intent.name,
            binding.synthesizedAction.description
        )
    }

    private func restorePacketDescription(_ plan: RestoreOnlyReportingPlan) -> String {
        let setBytes = plan.setRequest.bytes
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
        let verifyBytes = plan.verificationRequest.bytes
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
        return String(
            format: "[%02d] CID %04X  SET %@\n     VERIFY %@",
            plan.controlIndex,
            plan.controlID,
            setBytes,
            verifyBytes
        )
    }

    private func firmwareDeviceDescription(
        _ fingerprint: HIDPP20FirmwareFingerprint
    ) -> String {
        let unit = fingerprint.deviceInfo.unitID
            .map { String(format: "%02X", $0) }
            .joined()
        let models = fingerprint.deviceInfo.modelIDs
            .map { String(format: "%04X", $0) }
            .joined(separator: "/")
        return "Feature v\(fingerprint.featureVersion) • unit \(unit) • models \(models)"
    }

    private func firmwareEntityDescription(_ entity: HIDPP20FirmwareEntity) -> String {
        let extra = entity.extraVersion
            .map { String(format: "%02X", $0) }
            .joined()
        return String(
            format: "[%02d] type %02X  %@  extra %@",
            entity.index,
            entity.rawType,
            entity.versionDescription,
            extra
        )
    }

    private var calibrationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Control calibration")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Clear") { model.clearCalibrationReports() }
                    .controlSize(.mini)
                    .disabled(model.calibrationReports.isEmpty)
            }

            Text("Press one MX Ergo button at a time. Logitech controls and ordinary mouse-button transitions appear without pointer-movement noise.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.calibrationReports.isEmpty {
                Text("No control transitions captured yet.")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.calibrationReports.reversed().prefix(6).enumerated()), id: \.offset) { _, report in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 8) {
                                Text("#\(report.count)")
                                    .frame(width: 48, alignment: .trailing)
                                    .foregroundStyle(.tertiary)
                                Text(calibrationLabel(for: report))
                                    .foregroundStyle(.secondary)
                            }
                            Text(report.preview.map { String(format: "%02X", $0) }.joined(separator: " "))
                                .padding(.leading, 56)
                                .textSelection(.enabled)
                        }
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                    }
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func calibrationLabel(for report: HIDReportSnapshot) -> String {
        if let event = LogitechControlEventDecoder.decode(report) {
            switch event {
            case let .pressed(controlID):
                let controlName = event.control?.name ?? "Unknown control"
                return String(format: "%@ down (0x%04X)", controlName, controlID)
            case .released:
                return "Logitech control released"
            }
        }

        if let buttonMask = report.standardMouseButtonMask {
            if buttonMask == 0 {
                return "Standard mouse button released"
            }
            let buttonName = StandardMouseButton(rawValue: buttonMask)?.name ?? "Standard mouse button"
            return String(format: "%@ down (mask 0x%02X)", buttonName, buttonMask)
        }

        return "Logitech report"
    }

    private func wheelDescription(_ notches: Int) -> String {
        let direction = notches > 0 ? "up" : "down"
        return "\(direction) (\(notches.formatted(.number.sign(strategy: .always()))))"
    }

    /// Wheel tilt is an ordinary horizontal scroll axis on this device, not a
    /// button. Positive is a right tilt, confirmed on hardware 2026-09-05 and
    /// unaffected by the "natural scrolling" preference.
    private func tiltDescription(_ notches: Int) -> String {
        let direction = notches > 0 ? "right" : "left"
        return "\(direction) (\(notches > 0 ? "+" : "")\(notches))"
    }

    private var intentPreviewSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Action preview")
                .font(.subheadline.weight(.medium))

            if let intent = model.lastIntent {
                Label(intent.name, systemImage: "arrow.right.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)
            } else {
                Text("Press a configured control to verify its intended action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(model.audioExecutionEnabled
                ? "Mute and volume execute; all other actions remain preview-only."
                : "Preview only—actions are not executed while Audio test is off.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var audioTestSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { model.audioExecutionEnabled },
                set: { model.setAudioExecutionEnabled($0) }
            )) {
                Text("Execute mute and volume")
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(.switch)
            .disabled(
                model.rootQueryInProgress
                    || model.controlEnumerationInProgress
                    || model.reportingSnapshotInProgress
                    || model.recoveryRehearsalInProgress
                    || model.transactionSimulationInProgress
                    || model.restoreTrialSimulationInProgress
                    || model.precisionPreflightInProgress
            )

            Label(
                model.audioStatus.message,
                systemImage: model.audioStatus.isFailure
                    ? "exclamationmark.triangle.fill"
                    : "waveform"
            )
            .font(.caption)
            .foregroundStyle(model.audioStatus.isFailure ? .orange : .secondary)

            Text("Disable BetterTouchTool's Precision mute and volume triggers before enabling this test. The switch resets to off whenever the app launches.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var connectionTitle: String {
        switch model.status {
        case .stopped:
            return "Observer stopped"
        case .starting:
            return "Starting observer…"
        case .observing:
            return model.devices.isEmpty ? "MX Ergo not detected" : "MX Ergo connected"
        case let .failed(code):
            return "Observer failed (\(code))"
        }
    }

    private var reportPlaceholder: String {
        guard !model.devices.isEmpty else {
            return "Reports appear after the MX Ergo connects. This build does not remap buttons."
        }
        guard model.inputMonitoringGranted else {
            return "Grant Input Monitoring in System Settings, then click this window again. Move the ball or press a button; remapping is not live."
        }
        return "Move the ball or press a button. The report count should increase. Thumb, tilt, and wheel-click still belong to BetterTouchTool or macOS."
    }

    private func hexPair(_ device: HIDDeviceProperties) -> String {
        guard let vendorID = device.vendorID, let productID = device.productID else { return "Unknown" }
        return String(format: "%04X / %04X", vendorID, productID)
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
