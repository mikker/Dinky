import Foundation
import DinkyConfig
import Testing
@testable import dinky

struct WorkspacePublicationTests {
    private final class World {
        var snapshot = [World.display([10, 20, 30], current: 10)]
        var now: UInt64 = 0
        var arranging = false
        var swipeOK = true
        var emitted: [String] = []
        let numbers = WorkspaceNumbering()
        let plan = WorkspacePlan(count: 3, assignments: [:])
        lazy var model = DisplayModel(readSnapshot: { [unowned self] in snapshot })
        lazy var switcher = SpaceSwitcher(currentSpace: { [unowned self] _ in snapshot[0].currentSpaceID },
                                         spaceIDs: { [unowned self] _ in snapshot[0].userSpaces },
                                         swipe: { [unowned self] _, _, _ in swipeOK }, clock: { [unowned self] in now },
                                         pollAutomatically: false)
        lazy var hooks = WorkspaceHooks(model: model, numbers: numbers, switcher: switcher) { [unowned self] new, old, _ in
            emitted.append("\(old)->\(new)")
        }

        init() {
            numbers.binding = [1: 10, 2: 20, 3: 30]
            model.reconcile()
            _ = hooks
            model.observe { [unowned self] _ in
                guard !arranging else { return }
                numbers.renumber(plan, on: planDisplays)
            }
        }

        var planDisplays: [PlanDisplay] {
            snapshot.map { PlanDisplay(uuid: $0.uuid, monitor: Monitor(name: "Test", isMain: true, count: 1),
                                       spaces: $0.userSpaces, current: $0.currentSpaceID) }
        }

