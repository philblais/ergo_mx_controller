import Foundation

public enum MappedControlEventDeliveryAuthorization: String, Sendable, Equatable {
    case notAuthorizedForExecution
}

/// Resolves diverted mapped-control HID++ notifications into controller
/// intents. Only explicitly admitted CIDs from the five BTT-mapped controls
/// produce events. Precision stays on `PrecisionControlEventPump`. This type
/// posts no CGEvent and performs no HID I/O.
public struct MappedControlEventPump: Sendable {
    public let featureIndex: UInt8
    public let reviewedControlIDs: [UInt16]
    public let admittedControlIDs: Set<UInt16>
    private var resolver: ControllerIntentResolver

    public init(
        featureIndex: UInt8,
        reviewedControlIDs: [UInt16],
        admittedControlIDs: Set<UInt16> = []
    ) throws {
        _ = try MappedControlActionPlan.make(reviewedControlIDs: reviewedControlIDs)
        if admittedControlIDs.contains(MXErgoControl.precision.rawValue) {
            throw MappedControlActionPlanError.precisionControlExcluded
        }
        let allowed = Set(MappedControlActionPlan.controlIDs)
        if let unexpected = admittedControlIDs.subtracting(allowed).sorted().first {
            throw MappedControlActionPlanError.unexpectedMappedControl(unexpected)
        }
        self.featureIndex = featureIndex
        self.reviewedControlIDs = MappedControlActionPlan.controlIDs
        self.admittedControlIDs = admittedControlIDs
        resolver = ControllerIntentResolver()
    }

    public mutating func processHIDPPNotification(
        _ bytes: [UInt8],
        at timestamp: TimeInterval
    ) -> [ControllerIntent] {
        guard let event = LogitechControlEventDecoder.decodeNotification(
            bytes,
            featureIndex: featureIndex
        ) else {
            return []
        }
        switch event {
        case let .pressed(controlID):
            guard admittedControlIDs.contains(controlID),
                  let control = MXErgoControl(rawValue: controlID),
                  control != .precision else {
                return []
            }
            return resolver.process(.controlPressed(control), at: timestamp)
        case .released:
            return resolver.process(.controlsReleased, at: timestamp)
        }
    }
}

/// Immutable proof that mapped-control event delivery is reviewed and closed.
/// The app constructs this with an empty admitted set. It has no posting method.
public struct MappedControlEventDeliverySnapshot: Sendable, Equatable {
    public let featureIndex: UInt8
    public let reviewedControlIDs: [UInt16]
    public let admittedControlIDs: [UInt16]
    public let authorization: MappedControlEventDeliveryAuthorization

    public static func makeUnauthorized(
        featureIndex: UInt8,
        reviewedControlIDs: [UInt16]
    ) throws -> MappedControlEventDeliverySnapshot {
        _ = try MappedControlEventPump(
            featureIndex: featureIndex,
            reviewedControlIDs: reviewedControlIDs,
            admittedControlIDs: []
        )
        return MappedControlEventDeliverySnapshot(
            featureIndex: featureIndex,
            reviewedControlIDs: MappedControlActionPlan.controlIDs,
            admittedControlIDs: [],
            authorization: .notAuthorizedForExecution
        )
    }
}
