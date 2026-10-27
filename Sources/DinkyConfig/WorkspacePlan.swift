// Which native Space each workspace is, and the one step that brings the Spaces closer to the config: a
// workspace per Space, each on its display (`[workspace-to-display]`, else the main display), in number order
// on each display, and no empty Space left over. The app runs the step, re-reads the Spaces and asks again,
// so a change macOS makes halfway (a display coming or going) is planned around rather than fought.
// Pure: no AppKit, no WindowServer. The app supplies the Spaces and carries out the steps.

/// A display as the plan sees it.
public struct PlanDisplay: Equatable {
    public var uuid: String
    public var monitor: Monitor
    /// User Spaces in Mission Control order; full-screen Spaces are left out.
    public var spaces: [UInt64]
    public var current: UInt64

    public init(uuid: String, monitor: Monitor, spaces: [UInt64], current: UInt64) {
        self.uuid = uuid
        self.monitor = monitor
        self.spaces = spaces
        self.current = current
    }
}

public enum PlanAction: Equatable {
    /// Create a user Space at the end of the display's strip.
    case create(display: String)
    /// Move every window on one Space to another.
    case move(from: UInt64, to: UInt64)
    /// Remove an empty Space no workspace is on.
    case remove(space: UInt64)
}

public struct PlanStep: Equatable {
    /// Workspace number to Space, updated for this step. The app keeps it for the next one. It assumes the
    /// action succeeds; the app reverts it when the action fails.
    public var binding: [Int: UInt64]
    /// What to do next, nil when the Spaces match the config.
    public var action: PlanAction?
}

public struct WorkspacePlan {
    public let count: Int
    public let assignments: [Int: [MonitorPattern]]

    public init(count: Int, assignments: [Int: [MonitorPattern]]) {
        self.count = count
        self.assignments = assignments
    }

    public init(_ config: Config) {
        self.init(count: config.workspaces, assignments: config.workspaceDisplays)
    }

    /// Workspace numbers, 1 through `count`; none when `count` is 0.
    private var numbers: StrideThrough<Int> { stride(from: 1, through: count, by: 1) }

    /// The display each workspace lives on: the display its first matching pattern names, else the main one.
    public func homes(_ displays: [PlanDisplay]) -> [Int: String] {
        guard let main = displays.first(where: \.monitor.isMain) ?? displays.first else { return [:] }
        var homes: [Int: String] = [:]
        for n in numbers {
            let assigned = assignments[n]?.lazy.compactMap { pattern in displays.first { pattern.matches($0.monitor) } }.first
            homes[n] = (assigned ?? main).uuid
        }
        return homes
    }

    /// The next step from where things stand. `binding` is the previous step's; `occupied` is the Spaces that
    /// have windows on them. Workspaces are placed display by display, in number order, each on the first free
    /// Space after the previous one's (a new Space when there is none), moving its windows along when it
    /// changes Space; windows only ever go to an empty Space, so two sets never mix. Then empty Spaces no
    /// workspace is on are removed; one is kept on a display with no workspace, which macOS requires anyway.
    /// A leftover Space with windows is left alone.
    public func step(_ displays: [PlanDisplay], binding: [Int: UInt64], occupied: Set<UInt64>) -> PlanStep {
        let all = Set(displays.flatMap(\.spaces))
        // Forget Spaces that are gone and workspaces past the count; one workspace per Space.
        var binding = binding.filter { n, space in numbers.contains(n) && all.contains(space) }
        for n in binding.keys.sorted() where binding.contains(where: { $0.key < n && $0.value == binding[n] }) {
            binding[n] = nil
        }
        let homes = homes(displays)

        for display in displays {
            var last = -1  // position of the previous workspace's Space on this display
            for n in numbers.filter({ homes[$0] == display.uuid }) {
                if let space = binding[n], let at = display.spaces.firstIndex(of: space), at > last {
                    last = at
                    continue
                }
                let bound = Set(binding.values)
                let old = binding[n].flatMap { occupied.contains($0) ? $0 : nil }
                guard let at = display.spaces.indices.first(where: { i in
                    i > last && !bound.contains(display.spaces[i]) && (old == nil || !occupied.contains(display.spaces[i]))
                }) else {
                    return PlanStep(binding: binding, action: .create(display: display.uuid))
                }
                binding[n] = display.spaces[at]
                last = at
                if let old { return PlanStep(binding: binding, action: .move(from: old, to: display.spaces[at])) }
            }
        }

        let bound = Set(binding.values)
        for display in displays {
            let hasWorkspace = display.spaces.contains(where: bound.contains)
            let keep = hasWorkspace ? nil : (display.spaces.contains(display.current) ? display.current : display.spaces.first)
            if let space = display.spaces.first(where: { !bound.contains($0) && $0 != keep && !occupied.contains($0) }) {
                return PlanStep(binding: binding, action: .remove(space: space))
            }
        }
        return PlanStep(binding: binding, action: nil)
    }

    /// The binding renumbered to follow the order the Spaces now have, as a drag in Mission Control leaves them:
    /// on each display, the numbers of the workspaces that live there go, smallest first, to their Spaces from
    /// left to right. Spaces and windows stay where they are, and the numbers are back in the order `step`
    /// keeps, so it has nothing to move. A workspace off its display, or whose Space is gone, keeps its number.
    public func renumbered(_ displays: [PlanDisplay], binding: [Int: UInt64]) -> [Int: UInt64] {
        let homes = homes(displays)
        var result = binding
        for display in displays {
            let here = binding.filter { homes[$0.key] == display.uuid && display.spaces.contains($0.value) }
            let spaces = display.spaces.filter { here.values.contains($0) }
            for (n, space) in zip(here.keys.sorted(), spaces) { result[n] = space }
        }
        return result
    }
}
