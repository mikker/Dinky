import AppKit
import DinkyLayout
import DinkyPrivate

// Applies a layout through Accessibility. Scheduling (a queue per app, newest frame wins, one retry)
// lives in FrameScheduler; this file is only the AX side: element lookup, writes, readback, raises.
final class FrameApplier {
    /// A window by its owner too: window ids are reused, so an id alone can name another app's window.
    private struct Key: Hashable {
        let pid: pid_t
        let id: WindowID
    }

    /// How long one AX call to an app may block before giving up, so a hung app only stalls its own queue.
    static let timeout: Float = 1

    private var scheduler: FrameScheduler!
    private let lock = NSLock()
    private var generation = 0
    private var nextPass = 0
    private var passes: [WindowID: Int] = [:]

    private struct Pass {
        let generation: Int
        let revision: Int
        let ids: [WindowID]
    }
    private var elements: [Key: AXUIElement] = [:]
    /// Windows written but not read back, already logged, so a window that stays unreadable is logged once.
    private var unreadable: Set<WindowID> = []
    /// The largest minimum size any window of an app has shown, by bundle id. Kept across sessions in
    /// Application Support, so the write-settle-retry chain that discovers a minimum runs once per app ever.
    private var appMinimums: [String: CGSize] = [:]
    private let raiseQueue = DispatchQueue(label: "dinky.frames.raise")
    private static let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dinky")
    private static let minimumsURL = supportURL.appendingPathComponent("learned-minimum-sizes.json")

