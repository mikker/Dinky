import Foundation
import DinkyLayout

/// Translate an untiled frame into the current monitor without crossing its usable bounds.
func recoveryFrame(_ frame: CGRect, from source: CGRect?, on visible: CGRect) -> CGRect? {
    func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
    guard valid(frame), valid(visible), source.map(valid) ?? true else { return nil }
    let size = CGSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
    let origin: CGPoint
    if let source {
        origin = CGPoint(x: visible.minX + frame.minX - source.minX,
                         y: visible.minY + frame.minY - source.minY)
    } else if visible.contains(CGPoint(x: frame.midX, y: frame.midY)) {
        origin = frame.origin
    } else {
        // Older journals have only global coordinates; don't guess their former monitor's origin.
        origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
    }
    return CGRect(x: min(max(origin.x, visible.minX), visible.maxX - size.width),
                  y: min(max(origin.y, visible.minY), visible.maxY - size.height),
                  width: size.width, height: size.height)
}

struct RecoveryDisplay {
    let uuid: String
    let visibleFrame: CGRect
    let userSpaces: Set<UInt64>
    let currentSpace: UInt64

    init(_ display: Display) {
        uuid = display.uuid
        visibleFrame = display.visibleArea
        userSpaces = Set(display.userSpaces)
        currentSpace = display.currentSpaceID
    }

    init(uuid: String, visibleFrame: CGRect, userSpaces: Set<UInt64>, currentSpace: UInt64) {
        self.uuid = uuid
        self.visibleFrame = visibleFrame
        self.userSpaces = userSpaces
        self.currentSpace = currentSpace
    }
}

struct RecoveryWindowState {
    let pid: Int32
    let space: UInt64
    let frame: CGRect
    let isOnScreen: Bool
}

/// A frame completion can arrive after shutdown's bounded wait. Only the waiting caller consumes results.
final class RecoveryFrameCompletion {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var results: [FrameResult] = []
    private var closed = false

    func complete(_ results: [FrameResult]) {
        lock.withLock { if !closed { self.results = results } }
        done.signal()
    }

    func wait(until deadline: DispatchTime) -> [FrameResult] {
        _ = done.wait(timeout: deadline)
        return lock.withLock {
            closed = true
            return results
        }
    }
}
