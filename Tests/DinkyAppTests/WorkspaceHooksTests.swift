import Foundation
import DinkyConfig
import Testing
@testable import dinky

struct WorkspaceHooksTests {
    /// Same registration order as startup: the real hook subscriptions come before the numbering observer.
    /// The real model dispatches snapshots; its numbering observer uses production renumbering without
    /// starting WorkspaceNumbers' WindowServer subscriptions, timer or arrangement side effects.
    private final class World {
        var snapshot = [World.display([10, 20, 30], current: 10)]
        var now: UInt64 = 0
        var emitted: [String] = []
        let numbers = WorkspaceNumbering()
        lazy var model = DisplayModel(readSnapshot: { [unowned self] in snapshot })
        lazy var switcher = SpaceSwitcher(currentSpace: { [unowned self] _ in snapshot[0].currentSpaceID },
                                         spaceIDs: { [unowned self] _ in snapshot[0].userSpaces },
                                         swipe: { _, _, _ in true }, clock: { [unowned self] in now },
                                         pollAutomatically: false)
        lazy var hooks = WorkspaceHooks(model: model, numbers: numbers, switcher: switcher) { [unowned self] new, old, i in
            emitted.append("\(i):\(old)->\(new)")
        }

        init() {
            numbers.binding = [1: 10, 2: 20, 3: 30]
            model.reconcile()
            _ = hooks
            model.observe { [unowned self] model in
                let displays = model.displays.map {
                    PlanDisplay(uuid: $0.uuid, monitor: Monitor(name: "Test", isMain: $0.isMain, count: model.displays.count),
                                spaces: $0.userSpaces, current: $0.currentSpaceID)
                }
                numbers.renumber(WorkspacePlan(count: 3, assignments: [:]), on: displays)
            }
        }

        func beginSwitch() { #expect(switcher.request(30, on: "main")) }

        func giveUp() {
            now += 1_000_000_001
            switcher.poll() // retry
            now += 1_000_000_001
            switcher.poll() // authoritative failure completion
        }

        func publish(_ spaces: [UInt64], current: UInt64) {
            snapshot = [Self.display(spaces, current: current)]
            model.reconcile()
        }

        static func display(_ spaces: [UInt64], current: UInt64) -> Display {
            Display(uuid: "main", id: 0, frame: .zero, visibleArea: .zero, isMain: true,
                    spaces: spaces, userSpaces: spaces, currentSpaceID: current)
        }
    }

    @Test func combinedReorderAndCurrentSpaceChangeUsesFinalNumbering() {
        let world = World()
        world.publish([10, 30, 20], current: 30)
        #expect(world.numbers.binding == [1: 10, 2: 30, 3: 20])
        #expect(world.emitted == ["0:1->2"])
    }

    @Test func renumberDuringSwipeWaitsForLandingEvenIfTargetKeepsOldNumber() {
        let world = World()
        world.beginSwitch()
        world.publish([30, 20, 10], current: 20)
        #expect(world.emitted.isEmpty)
        world.publish([30, 20, 10], current: 30)
        #expect(world.emitted.isEmpty, "A matching snapshot is not authoritative flight completion")
        world.switcher.poll()
        #expect(world.emitted == ["0:1->1"])
        world.model.reconcile()
        #expect(world.emitted == ["0:1->1"])
    }

    @Test func intermediateSpaceWithOldNumberDoesNotConsumeRenumberEarly() {
        let world = World()
        world.beginSwitch()
        world.publish([20, 10, 30], current: 20)
        #expect(world.emitted.isEmpty)
        world.publish([20, 10, 30], current: 30)
        world.switcher.poll()
        #expect(world.emitted == ["0:1->3"])
    }

    @Test func giveUpConsumesDeferredRenumberOnceAfterReReadingTheDisplay() {
        let world = World()
        world.beginSwitch()
        world.publish([30, 20, 10], current: 20)
        #expect(world.emitted.isEmpty)
        // The authoritative failure's re-read may publish a new snapshot.
        world.snapshot = [World.display([30, 20, 10], current: 10)]
        world.giveUp()
        #expect(world.emitted == ["0:1->3"])
        world.model.reconcile()
        #expect(world.emitted == ["0:1->3"])
    }

    @Test func giveUpWithoutDisplayChangeStillCompletesTheSwitch() {
        let world = World()
        world.beginSwitch()
        world.publish([20, 10, 30], current: 20)
        #expect(world.emitted.isEmpty)
        world.giveUp()
        #expect(world.emitted == ["0:1->1"])
        world.model.reconcile()
        #expect(world.emitted == ["0:1->1"])
    }

    @Test func repeatedInFlightRenumbersCoalesceIntoOneSettledRefresh() {
        let world = World()
        world.beginSwitch()
        world.publish([30, 20, 10], current: 20)
        world.publish([30, 10, 20], current: 10)
        #expect(world.emitted.isEmpty)
        world.publish([30, 10, 20], current: 30)
        world.switcher.poll()
        #expect(world.emitted == ["0:1->1"])
    }

    @Test func unchangedNumberingStillReportsNativeSwitches() {
        let world = World()
        world.publish([10, 20, 30], current: 30)
        #expect(world.emitted == ["0:1->3"])
    }

    @Test func deferredRenumbersAreConsumedPerDisplay() {
        var state = WorkspaceHookState(workspaces: ["main": "1", "side": "4"])
        state.invalidate(["main", "side"])
        #expect(state.update("main", to: "2", stable: false) == nil)
        #expect(state.update("side", to: "5", stable: false) == nil)
        #expect(state.update("main", to: "1", stable: true) == "1")
        #expect(state.update("main", to: "1", stable: true) == nil)
        #expect(state.update("side", to: "4", stable: true) == "4")
        #expect(state.update("side", to: "4", stable: true) == nil)
    }
}
