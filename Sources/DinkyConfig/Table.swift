import Foundation
import TOMLDecoder

/// The warnings of one parse, shared by the root table and every table nested in it.
final class ConfigWarningSink {
    var warnings: [ConfigWarning] = []
}

/// A TOML table read strictly: every key read is remembered and `done()` rejects the rest, so a
/// typo like `gap` is an error instead of being ignored. Each read returns nil when the key is
/// absent and throws a `ConfigError` naming the key path when the value has the wrong type.
///
/// This walks `TOMLTable` directly rather than going through `Decodable`: TOMLDecoder 0.4.4's
/// `Decoder` crashes on custom coding keys and hands scalars to table decoders.
final class Table {
    let path: String
    private let table: TOMLTable
    let warningSink: ConfigWarningSink
    private var used: Set<String> = []
    /// Old key names already warned about, so reading a key twice warns once.
    private var compatibilityWarnings: Set<String> = []

    init(_ table: TOMLTable, path: String = "", warningSink: ConfigWarningSink = ConfigWarningSink()) {
        self.table = table
        self.path = path
        self.warningSink = warningSink
    }

    var keys: [String] { table.keys }

    func path(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

    /// Records a warning at `key`; `parse` fills in its line.
    func warn(_ key: String, _ message: String, fix: ConfigFix? = nil) {
        warningSink.warnings.append(ConfigWarning(path: path(key), message, fix: fix))
    }

    func bool(_ key: String) throws -> Bool? { try scalar(key, "true or false") { try $0.bool(forKey: $1) } }
    func int(_ key: String) throws -> Int? { try scalar(key, "an integer") { Int(try $0.integer(forKey: $1)) } }
    func double(_ key: String) throws -> Double? { try scalar(key, "a number") { try $0.float(forKey: $1) } }

    func string(_ key: String) throws -> String? {
        // TOMLDecoder crashes reading a one digit integer as a string, so rule integers out first.
        guard let actualKey = use(key) else { return nil }
        if (try? table.integer(forKey: actualKey)) != nil { throw ConfigError(path: path(actualKey), "expected a string") }
        return try scalar(actualKey, "a string") { try $0.string(forKey: $1) }
    }

    /// A value that must be one of `T`'s raw values, e.g. `'tiles'` for `LayoutKind`.
    func choice<T: RawRepresentable & CaseIterable>(_ key: String) throws -> T? where T.RawValue == String {
        guard let actualKey = use(key), let raw = try string(actualKey) else { return nil }
        guard let value = T(rawValue: raw) else {
            let choices = T.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
            throw ConfigError(path: path(actualKey), "'\(raw)' is not one of \(choices)")
        }
        return value
    }

    func color(_ key: String) throws -> Color? {
        guard let hex = try string(key) else { return nil }
        do {
            return try Color(hex: hex)
        } catch {
            throw ConfigError(path: path(key), error.message)
        }
    }

    /// A list of strings, e.g. bundle IDs.
    func strings(_ key: String) throws -> [String]? {
        guard let actualKey = use(key) else { return nil }
        guard let strings = stringArray(actualKey) else { throw ConfigError(path: path(actualKey), "expected a list of strings") }
        return strings
    }

    /// A string or a list of them, e.g. display patterns.
    func stringOrStrings(_ key: String) throws -> [String]? {
        guard let actualKey = use(key) else { return nil }
        guard let strings = stringArray(actualKey) ?? (try? string(actualKey)).map({ [$0] }) else {
            throw ConfigError(path: path(key), "expected a string or a list of strings")
        }
        return strings
    }

    func table(_ key: String) throws -> Table? {
        guard let actualKey = use(key) else { return nil }
        guard let nested = try? table.table(forKey: actualKey) else { throw ConfigError(path: path(actualKey), "expected a table") }
        return Table(nested, path: path(actualKey), warningSink: warningSink)
    }

    /// An array of tables, as written with `[[key]]`.
    func tables(_ key: String) throws -> [Table]? {
        guard let actualKey = use(key) else { return nil }
        guard let array = try? table.array(forKey: actualKey) else { throw ConfigError(path: path(actualKey), "expected a list of tables") }
        return try (0..<array.count).map { index in
            let path = "\(path(actualKey))[\(index)]"
            guard let nested = try? array.table(atIndex: index) else { throw ConfigError(path: path, "expected a table") }
            return Table(nested, path: path, warningSink: warningSink)
        }
    }

    /// A command string or a list of them, none blank. Commands stay strings here; the dispatcher owns
    /// the vocabulary. An empty list is an error unless `allowEmpty`, as it is for hooks.
    func commands(_ key: String, allowEmpty: Bool = false) throws -> [String]? {
        guard let actualKey = use(key) else { return nil }
        guard let commands = stringArray(actualKey) ?? (try? string(actualKey)).map({ [$0] }) else {
            throw ConfigError(path: path(key), "expected a command string or a list of them")
        }
        if (commands.isEmpty && !allowEmpty) || commands.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw ConfigError(path: path(key), "commands can't be empty")
        }
        return commands
    }

