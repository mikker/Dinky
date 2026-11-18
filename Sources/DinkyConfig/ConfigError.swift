import Foundation

/// A human-readable replacement suggestion, not a source span or an automatically applicable edit.
public struct ConfigFix: Equatable {
    public var replace: String
    public var with: String

    public init(replace: String, with: String) {
        self.replace = replace
        self.with = with
    }
}

/// Any problem loading the config: bad TOML, an unknown key, a wrong type or value.
/// `description` is the text to show in the menu bar and the log.
public struct ConfigError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Dotted key path such as `gaps.outer.top` or `rules[0].app-id`; empty for file-level errors.
    public var path: String
    public var message: String
    public var line: Int?

    public init(path: String = "", _ message: String, line: Int? = nil) {
        self.path = path
        self.message = message
        self.line = line
    }

    public var description: String { configIssueDescription(path: path, message: message, line: line) }

    public var errorDescription: String? { description }
}

/// A config problem that does not stop loading, with an optional human-readable replacement suggestion.
public struct ConfigWarning: Equatable, CustomStringConvertible {
    public var path: String
    public var message: String
    public var line: Int?
    public var fix: ConfigFix?

    public init(path: String = "", _ message: String, line: Int? = nil, fix: ConfigFix? = nil) {
        self.path = path
        self.message = message
        self.line = line
        self.fix = fix
    }

    public var description: String { configIssueDescription(path: path, message: message, line: line, fix: fix) }
}

private func configIssueDescription(path: String, message: String, line: Int?, fix: ConfigFix? = nil) -> String {
    let location = [line.map { "line \($0)" }, path.isEmpty ? nil : path].compactMap { $0 }
    let description = location.isEmpty ? message : location.joined(separator: ", ") + ": " + message
    guard let fix else { return description }
    return description + " (suggestion: replace '\(fix.replace)' with '\(fix.with)')"
}

/// Best effort line lookup for a key path, for errors TOMLDecoder gives no line for, such as unknown keys.
/// Tracks `[table]` headers and dotted keys, and returns the line whose full key shares the longest prefix
/// with `path`, either way round: a typo inside an inline table points at the line holding the table, and an
/// unknown table written as a dotted key, `if.app-id = 'x'`, points at that line.
func lineNumber(of path: String, in toml: String) -> Int? {
    let target = keyParts(path.replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression))
    var header: [String] = []
    var best: (line: Int, length: Int)?
    for (index, rawLine) in configLines(toml).enumerated() {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let full: [String]
        if line.hasPrefix("[") {
            header = keyParts(tableKey(line))
            full = header
        } else if let equals = line.firstIndex(of: "="), !line.hasPrefix("#") {
            full = header + keyParts(String(line[..<equals]))
        } else {
            continue
        }
        let shared = min(full.count, target.count)
        if shared > (best?.length ?? 0), Array(target.prefix(shared)) == Array(full.prefix(shared)) {
            best = (index + 1, shared)
        }
    }
    return best?.line
}

/// The key of a `[table]` or `[[table]]` line, without its brackets or a comment after them.
private func tableKey(_ line: String) -> String {
    var key = ""
    var quote: Character?
    for character in line.drop(while: { $0 == "[" }) {
        if let open = quote {
            if character == open { quote = nil }
        } else if character == "\"" || character == "'" {
            quote = character
        } else if character == "]" {
            break
        }
        key.append(character)
    }
    return key
}

private func keyParts(_ key: String) -> [String] {
    key.split(separator: ".").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
}
