import Testing
import DinkyConfig
@testable import dinky

struct WorkspaceNumberingTests {
    private let plan = WorkspacePlan(count: 4, assignments: [4: [.secondary]])
    private let initial: [Int: UInt64] = [1: 10, 2: 20, 3: 30, 4: 40]

    private func displays(_ spaces: [UInt64] = [10, 30, 20]) -> [PlanDisplay] {
        [PlanDisplay(uuid: "main", monitor: Monitor(name: "Main", isMain: true, count: 2), spaces: spaces, current: 10),
         PlanDisplay(uuid: "side", monitor: Monitor(name: "Side", isMain: false, count: 2), spaces: [40], current: 40)]
    }

    @Test func topologyPreservesOnlyBindingsAlreadyOnSurvivingDisplays() {
        let numbers = WorkspaceNumbering()
        numbers.binding = initial
        let before = displays([10, 20, 30])
        var after = [before[0]]
        after[0].spaces = [40, 10, 20, 30]
        numbers.noteTopologyChange(from: before)
        #expect(numbers.preservedSpaces(on: after) == [10, 20, 30])
        numbers.renumber(plan, on: after)
        #expect(numbers.binding == initial)
        // Changing only the visible Space does not discard the preservation.
        var switched = after
        switched[0].current = 20
        numbers.acceptSpaceReorders(from: after, to: switched)
        #expect(numbers.preservedSpaces(on: after) == [10, 20, 30])
        // A genuine Mission Control reorder restores normal reorder semantics.
        switched[0].spaces = [40, 30, 20, 10]
        numbers.acceptSpaceReorders(from: after, to: switched)
        #expect(numbers.preservedSpaces(on: switched).isEmpty)
        numbers.renumber(plan, on: switched)
        #expect(numbers.binding == [1: 40, 2: 30, 3: 20, 4: 10])
    }

    @Test func aSpaceReusedByAnotherWorkspaceDoesNotInheritPreservation() {
        let numbers = WorkspaceNumbering()
        numbers.binding = initial
        numbers.noteTopologyChange(from: displays())
        numbers.binding = [1: 20, 2: 10, 3: 30, 4: 40]
        #expect(numbers.preservedSpaces(on: displays()) == [30, 40])
    }

    @Test func temporarilyUnlistedSurvivingSpacesKeepTheirOldIdentities() {
        let numbers = WorkspaceNumbering()
        let plan = WorkspacePlan(count: 9, assignments: Dictionary(uniqueKeysWithValues: (6...9).map { ($0, [.name("built-in")]) }))
        let original = Dictionary(uniqueKeysWithValues: (1...9).map { ($0, UInt64($0)) })
        numbers.binding = original
        let docked = [
            PlanDisplay(uuid: "D", monitor: Monitor(name: "Dell", isMain: true, count: 2), spaces: [1, 2, 3, 4, 5], current: 1),
            PlanDisplay(uuid: "L", monitor: Monitor(name: "Built-in", isMain: false, count: 2), spaces: [6, 7, 8, 9], current: 6),
        ]
        // First callback: display survives but WindowServer temporarily omits all four old Spaces.
        let transient = [PlanDisplay(uuid: "L", monitor: Monitor(name: "Built-in", isMain: true, count: 1),
                                     spaces: [1, 2, 3, 4, 5], current: 1)]
        numbers.noteTopologyChange(from: docked)
        #expect(numbers.preservedSpaces(on: transient).isEmpty)
        // The existing reconciliation wait restores them before planning, without another topology change.
        let settled = [PlanDisplay(uuid: "L", monitor: transient[0].monitor, spaces: [6, 7, 8, 9, 1, 2, 3, 4, 5], current: 6)]
        #expect(numbers.preservedSpaces(on: settled) == [6, 7, 8, 9])
        let step = plan.step(settled, binding: numbers.binding, occupied: [6, 8], preserving: numbers.preservedSpaces(on: settled))
        #expect(step.binding == original)
        #expect(step.action == nil)
    }

    @Test func capturedHomeDoesNotPreserveASpaceRestoredOnAnotherDisplay() {
        let numbers = WorkspaceNumbering()
        numbers.binding = initial
        let before = displays([10, 20, 30])
        var transient = before
        transient[0].spaces = []
        numbers.noteTopologyChange(from: before)
        var settled = before
        settled[0].spaces = [10, 30]
        settled[1].spaces = [20, 40]
        #expect(numbers.preservedSpaces(on: settled) == [10, 30, 40])
        // If the old display itself subsequently disconnects, its captured provenance is retired.
        numbers.noteTopologyChange(from: transient)
        #expect(numbers.preservedSpaces(on: [settled[1]]) == [40])
    }

