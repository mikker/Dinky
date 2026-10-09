import Testing
@testable import DinkyConfig

/// Runs plans against a simulated WindowServer: displays with Spaces, and windows per Space.
struct WorkspacePlanTests {
    private struct World {
        var displays: [PlanDisplay]
        var windows: [UInt64: Int] = [:]  // count per Space
        var binding: [Int: UInt64] = [:]
        var nextSpace: UInt64 = 1000
        var actions: [PlanAction] = []

        /// Steps until the plan is done, applying each action as WindowServer would.
        mutating func settle(_ plan: WorkspacePlan, limit: Int = 50) {
            for _ in 0..<limit {
                let step = plan.step(displays, binding: binding, occupied: Set(windows.filter { $0.value > 0 }.keys))
                binding = step.binding
                guard let action = step.action else { return }
                actions.append(action)
                switch action {
                case .create(let uuid):
                    let i = displays.firstIndex { $0.uuid == uuid }!
                    displays[i].spaces.append(nextSpace)
                    nextSpace += 1
                case .move(let from, let to):
                    windows[to, default: 0] += windows[from, default: 0]
                    windows[from] = 0
                case .remove(let space):
                    let i = displays.firstIndex { $0.spaces.contains(space) }!
                    displays[i].spaces.removeAll { $0 == space }
                    if displays[i].current == space { displays[i].current = displays[i].spaces[0] }
                }
            }
            Issue.record("no fixed point after \(limit) steps: \(actions)")
        }

        func spaces(_ uuid: String) -> [UInt64] { displays.first { $0.uuid == uuid }!.spaces }
        func numbers(on uuid: String) -> [Int] { spaces(uuid).compactMap { s in binding.first { $0.value == s }?.key } }
    }

    private static func display(_ uuid: String, _ name: String, main: Bool, count: Int, _ spaces: [UInt64]) -> PlanDisplay {
        PlanDisplay(uuid: uuid, monitor: Monitor(name: name, isMain: main, count: count), spaces: spaces, current: spaces[0])
    }

    private let fivePlusSide = WorkspacePlan(count: 5, assignments: [5: [.secondary]])

    @Test func `Startup binds workspaces to Spaces in order`() {
        var world = World(displays: [Self.display("L", "Built-in", main: true, count: 1, [1, 2, 3])])
        world.windows = [1: 2, 3: 1]
        world.settle(fivePlusSide)
        #expect(world.actions == [.create(display: "L"), .create(display: "L")])
        #expect(world.numbers(on: "L") == [1, 2, 3, 4, 5])
        #expect(world.binding[1] == 1)
        #expect(world.binding[3] == 3)
    }

    @Test func `Docking moves the assigned workspace and removes its old Space`() {
        // Undocked: five Spaces on the laptop, workspace 5 with windows. Docked in clamshell: the laptop's Spaces
        // move to the new main display, and the side display arrives with a Space of its own.
        var world = World(displays: [Self.display("L", "Built-in", main: true, count: 1, [1, 2, 3, 4, 5])])
        world.windows = [1: 1, 5: 2]
        world.settle(fivePlusSide)
        #expect(world.actions == [])

        world.displays = [Self.display("P", "PG27UCDM", main: true, count: 2, [1, 2, 3, 4, 5]),
                          Self.display("S", "LS24D60xU", main: false, count: 2, [9])]
        world.settle(fivePlusSide)
        #expect(world.actions == [.move(from: 5, to: 9), .remove(space: 5)])
        #expect(world.numbers(on: "P") == [1, 2, 3, 4])
        #expect(world.numbers(on: "S") == [5])
        #expect(world.windows[9] == 2)
    }

    @Test func `Cleanup after replacement closes removes the extra Space without rebinding the workspace`() {
        var world = World(displays: [Self.display("L", "Built-in", main: true, count: 2, [1, 2, 3, 4, 5]),
                                     Self.display("S", "External", main: false, count: 2, [9])],
                          windows: [5: 1, 9: 1], binding: [1: 1, 2: 2, 3: 3, 4: 4, 5: 5])
        world.settle(fivePlusSide)
        #expect(world.spaces("S") == [9, 1000])
        #expect(world.binding[5] == 1000)
        // The app closes its temporary window after the session has returned to its workspace.
        world.windows[9] = 0
        world.actions = []
        world.settle(fivePlusSide)
        #expect(world.actions == [.remove(space: 9)])
        #expect(world.spaces("S") == [1000])
        #expect(world.binding[5] == 1000)
        #expect(world.windows[1000] == 1)
    }

    @Test func `Undocking keeps the merged Space and puts it back in order`() {
        var world = World(displays: [Self.display("P", "PG27UCDM", main: true, count: 2, [1, 2, 3, 4]),
                                     Self.display("S", "LS24D60xU", main: false, count: 2, [9])])
        world.windows = [9: 2]
        world.settle(fivePlusSide)
        #expect(world.numbers(on: "S") == [5])

        // macOS merges the side display's Space onto the laptop, not necessarily at the end.
        world.actions = []
        world.displays = [Self.display("L", "Built-in", main: true, count: 1, [1, 9, 2, 3, 4])]
        world.settle(fivePlusSide)
        #expect(world.actions == [.create(display: "L"), .move(from: 9, to: 1000), .remove(space: 9)])
        #expect(world.numbers(on: "L") == [1, 2, 3, 4, 5])
        #expect(world.windows[1000] == 2)
    }

