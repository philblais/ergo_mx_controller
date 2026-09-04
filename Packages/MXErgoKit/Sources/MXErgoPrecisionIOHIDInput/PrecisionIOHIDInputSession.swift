import Foundation
import MXErgoHIDPP
import MXErgoPrecisionIOHIDOwnership
import MXErgoPrecisionTransport

enum PrecisionIOHIDInputError: Error, Sendable, Equatable {
    case invalidDeviceIdentity
    case invalidInputReportBufferLength
    case alreadyConfigured
    case notConfigured
    case notActive
    case permanentlyStopped
}

protocol PrecisionIOHIDInputEventSink: AnyObject, Sendable {
    /// The report memory is owned by IOHID and is valid only for this call.
    func ioHIDInputReport(
        result: Int32,
        senderMatchesDevice: Bool,
        isInputReport: Bool,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>?,
        reportLength: Int
    )

    func ioHIDDeviceRemoved(
        result: Int32,
        senderMatchesDevice: Bool
    )

    func ioHIDCallbacksCancelled()
}

protocol PrecisionIOHIDInputRuntime: AnyObject, Sendable {
    var inputReportBufferByteCount: Int { get }

    /// Registers every callback and the cancel handler, but does not activate.
    func configure(
        queue: DispatchQueue,
        reportBuffer: UnsafeMutablePointer<UInt8>,
        reportBufferLength: Int,
        sink: any PrecisionIOHIDInputEventSink
    ) throws

    func activate() throws
    func cancel()
}