    @Test func chainedTopologyCallbacksKeepTheOriginalHomeUntilSettlement() {
        let numbers = WorkspaceNumbering()
        let plan = WorkspacePlan(count: 9, assignments: Dictionary(uniqueKeysWithValues: (6...9).map { ($0, [.name("built-in")]) }))
        let original = Dictionary(uniqueKeysWithValues: (1...9).map { ($0, UInt64($0)) })
        numbers.binding = original
        let dell = PlanDisplay(uuid: "D", monitor: Monitor(name: "Dell", isMain: true, count: 3), spaces: [1, 2, 3, 4, 5], current: 1)
        let laptop = PlanDisplay(uuid: "L", monitor: Monitor(name: "Built-in", isMain: false, count: 3), spaces: [6, 7, 8, 9], current: 6)
        let extra = PlanDisplay(uuid: "X", monitor: Monitor(name: "Extra", isMain: false, count: 3), spaces: [50], current: 50)
        var transient = [laptop, extra]
        transient[0].monitor.isMain = true
        transient[0].spaces = []
        transient[1].spaces = [6, 7, 8, 9, 50]
        numbers.noteTopologyChange(from: [dell, laptop, extra])
        let connected = PlanDisplay(uuid: "C", monitor: Monitor(name: "Connected", isMain: false, count: 3), spaces: [60], current: 60)
        numbers.noteTopologyChange(from: transient)
        var settled = [laptop, extra, connected]
        settled[0].monitor.isMain = true
        settled[0].spaces = [6, 7, 8, 9, 1, 2, 3, 4, 5]
        #expect(numbers.preservedSpaces(on: settled) == [6, 7, 8, 9])
        let step = plan.step(settled, binding: numbers.binding, occupied: [6, 8], preserving: numbers.preservedSpaces(on: settled))
        #expect(step.binding == original)
        #expect(step.action == nil)
    }

    @Test func aLaterSettledTopologyChangeCapturesTheNewHome() {
        let numbers = WorkspaceNumbering()
        numbers.binding = initial
        let original = displays([10, 20, 30])
        numbers.noteTopologyChange(from: original)
        numbers.withArrangement {} // finish the first topology chain
        // A deliberate move while settled changes the actual home without changing the Space ID.
        var moved = original
        moved[0].spaces = [10, 30]
        moved[1].spaces = [20, 40]
        numbers.noteTopologyChange(from: moved)
        #expect(numbers.preservedSpaces(on: moved) == [10, 20, 30, 40])
        #expect(numbers.preservedSpaces(on: original) == [10, 30, 40])
    }

    @Test func arrangementFinalizesTopologyAndPublishesAfterDisabledNumberingToo() {
        let numbers = WorkspaceNumbering()
        numbers.binding = initial
        let before = displays([10, 20, 30])
        numbers.noteTopologyChange(from: before)
        var publications = 0
        numbers.observe { _ in publications += 1 }
        #expect(numbers.topologyPending)
        numbers.withArrangement {
            #expect(numbers.arranging)
            #expect(numbers.topologyPending)
            // Disabled numbering carries out no action, but it still finishes this shared scope.
            #expect(publications == 0)
        }
        #expect(!numbers.arranging)
        #expect(!numbers.topologyPending)
        #expect(publications == 1)
        numbers.acceptSpaceReorders(from: before, to: displays([30, 20, 10]))
        numbers.renumber(plan, on: displays([30, 20, 10]))
        #expect(numbers.binding == [1: 30, 2: 20, 3: 10, 4: 40])
    }

