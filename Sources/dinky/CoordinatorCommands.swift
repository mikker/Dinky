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

    /// The container holding a tiled window.
    func container(of id: WindowID) -> Container? {
        placements[id]?.space.flatMap { workspaces[$0]?.container(of: id) }
    }

    /// The axis the container holding a tiled window runs along now, `auto` resolved.
    func containerAxis(of id: WindowID) -> Orientation? {
        placements[id]?.space.flatMap { workspaces[$0]?.containerAxis(of: id) }
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
        placements[id] = Placement(floating: floating, space: nil, floatingOverride: floating)
        session.saveSoon()
        track(window)
        flush()
        return true
    }

    /// Moves a window dinky just moved to another Space into that Space's tree now, rather than on the next event.
    /// macOS leaves keyboard focus with the moved window, so unless we are about to follow it, focus the window
    /// that took its place in the tree it left.
    func windowMoved(_ id: WindowID, refocus: Bool = true) {
        guard model.windows[id] != nil else { return }
        // The tree's own record: by now macOS has already re-pointed the app's frontmost window elsewhere.
        let from = placements[id]?.space
        let hadFocus = from.flatMap { workspaces[$0]?.focused } == id
        // Re-reads its Space; the update it publishes reaches handle, which tracks the window and flushes.
        model.refresh(id)
        guard refocus, hadFocus, let from, let successor = workspaces[from]?.focused, successor != id else { return }
        focus(successor)
    }
}
