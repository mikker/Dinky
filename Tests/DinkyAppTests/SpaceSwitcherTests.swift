import Foundation
import Testing
@testable import dinky

struct SpaceSwitcherTests {
    private final class World {
        var now: UInt64 = 0
        var current: [String: UInt64] = ["A": 1, "B": 101]
        // Noncontiguous IDs include a full-screen Space between ordinary desktops.
        var spaces: [String: [UInt64]] = ["A": [1, 13, 99, 15, 16, 17], "B": [101, 113, 114]]
        var posts: [String] = []
        var settlements: [String] = []
        var targets: [UInt64] = []
        var duringPost: (() -> Void)?
        var ok = true
        let batches: Bool
        var dock: pid_t? = 42
        lazy var switcher = SpaceSwitcher(currentSpace: { [unowned self] in current[$0] ?? 0 },
                                         spaceIDs: { [unowned self] in spaces[$0] ?? [] },
                                         swipe: { [unowned self] from, to, uuid in
                                             posts.append("\(uuid):\(from)->\(to)")
                                             let action = duringPost
                                             duringPost = nil
                                             action?()
                                             return ok
                                         }, clock: { [unowned self] in now },
                                         pollAutomatically: false, batchMovement: batches,
                                         dockProcess: { [unowned self] in dock })
        init(batches: Bool = false) {
            self.batches = batches
            switcher.onSettled = { [unowned self] in settlements.append($0) }
            switcher.onTarget = { [unowned self] _, target in targets.append(target) }
        }
        func observe(_ id: UInt64, on uuid: String = "A") {
            current[uuid] = id
            switcher.poll()
        }
    }

    @Test func stalledMovementIsNeverRetriedAndEachStepNeedsAcknowledgment() {
        let w = World()
        var landed = 0
        #expect(w.switcher.request(15, on: "A", landed: { landed += 1 }))
        w.now = 1_200_000_000
        w.switcher.poll()
        #expect(w.posts == ["A:1->2"])
        w.observe(13)
        #expect(w.posts == ["A:1->2", "A:2->3"])
        w.observe(99) // full-screen Space is an actual native ordinal, not a numbered workspace
        #expect(w.posts == ["A:1->2", "A:2->3", "A:3->4"])
        w.observe(15)
        #expect(landed == 1)
        #expect(w.settlements == ["A"])
        #expect(!w.switcher.switching)
    }

    @Test func retargetToObservedOriginCannotReversePendingMovement() {
        let w = World()
        var oldArrival = false
        var latestArrival = false
        _ = w.switcher.request(15, on: "A", landed: { oldArrival = true })
        _ = w.switcher.request(1, on: "A", landed: { latestArrival = true })
        w.now = 1_500_000_000
        w.switcher.poll()
        #expect(w.posts.count == 1)
        #expect(!latestArrival)
        w.observe(13)
        #expect(w.posts.last == "A:2->1")
        w.observe(1)
        #expect(!oldArrival)
        #expect(latestArrival)
    }

    @Test func giveUpRetainsNativeOwnershipAndLateLandingDoesNotActivate() {
        let w = World()
        var arrived = false
        _ = w.switcher.request(15, on: "A", landed: { arrived = true })
        w.now = 2_000_000_001
        w.switcher.poll()
        #expect(w.switcher.target(on: "A") == nil)
        #expect(w.switcher.destination(on: "A") == 13)
        #expect(w.switcher.switching)
        #expect(w.settlements == ["A"])
        w.now *= 10
        w.switcher.poll()
        #expect(w.posts.count == 1)
        w.observe(13)
        #expect(!arrived)
        #expect(!w.switcher.switching)
        #expect(w.switcher.destination(on: "A") == nil)
        #expect(w.settlements == ["A"])
        #expect(w.posts.count == 1)
    }

