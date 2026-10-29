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
    public var followAppActivation = FollowAppActivation()
    /// Float standard windows whose fullscreen button is missing or disabled, as AeroSpace does.
    public var floatWindowsWithoutFullscreen = true
    /// The share of the width inside the outer gaps a fullscreen window takes, centred.
    /// 1 fills the width. `[display.<pattern>]` and workspace tables override it.
    public var fullscreenWidth = 1.0
    /// A lone window's share, or nil to use the resolved fullscreen width.
    public var loneWindowWidth: Double?
    public var accordion = Accordion()
    public var scrolling = Scrolling()
    public var master = Master()
    public var gaps = Gaps()
    /// `[display.<pattern>]` overrides, in file order.
    public var displays: [DisplayOverride] = []
    public var borders = Borders()
    public var focusFollowsMouse = FocusFollowsMouse()
    public var swipe = Swipe()
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

    /// Write the default config to `url`, creating its folder, if there is nothing there yet. A symlink counts
    /// even when what it points to is missing, such as a dotfiles checkout not cloned yet: writing would replace it.
    public static func writeDefaultIfMissing(at url: URL) {
        // Unlike fileExists, attributesOfItem describes a symlink itself rather than following it.
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (defaultTOML + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

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
        followAppActivation = try FollowAppActivation(t, "follow-app-activation") ?? followAppActivation
        floatWindowsWithoutFullscreen = try t.bool("float-windows-without-fullscreen") ?? floatWindowsWithoutFullscreen
        fullscreenWidth = try t.windowWidth("fullscreen-width") ?? fullscreenWidth
        loneWindowWidth = try t.windowWidth("lone-window-width")
        accordion = try t.table("accordion").map(Accordion.init) ?? accordion
        scrolling = try t.table("scrolling").map(Scrolling.init) ?? scrolling
        master = try t.table("master").map(Master.init) ?? master
        gaps = try t.table("gaps").map { try gaps.applying(GapsPatch($0)) } ?? gaps
        if let displayTable = try t.table("display") {
            for pattern in displayTable.keys {
                displays.append(try DisplayOverride(pattern, displayTable.table(pattern)!))
            }
        }
        borders = try t.table("borders").map(Borders.init) ?? borders
        focusFollowsMouse = try t.table("focus-follows-mouse").map(FocusFollowsMouse.init) ?? focusFollowsMouse
        swipe = try t.table("swipe").map(Swipe.init) ?? swipe
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
    case tiles, dwindle, accordion, fixed, scrolling, master
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
    /// `fullscreen-width` from this table or the workspace's it inherits from; nil leaves it to the display's or
    /// the top-level value. See `Config.fullscreenWidth(forWorkspace:on:)`.
    public var fullscreenWidth: Double?
    /// A lone window's share from this table or its workspace, before display and top-level resolution.
    public var loneWindowWidth: Double?
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
        fullscreenWidth = try t.windowWidth("fullscreen-width") ?? fullscreenWidth
        loneWindowWidth = try t.windowWidth("lone-window-width") ?? loneWindowWidth
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

    /// The share of the width a fullscreen window takes on the workspace with this number on
    /// `monitor`: the workspace's own tables' value, else the most specific matching `[display.<pattern>]`'s, else
    /// the top-level `fullscreen-width`.
    public func fullscreenWidth(forWorkspace number: Int?, on monitor: Monitor? = nil) -> Double {
        if let width = settings(forWorkspace: number, on: monitor).fullscreenWidth { return width }
        guard let monitor else { return fullscreenWidth }
        return overrides(for: monitor).last { $0.fullscreenWidth != nil }?.fullscreenWidth ?? fullscreenWidth
    }

    /// Resolve the lone-window share independently, falling back only after every level has been checked.
    public func loneWindowWidth(forWorkspace number: Int?, on monitor: Monitor? = nil) -> Double {
        if let width = settings(forWorkspace: number, on: monitor).loneWindowWidth { return width }
        if let monitor, let width = overrides(for: monitor).last(where: { $0.loneWindowWidth != nil })?.loneWindowWidth {
            return width
        }
        return loneWindowWidth ?? fullscreenWidth(forWorkspace: number, on: monitor)
    }
}

extension Table {
    /// Window widths share the same range at every level of the config.
    func windowWidth(_ key: String) throws -> Double? {
        guard let width = try double(key) else { return nil }
        guard (0.1...1).contains(width) else { throw ConfigError(path: path(key), "must be 0.1 to 1") }
        return width
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

/// `[master]`: the master layout's master window, after Hyprland's `master` category.
public struct Master: Equatable {
    /// The master's share of the display's width inside the outer gaps while other windows are stacked beside it.
    /// Hyprland calls it `mfact`. Alone, the master fills the display.
    public var size = 0.6
    /// The side the master takes; the stack goes on the other. Hyprland calls it `orientation`.
    public var side = MasterSide.left

    public init() {}

    init(_ t: Table) throws {
        size = try t.double("size") ?? size
        guard (0.1...0.9).contains(size) else { throw ConfigError(path: t.path("size"), "must be 0.1 to 0.9") }
        side = try t.choice("side") ?? side
        try t.done()
    }
}

public enum MasterSide: String, CaseIterable {
    case left, right
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

/// `follow-app-activation = true`, or a table for apps not to follow.
public struct FollowAppActivation: Equatable {
    public var enabled = true
    /// Bundle IDs whose activation is not followed, such as a menu bar app whose popover counts as a window.
    public var excludeApps: [String] = []

    public init() {}

    init(_ t: Table) throws {
        enabled = try t.bool("enabled") ?? enabled
        excludeApps = try t.strings("exclude-apps") ?? excludeApps
        try t.done()
    }

    /// `key` in `parent` as written, `true`, `false` or a table; nil when it is absent.
    init?(_ parent: Table, _ key: String) throws {
        if parent.isTable(key) {
            try self.init(parent.table(key)!)
        } else if let enabled = try parent.bool(key) {
            self.init()
            self.enabled = enabled
        } else {
            return nil
        }
    }

    /// Whether activating the app with this bundle ID switches to its Space.
    public func follows(bundleID: String?) -> Bool {
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

/// `[swipe]`: the trackpad swipe that switches Spaces (three fingers, or four if macOS is set so) moves focus
/// between a tiled workspace's windows first, and switches Space only past the last one.
public struct Swipe: Equatable {
    public var enabled = false
    /// How a swipe past the last window switches Space.
    public var spaceSwitch = SpaceSwitch.instant
    /// Whether the swipe up and down, Mission Control's and App Exposé's, focuses the windows below and above first.
    public var vertical = false

    public init() {}

    init(_ t: Table) throws {
        enabled = try t.bool("enabled") ?? enabled
        spaceSwitch = try t.choice("space-switch") ?? spaceSwitch
        vertical = try t.bool("vertical") ?? vertical
        try t.done()
    }
}

/// `instant`: dinky keeps the swipe from macOS and switches with its own fast swipe once the fingers lift.
/// `native`: macOS sees the swipe begin and end, so a short swipe moves focus and a full one switches Space.
public enum SpaceSwitch: String, CaseIterable {
    case instant, native
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
/// `[drag] split-trigger`: resting the pointer on a tile for `split-delay-ms`, or holding a modifier key.
public enum SplitTrigger: String, CaseIterable {
    case off, hold, alt, ctrl, cmd, shift
}

public struct Drag: Equatable {
    /// Outline the tile a dragged window came from and the one it will swap with.
    public var placeholders = true
    /// What makes a drop split the tile under the pointer instead of swapping. Off by default.
    public var splitTrigger = SplitTrigger.off
    /// How long the pointer must rest on the tile first, with `split-trigger = 'hold'`.
    public var splitDelayMs = 500

    public init() {}

    init(_ t: Table) throws {
        placeholders = try t.bool("placeholders") ?? placeholders
        splitTrigger = try t.choice("split-trigger") ?? splitTrigger
        splitDelayMs = try t.int("split-delay-ms") ?? splitDelayMs
        guard splitDelayMs >= 0 else { throw ConfigError(path: t.path("split-delay-ms"), "must be 0 or more") }
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
