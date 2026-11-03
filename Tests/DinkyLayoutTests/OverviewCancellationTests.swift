import CoreGraphics
import Foundation
import Testing
@testable import DinkyLayout

struct OverviewCancellationTests {
    @Test func rejectedInFlightStepCannotPoisonMoveOnlyOptimizationAfterResume() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        let writes = FrameWrites()
        let initial = rect(0, 0, 100, 100)
        let target = rect(10, 10, 200, 200)
        var actual = initial
        var first = true
        let scheduler = FrameScheduler(
            settle: 0, alive: { _ in true },
            read: { job in job.id == 1 ? lock.withLock { actual } : .zero },
            write: { job in
                guard let permit = writes.permit else { return }
                let blocked = lock.withLock { let value = first; first = false; return value }
                if blocked { entered.signal(); release.wait() }
                guard writes.allows(permit) else { return }
                lock.withLock { actual = job.frame }
            },
            move: { job in lock.withLock { actual.origin = job.frame.origin } })
        scheduler.step([FrameJob(pid: 1, id: 1, frame: target)])
        let began = entered.wait(timeout: .now() + 2)
        #expect(began == .success)
        guard began == .success else { release.signal(); return }
        writes.transition(to: .overview)
        scheduler.cancel()
        writes.transition(to: .layout)
        // The canceled element lookup returns without writing. The exit snap already matches the real frame.
        scheduler.submit([FrameJob(pid: 1, id: 1, frame: initial)]) { _ in done.signal() }
        release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        scheduler.step([FrameJob(pid: 1, id: 1, frame: target)])
        scheduler.submit([FrameJob(pid: 1, id: 2, frame: .zero)]) { _ in done.signal() }
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(lock.withLock { actual == target }, "a rejected write must not be remembered as a known size")
    }

    @Test func cancelledDrainedAnimationBatchStartsNoWrites() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var writes: [WindowID] = []
        let target = CGRect(x: 100, y: 0, width: 400, height: 300)
        let scheduler = FrameScheduler(
            settle: 0,
            beforeBatch: { _ in entered.signal(); release.wait() },
            alive: { _ in true },
            read: { _ in target },
            write: { job in lock.withLock { writes.append(job.id) } })
        scheduler.step([FrameJob(pid: 1, id: 10, frame: target),
                        FrameJob(pid: 1, id: 11, frame: target)])
        let began = entered.wait(timeout: .now() + 2)
        #expect(began == .success)
        guard began == .success else { release.signal(); return }
        // The batch has been drained, but no actual frame call has started.
        scheduler.cancel()
        // A no-write full pass fences the same process queue after the steps.
        scheduler.submit([FrameJob(pid: 1, id: 20, frame: target)]) { _ in done.signal() }
        release.signal()
        release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(lock.withLock { writes.isEmpty })
    }

    @Test func cancelledDrainedFullBatchStartsNoWrites() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var writes: [WindowID] = []
        let target = CGRect(x: 100, y: 0, width: 400, height: 300)
        let scheduler = FrameScheduler(
            settle: 0,
            beforeBatch: { _ in entered.signal(); release.wait() },
            alive: { _ in true },
            read: { _ in .zero },
            write: { job in lock.withLock { writes.append(job.id) } })
        scheduler.submit([FrameJob(pid: 1, id: 10, frame: target)]) { _ in done.signal() }
        let began = entered.wait(timeout: .now() + 2)
        #expect(began == .success)
        guard began == .success else { release.signal(); return }
        scheduler.cancel()
        release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(lock.withLock { writes.isEmpty })
    }

    @Test func cancellationDuringAnAnimationStepStopsLaterStepsInTheSameDrain() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var writes: [WindowID] = []
        let target = CGRect(x: 100, y: 0, width: 400, height: 300)
        let scheduler = FrameScheduler(
            settle: 0, alive: { _ in true }, read: { _ in target },
            write: { job in
                lock.withLock { writes.append(job.id) }
                if job.id == 10 { entered.signal(); release.wait() }
            })
        scheduler.step([FrameJob(pid: 1, id: 10, frame: target),
                        FrameJob(pid: 1, id: 11, frame: target)])
        let began = entered.wait(timeout: .now() + 2)
        #expect(began == .success)
        guard began == .success else { release.signal(); return }
        scheduler.cancel()
        scheduler.submit([FrameJob(pid: 1, id: 20, frame: target)]) { _ in done.signal() }
        release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(lock.withLock { writes == [10] }, "only the system call already executing may finish")
    }
}
