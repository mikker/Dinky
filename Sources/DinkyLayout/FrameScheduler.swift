import CoreGraphics
import Foundation

/// A frame to write: a window, the process that owns it and where it should go (top-left origin).
public struct FrameJob: Equatable, Sendable {
    public var pid: Int32
    public var id: WindowID
    public var frame: CGRect

    public init(pid: Int32, id: WindowID, frame: CGRect) {
        self.pid = pid
        self.id = id
        self.frame = frame
    }
}

/// What a window ended up at after a write.
public struct FrameResult: Equatable, Sendable {
    public var job: FrameJob
    /// The request that produced this result; delayed readbacks must not affect a newer one.
    fileprivate var revision: UInt64 = 0
    /// Where the window was asked to go: the job's frame grown to the window's recorded minimum size.
    public var target: CGRect
    /// The frame read back, nil when the window could not be read.
    public var got: CGRect?
    /// False when the window was already in place and nothing was written.
    public var written = false
    /// True when the first write landed elsewhere and it was written once more.
    public var retried = false

    /// Landed within 2 pt of the target on every edge.
    public var matched: Bool { got.map { $0.isClose(to: target, within: 2) } ?? false }
}

/// Schedules frame writes: one serial queue per process so a slow app only stalls itself,
/// the newest frame per window wins, and a window that refuses its frame is written at most twice.
/// Animation steps take a lighter path on the same queues: written once, not read back, and only moved
/// when their size is the one last written. The actual reads and writes are injected, so this is testable
/// without Accessibility.
public final class FrameScheduler: @unchecked Sendable {
    public typealias Completion = ([FrameResult]) -> Void

    private let settle: TimeInterval
    private let prepare: (Int32) -> Void
    private let read: (FrameJob) -> CGRect?
    private let write: (FrameJob, () -> Bool) -> Void
    private let move: (FrameJob, () -> Bool) -> Void

    private let lock = NSLock()
    private var apps: [Int32: App] = [:]
    private var minimums: [WindowID: CGSize] = [:]
    /// The last refusal of each window: a minimum once a pass asking for another size sees the same one.
    private var candidates: [WindowID: Refusal] = [:]
    /// Each request supersedes earlier work for its window, including delayed verification.
    private var nextRevision: UInt64 = 0
    private var revisions: [WindowID: UInt64] = [:]
    private var lastJobs: [WindowID: FrameJob] = [:]

    private struct Scheduled {
        let job: FrameJob
        let revision: UInt64
    }

    /// `prepare` runs once per process before its first write; `read`, `write` and `move` (position only)
    /// run on that process's queue.
    public convenience init(settle: TimeInterval = 0.1, prepare: @escaping (Int32) -> Void = { _ in },
                read: @escaping (FrameJob) -> CGRect?, write: @escaping (FrameJob) -> Void,
                move: ((FrameJob) -> Void)? = nil) {
        self.init(settle: settle, prepare: prepare, read: read,
                  write: { job, live in if live() { write(job) } },
                  move: { job, live in if live() { (move ?? write)(job) } })
    }

    /// AX writes can check `live` between individual system calls, including after a slow element lookup.
    public init(settle: TimeInterval = 0.1, prepare: @escaping (Int32) -> Void = { _ in },
                read: @escaping (FrameJob) -> CGRect?, write: @escaping (FrameJob, () -> Bool) -> Void,
                move: ((FrameJob, () -> Bool) -> Void)? = nil) {
        self.settle = settle
        self.prepare = prepare
        self.read = read
        self.write = write
        self.move = move ?? write
    }

    /// Sizes windows refused to go below, the same for two different sizes asked. Only dimensions that were
    /// refused are set.
    public var minimumSizes: [WindowID: CGSize] { lock.withLock { minimums } }

    /// Queue frames. `completion` gets the results of every process queue these jobs went to,
    /// once each has verified them. Results can include writes completed before cancellation or supersession;
    /// check `isCurrent` before using them for follow-up work such as raising windows.
    public func submit(_ jobs: [FrameJob], completion: Completion? = nil) {
        let byPid = Dictionary(grouping: jobs, by: \.pid)
        guard !byPid.isEmpty else { completion?([]); return }
        let batch = Batch(waiting: byPid.count, completion)
        lock.withLock {
            for (pid, jobs) in byPid {
                let app = app(pid)
                for job in jobs {
                    let work = request(job)
                    if let i = app.pending.firstIndex(where: { $0.job.id == job.id }) { app.pending[i] = work } else { app.pending.append(work) }
                }
                app.batches.append(batch)
                schedule(app)
            }
        }
    }

    /// Queue animation steps: each replaces any step of the same window not written yet, and is written once
    /// without reading back. A step whose size is the one last written for its window only moves it.
    public func step(_ jobs: [FrameJob]) {
        lock.withLock {
            for job in jobs {
                let app = app(job.pid)
                let work = request(job)
                if let i = app.steps.firstIndex(where: { $0.job.id == job.id }) { app.steps[i] = work } else { app.steps.append(work) }
                schedule(app)
            }
        }
    }

