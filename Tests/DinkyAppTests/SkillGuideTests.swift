import DinkyCommands
import Foundation
import Testing
@testable import dinky

struct SkillGuideTests {
    @Test func `Guide lists every command with its syntax and description`() {
        for doc in Command.all { #expect(skillGuide.contains("- `\(doc.syntax)`: \(doc.description)"), "\(doc.name)") }
        for row in cliOnlyCommands { #expect(skillGuide.contains("- `\(row.syntax)`: \(row.description)"), "\(row.syntax)") }
    }

    @Test func `Shell examples are valid shell syntax`() throws {
        #expect(!examples.isEmpty)
        #expect(try run(examples.joined(separator: "\n"), syntaxOnly: true).status == 0)
    }

    @Test func `Examples parse and target the selected window without toggling`() throws {
        // The executable in this harness is a stub, never the installed CLI or running app.
        let result = try run(examples.joined(separator: "\n"))
        #expect(result.status == 0, "\(result.error)")
        #expect(!result.calls.isEmpty)
        for args in result.calls {
            let command = try Command.parse(Command.line(args))
            if ["move-window-to-workspace", "move-window-to-display", "layout", "workspace-layout"].contains(args.first) {
                guard case .targetWindow(42, _) = command else {
                    Issue.record("Recipe must target the selected window: \(args)")
                    continue
                }
            }
            if case .targetWindow(_, .layout(let layouts)) = command {
                #expect(!(layouts.contains(.floating) && layouts.contains(.tiling)), "Set the requested state, don't toggle it")
            }
        }
    }

    @Test(arguments: ["settled", "delayed"])
    func `Switch recipe confirms actual state without replaying the request`(mode: String) throws {
        let result = try run(verificationScript(), mode: mode)
        #expect(result.status == 0, "\(result.error)")
        #expect(result.calls.filter { $0.first == "workspace" } == [["workspace", "4"]])
        #expect(result.calls.filter { $0 == ["list-workspaces", "--focused"] }.count == (mode == "delayed" ? 4 : 1))
    }

    @Test(arguments: ["never", "command-failure", "query-failure"])
    func `Switch recipe stops on errors or bounded missing confirmation`(mode: String) throws {
        let result = try run(verificationScript(), mode: mode)
        #expect(result.status != 0)
        #expect(result.calls.filter { $0.first == "workspace" } == [["workspace", "4"]])
        let queries = result.calls.filter { $0 == ["list-workspaces", "--focused"] }.count
        #expect(queries == (mode == "never" ? 50 : mode == "query-failure" ? 1 : 0))
        if mode == "never" { #expect(result.error.contains("Workspace switch not confirmed")) }
    }

    private var examples: [String] {
        skillGuide.components(separatedBy: "```sh\n").dropFirst().map { $0.components(separatedBy: "```")[0] }
    }

    private func verificationScript() throws -> String {
        let section = try #require(skillGuide.components(separatedBy: "## Verify").dropFirst().first)
        let blocks = section.components(separatedBy: "```sh\n").dropFirst().map { $0.components(separatedBy: "```")[0] }
        return try #require(blocks.last, "Guide needs an executable result-verification recipe")
    }

    private struct Result {
        var status: Int32
        var error: String
        var calls: [[String]]
    }

    private func run(_ script: String, mode: String = "settled", syntaxOnly: Bool = false) throws -> Result {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dinky-skill-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = """
            #!/bin/sh
            printf '%s\\0' "$@" >> "$CALLS"
            printf '\\0' >> "$CALLS"
            case "$1:$2" in
              workspace:*)
                [ "$MODE" != command-failure ] || { echo 'workspace 4 has no Space' >&2; exit 1; }
                echo "workspace $2" ;;
              list-workspaces:--focused)
                count=0
                [ ! -f "$COUNT" ] || read -r count < "$COUNT"
                count=$((count + 1))
                printf '%s\\n' "$count" > "$COUNT"
                [ "$MODE" != query-failure ] || { echo 'app is not running' >&2; exit 1; }
                if [ "$MODE" = never ] || { [ "$MODE" = delayed ] && [ "$count" -lt 4 ]; }; then
                    echo 1
                else
                    echo 4
                fi ;;
              *) echo 42 ;;
            esac
            """
        for (name, text) in [("dinky", stub), ("sleep", "#!/bin/sh\nexit 0\n")] {
            let file = dir.appendingPathComponent(name)
            try text.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = syntaxOnly ? ["-n", "-c", script] : ["-c", script]
        process.environment = ["PATH": "\(dir.path):/usr/bin:/bin", "CALLS": dir.appendingPathComponent("calls").path,
                               "COUNT": dir.appendingPathComponent("count").path, "MODE": mode, "id": "42"]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let calls = (try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? ""
        return Result(status: process.terminationStatus,
                      error: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                      calls: calls.components(separatedBy: "\0\0").filter { !$0.isEmpty }.map { $0.components(separatedBy: "\0") })
    }
}
