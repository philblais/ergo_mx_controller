import Darwin
import Foundation
import MXErgoHIDPP

/// Test-only subprocess used to prove that a durable write-ahead record can be
/// decoded after an uncatchable process termination. This executable does not
/// import MXErgoHID and therefore cannot open or mutate an HID device.
@main
struct MXErgoTransactionCrashHarness {
    static func main() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.count >= 2 else {
            throw HarnessError.invalidArguments
        }

        if arguments[1] == "hold-trial-operation-lock" {
            guard arguments.count == 4 else { throw HarnessError.invalidArguments }
            try holdTrialOperationLock(
                lockURL: URL(fileURLWithPath: arguments[2]),
                readyURL: URL(fileURLWithPath: arguments[3])
            )
            return
        }

        guard arguments.count == 4,
              arguments[1] == "crash-after-apply-wal" else {
            throw HarnessError.invalidArguments
        }

        let baselineURL = URL(fileURLWithPath: arguments[2])
        let transactionURL = URL(fileURLWithPath: arguments[3])
        guard let baseline = try DeviceStateJournalStore(fileURL: baselineURL).load() else {
            throw HarnessError.missingBaseline
        }

        let repository = DurableDeviceTransactionFileRepository(fileURL: transactionURL)
        let prepared = try DeviceTransactionEnvelope(baselineJournal: baseline)
        _ = try await repository.commit(prepared, expectedRevision: nil)

        guard let firstControl = prepared.controls.min(by: {
            $0.controlIndex < $1.controlIndex
        }) else {
            throw HarnessError.missingControl
        }
        var intendedBytes = firstControl.baseline.rawParameters
        intendedBytes[2] ^= 0x01
        let intended = try DeviceTransactionWireState(rawParameters: intendedBytes)
        let reduction = try DeviceTransactionReducer.reduce(
            prepared,
            event: .armApply(
                controlID: firstControl.controlID,
                intended: intended,
                attemptID: UUID(),
                now: Date()
            )
        )
        _ = try await repository.commit(
            reduction.envelope,
            expectedRevision: reduction.previousRevision
        )

        // The test parent expects signal termination and then reopens the
        // journal from a different process. There is deliberately no transport
        // invocation between the durable commit and this hard stop.
        _ = Darwin.kill(Darwin.getpid(), SIGKILL)
        Darwin._exit(70)
    }

    private static func holdTrialOperationLock(lockURL: URL, readyURL: URL) throws {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw HarnessError.lockFailed(errno) }
        defer { _ = Darwin.close(descriptor) }

        var fileLock = flock()
        fileLock.l_start = 0
        fileLock.l_len = 0
        fileLock.l_pid = 0
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_OFD_SETLK, &fileLock) == 0 else {
            throw HarnessError.lockFailed(errno)
        }
        try Data("ready".utf8).write(to: readyURL, options: .atomic)
        while true { _ = Darwin.pause() }
    }
}

private enum HarnessError: Error {
    case invalidArguments
    case missingBaseline
    case missingControl
    case lockFailed(Int32)
}
