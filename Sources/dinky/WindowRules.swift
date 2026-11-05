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
            return retryClassification(window.id) ? nil : (true, false)
        }
        let kind = windowKind(subrole: axString(element, kAXSubroleAttribute))
        var resizable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &resizable)
        let title = axString(element, kAXTitleAttribute) ?? ""
        let identifier = axString(element, "AXIdentifier").flatMap { $0.isEmpty ? nil : $0 }
        // Finder can expose a browsing window before its subrole and resize capability settle.
        // Use the same bounded retry as a missing AX window before committing a floating placement.
        if window.bundleID == "com.apple.finder", identifier == "FinderWindow",
           (kind != .normal || !resizable.boolValue), retryClassification(window.id) {
            return nil
        }
        attempts[window.id] = nil
        return classify(window, kind: kind, resizable: resizable.boolValue, title: title, identifier: identifier,
                        lacksFullscreen: lacksFullscreen(element, bundleID: window.bundleID))
    }

    private func retryClassification(_ id: UInt32) -> Bool {
        let tries = attempts[id, default: 0] + 1
        attempts[id] = tries
        guard tries < 5 else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, let window = model.windows[id] else { return }
            track(window)
            flush()
        }
        return true
    }

    /// Applies the AX facts read above. Keep command scheduling separate from execution: a window must be
    /// placed before its workspace commands run. The fullscreen heuristic stays lazy and cannot override rules.
    func classify(_ window: Window, kind: WindowKind, resizable: Bool, title: String, identifier: String?,
                  lacksFullscreen: @autoclosure () -> Bool,
                  enqueue: (Command, UInt32) -> Void = enqueueRule) -> (floating: Bool, runsRules: Bool) {
        windowIdentifiers[window.id] = identifier
        // `layout floating` and `layout tiling` decide here, the last one wins. Other rule commands, such as
        // move-window-to-workspace, run for this window once it is placed.
        var floats: Bool?
        var runsRules = false
        for command in config.commands(for: window, kind: kind, title: title, identifier: identifier) {
            switch command {
            case .layout([.floating]): floats = true
            case .layout([.tiling]): floats = false
            default:
                runsRules = true
                enqueue(command, window.id)
            }
        }
        let floating = kind != .normal || !resizable
            || (floats ?? (config.floatWindowsWithoutFullscreen && lacksFullscreen()))
        return (floating, runsRules)
    }
}

private func enqueueRule(_ command: Command, _ window: UInt32) {
    DispatchQueue.main.async {
        let reply = Dispatcher.run(command, window: window)
        if !reply.ok { fputs("rule: \(reply.text)\n", stderr) }
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
    // The timeout is per element, and the button's would otherwise be the 6 s default, on the main thread.
    let buttonElement = button as! AXUIElement
    AXUIElementSetMessagingTimeout(buttonElement, FrameApplier.timeout)
    var enabled: CFTypeRef?
    AXUIElementCopyAttributeValue(buttonElement, kAXEnabledAttribute as CFString, &enabled)
    return enabled as? Bool == true
}

extension Config {
    /// The commands of every rule that matches, in order. Commands that do not parse are skipped.
    func commands(for window: Window, kind: WindowKind, title: String, identifier: String?) -> [Command] {
        rules.filter { $0.matches(appId: window.bundleID, appName: window.appName, title: title, kind: kind, windowIdentifier: identifier) }
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
