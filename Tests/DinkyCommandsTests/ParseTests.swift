import DinkyConfig
import DinkyLayout
import Testing
@testable import DinkyCommands

private func parse(_ s: String) throws -> Command { try Command.parse(s) }

struct ParseTests {
    @Test func workspace() throws {
        #expect(try parse("workspace 3") == .workspace(.number(3)))
        #expect(try parse("workspace prev") == .workspace(.prev))
        #expect(try parse("workspace next") == .workspace(.next))
        #expect(try parse("workspace-back-and-forth") == .workspaceBackAndForth)
    }

    @Test func `Move window to workspace`() throws {
        #expect(try parse("move-window-to-workspace 1") == .moveWindowToWorkspace(.number(1), follow: false))
        #expect(try parse("move-window-to-workspace 3 --follow") == .moveWindowToWorkspace(.number(3), follow: true))
        #expect(try parse("move-window-to-workspace --follow next") == .moveWindowToWorkspace(.next, follow: true))
        #expect(try parse("move-window-to-workspace prev") == .moveWindowToWorkspace(.prev, follow: false))
    }

    @Test func `Move a specific window to a workspace`() throws {
        #expect(try parse("move-window-to-workspace 3 --window-id 12345") ==
                .targetWindow(12345, .moveWindowToWorkspace(.number(3), follow: false)))
        #expect(try parse("move-window-to-workspace --window-id 12345 --follow next") ==
                .targetWindow(12345, .moveWindowToWorkspace(.next, follow: true)))
        for args in ["3 --window-id", "3 --window-id 0", "3 --window-id -1", "3 --window-id abc",
                     "3 --window-id 4294967296", "3 --window-id 1 --window-id 2"] {
            #expect(throws: CommandError.self) { try parse("move-window-to-workspace \(args)") }
        }
    }

    @Test func `Explicit window targets share parsing across supported commands`() throws {
        for (line, expected) in [
            ("move-window-to-workspace prev --follow", Command.moveWindowToWorkspace(.prev, follow: true)),
            ("move-window-to-display next --follow", .moveWindowToDisplay(.next, follow: true)),
            ("layout floating tiling", .layout([.floating, .tiling])),
            ("workspace-layout dwindle master", .workspaceLayout([.dwindle, .master]))
        ] {
            let words = line.split(separator: " ", maxSplits: 1)
            for command in ["\(line) --window-id 4294967295",
                            "\(words[0]) --window-id 4294967295 \(words[1])"] {
                #expect(try parse(command) == .targetWindow(UInt32.max, expected))
            }
            for value in ["", "0", "-1", "abc", "4294967296", "1 --window-id 2"] {
                #expect(throws: CommandError.self) { try parse("\(line) --window-id \(value)") }
            }
        }
        for line in ["workspace 2", "focus left", "move left", "fullscreen", "retile", "list-windows --all"] {
            #expect(throws: CommandError.self) { try parse("\(line) --window-id 123") }
        }
        #expect(try parse("exec-and-forget echo --window-id 123") == .execAndForget("echo --window-id 123"))
    }

    @Test func `Move window to display`() throws {
        #expect(try parse("move-window-to-display next") == .moveWindowToDisplay(.next, follow: false))
        #expect(try parse("move-window-to-display prev --follow") == .moveWindowToDisplay(.prev, follow: true))
    }

    @Test(arguments: [("left", Direction.left), ("down", .down), ("up", .up), ("right", .right)])
    func directional(word: String, dir: Direction) throws {
        #expect(try parse("focus \(word)") == .focus(dir))
        #expect(try parse("move \(word)") == .move(dir))
        #expect(try parse("join-with \(word)") == .joinWith(dir))
    }

    @Test func resize() throws {
        #expect(try parse("resize smart -50") == .resize(.smart, by: -50))
        #expect(try parse("resize smart +50") == .resize(.smart, by: 50))
        #expect(try parse("resize width +10") == .resize(.width, by: 10))
        #expect(try parse("resize height -20") == .resize(.height, by: -20))
    }

    @Test func layout() throws {
        #expect(try parse("layout tiles") == .layout([.tiles]))
        #expect(try parse("layout accordion") == .layout([.accordion]))
        #expect(try parse("layout floating") == .layout([.floating]))
        #expect(try parse("layout tiling") == .layout([.tiling]))
        #expect(try parse("layout floating tiling") == .layout([.floating, .tiling]))
        #expect(try parse("layout accordion tiles") == .layout([.accordion, .tiles]))
        #expect(try parse("layout horizontal vertical") == .layout([.horizontal, .vertical]))
        #expect(try parse("layout auto") == .layout([.auto]))
        #expect(try parse("layout accordion horizontal vertical") == .layout([.accordion, .horizontal, .vertical]))
        #expect(try parse("layout h_tiles v_tiles h_accordion v_accordion") == .layout([.hTiles, .vTiles, .hAccordion, .vAccordion]))
        #expect(try parse("layout floating h_accordion auto") == .layout([.floating, .hAccordion, .auto]))
        #expect(throws: CommandError.self) { try parse("layout scrolling") }
        #expect(throws: CommandError.self) { try parse("layout master") }
        #expect(throws: CommandError.self) { try parse("layout dwindle") }
    }

    @Test func `workspace-layout takes dwindle, master and scrolling`() throws {
        #expect(try parse("workspace-layout master") == .workspaceLayout([.master]))
        #expect(try parse("workspace-layout dwindle master scrolling") == .workspaceLayout([.dwindle, .master, .scrolling]))
        #expect(throws: CommandError.self) { try parse("workspace-layout") }
        #expect(throws: CommandError.self) { try parse("workspace-layout tiles") }
    }

    @Test func `A workspace is described by its layout, a fixed one as dwindle`() {
        #expect(WorkspaceLayoutName.describing(.dwindle(.accordion)) == .dwindle)
        #expect(WorkspaceLayoutName.describing(.fixed(rows: 1, columns: 2, expand: .columns)) == .dwindle)
        #expect(WorkspaceLayoutName.describing(.master) == .master)
        #expect(WorkspaceLayoutName.describing(.scrolling) == .scrolling)
    }

    @Test func `Workspace layouts toggle and cycle`() {
        let toggle: [WorkspaceLayoutName] = [.dwindle, .master]
        #expect(nextLayout(in: toggle, current: [.dwindle]) == .master)
        #expect(nextLayout(in: toggle, current: [.master]) == .dwindle)
        #expect(nextLayout(in: toggle, current: [.scrolling]) == .dwindle, "none describes it")
        #expect(nextLayout(in: toggle + [.scrolling], current: [.scrolling]) == .dwindle)
    }

    @Test func `Several layouts cycle from the last that describes the window`() {
        let cycle: [LayoutName] = [.tiles, .accordion, .vertical]
        #expect(nextLayout(in: cycle, current: [.tiling, .tiles, .horizontal, .hTiles]) == .accordion)
        #expect(nextLayout(in: cycle, current: [.tiling, .accordion, .horizontal, .hAccordion]) == .vertical)
        #expect(nextLayout(in: cycle, current: [.tiling, .tiles, .vertical, .vTiles]) == .tiles)
        #expect(nextLayout(in: cycle, current: [.floating]) == .tiles, "none describes it")
        let floating: [LayoutName] = [.floating, .tiling]
        #expect(nextLayout(in: floating, current: [.tiling, .tiles]) == .floating)
        #expect(nextLayout(in: floating, current: [.floating]) == .tiling)
        #expect(nextLayout(in: [LayoutName.accordion], current: [.tiling, .accordion]) == .accordion)
    }

    @Test func `Layout names set mode, orientation or both`() {
        #expect(LayoutName.hAccordion.mode == .accordion)
        #expect(LayoutName.hAccordion.orientation == .horizontal)
        #expect(LayoutName.vertical.mode == nil)
        #expect(LayoutName.auto.orientation == .auto)
        #expect(LayoutName.tiles.orientation == nil)
    }

    @Test func `Layout states describe the resolved axis`() {
        #expect(LayoutName.describing(.accordion, axis: .vertical, auto: true) == [.accordion, .vertical, .vAccordion, .auto])
        #expect(LayoutName.describing(.tiles, axis: .horizontal, auto: false) == [.tiles, .horizontal, .hTiles])
    }

    @Test func `Simple commands`() throws {
        #expect(try parse("fullscreen") == .fullscreen)
        #expect(try parse("flatten-workspace-tree") == .flattenWorkspaceTree)
        #expect(try parse("mode service") == .mode("service"))
        #expect(try parse("reload-config") == .reloadConfig)
        #expect(try parse("enable on") == .enable(.on))
        #expect(try parse("enable off") == .enable(.off))
        #expect(try parse("enable toggle") == .enable(.toggle))
        #expect(try parse("retile") == .retile)
        #expect(try parse("clear-minimum-sizes") == .clearMinimumSizes)
        #expect(try parse("exec-and-forget sketchybar --trigger 'a b'") == .execAndForget("sketchybar --trigger 'a b'"))
        #expect(try parse("  exec-and-forget   echo  hi") == .execAndForget("echo  hi"))
    }

    @Test func `Extra whitespace is ignored`() throws {
        #expect(try parse("  workspace   2 \n") == .workspace(.number(2)))
    }

    private static let defaultBindings = Config.default.modes.values.flatMap { $0.bindings.values.flatMap(\.commands) }

    @Test func `Default config has bindings`() {
        #expect(!Self.defaultBindings.isEmpty)
    }

    @Test(arguments: defaultBindings + Config.default.rules.flatMap(\.run))
    func `Every default binding parses`(command: String) {
        #expect(throws: Never.self) { try parse(command) }
    }

    @Test func `Documented names are unique`() {
        #expect(Set(Command.all.map(\.name)).count == Command.all.count)
    }

    /// One line that parses, per documented command.
    private static let knownGood = [
        "workspace 1", "workspace-back-and-forth", "move-window-to-workspace 2 --follow", "move-window-to-display next",
        "focus left", "focus-monitor next", "move left", "join-with left", "resize smart +10", "layout tiles", "workspace-layout master",
        "fullscreen", "flatten-workspace-tree", "balance-sizes", "swap-with-master", "retile", "clear-minimum-sizes", "mode main", "reload-config", "enable on",
        "list-workspaces", "list-windows", "list-monitors", "list-displays", "list-modes", "debug-state", "exec-and-forget true",
    ]

    @Test func `Known-good lines cover exactly the documented names`() {
        let names = Self.knownGood.map { String($0.prefix { $0 != " " }) }
        #expect(names.count == Self.knownGood.count, "a name has two known-good lines")
        #expect(Set(names) == Set(Command.all.map(\.name)))
    }

    @Test(arguments: Command.all.map(\.name))
    func `Every documented name parses`(name: String) throws {
        let line = try #require(Self.knownGood.first { $0.hasPrefix(name + " ") || $0 == name }, "no known-good line")
        #expect(Command.words(line).first == name)
        #expect(throws: Never.self) { try parse(line) }
    }

    @Test(arguments: Command.all.map(\.name).filter { $0 != "exec-and-forget" })
    func `Every documented name rejects extra words`(name: String) {
        #expect(throws: (any Error).self) { try parse("\(name) bogus extra words") }
    }
}

