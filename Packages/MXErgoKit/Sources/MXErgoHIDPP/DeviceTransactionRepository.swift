import CryptoKit
import Darwin
import Foundation

public enum DeviceTransactionRepositoryError: Error, Sendable, Equatable {
    case compareAndSwapMismatch(expected: UInt64?, actual: UInt64?)
    case transactionIdentityMismatch
    case invalidNextRevision(expected: UInt64, actual: UInt64)
    case durableCommitVerificationFailed
    case posix(operation: String, code: Int32)
}

public struct DeviceTransactionDurableCommitReceipt: Sendable, Equatable {
    public let transactionID: UUID
    public let revision: UInt64
    public let sha256: String

    public init(transactionID: UUID, revision: UInt64, sha256: String) {
        self.transactionID = transactionID
        self.revision = revision
        self.sha256 = sha256
    }
}

public enum DeviceTransactionCommitBoundary: String, Sendable, Equatable, CaseIterable {
    case beforeTemporaryWrite
    case afterTemporaryWrite
    case afterTemporaryFullSync
    case afterAtomicReplace
    case afterDirectorySync
    case beforeReceiptReturn
}

public protocol DeviceTransactionJournalRepository: Sendable {
    func loadValidated() async throws -> DeviceTransactionEnvelope?
    func commit(
        _ next: DeviceTransactionEnvelope,
        expectedRevision: UInt64?
    ) async throws -> DeviceTransactionDurableCommitReceipt
}

/// A schema-v3 compare-and-swap repository. The temporary file is fully
/// flushed before replacement, and the containing directory is flushed after
/// replacement. Any failure is ambiguous and therefore never authorizes a
/// transport effect.
public actor DurableDeviceTransactionFileRepository: DeviceTransactionJournalRepository {
    public let fileURL: URL
    private let faultInjector: (@Sendable (DeviceTransactionCommitBoundary) throws -> Void)?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        faultInjector = nil
    }

    package init(
        fileURL: URL,
        faultInjector: @escaping @Sendable (DeviceTransactionCommitBoundary) throws -> Void
    ) {
        self.fileURL = fileURL
        self.faultInjector = faultInjector
    }

    public func loadValidated() async throws -> DeviceTransactionEnvelope? {
        try Self.load(from: fileURL)
    }

    public func commit(
        _ next: DeviceTransactionEnvelope,
        expectedRevision: UInt64?
    ) async throws -> DeviceTransactionDurableCommitReceipt {
        try next.validate()
        let current = try Self.load(from: fileURL)
        let actualRevision = current?.revision
        guard actualRevision == expectedRevision else {
            throw DeviceTransactionRepositoryError.compareAndSwapMismatch(
                expected: expectedRevision,
                actual: actualRevision
            )
        }

        if let current {
            guard current.transactionID == next.transactionID else {
                throw DeviceTransactionRepositoryError.transactionIdentityMismatch
            }
            guard current.revision < .max else {
                throw DeviceTransactionRepositoryError.invalidNextRevision(
                    expected: current.revision,
                    actual: next.revision
                )
            }
            let expectedNextRevision = current.revision + 1
            guard next.revision == expectedNextRevision else {
                throw DeviceTransactionRepositoryError.invalidNextRevision(
                    expected: expectedNextRevision,
                    actual: next.revision
                )
            }
        } else {
            guard next.revision == 0 else {
                throw DeviceTransactionRepositoryError.invalidNextRevision(
                    expected: 0,
                    actual: next.revision
                )
            }
        }

        let data = try Self.encoded(next)
        try faultInjector?(.beforeTemporaryWrite)
        try Self.durablyReplace(
            data: data,
            at: fileURL,
            faultInjector: faultInjector
        )

        guard let verified = try Self.load(from: fileURL), verified == next else {
            throw DeviceTransactionRepositoryError.durableCommitVerificationFailed
        }
        let verifiedData = try Data(contentsOf: fileURL)
        guard verifiedData == data else {
            throw DeviceTransactionRepositoryError.durableCommitVerificationFailed
        }
        try faultInjector?(.beforeReceiptReturn)

        return DeviceTransactionDurableCommitReceipt(
            transactionID: next.transactionID,
            revision: next.revision,
            sha256: Self.sha256(data)
        )
    }

    private static func load(from fileURL: URL) throws -> DeviceTransactionEnvelope? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(DeviceTransactionEnvelope.self, from: data)
        try envelope.validate()
        return envelope
    }

    private static func encoded(_ envelope: DeviceTransactionEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func durablyReplace(
        data: Data,
        at fileURL: URL,
        faultInjector: (@Sendable (DeviceTransactionCommitBoundary) throws -> Void)?
    ) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        var fileDescriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard fileDescriptor >= 0 else {
            throw posixError("open temporary journal")
        }

        var temporaryFileExists = true
        defer {
            if fileDescriptor >= 0 {
                _ = Darwin.close(fileDescriptor)
            }
            if temporaryFileExists {
                _ = Darwin.unlink(temporaryURL.path)
            }
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write temporary journal")
                }
                guard written > 0 else {
                    throw DeviceTransactionRepositoryError.posix(
                        operation: "write temporary journal",
                        code: EIO
                    )
                }
                offset += written
            }
        }
        try faultInjector?(.afterTemporaryWrite)

        guard Darwin.fcntl(fileDescriptor, F_FULLFSYNC) == 0 else {
            throw posixError("F_FULLFSYNC temporary journal")
        }
        try faultInjector?(.afterTemporaryFullSync)
        guard Darwin.close(fileDescriptor) == 0 else {
            fileDescriptor = -1
            throw posixError("close temporary journal")
        }
        fileDescriptor = -1

        guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
            throw posixError("replace transaction journal")
        }
        temporaryFileExists = false
        try faultInjector?(.afterAtomicReplace)

        let directoryDescriptor = Darwin.open(directoryURL.path, O_RDONLY)
        guard directoryDescriptor >= 0 else {
            throw posixError("open transaction journal directory")
        }
        defer { _ = Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw posixError("fsync transaction journal directory")
        }
        try faultInjector?(.afterDirectorySync)
    }

    private static func posixError(_ operation: String) -> DeviceTransactionRepositoryError {
        DeviceTransactionRepositoryError.posix(operation: operation, code: errno)
    }
}
