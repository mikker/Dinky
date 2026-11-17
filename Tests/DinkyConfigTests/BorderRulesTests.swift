import Testing
@testable import DinkyConfig

struct BorderRulesTests {
    private func decorates(_ borders: Borders, identifier: String? = "Settings", title: String = "Untitled",
                           kind: WindowKind? = .normal, app: String? = "com.example.editor") -> Bool {
        borders.decorates(bundleID: app, appName: "Editor", title: title, kind: kind, identifier: identifier)
    }

    @Test func defaultAndLastMatchWins() throws {
        #expect(decorates(Borders()))
        let borders = try Config.parse("""
        [[borders.rules]]
        app-id = 'com.example.editor'
        enabled = false
        [[borders.rules]]
        window-identifier = '^Document$'
        enabled = true
        """).borders
        #expect(!decorates(borders))
        #expect(decorates(borders, identifier: "DOCUMENT"))
        #expect(!decorates(borders, identifier: nil))
        #expect(decorates(borders, app: "com.other.editor"))
    }

    @Test func sharesAllSelectorsWithPlacementRules() throws {
        let selectors = """
        app-id = 'com.example.editor'
        app-id-regex = '^com\\.example'
        app-name = '^editor$'
        title = '^Untitled$'
        kind = 'normal'
        window-identifier = 'settings'
        exclude-window-identifier = '^Inspector$'
        """
        let config = try Config.parse("""
        [[rules]]
        \(selectors)
        run = 'layout floating'
        [[borders.rules]]
        \(selectors)
        enabled = false
        """)
        #expect(config.rules[0].match == config.borders.rules[0].match)
        #expect(!decorates(config.borders))
        #expect(decorates(config.borders, title: "Document"))
        #expect(decorates(config.borders, kind: .dialog))
        #expect(decorates(config.borders, kind: nil))
        #expect(decorates(config.borders, identifier: nil))
        #expect(decorates(config.borders, identifier: "Inspector"))
    }

    @Test func globalAndAppVetoCannotBeOverridden() throws {
        var borders = try Config.parse("""
        [[borders.rules]]
        enabled = true
        """).borders
        borders.excludeApps = ["com.example.editor"]
        #expect(!decorates(borders))
        #expect(decorates(borders, app: nil))
        borders.enabled = false
        #expect(!decorates(borders, app: nil))
    }

    @Test func missingIdentifierDoesNotTriggerExclusion() throws {
        let borders = try Config.parse("""
        [[borders.rules]]
        exclude-window-identifier = '^Document$'
        enabled = false
        """).borders
        #expect(!decorates(borders, identifier: nil))
        #expect(decorates(borders, identifier: "Document"))
    }

    @Test func rejectsMissingEnabledCommandsAndInvalidPatterns() {
        assertError("[[borders.rules]]\ntitle = 'Settings'", path: "borders.rules[0].enabled", contains: "missing")
        assertError("[[borders.rules]]\nenabled = false\nrun = 'layout floating'",
                    path: "borders.rules[0].run", contains: "unknown")
        for key in ["app-id-regex", "app-name", "title", "window-identifier", "exclude-window-identifier"] {
            assertError("[[borders.rules]]\nenabled = false\n\(key) = '['",
                        path: "borders.rules[0].\(key)", contains: "not a valid regex")
        }
    }

    @Test func onlyDecorationChangesSkipWindowUpdates() throws {
        let previous = Config()
        #expect(previous.requiresWindowUpdate(comparedTo: previous))
        var changed = try Config.parse("[[borders.rules]]\nenabled = false")
        changed.borders.enabled = false
        changed.borders.width = 8
        changed.borders.excludeApps = ["com.example.editor"]
        #expect(!changed.requiresWindowUpdate(comparedTo: previous))
        changed.workspaces += 1
        #expect(changed.requiresWindowUpdate(comparedTo: previous))
        changed = previous
        changed.gaps = try Config.parse("[gaps]\ninner = 10").gaps
        #expect(changed.requiresWindowUpdate(comparedTo: previous))
    }
}