struct ParseErrorTests {
    private func message(_ s: String) -> String {
        do {
            _ = try Command.parse(s)
            return "parsed"
        } catch {
            #expect(error.input == s)
            return error.description
        }
    }

    @Test func `Unknown command names string and commands`() {
        let m = message("frobnicate 3")
        #expect(m.contains("'frobnicate 3'"), "\(m)")
        #expect(m.contains("workspace-back-and-forth"), "\(m)")
    }

    @Test func `Bad arguments name string and syntax`() {
        let m = message("workspace zero")
        #expect(m.contains("'workspace zero'"), "\(m)")
        #expect(m.contains("workspace <number|prev|next>"), "\(m)")
    }

    @Test(arguments: ["", "   ", "workspace", "workspace 0", "workspace -1", "workspace 1 2", "focus sideways",
                      "resize smart 50", "resize diagonal +50", "resize smart +x", "layout", "layout grid",
                      "layout tiles grid", "layout accordion h_list", "layout horizontal sideways", "layout auto_tiles", "move-window-to-display 2", "move-window-to-workspace --follow",
                      "mode", "mode a b", "enable maybe", "fullscreen now", "Workspace 1", "exec-and-forget", "exec-and-forget  "])
    func `Bad strings`(s: String) {
        #expect(message(s) != "parsed")
    }

