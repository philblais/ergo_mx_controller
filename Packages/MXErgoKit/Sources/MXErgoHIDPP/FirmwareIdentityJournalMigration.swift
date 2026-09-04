import CryptoKit
import Foundation

public enum FirmwareIdentityJournalMigrationError: Error, Sendable, Equatable {
    case emptyFirmwareIdentity
    case journalRequiresRecovery
    case deviceIdentityMismatch
    case firmwareIdentityConflict(saved: String, discovered: String)
    case malformedSourceJSON
    case invariantViolation
}

public enum FirmwareIdentityJournalMigrationDisposition: Sendable, Equatable {
    case ready
    case alreadyApplied
}

/// An exact-byte migration proposal. Constructing a plan never writes a file
/// and never communicates with a HID device.
public struct FirmwareIdentityJournalMigrationPlan: Sendable, Equatable {
    public let disposition: FirmwareIdentityJournalMigrationDisposition
    public let originalJournal: DeviceStateJournal
    public let proposedJournal: DeviceStateJournal
    public let changedPaths: [String]
    public let discoveredFirmwareIdentity: String
    public let sourceData: Data
    public let targetData: Data
    public let sourceSHA256: String
    public let targetSHA256: String

    public var changesExactlyFirmwareIdentity: Bool {
        disposition == .ready && changedPaths == ["device.firmwareIdentity"]
    }
}

public enum FirmwareIdentityJournalMigrationPlanner {
    public static func makePlan(
        sourceData: Data,
        connectedDevice: JournalDeviceIdentity,
        discoveredFirmwareIdentity: String
    ) throws -> FirmwareIdentityJournalMigrationPlan {
        guard !discoveredFirmwareIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FirmwareIdentityJournalMigrationError.emptyFirmwareIdentity
        }

        let decoder = JSONDecoder()
        let journal = try decoder.decode(DeviceStateJournal.self, from: sourceData)
        try journal.validateForRecovery()
        guard !journal.requiresRecovery else {
            throw FirmwareIdentityJournalMigrationError.journalRequiresRecovery
        }

        let unboundSavedDevice = replacingFirmwareIdentity(in: journal.device, with: nil)
        let unboundConnectedDevice = replacingFirmwareIdentity(in: connectedDevice, with: nil)
        guard unboundSavedDevice.isSafeRecoveryMatch(unboundConnectedDevice) else {
            throw FirmwareIdentityJournalMigrationError.deviceIdentityMismatch
        }

        if let savedFirmwareIdentity = journal.device.firmwareIdentity {
            guard savedFirmwareIdentity == discoveredFirmwareIdentity else {
                throw FirmwareIdentityJournalMigrationError.firmwareIdentityConflict(
                    saved: savedFirmwareIdentity,
                    discovered: discoveredFirmwareIdentity
                )
            }
            return FirmwareIdentityJournalMigrationPlan(
                disposition: .alreadyApplied,
                originalJournal: journal,
                proposedJournal: journal,
                changedPaths: [],
                discoveredFirmwareIdentity: discoveredFirmwareIdentity,
                sourceData: sourceData,
                targetData: sourceData,
                sourceSHA256: sha256(sourceData),
                targetSHA256: sha256(sourceData)
            )
        }

        guard let sourceObject = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
              var targetDeviceObject = sourceObject["device"] as? [String: Any],
              targetDeviceObject["firmwareIdentity"] == nil else {
            throw FirmwareIdentityJournalMigrationError.malformedSourceJSON
        }

        targetDeviceObject["firmwareIdentity"] = discoveredFirmwareIdentity
        var targetObject = sourceObject
        targetObject["device"] = targetDeviceObject
        let targetData = try JSONSerialization.data(
            withJSONObject: targetObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        let proposed = try decoder.decode(DeviceStateJournal.self, from: targetData)
        try proposed.validateForRecovery()

        guard onlyFirmwareIdentityDiffers(source: journal, proposed: proposed),
              jsonTreesDifferOnlyByFirmwareIdentity(
                sourceObject: sourceObject,
                targetData: targetData,
                expectedFirmwareIdentity: discoveredFirmwareIdentity
              ) else {
            throw FirmwareIdentityJournalMigrationError.invariantViolation
        }

        return FirmwareIdentityJournalMigrationPlan(
            disposition: .ready,
            originalJournal: journal,
            proposedJournal: proposed,
            changedPaths: ["device.firmwareIdentity"],
            discoveredFirmwareIdentity: discoveredFirmwareIdentity,
            sourceData: sourceData,
            targetData: targetData,
            sourceSHA256: sha256(sourceData),
            targetSHA256: sha256(targetData)
        )
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func replacingFirmwareIdentity(
        in device: JournalDeviceIdentity,
        with firmwareIdentity: String?
    ) -> JournalDeviceIdentity {
        JournalDeviceIdentity(
            deviceID: device.deviceID,
            vendorID: device.vendorID,
            productID: device.productID,
            transport: device.transport,
            serialNumber: device.serialNumber,
            locationID: device.locationID,
            firmwareIdentity: firmwareIdentity
        )
    }

    private static func jsonTreesDifferOnlyByFirmwareIdentity(
        sourceObject: [String: Any],
        targetData: Data,
        expectedFirmwareIdentity: String
    ) -> Bool {
        guard var strippedTarget = try? JSONSerialization.jsonObject(with: targetData) as? [String: Any],
              var strippedDevice = strippedTarget["device"] as? [String: Any],
              strippedDevice.removeValue(forKey: "firmwareIdentity") as? String
                == expectedFirmwareIdentity else {
            return false
        }
        strippedTarget["device"] = strippedDevice
        return NSDictionary(dictionary: sourceObject).isEqual(to: strippedTarget)
    }

    private static func onlyFirmwareIdentityDiffers(
        source: DeviceStateJournal,
        proposed: DeviceStateJournal
    ) -> Bool {
        guard source.schemaVersion == proposed.schemaVersion,
              source.transactionID == proposed.transactionID,
              source.appBuild == proposed.appBuild,
              source.featureID == proposed.featureID,
              source.feature == proposed.feature,
              source.expectedControlCount == proposed.expectedControlCount,
              source.controls == proposed.controls,
              source.createdAt == proposed.createdAt,
              source.updatedAt == proposed.updatedAt else {
            return false
        }

        let sourceDevice = source.device
        let proposedDevice = proposed.device
        return sourceDevice.deviceID == proposedDevice.deviceID
            && sourceDevice.vendorID == proposedDevice.vendorID
            && sourceDevice.productID == proposedDevice.productID
            && sourceDevice.transport == proposedDevice.transport
            && sourceDevice.serialNumber == proposedDevice.serialNumber
            && sourceDevice.locationID == proposedDevice.locationID
            && sourceDevice.firmwareIdentity == nil
            && proposedDevice.firmwareIdentity?.isEmpty == false
    }
}
