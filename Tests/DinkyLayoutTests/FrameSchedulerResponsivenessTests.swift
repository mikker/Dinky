import CoreGraphics
import Foundation
import Testing
@testable import DinkyLayout

private func frame(_ id: WindowID, x: CGFloat = 0) -> FrameJob {
    FrameJob(pid: 1, id: id, frame: CGRect(x: x, y: 0, width: 100, height: 100))
}

struct FrameSchedulerResponsivenessTests {
    @Test func `A superseded step cannot claim it resized the window`() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let arrived = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var calls: [String] = []
        let scheduler = FrameScheduler(settle: 0, read: { _ in nil }, write: { job, live in
            if job.frame.minX == 0 {
                started.signal()
                _ = release.wait(timeout: .now() + 2)
            }
            if live() { lock.withLock { calls.append("resize") }; arrived.signal() }
        }, move: { _, live in
            if live() { lock.withLock { calls.append("move") }; arrived.signal() }
        })
        scheduler.step([frame(10)])
        #expect(started.wait(timeout: .now() + 2) == .success)
        scheduler.step([frame(10, x: 10)])
        release.signal()
        #expect(arrived.wait(timeout: .now() + 2) == .success)
        #expect(lock.withLock { calls } == ["resize"], "the new step must size the window, since the old step never did")
    }

    @Test func `A closed and reused id invalidates a write waiting on an AX lookup`() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let oldDone = DispatchSemaphore(value: 0)
        let newDone = DispatchSemaphore(value: 0)
        var writes: [CGFloat] = []
        let scheduler = FrameScheduler(settle: 0, read: { _ in nil }, write: { job, live in
            if job.frame.minX == 10 {
                started.signal()
                _ = release.wait(timeout: .now() + 2)
            }
            if live() { writes.append(job.frame.minX) }
        })
        scheduler.submit([frame(10, x: 10)]) { _ in oldDone.signal() }
        #expect(started.wait(timeout: .now() + 2) == .success)
        scheduler.forget(10)
        scheduler.submit([frame(10, x: 20)]) { _ in newDone.signal() }
        release.signal()
        #expect(newDone.wait(timeout: .now() + 2) == .success)
        #expect(oldDone.wait(timeout: .now() + 2) == .success)
        #expect(writes == [20])
    }

    @Test func `Cancel during one retry prevents the remaining retries`() {
        let done = DispatchSemaphore(value: 0)
        var writes: [WindowID] = []
        var scheduler: FrameScheduler!
        scheduler = FrameScheduler(settle: 0,
            read: { _ in CGRect(x: 0, y: 0, width: 574, height: 100) }, write: { job in
                writes.append(job.id)
                if writes == [10, 11, 10] { scheduler.cancel() }
            })
        scheduler.submit([frame(10), frame(11)]) { _ in done.signal() }
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(writes == [10, 11, 10])
    }

    @Test func `Cancel during a retry cannot confirm a stale minimum size`() {
        let done = DispatchSemaphore(value: 0)
        var writes = 0
        var scheduler: FrameScheduler!
        scheduler = FrameScheduler(settle: 0,
            read: { _ in CGRect(x: 0, y: 0, width: 574, height: 100) }, write: { _ in
                writes += 1
                if writes == 4 { scheduler.cancel() }
            })
        scheduler.submit([frame(10)]) { _ in done.signal() }
        #expect(done.wait(timeout: .now() + 2) == .success)
        var smaller = frame(10)
        smaller.frame.size.width = 50
        scheduler.submit([smaller]) { _ in done.signal() }
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(scheduler.minimumSizes.isEmpty)
    }

    @Test func `Settling does not block a later animation step for the same app`() {
        let firstWrite = DispatchSemaphore(value: 0)
        let stepWrite = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var frames: [WindowID: CGRect] = [:]
        let scheduler = FrameScheduler(settle: 0.5, read: { job in lock.withLock { frames[job.id] } },
            write: { job in
                lock.withLock { frames[job.id] = job.frame }
                (job.id == 10 ? firstWrite : stepWrite).signal()
            })
        scheduler.submit([frame(10)]) { _ in done.signal() }
        #expect(firstWrite.wait(timeout: .now() + 2) == .success)
        scheduler.step([frame(11)])
        #expect(stepWrite.wait(timeout: .now() + 0.25) == .success,
                "new writes must not wait for the preceding pass's 500 ms verification interval")
        #expect(done.wait(timeout: .now() + 2) == .success)
    }

    @Test func `A newer target prevents the old target from retrying`() {
        let firstWrite = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let oldDone = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var writes: [CGFloat] = []
        let scheduler = FrameScheduler(settle: 0.1, read: { _ in .zero }, write: { job in
            lock.withLock { writes.append(job.frame.minX) }
            firstWrite.signal()
        })
        scheduler.submit([frame(10, x: 10)]) { _ in oldDone.signal() }
        #expect(firstWrite.wait(timeout: .now() + 2) == .success)
        scheduler.submit([frame(10, x: 20)]) { _ in done.signal() }
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(oldDone.wait(timeout: .now() + 2) == .success)
        #expect(lock.withLock { writes } == [10, 20, 20])
    }

    @Test func `Cancel stops steps already removed from the pending queue`() {
        let done = DispatchSemaphore(value: 0)
        var writes: [WindowID] = []
        var scheduler: FrameScheduler!
        scheduler = FrameScheduler(settle: 0, read: { $0.frame }, write: { job in
            writes.append(job.id)
            if job.id == 10 {
                scheduler.cancel()
                scheduler.submit([frame(99)]) { _ in done.signal() }
            }
        })
        scheduler.step([frame(10), frame(11)])
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(writes == [10])
    }

    @Test func `Forget drops queued writes for a closed window`() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        var writes: [WindowID] = []
        let scheduler = FrameScheduler(settle: 0, read: { _ in nil }, write: { job in
            if job.id == 10 {
                started.signal()
                _ = release.wait(timeout: .now() + 2)
            }
            writes.append(job.id)
        })
        scheduler.step([frame(10)])
        #expect(started.wait(timeout: .now() + 2) == .success)
        scheduler.submit([frame(11)]) { _ in done.signal() }
        scheduler.forget(11)
        release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(writes == [10])
    }
}
