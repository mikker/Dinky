import AppKit
import DinkyConfig
import DinkyPrivate
import Sparkle

// `dinky app`: a menu bar item showing the focused display's workspace number, with commands as menu
// items, and the socket the CLI talks to.
func runApp() -> Int32 {
    guard !appIsRunning() else {
        fputs("dinky: already running (\(socketPath))\n", stderr)
        return 1
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = DinkyApp()
    app.delegate = delegate
    app.run()
    return 0
}

final class DinkyApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    /// Other tiling window managers seen running at the last refresh.
    private var otherTilers: [String] = []
    private var socket: SocketServer?
    private let onboarding = Onboarding()
    private var signals: [DispatchSourceSignal] = []
    // Only a bundle carries the feed URL; a bare debug binary would otherwise show an "Unable to Check
    // For Updates" alert at launch that blocks the socket until dismissed.
    private let updater = SPUStandardUpdaterController(startingUpdater: Bundle.main.infoDictionary?["SUFeedURL"] != nil,
                                                       updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ note: Notification) {
        AppState.shared.loadConfig()
        socket = SocketServer(handle: handleCommand)
        // `kill` and logout quit through NSApplication, so windows are restored on the way out.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signals.append(source)
        }
        onboarding.run { [weak self] in self?.start() }
    }

    func applicationWillTerminate(_ note: Notification) {
        AppState.shared.quit()
        socket?.stop()
    }

    private func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        _ = AppState.shared.hotkeys.start()
        // First, so the follower sees every Space change from here on, the first arrangement's included.
        installActivationFollower()
        AppState.shared.startCoordinator()
        if let windows = AppState.shared.coordinator?.model { noteGoneWindows(in: windows) }
        AppState.shared.numbers.start()
        AppState.shared.numbers.observe { [weak self] in self?.refresh() }
        AppState.shared.displays.observe { [weak self] _ in self?.refresh() }
        // Nothing publishes the enabled state, the config error or other tilers starting and quitting.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
        print("app: status item up, listening on \(socketPath)")
        print("STATUS:READY")  // fut's run extension watches for this line
        fflush(stdout)
    }

    private func refresh() {
        let state = AppState.shared
        let workspace = state.displays.focusedDisplay().flatMap(state.numbers.current(on:))
        let tilers = runningOtherTilers()
        if tilers != otherTilers {
            otherTilers = tilers
            if !tilers.isEmpty { print("app: \(otherTilersWarning(tilers))") }
        }
        let trouble = state.configError != nil || !otherTilers.isEmpty
        statusItem.button?.title = (workspace.map { "\($0)" } ?? "?") + (trouble ? "!" : "")
        statusItem.button?.appearsDisabled = !state.enabled
    }

    /// The focused mode's bindings while the menu is built, so each item shows its key.
    private var bindings = MenuBindings(nil)

    // Every action is a command string, run exactly as `dinky <command>` would run it, and shows the key
    // bound to that command in the current mode.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = AppState.shared
        let mode = state.hotkeys.currentMode
        bindings = MenuBindings(state.config.modes[mode])
        let count = state.numbers.count
        let current = state.displays.focusedDisplay().flatMap(state.numbers.current(on:))
        menu.addItem(withTitle: "Workspace \(current.map { "\($0)" } ?? "?") of \(count)", action: nil, keyEquivalent: "")
        if mode != "main" {
            menu.addItem(withTitle: "Mode: \(mode)", action: nil, keyEquivalent: "")
        }
        if let error = state.configError {
            menu.addItem(withTitle: "Config error: \(error)", action: nil, keyEquivalent: "")
        }
        if !otherTilers.isEmpty {
            menu.addItem(withTitle: otherTilersWarning(otherTilers), action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())

        let go = NSMenu()
        let moveTo = NSMenu()
        let moveFollow = NSMenu()
        for n in 1...max(count, 1) {
            let title = "Workspace \(n)" + (n == current ? " (current)" : "")
            go.addItem(item(title, "workspace \(n)", enabled: n != current))
            moveTo.addItem(item(title, "move-window-to-workspace \(n)", enabled: n != current))
            moveFollow.addItem(item(title, "move-window-to-workspace \(n) --follow", enabled: n != current))
        }
        for menu in [go, moveTo, moveFollow] { menu.addItem(.separator()) }
        go.addItem(item("Previous", "workspace prev"))
        go.addItem(item("Next", "workspace next"))
        go.addItem(item("Back and Forth", "workspace-back-and-forth"))
        moveTo.addItem(item("Previous", "move-window-to-workspace prev"))
        moveTo.addItem(item("Next", "move-window-to-workspace next"))
        moveFollow.addItem(item("Previous", "move-window-to-workspace prev --follow"))
        moveFollow.addItem(item("Next", "move-window-to-workspace next --follow"))
        menu.addItem(submenu("Go to Workspace", go))
        menu.addItem(submenu("Move Window to Workspace", moveTo))
        menu.addItem(submenu("Move Window and Follow", moveFollow))
        menu.addItem(.separator())

        menu.addItem(submenu("Focus", directions("focus")))
        menu.addItem(submenu("Move Window", directions("move")))
        menu.addItem(submenu("Join With", directions("join-with")))
        menu.addItem(submenu("Resize", items([
            ("Grow", "resize smart +50"), ("Shrink", "resize smart -50"),
            ("Wider", "resize width +50"), ("Narrower", "resize width -50"),
            ("Taller", "resize height +50"), ("Shorter", "resize height -50"),
        ])))
        menu.addItem(submenu("Layout", items([
            ("Tiles", "layout tiles"), ("Accordion", "layout accordion"), nil,
            ("Horizontal", "layout horizontal"), ("Vertical", "layout vertical"),
            ("Follow Longer Side", "layout auto"), nil,
            ("Toggle Floating", "layout floating tiling"),
        ])))
        menu.addItem(item("Fullscreen", "fullscreen"))
        menu.addItem(item("Balance Sizes", "balance-sizes"))
        menu.addItem(item("Flatten Workspace Tree", "flatten-workspace-tree"))
        menu.addItem(.separator())

        menu.addItem(submenu("Display", items([
            ("Focus Left", "focus-monitor left"), ("Focus Down", "focus-monitor down"),
            ("Focus Up", "focus-monitor up"), ("Focus Right", "focus-monitor right"),
            ("Focus Next", "focus-monitor next"), ("Focus Previous", "focus-monitor prev"), nil,
            ("Move Window to Next", "move-window-to-display next"),
            ("Move Window to Previous", "move-window-to-display prev"),
            ("Move Window to Next and Follow", "move-window-to-display next --follow"),
            ("Move Window to Previous and Follow", "move-window-to-display prev --follow"),
        ])))
        let modes = NSMenu()
        let names = state.config.modes.keys.sorted()
        for name in names.filter({ $0 == "main" }) + names.filter({ $0 != "main" }) {
            let it = item(name, "mode \(name)")
            it.state = name == mode ? .on : .off
            modes.addItem(it)
        }
        menu.addItem(submenu("Mode", modes))
        // Bindings no item above runs, such as several commands at once or exec-and-forget.
        let others = bindings.unshown
        if !others.isEmpty {
            let other = NSMenu()
            for binding in others {
                other.addItem(item(binding.commands.joined(separator: "; "), binding.commands, key: binding.combo))
            }
            menu.addItem(submenu("Other Key Bindings", other))
        }
        menu.addItem(.separator())

        menu.addItem(item("Re-tile", "retile"))
        menu.addItem(item("Clear Saved Minimum Sizes", "clear-minimum-sizes"))
        menu.addItem(item("Reload Config", "reload-config"))
        let enabled = item("Enabled", "enable toggle")
        enabled.state = state.enabled ? .on : .off
        menu.addItem(enabled)
        let recoverable = state.recovery.recoverable
        if recoverable > 0 {
            menu.addItem(item("Restore \(recoverable) unfinished windows", "recover"))
        }
        menu.addItem(.separator())
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        menu.addItem(NSMenuItem(title: "Quit dinky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    private func item(_ title: String, _ command: String, enabled: Bool = true) -> NSMenuItem {
        item(title, [command], key: bindings.combo(for: command), enabled: enabled)
    }

    private func item(_ title: String, _ commands: [String], key: KeyCombo?, enabled: Bool = true) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: #selector(runCommand(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = commands
        it.toolTip = commands.map { "dinky \($0)" }.joined(separator: "\n")
        it.isEnabled = enabled
        if let (equivalent, mask) = key?.menuKey {
            it.keyEquivalent = equivalent
            it.keyEquivalentModifierMask = mask
        }
        return it
    }

    /// A menu of titled commands, nil for a separator.
    private func items(_ entries: [(String, String)?]) -> NSMenu {
        let menu = NSMenu()
        for entry in entries {
            menu.addItem(entry.map { item($0.0, $0.1) } ?? .separator())
        }
        return menu
    }

    private func directions(_ command: String) -> NSMenu {
        items(["left", "down", "up", "right"].map { ($0.capitalized, "\(command) \($0)") })
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = menu
        return it
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates(sender)
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let commands = sender.representedObject as? [String] else { return }
        for command in commands {
            let reply = handleCommand(command)
            if !reply.ok {
                fputs("\(command): \(reply.text)\n", stderr)
                NSSound.beep()
            }
        }
    }
}

/// A command from the menu or the CLI. `recover` belongs to the app rather than the command vocabulary.
private func handleCommand(_ line: String) -> Reply {
    line == "recover" ? AppState.shared.recover() : Dispatcher.run(line)
}
