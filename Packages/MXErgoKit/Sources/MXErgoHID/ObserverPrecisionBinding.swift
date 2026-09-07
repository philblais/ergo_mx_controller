import Foundation
import MXErgoCore
import MXErgoHIDPP

/// Historical proof from one observer run, sealed before its state is cleared.
/// Firmware identity and the app's root generation are deliberately not attested.
/// This is not evidence that a subsequently opened endpoint is still connected.
package struct MXErgoObserverPrecisionBinding: Sendable, Equatable {
    package let runID: UUID
    let properties: HIDDeviceProperties
    let feature: HIDPP20FeatureDescriptor
    let connectionEpoch: UInt64

    package func matches(_ session: DeviceTransactionSession) -> Bool {
        let expected = session.device
        return properties.id == expected.deviceID
            && properties.vendorID == expected.vendorID
            && properties.productID == expected.productID
            && properties.transport == expected.transport
            && properties.locationID == expected.locationID
            && (expected.serialNumber?.isEmpty != false
                || properties.serialNumber == expected.serialNumber)
            && session.featureID == ReprogControlsV4.featureID
            && session.featureIndex == feature.index
            && session.featureVersion == feature.version
            && session.connectionEpoch == connectionEpoch
    }
}

/// Callback-side evidence is published before UI delivery. Revisions prevent a
/// reply queued before a topology change from resurrecting invalidated proof.
final class MXErgoObserverPrecisionBindingStore: @unchecked Sendable {
    private let lock = NSLock()
    private let runID: UUID
    private var revision: UInt64 = 0
    private var root: (deviceID: String, feature: HIDPP20FeatureDescriptor, epoch: UInt64)?
    private var preflight: MXErgoObserverPrecisionBinding?
    private var sealed: MXErgoObserverPrecisionBinding?
    private var finished = false

    init(runID: UUID) { self.runID = runID }

    var currentRevision: UInt64 { lock.withLock { revision } }

    func invalidate() {
        lock.withLock {
            revision &+= 1
            root = nil
            preflight = nil
            sealed = nil
        }
    }

    func beginPreflight() {
        lock.withLock { preflight = nil; sealed = nil }
    }

    func recordRoot(deviceID: String, feature: HIDPP20FeatureDescriptor,
                    epoch: UInt64, expectedRevision: UInt64) {
        lock.withLock {
            guard !finished, expectedRevision == revision, feature.isSupported else { return }
            root = (deviceID, feature, epoch)
            preflight = nil
        }
    }

    func recordPreflight(properties: HIDDeviceProperties,
                         feature: HIDPP20FeatureDescriptor, epoch: UInt64,
                         expectedRevision: UInt64) {
        lock.withLock {
            guard !finished, expectedRevision == revision,
                  properties.isMXErgo, properties.isBluetooth,
                  properties.serialNumber?.isEmpty == false || properties.locationID != nil,
                  let root, root.deviceID == properties.id,
                  root.feature == feature, root.epoch == epoch else { return }
            preflight = MXErgoObserverPrecisionBinding(
                runID: runID, properties: properties, feature: feature,
                connectionEpoch: epoch
            )
        }
    }

    func seal(properties: [HIDDeviceProperties], feature: HIDPP20FeatureDescriptor?,
              epoch: UInt64) {
        lock.withLock {
            guard !finished else { return }
            finished = true
            guard properties.count == 1, let preflight,
                  properties[0] == preflight.properties,
                  feature == preflight.feature,
                  epoch == preflight.connectionEpoch else { return }
            sealed = preflight
        }
    }

    func sealedBinding(for expectedRunID: UUID) -> MXErgoObserverPrecisionBinding? {
        lock.withLock { expectedRunID == runID ? sealed : nil }
    }
}
