// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A wait that lasts until the test opens it, or until the task that waits is cancelled
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var entered = 0
    private var cancelled = 0

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                entered += 1
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else if Task.isCancelled {
                    cancelled += 1
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            if continuation != nil { cancelled += 1 }
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// lets every wait end, also those to come
    func open() {
        lock.lock()
        isOpen = true
        let waiting = Array(waiters.values)
        waiters = [:]
        lock.unlock()
        waiting.forEach { $0.resume() }
    }

    /// waits that have begun, that go on, and that were cancelled
    var counts: (entered: Int, waiting: Int, cancelled: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (entered, waiters.count, cancelled)
    }
}
