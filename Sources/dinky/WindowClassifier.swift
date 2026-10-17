import Foundation
import DinkyConfig

/// Accessibility metadata is read on one queue per app, never on the event/UI thread. Requests for the
/// same window are coalesced, and a close, reused id or disable invalidates even a result already in flight.
final class WindowClassifier: @unchecked Sendable {
    private final class Request {
        let window: Window
        let completion: (WindowMetadata?) -> Void
        var attempts = 0  // app queue only

        init(_ window: Window, completion: @escaping (WindowMetadata?) -> Void) {
            self.window = window
            self.completion = completion
        }
    }

    private let lock = NSLock()
    private var pending: [UInt32: Request] = [:]
    private var queues: [Int32: DispatchQueue] = [:]
    private let read: (Window) -> WindowMetadata?
    private let retryDelay: TimeInterval
    private let maxAttempts: Int

    init(retryDelay: TimeInterval = 0.2, maxAttempts: Int = 5,
         read: @escaping (Window) -> WindowMetadata? = readWindowMetadata) {
        self.retryDelay = retryDelay
        self.maxAttempts = maxAttempts
        self.read = read
    }

    /// False when this identity already has a request, including while it waits to retry.
    @discardableResult
    func request(_ window: Window, completion: @escaping (WindowMetadata?) -> Void) -> Bool {
        let request = Request(window, completion: completion)
        let queue: DispatchQueue? = lock.withLock {
            guard pending[window.id]?.window.identity != window.identity else { return nil }
            pending[window.id] = request
            let queue = queues[window.pid] ?? DispatchQueue(label: "dinky.classify.\(window.pid)")
            queues[window.pid] = queue
            return queue
        }
        guard let queue else { return false }
        queue.async { self.perform(request, on: queue) }
        return true
    }

    func forget(_ id: UInt32) { lock.withLock { pending[id] = nil } }
    func cancel() { lock.withLock { pending.removeAll() } }

    private func perform(_ request: Request, on queue: DispatchQueue) {
        guard isCurrent(request) else { return }
        request.attempts += 1
        let metadata = read(request.window)
        guard isCurrent(request) else { return }
        if metadata == nil, request.attempts < maxAttempts {
            queue.asyncAfter(deadline: .now() + retryDelay) { self.perform(request, on: queue) }
            return
        }
        DispatchQueue.main.async {
            let current = self.lock.withLock { () -> Bool in
                guard self.pending[request.window.id] === request else { return false }
                self.pending[request.window.id] = nil
                return true
            }
            if current { request.completion(metadata) }
        }
    }

    private func isCurrent(_ request: Request) -> Bool {
        lock.withLock { pending[request.window.id] === request }
    }
}

struct WindowMetadata {
    let kind: WindowKind
    let resizable: Bool
    let title: String
    let lacksFullscreen: Bool
}
