import Foundation
import Testing
@testable import DinkyConfig

struct ConfigIssuesTests {
    @Test func `Fixes change only their spans and preserve comments`() {
        let issue = ConfigIssue(ConfigWarning(path: "old", "rename", line: 2,
                                              fix: ConfigFix(replace: "old", with: "new")))
        let toml = "# keep\nold = 1 # keep\nother = 2\n"

        let result = ConfigIssues.applyFixes([issue], to: toml)

        #expect(result.text == "# keep\nnew = 1 # keep\nother = 2\n")
        #expect(result.applied == [issue])
    }

    @Test func `Several fixes on one line apply in order`() {
        let issues = [
            ConfigIssue(ConfigWarning(path: "one", "first", line: 1,
                                      fix: ConfigFix(replace: "old", with: "new"))),
            ConfigIssue(ConfigWarning(path: "two", "second", line: 1,
                                      fix: ConfigFix(replace: "new", with: "final")))
        ]

        let result = ConfigIssues.applyFixes(issues, to: "old = 1\n")

        #expect(result.text == "final = 1\n")
        #expect(result.applied == issues)
    }

    @Test func `A fix missing from its line is skipped`() {
        let issue = ConfigIssue(ConfigWarning(path: "missing", "not here", line: 2,
                                              fix: ConfigFix(replace: "old", with: "new")))

        let result = ConfigIssues.applyFixes([issue], to: "old = 1\nother = 2\n")

        #expect(result.text == "old = 1\nother = 2\n")
        #expect(result.applied.isEmpty)
    }

    @Test func `CRLF line endings are kept and counted as one line break`() {
        let issue = ConfigIssue(ConfigWarning(path: "old", "rename", line: 2,
                                              fix: ConfigFix(replace: "old", with: "new")))

        let result = ConfigIssues.applyFixes([issue], to: "# keep\r\nold = 1\r\n")

        #expect(result.text == "# keep\r\nnew = 1\r\n")
        #expect(result.applied == [issue])
    }

    @Test func `A file without a final newline stays without one`() {
        let issue = ConfigIssue(ConfigWarning(path: "key", "rename", line: 1,
                                              fix: ConfigFix(replace: "old", with: "new")))

        #expect(ConfigIssues.applyFixes([issue], to: "old = 1").text == "new = 1")
    }

    @Test func `File fixes back up the old file and write the new file`() throws {
        let directory = try temporaryDirectory()
        let url = directory.appending(path: "dinky.toml")
        let old = "old = 1\n"
        try old.write(to: url, atomically: false, encoding: .utf8)
        let issue = ConfigIssue(ConfigWarning(path: "key", "rename", line: 1,
                                              fix: ConfigFix(replace: "old", with: "new")))

        let applied = try ConfigIssues.applyFixes([issue], at: url)

        #expect(applied == [issue])
        #expect(try String(contentsOf: url, encoding: .utf8) == "new = 1\n")
        #expect(try String(contentsOf: url.appendingPathExtension("bak"), encoding: .utf8) == old)
    }

    @Test func `File fixes write nothing when no fix applies`() throws {
        let directory = try temporaryDirectory()
        let url = directory.appending(path: "dinky.toml")
        let old = "old = 1\n"
        try old.write(to: url, atomically: false, encoding: .utf8)
        let issue = ConfigIssue(ConfigWarning(path: "key", "missing", line: 1,
                                              fix: ConfigFix(replace: "absent", with: "new")))

        let applied = try ConfigIssues.applyFixes([issue], at: url)

        #expect(applied.isEmpty)
        #expect(try String(contentsOf: url, encoding: .utf8) == old)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
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
        let fix = ConfigFix(replace: "old", with: "new")
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

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