    @Test func `Windows never move onto a leftover Space with windows`() {
        var world = World(displays: [Self.display("P", "PG27UCDM", main: true, count: 2, [1, 2, 3, 4]),
                                     Self.display("S", "LS24D60xU", main: false, count: 2, [9])])
        world.windows = [9: 2]
        world.settle(fivePlusSide)
        // A leftover Space with windows (X = 50) sits on the laptop when workspace 5's Space merges mid-list.
        world.actions = []
        world.displays = [Self.display("L", "Built-in", main: true, count: 1, [1, 9, 2, 3, 4, 50])]
        world.windows[50] = 1
        world.settle(fivePlusSide)
        #expect(world.actions == [.create(display: "L"), .move(from: 9, to: 1000), .remove(space: 9)])
        #expect(world.windows[50] == 1, "the leftover keeps its own window")
        #expect(world.windows[1000] == 2)
        #expect(world.numbers(on: "L") == [1, 2, 3, 4, 5])
    }

    @Test func `Undocking with the merged Space at the end moves nothing`() {
        var world = World(displays: [Self.display("P", "PG27UCDM", main: true, count: 2, [1, 2, 3, 4]),
                                     Self.display("S", "LS24D60xU", main: false, count: 2, [9])])
        world.settle(fivePlusSide)
        world.actions = []
        world.displays = [Self.display("L", "Built-in", main: true, count: 1, [1, 2, 3, 4, 9])]
        world.settle(fivePlusSide)
        #expect(world.actions == [])
        #expect(world.binding[5] == 9)
    }

    @Test func `Fallback patterns and main`() {
        let plan = WorkspacePlan(count: 3, assignments: [2: [.name("dell"), .name("lg")], 3: [.name("dell")]])
        let displays = [Self.display("M", "Built-in", main: true, count: 2, [1]),
                        Self.display("G", "LG UltraFine", main: false, count: 2, [2])]
        #expect(plan.homes(displays) == [1: "M", 2: "G", 3: "M"])
    }

    @Test func `Display without workspaces keeps one Space`() {
        var world = World(displays: [Self.display("M", "Built-in", main: true, count: 2, [1, 2]),
                                     Self.display("T", "Projector", main: false, count: 2, [7, 8, 9])])
        world.displays[1].current = 8
        world.windows = [9: 1]
        world.settle(WorkspacePlan(count: 2, assignments: [:]))
        #expect(world.actions == [.remove(space: 7)], "the current Space stays, the one with windows is left alone")
        #expect(world.spaces("T") == [8, 9])
        #expect(world.numbers(on: "T") == [])
    }

    @Test func `Fewer workspaces removes empty Spaces and leaves ones with windows`() {
        var world = World(displays: [Self.display("L", "Built-in", main: true, count: 1, [1, 2, 3, 4, 5])])
        world.windows = [4: 1]
        world.settle(WorkspacePlan(count: 5, assignments: [:]))
        world.settle(WorkspacePlan(count: 3, assignments: [:]))
        #expect(world.actions == [.remove(space: 5)])
        #expect(world.spaces("L") == [1, 2, 3, 4])
        #expect(world.numbers(on: "L") == [1, 2, 3])
    }

    @Test func `Stale and duplicate bindings are dropped`() {
        let plan = WorkspacePlan(count: 2, assignments: [:])
        let displays = [Self.display("L", "Built-in", main: true, count: 1, [1, 2])]
        let step = plan.step(displays, binding: [1: 2, 2: 2, 7: 1, 3: 99], occupied: [])
        #expect(step.binding == [1: 2], "workspace 2 must get a Space after workspace 1's; there is none yet")
        #expect(step.action == .create(display: "L"))
    }

    @Test func `No workspaces plans nothing`() {
        let plan = WorkspacePlan(count: 0, assignments: [:])
        let displays = [Self.display("L", "Built-in", main: true, count: 1, [1])]
        #expect(plan.homes(displays).isEmpty)
        #expect(plan.step(displays, binding: [1: 1], occupied: []) == PlanStep(binding: [:], action: nil))
    }

    @Test func `Redocking is stable`() {
        var world = World(displays: [Self.display("L", "Built-in", main: true, count: 1, [1, 2, 3, 4, 5])])
        world.windows = [5: 1]
        world.settle(fivePlusSide)
        for _ in 0..<3 {
            world.displays = [Self.display("P", "PG27UCDM", main: true, count: 2, world.spaces(world.displays[0].uuid)),
                              Self.display("S", "LS24D60xU", main: false, count: 2, [world.nextSpace])]
            world.nextSpace += 1
            world.settle(fivePlusSide)
            #expect(world.numbers(on: "P") == [1, 2, 3, 4])
            #expect(world.numbers(on: "S") == [5])
            let side = world.spaces("S")
            world.displays = [Self.display("L", "Built-in", main: true, count: 1, world.spaces("P") + side)]
            world.settle(fivePlusSide)
            #expect(world.numbers(on: "L") == [1, 2, 3, 4, 5])
            #expect(world.windows[world.binding[5]!] == 1, "workspace 5's window travels with it")
        }
    }
}
