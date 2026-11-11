import AppKit
import DinkyPrivate

// A window as WindowServer sees it. Identity includes the owner pid and when dinky first saw
// the window, so a window ID reused by WindowServer is never mistaken for the old window.
struct Window {
    struct Identity: Hashable {
        let id: UInt32
        let pid: pid_t
        let firstSeen: Date  // model start for windows that existed before it
    }

    let identity: Identity
    let appName: String?
    let bundleID: String?
    var frame: CGRect = .zero
    var level = 0
    var spaceID: UInt64 = 0
    var isOrderedIn = false
    var isDocument = false
    var isVisible = false
    var isMinimized = false
    var cornerRadius = 0

    var id: UInt32 { identity.id }
    var pid: pid_t { identity.pid }

    // Tileable: normal layer, on screen, visible (not minimized), a document window rather than a sheet,
    // panel or popup.
    var isNormal: Bool { level == 0 && isOrderedIn && isVisible && isDocument }
}

struct WindowEvent {
    enum Change { case added, removed, updated, none }

    let kind: DinkyEventKind
    let change: Change
    let window: Window?  // after the change; last known state for .removed
    let pid: pid_t       // window owner, or the new front app for .frontApp
    let spaceID: UInt64  // from the payload, when it carries one
    let time: Date
}

// The window table, seeded from WindowServer and kept current by its notifications.
// Main thread only: SkyLight's callbacks are hopped to the main queue before they touch it.
final class WindowModel {
    private(set) var windows: [UInt32: Window] = [:]
    /// When the table was seeded. Windows first seen after it were created while dinky ran.
    private(set) var seededAt = Date.distantFuture
    private var observers: [(WindowEvent) -> Void] = []
    /// Windows that moved lately, by the full re-read each gets once it has been still for a moment. See `moved`.
    private var settling: [UInt32: DispatchWorkItem] = [:]

    private let ownPID = getpid()

    /// Subscribes to the shared WindowServer stream and seeds the table. False if WindowServer refused.
    /// Call once.
    func start() -> Bool {
        guard EventHub.shared.subscribe({ [weak self] event in self?.handle(event) }) else { return false }
        seed()
        return true
    }

    /// Calls `handler` with every change once the model has taken it in, in the order observers were added.
    func observe(_ handler: @escaping (WindowEvent) -> Void) {
        observers.append(handler)
    }

    // Sanity pass for callers that suspect drift: drops windows that no longer exist,
    // adds any the events missed, refreshes the rest. Publishes what changed.
    func reconcile() {
        for window in windows.values where !dinky_window_info(window.id).exists {
            remove(window.id, kind: .windowDestroy)
        }
        reconcile(dinky_all_window_ids().map(\.uint32Value))
    }

    /// The sanity pass for some windows only: adds those the events missed, refreshes the rest and drops those that
    /// no longer exist. Publishes what changed.
    func reconcile(_ ids: [UInt32]) {
        for id in ids {
            if windows[id] == nil {
                add(id, spaceID: 0, kind: .windowCreate)
            } else {
                refresh(id, kind: .windowUpdate)
            }
        }
    }

    private func seed() {
        let now = Date()
        seededAt = now
        for id in dinky_all_window_ids().map(\.uint32Value) {
            if let window = makeWindow(id, spaceID: 0, firstSeen: now) { windows[id] = window }
        }
        watch()
    }

    private func handle(_ event: DinkyEvent) {
        let id = event.windowID
        switch event.kind {
        case .windowCreate:
            // A reused ID from another process is a new window.
            if let old = windows[id], old.pid != event.pid { remove(id, kind: .windowDestroy) }
            if windows[id] == nil {
                add(id, spaceID: event.spaceID, kind: event.kind, pid: event.pid)
            } else {
                refresh(id, kind: event.kind)
            }
        case .windowDestroy:
            // JankyBorders treats 1326 as "left this Space"; the window may still exist elsewhere.
            if dinky_window_info(id).exists { refresh(id, kind: event.kind) } else { remove(id, kind: event.kind, pid: event.pid) }
        case .windowClose:
            remove(id, kind: event.kind, pid: event.pid)
        case .spaceChange, .spaceCreated, .spaceDestroyed, .frontApp:
            publish(event.kind, .none, nil, pid: event.pid, spaceID: event.spaceID)
        case .windowMove where windows[id] != nil:
            moved(id)
        default:
            if windows[id] != nil {
                refresh(id, kind: event.kind)
            } else {
                publish(event.kind, .none, nil, pid: event.pid)
            }
        }
    }

