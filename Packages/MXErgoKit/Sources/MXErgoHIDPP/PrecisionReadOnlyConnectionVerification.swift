import Foundation

package enum PrecisionConnectionVerificationError: Error, Sendable, Equatable {
    case invalidExpectedSession
    case requestAlreadyPending
    case noRequestPending
    case alreadyFinished
    case failed
    case candidateLimitExceeded
    case requestLimitExceeded
    case protocolError(UInt8)
    case echoedRequest
    case featureChanged
    case unsupportedFirmwareFeature
    case unsupportedEntityCount(UInt8)
    case firmwareChanged
}

/// A transcript result only. It does not attest transport provenance, endpoint
/// liveness, continuity with an earlier observer, or permission to send a SET.
package struct PrecisionConnectionVerificationObservation: Sendable, Equatable {
    package let feature: HIDPP20FeatureDescriptor
    package let firmware: HIDPP20FirmwareFingerprint
    package let requestCount: Int
}

/// Exact read-only packet capability. Only the fixed sequence can mint it;
/// its UUID is consumed by the existing output lifecycle's replay protection.
package struct PrecisionConnectionVerificationRequest: Sendable, Equatable {
    package let requestID: UUID
    package let session: DeviceTransactionSession
    package let message: HIDPP20LongMessage

    fileprivate init(session: DeviceTransactionSession, message: HIDPP20LongMessage) {
        requestID = UUID()
        self.session = session
        self.message = message
    }
}

