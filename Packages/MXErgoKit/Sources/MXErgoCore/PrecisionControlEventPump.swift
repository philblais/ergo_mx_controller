import Foundation

/// Resolves diverted Precision HID++ notifications into controller intents.
/// Other CIDs are ignored because this runtime only temporarily diverts
/// Precision. Wheel volume is applied only while Precision is held.
public struct PrecisionControlEventPump: Sendable {
    public let featureIndex: UInt8
    private var resolver: ControllerIntentResolver

    public var isPrecisionPressed: Bool { resolver.isPrecisionPressed }

    public init(
        featureIndex: UInt8,
        precisionTapMaximumDuration: TimeInterval = 0.3,
        volumeStepsPerNotch: Int = 2
    ) {
        self.featureIndex = featureIndex
        resolver = ControllerIntentResolver(
            precisionTapMaximumDuration: precisionTapMaximumDuration,
            volumeStepsPerNotch: volumeStepsPerNotch
        )
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
            guard controlID == MXErgoControl.precision.rawValue else {
                return []
            }
            return resolver.process(.controlPressed(.precision), at: timestamp)
        case .released:
            return resolver.process(.controlsReleased, at: timestamp)
        }
    }

    public mutating func processVerticalScroll(
        notches: Int,
        at timestamp: TimeInterval
    ) -> [ControllerIntent] {
        resolver.process(.verticalScroll(notches: notches), at: timestamp)
    }
}
