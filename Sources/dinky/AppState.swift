import DinkyConfig
import Foundation

// State that outlives a single command: the current config, the hotkey engine, whether dinky is
// enabled, the display model and the coordinator that tiles. Main thread only.
final class AppState {
    static let shared = AppState()

    /// Runs each binding's commands in order through the dispatcher. Started by the app once
    /// Accessibility is granted.
    let hotkeys = HotkeyEngine { commands in
        for command in commands {
            let reply = Dispatcher.run(command)
            if !reply.ok { fputs("\(command): \(reply.text)\n", stderr) }
        }
    }

    /// The config in effect. A config that fails to load leaves the previous one here.
    private(set) var config = Config.default
    /// The last load error, shown first in the status item's menu. Nil once a load succeeds.
    private(set) var configError: ConfigError?
    private(set) var enabled = true
    /// Displays and their Spaces, started on first use.
    private(set) lazy var displays: DisplayModel = {
        let model = DisplayModel()
        model.start()
        return model
    }()
    /// Which Space each workspace is, arranged by the app once tiling runs.
    let numbers = WorkspaceNumbers()
    /// Tiling and borders, started by the app once Accessibility is granted.
    private(set) var coordinator: Coordinator?
    /// The journal of original frames that disable, quit and `dinky recover` restore.
    let recovery = Recovery()
    private let hooks = Hooks()
    private let hoverFocus = HoverFocus()
    private let swipeFocus = SwipeFocus()
    private var watcher: ConfigWatcher?

    private init() {
        hotkeys.load(modes: config.modes, sides: config.modifiers)
    }

    /// Loads `~/.config/dinky/dinky.toml`, writing the default config there first if it is missing.
    @discardableResult
    func loadConfig() -> ConfigError? {
        let url = Config.userConfigURL
        Config.writeDefaultIfMissing(at: url)
        apply(Result { () throws(ConfigError) in try Config.load(from: url) })
        if watcher == nil {
            watcher = ConfigWatcher(url: url) { [weak self] in self?.apply($0) }
        }
        return configError
    }

    func startCoordinator() {
        guard coordinator == nil else { return }
        let coordinator = Coordinator(displays: displays, config: config)
        self.coordinator = coordinator
        // A disable sent before Accessibility was granted had no coordinator to reach.
        coordinator.enabled = enabled
        // Journal the frames the model read before the first arrange writes any. Disabled, nothing is tiled, so
        // nothing is journaled until enabling resumes it; a restore on quit would move windows dinky never touched.
        coordinator.start {
            recovery.start(model: coordinator.model, applier: coordinator.applier)
            if enabled { recovery.resume() }
        }
        // Once the windows are known, so each workspace's windows move with it, and before the hooks, which
        // report workspace numbers.
        numbers.arrange()
        hooks.start()
        hoverFocus.update(config: config.focusFollowsMouse)
        swipeFocus.update(config: config.swipe)
    }

    /// The one enable transition. Off stops tiling and puts every window back where it was before dinky
    /// touched it, and returns the restore's summary. This is the emergency path: `dinky enable off`, the
    /// menu's Enabled item, `dinky recover` and quitting all come through here.
    @discardableResult
    func setEnabled(_ on: Bool) -> String {
        if on { recovery.resume() }
        let wasOn = enabled
        enabled = on
        propagateEnabled()
        // Displays may have come or gone while off, when arranging only numbers the Spaces. Already on, they are
        // arranged, and arranging blocks the main thread.
        if on, !wasOn, coordinator != nil { numbers.arrange() }
        return on ? "" : recovery.restore()
    }

    /// `dinky recover` and the menu's restore item: after a crash, stops tiling and restores every
    /// journaled window, including those the crashed session left tiled.
    func recover() -> Reply {
        guard recovery.recoverable > 0 else { return .error("no windows from a previous session to restore") }
        return .ok(setEnabled(false) + "; dinky is disabled, `dinky enable on` tiles again")
    }

    /// Quitting stops tiling and puts every window back.
    func quit() {
        setEnabled(false)
    }

    private func apply(_ result: Result<Config, ConfigError>) {
        switch result {
        case .success(let config):
            self.config = config
            configError = nil
            hotkeys.load(modes: config.modes, sides: config.modifiers)
            // At launch the app arranges the workspaces itself, once the coordinator has started.
            if let coordinator {
                coordinator.update(config: config)
                numbers.arrange()
                hoverFocus.update(config: config.focusFollowsMouse)
                swipeFocus.update(config: config.swipe)
            }
            applyStartAtLogin(config.startAtLogin)
        case .failure(let error):
            configError = error
            fputs("config: \(error), keeping the previous config\n", stderr)
        }
        // The new hotkeys and a reload while disabled stay disabled.
        propagateEnabled()
    }

    /// Hands `enabled` to the parts that keep their own copy. The activation follower and hover focus read it
    /// when they decide.
    private func propagateEnabled() {
        hotkeys.enabled = enabled
        coordinator?.enabled = enabled
    }
}
