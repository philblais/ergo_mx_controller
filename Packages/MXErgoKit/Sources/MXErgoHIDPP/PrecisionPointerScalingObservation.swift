/// A read-only measurement; it is not proof of native Precision mode or write authorization.
public struct PrecisionPointerScalingObservation: Codable, Sendable, Equatable {
    public let device: JournalDeviceIdentity
    public let connectionEpoch: UInt64
    public let rootGeneration: UInt64
    public let featureIndex: UInt8
    public let featureVersion: UInt8
    public let rawScaling: UInt16
    public let requests: [[UInt8]]
    public let responses: [[UInt8]]
}
