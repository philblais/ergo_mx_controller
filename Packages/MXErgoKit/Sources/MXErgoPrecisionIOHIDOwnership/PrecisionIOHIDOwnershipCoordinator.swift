import Foundation
import MXErgoPrecisionTransport
import MXErgoPrecisionWriteLifecycle

enum PrecisionIOHIDOwnershipError: Error, Sendable, Equatable {
    case deviceOwnershipMismatch
    case ownershipTokenAlreadyBound
    case alreadyStarted
    case notStarted
    case shuttingDown
    case permanentlyStopped
}

/// Runtime-shaped ownership identity for one future transferred HID device.
/// This pure target deliberately cannot create or expose a physical handle.
/// The retained anchor models the handle's lifetime and is released explicitly
/// only after output drain and input callback quiescence complete.
final class PrecisionIOHIDOwnershipToken: @unchecked Sendable {
    let identity: UUID
    private let lock = NSLock()
    private let retainedAnchorCapsule: PrecisionIOHIDRetainedAnchorCapsule
    private var released = false
    private var releaseCountStorage = 0
    private let releaseHook: @Sendable () -> Void

    init(
        identity: UUID = UUID(),
        retainedAnchor: AnyObject,
        releaseHook: @escaping @Sendable () -> Void = {}
    ) {
        self.identity = identity
        let capsule = PrecisionIOHIDRetainedAnchorCapsule(
            releaseAnchor: PrecisionIOHIDOpaqueReleaseAnchor(
                retaining: retainedAnchor
            )
        )
        retainedAnchorCapsule = capsule
        self.releaseHook = releaseHook
        PrecisionIOHIDRetainedAnchorQuarantine.shared.retain(capsule)
    }

    fileprivate init(
        identity: UUID = UUID(),
        quiescentReleaseAnchor: any PrecisionIOHIDQuiescentReleaseAnchor,
        releaseHook: @escaping @Sendable () -> Void = {}
    ) {
        self.identity = identity
        let capsule = PrecisionIOHIDRetainedAnchorCapsule(
            releaseAnchor: quiescentReleaseAnchor
        )
        retainedAnchorCapsule = capsule
        self.releaseHook = releaseHook
        PrecisionIOHIDRetainedAnchorQuarantine.shared.retain(capsule)
    }

    var isReleased: Bool { lock.withLock { released } }
    var releaseCount: Int { lock.withLock { releaseCountStorage } }

    fileprivate func bindEndpointBundle(
        input: any PrecisionIOHIDOwnedInputEndpoint,
        output: any PrecisionIOHIDOwnedOutputEndpoint
    ) throws {
        guard lock.withLock({ !released }) else {
            throw PrecisionIOHIDOwnershipError.permanentlyStopped
        }
        guard retainedAnchorCapsule.bind(input: input, output: output) else {
            throw PrecisionIOHIDOwnershipError.ownershipTokenAlreadyBound
        }
    }

    fileprivate func bindNewEndpointBundle(
        input: any PrecisionIOHIDOwnedInputEndpoint,
        output: any PrecisionIOHIDOwnedOutputEndpoint
    ) {
        precondition(!released)
        precondition(retainedAnchorCapsule.bind(input: input, output: output))
    }

    fileprivate var retainedInputEndpoint:
        (any PrecisionIOHIDOwnedInputEndpoint)? {
        retainedAnchorCapsule.retainedInputEndpoint
    }

    fileprivate var retainedOutputEndpoint:
        (any PrecisionIOHIDOwnedOutputEndpoint)? {
        retainedAnchorCapsule.retainedOutputEndpoint
    }

    fileprivate func releaseAfterEndpointQuiescence() {
        let shouldNotify = lock.withLock {
            guard !released else { return false }
            released = true
            releaseCountStorage += 1
            return true
        }
        if shouldNotify {
            PrecisionIOHIDRetainedAnchorQuarantine.shared.release(
                retainedAnchorCapsule
            )
            releaseHook()
        }
    }
}

