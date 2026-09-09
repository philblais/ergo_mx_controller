import Foundation

// Process.waitUntilExit() can leave a cooperative test task blocked in a
// Foundation run loop after its child has exited. Register before launch and
// suspend asynchronously instead; cancellation must not skip child cleanup.
actor TestProcessExit {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    static func observe(_ process: Process) -> TestProcessExit {
        let completion = TestProcessExit()
        process.terminationHandler = { _ in
            Task { await completion.finish() }
        }
        return completion
    }

    func wait() async {
        guard !finished else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
