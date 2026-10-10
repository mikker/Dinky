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
    /// The largest minimum size any window of an app has shown, by bundle id. Kept across sessions in
    /// Application Support, so the write-settle-retry chain that discovers a minimum runs once per app ever.
    private var appMinimums: [String: CGSize] = [:]
    private let raiseQueue = DispatchQueue(label: "dinky.frames.raise")
    private static let minimumsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dinky/minimum-sizes.json")

    init() {
        appMinimums = Self.loadMinimums()
        scheduler = FrameScheduler(
            prepare: { pid in
                // Enhanced UI (set by VoiceOver and some utilities) makes apps animate and fight frame writes.
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, Self.timeout)
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            },
            read: { [unowned self] job in element(pid: job.pid, id: job.id).flatMap(frame) },
            write: { [unowned self] job in element(pid: job.pid, id: job.id).map { write(job.frame, to: $0) } },
            move: { [unowned self] job in element(pid: job.pid, id: job.id).map { move(job.frame.origin, to: $0) } }
        )
    }

    /// Sizes windows refused to shrink below, from readback.
    var minimumSizes: [WindowID: CGSize] { scheduler.minimumSizes }

    /// Windows that refused a size once, waiting for another pass to confirm it.
    var unconfirmedMinimums: Set<WindowID> { scheduler.unconfirmedMinimums }

    /// The size a window refused to shrink below or, if it has refused nothing yet, the largest any window of its
    /// app has refused, so a new window of a known app is laid out right the first time.
    func minimumSize(of id: WindowID, app: String?) -> CGSize? {
        scheduler.minimumSizes[id] ?? app.flatMap { app in lock.withLock { appMinimums[app] } }
    }

    /// Forgets a window that is gone: its element and what the scheduler learned about it.
    func forget(_ id: WindowID) {
        lock.withLock { elements = elements.filter { $0.key.id != id } }
        scheduler.forget(id)
    }

    /// Forgets every minimum size learned, this session's and the saved ones.
    func forgetMinimums() {
        scheduler.forgetMinimums()
        lock.withLock { appMinimums = [:] }
        try? FileManager.default.removeItem(at: Self.minimumsURL)
    }

    /// Drops every frame not written yet.
    func cancel() { scheduler.cancel() }

    /// Writes one step of an animation: no readback, no retry, no raising.
    func step(_ jobs: [FrameJob]) { scheduler.step(jobs) }

    /// Write every frame in `layout`, then raise overlapping windows into the layout's order if they are not,
    /// unless that would move focus away from a window other than `front`, the one the layout puts on top.
    /// `completion` runs on a background queue with the readback of every app touched.
    func apply(_ layout: Layout, pids: [WindowID: pid_t], front: WindowID? = nil, raiseWindows: Bool = true,
               completion: @escaping ([FrameResult]) -> Void = { _ in }) {
        let jobs = layout.order.compactMap { id in
            pids[id].map { FrameJob(pid: $0, id: id, frame: layout.frames[id]!) }
        }
        scheduler.submit(jobs) { [unowned self] results in
            rememberAppMinimums(results)
            if raiseWindows {
                raiseIntoOrder(layout, pids: pids, front: front) { completion(results) }
            } else {
                completion(results)
            }
        }
    }

    /// Raise overlapping windows into the layout's order if they are not, as `apply` does after writing.
    func raiseIntoOrder(_ layout: Layout, pids: [WindowID: pid_t], front: WindowID?, then done: @escaping () -> Void = {}) {
        raiseQueue.async {
            let ids = layout.raises(current: onScreenOrder())
            if Self.raisingKeepsFocus(ids, front: front, pids: pids) { self.raise(ids, pids: pids) }
            done()
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
    private func raise(_ ids: [WindowID], pids: [WindowID: pid_t]) {
        for id in ids {
            guard let pid = pids[id], let element = element(pid: pid, id: id) else { continue }
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
    }

    private func element(pid: pid_t, id: WindowID) -> AXUIElement? {
        let key = Key(pid: pid, id: id)
        if let cached = lock.withLock({ elements[key] }) { return cached }
        guard let element = axWindow(pid: pid, wid: id, timeout: Self.timeout) else { return nil }
        lock.withLock { elements[key] = element }
        return element
    }

    // Size, position, size: the first size lets a window near the screen edge move, the second
    // fixes the size if the move clamped it.
    private func write(_ frame: CGRect, to element: AXUIElement) {
        var size = frame.size, origin = frame.origin
        let sizeValue = AXValueCreate(.cgSize, &size)!, originValue = AXValueCreate(.cgPoint, &origin)!
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, originValue)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
    }

    private func move(_ origin: CGPoint, to element: AXUIElement) {
        var origin = origin
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              AXValueGetValue(value as! AXValue, .cgPoint, &origin),
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

/// On-screen windows, front to back.
func onScreenOrder() -> [WindowID] {
    let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return info.compactMap { $0[kCGWindowNumber as String] as? WindowID }
}
