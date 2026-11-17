import Foundation
import Testing
@testable import DinkyConfig

struct ConfigIssuesTests {
    @Test func `Fixes change only their spans and preserve comments`() throws {
        let toml = "# orientation\n[master] # orientation\norientation = 'left' # orientation\n"
        let issues = try parsedIssues(toml)

        let result = ConfigIssues.applyFixes(issues, to: toml)

        #expect(result.text == "# orientation\n[master] # orientation\nside = 'left' # orientation\n")
        #expect(result.applied == issues)
    }

    @Test func `Warnings are listed by line after the error, keeping order within a line`() {
        let error = ConfigError(path: "bad", "broken", line: 9)
        let warnings = [
            ConfigWarning(path: "eight", "w", line: 8),
            ConfigWarning(path: "none", "w"),
            ConfigWarning(path: "two-a", "w", line: 2),
            ConfigWarning(path: "five", "w", line: 5),
            ConfigWarning(path: "two-b", "w", line: 2)
        ]

        let paths = ConfigIssues.issues(error: error, warnings: warnings).map(\.path)

        #expect(paths == ["bad", "two-a", "two-b", "five", "eight", "none"])
    }

    @Test func `Two fixes on one line each edit only their own key's value`() throws {
        let toml = "gaps = { outer = -40, inner = -4 }\n"
        let issues = try parsedIssues(toml)
        #expect(issues.count == 2)

        let result = ConfigIssues.applyFixes(issues, to: toml)

        #expect(result.text == "gaps = { outer = 0, inner = 0 }\n")
        #expect(result.applied == issues)
        #expect(try Config.parse(result.text).warnings.isEmpty)
    }

    @Test func `A fix is declined unless its value is written exactly as it says`() throws {
        // The suggestions name -2 and inf; the file says -2.0 and +inf. Rather than guess, nothing is written.
        for toml in ["[borders]\nwidth = -2.0\n", "[borders]\nwidth = +inf\n"] {
            let issues = try parsedIssues(toml)
            #expect(issues.count == 1)

            let result = ConfigIssues.applyFixes(issues, to: toml)

            #expect(result.text == toml)
            #expect(result.applied.isEmpty)
        }
    }

    @Test func `Workspace keys are renamed in place, inside their quotes`() throws {
        let toml = "[workspace-to-display]\n'+2' = 'secondary' # +2\n01 = 'main'\n"
        let issues = try parsedIssues(toml)

        let result = ConfigIssues.applyFixes(issues, to: toml)

        #expect(result.text == "[workspace-to-display]\n'2' = 'secondary' # +2\n1 = 'main'\n")
        #expect(result.applied == issues)
    }

    @Test func `Line numbers count the lines inside multi-line strings`() throws {
        let toml = "[mode.main]\nalt-h = \"\"\"\nfocus left\"\"\"\n[gaps]\ninner = -4\n"
        let issues = try parsedIssues(toml)
        #expect(issues.map(\.line) == [5])

        #expect(ConfigIssues.applyFixes(issues, to: toml).text == toml.replacingOccurrences(of: "-4", with: "0"))
    }

    @Test func `An edit that matches two pairs on its line is declined`() {
        let toml = "rules = [{ app-id = 'a', run = 'float' }, { app-id = 'a', run = 'float' }]\n"
        let issue = ConfigIssue(ConfigWarning(path: "rules[1].app-id", "w", line: 1, fix: .value(of: "app-id", "a", to: "b")))

        let result = ConfigIssues.applyEdits([issue], to: toml)

        #expect(result.text == toml)
        #expect(result.applied.isEmpty)
    }

    @Test func `An edit whose result would not load is declined`() {
        // Renaming orientation while side is set would repeat the key; the parser never suggests it, and if a
        // fix ever did, the edited text fails to parse and the file is left alone.
        let toml = "[master]\norientation = 'left'\nside = 'right'\n"
        let issue = ConfigIssue(ConfigWarning(path: "master.orientation", "w", line: 2,
                                              fix: .rename("orientation", to: "side")))

        let result = ConfigIssues.applyEdits([issue], to: toml)

        #expect(result.text == toml)
        #expect(result.applied.isEmpty)
    }

    @Test func `The same fix twice is applied once`() throws {
        let toml = "[gaps]\ninner = -4\n"
        let issues = try parsedIssues(toml)

        let result = ConfigIssues.applyFixes(issues + issues, to: toml)

        #expect(result.text == "[gaps]\ninner = 0\n")
        #expect(result.applied == issues)
    }

    @Test func `The fixer edits the line the parser names, whatever the line breaks`() throws {
        for toml in ["[master]\r\norientation = 'left'\r\n", "# a\u{2028}b\n[master]\norientation = 'left'\n"] {
            let issues = try parsedIssues(toml)
            #expect(issues.map(\.path) == ["master.orientation"])

            let result = ConfigIssues.applyFixes(issues, to: toml)

            #expect(result.text == toml.replacingOccurrences(of: "orientation", with: "side"))
            #expect(result.applied == issues)
        }
    }