/// An anchor enters quarantine at token construction and can leave only after
/// ordered endpoint quiescence. If a coordinator is abandoned, the capsule is
/// deliberately retained for the process lifetime instead of allowing ARC to
/// release a potentially live device behind active callbacks or blocking I/O.
private final class PrecisionIOHIDRetainedAnchorCapsule:
    @unchecked Sendable {
    private let lock = NSLock()
    private var releaseAnchor: (any PrecisionIOHIDQuiescentReleaseAnchor)?
    private var retainedInput: (any PrecisionIOHIDOwnedInputEndpoint)?
    private var retainedOutput: (any PrecisionIOHIDOwnedOutputEndpoint)?

    var registryKey: ObjectIdentifier { ObjectIdentifier(self) }

    init(releaseAnchor: any PrecisionIOHIDQuiescentReleaseAnchor) {
        self.releaseAnchor = releaseAnchor
    }

    var retainedInputEndpoint: (any PrecisionIOHIDOwnedInputEndpoint)? {
        lock.withLock { retainedInput }
    }

    var retainedOutputEndpoint: (any PrecisionIOHIDOwnedOutputEndpoint)? {
        lock.withLock { retainedOutput }
    }

    func bind(
        input: any PrecisionIOHIDOwnedInputEndpoint,
        output: any PrecisionIOHIDOwnedOutputEndpoint
    ) -> Bool {
        lock.withLock {
            guard retainedInput == nil, retainedOutput == nil else {
                return false
            }
            retainedInput = input
            retainedOutput = output
            return true
        }
    }

    func releaseAfterEndpointQuiescence() {
        let anchor = lock.withLock {
            retainedOutput = nil
            retainedInput = nil
            let anchor = releaseAnchor
            releaseAnchor = nil
            return anchor
        }
        // Never invoke a concrete close/release callback while holding the
        // capsule lock. The callback is allowed to synchronously tear down its
        // owned system resource after both endpoint barriers have completed.
        anchor?.releaseAfterEndpointQuiescence()
    }
}

/// Compatibility anchor for internal ownership tests and opaque resources.
/// Future system-resource owners use the explicit package protocol directly.
private final class PrecisionIOHIDOpaqueReleaseAnchor:
    PrecisionIOHIDQuiescentReleaseAnchor,
    @unchecked Sendable {
    private let lock = NSLock()
    private var retained: AnyObject?

    init(retaining retained: AnyObject) {
        self.retained = retained
    }

    func releaseAfterEndpointQuiescence() {
        lock.withLock { retained = nil }
    }
}

private final class PrecisionIOHIDRetainedAnchorQuarantine:
    @unchecked Sendable {
    static let shared = PrecisionIOHIDRetainedAnchorQuarantine()

    private let lock = NSLock()
    private var capsules: [
        ObjectIdentifier: PrecisionIOHIDRetainedAnchorCapsule
    ] = [:]

    func retain(_ capsule: PrecisionIOHIDRetainedAnchorCapsule) {
        lock.withLock { capsules[capsule.registryKey] = capsule }
    }

    func release(_ capsule: PrecisionIOHIDRetainedAnchorCapsule) {
        let retained = lock.withLock {
            capsules.removeValue(forKey: capsule.registryKey)
        }
        retained?.releaseAfterEndpointQuiescence()
    }
}

protocol PrecisionIOHIDOwnedInputEndpoint:
    AnyObject,
    PrecisionTransportReportReader {
    var ownershipToken: PrecisionIOHIDOwnershipToken { get }
    func start() throws
    func shutdownAndWait()
    func setUnsolicitedHIDPPHandler(
        _ handler: (@Sendable (PrecisionTransportInputFrame) -> Void)?
    )
    func setDisconnectHandler(_ handler: (@Sendable () -> Void)?)
    func inputDiagnostics() -> PrecisionInputDiagnostics?
}

