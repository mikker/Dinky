import Foundation
import Testing
@testable import DinkyConfig

struct ConfigTests {
    @Test func `Default config loads`() throws {
        let config = try Config.parse(Config.defaultTOML)
        #expect(config == Config.default)
        #expect(config.startAtLogin)
        #expect(config.workspaces == 5)
        #expect(config.defaultLayout == .tiles)
        #expect(config.defaultTiling)
        #expect(config.followAppActivation)
        #expect(config.floatWindowsWithoutFullscreen)
        #expect(config.accordion.padding == 30)
        #expect(config.accordion.orientation == .auto)
        #expect(config.gaps == Gaps())
        #expect(config.displays == [])
        #expect(config.borders.enabled)
        #expect(config.borders.width == 4)
        #expect(config.borders.activeColor == Color(red: 0xE1 / 255, green: 0xE3 / 255, blue: 0xE4 / 255))
        #expect(config.hooks == Hooks())
        #expect(config.rules.count == 1)
        #expect(config.rules[0].appId == "com.apple.systempreferences")
        #expect(config.rules[0].run == ["layout floating"])
        #expect(Set(config.modes.keys) == ["main", "service"])
        let main = config.modes["main"]!.bindings
        #expect(try main[KeyCombo("ctrl-left")] == ["workspace prev"])
        #expect(try main[KeyCombo("alt-9")] == ["workspace 9"])
        #expect(try main[KeyCombo("alt-shift-9")] == ["move-window-to-workspace 9"])
        #expect(try main[KeyCombo("alt-k")] == ["focus up"])
        #expect(try main[KeyCombo("alt-shift-l")] == ["move right"])
        #expect(try main[KeyCombo("alt-shift-semicolon")] == ["mode service"])
        #expect(main.count == 37)
        #expect(try config.modes["service"]!.bindings[KeyCombo("esc")] == ["reload-config", "mode main"])
        #expect(try config.modes["service"]!.bindings[KeyCombo("alt-shift-j")] == ["join-with down", "mode main"])
    }

    @Test func `Shipped file is the defaults plus rules and bindings`() throws {
        var shipped = Config.default
        shipped.rules = []
        shipped.modes = [:]
        #expect(shipped == Config(), "a key left out of a user's file must mean what the shipped file says")
    }

    @Test func `Empty config uses defaults`() throws {
        #expect(try Config.parse("") == Config())
    }

    @Test func `Top-level keys`() throws {
        let config = try Config.parse("""
        start-at-login = false
        workspaces = 3
        default-layout = 'accordion'
        follow-app-activation = false
        float-windows-without-fullscreen = false
        """)
        #expect(!config.startAtLogin)
        #expect(config.workspaces == 3)
        #expect(config.defaultLayout == .accordion)
        #expect(!config.followAppActivation)
        #expect(!config.floatWindowsWithoutFullscreen)
        assertError("workspaces = 0\n", path: "workspaces", line: 1, contains: "at least 1")
        assertError("default-layout = 'stack'\n", path: "default-layout", line: 1, contains: "'tiles', 'dwindle', 'accordion', 'fixed', 'scrolling'")
    }

