import AppKit
import DinkyCommands
import DinkyConfig
import DinkyLayout
import DinkyPrivate

/// What a command answers: a short line for the CLI, and whether it worked.
struct Reply {
    var ok: Bool
    var text: String

    static func ok(_ text: String) -> Reply { Reply(ok: true, text: text) }
    static func error(_ text: String) -> Reply { Reply(ok: false, text: text) }
}

// Runs commands from bindings, the CLI and the menu against what exists today. Main thread only.
// Workspaces are numbered across displays; `prev` and `next` step through the focused display's.
enum Dispatcher {
    /// `env` is added to the environment of an `exec-and-forget`, for hooks.
    static func run(_ line: String, env: [String: String] = [:]) -> Reply {
        do {
            return run(try Command.parse(line), env: env)
        } catch {
            return .error(error.description)
        }
    }

    /// Runs a command. `window` stands in for the focused window in commands that act on one, for
    /// window rules; bindings and the CLI leave it nil.
    static func run(_ command: Command, window: WindowID? = nil, env: [String: String] = [:]) -> Reply {
        switch command {
        case .workspace(let target):
            return switchWorkspace(target)
        case .workspaceBackAndForth:
            let model = AppState.shared.displays
            guard let display = model.focusedDisplay(), let previous = model.previousSpace(on: display),
                  let n = AppState.shared.numbers.number(of: previous) else {
                return .error("no previous workspace")
            }
            return switchWorkspace(.number(n))
        case .moveWindowToWorkspace(let target, let follow):
            return moveWindowToWorkspace(target, follow: follow, window: window ?? focusedWindowID())
        case .moveWindowToDisplay(let target, let follow):
            return moveWindowToDisplay(target, follow: follow, window: window ?? focusedWindowID())
        case .focus(let direction, let boundaries, let action):
            return focus(direction, boundaries: boundaries, action: action)
        case .focusMonitor(let target):
            return focusMonitor(target)
        case .focusMonitorNumber(let n):
            return focusMonitor(number: n)
        case .layout(let names):
            return layout(names, window: window)
        case .move(let direction):
            return tree("move \(direction)") { $0.move(direction) }
        case .joinWith(let direction):
            return tree("join-with \(direction)") { $0.join(direction) }
        case .resize(let dimension, let delta):
            let axis: Orientation? = switch dimension {
            case .smart: nil
            case .width: .horizontal
            case .height: .vertical
            }
            return tree("resize \(dimension.rawValue) \(delta)") { $0.resize(by: CGFloat(delta), along: axis) }
        case .fullscreen:
            return tree("fullscreen") { $0.toggleFullscreen(); return true }
        case .flattenWorkspaceTree:
            return tree("flatten-workspace-tree") { $0.flatten(); return true }
        case .balanceSizes:
            return tree("balance-sizes") { $0.balanceSizes(); return true }
        case .retile:
            guard let coordinator = AppState.shared.coordinator else { return .error("tiling is not running") }
            coordinator.reconcile()
            return .ok("retiled")
        case .clearMinimumSizes:
            guard let coordinator = AppState.shared.coordinator else { return .error("tiling is not running") }
            coordinator.clearMinimumSizes()
            return .ok("cleared minimum sizes")
        case .mode(let name):
            guard AppState.shared.config.modes[name] != nil else { return .error("no mode '\(name)' in the config") }
            AppState.shared.hotkeys.setMode(name)
            return .ok("mode \(name)")
        case .reloadConfig:
            if let error = AppState.shared.loadConfig() { return .error("config: \(error)") }
            return .ok("reloaded \(Config.userConfigURL.path)")
        case .enable(let toggle):
            let on = toggle == .toggle ? !AppState.shared.enabled : toggle == .on
            AppState.shared.setEnabled(on)
            return .ok(on ? "enabled" : "disabled")
        case .listWindows(let query):
            return listWindows(query)
        case .listWorkspaces(let query):
            return .ok(listWorkspaces(query))
        case .listMonitors(let query):
            return .ok(listMonitors(query))
        case .listModes(let current):
            let state = AppState.shared
            if current { return .ok(state.hotkeys.currentMode) }
            let names = state.config.modes.keys.sorted()
            return .ok((names.filter { $0 == "main" } + names.filter { $0 != "main" }).joined(separator: "\n"))
        case .debugState:
            guard let coordinator = AppState.shared.coordinator else { return .error("tiling is not running") }
            return .ok(coordinator.debugState())
        case .execAndForget(let shell):
            exec(["/bin/sh", "-c", shell], env: env)
            return .ok("")
        }
    }

