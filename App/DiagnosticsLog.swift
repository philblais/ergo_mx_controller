import MXErgoCore

// Keep the app's call sites on the same asynchronous logging interface while
// the file writer is exercised independently of a live AppModel or device.
typealias DiagnosticsLog = BoundedDiagnosticsLog
