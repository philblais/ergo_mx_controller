import Foundation
import Synchronization

/// A best-effort diagnostic file, separate from durable recovery journals.
/// Callers choose its content; raw HID reports can include pointer movement.
/// Commands are queued in submission order so logging does not perform file
/// I/O on the caller's thread. Pending append payloads are bounded independently
/// of the file; overload drops new entries and records a loss notice when the
/// next entry or stop reaches the writer. File errors require an explicit start.
public final class BoundedDiagnosticsLog: Sendable {
    private let queue: DispatchQueue
    private let url: URL
    private let byteCap: Int
    private let pendingByteCap: Int
    private let pendingEntryCap: Int
    // This lock only orders submissions and accounts for retained payloads.
    // The caller never takes the storage lock or waits for file I/O.
    private let admission = Mutex(Admission())
    // The queue orders commands; the mutex gives mutable storage a checked
    // Sendable boundary without asserting that the entire class is unchecked.
    private let storage = Mutex(Storage())

    public var path: String { url.path }

    public convenience init(url: URL, byteCap: Int = 512 * 1024) {
        self.init(url: url, byteCap: byteCap, pendingByteCap: 512 * 1024,
            pendingEntryCap: 1024,
            queue: DispatchQueue(label: "com.phib.MXErgoController.DiagnosticsLog"))
    }

    // An injected queue lets tests hold the writer still without sleeps or
    // disk-speed assumptions. Production always uses its own serial queue.
    init(url: URL, byteCap: Int, pendingByteCap: Int, pendingEntryCap: Int,
         queue: DispatchQueue) {
        precondition(byteCap >= 128 && byteCap < Int.max)
        precondition(pendingByteCap >= 32 && pendingEntryCap > 0)
        self.url = url
        self.byteCap = byteCap
        self.pendingByteCap = pendingByteCap
        self.pendingEntryCap = pendingEntryCap
        self.queue = queue
    }

    var pendingUsage: (entries: Int, bytes: Int) {
        admission.withLock { ($0.entries, $0.bytes) }
    }

    public func start() {
        admission.withLock {
            $0.accepting = true
            $0.dropped = 0
            queue.async { [self] in
                storage.withLock { $0.start(at: url, byteCap: byteCap) }
            }
        }
    }

    public func stop() {
        admission.withLock {
            $0.accepting = false
            let dropped = $0.takeDropped()
            queue.async { [self] in
                storage.withLock {
                    $0.noteDropped(dropped, byteCap: byteCap)
                    $0.write("--- diagnostics log closed ---", byteCap: byteCap)
                    $0.close()
                }
            }
        }
    }

    public func append(_ line: String) {
        guard admission.withLock({ $0.accepting }) else { return }
        // Copy only a bounded UTF-8 prefix. Capturing the original String (or
        // a Substring) in a queued closure could retain an arbitrarily large input.
        let payload = Self.boundedPayload(line, limit: min(byteCap, pendingByteCap))
        admission.withLock { state in
            guard state.accepting else { return }
            guard state.entries < pendingEntryCap,
                  payload.count <= pendingByteCap - state.bytes else {
                if state.dropped < Int.max { state.dropped += 1 }
                return
            }
            state.entries += 1
            state.bytes += payload.count
            let dropped = state.takeDropped()
            queue.async { [self] in
                defer {
                    admission.withLock {
                        $0.entries -= 1
                        $0.bytes -= payload.count
                    }
                }
                storage.withLock {
                    $0.noteDropped(dropped, byteCap: byteCap)
                    $0.write(String(decoding: payload, as: UTF8.self), byteCap: byteCap)
                }
            }
        }
    }

    /// Completes after commands already submitted to the queue. This is a
    /// read/test barrier, not a promise of durable storage or process-exit flush.
    public func waitForPendingWrites() async {
        await withCheckedContinuation { continuation in
            admission.withLock { _ in
                queue.async { continuation.resume() }
            }
        }
    }

    private static func boundedPayload(_ line: String, limit: Int) -> Data {
        var data = Data(line.utf8.prefix(limit + 1))
        guard data.count > limit else { return data }
        let suffix = Data(" [truncated]".utf8)
        data.removeSubrange((limit - suffix.count)..<data.count)
        while String(data: data, encoding: .utf8) == nil { data.removeLast() }
        data.append(suffix)
        return data
    }

    private struct Admission {
        var accepting = false
        var entries = 0
        var bytes = 0
        var dropped = 0

        mutating func takeDropped() -> Int {
            defer { dropped = 0 }
            return dropped
        }
    }

    private struct Storage {
        var handle: FileHandle?
        var written = 0
        // Formatting is confined with the handle, avoiding a formatter
        // allocation for every raw report while diagnostics is enabled.
        let formatter: DateFormatter = {
            let value = DateFormatter()
            value.dateFormat = "HH:mm:ss.SSS"
            return value
        }()

        mutating func start(at url: URL, byteCap: Int) {
            close()
            written = 0
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
            do {
                handle = try FileHandle(forWritingTo: url)
                try handle?.truncate(atOffset: 0)
                try handle?.seek(toOffset: 0)
                write("--- diagnostics log opened ---", byteCap: byteCap)
            } catch {
                close()
            }
        }

        mutating func write(_ line: String, byteCap: Int) {
            guard let handle else { return }
            let marker = Data("--- log wrapped at \(byteCap) bytes ---\n".utf8)
            let entry = boundedEntry(line, limit: byteCap - marker.count)
            do {
                if written + entry.count > byteCap {
                    try handle.truncate(atOffset: 0)
                    try handle.seek(toOffset: 0)
                    try handle.write(contentsOf: marker)
                    written = marker.count
                }
                try handle.write(contentsOf: entry)
                written += entry.count
            } catch {
                close()
            }
        }

        mutating func noteDropped(_ count: Int, byteCap: Int) {
            guard count > 0 else { return }
            write("--- dropped \(count) diagnostics entries while writer was busy ---", byteCap: byteCap)
        }

        private func boundedEntry(_ line: String, limit: Int) -> Data {
            let data = Data("\(formatter.string(from: Date()))  \(line)\n".utf8)
            guard data.count > limit else { return data }
            let suffix = Data(" [truncated]\n".utf8)
            var prefix = Data(data.prefix(limit - suffix.count))
            // A byte cap must not leave half of a multi-byte character behind.
            while String(data: prefix, encoding: .utf8) == nil {
                prefix.removeLast()
            }
            prefix.append(suffix)
            return prefix
        }

        mutating func close() {
            try? handle?.close()
            handle = nil
        }
    }
}