    /// Whether the value at `key` is a table.
    func isTable(_ key: String) -> Bool {
        guard let actualKey = present(key) else { return false }
        return (try? table.table(forKey: actualKey)) != nil
    }

    func done() throws {
        if let unknown = keys.first(where: { !used.contains($0) }) {
            throw ConfigError(path: path(unknown), "unknown key")
        }
    }

    /// Marks `key` as read, warning once about an old name; returns the name it is written under, nil if absent.
    private func use(_ key: String) -> String? {
        let change = keyChangeForNew(key)
        if table.contains(key: key) {
            used.insert(key)
            if let change, table.contains(key: change.old) {
                used.insert(change.old)
                if compatibilityWarnings.insert(change.old).inserted {
                    warn(change.old, "ignored: '\(key)' is set (renamed from '\(change.old)' in \(change.version))")
                }
            }
            return key
        }
        guard let change, table.contains(key: change.old) else { return nil }
        used.insert(change.old)
        if compatibilityWarnings.insert(change.old).inserted {
            warn(change.old, "renamed to '\(change.new)' in \(change.version); the old name still works",
                 fix: ConfigFix(replace: change.old, with: change.new))
        }
        return change.old
    }

    /// The name `key` is written under in the TOML: itself, or the old name of a renamed key. Reads nothing.
    private func present(_ key: String) -> String? {
        if table.contains(key: key) { return key }
        guard let change = keyChangeForNew(key), table.contains(key: change.old) else { return nil }
        return change.old
    }

    /// The array at `key` if it holds only strings.
    private func stringArray(_ key: String) -> [String]? {
        guard let array = try? table.array(forKey: key) else { return nil }
        var strings: [String] = []
        for index in 0..<array.count {
            // As in string(_:): rule integers out before reading a string.
            guard (try? array.integer(atIndex: index)) == nil, let string = try? array.string(atIndex: index) else { return nil }
            strings.append(string)
        }
        return strings
    }

    private func scalar<T>(_ key: String, _ expected: String, _ read: (TOMLTable, String) throws -> T) throws -> T? {
        guard let actualKey = use(key) else { return nil }
        do {
            return try read(table, actualKey)
        } catch {
            throw ConfigError(path: path(actualKey), "expected \(expected)", line: lineNumber(in: error))
        }
    }

    private func keyChangeForNew(_ key: String) -> KeyChange? {
        KeyChange.shipped.first { $0.table == normalizedPath && $0.new == key }
    }

    private var normalizedPath: String {
        path.replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
    }
}

/// TOMLDecoder puts the line in its error text, e.g. `(Line 3) Invalid integer value ...`.
private func lineNumber(in error: Error) -> Int? {
    let text = "\(error)"
    guard let range = text.range(of: #"(?<=\(Line )\d+"#, options: .regularExpression) else { return nil }
    return Int(text[range])
}
