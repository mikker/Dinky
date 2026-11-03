// Workspace hook bookkeeping, shared by native switches and numbering announcements. A renumber is a
// change even when the visible number stays the same; it must not produce a second hook when it differs.
struct WorkspaceHookState {
    var workspaces: [String: String] = [:]
    private var pendingChanges: Set<String> = []

    init(workspaces: [String: String] = [:]) {
        self.workspaces = workspaces
    }

    /// Contents changed or a switch finished; both owe a refresh even if the visible number is unchanged.
    mutating func invalidate(_ displays: Set<String>) { pendingChanges.formUnion(displays) }

    /// Returns the previous number once all operations affecting this display have settled.
    mutating func update(_ uuid: String, to new: String, stable: Bool) -> String? {
        guard let old = workspaces[uuid] else {
            workspaces[uuid] = new
            pendingChanges.remove(uuid)
            return nil
        }
        guard stable else { return nil }
        let changed = pendingChanges.remove(uuid) != nil
        guard old != new || changed else { return nil }
        workspaces[uuid] = new
        return old
    }
}
