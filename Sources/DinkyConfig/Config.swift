import Foundation
import TOMLDecoder

// Config types and TOML loading. No AppKit here; Carbon.HIToolbox for the key codes only.
// TOML keys are kebab-case, Swift properties camelCase. Every key is optional; the defaults are the
// property initial values, and the shipped file (DefaultConfig.swift) spells out the same values.

public struct Config: Equatable {
    public var startAtLogin = true
    /// Workspaces across all displays, numbered from 1. Each is one native Space.
    public var workspaces = 5
    /// `[workspace-to-display]`: by workspace number, the display patterns it lives on, the first that matches
    /// a connected display winning. Other workspaces, and these when no pattern matches, live on the main display.
    public var workspaceDisplays: [Int: [MonitorPattern]] = [:]
    /// Workspace layout, with 'tiles' retained as the old name for dwindle.
    public var defaultLayout = LayoutKind.tiles
    /// Whether dinky tiles numbered workspaces unless overridden.
    public var defaultTiling = true
    /// Workspace numbers (1-based) with their own tiling settings, resolved against the top-level defaults.
    public var workspaceLayouts: [Int: WorkspaceSettings] = [:]
    /// Cmd-Tab and Dock clicks go through the fast switch.
    public var followAppActivation = true
    /// Float standard windows whose fullscreen button is missing or disabled, as AeroSpace does.
    public var floatWindowsWithoutFullscreen = true
    public var accordion = Accordion()
    public var scrolling = Scrolling()
    public var gaps = Gaps()
    /// `[display.<pattern>]` overrides, in file order.
    public var displays: [DisplayOverride] = []
    public var borders = Borders()
    public var focusFollowsMouse = FocusFollowsMouse()
    public var animations = Animations()
    public var drag = Drag()
    public var modifiers = ModifierSides()
    public var hooks = Hooks()
    /// `[[rules]]`, in file order.
    public var rules: [WindowRule] = []
    /// Keyed by mode name, e.g. `main`, `service`.
    public var modes: [String: Mode] = [:]

    public init() {}

