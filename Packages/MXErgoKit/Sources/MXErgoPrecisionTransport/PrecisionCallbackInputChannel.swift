import Foundation
import MXErgoHIDPP

package enum PrecisionCallbackChannelError: Error, Sendable, Equatable {
    case requestAlreadyActive
    case requestNotActive
    case concurrentRead
    case invalidRequest
}

/// A no-IOKit, request-scoped model for a future callback bridge.
///
/// Callback bytes are copied synchronously. One armed request accepts a
/// bounded FIFO of distinct candidate frames until the adapter's correlator
/// finds the matching reply. Cancellation is token-specific and sticky, so a
/// cancellation that wins before waiter installation is observed by the later
/// read instead of being lost.
package final class PrecisionCallbackInputChannel:
    PrecisionTransportReportReader,
    @unchecked Sendable {
    private struct Window {
        let requestID: UUID
        var frames: [PrecisionTransportInputFrame] = []
        var seenBytes: Set<[UInt8]> = []
        var acceptedCandidateCount = 0
        var continuation:
            CheckedContinuation<PrecisionTransportInputFrame, any Error>?
    }

    private let queue = DispatchQueue(
        label: "com.phib.MXErgoController.precision-callback-window"
    )
    private let expectedDevice: JournalDeviceIdentity
    private let expectedConnectionEpoch: UInt64
    private let expectedRootGeneration: UInt64
    private let capacity: Int
    private let candidateLimit: Int
    private var window: Window?
    private var closedReasons: [UUID: PrecisionTransportReportIOError] = [:]
    private var closedOrder: [UUID] = []
    private var removed = false
    private var stopped = false
    private var acceptedCountStorage = 0
    private var droppedCountStorage = 0
    private var resumeCountStorage = 0
    private var finishCountStorage = 0
    private var cancelCountStorage = 0
    private var unsolicitedHandler:
        (@Sendable (PrecisionTransportInputFrame) -> Void)?
    private var unsolicitedCountStorage = 0
    /// Frames that passed identity, epoch, report-type and length checks,
    /// counted before the unsolicited-notification test. The gap between
    /// this and `unsolicitedCount` is what distinguishes "the device sent
    /// nothing" from "the device sent something we refused to route".
    private var observedCountStorage = 0
    private var lastObservedBytesStorage: [UInt8]?
    /// The last routed notification carrying a non-zero payload. A release
    /// notification has all-zero parameters, so without this the last frame
    /// captured is almost always a release and says nothing about which
    /// control was pressed.
    private var lastPayloadNotificationBytesStorage: [UInt8]?

    package init(
        expectedDevice: JournalDeviceIdentity,
        expectedConnectionEpoch: UInt64,
        expectedRootGeneration: UInt64,
        capacity: Int = 8,
        candidateLimit: Int = 32
    ) {
        precondition(capacity > 0)
        precondition(candidateLimit >= capacity)
        self.expectedDevice = expectedDevice
        self.expectedConnectionEpoch = expectedConnectionEpoch
        self.expectedRootGeneration = expectedRootGeneration
        self.capacity = capacity
        self.candidateLimit = candidateLimit
    }

    package func beginRequest(_ frame: PrecisionTransportOutputFrame) throws {
        try queue.sync {
            guard !stopped else {
                throw PrecisionTransportReportIOError.cancelled
            }
            guard !removed else {
                throw PrecisionTransportReportIOError.disconnected
            }
            guard window == nil else {
                throw PrecisionCallbackChannelError.requestAlreadyActive
            }
            if let reason = closedReasons[frame.requestID] {
                throw reason
            }
            guard frame.reportType == .output,
                  frame.reportID == HIDPP20LongMessage.reportID,
                  frame.bytes.count == HIDPP20LongMessage.byteCount,
                  frame.bytes.first == HIDPP20LongMessage.reportID,
                  frame.device == expectedDevice,
                  frame.connectionEpoch == expectedConnectionEpoch,
                  frame.rootGeneration == expectedRootGeneration else {
                throw PrecisionCallbackChannelError.invalidRequest
            }
            window = Window(requestID: frame.requestID)
        }
    }

    /// Must be called synchronously while the callback-owned memory is valid.
    @discardableResult
    package func receiveCallback(
        reportType: PrecisionTransportReportType,
        reportID: UInt8,
        bytes: UnsafeRawBufferPointer,
        device: JournalDeviceIdentity,
        connectionEpoch: UInt64,
        rootGeneration: UInt64
    ) -> Bool {
        let copiedBytes = Array(bytes)
        guard reportType == .input,
              reportID == HIDPP20LongMessage.reportID,
              copiedBytes.count == HIDPP20LongMessage.byteCount,
              copiedBytes.first == HIDPP20LongMessage.reportID,
              device == expectedDevice,
              connectionEpoch == expectedConnectionEpoch,
              rootGeneration == expectedRootGeneration else {
            queue.sync { droppedCountStorage += 1 }
            return false
        }

        // Record every accepted-shape frame before deciding what it is. This is
        // diagnostic only: it drives no routing and gates nothing.
        queue.sync {
            observedCountStorage += 1
            lastObservedBytesStorage = copiedBytes
        }

        let frame = PrecisionTransportInputFrame(
            reportType: reportType,
            reportID: reportID,
            bytes: copiedBytes,
            device: device,
            connectionEpoch: connectionEpoch,
            rootGeneration: rootGeneration
        )
        if copiedBytes.count >= 2, copiedBytes[1] == 0xFF {
            let handler = queue.sync { () -> (@Sendable (PrecisionTransportInputFrame) -> Void)? in
                guard !stopped, !removed else { return nil }
                unsolicitedCountStorage += 1
                if copiedBytes.dropFirst(4).contains(where: { $0 != 0 }) {
                    lastPayloadNotificationBytesStorage = copiedBytes
                }
                return unsolicitedHandler
            }
            handler?(frame)
        }
        var continuation:
            CheckedContinuation<PrecisionTransportInputFrame, any Error>?
        var terminalContinuation:
            CheckedContinuation<PrecisionTransportInputFrame, any Error>?
        let accepted = queue.sync {
            guard !stopped, !removed, var active = window else {
                droppedCountStorage += 1
                return false
            }
            guard active.seenBytes.insert(copiedBytes).inserted else {
                droppedCountStorage += 1
                return false
            }
            guard active.acceptedCandidateCount < candidateLimit else {
                terminalContinuation = active.continuation
                rememberClosed(
                    requestID: active.requestID,
                    reason: .overflow
                )
                window = nil
                droppedCountStorage += 1
                if terminalContinuation != nil { resumeCountStorage += 1 }
                return false
            }
            active.acceptedCandidateCount += 1
            if let pending = active.continuation {
                active.continuation = nil
                continuation = pending
                window = active
                acceptedCountStorage += 1
                resumeCountStorage += 1
                return true
            }
            guard active.frames.count < capacity else {
                terminalContinuation = active.continuation
                rememberClosed(
                    requestID: active.requestID,
                    reason: .overflow
                )
                window = nil
                droppedCountStorage += 1
                if terminalContinuation != nil { resumeCountStorage += 1 }
                return false
            }
            active.frames.append(frame)
            window = active
            acceptedCountStorage += 1
            return true
        }
        continuation?.resume(returning: frame)
        terminalContinuation?.resume(
            throwing: PrecisionTransportReportIOError.overflow
        )
        return accepted
    }

    package func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame {
        try await withCheckedThrowingContinuation { continuation in
            var immediate: Result<PrecisionTransportInputFrame, any Error>?
            queue.sync {
                if let reason = closedReasons.removeValue(forKey: requestID) {
                    closedOrder.removeAll { $0 == requestID }
                    immediate = .failure(reason)
                    resumeCountStorage += 1
                    return
                }
                guard !stopped else {
                    immediate = .failure(PrecisionTransportReportIOError.cancelled)
                    resumeCountStorage += 1
                    return
                }
                guard !removed else {
                    immediate = .failure(PrecisionTransportReportIOError.disconnected)
                    resumeCountStorage += 1
                    return
                }
                guard var active = window,
                      active.requestID == requestID else {
                    immediate = .failure(
                        PrecisionCallbackChannelError.requestNotActive
                    )
                    resumeCountStorage += 1
                    return
                }
                if !active.frames.isEmpty {
                    immediate = .success(active.frames.removeFirst())
                    window = active
                    resumeCountStorage += 1
                } else if active.continuation != nil {
                    immediate = .failure(
                        PrecisionCallbackChannelError.concurrentRead
                    )
                    resumeCountStorage += 1
                } else {
                    active.continuation = continuation
                    window = active
                }
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    package func endRequest(_ requestID: UUID) {
        closeRequest(requestID, reason: nil)
    }

    package func cancelRequest(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        closeRequest(requestID, reason: reason)
    }

    package func disconnected() {
        var continuation:
            CheckedContinuation<PrecisionTransportInputFrame, any Error>?
        queue.sync {
            guard !removed else { return }
            removed = true
            if let active = window {
                continuation = active.continuation
                rememberClosed(requestID: active.requestID, reason: .disconnected)
                window = nil
                cancelCountStorage += 1
                if continuation != nil { resumeCountStorage += 1 }
            }
        }
        continuation?.resume(throwing: PrecisionTransportReportIOError.disconnected)
    }

    package func setUnsolicitedHIDPPHandler(
        _ handler: (@Sendable (PrecisionTransportInputFrame) -> Void)?
    ) {
        queue.sync { unsolicitedHandler = handler }
    }

    package func shutdown() {
        var continuation:
            CheckedContinuation<PrecisionTransportInputFrame, any Error>?
        queue.sync {
            guard !stopped else { return }
            stopped = true
            unsolicitedHandler = nil
            if let active = window {
                continuation = active.continuation
                rememberClosed(requestID: active.requestID, reason: .cancelled)
                window = nil
                cancelCountStorage += 1
                if continuation != nil { resumeCountStorage += 1 }
            }
        }
        continuation?.resume(throwing: PrecisionTransportReportIOError.cancelled)
    }

    package var acceptedCount: Int { queue.sync { acceptedCountStorage } }
    package var droppedCount: Int { queue.sync { droppedCountStorage } }
    package var unsolicitedCount: Int { queue.sync { unsolicitedCountStorage } }
    package var observedCount: Int { queue.sync { observedCountStorage } }
    package var inputDiagnostics: PrecisionInputDiagnostics {
        queue.sync {
            PrecisionInputDiagnostics(
                observedCount: observedCountStorage,
                unsolicitedCount: unsolicitedCountStorage,
                acceptedCount: acceptedCountStorage,
                droppedCount: droppedCountStorage,
                lastObservedFrameBytes: lastObservedBytesStorage,
                lastPayloadNotificationBytes: lastPayloadNotificationBytesStorage
            )
        }
    }
    package var lastObservedFrameBytes: [UInt8]? {
        queue.sync { lastObservedBytesStorage }
    }
    package var resumeCount: Int { queue.sync { resumeCountStorage } }
    package var finishCount: Int { queue.sync { finishCountStorage } }
    package var cancelCount: Int { queue.sync { cancelCountStorage } }
    package var hasPendingRead: Bool { queue.sync { window?.continuation != nil } }
    package var hasActiveRequest: Bool { queue.sync { window != nil } }

    private func closeRequest(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError?
    ) {
        var continuation:
            CheckedContinuation<PrecisionTransportInputFrame, any Error>?
        queue.sync {
            guard let active = window, active.requestID == requestID else {
                if let reason { rememberClosed(requestID: requestID, reason: reason) }
                return
            }
            continuation = active.continuation
            window = nil
            if let reason {
                rememberClosed(requestID: requestID, reason: reason)
                cancelCountStorage += 1
            } else {
                finishCountStorage += 1
            }
            if continuation != nil { resumeCountStorage += 1 }
        }
        if let continuation {
            continuation.resume(
                throwing: reason ?? PrecisionTransportReportIOError.cancelled
            )
        }
    }

    /// Called only while `queue` is held.
    private func rememberClosed(
        requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        guard closedReasons[requestID] == nil else { return }
        closedOrder.append(requestID)
        closedReasons[requestID] = reason
        while closedOrder.count > 16 {
            closedReasons.removeValue(forKey: closedOrder.removeFirst())
        }
    }
}
