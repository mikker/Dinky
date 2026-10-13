import Testing
import DinkyConfig
@testable import DinkyCommands

struct ConfigCheckTests {
    private func check(_ toml: String) throws -> [ConfigFinding] {
        checkConfig(try Config.parse(toml))
    }

    @Test func `Default config is clean`() throws {
        let findings = checkConfig(Config.default)
        #expect(findings == [])
    }

    @Test func `Missing main mode is a warning`() throws {
        let findings = try check("workspaces = 3")
        #expect(findings.map(\.level) == [.warning])
        #expect(findings[0].message.contains("[mode.main]"))
    }

    @Test func `Workspace table past the last workspace is a warning`() throws {
        let findings = try check("workspaces = 3\n[mode.main]\n[workspace.3]\ntiling = false\n[workspace.7]\ntiling = false\n[workspace.4]\ntiling = false")
        #expect(findings == [
            .init(level: .warning, message: "workspace.4: past the last workspace (3), so it does nothing"),
            .init(level: .warning, message: "workspace.7: past the last workspace (3), so it does nothing"),
        ])
    }

    @Test func `Unknown command in binding`() throws {
        let findings = try check("[mode.main]\nalt-h = 'fly left'")
        #expect(findings.count == 1)
        #expect(findings[0].level == .error)
        #expect(findings[0].message.hasPrefix("mode.main.alt-h:"))
    }

    @Test func `Mode command must name a mode`() throws {
        let findings = try check("[mode.main]\nalt-h = 'mode resize'")
        #expect(findings.count == 1)
        #expect(findings[0].message.contains("names a mode that is not in the config"))
        #expect(try check("[mode.main]\nalt-h = 'mode resize'\n[mode.resize]\nesc = 'mode main'") == [])
    }

    @Test func `Rule and hook commands are checked`() throws {
        let findings = try check("""
        [hooks]
        focus-changed = ['exec-and-forget true', 'nonsense']
        [mode.main]
        alt-h = 'focus left'
        [[rules]]
        app-id = 'com.apple.finder'
        run = 'layout floating'
        [[rules]]
        run = 'float'
        """)
        #expect(findings.count == 2)
        #expect(findings[0].message.hasPrefix("rules[1].run:"), "\(findings[0].message)")
        #expect(findings[1].message.hasPrefix("hooks.focus-changed:"), "\(findings[1].message)")
    }

    @Test func `Startup hook is checked`() throws {
        let findings = try check("""
        [hooks]
        startup = ['exec-and-forget true', 'balance-sizes', 'focus-monitor next', 'focus left --boundaries nowhere']
        """)
        #expect(findings.map(\.level) == [.warning, .error])
        #expect(findings[1].message.hasPrefix("hooks.startup:"), "\(findings[1].message)")
    }
}