    /// `~/.config/dinky/dinky.toml`
    public static var userConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/dinky/dinky.toml")
    }

    /// The config shipped with dinky, used when the user has none.
    public static let `default` = try! parse(defaultTOML)

    public static func load(from url: URL) throws(ConfigError) -> Config {
        let toml: String
        do {
            toml = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigError("can't read \(url.path): \(error.localizedDescription)")
        }
        return try parse(toml)
    }

    public static func parse(_ toml: String) throws(ConfigError) -> Config {
        let root: TOMLTable
        do {
            root = try TOMLTable(source: toml)
        } catch {
            // Syntax errors; TOMLDecoder's text already carries the line.
            throw ConfigError("\(error)")
        }
        do {
            return try Config(Table(root))
        } catch let error as ConfigError {
            var error = error
            error.line = error.line ?? lineNumber(of: error.path, in: toml)
            throw error
        } catch {
            throw ConfigError("\(error)")
        }
    }

    init(_ t: Table) throws {
        startAtLogin = try t.bool("start-at-login") ?? startAtLogin
        workspaces = try t.int("workspaces") ?? workspaces
        guard workspaces >= 1 else { throw ConfigError(path: "workspaces", "must be at least 1") }
        if let assignments = try t.table("workspace-to-display") {
            for key in assignments.keys {
                guard let n = Int(key), (1...workspaces).contains(n) else {
                    throw ConfigError(path: assignments.path(key), "'\(key)' is not a workspace number from 1 to \(workspaces)")
                }
                let patterns = try assignments.stringOrStrings(key)!
                guard !patterns.isEmpty, !patterns.contains("") else {
                    throw ConfigError(path: assignments.path(key), "a display pattern can't be empty")
                }
                workspaceDisplays[n] = patterns.map(MonitorPattern.init)
            }
            try assignments.done()
        }
        defaultLayout = try t.choice("default-layout") ?? defaultLayout
        defaultTiling = try t.bool("default-tiling") ?? defaultTiling
        if let workspacesTable = try t.table("workspace") {
            for number in workspacesTable.keys {
                guard let index = Int(number), index > 0, String(index) == number else {
                    throw ConfigError(path: workspacesTable.path(number), "expected a positive workspace number")
                }
                workspaceLayouts[index] = try WorkspaceSettings(workspacesTable.table(number)!,
                                                                base: WorkspaceSettings(tiling: defaultTiling, layout: defaultLayout))
            }
        }
        followAppActivation = try t.bool("follow-app-activation") ?? followAppActivation
        floatWindowsWithoutFullscreen = try t.bool("float-windows-without-fullscreen") ?? floatWindowsWithoutFullscreen
        accordion = try t.table("accordion").map(Accordion.init) ?? accordion
        scrolling = try t.table("scrolling").map(Scrolling.init) ?? scrolling
        gaps = try t.table("gaps").map { try gaps.applying(GapsPatch($0)) } ?? gaps
        if let displayTable = try t.table("display") {
            for pattern in displayTable.keys {
                displays.append(try DisplayOverride(pattern, displayTable.table(pattern)!))
            }
        }
        borders = try t.table("borders").map(Borders.init) ?? borders
        focusFollowsMouse = try t.table("focus-follows-mouse").map(FocusFollowsMouse.init) ?? focusFollowsMouse
        animations = try t.table("animations").map(Animations.init) ?? animations
        drag = try t.table("drag").map(Drag.init) ?? drag
        modifiers = try t.table("modifiers").map(ModifierSides.init) ?? modifiers
        hooks = try t.table("hooks").map(Hooks.init) ?? hooks
        rules = try t.tables("rules")?.map(WindowRule.init) ?? []
        if let modeTable = try t.table("mode") {
            for name in modeTable.keys {
                modes[name] = try Mode(modeTable.table(name)!)
            }
        }
        try t.done()
    }
}

public enum LayoutKind: String, CaseIterable {
    case tiles, dwindle, accordion, fixed, scrolling
}

public enum ExpansionKind: String, CaseIterable {
    case rows, columns, accordion
}

/// A workspace's tiling settings: a `[workspace.N]` table with omitted keys taken from the top-level settings,
/// or a `[workspace.N.display.<pattern>]` table with omitted keys taken from its workspace's.
public struct WorkspaceSettings: Equatable {
    public var tiling: Bool
    public var layout: LayoutKind
    public var rows = 1
    public var columns = 1
    public var expand = ExpansionKind.columns
    /// `[workspace.N.display.<pattern>]`: the settings that replace these on the displays a pattern matches,
    /// in file order.
    public var displays: [WorkspaceOnDisplay] = []

    public init(tiling: Bool, layout: LayoutKind) {
        self.tiling = tiling
        self.layout = layout
    }

    /// Display tables are read only in a workspace's own table, not nested in one another.
    init(_ t: Table, base: WorkspaceSettings, readsDisplays: Bool = true) throws {
        self = base
        displays = []
        tiling = try t.bool("tiling") ?? tiling
        layout = try t.choice("layout") ?? layout
        let columns: Int? = try t.int("columns")
        let rows: Int? = try t.int("rows")
        let expand: ExpansionKind? = try t.choice("expand")
        if let columns, columns < 1 { throw ConfigError(path: t.path("columns"), "must be at least 1") }
        if let rows, rows < 1 { throw ConfigError(path: t.path("rows"), "must be at least 1") }
        if layout != .fixed, let key = columns != nil ? "columns" : rows != nil ? "rows" : expand != nil ? "expand" : nil {
            throw ConfigError(path: t.path(key), "only valid for a fixed layout")
        }
        self.rows = rows ?? self.rows
        self.columns = columns ?? self.columns
        self.expand = expand ?? self.expand
        if readsDisplays, let displayTable = try t.table("display") {
            for pattern in displayTable.keys {
                guard !pattern.isEmpty else { throw ConfigError(path: displayTable.path, "a display pattern can't be empty") }
                let settings = try WorkspaceSettings(displayTable.table(pattern)!, base: self, readsDisplays: false)
                displays.append(WorkspaceOnDisplay(pattern: MonitorPattern(pattern), settings: settings))
            }
        }
        try t.done()
    }
}

