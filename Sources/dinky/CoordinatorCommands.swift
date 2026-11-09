import DinkyCommands
import DinkyConfig
import DinkyLayout

// What commands ask of the coordinator: tree commands on the focused window's Space, floating, and
// taking in a window dinky moved to another Space.
extension Coordinator {
    /// Whether dinky floats the window; nil for a window it has not classified.
    func isFloating(_ id: WindowID) -> Bool? { placements[id]?.floating }

    /// The tree of the display's current Space, if dinky has one.
    func workspace(on display: Display) -> Workspace? {
        workspaces[display.currentSpaceID]
    }

    /// A queued swipe must still refer to the same focused tile in the same Space, not follow a moved window.
    func swipeTarget(on space: UInt64, from id: WindowID, direction: Direction) -> WindowID? {
        guard enabled, placements[id]?.space == space, let workspace = workspaces[space],
              workspace.focused == id, let target = workspace.swipeTarget(direction),
              placements[target]?.space == space else { return nil }
        return target
    }

    /// The container holding a tiled window.
    func container(of id: WindowID) -> Container? {
        placements[id]?.space.flatMap { workspaces[$0]?.container(of: id) }
    }

    /// Whether the window shows whole: false only for a column scrolled partly or wholly out of view.
    func isInView(_ id: WindowID) -> Bool {
        placements[id]?.space.flatMap { workspaces[$0]?.isInView(id) } ?? true
    }

    /// The layout of a tiled window's workspace.
    func tilingAlgorithm(of id: WindowID) -> TilingAlgorithm? {
        placements[id]?.space.flatMap { workspaces[$0]?.algorithm }
    }

    /// Switches a tiled window's workspace to the scrolling strip, the master layout, or its tree: the one its
    /// config gives it, or tiles when the config gives scrolling or master. The choice holds until switched again.
    func switchLayout(to name: WorkspaceLayoutName, for id: WindowID) {
        guard let key = placements[id]?.space else { return }
        let configured = settings(for: key).algorithm
        let new: TilingAlgorithm = switch name {
        case .scrolling: .scrolling
        case .master: .master
        case .dwindle: switch configured {
            case .scrolling, .master: .dwindle(.tiles)
            case .dwindle, .fixed: configured
            }
        }
        edit(key) {
            // Focused first: switching to master makes the focused window the master, and this is the window the
            // command is for, which a rule run for a window that is no longer focused would otherwise miss.
            $0.focus(id)
            $0.chosenAlgorithm = new == configured ? nil : new
            $0.setAlgorithm(new)
        }
        flush()
    }

    /// The container `layout` commands change for a tiled window, and the axis it runs along now: see
    /// `Workspace.layoutContainer(of:)`.
    func layoutContainer(of id: WindowID) -> (container: Container, axis: Orientation)? {
        placements[id]?.space.flatMap { workspaces[$0]?.layoutContainer(of: id) }
    }

    /// AeroSpace's name for how a window is laid out: `h_tiles`, `v_tiles`, `h_accordion` or `v_accordion`
    /// from its container (an `auto` one by the axis it follows now), `fullscreen` for dinky's fullscreen,
    /// `floating` for any window that is not tiled.
    func layoutName(of id: WindowID) -> String {
        guard let key = placements[id]?.space, let workspace = workspaces[key],
              let container = workspace.container(of: id), let axis = workspace.containerAxis(of: id) else { return "floating" }
        if workspace.fullscreen == id { return "fullscreen" }
        return (axis == .horizontal ? "h_" : "v_") + (container.mode == .accordion ? "accordion" : "tiles")
    }

    /// The layout of the workspace on a Space, for `%{workspace-layout}`: `dwindle`, `fixed`, `master` or
    /// `scrolling`. Nil for a Space dinky has no tree for, such as a native full-screen one.
    func layoutName(ofWorkspace space: UInt64) -> String? {
        guard let algorithm = workspaces[space]?.algorithm else { return nil }
        if case .fixed = algorithm { return "fixed" }
        return WorkspaceLayoutName.describing(algorithm).rawValue
    }

    /// Runs a command on the tree of a window (the focused one by default), focused in that tree, and applies
    /// what changed. Nil if the window is not tiled.
    func command<T>(on id: WindowID? = nil, _ change: (inout Workspace) -> T) -> T? {
        let id = id ?? focusedWindow
        guard let key = placements[id]?.space else { return nil }
        edit(key) { $0.focus(id) }
        let result = edit(key, change)
        flush()
        return result
    }

    /// Floats a tiled window where it stands, or tiles a floating one beside the focused tile of its Space.
    /// A window held as a possible tab is released, so it cannot take over a tile once floated.
    /// False for a window dinky has not classified.
    @discardableResult
    func setFloating(_ id: WindowID, _ floating: Bool) -> Bool {
        guard let placement = placements[id], let window = model.windows[id] else { return false }
        if let space = placement.space { edit(space) { $0.remove(id) } }
        heldTabs[id] = nil
        placements[id] = Placement(floating: floating, space: nil)
        track(window)
        flush()
        return true
    }

    /// Moves a window dinky just moved to another Space into that Space's tree now, rather than on the next event.
    /// `source` requests a focus handoff there. The caller captures it before moving, only for a focused window
    /// it isn't following; remembered tree focus and tiled placement cannot tell us that for a floating window.
    func windowMoved(_ id: WindowID, refocusFrom source: UInt64? = nil) {
        guard model.windows[id] != nil else { return }
        // Re-reads its Space; the update it publishes reaches handle, which tracks the window and flushes.
        model.refresh(id)
        guard let source, let successor = workspaces[source]?.focused, successor != id else { return }
        focus(successor)
    }
}