    // MARK: Workspaces

    private struct Refusal: Error {
        let reply: Reply
        init(_ text: String) { reply = .error(text) }
    }

    /// The workspace a target names. `prev` and `next` step through the focused display's workspaces in number
    /// order, without wrapping, from the one it shows or is switching to, so rapid requests add up.
    private static func resolve(_ target: WorkspaceTarget) throws(Refusal) -> Int {
        let model = AppState.shared.displays
        let numbers = AppState.shared.numbers
        model.reconcile()
        switch target {
        case .number(let n):
            guard (1...numbers.count).contains(n) else { throw Refusal("no workspace \(n), there are \(numbers.count)") }
            return n
        case .prev, .next:
            guard let display = model.focusedDisplay(), let current = numbers.number(of: targetSpaceID(on: display)) else {
                throw Refusal("not on a numbered workspace")
            }
            let here = numbers.workspaces(on: display)
            guard let at = here.firstIndex(of: current) else { throw Refusal("not on a numbered workspace") }
            let i = at + (target == .next ? 1 : -1)
            guard here.indices.contains(i) else { throw Refusal("no \(target == .next ? "next" : "previous") workspace on this display") }
            return here[i]
        }
    }

    private static func switchWorkspace(_ target: WorkspaceTarget) -> Reply {
        do {
            return show(try resolve(target))
        } catch {
            return error.reply
        }
    }

    /// Puts workspace `n` on screen on its display and gives that display focus. `landed` runs once it shows, in
    /// place of focusing the workspace's window.
    private static func show(_ n: Int, landed: (() -> Void)? = nil) -> Reply {
        let model = AppState.shared.displays
        guard let space = AppState.shared.numbers.space(of: n), let display = model.display(containingSpace: space) else {
            return .error("workspace \(n) has no Space; see `dinky doctor`")
        }
        // On screen and staying there; a switch still on its way is not, and takes `arrive` for when it lands.
        let showing = display.currentSpaceID == space && targetSpaceID(on: display) == space
        let elsewhere = model.focusedDisplay()?.uuid != display.uuid
        if showing, !elsewhere, landed == nil { return .ok("already on workspace \(n)") }
        // Arriving on a Space, macOS activates an app, which can be one with a window on another display when the
        // workspace has no window of the app that had focus. Focus stays on this display.
        let arrive = landed ?? {
            model.reconcile()
            guard let shown = model.displays.first(where: { $0.uuid == display.uuid }) else { return }
            if !elsewhere, model.display(ofWindow: frontWindowID())?.uuid == shown.uuid { return }
            _ = focus(shown, window: AppState.shared.coordinator?.workspace(on: shown)?.focused)
        }
        if showing {
            arrive()
            return .ok("workspace \(n)")
        }
        guard switchSpace(toSpaceID: space, on: display, landed: arrive) else { return .error("switch to workspace \(n) failed") }
        return .ok("workspace \(n)")
    }

    private static func moveWindowToWorkspace(_ target: WorkspaceTarget, follow: Bool, window wid: WindowID) -> Reply {
        let n: Int
        do {
            n = try resolve(target)
        } catch {
            return error.reply
        }
        guard let space = AppState.shared.numbers.space(of: n),
              let to = AppState.shared.displays.display(containingSpace: space) else {
            return .error("workspace \(n) has no Space; see `dinky doctor`")
        }
        if let reply = relocate(wid, to: space, on: to, destination: "workspace \(n)", follow: follow) { return reply }
        // macOS activates another app when the Space left behind loses the active app's window, so focus the
        // moved window once its workspace shows.
        if follow { _ = show(n) { AppState.shared.coordinator?.focus(wid) } }
        return .ok("moved window \(wid) to workspace \(n)")
    }

    // MARK: Layout tree

    /// Runs a change on the focused window's tree; `change` returns false when there was nothing to do.
    private static func tree(_ name: String, _ change: (inout Workspace) -> Bool) -> Reply {
        guard let coordinator = AppState.shared.coordinator else { return .error("tiling is not running") }
        switch coordinator.command(change) {
        case nil: return .error("\(name): the focused window is not tiled")
        case false?: return .error("\(name): nothing to do")
        case true?: return .ok(name)
        }
    }