/// One `[workspace.N.display.<pattern>]` table.
public struct WorkspaceOnDisplay: Equatable {
    public var pattern: MonitorPattern
    public var settings: WorkspaceSettings
}

extension Config {
    /// The settings of the workspace with this number, the top-level ones for an unnumbered workspace. On
    /// `monitor`, the workspace's most specific matching display table replaces them, the last of equals winning.
    public func settings(forWorkspace number: Int?, on monitor: Monitor? = nil) -> WorkspaceSettings {
        let settings = number.flatMap { workspaceLayouts[$0] } ?? WorkspaceSettings(tiling: defaultTiling, layout: defaultLayout)
        guard let monitor else { return settings }
        var best: WorkspaceOnDisplay?
        for display in settings.displays where display.pattern.matches(monitor)
            && display.pattern.specificity >= best?.pattern.specificity ?? .min {
            best = display
        }
        return best?.settings ?? settings
    }
}

/// What a container's orientation becomes when it switches to accordion: `auto`, following its longer side,
/// or `keep`, the orientation it had. An orientation chosen with a `layout` command is always kept.
public enum AccordionOrientation: String, CaseIterable {
    case auto, keep
}

public struct Accordion: Equatable {
    /// Points by which neighbouring windows peek out.
    public var padding = 30
    public var orientation = AccordionOrientation.auto

    public init() {}

    init(_ t: Table) throws {
        padding = try t.int("padding") ?? padding
        orientation = try t.choice("orientation") ?? orientation
        try t.done()
    }
}

/// `[scrolling]`: the scrolling layout's columns.
public struct Scrolling: Equatable {
    /// A new column's width, as a share of the display's width inside the outer gaps. Omarchy's 0.49 fits two
    /// columns side by side with a sliver of margin; a lone column always fills the display.
    public var columnWidth = 0.49

    public init() {}

    init(_ t: Table) throws {
        columnWidth = try t.double("column-width") ?? columnWidth
        guard (0.1...1).contains(columnWidth) else { throw ConfigError(path: t.path("column-width"), "must be 0.1 to 1") }
        try t.done()
    }
}

/// Below the target, or above it as a ring that never covers content or takes clicks.
public enum BorderOrder: String, CaseIterable {
    case below, above
}

public struct Borders: Equatable {
    public var enabled = true
    public var width = 4.0
    public var activeColor = try! Color(hex: "#e1e3e4")
    public var inactiveColor = try! Color(hex: "#494d64")
    public var order = BorderOrder.below
    /// Bundle IDs whose windows get no border.
    public var excludeApps: [String] = []

    public init() {}

    init(_ t: Table) throws {
        enabled = try t.bool("enabled") ?? enabled
        width = try t.double("width") ?? width
        activeColor = try t.color("active-color") ?? activeColor
        inactiveColor = try t.color("inactive-color") ?? inactiveColor
        order = try t.choice("order") ?? order
        excludeApps = try t.strings("exclude-apps") ?? excludeApps
        try t.done()
    }

    /// Whether windows of the app with this bundle ID get a border.
    public func decorates(bundleID: String?) -> Bool {
        !(bundleID.map(excludeApps.contains) ?? false)
    }
}

public struct FocusFollowsMouse: Equatable {
    public var enabled = false
    /// How long the pointer must rest on a window before it takes focus.
    public var delayMs = 100
    /// Whether resting on the peeking edge of an accordion child focuses it. Off, only the front child does.
    public var accordionEdges = true