/// Input-only owner for one exclusively transferred IOHIDDevice.
///
/// The session performs no discovery, open, activation, or I/O in `init`.
/// `start()` registers callbacks before one-shot activation. Shutdown does not
/// return until the IOHID cancel handler proves that callbacks are quiescent.
/// No output-report API exists in this target.
final class PrecisionIOHIDInputSession:
    PrecisionIOHIDInputLifetime,
    PrecisionTransportReportReader,
    PrecisionIOHIDInputEventSink,
    @unchecked Sendable {
    typealias DisconnectHandler = @Sendable () -> Void

    private enum LifecycleState: Sendable, Equatable {
        case initialized
        case starting
        case active
        case cancelling
        case stopped
    }

    private let binding: PrecisionTransportBinding
    private let runtime: any PrecisionIOHIDInputRuntime
    private let callbackChannel: PrecisionCallbackInputChannel
    private let callbackQueue = DispatchQueue(
        label: "com.phib.MXErgoController.precision-iohid-input"
    )
    private let lifecycleOperationLock = NSLock()
    private let lifecycleCondition = NSCondition()
    private let disconnectHandler: DisconnectHandler
    private let reportBuffer: UnsafeMutablePointer<UInt8>
    private let reportBufferByteCount: Int
    private var lifecycleState: LifecycleState = .initialized
    private var disconnectDelivered = false
    private var extraDisconnectHandler: DisconnectHandler?
    private var rejectedCallbackCountStorage = 0

    init(
        binding: PrecisionTransportBinding,
        runtime: any PrecisionIOHIDInputRuntime,
        queueCapacity: Int = 8,
        totalCandidateLimit: Int = 32,
        disconnectHandler: @escaping DisconnectHandler = {}
    ) throws {
        let byteCount = runtime.inputReportBufferByteCount
        guard binding.session.device.vendorID == 0x046D,
              binding.session.device.productID == 0xB01D,
              binding.session.device.transport == "Bluetooth Low Energy",
              binding.session.device.hasStableDiscriminator,
              binding.session.device.firmwareIdentity?.isEmpty == false else {
            throw PrecisionIOHIDInputError.invalidDeviceIdentity
        }
        guard byteCount >= HIDPP20LongMessage.byteCount,
              byteCount <= 4_096 else {
            throw PrecisionIOHIDInputError.invalidInputReportBufferLength
        }
        self.binding = binding
        self.runtime = runtime
        self.disconnectHandler = disconnectHandler
        reportBufferByteCount = byteCount
        reportBuffer = .allocate(capacity: byteCount)
        reportBuffer.initialize(repeating: 0, count: byteCount)
        callbackChannel = PrecisionCallbackInputChannel(
            expectedDevice: binding.session.device,
            expectedConnectionEpoch: binding.session.connectionEpoch,
            expectedRootGeneration: binding.rootGeneration,
            capacity: queueCapacity,
            candidateLimit: totalCandidateLimit
        )
    }

    deinit {
        reportBuffer.deinitialize(count: reportBufferByteCount)
        reportBuffer.deallocate()
    }

    func start() throws {
        lifecycleOperationLock.lock()
        defer { lifecycleOperationLock.unlock() }

        lifecycleCondition.lock()
        switch lifecycleState {
        case .active:
            lifecycleCondition.unlock()
            return
        case .initialized:
            lifecycleState = .starting
        case .starting, .cancelling:
            lifecycleCondition.unlock()
            throw PrecisionIOHIDInputError.notActive
        case .stopped:
            lifecycleCondition.unlock()
            throw PrecisionIOHIDInputError.permanentlyStopped
        }
        lifecycleCondition.unlock()

        var didConfigureRuntime = false
        do {
            try runtime.configure(
                queue: callbackQueue,
                reportBuffer: reportBuffer,
                reportBufferLength: reportBufferByteCount,
                sink: self
            )
            didConfigureRuntime = true
            lifecycleCondition.lock()
            lifecycleState = .active
            lifecycleCondition.unlock()
            try runtime.activate()
        } catch {
            lifecycleCondition.lock()
            if didConfigureRuntime {
                // Registration may already have transferred callback lifetime
                // to IOHID. Only its cancel handler can prove quiescence.
                lifecycleState = .cancelling
            } else {
                lifecycleState = .stopped
                lifecycleCondition.broadcast()
            }
            lifecycleCondition.unlock()
            callbackChannel.shutdown()
            runtime.cancel()
            throw error
        }
    }

    /// Blocks the caller until the runtime's cancel handler has run.
    func shutdownAndWait() {
        lifecycleOperationLock.lock()
        var shouldCancel = false
        lifecycleCondition.lock()
        switch lifecycleState {
        case .initialized:
            lifecycleState = .stopped
            lifecycleCondition.broadcast()
        case .starting, .active:
            lifecycleState = .cancelling
            shouldCancel = true
        case .cancelling, .stopped:
            break
        }
        let alreadyStopped = lifecycleState == .stopped
        lifecycleCondition.unlock()
        callbackChannel.shutdown()
        if shouldCancel { runtime.cancel() }
        lifecycleOperationLock.unlock()

        guard !alreadyStopped else { return }
        lifecycleCondition.lock()
        while lifecycleState != .stopped {
            lifecycleCondition.wait()
        }
        lifecycleCondition.unlock()
    }

    func beginRequest(_ frame: PrecisionTransportOutputFrame) throws {
        try requireActive()
        try callbackChannel.beginRequest(frame)
    }

    func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame {
        try await callbackChannel.read(for: requestID)
    }

    func endRequest(_ requestID: UUID) {
        callbackChannel.endRequest(requestID)
    }

    func cancelRequest(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        callbackChannel.cancelRequest(requestID, reason: reason)
    }

    func disconnected() {
        transitionToDisconnected()
    }

    func setUnsolicitedHIDPPHandler(
        _ handler: (@Sendable (PrecisionTransportInputFrame) -> Void)?
    ) {
        callbackChannel.setUnsolicitedHIDPPHandler(handler)
    }

    func setDisconnectHandler(_ handler: (@Sendable () -> Void)?) {
        lifecycleCondition.lock()
        extraDisconnectHandler = handler
        lifecycleCondition.unlock()
    }

    func ioHIDInputReport(
        result: Int32,
        senderMatchesDevice: Bool,
        isInputReport: Bool,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>?,
        reportLength: Int
    ) {
        lifecycleCondition.lock()
        let isActive = lifecycleState == .active
        lifecycleCondition.unlock()
        guard isActive,
              result == 0,
              senderMatchesDevice,
              isInputReport,
              reportID == UInt32(HIDPP20LongMessage.reportID),
              reportLength == HIDPP20LongMessage.byteCount,
              let report else {
            recordRejectedCallback()
            return
        }
        let bytes = UnsafeRawBufferPointer(
            start: UnsafeRawPointer(report),
            count: reportLength
        )
        let accepted = callbackChannel.receiveCallback(
            reportType: .input,
            reportID: HIDPP20LongMessage.reportID,
            bytes: bytes,
            device: binding.session.device,
            connectionEpoch: binding.session.connectionEpoch,
            rootGeneration: binding.rootGeneration
        )
        if !accepted { recordRejectedCallback() }
    }

    func ioHIDDeviceRemoved(
        result: Int32,
        senderMatchesDevice: Bool
    ) {
        _ = result
        guard senderMatchesDevice else {
            recordRejectedCallback()
            return
        }
        transitionToDisconnected()
    }

    func ioHIDCallbacksCancelled() {
        callbackChannel.shutdown()
        lifecycleCondition.lock()
        lifecycleState = .stopped
        lifecycleCondition.broadcast()
        lifecycleCondition.unlock()
    }

    var acceptedCallbackCount: Int { callbackChannel.acceptedCount }
    var rejectedCallbackCount: Int {
        lifecycleCondition.lock()
        defer { lifecycleCondition.unlock() }
        return rejectedCallbackCountStorage
    }
    var isActive: Bool {
        lifecycleCondition.lock()
        defer { lifecycleCondition.unlock() }
        return lifecycleState == .active
    }
    var isStopped: Bool {
        lifecycleCondition.lock()
        defer { lifecycleCondition.unlock() }
        return lifecycleState == .stopped
    }

    private func requireActive() throws {
        lifecycleCondition.lock()
        defer { lifecycleCondition.unlock() }
        guard lifecycleState == .active else {
            if lifecycleState == .stopped {
                throw PrecisionIOHIDInputError.permanentlyStopped
            }
            throw PrecisionIOHIDInputError.notActive
        }
    }

    private func transitionToDisconnected() {
        var shouldCancel = false
        var shouldNotify = false
        lifecycleCondition.lock()
        switch lifecycleState {
        case .starting, .active:
            lifecycleState = .cancelling
            shouldCancel = true
        case .initialized:
            lifecycleState = .stopped
            lifecycleCondition.broadcast()
        case .cancelling, .stopped:
            break
        }
        if !disconnectDelivered {
            disconnectDelivered = true
            shouldNotify = true
        }
        let extraHandler = extraDisconnectHandler
        lifecycleCondition.unlock()
        callbackChannel.disconnected()
        if shouldNotify {
            disconnectHandler()
            extraHandler?()
        }
        if shouldCancel { runtime.cancel() }
    }

    private func recordRejectedCallback() {
        lifecycleCondition.lock()
        rejectedCallbackCountStorage += 1
        lifecycleCondition.unlock()
    }
}
