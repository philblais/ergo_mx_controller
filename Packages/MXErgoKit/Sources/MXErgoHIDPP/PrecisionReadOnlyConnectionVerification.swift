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

/// Pure, unwired read-only sequence. The eventual driver must separately bind
/// source/device lifetime, enforce a deadline, and abort on timeout or removal.
/// Each response key is used once: firmware replies do not echo entity indexes.
package struct PrecisionReadOnlyConnectionVerification: Sendable {
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