/// Pure read-only sequence. The driver must separately bind
/// source/device lifetime, enforce a deadline, and abort on timeout or removal.
/// Each response key is used once: firmware replies do not echo entity indexes.
package struct PrecisionReadOnlyConnectionVerification: PrecisionReadOnlyEndpointSequence {
    package static let maximumEntityCount: UInt8 = 15
    package static let maximumRequestCount = 19
    package static let maximumCandidateCount = 64

    private enum Stage: Sendable {
        case initialRoot, firmwareRoot, deviceInfo, entity(UInt8), finalRoot
        case complete, failed
    }

    private let expected: DeviceTransactionSession
    private var stage: Stage = .initialRoot
    private var pending: HIDPP20LongMessage?
    private var initialFeature: HIDPP20FeatureDescriptor?
    private var firmwareFeature: HIDPP20FeatureDescriptor?
    private var deviceInfo: HIDPP20DeviceInfo?
    private var entities: [HIDPP20FirmwareEntity] = []
    private var issuedKeys: Set<HIDPP20RequestKey> = []
    private var candidateCount = 0
    package private(set) var observation: PrecisionConnectionVerificationObservation?

    package init(expectedSession: DeviceTransactionSession) throws {
        guard expectedSession.device.vendorID == 0x046D,
              expectedSession.device.productID == 0xB01D,
              expectedSession.device.transport == "Bluetooth Low Energy",
              expectedSession.device.hasStableDiscriminator,
              expectedSession.device.firmwareIdentity?.isEmpty == false,
              expectedSession.featureID == ReprogControlsV4.featureID,
              expectedSession.featureIndex != 0,
              expectedSession.featureIndex != 0xFF,
              expectedSession.featureVersion == 3 else {
            throw PrecisionConnectionVerificationError.invalidExpectedSession
        }
        expected = expectedSession
    }

    package mutating func beginOutputRequest() throws -> PrecisionConnectionVerificationRequest {
        let message = try beginRequest()
        return PrecisionConnectionVerificationRequest(session: expected, message: message)
    }

    /// Consumes a stage once; calling again cannot obtain a resend packet.
    package mutating func beginRequest() throws -> HIDPP20LongMessage {
        try requireUnfinished()
        guard pending == nil else {
            throw PrecisionConnectionVerificationError.requestAlreadyPending
        }
        let request: HIDPP20LongMessage
        switch stage {
        case .initialRoot, .finalRoot:
            request = try HIDPP20Root.getFeatureRequest(
                ReprogControlsV4.featureID, deviceIndex: 0,
                softwareID: isFinalRoot ? 3 : 1
            )
        case .firmwareRoot:
            request = try HIDPP20Root.getFeatureRequest(
                HIDPP20DeviceInformation.featureID, deviceIndex: 0, softwareID: 2
            )
        case .deviceInfo:
            guard let firmwareFeature else { throw fail(.failed) }
            request = try HIDPP20DeviceInformation.getDeviceInfoRequest(
                featureIndex: firmwareFeature.index, deviceIndex: 0, softwareID: 1
            )
        case let .entity(index):
            guard let firmwareFeature else { throw fail(.failed) }
            request = try HIDPP20DeviceInformation.getFirmwareInfoRequest(
                entityIndex: index, featureIndex: firmwareFeature.index,
                deviceIndex: 0, softwareID: index + 1
            )
        case .complete, .failed:
            throw PrecisionConnectionVerificationError.failed
        }
        guard issuedKeys.count < Self.maximumRequestCount,
              issuedKeys.insert(request.requestKey).inserted else {
            throw fail(.requestLimitExceeded)
        }
        pending = request
        return request
    }

    package mutating func observe(bytes: [UInt8]) throws -> Bool {
        do { return try observe(HIDPP20LongMessage(bytes: bytes)) }
        catch {
            abort()
            throw error
        }
    }

    /// False means unrelated input; no stage advances. A bounded candidate
    /// budget prevents unrelated input from keeping the future driver busy.
    @discardableResult
    package mutating func observe(_ response: HIDPP20LongMessage) throws -> Bool {
        try requireUnfinished()
        guard let request = pending else {
            throw PrecisionConnectionVerificationError.noRequestPending
        }
        candidateCount += 1
        guard candidateCount <= Self.maximumCandidateCount else {
            throw fail(.candidateLimitExceeded)
        }
        if let error = HIDPP20ErrorResponse(message: response) {
            guard error.requestKey == request.requestKey else { return false }
            throw fail(.protocolError(error.rawErrorCode))
        }
        guard response.requestKey == request.requestKey else { return false }
        guard response.bytes != request.bytes else { throw fail(.echoedRequest) }
        pending = nil
        do {
            switch stage {
            case .initialRoot:
                let feature = try HIDPP20Root.decodeFeatureDescriptor(from: response)
                try requireExpectedFeature(feature)
                initialFeature = feature
                stage = .firmwareRoot
            case .firmwareRoot:
                let feature = try HIDPP20Root.decodeFeatureDescriptor(from: response)
                guard feature.isSupported, feature.index != 0xFF,
                      feature.index != expected.featureIndex else {
                    throw PrecisionConnectionVerificationError.unsupportedFirmwareFeature
                }
                firmwareFeature = feature
                stage = .deviceInfo
            case .deviceInfo:
                guard let firmwareFeature else { throw PrecisionConnectionVerificationError.failed }
                let info = try HIDPP20DeviceInformation.decodeDeviceInfo(
                    from: response, featureIndex: firmwareFeature.index
                )
                guard info.entityCount <= Self.maximumEntityCount else {
                    throw PrecisionConnectionVerificationError.unsupportedEntityCount(info.entityCount)
                }
                deviceInfo = info
                stage = .entity(0)
            case let .entity(index):
                guard let firmwareFeature, let deviceInfo else {
                    throw PrecisionConnectionVerificationError.failed
                }
                entities.append(try HIDPP20DeviceInformation.decodeFirmwareInfo(
                    entityIndex: index, from: response, featureIndex: firmwareFeature.index
                ))
                stage = index + 1 < deviceInfo.entityCount ? .entity(index + 1) : .finalRoot
            case .finalRoot:
                let feature = try HIDPP20Root.decodeFeatureDescriptor(from: response)
                try requireExpectedFeature(feature)
                guard feature == initialFeature, let firmwareFeature, let deviceInfo else {
                    throw PrecisionConnectionVerificationError.featureChanged
                }
                let firmware = try HIDPP20FirmwareFingerprint(
                    featureVersion: firmwareFeature.version, deviceInfo: deviceInfo, entities: entities
                )
                guard firmware.canonicalIdentity == expected.device.firmwareIdentity else {
                    throw PrecisionConnectionVerificationError.firmwareChanged
                }
                observation = PrecisionConnectionVerificationObservation(
                    feature: feature, firmware: firmware, requestCount: issuedKeys.count
                )
                stage = .complete
            case .complete, .failed:
                throw PrecisionConnectionVerificationError.failed
            }
            return true
        } catch {
            abort()
            throw error
        }
    }

    /// Sticky: timeout, cancellation, source mismatch or removal must end this
    /// instance. No new request or result can be obtained after invalidation.
    package mutating func abort() {
        stage = .failed
        pending = nil
        observation = nil
    }

    private var isFinalRoot: Bool { if case .finalRoot = stage { true } else { false } }

    private func requireExpectedFeature(_ feature: HIDPP20FeatureDescriptor) throws {
        guard feature.index == expected.featureIndex, feature.version == expected.featureVersion else {
            throw PrecisionConnectionVerificationError.featureChanged
        }
    }

    private func requireUnfinished() throws {
        switch stage {
        case .complete: throw PrecisionConnectionVerificationError.alreadyFinished
        case .failed: throw PrecisionConnectionVerificationError.failed
        default: break
        }
    }

    private mutating func fail(_ error: PrecisionConnectionVerificationError) -> PrecisionConnectionVerificationError {
        abort()
        return error
    }
}

