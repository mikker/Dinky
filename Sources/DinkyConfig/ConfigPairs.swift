import Foundation

/// Where one `key = value` pair sits in the config text, so that an edit can touch exactly that pair.
struct ConfigPair: Equatable {
    /// The line the key is on, counted by `configLines`.
    let line: Int
    /// The full key path without quotes or array indices: the table header, the keys of any inline table or array
    /// holding the pair, then the pair's own dotted key. `[gaps]` then `outer.top = 4` gives `gaps`, `outer`, `top`.
    let path: [String]
    /// The text of the last key segment, inside its quotes when it is quoted.
    let keyRange: Range<String.Index>
    /// The value's text: a bare value such as `-4`, `nan` or `true`, or the contents of a one-line string without
    /// its quotes. Nil for arrays, inline tables, multi-line strings and strings with escapes, which no fix edits.
    let valueRange: Range<String.Index>?
}

/// Every `key = value` pair in config text, including those in inline tables and arrays of them.
///
/// Returns nil when the text holds anything this scanner does not follow, such as a date with a space in it or a
/// quoted key with an escape, so a caller declines to edit instead of guessing where a value is.
func configPairs(in text: String) -> [ConfigPair]? {
    var scanner = PairScanner(text)
    return try? scanner.scan()
}

/// A small TOML scanner that follows strings, comments, tables and arrays only far enough to find each pair's
/// key and value. It does not check the TOML; callers scan text the config parser has already read.
private struct PairScanner {
    struct Unsupported: Error {}

    private let scalars: String.UnicodeScalarView
    private var index: String.Index
    private var line = 1
    private var pairs: [ConfigPair] = []

    init(_ text: String) {
        scalars = text.unicodeScalars
        index = scalars.startIndex
    }

    mutating func scan() throws -> [ConfigPair] {
        var header: [String] = []
        while true {
            skipBlank(newlines: true)
            guard let next = peek() else { return pairs }
            if next == "[" {
                header = try readHeader()
            } else {
                try readPair(in: header)
            }
            skipBlank(newlines: false)
            guard peek() == nil || isNewline(peek()) else { throw Unsupported() }
        }
    }

    /// `[table]` or `[[array.of.tables]]`; returns its key path.
    private mutating func readHeader() throws -> [String] {
        advance()
        let isArray = peek() == "["
        if isArray { advance() }
        let keys = try readKey().map(\.name)
        skipSpaces()
        try expect("]")
        if isArray { try expect("]") }
        return keys
    }

    private mutating func readPair(in prefix: [String]) throws {
        let keyLine = line
        let key = try readKey()
        skipSpaces()
        try expect("=")
        skipSpaces()
        let path = prefix + key.map(\.name)
        let value = try readValue(at: path)
        pairs.append(ConfigPair(line: keyLine, path: path, keyRange: key[key.count - 1].range, valueRange: value))
    }

    /// A dotted key: bare, `"basic"` or `'literal'` segments joined by dots.
    private mutating func readKey() throws -> [(name: String, range: Range<String.Index>)] {
        var segments: [(name: String, range: Range<String.Index>)] = []
        repeat {
            skipSpaces()
            let range: Range<String.Index>
            if let quote = peek(), quote == "\"" || quote == "'" {
                advance()
                guard let contents = try readOneLineString(closingWith: quote) else { throw Unsupported() }
                range = contents
            } else {
                let start = index
                while let next = peek(), isBareKeyCharacter(next) { advance() }
                guard start < index else { throw Unsupported() }
                range = start..<index
            }
            segments.append((String(scalars[range]), range))
            skipSpaces()
        } while consume(".")
        return segments
    }

