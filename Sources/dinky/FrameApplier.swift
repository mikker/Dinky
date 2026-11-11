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
    private var elements: [Key: AXUIElement] = [:]
    /// Windows written but not read back, already logged, so a window that stays unreadable is logged once.
    private var unreadable: Set<WindowID> = []
    /// The largest minimum size any window of an app has shown, by bundle id. Kept across sessions in
    /// Application Support, so the write-settle-retry chain that discovers a minimum runs once per app ever.
    private var appMinimums: [String: CGSize] = [:]
    private let raiseQueue = DispatchQueue(label: "dinky.frames.raise")
    /// A pass's raise waits for its slowest app, so a newer pass can raise first; the older one is then skipped.
    private let passes = LatestPasses()
    private let writes = FrameWrites()
    private let minimumsURL: URL

    init(supportURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dinky")) {
        minimumsURL = supportURL.appendingPathComponent("learned-minimum-sizes.json")
        // Saved before minimums needed two different sizes asked: Terminal's grid could pass for one there.
        try? FileManager.default.removeItem(at: supportURL.appendingPathComponent("minimum-sizes.json"))
        appMinimums = loadMinimums()
        scheduler = FrameScheduler(
            beforeBatch: { pid in Self.suppressEnhancedUI(pid) },
            read: { [unowned self] job in withElement(pid: job.pid, id: job.id, frame) ?? nil },
            write: { [unowned self] job in
                guard let permit = writes.permit else { return }
                withElement(pid: job.pid, id: job.id) { write(job.frame, to: $0, permit: permit) }
            },
            move: { [unowned self] job in
                guard let permit = writes.permit else { return }
                withElement(pid: job.pid, id: job.id) { move(job.frame.origin, to: $0, permit: permit) }
            }
        )
    }

    /// Utilities and apps can re-enable Enhanced UI, making apps animate and fight frame writes.
    /// Leave it alone when built-in assistive technology depends on it.
    private static func suppressEnhancedUI(_ pid: pid_t) {
        guard !NSWorkspace.shared.isVoiceOverEnabled, !NSWorkspace.shared.isSwitchControlEnabled else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &value) == .success,
              (value as? NSNumber)?.boolValue == true else { return }
        let error = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        print("\(stamp()) frames: pid \(pid) Enhanced UI re-enabled; disabling (error \(error.rawValue))")
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
            elements = elements.filter { $0.key.id != id }
            unreadable.remove(id)
        }
        scheduler.forget(id)
        passes.forget(id)
    }

    /// Forgets a process that quit: its elements and its queue, so a new process given the same pid starts afresh.
    func forget(pid: pid_t) {
        lock.withLock { elements = elements.filter { $0.key.pid != pid } }
        scheduler.forget(pid: pid)
    }

    /// Forgets every minimum size learned, this session's and the saved ones.
    func forgetMinimums() {
        scheduler.forgetMinimums()
        lock.withLock { appMinimums = [:] }
        try? FileManager.default.removeItem(at: minimumsURL)
    }

    /// A completion holds the permit of its pass, so canceled readbacks cannot revive an old layout.
    var permit: Int? { writes.permit }
    func allows(_ permit: Int) -> Bool { writes.allows(permit) }

    /// One lifecycle decision for the shared layout/restoration writer. Disabling invalidates automatic work
    /// and permits intentional restoration; enabled overview rejects all new layout work. Calls already
    /// admitted may finish, but no old frame, completion or raise permit revives across a transition.
    func updateLayoutState(enabled: Bool, overview: Bool) {
        let state: FrameWrites.State = !enabled ? .restoration : overview ? .overview : .layout
        if writes.transition(to: state) { scheduler.cancel() }
    }

    /// Writes one step of an animation: no readback, no retry, no raising.
    func step(_ jobs: [FrameJob]) {
        guard writes.permit != nil else { return }
        scheduler.step(jobs)
    }

    /// Write every frame in `layout`, then raise overlapping windows into the layout's order if they are not,
    /// unless that would move focus away from a window other than `front`, the one the layout puts on top.
    /// `completion` runs on a background queue with the readback of every app touched, once written: it does
    /// not wait for the raises, which queue behind earlier passes' and can block on a hung app for seconds.
    /// `progress` gets each app's readback as soon as that app is done, also on a background queue, so a caller
    /// that stops waiting for a hung app still has the others.
    func apply(_ layout: Layout, pids: [WindowID: pid_t], front: WindowID? = nil,
               progress: @escaping FrameScheduler.Completion = { _ in }, completion: @escaping ([FrameResult]) -> Void) {
        guard let permit = writes.permit else { completion([]); return }
        let jobs = layout.order.compactMap { id in
            pids[id].map { FrameJob(pid: $0, id: id, frame: layout.frames[id]!) }
        }
        let pass = passes.begin(layout.order)
        scheduler.submit(jobs, progress: progress) { [unowned self] results in
            rememberAppMinimums(results)
            logUnreadable(results)
            // A window that could not be read back is not raised: each lookup of it would block the raise queue
            // for a second.
            let unreadable = results.unreadable
            raiseIntoOrder(layout, pids: pids.filter { !unreadable.contains($0.key) }, front: front,
                           pass: pass, permit: permit)
            completion(results)
        }
    }

    /// Raise overlapping windows into the layout's order if they are not, as `apply` does after writing. Skipped
    /// when a newer pass includes any of the layout's windows, or overview/cancellation interrupted it.
    func raiseIntoOrder(_ layout: Layout, pids: [WindowID: pid_t], front: WindowID?) {
        guard let permit = writes.permit else { return }
        raiseIntoOrder(layout, pids: pids, front: front, pass: passes.begin(layout.order), permit: permit)
    }

    private func raiseIntoOrder(_ layout: Layout, pids: [WindowID: pid_t], front: WindowID?, pass: Int, permit: Int) {
        raiseQueue.async { [passes] in
            guard self.writes.allows(permit), passes.isLatest(pass, for: layout.order) else { return }
            var ids = layout.raises(current: onScreenOrder())
            // Raising makes a window its app's key window, so the front window goes last when its app had another
            // raised: it overlaps nothing (a column in view of a scrolling strip) and would lose focus otherwise.
            if let front, ids.last != front, let pid = pids[front], ids.contains(where: { pids[$0] == pid }) {
                ids = ids.filter { $0 != front } + [front]
            }
            if Self.raisingKeepsFocus(ids, front: front, pids: pids) { self.raise(ids, pids: pids, permit: permit) }
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

    private func loadMinimums() -> [String: CGSize] {
        guard let data = try? Data(contentsOf: minimumsURL),
              let raw = try? JSONDecoder().decode([String: [CGFloat]].self, from: data) else { return [:] }
        return raw.compactMapValues { $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil }
    }

    private func saveMinimums() {
        let raw = lock.withLock { appMinimums.mapValues { [$0.width, $0.height] } }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? FileManager.default.createDirectory(at: minimumsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: minimumsURL, options: .atomic)
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

    /// A pass can outlive native minimization: AXRaise would undo it, even before WindowServer updates its tags.
    static func mayRaise(minimized: Bool?) -> Bool { minimized != true }

    /// Raise back to front, so the last raised ends up frontmost. AXRaise does not activate the app.
    private func raise(_ ids: [WindowID], pids: [WindowID: pid_t], permit: Int) {
        for id in ids {
            guard writes.allows(permit) else { return }
            guard let pid = pids[id] else { continue }
            withElement(pid: pid, id: id) { element in
                guard self.writes.allows(permit) else { return AXError.success }
                var minimized: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
                if error == .invalidUIElement { return error }
                let isMinimized = error == .success ? (minimized as? NSNumber)?.boolValue : nil
                guard Self.mayRaise(minimized: isMinimized) else { return .success }
                return AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            }
        }
    }

    /// The window's Accessibility title, nil when it has no element or the app does not answer. Through the cached
    /// element, so a window laid out on another Space still answers, which a fresh lookup there would not.
    func title(pid: pid_t, id: WindowID) -> String? {
        withElement(pid: pid, id: id) { element -> (String?, AXError) in
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
            return (value as? String, error)
        } ?? nil
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
    private func write(_ frame: CGRect, to element: AXUIElement, permit: Int) -> AXError {
        var size = frame.size, origin = frame.origin
        let sizeValue = AXValueCreate(.cgSize, &size)!, originValue = AXValueCreate(.cgPoint, &origin)!
        for (attribute, value) in [(kAXSizeAttribute, sizeValue), (kAXPositionAttribute, originValue), (kAXSizeAttribute, sizeValue)] {
            guard writes.allows(permit) else { return .success }
            let error = AXUIElementSetAttributeValue(element, attribute as CFString, value)
            if error == .invalidUIElement { return error }
        }
        return .success
    }

    private func move(_ origin: CGPoint, to element: AXUIElement, permit: Int) -> AXError {
        guard writes.allows(permit) else { return .success }
        var origin = origin
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
    }

    private func frame(_ element: AXUIElement) -> (CGRect?, AXError) {
        var origin = CGPoint.zero, size = CGSize.zero
        // One variable per copy: a second copy into the same one overwrites the first without releasing it.
        var position: CFTypeRef?, extent: CFTypeRef?
        var error = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
        guard error == .success, AXValueGetValue(position as! AXValue, .cgPoint, &origin) else { return (nil, error) }
        error = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &extent)
        guard error == .success, AXValueGetValue(extent as! AXValue, .cgSize, &size) else { return (nil, error) }
        return (CGRect(origin: origin, size: size), .success)
    }
}

/// On-screen windows, front to back.
func onScreenOrder() -> [WindowID] {
    let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return info.compactMap { $0[kCGWindowNumber as String] as? WindowID }
}