        func arrange<T>(_ body: () throws -> T) rethrows -> T {
            arranging = true
            defer { arranging = false }
            return try numbers.withUpdates(body)
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

    @Test(arguments: [true, false]) func arrangementPublishesAfterPlannerRefreshOnCompletedAndIncompleteExit(completed: Bool) {
        let world = World()
        world.arrange {
            // Reload enables following after a hidden reorder; arranging suppresses the live observer.
            world.publish([30, 10, 20, 40, 50], current: 10)
            world.numbers.renumber(world.plan, on: world.planDisplays)
            let step = world.plan.step(world.planDisplays, binding: world.numbers.binding, occupied: [10, 20, 30])
            #expect(step.action == .remove(space: 40))
            world.numbers.binding = step.binding
            world.publish([30, 10, 20, 50], current: 10)
            #expect(world.emitted.isEmpty)
            if completed {
                let next = world.plan.step(world.planDisplays, binding: world.numbers.binding, occupied: [10, 20, 30])
                #expect(next.action == .remove(space: 50))
                world.numbers.binding = next.binding
                world.publish([30, 10, 20], current: 10)
            }
            // Otherwise the next action failed: the same finalization boundary still applies.
            #expect(world.emitted.isEmpty)
        }
        #expect(world.emitted == ["1->2"])
    }

    @Test func successfulRetargetToObservedIntermediateCompletesWithoutANewSnapshot() {
        let world = World()
        #expect(world.switcher.request(30, on: "main"))
        world.publish([20, 10, 30], current: 20)
        #expect(world.emitted.isEmpty)
        let unchanged = world.model.displays
        var arrivals = 0
        #expect(world.switcher.request(20, on: "main", landed: {
            arrivals += 1
            world.model.reconcile()
        }))
        world.now = 1_000_000_001
        world.switcher.poll()
        #expect(world.switcher.target(on: "main") == nil)
        #expect(arrivals == 1)
        #expect(world.model.displays == unchanged)
        #expect(world.emitted == ["1->1"])
        world.model.reconcile()
        #expect(world.emitted == ["1->1"])
    }

    @Test func ordinaryLandingAndSuccessfulCompletionPublishOnlyOnce() {
        let world = World()
        var arrivals = 0
        #expect(world.switcher.request(30, on: "main", landed: {
            arrivals += 1
            world.model.reconcile()
        }))
        world.publish([10, 20, 30], current: 30)
        #expect(world.emitted.isEmpty)
        world.switcher.poll()
        #expect(world.emitted == ["1->3"])
        #expect(arrivals == 1)
        world.switcher.poll()
        world.model.reconcile()
        #expect(world.emitted == ["1->3"])
    }

    @Test func switchCompletionJoinsAnOpenArrangementBoundary() {
        let world = World()
        #expect(world.switcher.request(30, on: "main"))
        world.publish([20, 10, 30], current: 20)
        world.arrange {
            #expect(world.switcher.request(20, on: "main"))
            world.now = 1_000_000_001
            world.switcher.poll()
            #expect(world.switcher.target(on: "main") == nil)
            #expect(world.emitted.isEmpty)
        }
        #expect(world.emitted == ["1->1"])
    }

    @Test func cancelledRetargetWhoseSpaceDisappearedCompletesOnObservedSpace() {
        let world = World()
        var obsoleteArrival = false
        #expect(world.switcher.request(30, on: "main", landed: { obsoleteArrival = true }))
        #expect(world.switcher.request(999, on: "main"))
        world.publish([10, 20, 30], current: 30)
        #expect(world.emitted.isEmpty)
        // The first swipe landed, but the replacement target is gone. The real post path cancels it.
        world.switcher.poll()
        #expect(world.switcher.target(on: "main") == nil)
        #expect(!obsoleteArrival)
        #expect(world.emitted == ["1->3"])
    }

    @Test func postingFailureCompletesEvenWithUnchangedSnapshotAndBinding() {
        let world = World()
        world.swipeOK = false
        let unchanged = world.model.displays
        #expect(world.switcher.request(30, on: "main"))
        #expect(world.switcher.target(on: "main") == nil)
        #expect(world.model.displays == unchanged)
        #expect(world.numbers.binding == [1: 10, 2: 20, 3: 30])
        #expect(world.emitted == ["1->1"])
        world.model.reconcile()
        #expect(world.emitted == ["1->1"])
    }

    @Test func giveUpWithoutRenumberStillHasOneAuthoritativeCompletion() {
        let world = World()
        #expect(world.switcher.request(30, on: "main"))
        world.now += 1_000_000_001
        world.switcher.poll()
        #expect(world.emitted.isEmpty)
        world.now += 1_000_000_001
        world.switcher.poll()
        #expect(world.switcher.target(on: "main") == nil)
        #expect(world.emitted == ["1->1"])
    }

    @Test func unchangedBindingStillFinalizesRawCurrentSpaceUpdates() {
        let world = World()
        world.arrange {
            world.publish([10, 20, 30], current: 30)
            #expect(world.emitted.isEmpty)
        }
        #expect(world.numbers.binding == [1: 10, 2: 20, 3: 30])
        #expect(world.emitted == ["1->3"])
        world.arrange {} // No changed binding or snapshot, and no pending obligation.
        #expect(world.emitted == ["1->3"])
    }

    @Test func cancelledNetRenumberPublishesNoContentsRefresh() {
        let world = World()
        let unchanged = world.model.displays
        world.arrange {
            let reversed = PlanDisplay(uuid: "main", monitor: Monitor(name: "Test", isMain: true, count: 1),
                                       spaces: [30, 20, 10], current: 10)
            world.numbers.renumber(world.plan, on: [reversed])
            world.numbers.renumber(world.plan, on: world.planDisplays)
        }
        #expect(world.numbers.binding == [1: 10, 2: 20, 3: 30])
        #expect(world.model.displays == unchanged)
        #expect(world.emitted.isEmpty)
    }

    @Test func thrownCancellationFinalizesTheLastObservedState() {
        enum Stop: Error { case cancelled }
        let world = World()
        #expect(throws: Stop.self) {
            try world.arrange {
                world.publish([30, 10, 20], current: 10)
                world.numbers.renumber(world.plan, on: world.planDisplays)
                #expect(world.emitted.isEmpty)
                throw Stop.cancelled
            }
        }
        #expect(!world.numbers.updating)
        #expect(world.emitted == ["1->2"])
    }
}
