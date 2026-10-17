import AppKit
import DinkyCommands
import DinkyConfig

// Window classification for the coordinator: the AX window kind, its fullscreen button and the config's `[[rules]]`.

extension Coordinator {
    /// Resolve AX metadata off the main thread, then evaluate the current rules once on the UI thread.
    func classify(_ window: Window) {
        guard enabled else { return }
        let started = classifier.request(window) { [weak self] metadata in
            guard let self, enabled, let current = model.windows[window.id],
                  current.identity == window.identity, current.isNormal, isVisible(current.spaceID),
                  placements[current.id] == nil else { return }
            let classification = metadata.map { self.classification(of: current, metadata: $0) }
                ?? (floating: true, runsRules: false)
            placements[current.id] = Placement(floating: classification.floating, space: nil)
            if !classification.runsRules, adopt(current) { return }
            track(current)
            flush()
        }
        if started { noteFirstShowing(window) }
    }

    private func classification(of window: Window, metadata: WindowMetadata) -> (floating: Bool, runsRules: Bool) {
        // `layout floating` and `layout tiling` decide here, the last one wins. Other rule commands, such as
        // move-window-to-workspace, run for this window once it is placed.
        var floats: Bool?
        var runsRules = false
        for command in config.commands(for: window, kind: metadata.kind, title: metadata.title) {
            switch command {
            case .layout([.floating]): floats = true
            case .layout([.tiling]): floats = false
            default:
                runsRules = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, enabled, model.windows[window.id]?.identity == window.identity else { return }
                    let reply = Dispatcher.run(command, window: window.id)
                    if !reply.ok { fputs("rule: \(reply.text)\n", stderr) }
                }
            }
        }
        let floating = metadata.kind != .normal || !metadata.resizable
            || (floats ?? (config.floatWindowsWithoutFullscreen && metadata.lacksFullscreen))
        return (floating, runsRules)
    }
}

/// Only the metadata reader touches AX; the classifier runs it on the owning app's queue.
func readWindowMetadata(_ window: Window) -> WindowMetadata? {
    guard let element = axWindow(pid: window.pid, wid: window.id, timeout: FrameApplier.timeout) else { return nil }
    let kind = windowKind(subrole: axString(element, kAXSubroleAttribute))
    var resizable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &resizable)
    return WindowMetadata(kind: kind, resizable: resizable.boolValue,
                          title: axString(element, kAXTitleAttribute) ?? "",
                          lacksFullscreen: kind == .normal && resizable.boolValue
                            && lacksFullscreen(element, bundleID: window.bundleID))
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

