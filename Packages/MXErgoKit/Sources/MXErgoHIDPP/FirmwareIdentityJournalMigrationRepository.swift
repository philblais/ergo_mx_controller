import Darwin
import Foundation

public enum FirmwareIdentityJournalMigrationCommitError: Error, Sendable, Equatable {
    case planNotReady
    case sourceBytesMismatch(expectedSHA256: String, actualSHA256: String?)
    case backupConflict
    case lockUnavailable
    case nonRegularFile(String)
    case durableVerificationFailed
    case posix(operation: String, code: Int32)
}

public enum FirmwareIdentityJournalMigrationCommitDisposition: Sendable, Equatable {
    case committed
    case alreadyCommitted
}

public struct FirmwareIdentityJournalMigrationCommitReceipt: Sendable, Equatable {
    public let disposition: FirmwareIdentityJournalMigrationCommitDisposition
    public let transactionID: UUID
    public let sourceSHA256: String
    public let targetSHA256: String
    public let backupURL: URL
}

public enum FirmwareIdentityJournalMigrationCommitBoundary:
    String,
    Sendable,
    Equatable,
    CaseIterable
{
    case beforeBackupWrite
    case afterBackupWrite
    case afterBackupFullSync
    case afterBackupPublish
    case afterBackupDirectorySync
    case beforeTargetWrite
    case afterTargetWrite
    case afterTargetFullSync
    case beforeSourceRecheck
    case afterAtomicReplace
    case afterDirectorySync
    case beforeReceiptReturn
}

