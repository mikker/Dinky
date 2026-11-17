import Testing
@testable import DinkyConfig

struct WindowIdentifierTests {
    private func matches(_ rule: WindowRule, _ identifier: String?) -> Bool {
        rule.match.matches(appId: "com.example.editor", appName: "Editor", title: "Untitled", kind: .normal,
                     windowIdentifier: identifier)
    }

    @Test func parsesIdentifierSelectors() throws {
        let rule = try Config.parse("""
        [[rules]]
        window-identifier = '^Settings$'
        exclude-window-identifier = 'Inspector'
        run = 'layout floating'
        """).rules[0]
        #expect(rule.match.windowIdentifier == "^Settings$")
        #expect(rule.match.excludeWindowIdentifier == "Inspector")
    }

    @Test func positiveMatchUsesAnchorsAndCaseInsensitiveRegex() {
        var rule = WindowRule()
        rule.match.windowIdentifier = "^DocumentSettingsWindow$"
        #expect(matches(rule, "documentsettingswindow"))
        #expect(!matches(rule, "OtherDocumentSettingsWindow"))
        #expect(!matches(rule, nil))
        rule.match.windowIdentifier = "Settings"
        #expect(matches(rule, "DocumentSettingsWindow"))
    }

    @Test func missingIdentifierDoesNotChangeExistingRules() {
        let rule = WindowRule()
        #expect(matches(rule, nil))
        #expect(matches(rule, "Anything"))
    }

    @Test func exclusionRejectsOnlyMatchingIdentifiers() {
        var rule = WindowRule()
        rule.match.excludeWindowIdentifier = "^Settings$"
        #expect(!matches(rule, "SETTINGS"))
        #expect(matches(rule, "Document"))
        #expect(matches(rule, nil))
        #expect(matches(rule, ""))
    }

    @Test func allConditionsStillHaveToMatch() {
        var rule = WindowRule()
        rule.match.appId = "com.other.editor"
        rule.match.windowIdentifier = "Settings"
        #expect(!matches(rule, "Settings"))
        rule.match.appId = "com.example.editor"
        rule.match.kind = .dialog
        #expect(!matches(rule, "Settings"))
        rule.match.kind = .normal
        rule.match.title = "Other"
        #expect(!matches(rule, "Settings"))
        rule.match.title = "Untitled"
        rule.match.excludeWindowIdentifier = "Settings"
        #expect(!matches(rule, "Settings"))
    }

    @Test func auxiliaryWindowSkipsTheEntireWorkspaceRule() throws {
        let rules = try Config.parse("""
        [[rules]]
        app-id = 'com.example.editor'
        exclude-window-identifier = '^Settings$'
        run = ['layout tiling', 'move-window-to-workspace 4 --follow']
        [[rules]]
        app-id = 'com.example.editor'
        window-identifier = '^Settings$'
        run = 'layout floating'
        """).rules
        #expect(rules.filter { matches($0, "Settings") }.flatMap(\.run) == ["layout floating"])
        #expect(rules.filter { matches($0, "Document") }.flatMap(\.run) ==
                ["layout tiling", "move-window-to-workspace 4 --follow"])
    }

    @Test func invalidPatternsReportTheSelectorKey() {
        for key in ["window-identifier", "exclude-window-identifier"] {
            do {
                _ = try Config.parse("[[rules]]\n\(key) = '['\nrun = 'layout floating'")
                Issue.record("Expected an invalid regex error")
            } catch {
                #expect(error.path == "rules[0].\(key)")
                #expect(error.message.contains("not a valid regex"))
            }
        }
    }
}
