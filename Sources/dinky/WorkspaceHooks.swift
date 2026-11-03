// Workspace hook delivery owns its subscriptions and swipe bookkeeping. The injected snapshot model,
// numbering and switch target are the same objects the app uses; tests can supply them without WindowServer.
final class WorkspaceHooks {
    private let model: DisplayModel
    private let numbers: WorkspaceNumbering
    private let switcher: SpaceSwitcher
    private let run: (String, String, Int) -> Void
    private var state = WorkspaceHookState()

    init(model: DisplayModel, numbers: WorkspaceNumbering, switcher: SpaceSwitcher,
         run: @escaping (String, String, Int) -> Void) {
        self.model = model
        self.numbers = numbers
        self.switcher = switcher
        self.run = run
        for display in model.displays { state.workspaces[display.uuid] = number(display) }
        model.observeAfterUpdates { [weak self] _ in self?.changed() }
        numbers.observe { [weak self] in self?.changed(renumbered: $0) }
        switcher.onSettled = { [weak self] in self?.settled($0) }
    }

    private func changed(renumbered: Set<String> = []) {
        state.invalidate(renumbered)
        for (i, display) in model.displays.enumerated() {
            let new = number(display)
            let stable = !numbers.updating && switcher.target(on: display.uuid) == nil
            guard let old = state.update(display.uuid, to: new, stable: stable) else { continue }
            run(new, old, i)
        }
    }

    /// The authoritative flight completion (success or failure) is an update even when no snapshot changed.
    private func settled(_ uuid: String) {
        numbers.withUpdates {
            state.invalidate([uuid])
            model.reconcile()
        }
    }

    private func number(_ display: Display) -> String {
        numbers.binding.first { $0.value == display.currentSpaceID }.map { "\($0.key)" } ?? ""
    }
}