    /// Whether every result still belongs to the newest request for its window.
    public func isCurrent(_ results: [FrameResult]) -> Bool {
        lock.withLock { results.allSatisfy { revisions[$0.job.id] == $0.revision } }
    }

    private func request(_ job: FrameJob) -> Scheduled {
        if lastJobs[job.id] == job, let revision = revisions[job.id] {
            return Scheduled(job: job, revision: revision)
        }
        lastJobs[job.id] = job
        nextRevision += 1
        revisions[job.id] = nextRevision
        return Scheduled(job: job, revision: nextRevision)
    }

    private func isCurrent(_ work: Scheduled) -> Bool {
        lock.withLock { revisions[work.job.id] == work.revision }
    }

    /// The process's queue, made on first use. Under the lock.
    private func app(_ pid: Int32) -> App {
        if let app = apps[pid] { return app }
        let app = App(pid)
        apps[pid] = app
        return app
    }

    /// Drain the process's queue unless a drain is already on its way. Under the lock.
    private func schedule(_ app: App) {
        guard !app.scheduled else { return }
        app.scheduled = true
        app.queue.async { self.drain(app) }
    }

    /// Forgets a window that is gone: its minimum size, its last refusal, and what steps wrote.
    /// Window ids are reused, so a new window must not inherit them.
    public func forget(_ id: WindowID) {
        lock.withLock {
            minimums[id] = nil
            candidates[id] = nil
            revisions[id] = nil
            lastJobs[id] = nil
            for app in apps.values {
                app.pending.removeAll { $0.job.id == id }
                app.steps.removeAll { $0.job.id == id }
            }
            // What steps wrote is the queue's alone, so it is cleared there, after anything already queued.
            for app in apps.values { app.queue.async { app.written[id] = nil; app.stepSizes[id] = nil } }
        }
    }

    /// Forgets every minimum size and refusal, so windows are asked for their tiles again.
    public func forgetMinimums() {
        lock.withLock { minimums = [:]; candidates = [:] }
    }

    /// Drops every frame not written yet, including a second try already under way. Completions still run,
    /// with the results of what was written.
    public func cancel() {
        lock.withLock {
            revisions.removeAll()
            lastJobs.removeAll()
            for app in apps.values {
                app.pending = []
                app.steps = []
                app.queue.async { app.written = [:]; app.stepSizes = [:] }
            }
        }
    }

    /// Take pending writes on the app's queue. Verification is scheduled later on that same queue,
    /// leaving it free for new frames while an app settles. No queue sleeps between writes and readback.
    private func drain(_ app: App) {
        let (steps, jobs, batches) = lock.withLock {
            defer { app.steps = []; app.pending = []; app.batches = []; app.scheduled = false }
            return (app.steps, app.pending, app.batches)
        }
        if !app.prepared, (steps + jobs).contains(where: isCurrent) {
            prepare(app.pid)
            app.prepared = true
        }
        for work in steps {
            guard isCurrent(work) else { continue }
            let job = work.job
            let live = { self.isCurrent(work) }
            app.written[job.id] == job.frame.size ? move(job, live) : write(job, live)
            app.written[job.id] = isCurrent(work) ? job.frame.size : nil
            app.stepSizes[job.id, default: []].insert(job.frame.size)
        }
        let results = jobs.compactMap { work -> FrameResult? in
            guard isCurrent(work) else { return nil }
            let job = work.job
            let current = read(job), target = reachable(job)
            let written = isCurrent(work) && !(current?.isClose(to: target, within: 1) ?? false)
            if written { write(job, { self.isCurrent(work) }); app.written[job.id] = nil }
            return FrameResult(job: job, revision: work.revision, target: target, got: current, written: written)
        }
        let stepSizes = app.stepSizes
        let finish: Completion = { results in
            self.lock.withLock {
                for result in results where self.revisions[result.job.id] == result.revision {
                    app.stepSizes[result.job.id] = nil
                    if result.matched || !result.written { self.candidates[result.job.id] = nil }
                }
            }
            for batch in batches { batch.report(results) }
        }
        guard results.contains(where: \.written) else { finish(results); return }
        app.queue.asyncAfter(deadline: .now() + settle) {
            self.verify(results, on: app, stepSizes: stepSizes, retry: true, completion: finish)
        }
    }

    /// Read back and retry only results that still describe the newest request. A newer frame can be
    /// written during either settle interval; the old pass cannot retry it or learn a minimum from it.
    private func verify(_ previous: [FrameResult], on app: App, stepSizes: [WindowID: Set<CGSize>],
                        retry: Bool, completion: @escaping Completion) {
        var results = previous
        for i in results.indices where results[i].written {
            guard isCurrent([results[i]]) else { continue }
            results[i].got = read(results[i].job)
            if !retry, results[i].retried { recordMinimum(results[i], stepSizes: stepSizes[results[i].job.id] ?? []) }
        }
        guard retry else { completion(results); return }
        var retried = false
        for i in results.indices where results[i].written {
            guard isCurrent([results[i]]), let got = results[i].got,
                  !got.isClose(to: results[i].target, within: 2) else { continue }
            let result = results[i]
            write(result.job, { self.isCurrent([result]) })
            results[i].retried = true
            retried = true
        }
        guard retried else { completion(results); return }
        app.queue.asyncAfter(deadline: .now() + settle) {
            self.verify(results, on: app, stepSizes: stepSizes, retry: false, completion: completion)
        }
    }