extension PrecisionIOHIDOwnedInputEndpoint {
    func inputDiagnostics() -> PrecisionInputDiagnostics? { nil }

    func setUnsolicitedHIDPPHandler(
        _ handler: (@Sendable (PrecisionTransportInputFrame) -> Void)?
    ) {
        _ = handler
    }

    func setDisconnectHandler(_ handler: (@Sendable () -> Void)?) {
        _ = handler
    }
}

protocol PrecisionIOHIDOwnedOutputEndpoint:
    AnyObject,
    PrecisionTransportDrainingReportWriter {
    var ownershipToken: PrecisionIOHIDOwnershipToken { get }
}

/// Narrow package boundary implemented by the productless input target.
/// It conveys only the input lifecycle needed by the ownership coordinator;
/// no raw handle, runtime, callback sink, or concrete session crosses it.
package protocol PrecisionIOHIDInputLifetime:
    AnyObject,
    PrecisionTransportReportReader {
    func start() throws
    func shutdownAndWait()
    func setUnsolicitedHIDPPHandler(
        _ handler: (@Sendable (PrecisionTransportInputFrame) -> Void)?
    )
    func setDisconnectHandler(_ handler: (@Sendable () -> Void)?)
    func inputDiagnostics() -> PrecisionInputDiagnostics?
}

/// A system-resource owner whose final synchronous release must occur only
/// after output drain and input callback quiescence. The ownership capsule
/// retains this capability fail-closed if its coordinator is abandoned.
package protocol PrecisionIOHIDQuiescentReleaseAnchor: AnyObject, Sendable {
    func releaseAfterEndpointQuiescence()
}

/// The sole package capability returned to the productless assembly target.
/// The concrete coordinator, token, quarantine, and endpoint wrappers remain
/// internal to this pure module.
package protocol PrecisionIOHIDAssembledEndpoint:
    AnyObject,
    PrecisionTransportReportReader,
    PrecisionTransportDrainingReportWriter {
    func start() async throws
    func setUnsolicitedHIDPPHandler(
        _ handler: (@Sendable (PrecisionTransportInputFrame) -> Void)?
    )
    func setDisconnectHandler(_ handler: (@Sendable () -> Void)?)
    func inputDiagnostics() -> PrecisionInputDiagnostics?
}

extension PrecisionIOHIDInputLifetime {
    package func inputDiagnostics() -> PrecisionInputDiagnostics? { nil }

    func setUnsolicitedHIDPPHandler(
        _ handler: (@Sendable (PrecisionTransportInputFrame) -> Void)?
    ) {
        _ = handler
    }

    func setDisconnectHandler(_ handler: (@Sendable () -> Void)?) {
        _ = handler
    }
}

extension PrecisionIOHIDAssembledEndpoint {
    package func inputDiagnostics() -> PrecisionInputDiagnostics? { nil }

    func setUnsolicitedHIDPPHandler(
        _ handler: (@Sendable (PrecisionTransportInputFrame) -> Void)?
    ) {
        _ = handler
    }

    func setDisconnectHandler(_ handler: (@Sendable () -> Void)?) {
        _ = handler
    }
}

/// Nonthrowing post-construction binding. Both fallible concrete endpoints
/// must exist before this creates the quarantined token and atomically attaches
/// the exact wrapper pair, so no partial bundle can escape or be abandoned.
package enum PrecisionIOHIDOwnershipFactory {
    package static func make(
        quiescentReleaseAnchor anchor:
            any PrecisionIOHIDQuiescentReleaseAnchor,
        input: any PrecisionIOHIDInputLifetime,
        output: any PrecisionTransportDrainingReportWriter
    ) -> any PrecisionIOHIDAssembledEndpoint {
        let token = PrecisionIOHIDOwnershipToken(
            quiescentReleaseAnchor: anchor
        )
        let ownedInput = PrecisionIOHIDReleasingInputEndpoint(
            ownershipToken: token,
            inner: input
        )
        let ownedOutput = PrecisionIOHIDReleasingOutputEndpoint(
            ownershipToken: token,
            inner: output
        )
        token.bindNewEndpointBundle(input: ownedInput, output: ownedOutput)
        return PrecisionIOHIDOwnershipCoordinator(boundToken: token)
    }
}

