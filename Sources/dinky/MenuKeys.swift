import AppKit
import DinkyCommands
import DinkyConfig

// The menu shows each command's key binding the way macOS menus show shortcuts. The event tap takes
// bound keys before the menu sees them, so the key equivalents only label the items.

extension KeyCombo {
    /// The key equivalent and modifier mask for a menu item, nil for keys a menu cannot show.
    var menuKey: (String, NSEvent.ModifierFlags)? {
        guard let equivalent = KeyCombo.menuKeys[key] ?? (key.count == 1 ? key : nil) else { return nil }
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.alt) { mask.insert(.option) }
        if modifiers.contains(.ctrl) { mask.insert(.control) }
        if modifiers.contains(.cmd) { mask.insert(.command) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        return (equivalent, mask)
    }

    private static let menuKeys: [String: String] = {
        var keys: [String: String] = [
            "minus": "-", "equal": "=", "left-bracket": "[", "right-bracket": "]", "backslash": "\\",
            "semicolon": ";", "quote": "'", "comma": ",", "period": ".", "slash": "/", "backtick": "`",
            "section": "§", "space": " ", "enter": "\r", "esc": "\u{1b}", "tab": "\t", "backspace": "\u{8}",
        ]
        let functionKeys: [String: Int] = [
            "left": NSLeftArrowFunctionKey, "right": NSRightArrowFunctionKey,
            "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey,
            "page-up": NSPageUpFunctionKey, "page-down": NSPageDownFunctionKey,
            "home": NSHomeFunctionKey, "end": NSEndFunctionKey, "forward-delete": NSDeleteFunctionKey,
        ]
        for (name, code) in functionKeys { keys[name] = String(UnicodeScalar(UInt16(code))!) }
        for n in 1...20 { keys["f\(n)"] = String(UnicodeScalar(UInt16(NSF1FunctionKey + n - 1))!) }
        return keys
    }()
}

/// The bindings of one mode, looked up by the command they run. Lookups mark bindings as shown, so
/// the ones no menu item claimed can be listed on their own.
struct MenuBindings {
    private var bindings: [(combo: KeyCombo, commands: [String], parsed: Command?)]
    private var shown: Set<KeyCombo> = []

    init(_ mode: Mode?) {
        bindings = (mode?.bindings ?? [:])
            .map { combo, binding in
                let commands = binding.commands
                return (combo, commands, commands.count == 1 ? try? Command.parse(commands[0]) : nil)
            }
            .sorted { $0.combo.description < $1.combo.description }
    }

    /// The binding that runs exactly this command and nothing else.
    mutating func combo(for command: String) -> KeyCombo? {
        guard let parsed = try? Command.parse(command),
              let binding = bindings.first(where: { $0.parsed == parsed }) else { return nil }
        shown.insert(binding.combo)
        return binding.combo
    }

    /// Bindings no lookup has returned, with their commands.
    var unshown: [(combo: KeyCombo, commands: [String])] {
        bindings.filter { !shown.contains($0.combo) }.map { ($0.combo, $0.commands) }
    }
}
