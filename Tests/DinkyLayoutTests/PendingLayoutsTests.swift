import CoreGraphics
import Foundation
import Testing
@testable import DinkyLayout

struct PendingLayoutsTests {
    @Test func overviewDuringAnimationWritesOnlyTheFinalAccumulatedWorkspaceOnExit() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        let writes = FrameWrites()
        var pending = PendingLayouts()
        var tree = workspace(2)
        var frames: [WindowID: CGRect] = [:]
        var observed: [FrameJob] = []
        let scheduler = FrameScheduler(
            settle: 0, beforeBatch: { _ in entered.signal(); release.wait() }, alive: { _ in true },
            read: { job in lock.withLock { frames[job.id] } },
            write: { job in
                guard let permit = writes.permit, writes.allows(permit) else { return }
                lock.withLock { observed.append(job); frames[job.id] = job.frame }
            })
        var animation = FrameAnimation(from: rect(0, 0, 50, 50), to: tree.layout().frames[1]!)
        _ = animation.step(Spring(response: 1, damping: 0.9), dt: 1.0 / 60, timeout: 4)
        scheduler.step([FrameJob(pid: 1, id: 1, frame: animation.frame)])
        let began = entered.wait(timeout: .now() + 2)
        #expect(began == .success)
        guard began == .success else { release.signal(); return }

        writes.transition(to: .overview)
        scheduler.cancel()
        pending.pause([1])
        for width in [800, 1200, 900] {
            tree.bounds = rect(0, 0, CGFloat(width), 600)
            pending.dirty.insert(1)
            #expect(pending.take(visible: [1], existing: [1]).isEmpty)
        }
        #expect(lock.withLock { observed.isEmpty })
        #expect(pending.resume() == [1])
        writes.transition(to: .layout)
        #expect(pending.take(visible: [1], existing: [1]) == [1])
        let layout = tree.layout()
        let final = layout.order.map { FrameJob(pid: 1, id: $0, frame: layout.frames[$0]!) }
        scheduler.submit(final) { _ in done.signal() }
        release.signal()
        release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(lock.withLock { observed == final }, "neither the interrupted spring nor intermediate layouts replay")
        #expect(pending.take(visible: [1], existing: [1]).isEmpty)
    }

    @Test func overviewEntryPreservesInterruptedAndAccumulatedTreesUntilOneExitPass() {
        var layouts = PendingLayouts()
        layouts.dirty = [1]
        layouts.pause([1, 2])
        #expect(layouts.take(visible: [1, 2], existing: [1, 2, 3]).isEmpty)
        for _ in 0..<5 {
            layouts.dirty.formUnion([1, 3])
            #expect(layouts.take(visible: [1, 2, 3], existing: [1, 2, 3]).isEmpty)
        }
        #expect(layouts.resume() == [1, 2, 3])
        #expect(layouts.take(visible: [1, 2, 3], existing: [1, 2, 3]) == [1, 2, 3])
        #expect(layouts.take(visible: [1, 2, 3], existing: [1, 2, 3]).isEmpty)
    }

    @Test func spaceChangesDuringOverviewWriteOnlyTheFinalVisibleTrees() {
        var layouts = PendingLayouts()
        layouts.pause([1, 2])
        #expect(layouts.take(visible: [1], existing: [1, 2]).isEmpty)
        #expect(layouts.take(visible: [2], existing: [1, 2]).isEmpty)
        layouts.resume()
        #expect(layouts.take(visible: [2], existing: [1, 2]) == [2])
        #expect(layouts.dirty == [1])
        #expect(layouts.take(visible: [1], existing: [1, 2]) == [1])
    }

    @Test func treesRemovedDuringOverviewDoNotReappearOnExit() {
        var layouts = PendingLayouts()
        layouts.pause([1, 2])
        layouts.resume()
        #expect(layouts.take(visible: [1, 2], existing: [2]) == [2])
        #expect(layouts.dirty.isEmpty)
    }
}