    init() {
        // Saved before minimums needed two different sizes asked: Terminal's grid could pass for one there.
        try? FileManager.default.removeItem(at: Self.supportURL.appendingPathComponent("minimum-sizes.json"))
        appMinimums = Self.loadMinimums()
        scheduler = FrameScheduler(
            prepare: { pid in
                // Enhanced UI (set by VoiceOver and some utilities) makes apps animate and fight frame writes.
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, Self.timeout)
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            },
            read: { [unowned self] job in withElement(pid: job.pid, id: job.id, frame) ?? nil },
            write: { [unowned self] job, live in
                guard live() else { return }
                withElement(pid: job.pid, id: job.id) { write(job.frame, to: $0, live: live) }
            },
            move: { [unowned self] job, live in
                guard live() else { return }
                withElement(pid: job.pid, id: job.id) {
                    guard live() else { return .success }
                    return move(job.frame.origin, to: $0)
                }
            }
        )
    }

    /// Sizes windows refused to shrink below, from readback.
    var minimumSizes: [WindowID: CGSize] { scheduler.minimumSizes }

    /// The size a window refused to shrink below or, if it has refused nothing yet, the largest any window of its
    /// app has refused, so a new window of a known app is laid out right the first time.
    func minimumSize(of id: WindowID, app: String?) -> CGSize? {
        scheduler.minimumSizes[id] ?? app.flatMap { app in lock.withLock { appMinimums[app] } }
    }

    /// Forgets a window that is gone: its element and what the scheduler learned about it.
    func forget(_ id: WindowID) {
        lock.withLock {
            passes[id] = nil
            elements = elements.filter { $0.key.id != id }
            unreadable.remove(id)
        }
        scheduler.forget(id)
    }

    /// Forgets every minimum size learned, this session's and the saved ones.
    func forgetMinimums() {
        scheduler.forgetMinimums()
        lock.withLock { appMinimums = [:] }
        try? FileManager.default.removeItem(at: Self.minimumsURL)
    }

    /// Drops every frame not written yet.
    func cancel() {
        lock.withLock { generation += 1; passes.removeAll() }
        scheduler.cancel()
    }

    func isCurrent(_ results: [FrameResult]) -> Bool { scheduler.isCurrent(results) }

    private func begin(_ layout: Layout) -> Pass {
        lock.withLock {
            nextPass += 1
            for id in layout.order { passes[id] = nextPass }
            return Pass(generation: generation, revision: nextPass, ids: layout.order)
        }
    }

    private func isCurrent(_ pass: Pass) -> Bool {
        lock.withLock { generation == pass.generation && pass.ids.allSatisfy { passes[$0] == pass.revision } }
    }

    /// Writes one step of an animation: no readback, no retry, no raising.
    func step(_ jobs: [FrameJob]) { scheduler.step(jobs) }

    /// Write every frame in `layout`, then raise overlapping windows into the layout's order if they are not,
    /// unless that would move focus away from a window other than `front`, the one the layout puts on top.
    /// `completion` runs on a background queue with the readback of every app touched.
    func apply(_ layout: Layout, pids: [WindowID: pid_t], front: WindowID? = nil,
               completion: @escaping ([FrameResult]) -> Void = { _ in }) {
        let pass = begin(layout)
        let jobs = layout.order.compactMap { id in
            pids[id].map { FrameJob(pid: $0, id: id, frame: layout.frames[id]!) }
        }
        let ids = Set(jobs.map(\.id))
        scheduler.submit(jobs) { [unowned self] results in
            // One app queue may coalesce writes from independent layouts on different displays.
            let results = results.filter { ids.contains($0.job.id) }
            guard isCurrent(pass), results.count == jobs.count, isCurrent(results) else { completion([]); return }
            rememberAppMinimums(results)
            logUnreadable(results)
            raiseIntoOrder(layout, pids: pids, front: front, pass: pass) {
                completion(self.isCurrent(pass) && self.isCurrent(results) ? results : [])
            }
        }
    }

    /// Raise overlapping windows into the layout's order if they are not, as `apply` does after writing.
    func raiseIntoOrder(_ layout: Layout, pids: [WindowID: pid_t], front: WindowID?, then done: @escaping () -> Void = {}) {
        raiseIntoOrder(layout, pids: pids, front: front, pass: begin(layout), then: done)
    }

    private func raiseIntoOrder(_ layout: Layout, pids: [WindowID: pid_t], front: WindowID?, pass: Pass,
                                then done: @escaping () -> Void) {
        raiseQueue.async {
            defer { done() }
            guard self.isCurrent(pass) else { return }
            var ids = layout.raises(current: onScreenOrder())
            // Raising makes a window its app's key window, so the front window goes last when its app had another
            // raised: it overlaps nothing (a column in view of a scrolling strip) and would lose focus otherwise.
            if let front, ids.last != front, let pid = pids[front], ids.contains(where: { pids[$0] == pid }) {
                ids = ids.filter { $0 != front } + [front]
            }
            if Self.raisingKeepsFocus(ids, front: front, pids: pids) { self.raise(ids, pids: pids, pass: pass) }
        }
    }

    /// Minimums are recorded after a retry; note each new one under its app.
    private func rememberAppMinimums(_ results: [FrameResult]) {
        let retried = results.filter(\.retried)
        guard !retried.isEmpty else { return }
        let minimums = scheduler.minimumSizes
        var changed = false
        for result in retried {
            guard let minimum = minimums[result.job.id],
                  let app = NSRunningApplication(processIdentifier: result.job.pid)?.bundleIdentifier else { continue }
            lock.withLock {
                let grown = appMinimums[app]?.grown(to: minimum) ?? minimum
                if appMinimums[app] != grown { appMinimums[app] = grown; changed = true }
            }
        }
        if changed { saveMinimums() }
    }

    /// The scheduler gives up on a window it wrote but cannot read back, so say so, once per window until it answers.
    private func logUnreadable(_ results: [FrameResult]) {
        let fresh = lock.withLock {
            unreadable.subtract(results.filter { $0.got != nil }.map(\.job.id))
            return results.filter { $0.written && $0.got == nil && unreadable.insert($0.job.id).inserted }
        }
        for result in fresh {
            print("\(stamp()) frames: wrote window \(result.job.id) of pid \(result.job.pid) but could not read it back, not retrying")
        }
    }

    private static func loadMinimums() -> [String: CGSize] {
        guard let data = try? Data(contentsOf: minimumsURL),
              let raw = try? JSONDecoder().decode([String: [CGFloat]].self, from: data) else { return [:] }
        return raw.compactMapValues { $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil }
    }

    private func saveMinimums() {
        let raw = lock.withLock { appMinimums.mapValues { [$0.width, $0.height] } }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? FileManager.default.createDirectory(at: Self.minimumsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.minimumsURL, options: .atomic)
    }

    /// Raising a window of the frontmost app makes it that app's key window. So windows are raised only when
    /// that cannot move focus: the focused window is the layout's front one, or its app owns none of them.
    /// Otherwise the layout is older than the focus, say right after Cmd-` or while a pass that started before
    /// a newer one finishes, and raising would take focus back. The next pass raises once the tree has caught up.
    private static func raisingKeepsFocus(_ ids: [WindowID], front: WindowID?, pids: [WindowID: pid_t]) -> Bool {
        let focused = dinky_border_focused_window()
        guard focused != 0, focused != front else { return true }
        let owner = dinky_window_info(focused).pid
        return !ids.contains { pids[$0] == owner }
    }

    /// Raise back to front, so the last raised ends up frontmost. AXRaise does not activate the app.
    private func raise(_ ids: [WindowID], pids: [WindowID: pid_t], pass: Pass) {
        for id in ids {
            guard isCurrent(pass) else { return }
            guard let pid = pids[id] else { continue }
            withElement(pid: pid, id: id) {
                guard self.isCurrent(pass) else { return .success }
                return AXUIElementPerformAction($0, kAXRaiseAction as CFString)
            }
        }
    }

    /// Runs `body` on the window's element, cached by window. An app can replace a window's element while the
    /// window lives on, same id and all: Slack hides its window on close and hands out a new element when it is
    /// reopened. So when the app calls the cached element invalid, it is looked up again and `body` runs once more.
    /// Nil when the window has no element.
    @discardableResult
    private func withElement<T>(pid: pid_t, id: WindowID, _ body: (AXUIElement) -> (T, AXError)) -> T? {
        let key = Key(pid: pid, id: id)
        let cached = lock.withLock { elements[key] }
        guard let element = cached ?? lookUp(key) else { return nil }
        let (value, error) = body(element)
        guard error == .invalidUIElement, cached != nil else { return value }
        guard let fresh = lookUp(key) else {
            print("\(stamp()) frames: window \(id) of pid \(pid) no longer has an Accessibility element")
            return nil
        }
        return body(fresh).0
    }

    /// `withElement` for a call that only reports its error.
    private func withElement(pid: pid_t, id: WindowID, _ body: (AXUIElement) -> AXError) {
        withElement(pid: pid, id: id) { ((), body($0)) }
    }

    /// Looks the window up and caches what it finds, so a failed lookup also drops a stale element.
    private func lookUp(_ key: Key) -> AXUIElement? {
        let element = axWindow(pid: key.pid, wid: key.id, timeout: Self.timeout)
        lock.withLock { elements[key] = element }
        return element
    }

    // Size, position, size: the first size lets a window near the screen edge move, the second
    // fixes the size if the move clamped it. Stops at an invalid element, which takes no writes.
    private func write(_ frame: CGRect, to element: AXUIElement, live: () -> Bool) -> AXError {
        var size = frame.size, origin = frame.origin
        let sizeValue = AXValueCreate(.cgSize, &size)!, originValue = AXValueCreate(.cgPoint, &origin)!
        for (attribute, value) in [(kAXSizeAttribute, sizeValue), (kAXPositionAttribute, originValue), (kAXSizeAttribute, sizeValue)] {
            guard live() else { return .success }
            let error = AXUIElementSetAttributeValue(element, attribute as CFString, value)
            if error == .invalidUIElement { return error }
        }
        return .success
    }

    private func move(_ origin: CGPoint, to element: AXUIElement) -> AXError {
        var origin = origin
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
    }

    private func frame(_ element: AXUIElement) -> (CGRect?, AXError) {
        var origin = CGPoint.zero, size = CGSize.zero
        var value: CFTypeRef?
        var error = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
        guard error == .success, AXValueGetValue(value as! AXValue, .cgPoint, &origin) else { return (nil, error) }
        error = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
        guard error == .success, AXValueGetValue(value as! AXValue, .cgSize, &size) else { return (nil, error) }
        return (CGRect(origin: origin, size: size), .success)
    }
}

/// On-screen windows, front to back.
func onScreenOrder() -> [WindowID] {
    let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return info.compactMap { $0[kCGWindowNumber as String] as? WindowID }
}
