import CoreGraphics
import DinkyConfig
import Foundation

/// One key-down event tap with per-mode bindings. A bound key is swallowed and its command list
/// handed to `onCommands`; anything else passes through untouched. Mode commands are the caller's
/// job: it sees `mode service` among the commands and calls `setMode`.
final class HotkeyEngine {
    private let onCommands: ([String]) -> Void
    private var modes: [String: [KeyPress: [String]]] = [:]
    private var sides = ModifierSides()
    private(set) var currentMode = "main"
    var enabled = true
    /// Called with the new mode's name and the previous one whenever the mode changes.
    var onModeChange: ((_ mode: String, _ previous: String) -> Void)?
    private var tap: CFMachPort?

    /// `onCommands` is called on the main queue with the binding's commands, in order.
    init(onCommands: @escaping ([String]) -> Void) {
        self.onCommands = onCommands
    }

    /// Replaces all bindings and goes back to `main`.
    func load(modes: [String: Mode], sides: ModifierSides) {
        self.sides = sides
        self.modes = modes.mapValues { mode in
            Dictionary(uniqueKeysWithValues: mode.bindings.map { (KeyPress($0.key), $0.value) })
        }
        enter("main")
    }

    func setMode(_ name: String) {
        guard modes[name] != nil else {
            fputs("hotkeys: unknown mode '\(name)', staying in '\(currentMode)'\n", stderr)
            return
        }
        enter(name)
    }

    private func enter(_ name: String) {
        guard name != currentMode else { return }
        let previous = currentMode
        currentMode = name
        onModeChange?(name, previous)
    }

    /// Creates the tap on the current run loop, unless it exists. False if it could not (Accessibility missing);
    /// the caller reports that, since it tries again.
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: hotkeyCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    /// The commands bound to this event in the current mode, if dinky should take it.
    fileprivate func commands(for event: CGEvent) -> [String]? {
        guard enabled, let press = KeyPress(event, sides: sides) else { return nil }
        return modes[currentMode]?[press]
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, let commands = commands(for: event) else { return Unmanaged.passUnretained(event) }
        // Run the commands after the callback returns, so slow commands never time the tap out.
        DispatchQueue.main.async { self.onCommands(commands) }
        return nil
    }
}

private func hotkeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<HotkeyEngine>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
