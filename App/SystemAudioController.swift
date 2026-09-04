import CoreAudio
import Foundation
import MXErgoCore

enum AudioExecutionStatus: Sendable, Equatable {
    case disabled
    case ready(volumePercent: Int)
    case volumeAdjusting(currentPercent: Int, targetPercent: Int)
    case volumeChanged(percent: Int)
    case muteChanged(isMuted: Bool)
    case failed(message: String)

    var message: String {
        switch self {
        case .disabled:
            "Audio execution disabled"
        case let .ready(volumePercent):
            "Ready · volume \(volumePercent)%"
        case let .volumeAdjusting(currentPercent, targetPercent):
            "Volume \(currentPercent)% → \(targetPercent)%"
        case let .volumeChanged(percent):
            "Volume \(percent)%"
        case let .muteChanged(isMuted):
            isMuted ? "Muted" : "Unmuted"
        case let .failed(message):
            message
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

final class SmoothSystemAudioController: @unchecked Sendable {
    typealias StatusHandler = @Sendable (AudioExecutionStatus) -> Void

    private let queue = DispatchQueue(
        label: "com.phib.MXErgoController.Audio",
        qos: .userInteractive
    )
    private let statusHandler: StatusHandler
    private var ramp = VolumeRampAccumulator()
    private var isRampScheduled = false
    private var targetVolume: Float32?

    init(statusHandler: @escaping StatusHandler) {
        self.statusHandler = statusHandler
    }

    func prepare() {
        queue.async { [self] in
            do {
                let volume = try CoreAudioOutput.currentVolume()
                targetVolume = volume
                statusHandler(.ready(volumePercent: Self.percent(volume)))
            } catch {
                statusHandler(.failed(message: error.localizedDescription))
            }
        }
    }

    func enqueueVolumeSteps(_ signedSteps: Int) {
        guard signedSteps != 0 else { return }
        queue.async { [self] in
            if !isRampScheduled {
                targetVolume = try? CoreAudioOutput.currentVolume()
            }
            if let targetVolume {
                let requestedChange = Float32(signedSteps) * ramp.scalarPerStep
                self.targetVolume = min(1, max(0, targetVolume + requestedChange))
            }
            ramp.enqueue(steps: signedSteps)
            guard !isRampScheduled else { return }
            isRampScheduled = true
            drainRamp()
        }
    }

    func toggleMute() {
        queue.async { [self] in
            do {
                let isMuted = try CoreAudioOutput.toggleMute()
                statusHandler(.muteChanged(isMuted: isMuted))
            } catch {
                statusHandler(.failed(message: error.localizedDescription))
            }
        }
    }

    func cancelPendingVolumeChanges() {
        queue.async { [self] in
            ramp.reset()
            targetVolume = nil
        }
    }

    private func drainRamp() {
        guard let scalarChange = ramp.takeNextChange() else {
            isRampScheduled = false
            return
        }

        do {
            let volume = try CoreAudioOutput.adjustVolume(by: scalarChange)
            if ramp.hasPendingChange, let targetVolume {
                statusHandler(.volumeAdjusting(
                    currentPercent: Self.percent(volume),
                    targetPercent: Self.percent(targetVolume)
                ))
            } else {
                targetVolume = volume
                statusHandler(.volumeChanged(percent: Self.percent(volume)))
            }

            if (volume >= 0.999 && scalarChange > 0) || (volume <= 0.001 && scalarChange < 0) {
                ramp.reset()
                targetVolume = volume
            }
        } catch {
            ramp.reset()
            isRampScheduled = false
            statusHandler(.failed(message: error.localizedDescription))
            return
        }

        guard ramp.hasPendingChange else {
            isRampScheduled = false
            return
        }

        queue.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
            self?.drainRamp()
        }
    }

    private static func percent(_ scalar: Float32) -> Int {
        Int((scalar * 100).rounded())
    }
}

private enum CoreAudioOutput {
    static func currentVolume() throws -> Float32 {
        let deviceID = try defaultOutputDevice()
        let addresses = try settableAddresses(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar
        )
        let values = try addresses.map { try readFloat(deviceID: deviceID, address: $0) }
        return values.reduce(0, +) / Float32(values.count)
    }

    static func adjustVolume(by scalarChange: Float32) throws -> Float32 {
        let deviceID = try defaultOutputDevice()
        let addresses = try settableAddresses(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar
        )

        try setMute(false, deviceID: deviceID, onlyIfSupported: true)

        var updatedValues: [Float32] = []
        for address in addresses {
            let current = try readFloat(deviceID: deviceID, address: address)
            let updated = min(1, max(0, current + scalarChange))
            try writeFloat(updated, deviceID: deviceID, address: address)
            updatedValues.append(updated)
        }
        return updatedValues.reduce(0, +) / Float32(updatedValues.count)
    }

    static func toggleMute() throws -> Bool {
        let deviceID = try defaultOutputDevice()
        let addresses = try settableAddresses(
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute
        )
        let currentValues = try addresses.map { try readUInt32(deviceID: deviceID, address: $0) }
        let shouldMute = !currentValues.allSatisfy { $0 != 0 }

        for address in addresses {
            try writeUInt32(shouldMute ? 1 : 0, deviceID: deviceID, address: address)
        }
        return shouldMute
    }

    private static func setMute(
        _ isMuted: Bool,
        deviceID: AudioDeviceID,
        onlyIfSupported: Bool
    ) throws {
        let addresses: [AudioObjectPropertyAddress]
        do {
            addresses = try settableAddresses(
                deviceID: deviceID,
                selector: kAudioDevicePropertyMute
            )
        } catch AudioControlError.propertyUnavailable where onlyIfSupported {
            return
        }

        for address in addresses {
            try writeUInt32(isMuted ? 1 : 0, deviceID: deviceID, address: address)
        }
    }

    private static func defaultOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        try requireSuccess(status, operation: "Read default output device")
        guard deviceID != kAudioObjectUnknown else {
            throw AudioControlError.noDefaultOutputDevice
        }
        return deviceID
    }

    private static func settableAddresses(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) throws -> [AudioObjectPropertyAddress] {
        let mainAddress = propertyAddress(selector: selector, element: kAudioObjectPropertyElementMain)
        if isSettable(deviceID: deviceID, address: mainAddress) {
            return [mainAddress]
        }

        let channelAddresses = (1...2)
            .map { propertyAddress(selector: selector, element: AudioObjectPropertyElement($0)) }
            .filter { isSettable(deviceID: deviceID, address: $0) }
        guard !channelAddresses.isEmpty else {
            throw AudioControlError.propertyUnavailable
        }
        return channelAddresses
    }

    private static func propertyAddress(
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func isSettable(
        deviceID: AudioDeviceID,
        address: AudioObjectPropertyAddress
    ) -> Bool {
        var address = address
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var isSettable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        return status == noErr && isSettable.boolValue
    }

    private static func readFloat(
        deviceID: AudioDeviceID,
        address: AudioObjectPropertyAddress
    ) throws -> Float32 {
        var address = address
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        try requireSuccess(status, operation: "Read output volume")
        return value
    }

    private static func writeFloat(
        _ value: Float32,
        deviceID: AudioDeviceID,
        address: AudioObjectPropertyAddress
    ) throws {
        var address = address
        var value = value
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        try requireSuccess(status, operation: "Set output volume")
    }

    private static func readUInt32(
        deviceID: AudioDeviceID,
        address: AudioObjectPropertyAddress
    ) throws -> UInt32 {
        var address = address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        try requireSuccess(status, operation: "Read output mute")
        return value
    }

    private static func writeUInt32(
        _ value: UInt32,
        deviceID: AudioDeviceID,
        address: AudioObjectPropertyAddress
    ) throws {
        var address = address
        var value = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        try requireSuccess(status, operation: "Set output mute")
    }

    private static func requireSuccess(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw AudioControlError.coreAudio(operation: operation, status: status)
        }
    }
}

private enum AudioControlError: LocalizedError {
    case noDefaultOutputDevice
    case propertyUnavailable
    case coreAudio(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .noDefaultOutputDevice:
            "No default audio output device is available."
        case .propertyUnavailable:
            "The current output device does not provide software volume or mute control."
        case let .coreAudio(operation, status):
            "\(operation) failed (CoreAudio \(status))."
        }
    }
}
