import Foundation

public enum ControllerInput: Sendable, Equatable {
    case controlPressed(MXErgoControl)
    case controlsReleased
    case standardMouseButtonsChanged(previous: UInt8, current: UInt8)
    case verticalScroll(notches: Int)
}

public enum ControllerIntent: Sendable, Equatable {
    case desktopLeft
    case desktopRight
    case navigateBack
    case navigateForward
    case missionControl
    case toggleMute
    case volumeUp(steps: Int)
    case volumeDown(steps: Int)

    public var name: String {
        switch self {
        case .desktopLeft: "Desktop left"
        case .desktopRight: "Desktop right"
        case .navigateBack: "Back"
        case .navigateForward: "Forward"
        case .missionControl: "Mission Control"
        case .toggleMute: "Mute / unmute"
        case let .volumeUp(steps): "Volume up ×\(steps)"
        case let .volumeDown(steps): "Volume down ×\(steps)"
        }
    }
}

/// Converts calibrated physical inputs into the user's desired behavior without
/// performing system actions. Keeping this state machine pure makes tap/hold
/// semantics testable before HID diversion or event synthesis is introduced.
public struct ControllerIntentResolver: Sendable {
    public let precisionTapMaximumDuration: TimeInterval
    public let volumeStepsPerNotch: Int

    private var activeControl: MXErgoControl?
    private var precisionPressedAt: TimeInterval?
    private var precisionWasUsedForVolume = false

    public init(
        precisionTapMaximumDuration: TimeInterval = 0.3,
        volumeStepsPerNotch: Int = 2
    ) {
        self.precisionTapMaximumDuration = precisionTapMaximumDuration
        self.volumeStepsPerNotch = volumeStepsPerNotch
    }

    public var isPrecisionPressed: Bool { activeControl == .precision }

    public mutating func process(
        _ input: ControllerInput,
        at timestamp: TimeInterval
    ) -> [ControllerIntent] {
        switch input {
        case let .controlPressed(control):
            guard activeControl != control else { return [] }
            activeControl = control

            if control == .precision {
                precisionPressedAt = timestamp
                precisionWasUsedForVolume = false
                return []
            }

            return intent(for: control).map { [$0] } ?? []

        case .controlsReleased:
            defer {
                activeControl = nil
                precisionPressedAt = nil
                precisionWasUsedForVolume = false
            }

            guard activeControl == .precision,
                  let pressedAt = precisionPressedAt,
                  timestamp - pressedAt <= precisionTapMaximumDuration + 0.000_001,
                  !precisionWasUsedForVolume else {
                return []
            }
            return [.toggleMute]

        case let .standardMouseButtonsChanged(previous, current):
            let wheelMask = StandardMouseButton.wheel.rawValue
            let wheelWasDown = previous & wheelMask != 0
            let wheelIsDown = current & wheelMask != 0
            return !wheelWasDown && wheelIsDown ? [.missionControl] : []

        case let .verticalScroll(notches):
            guard activeControl == .precision, notches != 0 else { return [] }
            precisionWasUsedForVolume = true
            let steps = abs(notches) * volumeStepsPerNotch
            return notches > 0 ? [.volumeUp(steps: steps)] : [.volumeDown(steps: steps)]
        }
    }

    private func intent(for control: MXErgoControl) -> ControllerIntent? {
        switch control {
        case .upperThumb: .desktopLeft
        case .lowerThumb: .desktopRight
        case .wheelTiltLeft: .navigateBack
        case .wheelTiltRight: .navigateForward
        case .wheelClick: .missionControl
        case .precision: nil
        }
    }
}
