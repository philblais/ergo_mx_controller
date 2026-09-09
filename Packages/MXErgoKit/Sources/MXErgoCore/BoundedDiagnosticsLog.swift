import Foundation
import Synchronization

/// A best-effort diagnostic file, separate from durable recovery journals.
/// Callers choose its content; raw HID reports can include pointer movement.
/// Commands are queued in submission order so logging does not perform file
/// I/O on the caller's thread. File errors stop writing until an explicit start.
public final class BoundedDiagnosticsLog: Sendable {
    private let queue = DispatchQueue(label: "com.phib.MXErgoController.DiagnosticsLog")
    private let url: URL
    private let byteCap: Int
    // The queue orders commands; the mutex gives mutable storage a checked
    // Sendable boundary without asserting that the entire class is unchecked.
    private let storage = Mutex(Storage())

    public var path: String { url.path }

    public init(url: URL, byteCap: Int = 512 * 1024) {
        precondition(byteCap >= 128, "A log needs room for its timestamp and markers")
        self.url = url
        self.byteCap = byteCap
    }

    public func start() {
        queue.async { [self] in
            storage.withLock { $0.start(at: url, byteCap: byteCap) }
        }
    }

    public func stop() {
        queue.async { [self] in
            storage.withLock {
                $0.write("--- diagnostics log closed ---", byteCap: byteCap)
                $0.close()
            }
        }
    }

    public func append(_ line: String) {
        queue.async { [self] in
            storage.withLock { $0.write(line, byteCap: byteCap) }
        }
    }

    /// Completes after commands already submitted to the queue. This is a
    /// read/test barrier, not a promise of durable storage or process-exit flush.
    public func waitForPendingWrites() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
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
