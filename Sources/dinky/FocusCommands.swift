import AppKit
import DinkyCommands
import DinkyLayout
import DinkyPrivate

// `focus` with AeroSpace's boundaries, and `focus-monitor`. Display geometry comes from the display model;
// a display is entered at the window snapped to the edge focus comes in by.
extension Dispatcher {
    /// Focuses the neighbour in the focused window's tree. At the workspace edge, `all-monitors-outer-frame`
    /// goes on to the display in that direction; at the last edge `action` decides. A floating window, which
    /// has no tree, looks for the nearest window on screen instead.
    static func focus(_ direction: Direction, boundaries: FocusBoundaries, action: BoundariesAction) -> Reply {
        guard let coordinator = AppState.shared.coordinator,
              let found = coordinator.command({ $0.focus(direction) ? $0.focused : nil }) else {
            return focusOnScreen(direction)
        }
        if let id = found { return focus(window: id) }
        let model = AppState.shared.displays
        if boundaries == .allMonitorsOuterFrame, let from = model.display(ofWindow: coordinator.focusedWindow) {
            let line = displays(inLineWith: from, direction.orientation, model.displays)
            let index = line.firstIndex(of: from)! + (direction.isForward ? 1 : -1)
            if line.indices.contains(index) { return enter(line[index], from: direction) }
            if action == .wrapAroundAllMonitors { return enter(direction.isForward ? line[0] : line[line.count - 1], from: direction) }
        }
        switch action {
        case .stop, .wrapAroundAllMonitors:
            return .ok("no window \(direction)")
        case .fail:
            return .error("no window \(direction)")
        case .wrapAroundTheWorkspace:
            guard let id = coordinator.command({ $0.focus(direction, wrapping: true) ? $0.focused : nil }) ?? nil else {
                return .ok("no window to wrap around to")
            }
            return focus(window: id)
        }
    }

    /// Focuses a display's most recently focused window, or the display itself when it has none.
    static func focusMonitor(_ target: MonitorTarget) -> Reply {
        let model = AppState.shared.displays
        model.reconcile()
        guard let from = model.focusedDisplay() else { return .error("no display") }
        let line = target.direction.map { displays(inLineWith: from, $0.orientation, model.displays) }
            ?? model.displays.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        let forward = target.direction?.isForward ?? (target == .next)
        let index = line.firstIndex(of: from)! + (forward ? 1 : -1)
        guard line.indices.contains(index) else {
            return .error(target.direction == nil ? "no \(target.rawValue) display" : "no display \(target.rawValue) of the focused one")
        }
        return focus(line[index], window: AppState.shared.coordinator?.workspace(on: line[index])?.focused)
    }

    /// Focuses the display numbered `n` (1-based, `list-monitors` order), as `focusMonitor` does. Focusing the
    /// display that already has focus is fine, so a bar can run `focus-monitor N` before `workspace M`.
    static func focusMonitor(number n: Int) -> Reply {
        let model = AppState.shared.displays
        model.reconcile()
        guard model.displays.indices.contains(n - 1) else { return .error("no display \(n), there are \(model.displays.count)") }
        let display = model.displays[n - 1]
        return focus(display, window: AppState.shared.coordinator?.workspace(on: display)?.focused)
    }

    /// Enters a display from `direction`: the window at the edge facing where focus came from.
    private static func enter(_ display: Display, from direction: Direction) -> Reply {
        focus(display, window: AppState.shared.coordinator?.workspace(on: display)?.edgeWindow(direction.opposite))
    }

    /// Focuses `window`, or, with none, makes `display` the focused one until a window takes focus, and takes the
    /// keyboard off any window on another display.
    static func focus(_ display: Display, window: WindowID?) -> Reply {
        if let window { return focus(window: window) }
        focusDesktop(of: display)
        let model = AppState.shared.displays
        model.focusOverride = display.uuid
        return .ok("focused display \((model.displays.firstIndex(of: display) ?? 0) + 1)")
    }

    private static func focus(window id: WindowID) -> Reply {
        guard let coordinator = AppState.shared.coordinator, let window = coordinator.model.windows[id] else {
            return .error("window \(id) is gone")
        }
        coordinator.focus(id)
        return .ok("focused window \(id) \(window.appName ?? "")")
    }

    /// Displays in the same row (for a horizontal axis) or column as `from`, `from` included, ordered along it.
    private static func displays(inLineWith from: Display, _ axis: Orientation, _ all: [Display]) -> [Display] {
        let horizontal = axis == .horizontal
        return all.filter { d in
            d == from || (horizontal ? min(d.frame.maxY, from.frame.maxY) > max(d.frame.minY, from.frame.minY)
                                     : min(d.frame.maxX, from.frame.maxX) > max(d.frame.minX, from.frame.minX))
        }.sorted { horizontal ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
    }

    /// The nearest window on the current Space whose centre lies in the direction, by distance between centres.
    private static func focusOnScreen(_ direction: Direction) -> Reply {
        let model = AppState.shared.displays
        model.reconcile()
        guard let main = model.displays.first(where: \.isMain) ?? model.displays.first else { return .error("no display") }
        let onSpace = Set(dinky_space_window_ids(main.currentSpaceID, false).map(\.uint32Value))
        let windows = windowList().filter { onSpace.contains($0.id) }
        guard let front = windows.first(where: { $0.id == frontWindowID() }) else { return .error("no focused window") }
        let from = CGPoint(x: front.frame.midX, y: front.frame.midY)
        let candidates = windows.filter { w in
            let dx = w.frame.midX - from.x, dy = w.frame.midY - from.y
            switch direction {
            case .left: return dx < 0 && abs(dx) >= abs(dy)
            case .right: return dx > 0 && abs(dx) >= abs(dy)
            case .up: return dy < 0 && abs(dy) >= abs(dx)
            case .down: return dy > 0 && abs(dy) >= abs(dx)
            }
        }
        guard let next = candidates.min(by: { hypot($0.frame.midX - from.x, $0.frame.midY - from.y)
                                              < hypot($1.frame.midX - from.x, $1.frame.midY - from.y) }) else {
            return .error("no window \(direction)")
        }
        focusWindow(pid: next.pid, id: next.id)
        return .ok("focused window \(next.id) \(next.app)")
    }
}
