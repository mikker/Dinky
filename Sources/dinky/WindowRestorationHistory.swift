/// A display transition resets move attempts, but not a restored window's status as an existing window.
struct WindowRestorationHistory {
    private var returned: Set<Window.Identity> = []
    private var restored: Set<Window.Identity> = []

    mutating func beginDisplayChange() { returned.removeAll() }
    mutating func noteReturn(_ identity: Window.Identity) {
        returned.insert(identity)
        restored.insert(identity)
    }
    mutating func retain(_ live: Set<Window.Identity>) {
        returned.formIntersection(live)
        restored.formIntersection(live)
    }
    func returnedDuringChange(_ identity: Window.Identity) -> Bool { returned.contains(identity) }
    func wasRestored(_ identity: Window.Identity) -> Bool { restored.contains(identity) }
}
