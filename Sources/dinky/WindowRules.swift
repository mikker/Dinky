import AppKit
import DinkyCommands
import DinkyConfig

// Window classification for the coordinator: the AX window kind, its fullscreen button and the config's `[[rules]]`.

extension Coordinator {
    /// Whether a window floats, and whether `[[rules]]` run commands for it, which then decide where it goes. Nil
    /// while its AX element is not there yet (a retry is scheduled; after a few, the window floats since dinky
    /// could not move it anyway).
    func classify(_ window: Window) -> (floating: Bool, runsRules: Bool)? {
        guard let element = axWindow(pid: window.pid, wid: window.id, timeout: FrameApplier.timeout) else {
            let tries = attempts[window.id, default: 0] + 1
            attempts[window.id] = tries
            guard tries < 5 else { return (true, false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, let window = model.windows[window.id] else { return }
                track(window)
                flush()
            }
            return nil
        }
        attempts[window.id] = nil
        let kind = windowKind(subrole: axString(element, kAXSubroleAttribute))
        var resizable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &resizable)
        let title = axString(element, kAXTitleAttribute) ?? ""
        // `layout floating` and `layout tiling` decide here, the last one wins. Other rule commands, such as
        // move-window-to-workspace, run for this window once it is placed.
        var floats: Bool?
        var runsRules = false
        for command in config.commands(for: window, kind: kind, title: title) {
            switch command {
            case .layout([.floating]): floats = true
            case .layout([.tiling]): floats = false
            default:
                runsRules = true
                DispatchQueue.main.async {
                    let reply = Dispatcher.run(command, window: window.id)
                    if !reply.ok { fputs("rule: \(reply.text)\n", stderr) }
                }
            }
        }
        let floating = kind != .normal || !resizable.boolValue
            || (floats ?? session.floatingOverride(for: window)
                ?? (config.floatWindowsWithoutFullscreen && lacksFullscreen(element, bundleID: window.bundleID)))
        return (floating, runsRules)
    }
}

/// AeroSpace's heuristic: a standard window whose fullscreen button is missing or disabled was not made to be
/// big, such as Finder's copy progress, About This Mac or Calculator. Apps that can hide their title bar, and
/// Chrome, whose torn-off tab enables its button a moment late, are left to tile.
private func lacksFullscreen(_ element: AXUIElement, bundleID: String?) -> Bool {
    if let bundleID, titleBarOptional.contains(bundleID) { return false }
    let fullscreen = buttonEnabled(element, kAXFullScreenButtonAttribute)
    // Ghostty with its title bar hidden has no close button either.
    if bundleID == "com.mitchellh.ghostty" { return !fullscreen && buttonEnabled(element, kAXCloseButtonAttribute) }
    return !fullscreen
}

private let titleBarOptional: Set<String> = [
    "com.google.Chrome", "com.apple.ActivityMonitor", "org.gimp.gimp-2.10", "com.valvesoftware.steam.helper",
    "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "com.googlecode.iterm2",
    "org.qutebrowser.qutebrowser", "org.gnu.Emacs", "com.microsoft.VSCode", "com.vscodium",
]

private func buttonEnabled(_ element: AXUIElement, _ attribute: String) -> Bool {
    var button: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &button) == .success,
          let button, CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
    var enabled: CFTypeRef?
    AXUIElementCopyAttributeValue(button as! AXUIElement, kAXEnabledAttribute as CFString, &enabled)
    return enabled as? Bool == true
}

extension Config {
    /// The commands of every rule that matches, in order. Commands that do not parse are skipped.
    func commands(for window: Window, kind: WindowKind, title: String) -> [Command] {
        rules.filter { $0.matches(appId: window.bundleID, appName: window.appName, title: title, kind: kind) }
            .flatMap { $0.run.compactMap { try? Command.parse($0) } }
    }
}

/// The rule kind for an AX subrole. Anything that is not a standard window, dialog or sheet is a panel.
private func windowKind(subrole: String?) -> WindowKind {
    switch subrole {
    case kAXStandardWindowSubrole: .normal
    case kAXDialogSubrole, kAXSystemDialogSubrole: .dialog
    case "AXSheet": .sheet
    default: .panel
    }
}

private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
}

