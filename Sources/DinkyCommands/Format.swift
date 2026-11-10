// `--format` strings of the list-* queries, AeroSpace style: text with `%{variable}` interpolation.
// `%{right-padding}` pads the column it ends to the widest value in that column across all rows,
// `%{newline}` and `%{tab}` insert those characters.

public struct Format: Equatable, Sendable {
    public enum Part: Equatable, Sendable {
        case text(String)
        case variable(String)
    }

    public let parts: [Part]

    static let special = ["right-padding", "newline", "tab"]

    /// Parses a format string, accepting only `variables` and the special ones. Throws a message naming
    /// the offending token.
    public init(_ string: String, variables: [String]) throws(CommandError) {
        var parts: [Part] = [], text = ""
        var i = string.startIndex
        while i < string.endIndex {
            guard string[i...].hasPrefix("%{") else {
                text.append(string[i])
                i = string.index(after: i)
                continue
            }
            let nameStart = string.index(i, offsetBy: 2)
            guard let end = string[nameStart...].firstIndex(of: "}") else {
                throw CommandError(input: string, message: "unclosed '%{' in format '\(string)'")
            }
            let name = String(string[nameStart..<end])
            guard variables.contains(name) || Self.special.contains(name) else {
                let known = (variables + Self.special.sorted()).map { "%{\($0)}" }.joined(separator: ", ")
                throw CommandError(input: string, message: "unknown format variable '%{\(name)}', expected one of: \(known)")
            }
            if !text.isEmpty { parts.append(.text(text)) }
            text = ""
            parts.append(.variable(name))
            i = string.index(after: end)
        }
        if !text.isEmpty { parts.append(.text(text)) }
        self.parts = parts
    }

    public func uses(_ variable: String) -> Bool { parts.contains(.variable(variable)) }

    /// One line per row. Variables missing from a row render empty.
    public func render(_ rows: [[String: String]]) -> String {
        let cells = rows.map(cells)
        let columns = cells.map(\.count).max() ?? 0
        let widths = (0..<columns).map { i in cells.map { i < $0.count ? $0[i].count : 0 }.max() ?? 0 }
        return cells.map { row in
            row.enumerated().map { i, cell in
                i == row.count - 1 ? cell : cell + String(repeating: " ", count: widths[i] - cell.count)
            }.joined()
        }.joined(separator: "\n")
    }

    /// The row's text split at each `%{right-padding}`.
    private func cells(_ row: [String: String]) -> [String] {
        var cells = [""]
        for part in parts {
            switch part {
            case .text(let text): cells[cells.count - 1] += text
            case .variable("right-padding"): cells.append("")
            case .variable("newline"): cells[cells.count - 1] += "\n"
            case .variable("tab"): cells[cells.count - 1] += "\t"
            case .variable(let name): cells[cells.count - 1] += row[name] ?? ""
            }
        }
        return cells
    }
}