/// IOKit-free admission and teardown owner for token-bound input and output.
///
/// This coordinator is the only endpoint presented to a future transport. It
/// opens admission only after input startup succeeds. Shutdown first closes
/// admission, then awaits physical output drain, then blocks on input callback
/// quiescence on a dedicated queue, and only then releases the retained anchor.
/// It contains no raw-handle factory; the productless assembly target binds its
/// input, output, and release anchor to one shared physical device reference.
final class PrecisionIOHIDOwnershipCoordinator:
    PrecisionIOHIDAssembledEndpoint,
    PrecisionTransportReportReader,
    PrecisionTransportDrainingReportWriter,
    @unchecked Sendable {
    private let token: PrecisionIOHIDOwnershipToken
    private let admission: PrecisionIOHIDAdmissionGate
    private let lifecycle: PrecisionIOHIDOwnershipLifecycle

    convenience init(
        input: any PrecisionIOHIDOwnedInputEndpoint,
        output: any PrecisionIOHIDOwnedOutputEndpoint
    ) throws {
        guard input.ownershipToken === output.ownershipToken else {
            throw PrecisionIOHIDOwnershipError.deviceOwnershipMismatch
        }
        try input.ownershipToken.bindEndpointBundle(
            input: input,
            output: output
        )
        self.init(boundToken: input.ownershipToken)
    }

    fileprivate init(boundToken token: PrecisionIOHIDOwnershipToken) {
        let admission = PrecisionIOHIDAdmissionGate()
        self.token = token
        self.admission = admission
        lifecycle = PrecisionIOHIDOwnershipLifecycle(
            token: token,
            admission: admission
        )
    }

    deinit {
        // Deinitialization cannot safely substitute for asynchronous drain.
        // Closing admission is the only bounded fail-closed action available.
        admission.close()
    }

    func start() async throws {
        try await lifecycle.start()
    }

    func write(_ frame: PrecisionTransportOutputFrame) async throws -> Int32 {
        try admission.requireActive()
        guard let output = token.retainedOutputEndpoint else {
            throw PrecisionIOHIDOwnershipError.permanentlyStopped
        }
        return try await output.write(frame)
    }

    func cancelPendingWrite(
        requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        token.retainedOutputEndpoint?.cancelPendingWrite(
            requestID: requestID,
            reason: reason
        )
    }

    func beginRequest(_ frame: PrecisionTransportOutputFrame) throws {
        try admission.requireActive()
        guard let input = token.retainedInputEndpoint else {
            throw PrecisionIOHIDOwnershipError.permanentlyStopped
        }
        try input.beginRequest(frame)
    }

    func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame {
        // An already-admitted read remains valid while shutdown is closing the
        // output side. Input shutdown later wakes it if it has not completed.
        guard let input = token.retainedInputEndpoint else {
            throw PrecisionTransportReportIOError.disconnected
        }
        return try await input.read(for: requestID)
    }

    func endRequest(_ requestID: UUID) {
        token.retainedInputEndpoint?.endRequest(requestID)
    }

    func cancelRequest(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        token.retainedInputEndpoint?.cancelRequest(requestID, reason: reason)
    }

    func disconnected() {
        token.retainedInputEndpoint?.disconnected()
    }

    func setUnsolicitedHIDPPHandler(
        _ handler: (@Sendable (PrecisionTransportInputFrame) -> Void)?
    ) {
        token.retainedInputEndpoint?.setUnsolicitedHIDPPHandler(handler)
    }

    package func inputDiagnostics() -> PrecisionInputDiagnostics? {
        token.retainedInputEndpoint?.inputDiagnostics()
    }

    func setDisconnectHandler(_ handler: (@Sendable () -> Void)?) {
        token.retainedInputEndpoint?.setDisconnectHandler(handler)
    }

    /// Full ownership teardown, not merely logical write completion.
    func shutdownAndDrain() async {
        await lifecycle.shutdown()
    }

    var isAcceptingRequests: Bool { admission.isActive }
    var ownershipWasReleased: Bool { token.isReleased }
    var ownershipReleaseCount: Int { token.releaseCount }
    var isStopped: Bool { get async { await lifecycle.isStopped } }
}

