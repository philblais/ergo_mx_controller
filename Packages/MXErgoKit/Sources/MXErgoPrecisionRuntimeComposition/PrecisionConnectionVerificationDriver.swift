import Foundation
import MXErgoHIDPP
import MXErgoPrecisionIOHIDAcquisition
import MXErgoPrecisionTransport

enum PrecisionConnectionVerificationDriverError: Error, Sendable, Equatable {
    case invalidDeadline
    case invalidSource
    case outputFailed(Int32)
    case competitorsPresent
    case incomplete
}

/// Drives one read-only verification on the exact acquired endpoint. The
/// caller retains the operation lease and must drain/close on every failure.
enum PrecisionConnectionVerificationDriver {
    static func verify(
        endpoint: any PrecisionIOHIDAcquiredEndpoint,
        binding: PrecisionTransportBinding,
        competitorProbe: @escaping @Sendable () throws -> [String],
        requestTimeoutNanoseconds: UInt64,
        totalTimeoutNanoseconds: UInt64 = 30_000_000_000
    ) async throws -> PrecisionConnectionVerificationObservation {
        guard requestTimeoutNanoseconds > 0, totalTimeoutNanoseconds > 0,
              requestTimeoutNanoseconds <= 30_000_000_000,
              totalTimeoutNanoseconds <= 30_000_000_000 else {
            throw PrecisionConnectionVerificationDriverError.invalidDeadline
        }
        var sequence = try PrecisionReadOnlyConnectionVerification(expectedSession: binding.session)
        let totalDeadline = DispatchTime.now().uptimeNanoseconds + totalTimeoutNanoseconds
        while sequence.observation == nil {
            try validate(endpoint, competitorProbe)
            let request = try sequence.beginOutputRequest()
            let frame = PrecisionTransportOutputFrame(
                requestID: request.requestID, reportType: .output,
                reportID: HIDPP20LongMessage.reportID, bytes: request.message.bytes,
                device: binding.session.device, connectionEpoch: binding.session.connectionEpoch,
                rootGeneration: binding.rootGeneration, connectionVerification: request
            )
            let deadline = min(totalDeadline,
                DispatchTime.now().uptimeNanoseconds + requestTimeoutNanoseconds)
            let cancel: @Sendable (PrecisionTransportReportIOError) -> Void = { reason in
                endpoint.cancelPendingWrite(requestID: frame.requestID, reason: reason)
                endpoint.cancelRequest(frame.requestID, reason: reason)
            }
            do {
                try endpoint.beginRequest(frame)
                let code = try await bounded(deadline: deadline, cancel: cancel) {
                    try await endpoint.write(frame)
                }
                try validate(endpoint, competitorProbe)
                guard code == 0 else { throw PrecisionConnectionVerificationDriverError.outputFailed(code) }
                while true {
                    let input = try await bounded(deadline: deadline, cancel: cancel) {
                        try await endpoint.read(for: frame.requestID)
                    }
                    try validate(endpoint, competitorProbe)
                    guard input.reportType == .input,
                          input.reportID == HIDPP20LongMessage.reportID,
                          input.device == binding.session.device,
                          input.connectionEpoch == binding.session.connectionEpoch,
                          input.rootGeneration == binding.rootGeneration else {
                        throw PrecisionConnectionVerificationDriverError.invalidSource
                    }
                    if try sequence.observe(bytes: input.bytes) { break }
                }
                endpoint.endRequest(frame.requestID)
            } catch {
                sequence.abort()
                cancel((error as? PrecisionTransportReportIOError) ?? .cancelled)
                endpoint.endRequest(frame.requestID)
                throw error
            }
        }
        try validate(endpoint, competitorProbe)
        guard DispatchTime.now().uptimeNanoseconds < totalDeadline else {
            throw PrecisionTransportReportIOError.timeout
        }
        guard let observation = sequence.observation else {
            throw PrecisionConnectionVerificationDriverError.incomplete
        }
        return observation
    }

    private static func validate(
        _ endpoint: any PrecisionIOHIDAcquiredEndpoint,
        _ competitorProbe: @Sendable () throws -> [String]
    ) throws {
        try Task.checkCancellation()
        try endpoint.validateActiveConnection()
        guard try competitorProbe().allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw PrecisionConnectionVerificationDriverError.competitorsPresent
        }
        try endpoint.validateActiveConnection()
        try Task.checkCancellation()
    }

    private static func bounded<Value: Sendable>(
        deadline: UInt64,
        cancel: @escaping @Sendable (PrecisionTransportReportIOError) -> Void,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { cancel(.timeout); throw PrecisionTransportReportIOError.timeout }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Value.self) { group in
                defer { group.cancelAll() }
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(nanoseconds: deadline - now)
                    cancel(.timeout)
                    throw PrecisionTransportReportIOError.timeout
                }
                guard let value = try await group.next() else { throw PrecisionTransportReportIOError.cancelled }
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    cancel(.timeout)
                    throw PrecisionTransportReportIOError.timeout
                }
                try Task.checkCancellation()
                return value
            }
        } onCancel: { cancel(.cancelled) }
    }
}