/// Dedicated schema-v2 metadata committer. It never sends HID requests and it
/// accepts only the exact planned source or target byte sequence.
public actor DurableFirmwareIdentityJournalMigrationRepository {
    public let fileURL: URL
    public let backupURL: URL
    public let lockURL: URL

    private let faultInjector:
        (@Sendable (FirmwareIdentityJournalMigrationCommitBoundary) throws -> Void)?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("device-state-journal.pre-firmware-identity.json")
        lockURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".device-state-journal.firmware-identity.lock")
        faultInjector = nil
    }

    init(
        fileURL: URL,
        faultInjector: @escaping @Sendable (
            FirmwareIdentityJournalMigrationCommitBoundary
        ) throws -> Void
    ) {
        self.fileURL = fileURL
        backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("device-state-journal.pre-firmware-identity.json")
        lockURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".device-state-journal.firmware-identity.lock")
        self.faultInjector = faultInjector
    }

    public func commit(
        _ plan: FirmwareIdentityJournalMigrationPlan
    ) throws -> FirmwareIdentityJournalMigrationCommitReceipt {
        guard plan.changesExactlyFirmwareIdentity,
              plan.sourceData != plan.targetData,
              plan.sourceSHA256 == FirmwareIdentityJournalMigrationPlanner.sha256(plan.sourceData),
              plan.targetSHA256 == FirmwareIdentityJournalMigrationPlanner.sha256(plan.targetData) else {
            throw FirmwareIdentityJournalMigrationCommitError.planNotReady
        }
        try plan.originalJournal.validateForRecovery()
        try plan.proposedJournal.validateForRecovery()

        let operationLease: MXErgoDeviceOperationLease
        do {
            operationLease = try MXErgoDeviceOperationLease.acquire(beside: fileURL)
        } catch MXErgoDeviceOperationLeaseError.unavailable {
            throw FirmwareIdentityJournalMigrationCommitError.lockUnavailable
        }
        defer { withExtendedLifetime(operationLease) {} }

        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let lockDescriptor = try acquireLock()
        defer {
            _ = setAdvisoryLock(lockDescriptor, type: Int16(F_UNLCK))
            _ = Darwin.close(lockDescriptor)
        }

        try requireRegularFile(fileURL)
        let currentData = try Data(contentsOf: fileURL)
        if currentData == plan.targetData {
            try requireExactBackup(plan.sourceData)
            try syncDirectory(directoryURL)
            try validate(data: currentData, equals: plan.proposedJournal)
            return receipt(for: plan, disposition: .alreadyCommitted)
        }

        guard currentData == plan.sourceData else {
            throw FirmwareIdentityJournalMigrationCommitError.sourceBytesMismatch(
                expectedSHA256: plan.sourceSHA256,
                actualSHA256: FirmwareIdentityJournalMigrationPlanner.sha256(currentData)
            )
        }

        try ensureDurableBackup(plan.sourceData, directoryURL: directoryURL)
        try replaceLiveJournal(
            with: plan.targetData,
            expectedSourceData: plan.sourceData,
            directoryURL: directoryURL
        )

        let verifiedData = try Data(contentsOf: fileURL)
        try validate(data: verifiedData, equals: plan.proposedJournal)
        guard verifiedData == plan.targetData else {
            throw FirmwareIdentityJournalMigrationCommitError.durableVerificationFailed
        }
        try faultInjector?(.beforeReceiptReturn)
        return receipt(for: plan, disposition: .committed)
    }

    private func receipt(
        for plan: FirmwareIdentityJournalMigrationPlan,
        disposition: FirmwareIdentityJournalMigrationCommitDisposition
    ) -> FirmwareIdentityJournalMigrationCommitReceipt {
        FirmwareIdentityJournalMigrationCommitReceipt(
            disposition: disposition,
            transactionID: plan.originalJournal.transactionID,
            sourceSHA256: plan.sourceSHA256,
            targetSHA256: plan.targetSHA256,
            backupURL: backupURL
        )
    }

    private func acquireLock() throws -> Int32 {
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError("open migration lock") }
        guard setAdvisoryLock(descriptor, type: Int16(F_WRLCK)) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            if code == EACCES || code == EAGAIN {
                throw FirmwareIdentityJournalMigrationCommitError.lockUnavailable
            }
            throw FirmwareIdentityJournalMigrationCommitError.posix(
                operation: "lock migration journal",
                code: code
            )
        }
        return descriptor
    }

    private func setAdvisoryLock(_ descriptor: Int32, type: Int16) -> Int32 {
        var lock = flock()
        lock.l_type = type
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        return Darwin.fcntl(descriptor, F_SETLK, &lock)
    }

    private func ensureDurableBackup(_ sourceData: Data, directoryURL: URL) throws {
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try requireExactBackup(sourceData)
            try syncDirectory(directoryURL)
            return
        }

        try faultInjector?(.beforeBackupWrite)
        let temporaryURL = uniqueTemporaryURL(in: directoryURL, label: "backup")
        var temporaryExists = true
        defer {
            if temporaryExists { _ = Darwin.unlink(temporaryURL.path) }
        }

        try writeAndFullSync(
            sourceData,
            to: temporaryURL,
            afterWrite: .afterBackupWrite,
            afterFullSync: .afterBackupFullSync
        )
        guard Darwin.link(temporaryURL.path, backupURL.path) == 0 else {
            if errno == EEXIST {
                try requireExactBackup(sourceData)
                return
            }
            throw posixError("publish firmware identity backup")
        }
        try faultInjector?(.afterBackupPublish)
        guard Darwin.unlink(temporaryURL.path) == 0 else {
            throw posixError("remove published backup temporary file")
        }
        temporaryExists = false

        try requireExactBackup(sourceData)
        try syncDirectory(directoryURL)
        try faultInjector?(.afterBackupDirectorySync)
    }

    private func requireExactBackup(_ sourceData: Data) throws {
        try requireRegularFile(backupURL)
        guard try Data(contentsOf: backupURL) == sourceData else {
            throw FirmwareIdentityJournalMigrationCommitError.backupConflict
        }
    }

    private func replaceLiveJournal(
        with targetData: Data,
        expectedSourceData: Data,
        directoryURL: URL
    ) throws {
        try faultInjector?(.beforeTargetWrite)
        let temporaryURL = uniqueTemporaryURL(in: directoryURL, label: "target")
        var temporaryExists = true
        defer {
            if temporaryExists { _ = Darwin.unlink(temporaryURL.path) }
        }

        try writeAndFullSync(
            targetData,
            to: temporaryURL,
            afterWrite: .afterTargetWrite,
            afterFullSync: .afterTargetFullSync
        )
        guard try Data(contentsOf: temporaryURL) == targetData else {
            throw FirmwareIdentityJournalMigrationCommitError.durableVerificationFailed
        }

        try faultInjector?(.beforeSourceRecheck)
        try requireRegularFile(fileURL)
        guard try Data(contentsOf: fileURL) == expectedSourceData else {
            let actualData = try? Data(contentsOf: fileURL)
            throw FirmwareIdentityJournalMigrationCommitError.sourceBytesMismatch(
                expectedSHA256: FirmwareIdentityJournalMigrationPlanner.sha256(expectedSourceData),
                actualSHA256: actualData.map(FirmwareIdentityJournalMigrationPlanner.sha256)
            )
        }

        guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
            throw posixError("replace recovery journal")
        }
        temporaryExists = false
        try faultInjector?(.afterAtomicReplace)
        try syncDirectory(directoryURL)
        try faultInjector?(.afterDirectorySync)
    }

    private func writeAndFullSync(
        _ data: Data,
        to fileURL: URL,
        afterWrite: FirmwareIdentityJournalMigrationCommitBoundary,
        afterFullSync: FirmwareIdentityJournalMigrationCommitBoundary
    ) throws {
        var descriptor = Darwin.open(
            fileURL.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixError("open migration temporary file") }
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write migration temporary file")
                }
                guard written > 0 else {
                    throw FirmwareIdentityJournalMigrationCommitError.posix(
                        operation: "write migration temporary file",
                        code: EIO
                    )
                }
                offset += written
            }
        }
        try faultInjector?(afterWrite)
        guard Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw posixError("F_FULLFSYNC migration temporary file")
        }
        try faultInjector?(afterFullSync)
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw posixError("close migration temporary file")
        }
        descriptor = -1
    }

    private func syncDirectory(_ directoryURL: URL) throws {
        let descriptor = Darwin.open(directoryURL.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError("open migration directory") }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError("fsync migration directory")
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw posixError("lstat \(url.lastPathComponent)")
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw FirmwareIdentityJournalMigrationCommitError.nonRegularFile(url.path)
        }
    }

    private func validate(data: Data, equals expected: DeviceStateJournal) throws {
        let journal = try JSONDecoder().decode(DeviceStateJournal.self, from: data)
        try journal.validateForRecovery()
        guard journal == expected else {
            throw FirmwareIdentityJournalMigrationCommitError.durableVerificationFailed
        }
    }

    private func uniqueTemporaryURL(in directoryURL: URL, label: String) -> URL {
        directoryURL.appendingPathComponent(
            ".device-state-journal.\(label).\(UUID().uuidString).tmp"
        )
    }

    private func posixError(_ operation: String) -> FirmwareIdentityJournalMigrationCommitError {
        FirmwareIdentityJournalMigrationCommitError.posix(operation: operation, code: errno)
    }
}