    public init() {}

    init(_ t: Table) throws {
        enabled = try t.bool("enabled") ?? enabled
        delayMs = try t.int("delay-ms") ?? delayMs
        guard delayMs >= 0 else { throw ConfigError(path: t.path("delay-ms"), "must be 0 or more") }
        accordionEdges = try t.bool("accordion-edges") ?? accordionEdges
        try t.done()
    }
}

/// `[animations]`: windows glide to their tiles instead of jumping. Off while macOS's Reduce Motion is on.
public struct Animations: Equatable {
    public var enabled = true
    /// Roughly how long a window takes to reach its tile. 0 jumps, as with animations off.
    public var durationMs = 150

    public init() {}

    init(_ t: Table) throws {
        enabled = try t.bool("enabled") ?? enabled
        durationMs = try t.int("duration-ms") ?? durationMs
        guard (0...1000).contains(durationMs) else { throw ConfigError(path: t.path("duration-ms"), "must be 0 to 1000") }
        try t.done()
    }
}

/// `[drag]`: dragging a tiled window with the mouse.
public struct Drag: Equatable {
    /// Outline the tile a dragged window came from and the one it will swap with.
    public var placeholders = true
    /// Holding a dragged window still over a tile splits the tile on the drop, instead of swapping. Off by default.
    public var holdToSplit = false
    /// How long the pointer must rest on the tile first.
    public var holdMs = 500

    public init() {}

    init(_ t: Table) throws {
        placeholders = try t.bool("placeholders") ?? placeholders
        holdToSplit = try t.bool("hold-to-split") ?? holdToSplit
        holdMs = try t.int("hold-ms") ?? holdMs
        guard holdMs >= 0 else { throw ConfigError(path: t.path("hold-ms"), "must be 0 or more") }
        try t.done()
    }
}

/// Which of a modifier's two keys bindings answer to.
public enum ModifierSide: String, CaseIterable {
    case both, left, right
}

/// `[modifiers]`: a modifier limited to one side is only a binding's modifier from that side's key; the other
/// key types as usual, so right Option can still make special characters while left Option drives dinky.
public struct ModifierSides: Equatable {
    public var alt = ModifierSide.both
    public var ctrl = ModifierSide.both
    public var cmd = ModifierSide.both
    public var shift = ModifierSide.both

    public init() {}

    init(_ t: Table) throws {
        alt = try t.choice("alt") ?? alt
        ctrl = try t.choice("ctrl") ?? ctrl
        cmd = try t.choice("cmd") ?? cmd
        shift = try t.choice("shift") ?? shift
        try t.done()
    }
}

/// `[hooks]`: dinky commands run on events. Each is a command string or a list, empty by default.
public struct Hooks: Equatable {
    /// Once, after dinky has first read the windows and displays.
    public var startup: [String] = []
    /// When dinky starts switching a display to a workspace, or a switch in flight gets a new target.
    public var workspaceChanging: [String] = []
    /// When a display's current workspace changes, by dinky or natively, and when a dinky switch gives up.
    public var workspaceChanged: [String] = []
    /// When the focused window changes.
    public var focusChanged: [String] = []
    /// When the binding mode changes.
    public var modeChanged: [String] = []
    /// When a display connects or disconnects.
    public var displayChanged: [String] = []

    public init() {}

    init(_ t: Table) throws {
        startup = try t.commands("startup", allowEmpty: true) ?? startup
        workspaceChanging = try t.commands("workspace-changing", allowEmpty: true) ?? workspaceChanging
        workspaceChanged = try t.commands("workspace-changed", allowEmpty: true) ?? workspaceChanged
        focusChanged = try t.commands("focus-changed", allowEmpty: true) ?? focusChanged
        modeChanged = try t.commands("mode-changed", allowEmpty: true) ?? modeChanged
        displayChanged = try t.commands("display-changed", allowEmpty: true) ?? displayChanged
        try t.done()
    }
}
