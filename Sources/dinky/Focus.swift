import AppKit
import DinkyPrivate

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

func windowPID(_ wid: UInt32) -> pid_t? {
    let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]] ?? []
    return info.first?[kCGWindowOwnerPID as String] as? pid_t
}

// `timeout` (seconds) bounds how long AX calls on the app and the window may block. There is no default:
// unbounded, a hung app holds the main thread, and with it the key tap, for AX's 6 s default per call.
// Electron apps like Obsidian can answer AXWindows with an empty list while still naming the window
// as their main or focused one, so those are asked too.
func axWindow(pid: pid_t, wid: UInt32, timeout: Float) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, timeout)
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
    let windows = value as? [AXUIElement] ?? []
    guard let window = windows.first(where: { axWindowID($0) == wid })
        ?? [kAXMainWindowAttribute, kAXFocusedWindowAttribute].lazy.compactMap({ axElement(app, $0) })
            .first(where: { axWindowID($0) == wid }) else { return nil }
    AXUIElementSetMessagingTimeout(window, timeout)
    return window
}

private func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

private func axWindowID(_ element: AXUIElement) -> UInt32 {
    var wid: CGWindowID = 0
    return _AXUIElementGetWindow(element, &wid) == .success ? wid : 0
}

/// The app's main window, wherever it is: the one activating the app brings forward. 0 if it has none.
func mainWindowID(of pid: pid_t) -> UInt32 {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)
    return axElement(app, kAXMainWindowAttribute).map(axWindowID) ?? 0
}

/// The frontmost app's focused window, 0 if none. Asked on the main thread every half second, so bounded as
/// `mainWindowID` is: a hung app must not stall the key tap.
func frontWindowID() -> UInt32 {
    keyboardWindowID() ?? 0
}

/// Unlike the query convenience above, a focus repair must distinguish no key window from a failed AX read.
/// nil means unknown, not permission to activate another app.
func keyboardWindowID() -> UInt32? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 0.25)
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value)
    if error == .noValue { return 0 }
    guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    var id: UInt32 = 0
    guard _AXUIElementGetWindow(value as! AXUIElement, &id) == .success else { return nil }
    return id
}

/// Focuses a window on a Space that is on screen: AX raise, then activate its app. Never switches Spaces:
/// the activation is dinky's own, so the activation follower is told not to chase the app's frontmost
/// window, which can still be one on another Space when the activation lands. This is the primitive for windows
/// no tree models (e.g. `focusOnScreen` when the coordinator is not running); a window the coordinator models is
/// focused through `Coordinator.focus(_:)`, which also arms the grace against stale focus reads.
func focusWindow(pid: pid_t, id: UInt32) {
    // Focus is on a window again, even when it is the one that had it before a `focus-monitor`.
    AppState.shared.displays.focusOverride = nil
    if AppState.shared.displays.display(ofWindow: id) != nil {
        noteOwnSwitch()
    }
    if let element = axWindow(pid: pid, wid: id, timeout: FrameApplier.timeout) {
        // Raise alone makes the window main; the app's key window can stay one on another Space, and the
        // next command would then act on that one. Make this window main and key explicitly.
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
    NSRunningApplication(processIdentifier: pid)?.activate()
}

/// Activates Finder when `display` has no window to focus, as macOS does on an empty Space with the desktop shown.
/// Without the desktop, or with separate Spaces per display, macOS can leave active an app whose window is on another
/// Space. Left alone when activating Finder would bring one of its windows forward: one on screen, or one anywhere
/// when macOS switches to a Space with the app's windows.
func focusDesktop(of display: Display) {
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
          let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != finder.processIdentifier,
          dinky_window_space_id(frontWindowID()) != display.currentSpaceID else { return }
    let app = front.localizedName ?? "the front app"
    let swoosh = dockSetting("workspaces-auto-swoosh") ?? true
    guard normalWindows(of: finder.processIdentifier, swoosh ? [.optionAll] : [.optionOnScreenOnly]).isEmpty else {
        print("\(stamp()) focus: left the keyboard with \(app), activating Finder would show its window")
        fflush(stdout)
        return
    }
    print("\(stamp()) focus: activated Finder in place of \(app), which has no window here")
    fflush(stdout)
    noteOwnSwitch()
    finder.activate()
}
