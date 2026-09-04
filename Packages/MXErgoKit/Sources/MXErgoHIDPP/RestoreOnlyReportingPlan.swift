import Foundation

public enum RestoreOnlyReportingPlanError: Error, Sendable, Equatable {
    case journalRequiresRecovery
    case unsupportedFeatureVersion(UInt8)
    case featureVersionMismatch(saved: UInt8, current: UInt8)
    case controlIsNotPhysical(UInt16)
    case controlIsNotReprogrammable(UInt16)
    case controlIsNotDivertable(UInt16)
    case unsupportedBaselineFlags(controlID: UInt16, flags: UInt16)
    case baselineFieldMismatch(UInt16)
    case unsupportedPersistentState(UInt16)
    case unsupportedRawXYState(UInt16)
    case mappedControlUnavailable(controlID: UInt16, mappedControlID: UInt16)
    case mappedControlOutsideGroupMask(controlID: UInt16, mappedControlID: UInt16)
    case noEligiblePhysicalControls
    case unexpectedSetAcknowledgement
}

/// A byte-exact, offline-only preview of the two packets needed for one
/// restore operation: SetCidReporting followed by a distinct GetCidReporting
/// read-back. Constructing this value never performs HID I/O.
public struct RestoreOnlyReportingPlan: Sendable, Equatable {
    public let controlIndex: UInt8
    public let controlID: UInt16
    public let baselineReporting: ReprogControlReportingState
    public let setFlags: UInt8
    public let setMappedControlID: UInt16
    public let setRequest: HIDPP20LongMessage
    public let verificationRequest: HIDPP20LongMessage

    public init(
        controlIndex: UInt8,
        controlID: UInt16,
        baselineReporting: ReprogControlReportingState,
        setFlags: UInt8,
        setMappedControlID: UInt16,
        setRequest: HIDPP20LongMessage,
        verificationRequest: HIDPP20LongMessage
    ) {
        self.controlIndex = controlIndex
        self.controlID = controlID
        self.baselineReporting = baselineReporting
        self.setFlags = setFlags
        self.setMappedControlID = setMappedControlID
        self.setRequest = setRequest
        self.verificationRequest = verificationRequest
    }
}

public enum RestoreOnlyReportingPlanner {
    private static let reprogrammable: UInt8 = 0x10
    private static let divertable: UInt8 = 0x20
    private static let virtualControl: UInt8 = 0x80

    private static let divertValue: UInt8 = 0x01
    private static let divertValid: UInt8 = 0x02
    private static let featureV3StateMask: UInt16 = 0x0015

    /// Builds plans for every physical control whose metadata says it can be
    /// remapped and diverted. Non-divertable and virtual CIDs are omitted; an
    /// eligible control with inconsistent recovery data fails the whole plan.
    public static func makePlans(
        journal: DeviceStateJournal,
        currentFeature: HIDPP20FeatureDescriptor,
        deviceIndex: UInt8,
        softwareID: UInt8
    ) throws -> [RestoreOnlyReportingPlan] {
        try journal.validateForRecovery()
        guard !journal.requiresRecovery else {
            throw RestoreOnlyReportingPlanError.journalRequiresRecovery
        }
        guard currentFeature.version == 3 else {
            throw RestoreOnlyReportingPlanError.unsupportedFeatureVersion(
                currentFeature.version
            )
        }
        guard journal.feature.version == currentFeature.version else {
            throw RestoreOnlyReportingPlanError.featureVersionMismatch(
                saved: journal.feature.version,
                current: currentFeature.version
            )
        }

        let eligible = journal.controls
            .filter { entry in
                let flags = entry.controlInfo.capabilityFlags
                return flags & virtualControl == 0
                    && flags & reprogrammable != 0
                    && flags & divertable != 0
            }
            .sorted { $0.controlInfo.index < $1.controlInfo.index }

        guard !eligible.isEmpty else {
            throw RestoreOnlyReportingPlanError.noEligiblePhysicalControls
        }

        return try eligible.map { entry in
            try makePlan(
                entry: entry,
                currentFeature: currentFeature,
                deviceIndex: deviceIndex,
                softwareID: softwareID
            )
        }
    }