private final class PrecisionIOHIDReleasingInputEndpoint:
    PrecisionIOHIDOwnedInputEndpoint,
    @unchecked Sendable {
    let ownershipToken: PrecisionIOHIDOwnershipToken
    private let lock = NSLock()
    private var inner: (any PrecisionIOHIDInputLifetime)?

    init(
        ownershipToken: PrecisionIOHIDOwnershipToken,
        inner: any PrecisionIOHIDInputLifetime
    ) {
        self.ownershipToken = ownershipToken
        self.inner = inner
    }

    func start() throws {
        guard let inner = retainedInner() else {
            throw PrecisionIOHIDOwnershipError.permanentlyStopped
        }
        try inner.start()
    }

    func shutdownAndWait() {
        guard let retained = retainedInner() else { return }
        retained.shutdownAndWait()
        clear(ifIdenticalTo: retained)
    }

    func beginRequest(_ frame: PrecisionTransportOutputFrame) throws {
        guard let inner = retainedInner() else {
            throw PrecisionIOHIDOwnershipError.permanentlyStopped
        }
        try inner.beginRequest(frame)
    }

    func read(for requestID: UUID) async throws -> PrecisionTransportInputFrame {
        guard let inner = retainedInner() else {
            throw PrecisionTransportReportIOError.disconnected
        }
        return try await inner.read(for: requestID)
    }

    func endRequest(_ requestID: UUID) {
        retainedInner()?.endRequest(requestID)
    }

    func cancelRequest(
        _ requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        retainedInner()?.cancelRequest(requestID, reason: reason)
    }

    func disconnected() {
        retainedInner()?.disconnected()
    }

    func setUnsolicitedHIDPPHandler(
        _ handler: (@Sendable (PrecisionTransportInputFrame) -> Void)?
    ) {
        retainedInner()?.setUnsolicitedHIDPPHandler(handler)
    }

    package func inputDiagnostics() -> PrecisionInputDiagnostics? {
        retainedInner()?.inputDiagnostics()
    }

    func setDisconnectHandler(_ handler: (@Sendable () -> Void)?) {
        retainedInner()?.setDisconnectHandler(handler)
    }

    private func retainedInner() -> (any PrecisionIOHIDInputLifetime)? {
        lock.withLock { inner }
    }

    private func clear(ifIdenticalTo retained: any PrecisionIOHIDInputLifetime) {
        lock.withLock {
            if let current = inner, current === retained { inner = nil }
        }
    }
}

private final class PrecisionIOHIDReleasingOutputEndpoint:
    PrecisionIOHIDOwnedOutputEndpoint,
    @unchecked Sendable {
    let ownershipToken: PrecisionIOHIDOwnershipToken
    private let lock = NSLock()
    private var inner: (any PrecisionTransportDrainingReportWriter)?

    init(
        ownershipToken: PrecisionIOHIDOwnershipToken,
        inner: any PrecisionTransportDrainingReportWriter
    ) {
        self.ownershipToken = ownershipToken
        self.inner = inner
    }

    func write(_ frame: PrecisionTransportOutputFrame) async throws -> Int32 {
        guard let inner = retainedInner() else {
            throw PrecisionIOHIDOwnershipError.permanentlyStopped
        }
        return try await inner.write(frame)
    }

    func cancelPendingWrite(
        requestID: UUID,
        reason: PrecisionTransportReportIOError
    ) {
        retainedInner()?.cancelPendingWrite(requestID: requestID, reason: reason)
    }

    func shutdownAndDrain() async {
        guard let retained = retainedInner() else { return }
        await retained.shutdownAndDrain()
        clear()
    }

    private func retainedInner() ->
        (any PrecisionTransportDrainingReportWriter)? {
        lock.withLock { inner }
    }

    private func clear() {
        lock.withLock { inner = nil }
    }
}

