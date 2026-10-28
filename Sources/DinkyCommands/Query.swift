// The list-* queries: their flags and format variables, named after AeroSpace's (MIT,
// github.com/nikitabobko/AeroSpace). Workspaces are numbered across displays, as AeroSpace names them.

/// Which displays a query covers: the focused one, all, or a 1-based display number.
public enum MonitorSpec: Equatable, Sendable {
    case focused, all
    case number(Int)
}

/// A workspace filter: the focused display's current workspace, every display's current one, or a number.
public enum WorkspaceSpec: Equatable, Sendable {
    case focused, visible
    case number(Int)
}

public struct WorkspaceQuery: Equatable, Sendable {
    public static let variables = ["workspace", "workspace-is-focused", "workspace-is-visible", "workspace-layout",
                                   "monitor-id", "monitor-name", "monitor-is-main"]

    public var monitors: [MonitorSpec] = [.focused]
    /// Only visible workspaces (true) or only hidden ones (false).
    public var visible: Bool?
    /// Only empty workspaces (true) or only ones with windows (false).
    public var empty: Bool?
    public var format = try! Format("%{workspace}", variables: variables)

    public init() {}

    init(parsing args: [String]) throws(CommandError) {
        var flags = Flags(args)
        while let flag = flags.next() {
            switch flag {
            case "--all": monitors = [.all]
            case "--focused": (monitors, visible) = ([.focused], true)
            case "--monitor": monitors = try flags.monitors(flag)
            case "--visible": visible = flags.yesNo()
            case "--empty": empty = flags.yesNo()
            case "--format": format = try Format(flags.value(flag), variables: Self.variables)
            default: throw Flags.unknown(flag)
            }
        }
    }
}

public struct WindowQuery: Equatable, Sendable {
    public static let variables = ["window-id", "window-title", "window-identifier", "window-layout", "window-parent-container-layout",
                                   "window-is-floating", "window-is-fullscreen", "app-name", "app-bundle-id", "app-pid",
                                   "workspace", "workspace-is-focused", "workspace-is-visible", "workspace-layout",
                                   "monitor-id", "monitor-name", "monitor-is-main"]

    public var monitors: [MonitorSpec] = [.focused]
    /// Empty means any workspace.
    public var workspaces: [WorkspaceSpec] = []
    /// Only the focused window.
    public var focused = false
    public var appBundleID: String?
    public var format = try! Format("%{window-id}%{right-padding} | %{app-name}%{right-padding} | %{window-title}",
                                    variables: variables)

    public init() {}

    init(parsing args: [String]) throws(CommandError) {
        var flags = Flags(args)
        while let flag = flags.next() {
            switch flag {
            case "--all": monitors = [.all]
            case "--focused": focused = true
            case "--monitor": monitors = try flags.monitors(flag)
            case "--workspace": workspaces += try flags.values(flag).map { word throws(CommandError) in
                switch word {
                case "focused": return .focused
                case "visible": return .visible
                default:
                    guard let n = Int(word), n >= 1 else {
                        throw CommandError(input: word, message: "--workspace takes focused, visible or a number, not '\(word)'")
                    }
                    return .number(n)
                }
            }
            case "--app-bundle-id", "--app-id": appBundleID = try flags.value(flag)
            case "--format": format = try Format(flags.value(flag), variables: Self.variables)
            default: throw Flags.unknown(flag)
            }
        }
    }
}

public struct MonitorQuery: Equatable, Sendable {
    public static let variables = ["monitor-id", "monitor-name", "monitor-is-main"]

    /// Only the focused display (true) or only the others (false).
    public var focused: Bool?
    public var format = try! Format("%{monitor-id}%{right-padding} | %{monitor-name}", variables: variables)

    public init() {}

    init(parsing args: [String]) throws(CommandError) {
        var flags = Flags(args)
        while let flag = flags.next() {
            switch flag {
            case "--focused": focused = flags.yesNo()
            case "--format": format = try Format(flags.value(flag), variables: Self.variables)
            default: throw Flags.unknown(flag)
            }
        }
    }
}

/// Reads flags and their values off a query's words.
private struct Flags {
    private var words: [String]

    init(_ words: [String]) { self.words = words }

    mutating func next() -> String? { words.isEmpty ? nil : words.removeFirst() }

    /// Exactly one value.
    mutating func value(_ flag: String) throws(CommandError) -> String {
        guard let value = next() else { throw CommandError(input: flag, message: "\(flag) needs a value") }
        return value
    }

    /// One or more values, up to the next flag.
    mutating func values(_ flag: String) throws(CommandError) -> [String] {
        let values = words.prefix { !$0.hasPrefix("--") }
        guard !values.isEmpty else { throw CommandError(input: flag, message: "\(flag) needs a value") }
        words.removeFirst(values.count)
        return Array(values)
    }

    /// An optional `yes` or `no` after a flag. True unless `no`.
    mutating func yesNo() -> Bool {
        guard let word = words.first, word == "yes" || word == "no" else { return true }
        words.removeFirst()
        return word == "yes"
    }

    mutating func monitors(_ flag: String) throws(CommandError) -> [MonitorSpec] {
        try values(flag).map { word throws(CommandError) in
            switch word {
            case "focused": return .focused
            case "all": return .all
            default:
                guard let n = Int(word), n >= 1 else {
                    throw CommandError(input: word, message: "\(flag) takes focused, all or a display number, not '\(word)'")
                }
                return .number(n)
            }
        }
    }

    static func unknown(_ flag: String) -> CommandError {
        CommandError(input: flag, message: "unknown flag '\(flag)'")
    }
}
