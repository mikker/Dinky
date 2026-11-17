import Foundation

/// Conditions shared by placement and decoration rules. Every supplied selector must match.
/// Regexes are case-insensitive searches; app-id is exact. Missing identifiers never match a
/// positive selector and never trigger an exclusion.
public struct WindowMatcher: Equatable {
    public var appId: String?
    public var appIdRegex: String?
    public var appName: String?
    public var title: String?
    public var windowIdentifier: String?
    public var excludeWindowIdentifier: String?
    public var kind: WindowKind?

    public init() {}

    init(_ t: Table) throws {
        appId = try t.string("app-id")
        appIdRegex = try regex(t, "app-id-regex")
        appName = try regex(t, "app-name")
        title = try regex(t, "title")
        windowIdentifier = try regex(t, "window-identifier")
        excludeWindowIdentifier = try regex(t, "exclude-window-identifier")
        kind = try t.choice("kind")
    }

    public func matches(appId: String?, appName: String?, title: String, kind: WindowKind?, windowIdentifier: String? = nil) -> Bool {
        func search(_ pattern: String?, _ text: String?) -> Bool {
            guard let pattern else { return true }
            return text?.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return (self.appId == nil || self.appId == appId) && (self.kind == nil || self.kind == kind)
            && search(appIdRegex, appId) && search(self.appName, appName) && search(self.title, title)
            && search(self.windowIdentifier, windowIdentifier)
            && (excludeWindowIdentifier.map { pattern in
                windowIdentifier?.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil
            } ?? true)
    }
}

/// One-shot commands for a newly classified window.
public struct WindowRule: Equatable {
    public var match = WindowMatcher()
    public var run: [String] = []

    public init() {}

    init(_ t: Table) throws {
        match = try WindowMatcher(t)
        guard let run = try t.commands("run") else { throw ConfigError(path: t.path("run"), "missing, every rule needs 'run'") }
        self.run = run
        try t.done()
    }
}

/// Persistent decoration, independent of placement. The last matching border rule wins.
public struct BorderRule: Equatable {
    public var match = WindowMatcher()
    public var enabled: Bool

    init(_ t: Table) throws {
        match = try WindowMatcher(t)
        guard let enabled = try t.bool("enabled") else {
            throw ConfigError(path: t.path("enabled"), "missing, every border rule needs 'enabled'")
        }
        self.enabled = enabled
        try t.done()
    }
}

private func regex(_ t: Table, _ key: String) throws -> String? {
    guard let pattern = try t.string(key) else { return nil }
    if (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)) == nil {
        throw ConfigError(path: t.path(key), "'\(pattern)' is not a valid regex")
    }
    return pattern
}

public enum WindowKind: String, CaseIterable {
    case normal, dialog, sheet, panel
}

/// What a key combo does: the commands it runs, in order, in every app but the excluded ones.
public struct KeyBinding: Equatable {
    public var commands: [String]
    /// Bundle IDs whose windows get the key instead: in them dinky leaves the combo alone.
    public var excludeApps: [String] = []

    public init(_ commands: [String], excludeApps: [String] = []) {
        self.commands = commands
        self.excludeApps = excludeApps
    }

    /// The table form, `{ command = ..., exclude-apps = [...] }`.
    init(_ t: Table) throws {
        guard let commands = try t.commands("command") else {
            throw ConfigError(path: t.path("command"), "missing, a binding table needs 'command'")
        }
        self.init(commands, excludeApps: try t.strings("exclude-apps") ?? [])
        try t.done()
    }

    /// Whether the combo is dinky's while this app is frontmost.
    public func applies(to bundleID: String?) -> Bool {
        !(bundleID.map(excludeApps.contains) ?? false)
    }
}

/// `[mode.<name>]`: key combos mapped to their bindings. A binding is a command string, a list of
/// them, or a table with `command` and `exclude-apps`.
public struct Mode: Equatable {
    public var bindings: [KeyCombo: KeyBinding] = [:]

    public init() {}

    init(_ t: Table) throws {
        for key in t.keys {
            let combo: KeyCombo
            do {
                combo = try KeyCombo(key)
            } catch {
                throw ConfigError(path: t.path(key), error.message)
            }
            if bindings[combo] != nil {
                throw ConfigError(path: t.path(key), "'\(combo)' is bound twice")
            }
            bindings[combo] = try t.isTable(key) ? KeyBinding(try t.table(key)!) : KeyBinding(try t.commands(key)!)
        }
        try t.done()
    }
}
