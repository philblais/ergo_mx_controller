import Foundation

/// Appends what the app observed to a file, so a session can be read back
/// exactly rather than transcribed from the menu.
///
/// It exists because reading a value off screen and typing it into a
/// conversation is a lossy step that has already produced one wrong diagnosis:
/// a "last seen" row reported as a click when it held a scroll. Bytes in a file
/// are not subject to that.
///
/// It never records pointer motion. Only reports whose button state changed,
/// vendor reports, and the event layer's own counters are written — which is
/// the same information the menu already shows, and nothing more.
final class DiagnosticsLog {
    /// Bounded so an enabled log cannot fill a disk. When the cap is passed the
    /// file starts again with a marker, rather than growing or silently
    /// stopping.
    private static let byteCap = 512 * 1024

    private let queue = DispatchQueue(label: "com.phib.MXErgoController.DiagnosticsLog")
    private let url: URL
    private var handle: FileHandle?
    private var written = 0

    var path: String { url.path }

    init(url: URL) {
        self.url = url
    }

    func start() {
        queue.async { [self] in
            close()
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            written = 0
            write("--- diagnostics log opened \(Self.stamp()) ---")
        }
    }

    func stop() {
        queue.async { [self] in
            write("--- diagnostics log closed \(Self.stamp()) ---")
            close()
        }
    }

    func append(_ line: String) {
        queue.async { [self] in write(line) }
    }

    private func write(_ line: String) {
        guard let handle else { return }
        let text = "\(Self.stamp())  \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if written + data.count > Self.byteCap {
            try? handle.truncate(atOffset: 0)
            written = 0
            let marker = "--- log wrapped at \(Self.byteCap) bytes ---\n"
            if let markerData = marker.data(using: .utf8) {
                try? handle.write(contentsOf: markerData)
                written += markerData.count
            }
        }
        try? handle.write(contentsOf: data)
        written += data.count
    }

    private func close() {
        try? handle?.close()
        handle = nil
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
