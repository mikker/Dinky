import Testing
@testable import DinkyConfig

struct GapsTests {
    private let builtIn = Monitor(name: "Built-in Retina Display", isMain: false, count: 2)
    private let dell = Monitor(name: "DELL U2723QE", isMain: true, count: 2)

    @Test func `Numbers and tables`() throws {
        let gaps = try Config.parse("[gaps]\ninner = 6\nouter = 4\n").gaps
        #expect(gaps.inner == Inner(6))
        #expect(gaps.outer == Sides(4))
        let split = try Config.parse("[gaps]\ninner = { horizontal = 8, vertical = 6 }\nouter = { top = 44, left = 2 }\n").gaps
        #expect(split.inner == Inner(horizontal: 8, vertical: 6))
        #expect(split.outer == Sides(top: 44, bottom: 8, left: 2, right: 8), "sides left out keep the default")
        let dotted = try Config.parse("[gaps]\ninner.vertical = 0\nouter.top = 44\n").gaps
        #expect(dotted.inner == Inner(horizontal: 8, vertical: 0))
        #expect(dotted.outer.top == 44)
    }

    @Test func `Display overrides`() throws {
        let config = try Config.parse("""
        [gaps]
        inner = 12
        outer = 8

        [display.main]
        gaps.outer.top = 44

        [display.built-in]
        gaps.outer.top = 10
        gaps.inner = 6
        """)
        #expect(config.displays.count == 2)
        #expect(config.gaps(for: dell) == Gaps(inner: Inner(12), outer: Sides(top: 44, bottom: 8, left: 8, right: 8)))
        #expect(config.gaps(for: builtIn) == Gaps(inner: Inner(6), outer: Sides(top: 10, bottom: 8, left: 8, right: 8)))
        #expect(config.gaps(for: Monitor(name: "LG", isMain: false, count: 3)) == config.gaps, "no match, no change")
    }

    @Test func `Name pattern beats main and longer name beats shorter`() throws {
        let config = try Config.parse("""
        [display.main]
        gaps.outer.top = 1
        gaps.outer.bottom = 1
        [display.dell]
        gaps.outer.top = 2
        [display."dell u2723"]
        gaps.outer.top = 3
        """)
        let gaps = config.gaps(for: dell)
        #expect(gaps.outer.top == 3)
        #expect(gaps.outer.bottom == 1, "the overrides layer, each one only changes what it sets")
    }

    @Test func `Workspace to display`() throws {
        let config = try Config.parse("""
        workspaces = 4
        [workspace-to-display]
        4 = 'secondary'
        2 = ['dell', 'main']
        """)
        #expect(config.workspaceDisplays == [4: [.secondary], 2: [.name("dell"), .main]])
        #expect(try Config.parse("").workspaceDisplays == [:])
        assertError("[workspace-to-display]\n6 = 'main'\n", path: "workspace-to-display.6", line: 2, contains: "from 1 to 5")
        assertError("[workspace-to-display]\nfive = 'main'\n", path: "workspace-to-display.five", line: 2, contains: "not a workspace number")
        assertError("[workspace-to-display]\n1 = ''\n", path: "workspace-to-display.1", line: 2, contains: "can't be empty")
        assertError("[workspace-to-display]\n1 = 2\n", path: "workspace-to-display.1", line: 2, contains: "string")
        // `01` and `+1` would both be workspace 1, silently overriding each other.
        assertError("[workspace-to-display]\n01 = 'main'\n", path: "workspace-to-display.01", line: 2, contains: "not a workspace number")
        assertError("[workspace-to-display]\n'+1' = 'main'\n", path: "workspace-to-display.+1", line: 2, contains: "not a workspace number")
        assertError("[display.main]\nworkspaces = 1\n", path: "display.main.workspaces", line: 2, contains: "[workspace-to-display]")
    }

    @Test func patterns() {
        #expect(MonitorPattern.main.matches(dell))
        #expect(!MonitorPattern.main.matches(builtIn))
        #expect(MonitorPattern.secondary.matches(builtIn))
        #expect(!MonitorPattern.secondary.matches(Monitor(name: "x", isMain: false, count: 3)))
        #expect(MonitorPattern.name("built-in").matches(builtIn))
        #expect(MonitorPattern.name("dell").matches(dell), "case-insensitive substring")
        #expect(!MonitorPattern.name("built-in").matches(Monitor(name: "Apple Virtual Display", isMain: true, count: 1)))
    }

    @Test func `Bad gaps fail`() {
        assertError("[gaps]\nouter.top = 'wide'\n", path: "gaps.outer.top", line: 2, contains: "expected an integer")
        assertError("[gaps]\nouter.top = [{ monitor.main = 44 }, 8]\n", path: "gaps.outer.top", line: 2, contains: "expected an integer")
        assertError("[gaps]\ninner.diagonal = 3\n", path: "gaps.inner.diagonal", line: 2, contains: "unknown key")
        assertError("[display.main]\nborders.width = 2\n", path: "display.main.borders", line: 2, contains: "unknown key")
        assertError("[display.main]\ngaps.outer.tpo = 2\n", path: "display.main.gaps.outer.tpo", line: 2, contains: "unknown key")
        assertError("[display]\ngaps.outer.top = 2\n", path: "display.gaps.outer", line: 2, contains: "unknown key")
    }
}
