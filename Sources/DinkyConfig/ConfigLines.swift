import Foundation

/// One line of config text and the line break that ends it, empty for a last line without one.
struct ConfigLine: Equatable {
    var content: String
    let ending: String
}

/// Splits config text into lines, so that joining `content + ending` gives the text back byte for byte.
///
/// This is the one line-counting rule for the config: `\r\n`, `\n` and a lone `\r` each end one line.
/// Line numbers in warnings and errors and any edit made by line number go through it, so they always agree.
/// Swift reads `\r\n` as one `Character`, which keeps it a single break. `Character.isNewline` is not used
/// because it also breaks on form feed, vertical tab and Unicode line separators, which TOML does not.
func configLines(_ text: String) -> [ConfigLine] {
    var lines: [ConfigLine] = []
    var content = ""
    for character in text {
        if character == "\r\n" || character == "\n" || character == "\r" {
            lines.append(ConfigLine(content: content, ending: String(character)))
            content = ""
        } else {
            content.append(character)
        }
    }
    if !content.isEmpty { lines.append(ConfigLine(content: content, ending: "")) }
    return lines
}
