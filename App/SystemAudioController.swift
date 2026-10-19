import CoreAudio
import Foundation
import MXErgoCore

final class SmoothSystemAudioController: @unchecked Sendable {
    typealias StatusHandler = @Sendable (AudioExecutionStatus) -> Void
    typealias TickScheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    private let queue: DispatchQueue
    private let statusHandler: StatusHandler
    private let output: SystemAudioOutput
    private let scheduleTick: TickScheduler
    private var ramp = VolumeRampAccumulator()
    private var isRampScheduled = false
    private var targetVolume: Float32?
    private var currentVolume: Float32?
    private var rampGeneration: UInt64 = 0
    private var remainingRampTicks = 0

    init(
        output: SystemAudioOutput = .live,
        queue: DispatchQueue = DispatchQueue(
            label: "com.phib.MXErgoController.Audio",
            qos: .userInteractive
        ),
        scheduleTick: TickScheduler? = nil,
        statusHandler: @escaping StatusHandler
    ) {
        self.output = output
        self.queue = queue
        self.scheduleTick = scheduleTick ?? { delay, tick in
            queue.asyncAfter(deadline: .now() + delay, execute: tick)
        }
        self.statusHandler = statusHandler
    }

    func prepare() {
        queue.async { [self] in
            do {
                let volume = try output.currentVolume()
                currentVolume = volume
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
            do {
                if !isRampScheduled {
                    let volume = try output.currentVolume()
                    currentVolume = volume
                    targetVolume = volume
                }
                guard let targetVolume, let currentVolume else { return }
                let requestedChange = Float32(signedSteps) * ramp.scalarPerStep
                let nextTarget = min(1, max(0, targetVolume + requestedChange))
                self.targetVolume = nextTarget
                ramp.retarget(pendingScalarChange: nextTarget - currentVolume)
                // Normalized volume needs at most 32 default ticks. Allow
                // slower per-channel progress, but never chase a driver forever.
                remainingRampTicks = Int(ceil(2 / ramp.maximumScalarChangePerTick))
                guard !isRampScheduled else { return }
                rampGeneration &+= 1
                isRampScheduled = true
                drainRamp(generation: rampGeneration)
            } catch {
                resetRamp()
                statusHandler(.failed(message: error.localizedDescription))
            }
        }
    }

    func toggleMute() {
        queue.async { [self] in
            // A later mute gesture supersedes movement from an older scroll.
            // Otherwise the next ramp tick would immediately unmute again.
            resetRamp()
            do {
                let isMuted = try output.toggleMute()
                statusHandler(.muteChanged(isMuted: isMuted))
            } catch {
                statusHandler(.failed(message: error.localizedDescription))
            }
        }
    }

    func cancelPendingVolumeChanges() {
        queue.async { [self] in
            resetRamp()
        }
    }

    private func resetRamp() {
        rampGeneration &+= 1
        ramp.reset()
        targetVolume = nil
        currentVolume = nil
        isRampScheduled = false
        remainingRampTicks = 0
    }

    private func drainRamp(generation: UInt64) {
        guard generation == rampGeneration, isRampScheduled else { return }
        guard let scalarChange = ramp.takeNextChange() else {
            isRampScheduled = false
            return
        }

        do {
            let previousDistance = targetVolume.flatMap { target in
                currentVolume.map { abs(target - $0) }
            }
            let volume = try output.adjustVolume(scalarChange)
            currentVolume = volume
            remainingRampTicks -= 1
            if let targetVolume {
                ramp.retarget(pendingScalarChange: targetVolume - volume)
                if remainingRampTicks <= 0
                    || previousDistance.map({ abs(targetVolume - volume) >= $0 - 0.000_001 }) == true {
                    // CoreAudio success need not mean the device accepted a
                    // representable level. Stop at the reported value on a stall.
                    ramp.reset()
                    self.targetVolume = volume
                }
            }
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
            resetRamp()
            statusHandler(.failed(message: error.localizedDescription))
            return
        }

        guard ramp.hasPendingChange else {
            isRampScheduled = false
            return
        }

        scheduleTick(0.016) { [weak self] in
            self?.drainRamp(generation: generation)
        }
    }

    private static func percent(_ scalar: Float32) -> Int {
        Int((scalar * 100).rounded())
    }
}

/// The app uses CoreAudio; regression tests inject memory-only operations.
struct SystemAudioOutput: Sendable {
    var currentVolume: @Sendable () throws -> Float32
    var adjustVolume: @Sendable (Float32) throws -> Float32
    var toggleMute: @Sendable () throws -> Bool

    static let live = Self(
        currentVolume: { try CoreAudioOutput.currentVolume() },
        adjustVolume: { try CoreAudioOutput.adjustVolume(by: $0) },
        toggleMute: { try CoreAudioOutput.toggleMute() }
    )
}

/// Read synchronously by the wheel tap without crossing the main actor.
final class AudioExecutionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
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
