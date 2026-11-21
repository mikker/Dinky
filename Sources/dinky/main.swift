import Foundation

/// `~/Library/Logs/dinky.log`, where the app writes its log when it has no terminal (launched by Finder or at login).
let logURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/dinky.log")

/// Whether stdout is closed or /dev/null, as launchd leaves it for an app it starts. A terminal, a pipe or a
/// redirect to a file all count as someone reading.
func stdoutIsDiscarded() -> Bool {
    var out = stat(), null = stat()
    guard fstat(STDOUT_FILENO, &out) == 0 else { return true }
    guard stat("/dev/null", &null) == 0 else { return false }
    return out.st_mode & S_IFMT == S_IFCHR && out.st_rdev == null.st_rdev
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    // Launched from the app bundle with no arguments: run the menu bar app. Started by Finder, `open` or the
    // login item, its output would go nowhere, so it goes to the log file; `just run` on a terminal and fut
    // reading it through a pipe keep it.
    if Bundle.main.bundleIdentifier != nil {
        if stdoutIsDiscarded() {
            if (try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 5_000_000 {
                try? FileManager.default.removeItem(at: logURL)
            }
            for stream in [stdout, stderr] { freopen(logURL.path, "a", stream); setlinebuf(stream) }
        }
        exit(runApp())
    }
    fputs("usage: dinky <command> (see dinky help) | app\n", stderr)
    exit(64)
}

let rest = Array(args.dropFirst())
switch command {
case "app": exit(runApp())
case "recover": exit(runRecover())
case "debug": exit(runDebug(rest))
case "doctor": exit(runDoctor(rest))
case "skill": exit(runSkill())
case "help", "--help", "-h": exit(runHelp())
case "version", "--version", "-v":
    let info = Bundle.main.infoDictionary
    print("dinky \(info?["CFBundleShortVersionString"] ?? "dev") (\(info?["CFBundleVersion"] ?? "0"))")
    exit(0)
default: exit(runCli(args))
}
