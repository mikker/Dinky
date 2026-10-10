import DinkyCommands
import Foundation

// `dinky <command>`: checks the command, sends it to the running app and prints the reply.
func runCli(_ args: [String]) -> Int32 {
    let line = Command.line(args)
    do {
        _ = try Command.parse(line)
    } catch {
        fputs("dinky: \(error)\n", stderr)
        return 1
    }
    return sendAndPrint(line)
}

/// Sends a line to the running app and prints its reply: the exit status is 0 when it succeeded.
func sendAndPrint(_ line: String) -> Int32 {
    guard let reply = sendToApp(line) else {
        fputs("dinky: app is not running (\(socketPath))\n", stderr)
        return 1
    }
    if !reply.text.isEmpty { fputs(reply.text + "\n", reply.ok ? stdout : stderr) }
    return reply.ok ? 0 : 1
}

// `dinky help`: the command reference, then the subcommands main.swift handles itself.
func runHelp() -> Int32 {
    let cliOnly = [
        ("app", "Run the app in the foreground, logging to the terminal."),
        ("recover", "Restore unfinished window frames, preserving native Spaces."),
        ("debug events|windows", "Print the live window event stream, or the current windows, for bug reports."),
        ("doctor [--config <path>]", "Check the config and the macOS settings dinky depends on. Exit 1 on errors."),
        ("version, -v, --version", "Print the version and build number."),
    ]
    print("usage: dinky <command>, sent to the running app over \(socketPath)\n")
    for doc in Command.all { print("  \(doc.syntax)\n      \(doc.description)") }
    print("\ncommand line only:")
    for (syntax, description) in cliOnly { print("  \(syntax)\n      \(description)") }
    return 0
}