    @Test func `Workspace layouts`() throws {
        let config = try Config.parse("""
        default-tiling = false
        [workspace.2]
        tiling = true
        layout = 'fixed'
        columns = 2
        rows = 3
        expand = 'accordion'
        [workspace.3]
        layout = 'accordion'
        """)
        #expect(!config.settings(forWorkspace: 1).tiling)
        let fixed = config.settings(forWorkspace: 2)
        #expect(fixed.tiling)
        #expect(fixed.layout == .fixed)
        #expect(fixed.columns == 2)
        #expect(fixed.rows == 3)
        #expect(fixed.expand == .accordion)
        let accordion = config.settings(forWorkspace: 3)
        #expect(!accordion.tiling, "omitted keys inherit the top-level settings")
        #expect(accordion.layout == .accordion)
        #expect(accordion.rows == 1)
        #expect(accordion.columns == 1)
        #expect(accordion.expand == .columns)
        #expect(config.settings(forWorkspace: nil) == WorkspaceSettings(tiling: false, layout: .tiles),
                "an unnumbered workspace gets the top-level settings")
        assertError("[workspace.0]\nlayout = 'fixed'\n", path: "workspace.0", line: 1, contains: "positive workspace number")
        assertError("[workspace.2]\nlayout = 'fixed'\ncolumns = 0\n", path: "workspace.2.columns", line: 3, contains: "at least 1")
        assertError("[workspace.2]\nlayout = 'fixed'\nrows = 0\n", path: "workspace.2.rows", line: 3, contains: "at least 1")
        assertError("[workspace.2]\nlayout = 'dwindle'\ncolumns = 2\n", path: "workspace.2.columns", line: 3, contains: "only valid")
        assertError("[workspace.2]\ncolumns = 2\n", path: "workspace.2.columns", line: 2, contains: "only valid")
        let inherited = try Config.parse("default-layout = 'fixed'\n[workspace.2]\ncolumns = 3\n")
        #expect(inherited.settings(forWorkspace: 2).columns == 3)
        #expect(inherited.settings(forWorkspace: 2).rows == 1)
        let oneByOne = try Config.parse("[workspace.2]\nlayout = 'fixed'\n")
        #expect(oneByOne.settings(forWorkspace: 2).columns == 1)
        #expect(oneByOne.settings(forWorkspace: 2).rows == 1)
        assertError("[workspace.2]\nlayout = 'fixed'\nexpand = 'diagonal'\n", path: "workspace.2.expand", line: 3, contains: "'rows', 'columns', 'accordion'")
    }

    @Test func `Workspace settings per display`() throws {
        let config = try Config.parse("""
        [workspace.2]
        layout = 'fixed'
        columns = 2
        [workspace.2.display.built-in]
        layout = 'accordion'
        [workspace.2.display.main]
        rows = 2
        [workspace.2.display.'Built-in Retina']
        tiling = false
        [workspace.3.display.secondary]
        layout = 'scrolling'
        """)
        let ultrawide = Monitor(name: "DELL U3824DW", isMain: true, count: 2)
        let laptop = Monitor(name: "Built-in Retina Display", isMain: false, count: 2)
        let otherLaptop = Monitor(name: "Built-in Liquid Retina XDR Display", isMain: false, count: 2)
        #expect(config.settings(forWorkspace: 2).layout == .fixed, "without a display, the workspace's own")
        let main = config.settings(forWorkspace: 2, on: ultrawide)
        #expect((main.layout, main.columns, main.rows) == (.fixed, 2, 2), "omitted keys come from the workspace")
        #expect(config.settings(forWorkspace: 2, on: otherLaptop).layout == .accordion)
        #expect(!config.settings(forWorkspace: 2, on: laptop).tiling, "the longest name wins")
        #expect(config.settings(forWorkspace: 2, on: laptop).layout == .fixed, "and inherits from the workspace, not other displays")
        #expect(config.settings(forWorkspace: 3, on: laptop).layout == .scrolling)
        #expect(config.settings(forWorkspace: 3, on: ultrawide).layout == .tiles)
        #expect(config.settings(forWorkspace: 1, on: laptop) == config.settings(forWorkspace: 1))
        let ties = try Config.parse("[workspace.1.display.main]\nlayout = 'accordion'\n[workspace.1.display.secondary]\nlayout = 'fixed'\n")
        #expect(ties.settings(forWorkspace: 1, on: Monitor(name: "x", isMain: true, count: 1)).layout == .accordion)
        assertError("[workspace.2.display.main]\ncolumns = 2\n", path: "workspace.2.display.main.columns", line: 2, contains: "only valid")
        assertError("[workspace.2.display.main]\ngaps.inner = 2\n", path: "workspace.2.display.main.gaps", line: 2, contains: "unknown key")
        assertError("[workspace.2.display.main.display.dell]\nlayout = 'fixed'\n", path: "workspace.2.display.main.display",
                    line: 1, contains: "unknown key")
        assertError("[workspace.2.display.'']\nlayout = 'fixed'\n", path: "workspace.2.display", line: 1, contains: "can't be empty")
    }

    @Test func `Unknown top-level key fails`() {
        assertError("workspaces = 3\ngap = 8\n", path: "gap", line: 2, contains: "unknown key")
        assertError("config-version = 1\n", path: "config-version", line: 1, contains: "unknown key")
        assertError("auto-reload-config = true\n", path: "auto-reload-config", line: 1, contains: "unknown key")
    }

    @Test func `Unknown key in table fails`() {
        assertError("[gaps]\ninner = 8\n\n[borders]\nwidht = 4\n", path: "borders.widht", line: 5, contains: "unknown key")
        assertError("[gaps]\nouter = { top = 8, tpo = 8 }\n", path: "gaps.outer.tpo", line: 2, contains: "unknown key")
        assertError("[[rules]]\napp-idd = 'x'\nrun = 'y'\n", path: "rules[0].app-idd", line: 2, contains: "unknown key")
        assertError("[switching]\nfollow-app-activation = true\n", path: "switching", line: 1, contains: "unknown key")
        assertError("[layout]\ndefault = 'tiles'\n", path: "layout", line: 1, contains: "unknown key")
        assertError("[borders]\nonly-apps = []\n", path: "borders.only-apps", line: 2, contains: "unknown key")
    }

    @Test func `Bad type fails`() {
        assertError("[gaps]\ninner = 'wide'\n", path: "gaps.inner", line: 2, contains: "expected an integer")
        assertError("workspaces = true\n", path: "workspaces", line: 1, contains: "expected an integer")
        assertError("gaps = 8\n", path: "gaps", line: 1, contains: "expected a table")
        assertError("[accordion]\norientation = 'sideways'\n", path: "accordion.orientation", line: 2, contains: "'auto', 'keep'")
    }

    @Test func accordion() throws {
        let accordion = try Config.parse("[accordion]\npadding = 12\norientation = 'keep'\n").accordion
        #expect(accordion.padding == 12)
        #expect(accordion.orientation == .keep)
    }

    @Test func scrolling() throws {
        #expect(Config().scrolling.columnWidth == 0.49)
        #expect(try Config.parse("[scrolling]\ncolumn-width = 0.5\n").scrolling.columnWidth == 0.5)
        #expect(try Config.parse("default-layout = 'scrolling'\n").defaultLayout == .scrolling)
        assertError("[scrolling]\ncolumn-width = 1.5\n", path: "scrolling.column-width", line: 2, contains: "0.1 to 1")
    }

    @Test func `Syntax error has line`() {
        let error = #expect(throws: ConfigError.self) {
            try Config.parse("workspaces = 5\n[gaps\n")
        }
        if let error { #expect("\(error)".contains("Line 2"), "\(error)") }
    }

    @Test func colours() throws {
        #expect(try Color(hex: "#ff000080") == Color(red: 1, green: 0, blue: 0, alpha: 128 / 255))
        #expect(try Color(hex: "#00FF00") == Color(red: 0, green: 1, blue: 0))
        for bad in ["e1e3e4", "#e1e3", "#e1e3e4g", "#+1e3e4", "0xff0000", "0x80ff0000"] {
            #expect(throws: ConfigError.self, "\(bad)") { try Color(hex: bad) }
        }
        assertError("[borders]\nactive-color = 'red'\n", path: "borders.active-color", line: 2, contains: "'red' is not a colour")
    }

    @Test func borders() throws {
        #expect(Config().borders.order == .below)
        let borders = try Config.parse("""
        [borders]
        order = 'above'
        width = 2.5
        exclude-apps = ['com.apple.finder', 'com.apple.Terminal']
        """).borders
        #expect(borders.order == .above)
        #expect(borders.width == 2.5)
        #expect(borders.excludeApps == ["com.apple.finder", "com.apple.Terminal"])
        #expect(!borders.decorates(bundleID: "com.apple.finder"))
        #expect(borders.decorates(bundleID: "com.apple.TextEdit"))
        #expect(borders.decorates(bundleID: nil))

        assertError("[borders]\norder = 'over'\n", path: "borders.order", line: 2, contains: "'below', 'above'")
        assertError("[borders]\nexclude-apps = 'com.apple.finder'\n", path: "borders.exclude-apps", line: 2, contains: "list of strings")
    }

    @Test func `Binding values`() throws {
        let config = try Config.parse("""
        [mode.main]
        alt-a = 'workspace 1'
        alt-b = ['layout floating', 'mode main']

        [mode.resize]
        minus = 'resize smart -50'
        """)
        let bindings = config.modes["main"]!.bindings
        #expect(bindings[KeyCombo(modifiers: .alt, key: "a")] == ["workspace 1"])
        #expect(bindings[KeyCombo(modifiers: .alt, key: "b")] == ["layout floating", "mode main"])
        #expect(config.modes["resize"]!.bindings[KeyCombo(key: "minus")] == ["resize smart -50"])
    }

    @Test func `Bad binding values fail`() {
        assertError("[mode.main]\nalt-a = ''\n", path: "mode.main.alt-a", line: 2, contains: "can't be empty")
        assertError("[mode.main]\nalt-a = []\n", path: "mode.main.alt-a", line: 2, contains: "can't be empty")
        assertError("[mode.main]\nalt-a = 3\n", path: "mode.main.alt-a", line: 2, contains: "command string")
        assertError("[mode.main]\nalt-a = ['x', 3]\n", path: "mode.main.alt-a", line: 2, contains: "command string")
        assertError("[mode.main]\nalt-super-a = 'x'\n", path: "mode.main.alt-super-a", line: 2, contains: "'alt-super-a'")
        assertError("[mode.main]\nalt-shift-a = 'x'\nshift-alt-a = 'y'\n", path: "mode.main.shift-alt-a", line: 3, contains: "bound twice")
        assertError("[mode.main]\nhyper-a = 'x'\nctrl-alt-cmd-shift-a = 'y'\n", path: "mode.main.ctrl-alt-cmd-shift-a", line: 3, contains: "bound twice")
        assertError("[mode.main.binding]\nalt-a = 'x'\n", path: "mode.main.binding", line: 1, contains: "unknown key 'binding'")
    }

    @Test func `Window rule round-trips`() throws {
        let config = try Config.parse("""
        [[rules]]
        app-id = 'com.apple.finder'
        app-name = 'find'
        title = '^Copy'
        kind = 'dialog'
        run = ['layout floating', 'move-window-to-workspace 2']

        [[rules]]
        run = 'layout tiling'
        """)
        var expected = WindowRule()
        expected.appId = "com.apple.finder"
        expected.appName = "find"
        expected.title = "^Copy"
        expected.kind = .dialog
        expected.run = ["layout floating", "move-window-to-workspace 2"]
        var second = WindowRule()
        second.run = ["layout tiling"]
        #expect(config.rules == [expected, second])

        #expect(expected.matches(appId: "com.apple.finder", appName: "Finder", title: "Copy 3 items", kind: .dialog))
        #expect(!expected.matches(appId: "com.apple.finder", appName: "Finder", title: "Copy 3 items", kind: .normal))
        #expect(!expected.matches(appId: "com.apple.finder", appName: "Finder", title: "Desktop", kind: .dialog))
        #expect(!expected.matches(appId: "com.apple.Safari", appName: "Finder", title: "Copy", kind: .dialog))
        #expect(second.matches(appId: nil, appName: nil, title: "", kind: .normal), "a rule with no conditions matches everything")
    }

    @Test func `Window rule matches the bundle ID by regex`() throws {
        let config = try Config.parse("""
        [[rules]]
        app-id-regex = '^co\\.ensili\\.'
        run = 'layout floating'

        [[rules]]
        app-id = 'co.ensili.Scrivener'
        app-id-regex = 'scrivener$'
        run = 'layout floating'
        """)
        var expected = WindowRule()
        expected.appIdRegex = "^co\\.ensili\\."
        expected.run = ["layout floating"]
        #expect(config.rules.first == expected)

        let prefix = config.rules[0], both = config.rules[1]
        #expect(prefix.matches(appId: "co.ensili.Scrivener", appName: "Scrivener", title: "", kind: .normal))
        #expect(prefix.matches(appId: "CO.Ensili.Other", appName: nil, title: "", kind: .normal), "case-insensitive")
        #expect(!prefix.matches(appId: "uk.co.ensili.x", appName: nil, title: "", kind: .normal), "anchored by the pattern")
        #expect(!prefix.matches(appId: nil, appName: "Scrivener", title: "", kind: .normal), "no bundle ID never matches")
        #expect(both.matches(appId: "co.ensili.Scrivener", appName: nil, title: "", kind: .normal))
        #expect(!both.matches(appId: "co.ensili.scrivener", appName: nil, title: "", kind: .normal), "app-id stays exact")
    }

    @Test func `Bad window rules fail`() {
        assertError("[[rules]]\napp-id = 'x'\n", path: "rules[0].run", line: 1, contains: "every rule needs 'run'")
        assertError("[[rules]]\ntitle = '('\nrun = 'x'\n", path: "rules[0].title", line: 2, contains: "not a valid regex")
        assertError("[[rules]]\napp-id-regex = '['\nrun = 'x'\n", path: "rules[0].app-id-regex", line: 2, contains: "not a valid regex")
        assertError("[[rules]]\nkind = 'popup'\nrun = 'x'\n", path: "rules[0].kind", line: 2, contains: "'normal', 'dialog', 'sheet', 'panel'")
        assertError("[[rules]]\nif.app-id = 'x'\nrun = 'y'\n", path: "rules[0].if", line: 2, contains: "unknown key")
    }

    @Test func hooks() throws {
        #expect(Config.default.hooks == Hooks())
        let hooks = try Config.parse("""
        [hooks]
        startup = 'exec-and-forget brew services restart sketchybar'
        workspace-changing = 'exec-and-forget sketchybar --trigger workspace_changing'
        workspace-changed = ['exec-and-forget sketchybar --trigger workspace_change']
        focus-changed = []
        mode-changed = ['exec-and-forget sketchybar --trigger mode_changed', 'retile']
        display-changed = 'layout accordion'
        """).hooks
        #expect(hooks.startup == ["exec-and-forget brew services restart sketchybar"])
        #expect(hooks.workspaceChanging == ["exec-and-forget sketchybar --trigger workspace_changing"])
        #expect(hooks.workspaceChanged == ["exec-and-forget sketchybar --trigger workspace_change"])
        #expect(hooks.focusChanged == [])
        #expect(hooks.modeChanged == ["exec-and-forget sketchybar --trigger mode_changed", "retile"])
        #expect(hooks.displayChanged == ["layout accordion"])
        assertError("[hooks]\nmode-changed = [1]\n", path: "hooks.mode-changed", line: 2, contains: "command string")
        assertError("[hooks]\nstartup = ['']\n", path: "hooks.startup", line: 2, contains: "can't be empty")
        assertError("[hooks]\non-startup = 'x'\n", path: "hooks.on-startup", line: 2, contains: "unknown key")
        assertError("after-startup-command = ['x']\n", path: "after-startup-command", line: 1, contains: "unknown key")
    }

    @Test func `Focus follows mouse`() throws {
        let defaults = Config.default.focusFollowsMouse
        #expect(defaults == FocusFollowsMouse())
        #expect(!defaults.enabled)
        #expect(defaults.delayMs == 100)
        #expect(defaults.accordionEdges)
        let ffm = try Config.parse("""
        [focus-follows-mouse]
        enabled = true
        delay-ms = 0
        accordion-edges = false
        """).focusFollowsMouse
        #expect(ffm.enabled)
        #expect(ffm.delayMs == 0)
        #expect(!ffm.accordionEdges)
        assertError("[focus-follows-mouse]\ndelay-ms = -1\n", path: "focus-follows-mouse.delay-ms", line: 2, contains: "0 or more")
        assertError("[focus-follows-mouse]\naccordion = true\n", path: "focus-follows-mouse.accordion", line: 2, contains: "unknown key")
    }

    @Test func `Animations and drag`() throws {
        #expect(Config.default.animations == Animations())
        #expect(Config.default.drag == Drag())
        let config = try Config.parse("""
        [animations]
        enabled = false
        duration-ms = 300
        [drag]
        placeholders = false
        hold-to-split = true
        hold-ms = 250
        """)
        #expect(!config.animations.enabled)
        #expect(config.animations.durationMs == 300)
        #expect(!config.drag.placeholders)
        #expect(config.drag.holdToSplit)
        #expect(config.drag.holdMs == 250)
        assertError("[drag]\nhold-ms = -1\n", path: "drag.hold-ms", line: 2, contains: "0 or more")
        assertError("[animations]\nduration-ms = -1\n", path: "animations.duration-ms", line: 2, contains: "0 to 1000")
        assertError("[drag]\nghost = true\n", path: "drag.ghost", line: 2, contains: "unknown key")
    }

    @Test func `Modifier sides`() throws {
        #expect(Config.default.modifiers == ModifierSides())
        let config = try Config.parse("[modifiers]\nalt = 'left'\nshift = 'right'\n")
        #expect(config.modifiers.alt == .left)
        #expect(config.modifiers.ctrl == .both)
        #expect(config.modifiers.shift == .right)
        assertError("[modifiers]\nalt = 'up'\n", path: "modifiers.alt", line: 2, contains: "'both', 'left', 'right'")
        assertError("[modifiers]\nfn = 'left'\n", path: "modifiers.fn", line: 2, contains: "unknown key")
    }

    @Test func `Load from missing file fails`() {
        let error = #expect(throws: ConfigError.self) {
            try Config.load(from: URL(fileURLWithPath: "/nonexistent/dinky.toml"))
        }
        if let error { #expect("\(error)".contains("/nonexistent/dinky.toml")) }
    }
}
