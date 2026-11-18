/// The line-counting rule for config diagnostics: CRLF, LF and a lone CR each end one line.
/// Swift reads CRLF as one Character. Character.isNewline is not used because it also breaks on form feed,
/// vertical tab and Unicode line separators, which TOML does not.
func configLines(_ text: String) -> [Substring] {
    text.split(omittingEmptySubsequences: false) { $0 == "\r\n" || $0 == "\n" || $0 == "\r" }
}