    /// Applies the first layout that does not describe the window now, or the first if all do:
    /// floating or tiling for the window, a mode, an orientation or both for its container (tiling it first if it floats).
    private static func layout(_ names: [LayoutName], window: WindowID?) -> Reply {
        guard let coordinator = AppState.shared.coordinator else { return .error("tiling is not running") }
        let id = window ?? coordinator.focusedWindow
        guard let floating = coordinator.isFloating(id) else { return .error("layout: no window dinky manages is focused") }
        var current: [LayoutName] = floating ? [.floating] : [.tiling]
        if !floating, let container = coordinator.container(of: id), let axis = coordinator.containerAxis(of: id) {
            current += LayoutName.describing(container.mode, axis: axis, auto: container.orientation == .auto)
        }
        let name = names.first { !current.contains($0) } ?? names[0]
        switch name {
        case .floating, .tiling:
            coordinator.setFloating(id, name == .floating)
        default:
            if floating { coordinator.setFloating(id, false) }
            coordinator.command(on: id) { $0.setLayout(name.mode, name.orientation) }
        }
        return .ok("layout \(name.rawValue)")
    }

    // MARK: Windows

    /// Moves a window to the current Space of the next or previous display (wrapping around), into that
    /// Space's tree. A floating window keeps its offset from the display's corner. Untested with two displays.
    private static func moveWindowToDisplay(_ target: DisplayTarget, follow: Bool, window wid: WindowID) -> Reply {
        let model = AppState.shared.displays
        model.reconcile()
        guard wid != 0, let from = model.display(ofWindow: wid) else { return .error("no focused window") }
        let displays = model.displays
        guard displays.count > 1, let i = displays.firstIndex(of: from) else { return .error("no other display") }
        let n = (i + (target == .next ? 1 : -1) + displays.count) % displays.count
        let to = displays[n]
        if let reply = relocate(wid, to: to.currentSpaceID, on: to, destination: "display \(n + 1)", follow: follow) {
            return reply
        }
        // The Space is on screen, so there is nothing to show first.
        if follow { AppState.shared.coordinator?.focus(wid) }
        return .ok("moved window \(wid) to display \(n + 1)")
    }

    /// Moves a new window to the current Space of `display`, without telling the coordinator, which is holding it
    /// out of the trees. Nil once moved, else the error.
    static func adopt(_ wid: WindowID, onto display: Display) -> Reply? {
        let from = AppState.shared.displays.display(ofWindow: wid)
        if let error = move(wid, to: display.currentSpaceID, arriving: "display \(display.id)") { return error }
        if let from { keepOffset(of: wid, from: from, to: display) }
        return nil
    }

    /// Moves a window to a Space on display `to` and tells the coordinator, which refocuses the Space left
    /// behind unless the caller follows the window. Nil once moved, else the reply to answer (an error, or ok
    /// when the window is already there).
    private static func relocate(_ wid: WindowID, to space: UInt64, on to: Display, destination: String,
                                 follow: Bool) -> Reply? {
        guard wid != 0 else { return .error("no focused window") }
        guard dinky_window_space_id(wid) != space else { return .ok("window \(wid) is already on \(destination)") }
        let from = AppState.shared.displays.display(ofWindow: wid)
        if let error = move(wid, to: space, arriving: destination) { return error }
        if let from { keepOffset(of: wid, from: from, to: to) }
        AppState.shared.coordinator?.windowMoved(wid, refocus: !follow)
        return nil
    }

    /// A floating window moved to another display keeps its offset from the display's corner; the tree places a
    /// tiled one.
    private static func keepOffset(of wid: WindowID, from: Display, to: Display) {
        guard from.uuid != to.uuid, AppState.shared.coordinator?.isFloating(wid) != false,
              let pid = windowPID(wid), let element = axWindow(pid: pid, wid: wid) else { return }
        let frame = dinky_window_info(wid).frame
        var origin = CGPoint(x: to.frame.minX + max(0, frame.minX - from.frame.minX),
                             y: to.frame.minY + max(0, frame.minY - from.frame.minY))
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
    }

    /// Moves a window to a Space and waits for it to arrive: the bridged move is asynchronous, and callers
    /// act on the window's new place. Nil on success, else the error to answer.
    private static func move(_ wid: WindowID, to space: UInt64, arriving destination: String) -> Reply? {
        var ids = [wid]
        guard dinky_move_windows_to_space(&ids, 1, space) else { return .error("move failed") }
        guard waitUntil(0.5, { dinky_window_space_id(wid) == space }) else {
            return .error("window \(wid) did not arrive on \(destination)")
        }
        return nil
    }
}

