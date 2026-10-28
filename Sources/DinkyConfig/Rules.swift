import Foundation

/// One `[[rules]]` entry: when a new window matches every condition that is set, run the commands.
/// `app-id` is an exact bundle ID; `app-id-regex`, `app-name` and `title` are case-insensitive
/// regexes found anywhere in the text. `window-identifier` matches AXIdentifier; its exclusion
/// rejects matching identifiers before any commands are queued. Missing identifiers do not match
/// a positive selector and do not trigger an exclusion.
public struct WindowRule: Equatable {
    public var appId: String?
    public var appIdRegex: String?
    public var appName: String?
    public var title: String?
    public var windowIdentifier: String?
    public var excludeWindowIdentifier: String?
    public var kind: WindowKind?
    public var run: [String] = []

    public init() {}

    init(_ t: Table) throws {
        appId = try t.string("app-id")
        appIdRegex = try regex(t, "app-id-regex")
        appName = try regex(t, "app-name")
        title = try regex(t, "title")
        windowIdentifier = try regex(t, "window-identifier")
        excludeWindowIdentifier = try regex(t, "exclude-window-identifier")
        kind = try t.choice("kind")
        guard let run = try t.commands("run") else { throw ConfigError(path: t.path("run"), "missing, every rule needs 'run'") }
        self.run = run
        try t.done()
    }

    /// Whether every condition that is set holds for this window.
    public func matches(appId: String?, appName: String?, title: String, kind: WindowKind, windowIdentifier: String? = nil) -> Bool {
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

/// `[mode.<name>]`: key combos mapped to the commands they run, in order.
public struct Mode: Equatable {
    public var bindings: [KeyCombo: [String]] = [:]

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
            bindings[combo] = try t.commands(key)
        }
        try t.done()
    }
}