    @Test func arrangementFailureAlsoFinalizesTopology() {
        enum Failure: Error { case interrupted }
        let numbers = WorkspaceNumbering()
        numbers.noteTopologyChange(from: displays())
        #expect(throws: Failure.interrupted) {
            try numbers.withArrangement { throw Failure.interrupted }
        }
        #expect(!numbers.arranging)
        #expect(!numbers.topologyPending)
    }

    @Test func topologyDuringArrangementRollsBackIdentityAndHomesBeforePublication() {
        let numbers = WorkspaceNumbering()
        numbers.binding = initial
        numbers.homes = [102: 2]
        numbers.pendingHomes = [202: 2]
        var published: [[Int: UInt64]] = []
        var changes: [Set<String>] = []
        numbers.observe { changed in
            published.append(numbers.binding)
            changes.append(changed)
        }
        numbers.withArrangement {
            numbers.renumber(plan, on: displays())
            numbers.binding[4] = 50
            numbers.noteTopologyChange(from: displays([10, 20, 30]))
            #expect(!numbers.arrangementIsCurrent)
            #expect(published.isEmpty)
        }
        #expect(numbers.topologyPending)
        #expect(!numbers.arranging)
        #expect(numbers.binding == initial)
        #expect(numbers.homes == [102: 2])
        #expect(numbers.pendingHomes == [202: 2])
        #expect(published == [initial])
        #expect(changes == [[]])
        // First callback must capture the pre-arrangement identities, not the speculative numbering.
        #expect(numbers.preservedSpaces(on: displays([10, 20, 30])) == [10, 20, 30, 40])
    }

    @Test func repeatedTopologyCallbackInvalidatesEvenWhileAlreadyPending() {
        let numbers = WorkspaceNumbering()
        numbers.binding = initial
        let original = displays([10, 20, 30])
        numbers.noteTopologyChange(from: original)
        numbers.withArrangement {
            #expect(numbers.arrangementIsCurrent)
            numbers.binding[4] = 50
            numbers.noteTopologyChange(from: [original[0]])
            #expect(!numbers.arrangementIsCurrent)
        }
        #expect(numbers.topologyPending)
        #expect(numbers.binding == initial)
        #expect(numbers.preservedSpaces(on: original) == [10, 20, 30, 40])
        // The next coherent arrangement can settle; no indefinitely missing-ID veto is needed.
        numbers.withArrangement {
            #expect(numbers.arrangementIsCurrent)
            numbers.binding[4] = 50
        }
        #expect(!numbers.topologyPending)
        #expect(numbers.binding[4] == 50)
    }

    @Test func invalidatedTransientPlanDoesNotKeepReplacementWorkspaceIdentity() {
        let numbers = WorkspaceNumbering()
        let plan = WorkspacePlan(count: 9, assignments: Dictionary(uniqueKeysWithValues:
            (1...9).map { ($0, [.name($0 <= 5 ? "Dell" : "Built-in")]) }))
        let original: [Int: UInt64] = [1: 1, 2: 6444, 3: 6445, 4: 6446, 5: 6447,
                                       6: 7440, 7: 7433, 8: 7434, 9: 7435]
        let dell = PlanDisplay(uuid: "D", monitor: Monitor(name: "Dell", isMain: true, count: 2),
                               spaces: [1, 6444, 6445, 6446, 6447], current: 1)
        let laptop = PlanDisplay(uuid: "L", monitor: Monitor(name: "Built-in", isMain: false, count: 2),
                                 spaces: [7440, 7433, 7434, 7435], current: 7440)
        var transient = [PlanDisplay(uuid: "L", monitor: Monitor(name: "Built-in", isMain: true, count: 1),
                                     spaces: [7441, 7433, 7434, 7435], current: 7441)]
        numbers.binding = original
        numbers.noteTopologyChange(from: [dell, laptop])
        numbers.withArrangement {
            // Replay the reporter's five creates, then observe reconnect before the next action.
            for id: UInt64 in 7443...7447 {
                let step = plan.step(transient, binding: numbers.binding, occupied: [],
                                     preserving: numbers.preservedSpaces(on: transient))
                #expect(step.action == .create(display: "L"))
                numbers.binding = step.binding
                transient[0].spaces.append(id)
            }
            numbers.binding = plan.step(transient, binding: numbers.binding, occupied: [],
                                        preserving: numbers.preservedSpaces(on: transient)).binding
            #expect(numbers.binding[6] == 7447)
            numbers.noteTopologyChange(from: transient)
            #expect(!numbers.arrangementIsCurrent)
        }
        #expect(numbers.binding == original)
        #expect(numbers.topologyPending)
        numbers.withArrangement {
            // The old identities return. Created native Spaces may remain, but cannot steal w6's identity.
            let step = plan.step([dell, laptop], binding: numbers.binding, occupied: [],
                                 preserving: numbers.preservedSpaces(on: [dell, laptop]))
            #expect(step.action == nil)
            #expect(step.binding == original)
        }
        #expect(!numbers.topologyPending)
    }

    @Test(arguments: [true, false]) func lateInvalidationRestoresConsumedDisplacedObligation(enabled: Bool) {
        let numbers = WorkspaceNumbering()
        numbers.binding = initial
        numbers.displaced.displaysChanged()
        numbers.noteTopologyChange(from: displays())
        var publishedPending: [Bool] = []
        numbers.observe { _ in publishedPending.append(numbers.displaced.pending) }
        numbers.withArrangement {
            #expect(numbers.displaced.arranged(enabled: enabled, completed: true) == (enabled ? .returnThem : .leaveThem))
            #expect(!numbers.displaced.pending)
            // returnDisplaced/final reconciliation sees a main-display change, not a new disconnect.
            // Such a change invalidates the plan without calling displaced.displaysChanged again.
            numbers.noteTopologyChange(from: displays())
        }
        #expect(numbers.topologyPending)
        #expect(numbers.displaced.pending)
        #expect(publishedPending == [true], "Restore recovery before publishing the rolled-back identities")
        numbers.withArrangement {
            #expect(numbers.displaced.arranged(enabled: enabled, completed: true) == (enabled ? .returnThem : .leaveThem))
        }
        #expect(!numbers.topologyPending)
        #expect(!numbers.displaced.pending)
        #expect(publishedPending == [true, false])
    }

    @Test func invalidationKeepsNewDisplacedObligationWhenNoneWasPendingAtEntry() {
        let numbers = WorkspaceNumbering()
        numbers.withArrangement {
            #expect(!numbers.displaced.pending)
            numbers.noteTopologyChange(from: displays())
            numbers.displaced.displaysChanged()
        }
        #expect(numbers.topologyPending)
        #expect(numbers.displaced.pending, "Cancellation must not overwrite a newer display callback")
    }

    @Test func renumberRemapsBothHomeGenerationsWithoutSamplingWindows() {
        let numbers = WorkspaceNumbering()
        numbers.binding = initial
        // Different generations are intentional: neither may be replaced by a fresh WindowServer sample.
        numbers.homes = [101: 1, 102: 2, 103: 3, 104: 4, 105: 9]
        numbers.pendingHomes = [202: 2, 203: 3, 204: 4]
        numbers.renumber(plan, on: displays())
        #expect(numbers.binding == [1: 10, 2: 30, 3: 20, 4: 40])
        #expect(numbers.homes == [101: 1, 102: 3, 103: 2, 104: 4, 105: 9])
        #expect(numbers.pendingHomes == [202: 3, 203: 2, 204: 4])
        // A subsequent timer tick may promote pendingHomes. It must not resurrect the old numbering.
        numbers.homes = numbers.pendingHomes!
        #expect(numbers.binding[numbers.homes[202]!] == 20)
        #expect(numbers.binding[numbers.homes[203]!] == 30)
    }

    @Test func quickDisconnectDoesNotDisplaceUnaffectedMainDisplayWindows() {
        let numbers = WorkspaceNumbering()
        numbers.binding = initial
        numbers.homes = [102: 2, 103: 3, 104: 4]
        numbers.renumber(plan, on: displays())
        // The secondary goes away before another homes sample. Its windows pour onto Space 10;
        // a plan step binds its workspace to a replacement Space 50 on the main display.
        let main = PlanDisplay(uuid: "main", monitor: Monitor(name: "Main", isMain: true, count: 1),
                               spaces: [10, 30, 20, 50], current: 10)
        let step = plan.step([main], binding: numbers.binding, occupied: [10, 20, 30])
        #expect(step.action == nil)
        numbers.binding = step.binding
        #expect(numbers.binding[numbers.homes[102]!] == 20)
        #expect(numbers.binding[numbers.homes[103]!] == 30)
        #expect(numbers.binding[numbers.homes[104]!] == 50)
    }

    @Test func reloadedNumberingRefreshesHiddenWorkspacesOnceAtFinalAnnouncement() {
        let numbers = WorkspaceNumbering()
        numbers.binding = initial
        var hooks = WorkspaceHookState(workspaces: ["main": "1", "side": "4"])
        var emitted: [String] = []
        var announcements = 0
        numbers.observe { renumbered in
            announcements += 1
            hooks.invalidate(renumbered)
            for display in displays() {
                let new = numbers.binding.first { $0.value == display.current }!.key.description
                if let old = hooks.update(display.uuid, to: new, stable: !numbers.updating) {
                    emitted.append("\(display.uuid):\(old)->\(new)")
                }
            }
        }
        // This is the shared numbering operation used by arrange (reload), disabled numberInPlace,
        // and the live display observer. No notifications escape before the final binding is ready.
        numbers.withUpdates {
            numbers.renumber(plan, on: displays())
            #expect(emitted.isEmpty)
        }
        #expect(announcements == 1)
        #expect(emitted == ["main:1->1"])
        numbers.renumber(plan, on: displays())
        #expect(announcements == 2, "Even unchanged updates finalize, without executing an unchanged hook")
        #expect(emitted == ["main:1->1"])
    }

    @Test func visibleNumberChangeAndRenumberProduceOneHook() {
        let numbers = WorkspaceNumbering()
        numbers.binding = initial
        var hooks = WorkspaceHookState(workspaces: ["main": "2"])
        var previous: [String] = []
        numbers.observe { changed in
            hooks.invalidate(changed)
            let new = numbers.binding.first { $0.value == 20 }!.key.description
            if let old = hooks.update("main", to: new, stable: !numbers.updating) {
                previous.append(old)
            }
        }
        numbers.renumber(plan, on: displays())
        // A display-model notification for the same settled snapshot must not repeat the hook.
        #expect(hooks.update("main", to: "3", stable: true) == nil)
        #expect(previous == ["2"])
    }

    @Test func ordinaryPlanMovesKeepNumberedHomesAndDoNotReportARenumber() {
        let numbers = WorkspaceNumbering()
        numbers.binding = initial
        numbers.homes = [102: 2]
        numbers.pendingHomes = [202: 2]
        var changes: [Set<String>] = []
        numbers.observe { changes.append($0) }
        numbers.withUpdates { numbers.binding[2] = 50 }
        #expect(numbers.homes == [102: 2])
        #expect(numbers.pendingHomes == [202: 2])
        #expect(changes == [[]])
    }

    @Test func repeatedRenumbersComposeAndMissingPendingHomesStaysMissing() {
        let numbers = WorkspaceNumbering()
        numbers.binding = initial
        numbers.homes = [102: 2, 103: 3]
        numbers.renumber(plan, on: displays())
        numbers.renumber(plan, on: displays([30, 20, 10]))
        #expect(numbers.binding[numbers.homes[102]!] == 20)
        #expect(numbers.binding[numbers.homes[103]!] == 30)
        #expect(numbers.pendingHomes == nil)
    }

    @Test func announcementCoalescesChangesOnMultipleDisplays() {
        let numbers = WorkspaceNumbering()
        numbers.binding = initial
        let split = WorkspacePlan(count: 4, assignments: [3: [.secondary], 4: [.secondary]])
        let reordered = [
            PlanDisplay(uuid: "main", monitor: Monitor(name: "Main", isMain: true, count: 2), spaces: [20, 10], current: 20),
            PlanDisplay(uuid: "side", monitor: Monitor(name: "Side", isMain: false, count: 2), spaces: [40, 30], current: 40),
        ]
        var changes: [Set<String>] = []
        numbers.observe { changes.append($0) }
        numbers.withUpdates {
            numbers.renumber(split, on: reordered)
            numbers.renumber(split, on: reordered)
        }
        #expect(changes == [["main", "side"]])
    }

    @Test func cancelledRenumberDoesNotLeakIntoTheNextAnnouncement() {
        let numbers = WorkspaceNumbering()
        numbers.binding = initial
        numbers.homes = [102: 2]
        var changes: [Set<String>] = []
        numbers.observe { changes.append($0) }
        numbers.withUpdates {
            numbers.renumber(plan, on: displays())
            numbers.renumber(plan, on: displays([10, 20, 30]))
        }
        #expect(changes == [[]], "The cancelled update finalizes with no net renumber")
        #expect(numbers.homes == [102: 2])
        numbers.withUpdates { numbers.binding[4] = 50 }
        #expect(changes == [[], []])
    }

    @Test func hookStateSuppressesNewDisplaysAndIntermediateSwipeNumbers() {
        var hooks = WorkspaceHookState()
        hooks.invalidate(["main"])
        #expect(hooks.update("main", to: "1", stable: true) == nil)
        #expect(hooks.update("main", to: "2", stable: false) == nil)
        #expect(hooks.workspaces["main"] == "1")
        #expect(hooks.update("main", to: "3", stable: true) == "1")
    }
}