    public static func makePlan(
        for controlID: UInt16,
        journal: DeviceStateJournal,
        currentFeature: HIDPP20FeatureDescriptor,
        deviceIndex: UInt8,
        softwareID: UInt8
    ) throws -> RestoreOnlyReportingPlan {
        try journal.validateForRecovery()
        guard !journal.requiresRecovery else {
            throw RestoreOnlyReportingPlanError.journalRequiresRecovery
        }
        guard currentFeature.version == 3 else {
            throw RestoreOnlyReportingPlanError.unsupportedFeatureVersion(
                currentFeature.version
            )
        }
        guard journal.feature.version == currentFeature.version else {
            throw RestoreOnlyReportingPlanError.featureVersionMismatch(
                saved: journal.feature.version,
                current: currentFeature.version
            )
        }
        guard let entry = journal.controls.first(where: {
            $0.controlInfo.controlID == controlID
        }) else {
            throw DeviceStateJournalError.unknownControlID(controlID)
        }
        return try makePlan(
            entry: entry,
            currentFeature: currentFeature,
            deviceIndex: deviceIndex,
            softwareID: softwareID
        )
    }

    /// Validates the SET response as an exact echo of the reviewed request.
    /// This acknowledgement is not accepted as state verification; callers
    /// must still send and decode the plan's separate GetReporting request.
    public static func validateSetAcknowledgement(
        _ response: HIDPP20LongMessage,
        for plan: RestoreOnlyReportingPlan
    ) throws {
        guard response.deviceIndex == plan.setRequest.deviceIndex,
              response.featureIndex == plan.setRequest.featureIndex,
              response.functionID == 3,
              response.softwareID == plan.setRequest.softwareID,
              response.parameters == plan.setRequest.parameters else {
            throw RestoreOnlyReportingPlanError.unexpectedSetAcknowledgement
        }
    }

    private static func makePlan(
        entry: DeviceControlJournalEntry,
        currentFeature: HIDPP20FeatureDescriptor,
        deviceIndex: UInt8,
        softwareID: UInt8
    ) throws -> RestoreOnlyReportingPlan {
        let info = entry.controlInfo
        let capabilities = info.capabilityFlags
        guard capabilities & virtualControl == 0 else {
            throw RestoreOnlyReportingPlanError.controlIsNotPhysical(info.controlID)
        }
        guard capabilities & reprogrammable != 0 else {
            throw RestoreOnlyReportingPlanError.controlIsNotReprogrammable(info.controlID)
        }
        guard capabilities & divertable != 0 else {
            throw RestoreOnlyReportingPlanError.controlIsNotDivertable(info.controlID)
        }

        let baseline = entry.baselineReporting
        let wire = try DeviceTransactionWireState(rawParameters: baseline.rawParameters)
        guard wire.controlID == info.controlID,
              wire.rawFlags(featureVersion: 3) == baseline.rawFlags,
              wire.mappedControlID == baseline.rawMappedControlID else {
            throw RestoreOnlyReportingPlanError.baselineFieldMismatch(info.controlID)
        }
        guard baseline.rawFlags & ~featureV3StateMask == 0 else {
            throw RestoreOnlyReportingPlanError.unsupportedBaselineFlags(
                controlID: info.controlID,
                flags: baseline.rawFlags
            )
        }
        if baseline.isPersistentlyDiverted {
            throw RestoreOnlyReportingPlanError.unsupportedPersistentState(info.controlID)
        }
        if baseline.isRawXYDiverted {
            throw RestoreOnlyReportingPlanError.unsupportedRawXYState(info.controlID)
        }

        // This app only owns temporary diversion. A restore must therefore
        // update that one field and leave persistent diversion, raw-XY, and
        // mapping untouched. In feature v3, 0x02 means "temporary-diversion
        // value is valid" and a zero mapping means "do not update mapping".
        var setFlags = divertValid
        if baseline.isTemporarilyDiverted { setFlags |= divertValue }
        let mappedControlID: UInt16 = 0

        let setParameters: [UInt8] = [
            UInt8(info.controlID >> 8), UInt8(info.controlID & 0xFF),
            setFlags,
            UInt8(mappedControlID >> 8), UInt8(mappedControlID & 0xFF),
        ]
        let setRequest = try HIDPP20LongMessage(
            deviceIndex: deviceIndex,
            featureIndex: currentFeature.index,
            functionID: 3,
            softwareID: softwareID,
            parameters: setParameters
        )
        let verificationRequest = try ReprogControlsV4.getReportingRequest(
            controlID: info.controlID,
            featureIndex: currentFeature.index,
            deviceIndex: deviceIndex,
            softwareID: softwareID
        )

        return RestoreOnlyReportingPlan(
            controlIndex: info.index,
            controlID: info.controlID,
            baselineReporting: baseline,
            setFlags: setFlags,
            setMappedControlID: mappedControlID,
            setRequest: setRequest,
            verificationRequest: verificationRequest
        )
    }
}
