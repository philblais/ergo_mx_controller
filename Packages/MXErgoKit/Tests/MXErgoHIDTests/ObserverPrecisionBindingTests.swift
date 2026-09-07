import Foundation
import Testing
import MXErgoCore
import MXErgoHIDPP
@testable import MXErgoHID

private let bindingFeature = HIDPP20FeatureDescriptor(index: 7, type: 0, version: 4)

private func bindingDevice(id: String = "observed-device") -> HIDDeviceProperties {
    HIDDeviceProperties(id: id, vendorID: 0x046D, productID: 0xB01D,
        productName: "MX Ergo", transport: "Bluetooth Low Energy",
        serialNumber: "proof-test", locationID: 29, primaryUsagePage: 1, primaryUsage: 2)
}

private func bindingSession(epoch: UInt64 = 41, index: UInt8 = 7,
                            firmware: String = "authorized-context") -> DeviceTransactionSession {
    DeviceTransactionSession(device: JournalDeviceIdentity(
        deviceID: "observed-device", vendorID: 0x046D, productID: 0xB01D,
        transport: "Bluetooth Low Energy", serialNumber: "proof-test", locationID: 29,
        firmwareIdentity: firmware), featureID: 0x1B04, featureVersion: 4,
        featureIndex: index, connectionEpoch: epoch)
}

private func recordBinding(_ store: MXErgoObserverPrecisionBindingStore) {
    let revision = store.currentRevision
    store.recordRoot(deviceID: bindingDevice().id, feature: bindingFeature,
                     epoch: 41, expectedRevision: revision)
    store.recordPreflight(properties: bindingDevice(), feature: bindingFeature,
                          epoch: 41, expectedRevision: revision)
}

private func sealBinding(_ store: MXErgoObserverPrecisionBindingStore) {
    store.seal(properties: [bindingDevice()], feature: bindingFeature, epoch: 41)
}

@Test func observerBindingIsUnavailableUntilSealedForTheExactRun() throws {
    let run = UUID()
    let store = MXErgoObserverPrecisionBindingStore(runID: run)
    recordBinding(store)
    #expect(store.sealedBinding(for: run) == nil)
    sealBinding(store)
    let proof = try #require(store.sealedBinding(for: run))
    #expect(proof.runID == run)
    #expect(proof.matches(bindingSession()))
    #expect(!proof.matches(bindingSession(epoch: 42)))
    #expect(!proof.matches(bindingSession(index: 8)))
    #expect(store.sealedBinding(for: UUID()) == nil)
    // Firmware is immutable authorization context, not an observer attestation.
    #expect(proof.matches(bindingSession(firmware: "different-context")))
}

@Test func observerBindingCannotBeResurrectedByLateTopologyReplies() {
    let run = UUID()
    let store = MXErgoObserverPrecisionBindingStore(runID: run)
    let revision = store.currentRevision
    recordBinding(store)
    store.invalidate()
    store.recordRoot(deviceID: bindingDevice().id, feature: bindingFeature,
                     epoch: 41, expectedRevision: revision)
    store.recordPreflight(properties: bindingDevice(), feature: bindingFeature,
                          epoch: 41, expectedRevision: revision)
    sealBinding(store)
    #expect(store.sealedBinding(for: run) == nil)
}

@Test func observerBindingRequiresRootAndPreflightFromTheSameEpoch() {
    let run = UUID()
    let store = MXErgoObserverPrecisionBindingStore(runID: run)
    store.recordRoot(deviceID: bindingDevice().id, feature: bindingFeature,
                     epoch: 40, expectedRevision: store.currentRevision)
    store.recordPreflight(properties: bindingDevice(), feature: bindingFeature,
                          epoch: 41, expectedRevision: store.currentRevision)
    sealBinding(store)
    #expect(store.sealedBinding(for: run) == nil)
}

@Test func observerBindingRejectsChangedTopologyFeatureAndEpochAtTeardown() {
    for scenario in 0..<4 {
        let run = UUID()
        let store = MXErgoObserverPrecisionBindingStore(runID: run)
        recordBinding(store)
        store.seal(
            properties: scenario == 0 ? [] : scenario == 1
                ? [bindingDevice(), bindingDevice(id: "second-device")] : [bindingDevice()],
            feature: scenario == 2 ? HIDPP20FeatureDescriptor(index: 8, type: 0, version: 4)
                : bindingFeature,
            epoch: scenario == 3 ? 42 : 41
        )
        #expect(store.sealedBinding(for: run) == nil)
    }
}

@Test func observerBindingFailureOrPoisonClearsPreviouslyValidProof() {
    for poison in [false, true] {
        let run = UUID()
        let store = MXErgoObserverPrecisionBindingStore(runID: run)
        recordBinding(store)
        if poison { store.invalidate() } else { store.beginPreflight() }
        sealBinding(store)
        #expect(store.sealedBinding(for: run) == nil)
    }
}

@Test func observerBindingCannotBeAddedOrReplacedAfterTeardown() {
    let run = UUID()
    let store = MXErgoObserverPrecisionBindingStore(runID: run)
    sealBinding(store)
    recordBinding(store)
    sealBinding(store)
    #expect(store.sealedBinding(for: run) == nil)
}

@Test func observerBindingRequiresAnObservedRootBeforePreflight() {
    let run = UUID()
    let store = MXErgoObserverPrecisionBindingStore(runID: run)
    store.recordPreflight(properties: bindingDevice(), feature: bindingFeature,
                          epoch: 41, expectedRevision: store.currentRevision)
    sealBinding(store)
    #expect(store.sealedBinding(for: run) == nil)
}
