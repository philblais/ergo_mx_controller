import Foundation

public enum MappedControlTemporaryDiversionError: Error, Sendable, Equatable {
    case unsupportedDevice
    case unstableRecoveryIdentity
    case journalRequiresRecovery
    case featureMismatch
    case unsupportedFeatureVersion(UInt8)
    case missingMappedControl(UInt16)
    case unexpectedMappedControl(UInt16)
    case controlNotEligible(UInt16)
    case baselineNotClean(UInt16)
    case invalidMutation
}

/// One reviewed temporary-diversion lifecycle for a mapped MX Ergo control
/// other than Precision. Construction performs no HID I/O.
public struct MappedControlTemporaryDiversionPlan: Sendable, Equatable {
    public let controlID: UInt16
    public let controlIndex: UInt8
    public let baseline: DeviceTransactionWireState
    public let activeState: DeviceTransactionWireState
    public let applySetRequest: HIDPP20LongMessage
    public let restoreSetRequest: HIDPP20LongMessage
    public let verificationRequest: HIDPP20LongMessage
}

/// The five BTT-mapped divertable CIDs this app may own after Precision.
/// Precision CID 00ED is intentionally absent. The plan is not an authorization
/// to send SET.
public struct MappedControlsTemporaryDiversionPlan: Sendable, Equatable {
    public static let controlIDs: [UInt16] = [
        0x0052, 0x0053, 0x0056, 0x005B, 0x005D,
    ]

    public let controls: [MappedControlTemporaryDiversionPlan]
    public let device: JournalDeviceIdentity
    public let featureIndex: UInt8
    public let featureVersion: UInt8

    public static func make(
        journal: DeviceStateJournal,
        currentFeature: HIDPP20FeatureDescriptor,
        deviceIndex: UInt8,
        softwareID: UInt8
    ) throws -> MappedControlsTemporaryDiversionPlan {
        try journal.validateForRecovery()
        guard !journal.requiresRecovery else {
            throw MappedControlTemporaryDiversionError.journalRequiresRecovery
        }
        guard journal.device.vendorID == 0x046D,
              journal.device.productID == 0xB01D,
              journal.device.transport == "Bluetooth Low Energy" else {
            throw MappedControlTemporaryDiversionError.unsupportedDevice
        }
        guard journal.device.serialNumber?.isEmpty == false,
              journal.device.locationID != nil,
              journal.device.firmwareIdentity?.isEmpty == false else {
            throw MappedControlTemporaryDiversionError.unstableRecoveryIdentity
        }
        guard currentFeature.index != 0,
              currentFeature.index != 0xFF,
              journal.feature.index == currentFeature.index,
              journal.feature.version == currentFeature.version else {
            throw MappedControlTemporaryDiversionError.featureMismatch
        }
        guard currentFeature.version == 3 else {
            throw MappedControlTemporaryDiversionError.unsupportedFeatureVersion(
                currentFeature.version
            )
        }

        let byID = Dictionary(
            uniqueKeysWithValues: journal.controls.map {
                ($0.controlInfo.controlID, $0)
            }
        )
        let extraMapped = journal.controls.compactMap { entry -> UInt16? in
            let id = entry.controlInfo.controlID
            let flags = entry.controlInfo.capabilityFlags
            let isPhysical = flags & 0x80 == 0
            let isReprogrammable = flags & 0x10 != 0
            let isDivertable = flags & 0x20 != 0
            guard isPhysical, isReprogrammable, isDivertable,
                  id != PrecisionTemporaryDiversionPlan.controlID,
                  !Self.controlIDs.contains(id) else {
                return nil
            }
            return id
        }
        if let unexpected = extraMapped.sorted().first {
            throw MappedControlTemporaryDiversionError.unexpectedMappedControl(
                unexpected
            )
        }

        let controls = try Self.controlIDs.map { controlID in
            guard let entry = byID[controlID] else {
                throw MappedControlTemporaryDiversionError.missingMappedControl(
                    controlID
                )
            }
            return try makeControlPlan(
                entry: entry,
                currentFeature: currentFeature,
                deviceIndex: deviceIndex,
                softwareID: softwareID
            )
        }

        return MappedControlsTemporaryDiversionPlan(
            controls: controls.sorted { $0.controlIndex < $1.controlIndex },
            device: journal.device,
            featureIndex: currentFeature.index,
            featureVersion: currentFeature.version
        )
    }

    public func plan(for controlID: UInt16) throws -> MappedControlTemporaryDiversionPlan {
        guard let plan = controls.first(where: { $0.controlID == controlID }) else {
            throw MappedControlTemporaryDiversionError.invalidMutation
        }
        return plan
    }

    public func request(
        for mutation: DeviceTransactionMutation
    ) throws -> HIDPP20LongMessage {
        let plan = try plan(for: mutation.controlID)
        switch mutation.kind {
        case .apply:
            guard mutation.state == plan.activeState else {
                throw MappedControlTemporaryDiversionError.invalidMutation
            }
            return plan.applySetRequest
        case .restore:
            guard mutation.state == plan.baseline else {
                throw MappedControlTemporaryDiversionError.invalidMutation
            }
            return plan.restoreSetRequest
        }
    }

    private static func makeControlPlan(
        entry: DeviceControlJournalEntry,
        currentFeature: HIDPP20FeatureDescriptor,
        deviceIndex: UInt8,
        softwareID: UInt8
    ) throws -> MappedControlTemporaryDiversionPlan {
        let controlID = entry.controlInfo.controlID
        let capabilities = entry.controlInfo.capabilityFlags
        let isPhysical = capabilities & 0x80 == 0
        let isReprogrammable = capabilities & 0x10 != 0
        let isDivertable = capabilities & 0x20 != 0
        guard isPhysical, isReprogrammable, isDivertable else {
            throw MappedControlTemporaryDiversionError.controlNotEligible(controlID)
        }

        let baseline = try DeviceTransactionWireState(
            rawParameters: entry.baselineReporting.rawParameters
        )
        guard entry.phase == .baselineVerified,
              entry.intendedReporting == nil,
              entry.readBackReporting == nil,
              baseline.controlID == controlID,
              baseline.rawFlags(featureVersion: 3) == 0,
              baseline.mappedControlID == 0,
              baseline.rawParameters.dropFirst(5).allSatisfy({ $0 == 0 }) else {
            throw MappedControlTemporaryDiversionError.baselineNotClean(controlID)
        }

        let active = try baseline.replacingRawFlags(0x01, featureVersion: 3)
        let cidHigh = UInt8(controlID >> 8)
        let cidLow = UInt8(controlID & 0xFF)
        let apply = try HIDPP20LongMessage(
            deviceIndex: deviceIndex,
            featureIndex: currentFeature.index,
            functionID: 3,
            softwareID: softwareID,
            parameters: [cidHigh, cidLow, 0x03, 0x00, 0x00]
        )
        let restore = try HIDPP20LongMessage(
            deviceIndex: deviceIndex,
            featureIndex: currentFeature.index,
            functionID: 3,
            softwareID: softwareID,
            parameters: [cidHigh, cidLow, 0x02, 0x00, 0x00]
        )
        let verification = try ReprogControlsV4.getReportingRequest(
            controlID: controlID,
            featureIndex: currentFeature.index,
            deviceIndex: deviceIndex,
            softwareID: softwareID
        )
        return MappedControlTemporaryDiversionPlan(
            controlID: controlID,
            controlIndex: entry.controlInfo.index,
            baseline: baseline,
            activeState: active,
            applySetRequest: apply,
            restoreSetRequest: restore,
            verificationRequest: verification
        )
    }
}
