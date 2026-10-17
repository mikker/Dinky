import AppKit
import DinkyConfig
import DinkyPrivate

// din-nt98: focus borders. One BorderWindow per document window on a visible Space; the
// focused window's border gets the active colour, the rest the inactive one (JankyBorders'
// behaviour).
//
// The owner feeds it the WindowModel's events through handle(_:). Events only record what needs doing;
// one flush per run-loop turn does it, in a fixed order: the focus check first, so every border is drawn
// with the current focus, then the borders of the windows that changed (or all of them).
final class BorderManager {
    private var config: Borders
    private let model: WindowModel
    private var borders: [UInt32: BorderWindow] = [:]
    private(set) var focusedID: UInt32 = 0
    private(set) var visibleSpaces: Set<UInt64> = []
    private let focusedWindow: () -> UInt32
    /// What the next flush does: check focus, place every border, or place the borders of these windows and move
    /// those of windows that only moved.
    private var pending = (refocus: false, all: false, ids: Set<UInt32>(), moved: Set<UInt32>())
    private var flushScheduled = false
    private var refocusScheduled = false
    /// Whether dinky is animating the window, when its border only follows moves: redrawing it at every
    /// size of a resize costs more than a frame.
    private let isAnimating: (UInt32) -> Bool

    init(config: Borders, model: WindowModel, displays: [Display], isAnimating: @escaping (UInt32) -> Bool,
         focusedWindow: @escaping () -> UInt32 = dinky_border_focused_window) {
        self.config = config
        self.model = model
        self.isAnimating = isAnimating
        self.focusedWindow = focusedWindow
        visibleSpaces = Self.visibleSpaces(on: displays)
        focusedID = focusedWindow()
        syncAll()
    }

    /// Every display-model update counts, including NSWorkspace notifications and the fallback poll.
    func spacesChanged(_ displays: [Display]) {
        let fresh = Self.visibleSpaces(on: displays)
        guard fresh != visibleSpaces else { return }
        visibleSpaces = fresh
        pending.refocus = true
        pending.all = true
        scheduleFlush()
        scheduleRefocus()
    }

    func update(config: Borders) {
        guard config != self.config else { return }
        self.config = config
        syncAll()
    }

    /// Whether a window id is one of the border windows dinky draws.
    func isBorder(_ id: UInt32) -> Bool { borders.values.contains { $0.id == id } }

    func handle(_ event: WindowEvent) {
        switch event.kind {
        case .spaceChange, .spaceCreated, .spaceDestroyed:
            pending.refocus = true
            pending.all = true
        case .frontApp:
            pending.refocus = true
            // The new app's front window can settle a few ms after the app (JankyBorders waits 20 ms).
            scheduleRefocus()
        case .windowReorder:
            pending.refocus = true
            // A click between one app's windows can report the previous one in front for a few ms.
            scheduleRefocus()
        case .windowUpdate, .windowCreate, .windowDestroy, .windowTitle:
            pending.refocus = true
        default:
            break
        }

        if let window = event.window {
            if event.change == .removed {
                // Released now, not at the flush: WindowServer can reuse the id before then.
                borders[window.id] = nil
            } else if event.kind == .windowReorder {
                // A border is ordered next to its target once, so a window raised later lands on top of every
                // border below it: an app's activation, or the accordion raising its other windows, buries the
                // focused border under the windows raised after it. So any reorder places every border again.
                pending.all = true
            } else if event.kind == .windowMove {
                // A window being dragged or animated moves every frame, and its border only needs moving along,
                // once for all the moves of one turn.
                pending.moved.insert(window.id)
            } else {
                // A window being animated or resized sends a resize every frame, and placing its border is a
                // WindowServer round trip, so the events of one turn share one placement.
                pending.ids.insert(window.id)
            }
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    private func scheduleRefocus() {
        guard !refocusScheduled else { return }
        refocusScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
            guard let self else { return }
            refocusScheduled = false
            refocus()
        }
    }

    /// Does what the events since the last flush asked for: focus first, then the borders.
    private func flush() {
        let work = pending
        pending = (refocus: false, all: false, ids: [], moved: [])
        flushScheduled = false
        if work.refocus { refocus() }
        if work.all { syncAll() } else { sync(work.ids); follow(work.moved.subtracting(work.ids)) }
    }

    /// Borders of windows that only moved follow them. One that needs more than a move is placed in full.
    private func follow(_ ids: Set<UInt32>) {
        for id in ids {
            guard let window = model.windows[id] else { continue }
            if borders[id]?.follow(window) != true { sync(window) }
        }
    }

    /// Windows that finished animating: their borders catch up with any size they skipped.
    func arrived(_ ids: [UInt32]) { sync(ids) }

    private func sync<S: Sequence<UInt32>>(_ ids: S) {
        for id in ids { if let window = model.windows[id] { sync(window) } }
    }

    /// Mission Control came or went: every border hides or returns.
    func missionControlChanged() { syncAll() }

    private func syncAll() {
        for id in borders.keys where model.windows[id] == nil { borders[id] = nil }
        for window in model.windows.values { sync(window) }
    }

    private func sync(_ window: Window) {
        guard config.enabled, window.isDocument, config.decorates(bundleID: window.bundleID) else {
            borders[window.id] = nil
            return
        }
        // Minimized windows land here too (they are still documents, just not visible), so the border hides.
        guard window.isOrderedIn, window.isVisible, !window.isMinimized, visibleSpaces.contains(window.spaceID), !MissionControl.shared.active else {
            borders[window.id]?.hide()
            return
        }
        let focused = window.id == focusedID
        let border = borders[window.id] ?? BorderWindow(target: window.id)
        borders[window.id] = border
        border.update(window, color: focused ? config.activeColor : config.inactiveColor, config: config,
                      moveOnly: isAnimating(window.id))
    }

    private func refocus() {
        let id = focusedWindow()
        guard id != focusedID else { return }
        let old = focusedID
        focusedID = id
        for id in [old, id] {
            if let window = model.windows[id] { sync(window) }
        }
    }

    // The current Space of every display, full-screen Spaces left out.
    private static func visibleSpaces(on displays: [Display]) -> Set<UInt64> {
        Set(displays.compactMap { $0.userSpaces.contains($0.currentSpaceID) ? $0.currentSpaceID : nil })
    }
}