    @Test func empty() {
        #expect(message("") == "empty command")
    }
}

struct QuotingTests {
    @Test func `Words keep quoted spaces`() {
        #expect(Command.words(#"list-windows --format '%{app-name} | %{window-title}'"#) ==
                ["list-windows", "--format", "%{app-name} | %{window-title}"])
        #expect(Command.words(#"a "b 'c'" '' d"#) == ["a", "b 'c'", "", "d"])
    }

    @Test func `Line round-trips through words`() {
        let args = ["list-windows", "--format", "%{window-id} | %{app-name}", "--workspace", "1", "it's"]
        #expect(Command.words(Command.line(args)) == args)
        #expect(Command.line(["workspace", "3"]) == "workspace 3")
    }

    @Test(arguments: [#"it's "x""#, #"a"b'c"#, #"'""#, #"''"""#, #"say "hi""#])
    func `Line round-trips a word with both kinds of quote`(word: String) {
        let args = ["list-windows", "--format", word, "--workspace", "1"]
        #expect(Command.words(Command.line(args)) == args)
    }

    // A combining mark joins the character before it into one Character, quote and space included.
    @Test(arguments: ["\u{301}e", "a \u{301}b", "\u{301}", "it's \u{301}", "x\u{301}'y\"\u{301}", "'\u{301}\"", "'\u{301}"])
    func `Line round-trips a word with combining marks`(word: String) {
        let args = ["list-windows", "--format", word, "--workspace", "1"]
        #expect(Command.words(Command.line(args)) == args)
    }

    @Test func `Exec-and-forget line is passed as written`() {
        #expect(Command.line(["exec-and-forget", "echo 'a b'", "> /tmp/x"]) == "exec-and-forget echo 'a b' > /tmp/x")
    }
}
