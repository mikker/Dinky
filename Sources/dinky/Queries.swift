import AppKit
import DinkyCommands
import DinkyLayout
import DinkyPrivate

// The list-* queries, and the window list they and the dispatcher share. Flags and output follow
// AeroSpace's; the format rendering lives in DinkyCommands. Monitor ids are 1-based display indices
// in the display model's order, workspaces are numbered across displays.

struct WindowInfo {
    let id: UInt32
    let pid: pid_t
    let app: String
    let title: String
    /// Global coordinates, top-left origin.
    let frame: CGRect
}

/// Normal windows on any Space, front to back, filtered like the spike's `ls`. dinky's own (borders) are left out,
/// and so are windows their app has ordered out, such as a settings window closed with Cmd-W that the app keeps
/// around hidden: WindowServer still lists those, on the Space they were last shown on.
func windowList() -> [WindowInfo] {
    let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.compactMap { w in
        let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let window = WindowInfo(
            id: w[kCGWindowNumber as String] as? UInt32 ?? 0,
            pid: w[kCGWindowOwnerPID as String] as? pid_t ?? 0,
            app: w[kCGWindowOwnerName as String] as? String ?? "",
            title: w[kCGWindowName as String] as? String ?? "",
            frame: CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0))
        guard w[kCGWindowLayer as String] as? Int == 0, (w[kCGWindowAlpha as String] as? Double ?? 0) > 0,
              window.app != "Dock", window.app != "WindowServer", window.pid != getpid(),
              !window.title.isEmpty || (window.frame.width > 40 && window.frame.height > 40),
              dinky_window_info(window.id).isOrderedIn else { return nil }
        return window
    }
}

/// The window a command acts on: the coordinator's focused window (the front app's frontmost document window
/// on a visible Space), falling back to the front app's AX key window, which can still be one on another Space.
func focusedWindowID() -> WindowID {
    if let id = AppState.shared.coordinator?.focusedWindow, id != 0 { return id }
    return frontWindowID()
}

func listWorkspaces(_ query: WorkspaceQuery) -> String {
    let now = QueryState()
    let occupied = Set(now.windows.map(\.space))
    var rows: [[String: String]] = []
    for (n, sid) in now.numbers.sorted(by: { $0.key < $1.key }) {
        guard let i = now.displays.firstIndex(where: { $0.userSpaces.contains(sid) }), now.matches(query.monitors, i) else { continue }
        let visible = sid == now.displays[i].currentSpaceID
        if let only = query.visible, only != visible { continue }
        if let empty = query.empty, empty == occupied.contains(sid) { continue }
        rows.append(row(now.monitorValues(i).merging(now.workspaceValues(n, space: sid, on: now.displays[i])) { a, _ in a },
                        WorkspaceQuery.variables))
    }
    return query.format.render(rows)
}

/// Windows sorted by display, workspace, then id. Windows on no Space (minimized ones) are left out.
func listWindows(_ query: WindowQuery) -> Reply {
    let now = QueryState()
    let coordinator = AppState.shared.coordinator
    let focused = query.focused ? focusedWindowID() : nil
    var rows: [(display: Int, workspace: Int, id: UInt32, values: [String: String])] = []
    for (window, sid) in now.windows {
        guard let i = now.displays.firstIndex(where: { $0.spaces.contains(sid) }) else { continue }
        let display = now.displays[i], n = now.numbers.first { $0.value == sid }?.key
        if let focused { guard window.id == focused else { continue } } else if !now.matches(query.monitors, i) { continue }
        guard query.workspaces.isEmpty || query.workspaces.contains(where: { spec in
            switch spec {
            case .focused: display.uuid == now.focused?.uuid && sid == display.currentSpaceID
            case .visible: sid == display.currentSpaceID
            case .number(let k): n == k
            }
        }) else { continue }
        let app = NSRunningApplication(processIdentifier: window.pid)
        if let bundleID = query.appBundleID, app?.bundleIdentifier != bundleID { continue }
        // Nothing is tiled on a native full-screen Space.
        let layout = !display.userSpaces.contains(sid) ? "fullscreen" : coordinator?.layoutName(of: window.id) ?? "floating"
        var values = now.monitorValues(i).merging(n.map { now.workspaceValues($0, space: sid, on: display) } ?? [:]) { a, _ in a }
        values.merge([
            "window-id": "\(window.id)", "window-title": window.title,
            "window-identifier": coordinator?.windowIdentifiers[window.id] ?? "",
            "window-layout": layout, "window-parent-container-layout": layout,
            "window-is-floating": "\(layout == "floating")", "window-is-fullscreen": "\(layout == "fullscreen")",
            "app-name": app?.localizedName ?? window.app, "app-bundle-id": app?.bundleIdentifier ?? "",
            "app-pid": "\(window.pid)",
        ]) { a, _ in a }
        rows.append((i, n ?? Int.max, window.id, row(values, WindowQuery.variables)))
    }
    if query.focused, rows.isEmpty { return .error("no window is focused") }
    rows.sort { ($0.display, $0.workspace, $0.id) < ($1.display, $1.workspace, $1.id) }
    return .ok(query.format.render(rows.map(\.values)))
}

func listMonitors(_ query: MonitorQuery) -> String {
    let now = QueryState()
    let rows = now.displays.indices.filter { i in
        query.focused.map { $0 == (now.displays[i].uuid == now.focused?.uuid) } ?? true
    }.map { row(now.monitorValues($0), MonitorQuery.variables) }
    return query.format.render(rows)
}

/// A query's row of format values. Every key must be one of the query's `variables`, the list its
/// `--format` is checked against, so a value filed under a misspelt or renamed variable fails in debug builds.
private func row(_ values: [String: String], _ variables: [String]) -> [String: String] {
    assert(values.keys.allSatisfy(variables.contains), "not format variables: \(values.keys.filter { !variables.contains($0) })")
    return values
}

/// What the queries read, taken fresh once per query.
private struct QueryState {
    let displays: [Display]
    let focused: Display?
    /// Workspace number to Space.
    let numbers: [Int: UInt64]
    /// Every listed window with the Space it is on, 0 for none.
    let windows: [(window: WindowInfo, space: UInt64)]

    init() {
        let model = AppState.shared.displays
        model.reconcile()
        displays = model.displays
        focused = model.focusedDisplay()
        numbers = AppState.shared.numbers.binding
        windows = windowList().map { ($0, dinky_window_space_id($0.id)) }
    }

    func matches(_ monitors: [MonitorSpec], _ index: Int) -> Bool {
        monitors.contains { spec in
            switch spec {
            case .all: true
            case .focused: displays[index].uuid == focused?.uuid
            case .number(let n): index == n - 1
            }
        }
    }

    func monitorValues(_ index: Int) -> [String: String] {
        let display = displays[index]
        return ["monitor-id": "\(index + 1)", "monitor-name": display.name, "monitor-is-main": "\(display.isMain)"]
    }

    /// Values for workspace `n`, on `space` of `display`.
    func workspaceValues(_ n: Int, space: UInt64, on display: Display) -> [String: String] {
        let visible = space == display.currentSpaceID
        return ["workspace": "\(n)", "workspace-is-visible": "\(visible)",
                "workspace-is-focused": "\(visible && display.uuid == focused?.uuid)",
                "workspace-layout": AppState.shared.coordinator?.layoutName(ofWorkspace: space) ?? ""]
    }
}
