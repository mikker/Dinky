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
