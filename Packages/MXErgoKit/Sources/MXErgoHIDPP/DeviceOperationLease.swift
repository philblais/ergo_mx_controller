import Darwin
import Foundation

public enum MXErgoDeviceOperationLeaseError: Error, Sendable, Equatable {
    case unavailable
    case nonRegularFile
    case posix(operation: String, code: Int32)
}

/// A stable, descriptor-scoped lease shared by every writer of the live device
/// journal and by any future hardware helper. The lock lives beside the journal
/// so atomic journal replacement never changes the locked inode.
public final class MXErgoDeviceOperationLease: @unchecked Sendable {
    private static let processRegistry = ProcessRegistry()

    public let lockURL: URL
    private let processLockPath: String
    private var descriptor: Int32

    private init(lockURL: URL, processLockPath: String, descriptor: Int32) {
        self.lockURL = lockURL
        self.processLockPath = processLockPath
        self.descriptor = descriptor
    }

    public static func acquire(
        beside journalURL: URL
    ) throws -> MXErgoDeviceOperationLease {
        let directory = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let lockURL = directory.appendingPathComponent(
            ".device-state-journal.operation.lock"
        )
        let canonicalDirectory = directory.standardizedFileURL
            .resolvingSymlinksInPath()
        let processLockPath = canonicalDirectory
            .appendingPathComponent(lockURL.lastPathComponent)
            .path
        guard processRegistry.acquire(processLockPath) else {
            throw MXErgoDeviceOperationLeaseError.unavailable
        }

        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            processRegistry.release(processLockPath)
            throw posix("open device-operation lease")
        }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            processRegistry.release(processLockPath)
            throw MXErgoDeviceOperationLeaseError.posix(
                operation: "inspect device-operation lease",
                code: code
            )
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            _ = Darwin.close(descriptor)
            processRegistry.release(processLockPath)
            throw MXErgoDeviceOperationLeaseError.nonRegularFile
        }

        var lock = flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_OFD_SETLK, &lock) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            processRegistry.release(processLockPath)
            if code == EACCES || code == EAGAIN {
                throw MXErgoDeviceOperationLeaseError.unavailable
            }
            throw MXErgoDeviceOperationLeaseError.posix(
                operation: "lock device-operation lease",
                code: code
            )
        }

        return MXErgoDeviceOperationLease(
            lockURL: lockURL,
            processLockPath: processLockPath,
            descriptor: descriptor
        )
    }

    /// Confirms that a caller-supplied lease protects the canonical operation
    /// lock beside this exact live journal. This lets a short-lived hardware
    /// helper hold one uninterrupted lease across discovery and execution.
    public func protects(journalURL: URL) -> Bool {
        let directory = journalURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let expected = directory.appendingPathComponent(
            ".device-state-journal.operation.lock"
        )
        return lockURL.standardizedFileURL.resolvingSymlinksInPath().path
            == expected.path
    }

    deinit {
        guard descriptor >= 0 else { return }
        var lock = flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_OFD_SETLK, &lock)
        _ = Darwin.close(descriptor)
        descriptor = -1
        Self.processRegistry.release(processLockPath)
    }

    private static func posix(_ operation: String) -> MXErgoDeviceOperationLeaseError {
        .posix(operation: operation, code: errno)
    }
}

private final class ProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var heldPaths: Set<String> = []

    func acquire(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return heldPaths.insert(path).inserted
    }

    func release(_ path: String) {
        lock.lock()
        heldPaths.remove(path)
        lock.unlock()
    }
}
