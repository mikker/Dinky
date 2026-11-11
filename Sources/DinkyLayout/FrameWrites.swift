import Foundation

/// Invalidates work across cancellation, including work already waiting on an app or a raise queue.
/// Check the permit immediately before each system call. A call already in progress may finish.
public final class FrameWrites: @unchecked Sendable {
    public enum State { case layout, overview, restoration }

    private let lock = NSLock()
    private var generation = 0
    private var state = State.layout

    public init() {}

    public var permit: Int? { lock.withLock { state == .overview ? nil : generation } }

    public func allows(_ permit: Int) -> Bool {
        lock.withLock { state != .overview && generation == permit }
    }

    /// Cancel queued work without changing whether new layout work is admitted.
    public func invalidate() { lock.withLock { generation += 1 } }

    /// Disabled tiling gives restoration a fresh permit, even in overview. Overview changes while disabled
    /// leave that restoration alone; re-enabling invalidates it before automatic layout work can resume.
    @discardableResult
    public func transition(to state: State) -> Bool {
        lock.withLock {
            guard self.state != state else { return false }
            generation += 1
            self.state = state
            return true
        }
    }
}