    @Test func newRequestsAfterGiveUpCoalesceBehindUnresolvedNativeMovement() {
        let w = World()
        _ = w.switcher.request(15, on: "A")
        w.now = 2_000_000_001
        w.switcher.poll()
        _ = w.switcher.request(1, on: "A")
        _ = w.switcher.request(17, on: "A")
        w.switcher.poll()
        #expect(w.posts == ["A:1->2"])
        w.observe(13)
        #expect(w.posts == ["A:1->2", "A:2->3"])
        #expect(w.switcher.target(on: "A") == 17)
    }

    @Test func retargetToPendingEndpointCompletesWithoutPostingObsoleteRemainingSteps() {
        let w = World()
        var arrived = false
        _ = w.switcher.request(17, on: "A")
        _ = w.switcher.request(13, on: "A", landed: { arrived = true })
        w.switcher.poll()
        #expect(w.posts == ["A:1->2"])
        #expect(!arrived)
        w.observe(13)
        #expect(w.posts == ["A:1->2"])
        #expect(arrived)
    }

    @Test func reentrantRequestsAndOtherDisplaysDoNotPostInsideCursorWarp() {
        let w = World()
        w.duringPost = {
            _ = w.switcher.request(1, on: "A")
            _ = w.switcher.request(114, on: "B")
            w.switcher.poll()
            #expect(w.posts == ["A:1->2"])
        }
        _ = w.switcher.request(15, on: "A")
        w.switcher.poll()
        #expect(w.posts == ["A:1->2", "B:1->2"])
        w.observe(13)
        #expect(w.posts.last == "A:2->1")
        w.observe(113, on: "B")
        #expect(w.posts.last == "B:2->3")
        w.observe(1)
        w.observe(114, on: "B")
        #expect(Set(w.settlements) == ["A", "B"])
        #expect(!w.switcher.switching)
    }

    @Test func missingRetargetIsRejectedOnlyAfterPendingMovementLands() {
        let w = World()
        _ = w.switcher.request(15, on: "A")
        _ = w.switcher.request(999, on: "A")
        w.switcher.poll()
        #expect(w.switcher.target(on: "A") == 999)
        w.observe(13)
        #expect(!w.switcher.switching)
        #expect(w.posts.count == 1)
        #expect(w.settlements == ["A"])
    }

    @Test func reverseJourneyUsesFreshNativeOrdinalsAndOnlyLatestArrival() {
        let w = World()
        w.current["A"] = 17
        var obsoleteArrival = false
        var latestArrivals = 0
        _ = w.switcher.request(1, on: "A", landed: { obsoleteArrival = true })
        _ = w.switcher.request(1, on: "A", landed: { latestArrivals += 1 })
        for id: UInt64 in [16, 15, 99, 13, 1] { w.observe(id) }
        #expect(w.posts == ["A:6->5", "A:5->4", "A:4->3", "A:3->2", "A:2->1"])
        #expect(w.targets == [1])
        #expect(!obsoleteArrival)
        #expect(latestArrivals == 1)
    }

    @Test func giveUpBudgetIsPerPendingStepNotWholeJourney() {
        let w = World()
        var arrived = false
        _ = w.switcher.request(15, on: "A", landed: { arrived = true })
        for id: UInt64 in [13, 99, 15] {
            w.now += 1_500_000_000
            w.observe(id)
        }
        #expect(arrived)
        #expect(!w.switcher.switching)
        #expect(w.settlements == ["A"])
    }

    @Test func removedPendingDestinationInvalidatesRatherThanReplaysTheRequest() {
        let w = World()
        var arrived = false
        _ = w.switcher.request(15, on: "A")
        w.spaces["A"] = [1, 99, 15, 16, 17]
        _ = w.switcher.request(17, on: "A", landed: { arrived = true })
        w.switcher.poll()
        #expect(!w.switcher.switching)
        #expect(!arrived)
        #expect(w.posts == ["A:1->2"])
        #expect(w.settlements == ["A"])
    }

