import Testing
@testable import DinkyCommands

private func parse(_ s: String) throws -> Command { try Command.parse(s) }

struct QueryParseTests {
    @Test func `Debug state`() throws {
        #expect(try parse("debug-state") == .debugState)
        #expect(try parse("list-modes") == .listModes(current: false))
        #expect(try parse("list-modes --current") == .listModes(current: true))
        #expect(throws: (any Error).self) { try parse("list-modes --all") }
        #expect(throws: (any Error).self) { try parse("debug-state --all") }
    }

    @Test func `List workspaces`() throws {
        #expect(try parse("list-workspaces") == .listWorkspaces(WorkspaceQuery()))
        var all = WorkspaceQuery()
        all.monitors = [.all]
        #expect(try parse("list-workspaces --all") == .listWorkspaces(all))
        #expect(try parse("list-workspaces --monitor all") == .listWorkspaces(all))
        var focused = WorkspaceQuery()
        focused.visible = true
        #expect(try parse("list-workspaces --focused") == .listWorkspaces(focused))
        var q = WorkspaceQuery()
        q.monitors = [.number(2), .focused]
        q.visible = false
        q.empty = true
        q.format = try Format("%{monitor-id}:%{workspace}", variables: WorkspaceQuery.variables)
        #expect(try parse("list-workspaces --monitor 2 focused --visible no --empty --format '%{monitor-id}:%{workspace}'") ==
                .listWorkspaces(q))
        var nonEmpty = WorkspaceQuery()
        (nonEmpty.empty, nonEmpty.visible) = (false, true)
        #expect(try parse("list-workspaces --empty no --visible yes") == .listWorkspaces(nonEmpty))
    }

    @Test func `List windows`() throws {
        #expect(try parse("list-windows") == .listWindows(WindowQuery()))
        var q = WindowQuery()
        q.workspaces = [.number(1), .focused, .number(3), .visible]
        #expect(try parse("list-windows --workspace 1 focused --workspace 3 visible") == .listWindows(q))
        q = WindowQuery()
        q.focused = true
        q.format = try Format("%{window-layout}", variables: WindowQuery.variables)
        #expect(try parse("list-windows --focused --format %{window-layout}") == .listWindows(q))
        q = WindowQuery()
        q.monitors = [.all]
        q.appBundleID = "com.apple.Safari"
        #expect(try parse("list-windows --all --app-bundle-id com.apple.Safari") == .listWindows(q))
        q.monitors = [.number(1)]
        #expect(try parse("list-windows --monitor 1 --app-id com.apple.Safari") == .listWindows(q))
    }

    @Test func `List monitors`() throws {
        #expect(try parse("list-monitors") == .listMonitors(MonitorQuery()))
        #expect(try parse("list-displays") == .listMonitors(MonitorQuery()))
        var q = MonitorQuery()
        q.focused = true
        #expect(try parse("list-monitors --focused") == .listMonitors(q))
        q.focused = false
        q.format = try Format("%{monitor-name}", variables: MonitorQuery.variables)
        #expect(try parse("list-displays --focused no --format '%{monitor-name}'") == .listMonitors(q))
    }

    @Test(arguments: [
        ("list-windows --bogus", "unknown flag '--bogus'"),
        ("list-workspaces extra", "unknown flag 'extra'"),
        ("list-monitors --all", "unknown flag '--all'"),
        ("list-windows --workspace", "--workspace needs a value"),
        ("list-windows --workspace zero", "not 'zero'"),
        ("list-workspaces --monitor left", "not 'left'"),
        ("list-windows --format", "--format needs a value"),
        ("list-windows --format '%{workspace-name}'", "unknown format variable '%{workspace-name}'"),
        ("list-workspaces --format '%{window-id}'", "unknown format variable '%{window-id}'"),
        ("list-monitors --format '%{monitor-id'", "unclosed '%{'"),
    ])
    func errors(input: String, expected: String) {
        let error = #expect(throws: CommandError.self, "parsed \(input)") {
            try Command.parse(input)
        }
        guard let error else { return }
        #expect(error.input == input)
        #expect(error.message.contains(expected), "\(error.message)")
        #expect(error.message.contains("can't parse '\(input)'"), "\(error.message)")
    }
}

struct FormatTests {
    private func render(_ format: String, _ rows: [[String: String]]) throws -> String {
        try Format(format, variables: ["a", "b"]).render(rows)
    }

    @Test func `Substitutes variables and keeps text`() throws {
        #expect(try render("x %{a}-%{b} y", [["a": "1", "b": "2"], ["a": "3"]]) == "x 1-2 y\nx 3- y")
        #expect(try render("%{a}%{tab}%{b}%{newline}", [["a": "1", "b": "2"]]) == "1\t2\n")
        #expect(try render("100%", [[:]]) == "100%")
        #expect(try render("%{a}", []) == "")
    }

    @Test func `Right padding aligns columns`() throws {
        let rows = [["a": "1", "b": "Safari"], ["a": "12345", "b": "Terminal"], ["a": "77", "b": "Finder"]]
        #expect(try render("%{a}%{right-padding} | %{b}", rows) == "1     | Safari\n12345 | Terminal\n77    | Finder")
    }

    @Test func `Default formats match AeroSpace`() {
        let rows = [["window-id": "7", "app-name": "Safari", "window-title": "Home"],
                    ["window-id": "123", "app-name": "Terminal", "window-title": "zsh"]]
        #expect(WindowQuery().format.render(rows) == "7   | Safari   | Home\n123 | Terminal | zsh")
        #expect(WorkspaceQuery().format.render([["workspace": "1"], ["workspace": "2"]]) == "1\n2")
        #expect(MonitorQuery().format.render([["monitor-id": "1", "monitor-name": "Built-in"]]) == "1 | Built-in")
    }

    @Test func `A format knows which variables it shows`() throws {
        #expect(WindowQuery().format.uses("window-title"))
        let ids = try Format("%{window-id}%{right-padding}", variables: WindowQuery.variables)
        #expect(ids.uses("window-id"))
        #expect(!ids.uses("window-title"))
    }

    @Test func `Unknown variable fails`() {
        let error = #expect(throws: CommandError.self) {
            try render("%{c}", [])
        }
        let description = error?.description ?? ""
        #expect(description.contains("%{c}"), "\(description)")
        #expect(description.contains("%{a}, %{b}"), "\(description)")
    }
}
