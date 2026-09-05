import AppKit
import Foundation

/// Remembers which application is frontmost, so the event tap can ask without
/// touching AppKit.
///
/// The tap runs on its own thread and decides what to inject inside a callback
/// the window server is waiting on. Calling `NSWorkspace` from there would be
/// both a main-thread violation and a latency risk, so the value is kept
/// current from workspace notifications and only read.
final class FrontmostApplicationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    init() {
        storage = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    var bundleIdentifier: String? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        let identifier = (notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication)?.bundleIdentifier
        lock.lock()
        storage = identifier
        lock.unlock()
    }
}
