import DinkyConfig

// The numbering and its recovery journal, independent of WindowServer. Only a renumber changes what a
// workspace number means; a plan step moving its windows to a new Space must keep their recorded homes.
class WorkspaceNumbering {
    /// Workspace number to native Space ID.
    var binding: [Int: UInt64] = [:]
    /// Window homes while the displays were settled, plus the sample awaiting a second settled tick.
    var homes: [UInt32: Int] = [:]
    var pendingHomes: [UInt32: Int]?
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
            let updated = plan.renumbered(displays, binding: binding)
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
            print("workspaces: " + binding.keys.sorted().map { "\($0)=\(binding[$0]!)" }.joined(separator: " "))
        }
        observers.forEach { $0(renumbered) }
    }
}
