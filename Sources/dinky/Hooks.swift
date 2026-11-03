import Foundation

// The config's `[hooks]`: `workspace-changing` when dinky starts or retargets a switch, `workspace-changed`
// when any display's current workspace changes (dinky's switches and native ones alike), a dinky switch
// gives up, or `follow-space-order` renumbers a display's workspaces, `focus-changed` when the focused
// window changes, debounced, `mode-changed` when the binding mode changes, with the new mode and the
// previous one, `display-changed` once the workspaces have moved after a
// display connects or disconnects, and `startup` once. Started once the coordinator has read the windows and displays, so startup fires nothing
// but `startup`. Main thread only.
final class Hooks {
    private var workspaceHooks: WorkspaceHooks?
    private var pendingFocus: DispatchWorkItem?
    /// The displays connected when last seen, by UUID.
    private var connected: Set<String> = []

    func start() {
        let state = AppState.shared
        workspaceHooks = WorkspaceHooks(model: state.displays, numbers: state.numbers,
                                        switcher: SpaceSwitcher.shared) { [weak self] new, old, i in
            self?.runWorkspaceHooks(AppState.shared.config.hooks.workspaceChanged, workspace: new, previous: old, display: i)
        }
        connected = Set(state.displays.displays.map(\.uuid))
        state.numbers.onArranged = { [weak self] in self?.arranged() }
        SpaceSwitcher.shared.onTarget = { [weak self] uuid, target in self?.switchTargeted(uuid, target) }
        state.coordinator?.onFocusChange = { [weak self] in self?.focusChanged() }
        state.hotkeys.onModeChange = { mode, previous in
            run(AppState.shared.config.hooks.modeChanged, env: ["DINKY_MODE": mode, "DINKY_PREV_MODE": previous])
        }
        run(state.config.hooks.startup)
    }

    /// Reports displays that came or went once the workspaces have moved to the displays now present, which
    /// waits for the displays to settle.
    private func arranged() {
        let now = Set(AppState.shared.displays.displays.map(\.uuid))
        guard now != connected else { return }
        let previous = connected.count
        connected = now
        run(AppState.shared.config.hooks.displayChanged, env: ["DINKY_DISPLAYS": "\(now.count)", "DINKY_PREV_DISPLAYS": "\(previous)"])
    }

    /// Announces where a dinky switch is going before it lands, so a bar can show it at once.
    private func switchTargeted(_ uuid: String, _ target: UInt64) {
        let displays = AppState.shared.displays.displays
        guard let i = displays.firstIndex(where: { $0.uuid == uuid }) else { return }
        let workspace = AppState.shared.numbers.label(of: target)
        runWorkspaceHooks(AppState.shared.config.hooks.workspaceChanging, workspace: workspace, previous: number(displays[i]), display: i)
    }

    /// Runs workspace hooks with the numbers `exec-and-forget` passes on; `display` is 0-based.
    private func runWorkspaceHooks(_ commands: [String], workspace: String, previous: String, display: Int) {
        run(commands, env: ["DINKY_WORKSPACE": workspace, "DINKY_PREV_WORKSPACE": previous, "DINKY_DISPLAY": "\(display + 1)"])
    }

    private func focusChanged() {
        pendingFocus?.cancel()
        let work = DispatchWorkItem { run(AppState.shared.config.hooks.focusChanged) }
        pendingFocus = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func number(_ display: Display) -> String {
        AppState.shared.numbers.label(of: display.currentSpaceID)
    }
}

/// Runs dinky command strings through the dispatcher, logging failures. `env` reaches `exec-and-forget`.
private func run(_ commands: [String], env: [String: String] = [:]) {
    for command in commands {
        let reply = Dispatcher.run(command, env: env)
        if !reply.ok { fputs("hook \(command): \(reply.text)\n", stderr) }
    }
}

/// Starts a process without waiting for it. Its output goes to dinky's own stdout and stderr, the log.
/// dinky's own directory and Homebrew's go first on PATH, since apps started from Finder lack them, so scripts
/// can call `dinky` and find Homebrew tools: /opt/homebrew on Apple silicon, /usr/local on Intel.
func exec(_ argv: [String], env: [String: String] = [:]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: argv[0])
    process.arguments = Array(argv.dropFirst())
    var environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
    let own = Bundle.main.executableURL?.deletingLastPathComponent().path ?? ""
    environment["PATH"] = own + ":/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:"
        + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        fputs("exec \(argv[0]): \(error.localizedDescription)\n", stderr)
    }
}