    @Test func `A file without a final newline stays without one`() throws {
        let toml = "[master]\norientation = 'left'"

        #expect(ConfigIssues.applyFixes(try parsedIssues(toml), to: toml).text == "[master]\nside = 'left'")
    }

    @Test func `File fixes back up the old file and write the new file`() throws {
        let directory = try temporaryDirectory()
        let url = directory.appending(path: "dinky.toml")
        let old = "[master]\norientation = 'left'\n"
        try old.write(to: url, atomically: false, encoding: .utf8)
        let issues = try parsedIssues(old)

        let applied = try ConfigIssues.applyFixes(issues, at: url)

        #expect(applied == issues)
        #expect(try String(contentsOf: url, encoding: .utf8) == "[master]\nside = 'left'\n")
        #expect(try String(contentsOf: url.appendingPathExtension("bak"), encoding: .utf8) == old)
    }

    @Test func `Outdated fixes are declined instead of applied to another setting`() throws {
        let issues = try parsedIssues("[gaps]\ninner = -4\n")
        #expect(issues.count == 1)
        let url = try temporaryDirectory().appending(path: "dinky.toml")

        // Another key now holds the line, or the key moved to another line: the fix no longer matches a warning.
        for current in ["[gaps]\nouter = -40\n", "# moved\n[gaps]\ninner = -4\n"] {
            try current.write(to: url, atomically: false, encoding: .utf8)

            #expect(try ConfigIssues.applyFixes(issues, at: url).isEmpty)
            #expect(try String(contentsOf: url, encoding: .utf8) == current)
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
        }

        // The warning is still reported where it was, so the fix applies even though the file changed elsewhere.
        try "[gaps]\ninner = -4\nouter = 8\n".write(to: url, atomically: false, encoding: .utf8)
        #expect(try ConfigIssues.applyFixes(issues, at: url) == issues)
        #expect(try String(contentsOf: url, encoding: .utf8) == "[gaps]\ninner = 0\nouter = 8\n")
    }

    @Test func `Issue lists cross off fixed rows and reopen returning rows`() {
        let first = ConfigIssue(ConfigWarning(path: "one", "first"))
        let second = ConfigIssue(ConfigWarning(path: "two", "second"))
        let list = ConfigIssueList(rows: [
            .init(issue: first, fixed: false), .init(issue: second, fixed: false)
        ])

        let fixed = list.updated(with: [second])
        #expect(fixed?.rows == [.init(issue: second, fixed: false), .init(issue: first, fixed: true)])
        #expect(fixed?.updated(with: []) == nil)
        #expect(fixed?.updated(with: [first])?.rows == [.init(issue: first, fixed: false),
                                                         .init(issue: second, fixed: true)])
    }

    @Test func `Issue lists preserve current order before fixed rows`() {
        let old = ConfigIssue(ConfigWarning(path: "old", "old"))
        let current = ConfigIssue(ConfigWarning(path: "current", "current"))
        let list = ConfigIssueList(rows: [.init(issue: old, fixed: false)])

        #expect(list.updated(with: [current])?.rows == [.init(issue: current, fixed: false),
                                                         .init(issue: old, fixed: true)])
    }

    @Test func `Actions reflect open fixable rows`() {
        let fix = ConfigFix.rename("old", to: "new")
        let fixable = ConfigIssue(ConfigWarning("fixable", fix: fix))
        let plain = ConfigIssue(ConfigWarning("plain"))

        #expect(ConfigIssueActions.forOpenRows([.init(issue: fixable, fixed: false)]) == .applyAll)
        #expect(ConfigIssueActions.forOpenRows([.init(issue: fixable, fixed: false),
                                                 .init(issue: plain, fixed: false)]) == .applySuggestions)
        #expect(ConfigIssueActions.forOpenRows([.init(issue: plain, fixed: false)]) == .dismissOnly)
        #expect(ConfigIssueActions.forOpenRows([.init(issue: fixable, fixed: true)]) == .dismissOnly)
    }

    @Test func `Parsed warnings can be fixed and parsed cleanly`() throws {
        let toml = "[master]\norientation = 'right'\n[gaps]\ninner = -4\n"
        let parsed = try Config.parse(toml)
        let issues = ConfigIssues.issues(error: nil, warnings: parsed.warnings)
        let fixed = ConfigIssues.applyFixes(issues, to: toml)

        #expect(fixed.applied == issues)
        #expect(try Config.parse(fixed.text).warnings.isEmpty)
    }

    /// The issues the window would list for `toml`.
    private func parsedIssues(_ toml: String) throws -> [ConfigIssue] {
        ConfigIssues.issues(error: nil, warnings: try Config.parse(toml).warnings)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