    // `pid` is the raw event's, published when the window is not one the model keeps.
    private func add(_ id: UInt32, spaceID: UInt64, kind: DinkyEventKind, pid: pid_t = 0) {
        guard let window = makeWindow(id, spaceID: spaceID, firstSeen: Date()) else {
            publish(kind, .none, nil, pid: pid, spaceID: spaceID)
            return
        }
        windows[id] = window
        watch()
        publish(kind, .added, window, pid: window.pid, spaceID: spaceID)
    }

    // `pid` is the raw event's, published when the model did not know the window.
    private func remove(_ id: UInt32, kind: DinkyEventKind, pid: pid_t = 0) {
        settling.removeValue(forKey: id)?.cancel()
        guard let window = windows.removeValue(forKey: id) else {
            publish(kind, .none, nil, pid: pid)
            return
        }
        watch()
        publish(kind, .removed, window, pid: window.pid)
    }

    /// Re-reads a known window, its Space included, and publishes it as updated (or removed, if it is gone).
    /// Does nothing for a window the model does not know.
    func refresh(_ id: UInt32, kind: DinkyEventKind = .windowUpdate) {
        // Any full read supersedes the one waiting for the window to settle.
        settling.removeValue(forKey: id)?.cancel()
        guard var window = windows[id] else { return }
        let info = dinky_window_info(id)
        guard info.exists else { return remove(id, kind: kind) }
        apply(info, to: &window)
        window.spaceID = dinky_window_space_id(id)
        windows[id] = window
        publish(kind, .updated, window, pid: window.pid)
    }

    /// A move comes on every frame of a drag or a glide, so it reads only the frame. The full re-read waits until the
    /// window has been still for a moment, for whatever changed along with it, such as its Space when it is dropped
    /// on another display.
    private func moved(_ id: UInt32) {
        guard var window = windows[id] else { return }
        let frame = dinky_window_frame(id)
        guard !frame.isNull else { return refresh(id, kind: .windowMove) }
        window.frame = frame
        windows[id] = window
        publish(.windowMove, .updated, window, pid: window.pid)
        settling[id]?.cancel()
        let settle = DispatchWorkItem { [weak self] in self?.refresh(id) }
        settling[id] = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: settle)
    }

    // nil for dinky's own windows, windows that are already gone and child windows.
    private func makeWindow(_ id: UInt32, spaceID: UInt64, firstSeen: Date) -> Window? {
        let info = dinky_window_info(id)
        guard info.exists, info.pid != 0, info.pid != ownPID, info.parentID == 0 else { return nil }
        let app = NSRunningApplication(processIdentifier: info.pid)
        var window = Window(
            identity: .init(id: id, pid: info.pid, firstSeen: firstSeen),
            appName: app?.localizedName,
            bundleID: app?.bundleIdentifier
        )
        apply(info, to: &window)
        window.spaceID = spaceID != 0 ? spaceID : dinky_window_space_id(id)
        return window
    }

    private func apply(_ info: DinkyWindowInfo, to window: inout Window) {
        window.frame = info.frame
        window.level = Int(info.level)
        window.isOrderedIn = info.isOrderedIn
        window.isDocument = info.isDocument
        window.isVisible = info.isVisible
        window.isMinimized = info.isMinimized
        // Read once: SkyLight leaks a radius that is not a whole number on every read. A window that reported none
        // yet, as it may while it is still being set up, is asked again; a radius of 0 never leaks.
        if window.cornerRadius == 0 { window.cornerRadius = Int(dinky_window_corner_radius(window.id)) }
    }

    private func watch() {
        let ids = Array(windows.keys)
        dinky_events_watch_windows(ids, Int32(ids.count))
    }

    private func publish(_ kind: DinkyEventKind, _ change: WindowEvent.Change, _ window: Window?, pid: pid_t, spaceID: UInt64 = 0) {
        let event = WindowEvent(kind: kind, change: change, window: window, pid: pid, spaceID: spaceID, time: Date())
        observers.forEach { $0(event) }
    }
}
