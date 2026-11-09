import AppKit
import DinkyCommands
import DinkyConfig

// Window classification for the coordinator: the AX window kind, its fullscreen button and the config's `[[rules]]`.

/// A real settling interval, independent of how many window events arrive during the opening animation.
final class ClassificationSettlement {
    let deadline: TimeInterval
    init(now: TimeInterval) { deadline = now + 1 }
    func isWaiting(at now: TimeInterval) -> Bool { now < deadline }
}

extension Coordinator {
    /// Classify only once AX is usable or its settling interval expires. Rules run only on the final snapshot.
    func classify(_ window: Window) -> (floating: Bool, runsRules: Bool)? {
        guard let element = axWindow(pid: window.pid, wid: window.id, timeout: FrameApplier.timeout) else {
            return awaitClassification(window.id, unsettled: true) ? nil : (true, false)
        }
        let subrole = axString(element, kAXSubroleAttribute)
        let kind = windowKind(subrole: subrole)
        var resizable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &resizable)
        let title = axString(element, kAXTitleAttribute) ?? ""
        let identifier = axString(element, "AXIdentifier").flatMap { $0.isEmpty ? nil : $0 }
        // Standard windows can briefly refuse resizing while opening. Known dialogs and panels need no wait.
        if awaitClassification(window.id, unsettled: subrole == nil || (kind == .normal && !resizable.boolValue)) { return nil }
        return classify(window, kind: kind, resizable: resizable.boolValue, title: title, identifier: identifier,
                        lacksFullscreen: lacksFullscreen(element, bundleID: window.bundleID))
    }

    /// One deadline and one retry chain per window, shared by missing AX and incomplete AX facts.
    func awaitClassification(_ id: UInt32, unsettled: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard unsettled else {
            settlements[id] = nil
            return false
        }
        let settlement: ClassificationSettlement
        if let pending = settlements[id] {
            settlement = pending
        } else {
            settlement = ClassificationSettlement(now: now)
            settlements[id] = settlement
            retryClassification(id, settlement: settlement)
        }
        guard settlement.isWaiting(at: now) else {
            settlements[id] = nil
            return false
        }
        return true
    }

    private func retryClassification(_ id: UInt32, settlement: ClassificationSettlement) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak settlement] in
            guard let self, let settlement, settlements[id] === settlement,
                  let window = model.windows[id] else { return }
            track(window)
            flush()
            if settlements[id] === settlement, settlement.isWaiting(at: ProcessInfo.processInfo.systemUptime) {
                retryClassification(id, settlement: settlement)
            }
        }
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
