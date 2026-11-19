import DinkyConfig

// The numbering and its recovery journal, independent of WindowServer. Only a renumber changes what a
// workspace number means; a plan step moving its windows to a new Space must keep their recorded homes.
class WorkspaceNumbering {
    /// Workspace number to native Space ID.
    var binding: [Int: UInt64] = [:]
    /// Window homes while the displays were settled, plus the sample awaiting a second settled tick.
    var homes: [UInt32: Int] = [:]
    var pendingHomes: [UInt32: Int]?
    /// Windows displaced by a display change are recovered only by the next coherent arrangement.
    var displaced = DisplacedWindows()
    private(set) var arranging = false
    private(set) var topologyPending = false
    private var topologyGeneration: UInt64 = 0
    private var arrangementGeneration: UInt64?
    private var arrangementBinding: [Int: UInt64]?

    /// A refreshed observation may invalidate the plan even when a topology transition was already pending.
    var arrangementIsCurrent: Bool { arrangementGeneration == topologyGeneration }
    /// Old workspace/Space/display identities, captured before macOS's transient new Space list.
    /// Keep these across arrangements; the next config reload must not undo preservation.
    private var topologyHomes: [Int: (space: UInt64, display: String)] = [:]

    func preservedSpaces(on displays: [PlanDisplay]) -> Set<UInt64> {
        Set(topologyHomes.filter { n, home in
            binding[n] == home.space && displays.contains { $0.uuid == home.display && $0.spaces.contains(home.space) }
        }.values.map(\.space))
    }

    func noteTopologyChange(from before: [PlanDisplay]) {
        // Only the first callback has a settled `before`. Further callbacks in this chain may list a
        // Space on a temporary host, even when its original display is still connected.
        topologyGeneration &+= 1
        guard !topologyPending else { return }
        topologyPending = true
        topologyHomes = [:]
        for (n, space) in arrangementBinding ?? binding {
            guard let old = before.first(where: { $0.spaces.contains(space) }) else { continue }
            topologyHomes[n] = (space, old.uuid)
        }
    }

    /// Enabled arrangements and disabled numbering share one settlement/publication boundary. Only an
    /// uninterrupted topology generation settles; an invalidated run keeps the original identity journal.
    func withArrangement<T>(_ update: () throws -> T) rethrows -> T {
        arranging = true
        arrangementGeneration = topologyGeneration
        let originalBinding = binding
        arrangementBinding = originalBinding
        let originalRenumberedDisplays = renumberedDisplays
        let originalHomes = homes
        let originalPendingHomes = pendingHomes
        let hadDisplacedWindows = displaced.pending
        defer {
            arranging = false
            arrangementGeneration = nil
            arrangementBinding = nil
        }
        return try withUpdates {
            defer {
                if arrangementIsCurrent {
                    topologyPending = false
                } else {
                    // Native steps cannot be undone, but a transient snapshot must not replace identities
                    // or window homes. The next arrangement plans afresh from the original journal.
                    binding = originalBinding
                    homes = originalHomes
                    pendingHomes = originalPendingHomes
                    renumberedDisplays = originalRenumberedDisplays
                    // Recovery can itself refresh topology after consuming this obligation. Restore it,
                    // without overwriting a newer display callback's pending recovery.
                    if hadDisplacedWindows { displaced.displaysChanged() }
                }
            }
            return try update()
        }
    }

    /// A genuine strip reorder (not a current-Space change or create/remove) restores the ordinary
    /// numeric-order policy on that display. Topology-induced ordering itself is not a user reorder.
    func acceptSpaceReorders(from before: [PlanDisplay], to after: [PlanDisplay]) {
        for display in after {
            guard let old = before.first(where: { $0.uuid == display.uuid }),
                  old.spaces != display.spaces, Set(old.spaces) == Set(display.spaces) else { continue }
            topologyHomes = topologyHomes.filter { $0.value.display != display.uuid }
        }
    }

    private var observers: [(Set<String>) -> Void] = []
    private var renumberedDisplays: Set<String> = []
    private var updateDepth = 0

    /// Snapshots and numbering may change inside an operation; hooks only consume its stable result.
    var updating: Bool { updateDepth > 0 }

    /// Called at every outer update's completion, even if its final binding equals the initial binding.
    /// The set names displays whose workspace contents changed number.
    func observe(_ handler: @escaping (Set<String>) -> Void) { observers.append(handler) }

    /// One publication boundary for arrangements, live renumbering and switch settlement re-reads.
    /// Nested updates join it. Early returns and thrown errors still finalize the observed state once.
    func withUpdates<T>(_ update: () throws -> T) rethrows -> T {
        let start = binding
        updateDepth += 1
        defer {
            updateDepth -= 1
            if !updating { publish(since: start) }
        }
        return try update()
    }

    func renumber(_ plan: WorkspacePlan, on displays: [PlanDisplay]) {
        withUpdates {
            let updated = plan.renumbered(displays, binding: binding, preserving: preservedSpaces(on: displays))
            guard updated != binding else { return }
            // Do not re-read windows here: macOS may already be pouring them off a disconnecting display.
            // Translate both journal generations through the Space they named before the renumber.
            var numbers: [Int: Int] = [:]
            for (n, space) in binding { numbers[n] = updated.first { $0.value == space }?.key }
            homes = homes.mapValues { numbers[$0] ?? $0 }
            pendingHomes = pendingHomes?.mapValues { numbers[$0] ?? $0 }
            let moved = Set(updated.filter { binding[$0.key] != $0.value }.values)
            renumberedDisplays.formUnion(displays.filter { $0.spaces.contains(where: moved.contains) }.map(\.uuid))
            binding = updated
        }
    }

    private func publish(since start: [Int: UInt64]) {
        let renumbered = binding == start ? [] : renumberedDisplays
        renumberedDisplays = []
        if binding != start {
            print("\(stamp()) workspaces: " + binding.keys.sorted().map { "\($0)=\(binding[$0]!)" }.joined(separator: " "))
        }
        observers.forEach { $0(renumbered) }
    }
}