private final class PrecisionIOHIDAdmissionGate: @unchecked Sendable {
    private enum State: Sendable, Equatable {
        case initialized
        case active
        case closed
    }

    private let lock = NSLock()
    private var state: State = .initialized

    var isActive: Bool { lock.withLock { state == .active } }

    func activate() throws {
        try lock.withLock {
            guard state == .initialized else {
                if state == .closed {
                    throw PrecisionIOHIDOwnershipError.permanentlyStopped
                }
                throw PrecisionIOHIDOwnershipError.alreadyStarted
            }
            state = .active
        }
    }

    func close() {
        lock.withLock { state = .closed }
    }

    func requireActive() throws {
        try lock.withLock {
            switch state {
            case .active:
                return
            case .initialized:
                throw PrecisionIOHIDOwnershipError.notStarted
            case .closed:
                throw PrecisionIOHIDOwnershipError.shuttingDown
            }
        }
    }
}

private actor PrecisionIOHIDOwnershipLifecycle {
    private enum State {
        case initialized
        case active
        case shuttingDown(Task<Void, Never>)
        case stopped
    }

    private let token: PrecisionIOHIDOwnershipToken
    private let admission: PrecisionIOHIDAdmissionGate
    private let inputTeardownQueue = DispatchQueue(
        label: "com.phib.MXErgoController.precision-input-teardown"
    )
    private var state: State = .initialized

    init(
        token: PrecisionIOHIDOwnershipToken,
        admission: PrecisionIOHIDAdmissionGate
    ) {
        self.token = token
        self.admission = admission
    }

    func start() async throws {
        switch state {
        case .initialized:
            break
        case .active:
            throw PrecisionIOHIDOwnershipError.alreadyStarted
        case .shuttingDown:
            throw PrecisionIOHIDOwnershipError.shuttingDown
        case .stopped:
            throw PrecisionIOHIDOwnershipError.permanentlyStopped
        }

        do {
            guard let input = token.retainedInputEndpoint else {
                throw PrecisionIOHIDOwnershipError.permanentlyStopped
            }
            try input.start()
            try admission.activate()
            state = .active
        } catch {
            let task = makeShutdownTask()
            state = .shuttingDown(task)
            await task.value
            state = .stopped
            throw error
        }
    }

    func shutdown() async {
        let task: Task<Void, Never>
        switch state {
        case .initialized, .active:
            task = makeShutdownTask()
            state = .shuttingDown(task)
        case let .shuttingDown(existing):
            task = existing
        case .stopped:
            return
        }
        await task.value
        state = .stopped
    }

    var isStopped: Bool {
        if case .stopped = state { return true }
        return false
    }

    private func makeShutdownTask() -> Task<Void, Never> {
        admission.close()
        let token = self.token
        let input = token.retainedInputEndpoint
        let output = token.retainedOutputEndpoint
        let queue = inputTeardownQueue
        return Task {
            if let output {
                await output.shutdownAndDrain()
            }
            if let input {
                await withCheckedContinuation {
                    (continuation: CheckedContinuation<Void, Never>) in
                    queue.async {
                        input.shutdownAndWait()
                        continuation.resume()
                    }
                }
            }
            token.releaseAfterEndpointQuiescence()
        }
    }
}
