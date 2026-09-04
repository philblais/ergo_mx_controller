import Foundation

public enum MappedControlActionPlanError: Error, Sendable, Equatable {
    case missingMappedControl(UInt16)
    case unexpectedMappedControl(UInt16)
    case precisionControlExcluded
}

public enum MappedControlActionSynthesisAuthorization: String, Sendable, Equatable {
    case notAuthorizedForExecution
}

public enum MappedControlHorizontalSwipe: String, Sendable, Equatable {
    case left
    case right
}

/// Value-only description of the BTT-replacement shortcut or swipe. This type
/// has no CGEvent, posting, or HID method.
public enum MappedControlSynthesizedAction: Sendable, Equatable {
    case controlArrow(name: String, keyCode: UInt16)
    case threeFingerSwipe(name: String, direction: MappedControlHorizontalSwipe)

    public var description: String {
        switch self {
        case let .controlArrow(name, keyCode):
            "Control+\(name) (key \(keyCode))"
        case let .threeFingerSwipe(name, direction):
            "3-finger swipe \(direction.rawValue) (\(name))"
        }
    }
}

public struct MappedControlActionBinding: Sendable, Equatable {
    public let control: MXErgoControl
    public let intent: ControllerIntent
    public let synthesizedAction: MappedControlSynthesizedAction
}

/// The five BTT-mapped actions this app may synthesize after those CIDs are
/// diverted. Construction performs no HID I/O and posts no events. Precision
/// mute/volume stay on the existing audio path.
public struct MappedControlActionPlan: Sendable, Equatable {
    public static let controlIDs: [UInt16] = [
        MXErgoControl.wheelClick.rawValue,
        MXErgoControl.lowerThumb.rawValue,
        MXErgoControl.upperThumb.rawValue,
        MXErgoControl.wheelTiltLeft.rawValue,
        MXErgoControl.wheelTiltRight.rawValue,
    ]

    public let bindings: [MappedControlActionBinding]
    public let authorization: MappedControlActionSynthesisAuthorization

    public static func make(
        reviewedControlIDs: [UInt16]
    ) throws -> MappedControlActionPlan {
        if reviewedControlIDs.contains(MXErgoControl.precision.rawValue) {
            throw MappedControlActionPlanError.precisionControlExcluded
        }
        let expected = Set(controlIDs)
        let reviewed = Set(reviewedControlIDs)
        if let unexpected = reviewed.subtracting(expected).sorted().first {
            throw MappedControlActionPlanError.unexpectedMappedControl(unexpected)
        }
        if let missing = expected.subtracting(reviewed).sorted().first {
            throw MappedControlActionPlanError.missingMappedControl(missing)
        }

        return MappedControlActionPlan(
            bindings: controlIDs.compactMap { id in
                MXErgoControl(rawValue: id).flatMap(binding(for:))
            },
            authorization: .notAuthorizedForExecution
        )
    }

    public func binding(for controlID: UInt16) throws -> MappedControlActionBinding {
        guard let binding = bindings.first(where: { $0.control.rawValue == controlID }) else {
            throw MappedControlActionPlanError.unexpectedMappedControl(controlID)
        }
        return binding
    }

    private static func binding(
        for control: MXErgoControl
    ) -> MappedControlActionBinding? {
        switch control {
        case .upperThumb:
            return MappedControlActionBinding(
                control: .upperThumb,
                intent: .desktopLeft,
                synthesizedAction: .controlArrow(name: "Left Arrow", keyCode: 123)
            )
        case .lowerThumb:
            return MappedControlActionBinding(
                control: .lowerThumb,
                intent: .desktopRight,
                synthesizedAction: .controlArrow(name: "Right Arrow", keyCode: 124)
            )
        case .wheelTiltLeft:
            return MappedControlActionBinding(
                control: .wheelTiltLeft,
                intent: .navigateBack,
                synthesizedAction: .threeFingerSwipe(
                    name: "Page Back",
                    direction: .left
                )
            )
        case .wheelTiltRight:
            return MappedControlActionBinding(
                control: .wheelTiltRight,
                intent: .navigateForward,
                synthesizedAction: .threeFingerSwipe(
                    name: "Page Forward",
                    direction: .right
                )
            )
        case .wheelClick:
            return MappedControlActionBinding(
                control: .wheelClick,
                intent: .missionControl,
                synthesizedAction: .controlArrow(name: "Up Arrow", keyCode: 126)
            )
        case .precision:
            return nil
        }
    }
}
