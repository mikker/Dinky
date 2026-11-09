import DinkyLayout

/// A command string that does not parse. `description` names the string and the accepted form.
public struct CommandError: Error, Equatable, CustomStringConvertible {
    public let input: String
    public let message: String

    public var description: String { message }
}

extension Command {
    /// Parses a command string such as `workspace 3`, `move-window-to-workspace 3 --follow` or `focus left`.
    public static func parse(_ string: String) throws(CommandError) -> Command {
        let words = words(string)
        guard let name = words.first else {
            throw CommandError(input: string, message: "empty command")
        }
        guard let doc = all.first(where: { $0.name == name }) else {
            let names = all.map(\.name).joined(separator: ", ")
            throw CommandError(input: string, message: "unknown command '\(string)', expected one of: \(names)")
        }
        if name == "exec-and-forget" {
            let shell = string.drop(while: \.isWhitespace).dropFirst(name.count).drop(while: \.isWhitespace)
            guard !shell.isEmpty else { throw CommandError(input: string, message: "can't parse '\(string)', expected '\(doc.syntax)'") }
            return .execAndForget(String(shell))
        }
        let parsed: Command?
        do {
            parsed = try parse(name, Array(words.dropFirst()))
        } catch {
            throw CommandError(input: string, message: "can't parse '\(string)': \(error.message)")
        }
        guard let command = parsed else {
            throw CommandError(input: string, message: "can't parse '\(string)', expected '\(doc.syntax)'")
        }
        return command
    }

    /// Nil for arguments that don't fit; `focus` and the list-* queries throw a message naming the problem.
    private static func parse(_ name: String, _ args: [String]) throws(CommandError) -> Command? {
        if ["move-window-to-workspace", "move-window-to-display", "layout", "workspace-layout"].contains(name),
           let index = args.firstIndex(of: "--window-id") {
            guard args.indices.contains(index + 1), let id = UInt32(args[index + 1]), id > 0 else { return nil }
            var rest = args
            rest.removeSubrange(index...index + 1)
            guard !rest.contains("--window-id"), let command = try parse(name, rest) else { return nil }
            return .targetWindow(id, command)
        }
        let none = args.isEmpty
        let one = args.count == 1 ? args[0] : nil
        switch name {
        case "workspace":
            return one.flatMap(workspaceTarget).map { .workspace($0) }
        case "workspace-back-and-forth":
            return none ? .workspaceBackAndForth : nil
        case "move-window-to-workspace":
            let (rest, follow) = followFlag(args)
            guard rest.count == 1, let target = workspaceTarget(rest[0]) else { return nil }
            return .moveWindowToWorkspace(target, follow: follow)
        case "move-window-to-display":
            let (rest, follow) = followFlag(args)
            guard rest.count == 1, let target = DisplayTarget(rawValue: rest[0]) else { return nil }
            return .moveWindowToDisplay(target, follow: follow)
        case "focus":
            return try focus(args)
        case "focus-monitor":
            if let n = one.flatMap({ Int($0) }) { return n >= 1 ? .focusMonitorNumber(n) : nil }
            return one.flatMap(MonitorTarget.init(rawValue:)).map { .focusMonitor($0) }
        case "move":
            return one.flatMap(Direction.init).map { .move($0) }
        case "join-with":
            return one.flatMap(Direction.init).map { .joinWith($0) }
        case "resize":
            guard args.count == 2, let dimension = ResizeDimension(rawValue: args[0]),
                  args[1].hasPrefix("+") || args[1].hasPrefix("-"), let delta = Int(args[1]) else { return nil }
            return .resize(dimension, by: delta)
        case "layout":
            let layouts = args.compactMap(LayoutName.init(rawValue:))
            guard !none, layouts.count == args.count else { return nil }
            return .layout(layouts)
        case "workspace-layout":
            let layouts = args.compactMap(WorkspaceLayoutName.init(rawValue:))
            guard !none, layouts.count == args.count else { return nil }
            return .workspaceLayout(layouts)
        case "fullscreen":
            return none ? .fullscreen : nil
        case "flatten-workspace-tree":
            return none ? .flattenWorkspaceTree : nil
        case "balance-sizes":
            return none ? .balanceSizes : nil
        case "swap-with-master":
            return none ? .swapWithMaster : nil
        case "retile":
            return none ? .retile : nil
        case "clear-minimum-sizes":
            return none ? .clearMinimumSizes : nil
        case "mode":
            return one.map { .mode($0) }
        case "reload-config":
            return none ? .reloadConfig : nil
        case "enable":
            return one.flatMap(Toggle.init(rawValue:)).map { .enable($0) }
        case "list-windows":
            return .listWindows(try WindowQuery(parsing: args))
        case "list-workspaces":
            return .listWorkspaces(try WorkspaceQuery(parsing: args))
        case "list-monitors", "list-displays":
            return .listMonitors(try MonitorQuery(parsing: args))
        case "list-modes":
            return none ? .listModes(current: false) : one == "--current" ? .listModes(current: true) : nil
        case "debug-state":
            return none ? .debugState : nil
        default:
            return nil
        }
    }

