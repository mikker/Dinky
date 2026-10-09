import Foundation
import TOMLDecoder

/// A TOML table read strictly: every key read is remembered and `done()` rejects the rest, so a
/// typo like `gap` is an error instead of being ignored. Each read returns nil when the key is
/// absent and throws a `ConfigError` naming the key path when the value has the wrong type.
///
/// This walks `TOMLTable` directly rather than going through `Decodable`: TOMLDecoder 0.4.4's
/// `Decoder` crashes on custom coding keys and hands scalars to table decoders.
final class Table {
    let path: String
    private let table: TOMLTable
    private var used: Set<String> = []

    init(_ table: TOMLTable, path: String = "") {
        self.table = table
        self.path = path
    }

    var keys: [String] { table.keys }

    func path(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

    func bool(_ key: String) throws -> Bool? { try scalar(key, "true or false") { try $0.bool(forKey: key) } }
    func int(_ key: String) throws -> Int? { try scalar(key, "an integer") { Int(try $0.integer(forKey: key)) } }
    func double(_ key: String) throws -> Double? { try scalar(key, "a number") { try $0.float(forKey: key) } }

    func number(_ key: String) throws -> Double? {
        try scalar(key, "a number") { table in
            if let integer = try? table.integer(forKey: key) { return Double(integer) }
            return try table.float(forKey: key)
        }
    }

    func string(_ key: String) throws -> String? {
        // TOMLDecoder crashes reading a one digit integer as a string, so rule integers out first.
        if (try? table.integer(forKey: key)) != nil { throw ConfigError(path: path(key), "expected a string") }
        return try scalar(key, "a string") { try $0.string(forKey: key) }
    }

    /// A value that must be one of `T`'s raw values, e.g. `'tiles'` for `LayoutKind`.
    func choice<T: RawRepresentable & CaseIterable>(_ key: String) throws -> T? where T.RawValue == String {
        guard let raw = try string(key) else { return nil }
        guard let value = T(rawValue: raw) else {
            let choices = T.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
            throw ConfigError(path: path(key), "'\(raw)' is not one of \(choices)")
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
        guard use(key) else { return nil }
        guard let strings = stringArray(key) else { throw ConfigError(path: path(key), "expected a list of strings") }
        return strings
    }

    /// A string or a list of them, e.g. display patterns.
    func stringOrStrings(_ key: String) throws -> [String]? {
        guard use(key) else { return nil }
        guard let strings = stringArray(key) ?? (try? string(key)).map({ [$0] }) else {
            throw ConfigError(path: path(key), "expected a string or a list of strings")
        }
        return strings
    }

    func table(_ key: String) throws -> Table? {
        guard use(key) else { return nil }
        guard let nested = try? table.table(forKey: key) else { throw ConfigError(path: path(key), "expected a table") }
        return Table(nested, path: path(key))
    }

    /// An array of tables, as written with `[[key]]`.
    func tables(_ key: String) throws -> [Table]? {
        guard use(key) else { return nil }
        guard let array = try? table.array(forKey: key) else { throw ConfigError(path: path(key), "expected a list of tables") }
        return try (0..<array.count).map { index in
            let path = "\(path(key))[\(index)]"
            guard let nested = try? array.table(atIndex: index) else { throw ConfigError(path: path, "expected a table") }
            return Table(nested, path: path)
        }
    }

    /// A command string or a list of them, none blank. Commands stay strings here; the dispatcher owns
    /// the vocabulary. An empty list is an error unless `allowEmpty`, as it is for hooks.
    func commands(_ key: String, allowEmpty: Bool = false) throws -> [String]? {
        guard use(key) else { return nil }
        guard let commands = stringArray(key) ?? (try? string(key)).map({ [$0] }) else {
            throw ConfigError(path: path(key), "expected a command string or a list of them")
        }
        if (commands.isEmpty && !allowEmpty) || commands.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw ConfigError(path: path(key), "commands can't be empty")
        }
        return commands
    }

    /// Whether the value at `key` is a table.
    func isTable(_ key: String) -> Bool { (try? table.table(forKey: key)) != nil }

    func done() throws {
        if let unknown = keys.first(where: { !used.contains($0) }) {
            throw ConfigError(path: path(unknown), "unknown key")
        }
    }

    /// Marks `key` as read; returns whether it is present.
    private func use(_ key: String) -> Bool {
        used.insert(key)
        return table.contains(key: key)
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

    private func scalar<T>(_ key: String, _ expected: String, _ read: (TOMLTable) throws -> T) throws -> T? {
        guard use(key) else { return nil }
        do {
            return try read(table)
        } catch {
            throw ConfigError(path: path(key), "expected \(expected)", line: lineNumber(in: error))
        }
    }
}

/// TOMLDecoder puts the line in its error text, e.g. `(Line 3) Invalid integer value ...`.
private func lineNumber(in error: Error) -> Int? {
    let text = "\(error)"
    guard let range = text.range(of: #"(?<=\(Line )\d+"#, options: .regularExpression) else { return nil }
    return Int(text[range])
}