    /// The job's frame grown to the window's recorded minimum size: as close as the window will come.
    private func reachable(_ job: FrameJob) -> CGRect {
        guard let minimum = minimumSizes[job.id] else { return job.frame }
        return CGRect(origin: job.frame.origin, size: job.frame.size.grown(to: minimum))
    }

    /// A window that came back larger than asked, where it was put, may have a minimum size in that dimension. It
    /// counts once a pass asking for a different size gets the same size back. Asking the same size again proves
    /// nothing: an app that snaps to a grid (Terminal's rows and columns) misses the same way every time, but a
    /// smaller ask snaps smaller, while a real minimum comes back unchanged. An app still resizing to an earlier
    /// size (Ghostty reflowing, an Electron app, or a size an animation step asked for) has caught up by the later
    /// pass. A window somewhere else has left (native full screen, another Space) and says nothing about how small
    /// it can be.
    private func recordMinimum(_ result: FrameResult, stepSizes: Set<CGSize>) {
        let id = result.job.id
        guard let got = result.got else { return }
        let refusal = Refusal(asked: result.job.frame.size, got: got.size)
        lock.withLock {
            guard revisions[id] == result.revision else { return }
            guard abs(got.minX - result.job.frame.minX) <= 2, abs(got.minY - result.job.frame.minY) <= 2,
                  !stepSizes.contains(got.size) else { candidates[id] = nil; return }
            if let seen = candidates[id] {
                let confirmed = refusal.confirms(seen)
                if confirmed != .zero { minimums[id] = minimums[id]?.grown(to: confirmed) ?? confirmed }
            }
            candidates[id] = refusal.got == .zero ? nil : refusal
        }
    }

    /// The size a window was asked for and the size it came back at, in the dimensions where it came back more
    /// than 2 pt larger. Others are zero.
    private struct Refusal {
        var asked = CGSize.zero
        var got = CGSize.zero

        init(asked: CGSize, got: CGSize) {
            if got.width > asked.width + 2 { self.asked.width = asked.width; self.got.width = got.width }
            if got.height > asked.height + 2 { self.asked.height = asked.height; self.got.height = got.height }
        }

        /// The minimum this and an earlier refusal show: each dimension both refused, at sizes asked more than
        /// 2 pt apart, coming back within 2 pt of each other.
        func confirms(_ earlier: Refusal) -> CGSize {
            func minimum(_ asked: CGFloat, _ got: CGFloat, _ askedBefore: CGFloat, _ gotBefore: CGFloat) -> CGFloat {
                got > 0 && gotBefore > 0 && abs(got - gotBefore) <= 2 && abs(asked - askedBefore) > 2 ? max(got, gotBefore) : 0
            }
            return CGSize(width: minimum(asked.width, got.width, earlier.asked.width, earlier.got.width),
                          height: minimum(asked.height, got.height, earlier.asked.height, earlier.got.height))
        }
    }

    /// Pending work uses the scheduler's lock; frame caches and preparation belong to the app's queue.
    private final class App {
        let pid: Int32
        let queue: DispatchQueue
        var pending: [Scheduled] = []
        var batches: [Batch] = []
        var steps: [Scheduled] = []
        /// The size each window's last step wrote, so the next step can be a plain move. Queue only.
        var written: [WindowID: CGSize] = [:]
        /// Every size steps asked of each window since the last full pass that included it. Apps that resize
        /// lazily can still be at one of them when the full write reads back. Queue only.
        var stepSizes: [WindowID: Set<CGSize>] = [:]
        var scheduled = false
        var prepared = false

        init(_ pid: Int32) {
            self.pid = pid
            self.queue = DispatchQueue(label: "dinky.frames.\(pid)")
        }
    }

    /// Collects results from each process queue a submit went to, then calls its completion.
    private final class Batch {
        private let lock = NSLock()
        private var waiting: Int
        private var results: [FrameResult] = []
        private let completion: Completion?

        init(waiting: Int, _ completion: Completion?) {
            self.waiting = waiting
            self.completion = completion
        }

        func report(_ new: [FrameResult]) {
            let done: [FrameResult]? = lock.withLock {
                results += new
                waiting -= 1
                return waiting == 0 ? results : nil
            }
            if let done { completion?(done) }
        }
    }
}

extension CGSize {
    /// The larger of the two sizes in each dimension.
    public func grown(to other: CGSize) -> CGSize {
        CGSize(width: max(width, other.width), height: max(height, other.height))
    }
}

extension CGRect {
    /// Every edge within `tolerance` points of the other rect's.
    public func isClose(to other: CGRect, within tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
            abs(maxX - other.maxX) <= tolerance && abs(maxY - other.maxY) <= tolerance
    }
}
