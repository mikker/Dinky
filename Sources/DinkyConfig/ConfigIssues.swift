import Foundation

/// The model for dinky's config issues window: ordered open issues followed by issues fixed by the last reload.
public struct ConfigIssue: Equatable, CustomStringConvertible {
    public var path: String
    public var message: String
    public var line: Int?
    public var fix: ConfigFix?
    public var isError: Bool

    public init(path: String, message: String, line: Int? = nil, fix: ConfigFix? = nil, isError: Bool = false) {
        self.path = path
        self.message = message
        self.line = line
        self.fix = fix
        self.isError = isError
    }

    public init(_ warning: ConfigWarning) {
        self.init(path: warning.path, message: warning.message, line: warning.line, fix: warning.fix)
    }

    public init(_ error: ConfigError) {
        self.init(path: error.path, message: error.message, line: error.line, fix: error.fix, isError: true)
    }

    public var description: String {
        if isError {
            return ConfigError(path: path, message, line: line, fix: fix).description
        }
        return ConfigWarning(path: path, message, line: line, fix: fix).description
    }
}

/// Builds, applies and persists the model shown by dinky's config issues window.
public enum ConfigIssues {
    public static let documentationURL = URL(string: "https://github.com/mikker/Dinky/blob/main/docs/configuration.md")!

    public static func issues(error: ConfigError?, warnings: [ConfigWarning]) -> [ConfigIssue] {
        (error.map { [ConfigIssue($0)] } ?? []) + warnings.map(ConfigIssue.init)
    }

    /// Applies the first matching replacement on each issue's line without re-serialising the TOML.
    public static func applyFixes(_ issues: [ConfigIssue], to toml: String) -> (text: String, applied: [ConfigIssue]) {
        var lines = splitLines(toml)
        var applied: [ConfigIssue] = []
        for issue in issues {
            guard let fix = issue.fix, let lineNumber = issue.line,
                  lines.indices.contains(lineNumber - 1),
                  let range = lines[lineNumber - 1].content.range(of: fix.replace) else { continue }
            lines[lineNumber - 1].content.replaceSubrange(range, with: fix.with)
            applied.append(issue)
        }
        return (lines.map { $0.content + $0.ending }.joined(), applied)
    }

    /// Applies the fixes to the file at `url`, first copying it to `<name>.bak`. Writes nothing when no fix applies.
    public static func applyFixes(_ issues: [ConfigIssue], at url: URL) throws -> [ConfigIssue] {
        let original = try String(contentsOf: url, encoding: .utf8)
        let result = applyFixes(issues, to: original)
        guard !result.applied.isEmpty else { return [] }

        let backup = url.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: backup)
        }
        try FileManager.default.copyItem(at: url, to: backup)
        try result.text.write(to: url, atomically: true, encoding: .utf8)
        return result.applied
    }

    private struct Line {
        var content: String
        let ending: String
    }

    /// Lines with their own endings, so joining them gives back the text byte for byte. Swift reads `\r\n` as
    /// one Character, which `isNewline` covers along with `\n` and `\r`.
    private static func splitLines(_ text: String) -> [Line] {
        var lines: [Line] = []
        var start = text.startIndex
        while start < text.endIndex {
            guard let newline = text[start...].firstIndex(where: \.isNewline) else {
                lines.append(Line(content: String(text[start...]), ending: ""))
                break
            }
            lines.append(Line(content: String(text[start..<newline]), ending: String(text[newline])))
            start = text.index(after: newline)
        }
        return lines
    }
}

/// What the window lists: the current issues, then those a reload no longer reports, crossed off.
public struct ConfigIssueList: Equatable {
    public struct Row: Equatable {
        public let issue: ConfigIssue
        public let fixed: Bool

        public init(issue: ConfigIssue, fixed: Bool) {
            self.issue = issue
            self.fixed = fixed
        }
    }

    public var rows: [Row]

    public init(rows: [Row] = []) {
        self.rows = rows
    }

    /// The list after a reload reporting `current`, or nil when the config is clean and the window closes. Issues
    /// match by path and message, since an edit moves line numbers.
    public func updated(with current: [ConfigIssue]) -> ConfigIssueList? {
        guard !current.isEmpty else { return nil }
        let currentKeys = Set(current.map(Self.key))
        let open = current.map { Row(issue: $0, fixed: false) }
        let fixed = rows.filter { !currentKeys.contains(Self.key($0.issue)) }
            .map { Row(issue: $0.issue, fixed: true) }
        return ConfigIssueList(rows: open + fixed)
    }

    public var action: ConfigIssueActions {
        ConfigIssueActions.forOpenRows(rows)
    }

    private static func key(_ issue: ConfigIssue) -> String {
        issue.path + "\u{0}" + issue.message
    }
}

/// The window's apply button: "Apply All" when every open issue has a fix, "Apply Suggestions" when some do.
public enum ConfigIssueActions: Equatable {
    case applyAll, applySuggestions, dismissOnly

    public static func forOpenRows(_ rows: [ConfigIssueList.Row]) -> Self {
        let open = rows.filter { !$0.fixed }
        let fixable = open.filter { $0.issue.fix != nil }
        if !open.isEmpty, fixable.count == open.count { return .applyAll }
        if !fixable.isEmpty { return .applySuggestions }
        return .dismissOnly
    }
}
