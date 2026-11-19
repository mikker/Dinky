import Testing
import DinkyConfig
@testable import dinky

struct SpaceRemovalTests {
    private final class Server {
        var displays = [PlanDisplay(uuid: "L", monitor: Monitor(name: "Built-in", isMain: true, count: 1),
                                    spaces: [6, 1], current: 6)]
        var targets: [UInt64] = [1]
        var posted = true
        var lands = true
        var removable = true
        var destroyed: [UInt64] = []
        var requested: [UInt64] = []
        var afterWait: (() -> Void)?

        func remove() -> Bool {
            SpaceRemoval(snapshot: { self.displays }, destinations: { _ in self.targets }, switchTo: { target, _ in
                self.requested.append(target)
                return self.posted
            }, wait: { arrived in
                if self.lands { self.displays[0].current = 1 }
                let result = arrived()
                self.afterWait?()
                return result
            }, canRemove: { _ in self.removable }, destroy: {
                self.destroyed.append($0)
                return true
            }).remove(6)
        }
    }

    @Test func visibleSpaceRequiresObservedLandingBeforeDestruction() {
        let server = Server()
        #expect(server.remove())
        #expect(server.requested == [1])
        #expect(server.destroyed == [6])
    }

    @Test func noTargetFailedPostAndTimeoutNeverDestroy() {
        for failure in 0..<3 {
            let server = Server()
            if failure == 0 { server.targets = [6, 999] }
            if failure == 1 { server.posted = false }
            if failure == 2 { server.lands = false }
            #expect(!server.remove())
            #expect(server.destroyed.isEmpty)
        }
    }

    @Test func unknownCurrentOrMissingSourceFailsClosed() {
        for current: UInt64 in [0, 999] {
            let server = Server()
            server.displays[0].current = current
            #expect(!server.remove())
            #expect(server.destroyed.isEmpty)
        }
        let server = Server()
        server.displays = []
        #expect(!server.remove())
        #expect(server.destroyed.isEmpty)
    }

    @Test func inactiveSpaceDoesNotNeedASwipe() {
        let server = Server()
        server.displays[0].current = 1
        #expect(server.remove())
        #expect(server.requested.isEmpty)
        #expect(server.destroyed == [6])
    }

    @Test func revalidateDisplayCurrentAndEligibilityAfterWaiting() {
        for change in 0..<5 {
            let server = Server()
            server.afterWait = {
                switch change {
                case 0: server.displays = []
                case 1: server.displays[0].current = 6
                case 2: server.displays[0].spaces = [6]
                case 3: server.removable = false
                default: server.displays[0].uuid = "replacement"
                }
            }
            #expect(!server.remove())
            #expect(server.destroyed.isEmpty)
        }
    }

    @Test(arguments: [false, true]) func topologyChangeDuringObservationOrDepartureFencesDestruction(duringWait: Bool) {
        let numbers = WorkspaceNumbering()
        numbers.binding = [1: 1]
        var displays = [PlanDisplay(uuid: "L", monitor: Monitor(name: "Built-in", isMain: true, count: 1),
                                    spaces: [6, 1], current: duringWait ? 6 : 1)]
        var reads = 0
        var destroyed: [UInt64] = []
        numbers.noteTopologyChange(from: displays)
        numbers.withArrangement {
            let removal = SpaceRemoval(snapshot: {
                reads += 1
                if !duringWait && reads == 2 { numbers.noteTopologyChange(from: displays) }
                return displays
            }, destinations: { _ in [1] }, switchTo: { _, _ in true }, wait: { arrived in
                displays[0].current = 1
                let landed = arrived()
                numbers.noteTopologyChange(from: displays)
                return landed
            }, canRemove: { _ in numbers.arrangementIsCurrent }, destroy: {
                destroyed.append($0)
                return true
            })
            #expect(!removal.remove(6))
        }
        #expect(destroyed.isEmpty)
        #expect(numbers.topologyPending)
    }

    @Test func boundOrOccupiedSpaceNeverDestroysEvenWhenInactive() {
        let server = Server()
        server.displays[0].current = 1
        server.removable = false
        #expect(!server.remove())
        #expect(server.destroyed.isEmpty)
    }
}