    /// Reads one value and returns the range of its text when it is a bare value or a plain one-line string.
    private mutating func readValue(at path: [String]) throws -> Range<String.Index>? {
        guard let first = peek() else { throw Unsupported() }
        switch first {
        case "\"", "'":
            if peek(1) == first, peek(2) == first {
                try skipMultilineString(quote: first)
                return nil
            }
            advance()
            return try readOneLineString(closingWith: first)
        case "{":
            try readInlineTable(at: path)
            return nil
        case "[":
            try readArray(at: path)
            return nil
        default:
            let start = index
            while let next = peek(), !isNewline(next), !" \t,]}#".unicodeScalars.contains(next) { advance() }
            guard start < index else { throw Unsupported() }
            return start..<index
        }
    }

    private mutating func readInlineTable(at path: [String]) throws {
        advance()
        skipBlank(newlines: true)
        if consume("}") { return }
        while true {
            try readPair(in: path)
            skipBlank(newlines: true)
            if consume("}") { return }
            try expect(",")
            skipBlank(newlines: true)
            if consume("}") { return }
        }
    }

    private mutating func readArray(at path: [String]) throws {
        advance()
        while true {
            skipBlank(newlines: true)
            if consume("]") { return }
            _ = try readValue(at: path)
            skipBlank(newlines: true)
            if consume("]") { return }
            try expect(",")
        }
    }

    /// After the opening quote: the contents' range, or nil when a basic string has escapes.
    private mutating func readOneLineString(closingWith quote: Unicode.Scalar) throws -> Range<String.Index>? {
        let start = index
        var escaped = false
        while let next = peek(), !isNewline(next) {
            if next == quote {
                let contents = start..<index
                advance()
                return escaped ? nil : contents
            }
            if quote == "\"", next == "\\" {
                escaped = true
                advance()
                guard let escapedCharacter = peek(), !isNewline(escapedCharacter) else { throw Unsupported() }
            }
            advance()
        }
        throw Unsupported()
    }

    /// `"""…"""` or `'''…'''`, counting the lines inside. Up to two more quotes may end the contents.
    private mutating func skipMultilineString(quote: Unicode.Scalar) throws {
        advance(3)
        while let next = peek() {
            if next == quote, peek(1) == quote, peek(2) == quote {
                advance(3)
                if peek() == quote { advance() }
                if peek() == quote { advance() }
                return
            }
            if isNewline(next) {
                consumeNewline()
                continue
            }
            // A backslash escapes the next character, or ends the line, which the next round counts.
            if quote == "\"", next == "\\" {
                advance()
                if let escaped = peek(), !isNewline(escaped) { advance() }
                continue
            }
            advance()
        }
        throw Unsupported()
    }

    // MARK: Characters

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        var position = index
        for _ in 0..<offset {
            guard position < scalars.endIndex else { return nil }
            position = scalars.index(after: position)
        }
        return position < scalars.endIndex ? scalars[position] : nil
    }

    private mutating func advance(_ count: Int = 1) {
        for _ in 0..<count where index < scalars.endIndex { index = scalars.index(after: index) }
    }

    private mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
        guard peek() == scalar else { return false }
        advance()
        return true
    }

    private mutating func expect(_ scalar: Unicode.Scalar) throws {
        guard consume(scalar) else { throw Unsupported() }
    }

    /// `\r\n`, `\n` or a lone `\r`, the breaks `configLines` counts.
    private func isNewline(_ scalar: Unicode.Scalar?) -> Bool {
        scalar == "\n" || scalar == "\r"
    }

    private mutating func consumeNewline() {
        if consume("\r") { _ = consume("\n") } else { advance() }
        line += 1
    }

    private mutating func skipSpaces() {
        while peek() == " " || peek() == "\t" { advance() }
    }

    /// Spaces, tabs and comments, and line breaks too when `newlines` is set.
    private mutating func skipBlank(newlines: Bool) {
        while let next = peek() {
            if next == " " || next == "\t" {
                advance()
            } else if next == "#" {
                while let comment = peek(), !isNewline(comment) { advance() }
            } else if newlines, isNewline(next) {
                consumeNewline()
            } else {
                return
            }
        }
    }

    private func isBareKeyCharacter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
            || scalar == "_" || scalar == "-"
    }
}