    @Test func disconnectReleasesOnlyThatDisplaysFlight() {
        let w = World()
        _ = w.switcher.request(15, on: "A")
        _ = w.switcher.request(114, on: "B")
        w.spaces.removeValue(forKey: "A")
        w.current.removeValue(forKey: "A")
        w.switcher.poll()
        #expect(w.switcher.target(on: "A") == nil)
        #expect(w.switcher.target(on: "B") == 114)
        #expect(w.switcher.switching)
        #expect(w.settlements == ["A"])
        w.observe(113, on: "B")
        w.observe(114, on: "B")
        #expect(!w.switcher.switching)
        #expect(w.posts == ["A:1->2", "B:1->2", "B:2->3"])
    }

    @Test(arguments: [true, false]) func dockReplacementReleasesLostMovementWithoutObsoleteArrival(giveUpFirst: Bool) {
        let w = World()
        var arrived = false
        _ = w.switcher.request(15, on: "A", landed: { arrived = true })
        if giveUpFirst {
            w.now = 3_000_000_000
            w.switcher.poll()
        }
        w.dock = 43 // actual native queue owner changed, not just elapsed time
        w.observe(13) // even a coincident endpoint cannot activate the obsolete request
        #expect(!w.switcher.switching)
        #expect(!arrived)
        #expect(w.settlements == ["A"])
        #expect(w.posts == ["A:1->2"])
        _ = w.switcher.request(15, on: "A")
        #expect(w.posts == ["A:1->2", "A:2->3"])
    }

    @Test func missedEndpointDuringPhysicalGestureIsNotProofQueuedMovementWasCancelled() {
        let w = World()
        var arrived = false
        _ = w.switcher.request(15, on: "A", landed: { arrived = true })
        w.observe(99) // a physical gesture can move first, while our 1->13 is still pending
        w.now = 3_000_000_000
        w.switcher.poll()
        #expect(w.switcher.switching)
        #expect(!arrived)
        #expect(w.posts == ["A:1->2"])
        w.dock = nil // confirmed native owner exit is an explicit recovery boundary
        w.switcher.poll()
        #expect(!w.switcher.switching)
        #expect(w.settlements == ["A"])
    }

    @Test func augmentedBatchIsAcknowledgedBeforeRetargetingWithoutIntermediateActivation() {
        let w = World(batches: true)
        var obsoleteArrival = false
        var latestArrival = false
        _ = w.switcher.request(15, on: "A", landed: { obsoleteArrival = true })
        w.observe(13)
        _ = w.switcher.request(1, on: "A", landed: { latestArrival = true })
        #expect(w.posts == ["A:1->4"])
        #expect(w.settlements.isEmpty)
        w.observe(15)
        #expect(w.posts == ["A:1->4", "A:4->1"])
        #expect(!obsoleteArrival)
        #expect(!latestArrival)
        w.observe(1)
        #expect(latestArrival)
        #expect(w.settlements == ["A"])
        #expect(!w.switcher.switching)
    }

    @Test func augmentedGiveUpRetainsTheWholePostedBatchEndpoint() {
        let w = World(batches: true)
        var obsoleteArrival = false
        _ = w.switcher.request(15, on: "A", landed: { obsoleteArrival = true })
        w.now = 3_000_000_000
        w.switcher.poll()
        #expect(w.switcher.target(on: "A") == nil)
        #expect(w.switcher.destination(on: "A") == 15)
        _ = w.switcher.request(17, on: "A")
        w.observe(13)
        #expect(w.posts == ["A:1->4"])
        w.observe(15)
        #expect(w.posts == ["A:1->4", "A:4->6"])
        w.observe(17)
        #expect(!obsoleteArrival)
        #expect(w.settlements == ["A", "A"])
        #expect(!w.switcher.switching)
    }

    @Test(arguments: [true, false]) func failedPostReleasesOwnershipWithoutArrival(batches: Bool) {
        let w = World(batches: batches)
        w.ok = false
        var arrived = false
        _ = w.switcher.request(15, on: "A", landed: { arrived = true })
        #expect(!w.switcher.switching)
        #expect(!arrived)
        #expect(w.settlements == ["A"])
    }
}