/// Only fixed package sequences can mint output capabilities; the driver accepts
/// a sequence, never arbitrary packets supplied by a caller.
package protocol PrecisionReadOnlyEndpointSequence: Sendable {
    associatedtype Observation: Sendable
    var observation: Observation? { get }
    mutating func beginOutputRequest() throws -> PrecisionConnectionVerificationRequest
    mutating func observe(bytes: [UInt8]) throws -> Bool
    mutating func abort()
}


package enum PrecisionPointerInspectionError: Error, Sendable, Equatable {
    case unsupported
    case invalidResponse
    case alreadyAttempted
    case unavailable
}

/// Read-only x2205 protocol: Root lookup, getPointerScalingValue, Root recheck.
/// A scaler is a measurement, not proof of native Precision mode or SET consent.
package struct PrecisionReadOnlyPointerScaling: PrecisionReadOnlyEndpointSequence {
    private let session: DeviceTransactionSession
    private let rootGeneration: UInt64
    private var stage = 0
    private var pending: PrecisionConnectionVerificationRequest?
    private var feature: HIDPP20FeatureDescriptor?
    private var scaling: UInt16?
    private var candidates = 0
    private var requests: [[UInt8]] = []
    private var responses: [[UInt8]] = []
    package private(set) var observation: PrecisionPointerScalingObservation?

    package init(expectedSession: DeviceTransactionSession, rootGeneration: UInt64) throws {
        _ = try PrecisionReadOnlyConnectionVerification(expectedSession: expectedSession)
        session = expectedSession
        self.rootGeneration = rootGeneration
    }

    package mutating func beginOutputRequest() throws -> PrecisionConnectionVerificationRequest {
        guard (0...2).contains(stage), pending == nil else { throw PrecisionPointerInspectionError.alreadyAttempted }
        let message: HIDPP20LongMessage
        if stage == 1 {
            guard let feature else { abort(); throw PrecisionPointerInspectionError.unavailable }
            message = try HIDPP20LongMessage(deviceIndex: 0, featureIndex: feature.index,
                functionID: 0, softwareID: 5, parameters: [])
        } else {
            message = try HIDPP20Root.getFeatureRequest(0x2205, deviceIndex: 0, softwareID: stage == 0 ? 4 : 6)
        }
        let request = PrecisionConnectionVerificationRequest(session: session, message: message)
        pending = request
        requests.append(message.bytes)
        return request
    }

    package mutating func observe(bytes: [UInt8]) throws -> Bool {
        do {
            guard let pending, (0...2).contains(stage) else { throw PrecisionPointerInspectionError.unavailable }
            candidates += 1
            guard candidates <= 32 else { throw PrecisionConnectionVerificationError.candidateLimitExceeded }
            let response = try HIDPP20LongMessage(bytes: bytes)
            if let error = HIDPP20ErrorResponse(message: response) {
                guard error.requestKey == pending.message.requestKey else { return false }
                throw PrecisionConnectionVerificationError.protocolError(error.rawErrorCode)
            }
            guard response.requestKey == pending.message.requestKey else { return false }
            guard response.bytes != pending.message.bytes else { throw PrecisionConnectionVerificationError.echoedRequest }
            responses.append(bytes)
            switch stage {
            case 0:
                let descriptor = try HIDPP20Root.decodeFeatureDescriptor(from: response)
                guard descriptor.isSupported, descriptor.index != 0xFF,
                      descriptor.index != session.featureIndex, descriptor.version == 0 else {
                    throw PrecisionPointerInspectionError.unsupported
                }
                feature = descriptor
            case 1:
                let value = UInt16(response.parameters[0]) << 8 | UInt16(response.parameters[1])
                guard value > 0, value <= 0x1000 else { throw PrecisionPointerInspectionError.invalidResponse }
                scaling = value
            case 2:
                let descriptor = try HIDPP20Root.decodeFeatureDescriptor(from: response)
                guard descriptor == feature, let scaling, let feature else {
                    throw PrecisionConnectionVerificationError.featureChanged
                }
                observation = PrecisionPointerScalingObservation(device: session.device,
                    connectionEpoch: session.connectionEpoch, rootGeneration: rootGeneration,
                    featureIndex: feature.index, featureVersion: feature.version, rawScaling: scaling,
                    requests: requests, responses: responses)
            default: throw PrecisionPointerInspectionError.unavailable
            }
            self.pending = nil
            stage += 1
            return true
        } catch { abort(); throw error }
    }

    package mutating func abort() {
        stage = -1
        pending = nil
        observation = nil
    }
}
