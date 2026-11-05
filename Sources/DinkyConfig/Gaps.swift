// Gaps in points, the `[display.<pattern>]` tables that override them for one display, and the display
// patterns those tables, `[workspace.N.display.<pattern>]` and `[workspace-to-display]` use.

/// The gap between side-by-side windows (`horizontal`) and between stacked ones (`vertical`).
public struct Inner: Equatable {
    public var horizontal, vertical: Int

    public init(_ both: Int) { (horizontal, vertical) = (both, both) }
    public init(horizontal: Int, vertical: Int) { (self.horizontal, self.vertical) = (horizontal, vertical) }
}

/// The gaps between tiled windows and the screen edges.
public struct Sides: Equatable {
    public var top, bottom, left, right: Int

    public init(_ all: Int) { (top, bottom, left, right) = (all, all, all, all) }
    public init(top: Int, bottom: Int, left: Int, right: Int) {
        (self.top, self.bottom, self.left, self.right) = (top, bottom, left, right)
    }
}

public struct Gaps: Equatable {
    public var inner = Inner(8)
    public var outer = Sides(8)

    public init() {}
    public init(inner: Inner, outer: Sides) { (self.inner, self.outer) = (inner, outer) }

    /// These gaps with the patch's values in place of the matching ones.
    public func applying(_ patch: GapsPatch) -> Gaps {
        var gaps = self
        gaps.inner.horizontal = patch.horizontal ?? inner.horizontal
        gaps.inner.vertical = patch.vertical ?? inner.vertical
        gaps.outer.top = patch.top ?? outer.top
        gaps.outer.bottom = patch.bottom ?? outer.bottom
        gaps.outer.left = patch.left ?? outer.left
        gaps.outer.right = patch.right ?? outer.right
        return gaps
    }
}

/// A `[gaps]` table as written: `inner = 8` or `inner = { horizontal = 8, vertical = 6 }`, `outer = 8` or
/// `outer = { top = 44, left = 8 }`. A value left out is nil and keeps whatever it is applied to.
public struct GapsPatch: Equatable {
    public var horizontal, vertical, top, bottom, left, right: Int?

    public init() {}

    init(_ t: Table) throws {
        if t.isTable("inner") {
            let inner = try t.table("inner")!
            horizontal = try Self.points(inner, "horizontal")
            vertical = try Self.points(inner, "vertical")
            try inner.done()
        } else if let both = try Self.points(t, "inner") {
            (horizontal, vertical) = (both, both)
        }
        if t.isTable("outer") {
            let outer = try t.table("outer")!
            top = try Self.points(outer, "top")
            bottom = try Self.points(outer, "bottom")
            left = try Self.points(outer, "left")
            right = try Self.points(outer, "right")
            try outer.done()
        } else if let all = try Self.points(t, "outer") {
            (top, bottom, left, right) = (all, all, all, all)
        }
        try t.done()
    }

    /// A gap in points, which can't be negative.
    private static func points(_ t: Table, _ key: String) throws -> Int? {
        guard let value = try t.int(key) else { return nil }
        if value < 0 {
            t.warn(key, "must be 0 or more; using 0", fix: ConfigFix(replace: String(value), with: "0"))
            return 0
        }
        return value
    }
}

/// What a display pattern is matched against. dinky fills it in per display.
public struct Monitor: Equatable {
    /// The display's name, such as "Built-in Retina Display" or "DELL U2723QE".
    public var name: String
    /// Whether this is the main display (System Settings, Displays, "Use as: Main display").
    public var isMain: Bool
    /// How many displays there are.
    public var count: Int

    public init(name: String, isMain: Bool, count: Int) {
        self.name = name
        self.isMain = isMain
        self.count = count
    }
}

/// `main`, `secondary` (the non-main display when there are exactly two), or a case-insensitive
/// substring of the display's name, such as `built-in` or `dell`.
public enum MonitorPattern: Equatable {
    case main, secondary
    case name(String)

    init(_ text: String) {
        switch text {
        case "main": self = .main
        case "secondary": self = .secondary
        default: self = .name(text)
        }
    }

    public func matches(_ monitor: Monitor) -> Bool {
        switch self {
        case .main: monitor.isMain
        case .secondary: monitor.count == 2 && !monitor.isMain
        case .name(let text): monitor.name.localizedCaseInsensitiveContains(text)
        }
    }

    /// Name patterns beat `main` and `secondary`, longer names beat shorter.
    var specificity: Int {
        if case .name(let text) = self { text.count } else { -1 }
    }
}

/// One `[display.<pattern>]` table: settings that replace the general ones on the displays the pattern matches.
public struct DisplayOverride: Equatable {
    public var pattern: MonitorPattern
    public var gaps = GapsPatch()
    /// `fullscreen-width` on these displays, nil for the top-level value.
    public var fullscreenWidth: Double?
    /// A lone window's share on these displays, nil to continue the cascade.
    public var loneWindowWidth: Double?

    init(_ pattern: String, _ t: Table) throws {
        guard !pattern.isEmpty else { throw ConfigError(path: t.path, "a display pattern can't be empty") }
        self.pattern = MonitorPattern(pattern)
        gaps = try t.table("gaps").map(GapsPatch.init) ?? gaps
        fullscreenWidth = try t.windowWidth("fullscreen-width")
        loneWindowWidth = try t.windowWidth("lone-window-width")
        if try t.int("workspaces") != nil {
            throw ConfigError(path: t.path("workspaces"),
                              "workspaces are numbered across displays now; put one on a display with [workspace-to-display]")
        }
        try t.done()
    }
}

extension Config {
    /// The display tables matching `monitor`, least specific first: `main` and `secondary`, then name
    /// patterns, shortest first, so applying them in order lets the most specific win.
    func overrides(for monitor: Monitor) -> [DisplayOverride] {
        displays.filter { $0.pattern.matches(monitor) }.sorted { $0.pattern.specificity < $1.pattern.specificity }
    }

    /// The gaps on `monitor`: the general ones, with the overrides of every matching display table applied.
    public func gaps(for monitor: Monitor) -> Gaps {
        overrides(for: monitor).reduce(gaps) { $0.applying($1.gaps) }
    }
}
