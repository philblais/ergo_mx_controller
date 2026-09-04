import Foundation

public enum MappedControlReadOnlyPreflightAuthorization:
    String, Sendable, Equatable {
    case notAuthorizedForExecution
}

public enum MappedControlReadOnlyPreflightError: Error, Sendable, Equatable {
    case missingMappedControl(UInt16)
    case unexpectedMappedControl(UInt16)
    case precisionControlExcluded
    case verificationRequestMismatch(UInt16)
    case unexpectedResponse(UInt16)
    case baselineMismatch(UInt16)
    case sequenceAlreadyComplete
    case sequenceAlreadyFailed
}

/// One reviewed GetCidReporting packet for a mapped MX Ergo control.
/// Construction and evaluation perform no HID I/O.
public struct MappedControlReadOnlyPreflight: Sendable, Equatable {
    public let controlID: UInt16
    public let baseline: DeviceTransactionWireState
    public let verificationRequest: HIDPP20LongMessage

    public func decodeResponse(
        _ response: HIDPP20LongMessage,
        featureIndex: UInt8,
        featureVersion: UInt8
    ) throws -> DeviceTransactionWireState {
        let reporting = try ReprogControlsV4.decodeReporting(
            requestedControlID: controlID,
            from: response,
            featureIndex: featureIndex,
            featureVersion: featureVersion
        )
        let state = try DeviceTransactionWireState(
            rawParameters: reporting.rawParameters
        )
        guard state.controlID == controlID else {
            throw MappedControlReadOnlyPreflightError.unexpectedResponse(controlID)
        }
        return state
    }

    public func evaluateResponse(
        _ response: HIDPP20LongMessage,
        featureIndex: UInt8,
        featureVersion: UInt8
    ) throws -> DeviceTransactionWireState {
        let state = try decodeResponse(
            response,
            featureIndex: featureIndex,
            featureVersion: featureVersion
        )
        guard state == baseline else {
            throw MappedControlReadOnlyPreflightError.baselineMismatch(controlID)
        }
        return state
    }
}

/// The five independent GET packets this app may send later as a mapped-control
/// preflight. This value has no observer, transport, SET, or retry method.
public struct MappedControlsReadOnlyPreflightPlan: Sendable, Equatable {
    public static let maximumPacketCount = 5

    public let controls: [MappedControlReadOnlyPreflight]
    public let featureIndex: UInt8
    public let featureVersion: UInt8
    public let authorization: MappedControlReadOnlyPreflightAuthorization

    public static func make(
        from plan: MappedControlsTemporaryDiversionPlan
    ) throws -> MappedControlsReadOnlyPreflightPlan {
        let reviewedIDs = plan.controls.map(\.controlID)
        if reviewedIDs.contains(PrecisionTemporaryDiversionPlan.controlID) {
            throw MappedControlReadOnlyPreflightError.precisionControlExcluded
        }
        let expected = Set(MappedControlsTemporaryDiversionPlan.controlIDs)
        let reviewed = Set(reviewedIDs)
        if let unexpected = reviewed.subtracting(expected).sorted().first {
            throw MappedControlReadOnlyPreflightError.unexpectedMappedControl(
                unexpected
            )
        }
        if let missing = expected.subtracting(reviewed).sorted().first {
            throw MappedControlReadOnlyPreflightError.missingMappedControl(missing)
        }

        let controls = try plan.controls.map { control in
            let expectedRequest = try ReprogControlsV4.getReportingRequest(
                controlID: control.controlID,
                featureIndex: plan.featureIndex,
                deviceIndex: control.verificationRequest.deviceIndex,
                softwareID: control.verificationRequest.softwareID
            )
            guard expectedRequest == control.verificationRequest,
                  expectedRequest.functionID == 2 else {
                throw MappedControlReadOnlyPreflightError
                    .verificationRequestMismatch(control.controlID)
            }
            return MappedControlReadOnlyPreflight(
                controlID: control.controlID,
                baseline: control.baseline,
                verificationRequest: control.verificationRequest
            )
        }
        return MappedControlsReadOnlyPreflightPlan(
            controls: controls,
            featureIndex: plan.featureIndex,
            featureVersion: plan.featureVersion,
            authorization: .notAuthorizedForExecution
        )
    }

    public func preflight(
        for controlID: UInt16
    ) throws -> MappedControlReadOnlyPreflight {
        guard let preflight = controls.first(where: { $0.controlID == controlID }) else {
            throw MappedControlReadOnlyPreflightError.unexpectedMappedControl(
                controlID
            )
        }
        return preflight
    }
}

public struct MappedControlReadOnlyPreflightObservation: Sendable, Equatable {
    public let controlID: UInt16
    public let requestBytes: [UInt8]
    public let responseBytes: [UInt8]
    public let state: DeviceTransactionWireState
}

/// Fail-closed GET sequence for the five mapped CIDs. It never produces a SET
/// and never retries. Completing the sequence is not SET authorization.
public struct MappedControlReadOnlyPreflightSequence: Sendable, Equatable {
    public let plan: MappedControlsReadOnlyPreflightPlan
    public private(set) var observations: [MappedControlReadOnlyPreflightObservation]
    public private(set) var failedControlID: UInt16?

    public init(plan: MappedControlsReadOnlyPreflightPlan) {
        self.plan = plan
        observations = []
        failedControlID = nil
    }

    public var isComplete: Bool {
        failedControlID == nil && observations.count == plan.controls.count
    }

    public var currentControlID: UInt16? {
        if let failedControlID { return failedControlID }
        if observations.count < plan.controls.count {
            return plan.controls[observations.count].controlID
        }
        return observations.last?.controlID
    }

    public var authorization: MappedControlReadOnlyPreflightAuthorization {
        .notAuthorizedForExecution
    }

    public func nextRequest() throws -> HIDPP20LongMessage {
        guard failedControlID == nil else {
            throw MappedControlReadOnlyPreflightError.sequenceAlreadyFailed
        }
        guard observations.count < plan.controls.count else {
            throw MappedControlReadOnlyPreflightError.sequenceAlreadyComplete
        }
        let request = plan.controls[observations.count].verificationRequest
        guard request.functionID == 2 else {
            throw MappedControlReadOnlyPreflightError.verificationRequestMismatch(
                plan.controls[observations.count].controlID
            )
        }
        return request
    }

    public mutating func observe(
        _ response: HIDPP20LongMessage
    ) throws -> MappedControlReadOnlyPreflightObservation {
        let request = try nextRequest()
        let control = plan.controls[observations.count]
        do {
            let state = try control.evaluateResponse(
                response,
                featureIndex: plan.featureIndex,
                featureVersion: plan.featureVersion
            )
            let observation = MappedControlReadOnlyPreflightObservation(
                controlID: control.controlID,
                requestBytes: request.bytes,
                responseBytes: response.bytes,
                state: state
            )
            observations.append(observation)
            return observation
        } catch {
            failedControlID = control.controlID
            throw error
        }
    }
}