    /// The quoting rule `words` reads and `line` writes, by Unicode scalar rather than Character: a word starting
    /// with a combining mark would otherwise make one Character with the quote before it.
    private static func isSpace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace }
    private static func isQuote(_ c: Unicode.Scalar) -> Bool { c == "'" || c == "\"" }

    /// Splits a command line into words at whitespace. Single or double quotes keep spaces inside a word,
    /// as in `list-windows --format '%{app-name} | %{window-title}'`.
    static func words(_ line: String) -> [String] {
        var words: [String] = [], word = String.UnicodeScalarView(), inWord = false
        var quote: Unicode.Scalar?
        for c in line.unicodeScalars {
            if let q = quote {
                if c == q { quote = nil } else { word.append(c) }
            } else if isQuote(c) {
                quote = c
                inWord = true
            } else if isSpace(c) {
                if inWord { words.append(String(word)) }
                (word, inWord) = (String.UnicodeScalarView(), false)
            } else {
                word.append(c)
                inWord = true
            }
        }
        if inWord { words.append(String(word)) }
        return words
    }

    /// The command line for CLI arguments, quoting words with spaces or quotes so `words` splits it back
    /// the same. `exec-and-forget` is shell text and is passed as written.
    public static func line(_ args: [String]) -> String {
        guard args.first != "exec-and-forget" else { return args.joined(separator: " ") }
        return args.map { word in
            let scalars = word.unicodeScalars
            guard word.isEmpty || scalars.contains(where: { isSpace($0) || isQuote($0) }) else { return word }
            if !scalars.contains("'") { return "'\(word)'" }
            if !scalars.contains("\"") { return "\"\(word)\"" }
            // Both kinds: single-quoted runs, each ' written as "'" between them. Adjacent runs make one word.
            let runs = scalars.split(separator: "'", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
            return "'" + runs.joined(separator: "'\"'\"'") + "'"
        }.joined(separator: " ")
    }

    private static func workspaceTarget(_ word: String) -> WorkspaceTarget? {
        switch word {
        case "prev": return .prev
        case "next": return .next
        default:
            guard let n = Int(word), n >= 1 else { return nil }
            return .number(n)
        }
    }

    /// `focus <direction>` with AeroSpace's `--boundaries`, `--boundaries-action` and `--wrap-around`, in any order.
    private static func focus(_ args: [String]) throws(CommandError) -> Command? {
        var rest = args[...], direction: Direction?
        var boundaries = FocusBoundaries.workspace, action = BoundariesAction.stop
        while let word = rest.popFirst() {
            switch word {
            case "--boundaries":
                guard let value = rest.popFirst().flatMap(FocusBoundaries.init(rawValue:)) else { return nil }
                boundaries = value
            case "--boundaries-action":
                guard let value = rest.popFirst().flatMap(BoundariesAction.init(rawValue:)) else { return nil }
                action = value
            case "--wrap-around":
                action = .wrapAroundTheWorkspace
            default:
                guard direction == nil, let value = Direction(word) else { return nil }
                direction = value
            }
        }
        guard let direction else { return nil }
        if boundaries == .workspace, action == .wrapAroundAllMonitors {
            throw CommandError(input: "", message: "wrap-around-all-monitors needs --boundaries all-monitors-outer-frame")
        }
        return .focus(direction, boundaries: boundaries, action: action)
    }

    private static func followFlag(_ args: [String]) -> (rest: [String], follow: Bool) {
        (args.filter { $0 != "--follow" }, args.contains("--follow"))
    }
}
