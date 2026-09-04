import Foundation
@preconcurrency import IOKit.hid
import MXErgoHIDPP
import MXErgoPrecisionIOHIDInput
import MXErgoPrecisionIOHIDOutput
import MXErgoPrecisionIOHIDOwnership
import MXErgoPrecisionTransport
import MXErgoPrecisionWriteLifecycle

/// The assembly target's sole package construction door. A future productless
/// acquisition owner supplies the same directly opened device plus the anchor
/// that must close it after both endpoint barriers complete.
package enum PrecisionIOHIDAssemblyFactory {
    package static func make(
        exclusivelyOpenedDevice device: IOHIDDevice,
        quiescentReleaseAnchor: any PrecisionIOHIDQuiescentReleaseAnchor,
        plan: PrecisionTemporaryDiversionPlan,
        binding: PrecisionTransportBinding
    ) throws -> any PrecisionIOHIDAssembledEndpoint {
        try PrecisionIOHIDDeviceAssembly(
            exclusivelyOpenedDevice: device,
            quiescentReleaseAnchor: quiescentReleaseAnchor,
            plan: plan,
            binding: binding
        )
    }
}

/// Productless composition root for one already-open, exclusively transferred
/// HID device. Construction performs identity/capability inspection only. It
/// does not discover, open, close, activate, write, or register callbacks.
/// Every operation and lifecycle transition delegates to the existing input,
/// output, and pure ownership targets; this type adds no state machine.
final class PrecisionIOHIDDeviceAssembly:
    PrecisionIOHIDAssembledEndpoint,
    PrecisionTransportReportReader,
    PrecisionTransportDrainingReportWriter,
    @unchecked Sendable {
    typealias InputFactory<Handle: AnyObject> = (Handle) throws ->
        any PrecisionIOHIDInputLifetime
    typealias OutputFactory<Handle: AnyObject> = (Handle) throws ->
        any PrecisionTransportDrainingReportWriter
    typealias ReleaseAnchorFactory<Handle: AnyObject> = (Handle) ->
        any PrecisionIOHIDQuiescentReleaseAnchor

    private let endpoint: any PrecisionIOHIDAssembledEndpoint

    init(
        exclusivelyTransferredDevice device: IOHIDDevice,
        plan: PrecisionTemporaryDiversionPlan,
        binding: PrecisionTransportBinding
    ) throws {
        endpoint = try Self.assemble(
            retaining: device,
            makeInput: { device in
                try PrecisionIOHIDInputFactory.make(
                    exclusivelyOwnedDevice: device,
                    binding: binding
                )
            },
            makeOutput: { device in
                try PrecisionIOHIDOutputFactory.make(
                    exclusivelyOwnedDevice: device,
                    plan: plan,
                    binding: binding
                )
            },
            makeReleaseAnchor: {
                PrecisionIOHIDRetainedHandleReleaseAnchor(retaining: $0)
            }
        )
    }

    fileprivate init(
        exclusivelyOpenedDevice device: IOHIDDevice,
        quiescentReleaseAnchor: any PrecisionIOHIDQuiescentReleaseAnchor,
        plan: PrecisionTemporaryDiversionPlan,
        binding: PrecisionTransportBinding
    ) throws {
        endpoint = try Self.assemble(
            retaining: device,
            makeInput: { device in
                try PrecisionIOHIDInputFactory.make(
                    exclusivelyOwnedDevice: device,
                    binding: binding
                )
            },
            makeOutput: { device in
                try PrecisionIOHIDOutputFactory.make(
                    exclusivelyOwnedDevice: device,
                    plan: plan,
                    binding: binding
                )
            },
            makeReleaseAnchor: { _ in quiescentReleaseAnchor }
        )
    }

    /// Internal deterministic seam for this productless target's tests. The
    /// real initializer above uses this same generic path, so both factories
    /// receive the exact same reference-identity handle.
    init<Handle: AnyObject>(
        testingTransferredHandle handle: Handle,
        makeInput: InputFactory<Handle>,
        makeOutput: OutputFactory<Handle>
    ) throws {
        endpoint = try Self.assemble(
            retaining: handle,
            makeInput: makeInput,
            makeOutput: makeOutput,
            makeReleaseAnchor: {
                PrecisionIOHIDRetainedHandleReleaseAnchor(retaining: $0)
            }
        )
    }

    /// Test seam for a future direct-open owner. The release capability is
    /// created only after both endpoint constructors succeed, then enters the
    /// same fail-closed quarantine as the endpoint bundle.
    init<Handle: AnyObject>(
        testingTransferredHandle handle: Handle,
        makeInput: InputFactory<Handle>,
        makeOutput: OutputFactory<Handle>,
        makeQuiescentReleaseAnchor: ReleaseAnchorFactory<Handle>
    ) throws {
        endpoint = try Self.assemble(
            retaining: handle,
            makeInput: makeInput,
            makeOutput: makeOutput,
            makeReleaseAnchor: makeQuiescentReleaseAnchor
        )
    }

    func start() async throws {
        try await endpoint.start()
    }

    func write(_ frame: PrecisionTransportOutputFrame) async throws -> Int32 {
        try await endpoint.write(frame)
    }

    func cancelPendingWrite(
        requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        endpoint.cancelPendingWrite(requestID: requestID, reason: reason)
    }

    func shutdownAndDrain() async {
        await endpoint.shutdownAndDrain()
    }

    func beginRequest(_ frame: PrecisionTransportOutputFrame) throws {
        try endpoint.beginRequest(frame)
    }

    func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame {
        try await endpoint.read(for: requestID)
    }

    func endRequest(_ requestID: UUID) {
        endpoint.endRequest(requestID)
    }

    func cancelRequest(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        endpoint.cancelRequest(requestID, reason: reason)
    }

    func disconnected() {
        endpoint.disconnected()
    }

    func setUnsolicitedHIDPPHandler(
        _ handler: (@Sendable (PrecisionTransportInputFrame) -> Void)?
    ) {
        endpoint.setUnsolicitedHIDPPHandler(handler)
    }

    package func inputDiagnostics() -> PrecisionInputDiagnostics? {
        endpoint.inputDiagnostics()
    }

    func setDisconnectHandler(_ handler: (@Sendable () -> Void)?) {
        endpoint.setDisconnectHandler(handler)
    }

    private static func assemble<Handle: AnyObject>(
        retaining handle: Handle,
        makeInput: InputFactory<Handle>,
        makeOutput: OutputFactory<Handle>,
        makeReleaseAnchor: ReleaseAnchorFactory<Handle>
    ) throws -> any PrecisionIOHIDAssembledEndpoint {
        let input = try makeInput(handle)
        let output: any PrecisionTransportDrainingReportWriter
        do {
            output = try makeOutput(handle)
        } catch {
            // The input endpoint is still initialized and inactive, so this is
            // synchronous and cannot wait on a callback cancellation barrier.
            input.shutdownAndWait()
            throw error
        }
        // Token creation and atomic full-bundle quarantine happen only after
        // both fallible endpoint constructors have succeeded.
        let releaseAnchor = makeReleaseAnchor(handle)
        return PrecisionIOHIDOwnershipFactory.make(
            quiescentReleaseAnchor: releaseAnchor,
            input: input,
            output: output
        )
    }
}

/// Default release capability for an externally transferred reference. A
/// future direct-open owner can replace this with a close-owning anchor without
/// widening the assembly or ownership coordinator surfaces.
private final class PrecisionIOHIDRetainedHandleReleaseAnchor:
    PrecisionIOHIDQuiescentReleaseAnchor,
    @unchecked Sendable {
    private let lock = NSLock()
    private var retainedHandle: AnyObject?

    init(retaining handle: AnyObject) {
        retainedHandle = handle
    }

    func releaseAfterEndpointQuiescence() {
        lock.withLock { retainedHandle = nil }
    }
}
