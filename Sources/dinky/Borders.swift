import AppKit
import DinkyConfig
import DinkyPrivate

// din-nt98: focus borders. One BorderWindow per document window on a visible Space; the
// focused window's border gets the active colour, the rest the inactive one (JankyBorders'
// behaviour).
//
// The owner feeds it the WindowModel's events through handle(_:).
final class BorderManager {
    private var config: Borders
    private let model: WindowModel
    private var borders: [UInt32: BorderWindow] = [:]
    private var focusedID: UInt32 = 0
    private var visibleSpaces: Set<UInt64> = []
    private var restackPending = false

    init(config: Borders, model: WindowModel) {
        self.config = config
        self.model = model
        refreshSpaces()
        focusedID = dinky_border_focused_window()
        syncAll()
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
            refreshSpaces()
            refocus()
            syncAll()
            return
        case .frontApp, .windowReorder:
            refocus()
            // The front window can settle after the notification, including a click between windows of one app.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in self?.refocus() }
        case .windowCreate, .windowDestroy, .windowUpdate, .windowTitle:
            refocus()
        default:
            break
        }

        guard let window = event.window else { return }
        if event.change == .removed {
            borders[window.id] = nil
        } else if event.kind == .windowReorder {
            restack()
        } else {
            sync(window)
        }
    }

    /// A border is ordered next to its target once, so a window raised later lands on top of every border
    /// below it: an app's activation, or the accordion raising its other windows, buries the focused border
    /// under the windows raised after it. So any reorder places every border again, once per run-loop turn.
    private func restack() {
        guard !restackPending else { return }
        restackPending = true
        DispatchQueue.main.async { [weak self] in
            self?.restackPending = false
            self?.syncAll()
        }
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
        guard window.isOrderedIn, !window.isMinimized, visibleSpaces.contains(window.spaceID), !MissionControl.shared.active else {
            borders[window.id]?.hide()
            return
        }
        let focused = window.id == focusedID
        let border = borders[window.id] ?? BorderWindow(target: window.id)
        borders[window.id] = border
        border.update(window, color: focused ? config.activeColor : config.inactiveColor, config: config)
    }

    private func refocus() {
        let id = dinky_border_focused_window()
        guard id != focusedID else { return }
        let old = focusedID
        focusedID = id
        for id in [old, id] {
            if let window = model.windows[id] { sync(window) }
        }
    }

    // The current Space of every display, full-screen Spaces left out.
    private func refreshSpaces() {
        visibleSpaces = Set(dinky_displays().compactMap { display in
            let current = display.spaces.first { $0.spaceID == display.currentSpaceID }
            return current?.isFullscreen == true ? nil : display.currentSpaceID
        })
    }
}
