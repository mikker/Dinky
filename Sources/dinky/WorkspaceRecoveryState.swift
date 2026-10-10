/// Temporary title and move state for display recovery. Keys include the window's full identity.
struct WorkspaceRecoveryState {
    private(set) var titles: [Window.Identity: String] = [:]
    private(set) var moves: [Window.Identity: UInt64] = [:]

    mutating func cacheTitle(_ title: String, for identity: Window.Identity) { titles[identity] = title }
    mutating func invalidateTitle(_ identity: Window.Identity) { titles.removeValue(forKey: identity) }
    mutating func remove(_ identity: Window.Identity) {
        invalidateTitle(identity)
        moves.removeValue(forKey: identity)
    }
    mutating func reset() {
        titles.removeAll()
        moves.removeAll()
    }
    mutating func retain(live: Set<Window.Identity>, destinations: [Window.Identity: UInt64]) {
        titles = titles.filter { live.contains($0.key) }
        moves = moves.filter { destinations[$0.key] == $0.value }
    }
    /// Reserve a move before calling WindowServer; duplicate events must not submit it again.
    mutating func beginMove(_ identity: Window.Identity, to destination: UInt64) -> Bool {
        guard moves[identity] != destination else { return false }
        moves[identity] = destination
        return true
    }
    mutating func rejectMove(_ identity: Window.Identity) { moves.removeValue(forKey: identity) }
    /// A read or event confirms arrival. Other Spaces leave the request pending.
    mutating func confirmMove(_ identity: Window.Identity, on space: UInt64,
                             history: inout WindowRestorationHistory) -> Bool {
        guard moves[identity] == space else { return false }
        moves.removeValue(forKey: identity)
        history.noteReturn(identity)
        return true
    }
}
