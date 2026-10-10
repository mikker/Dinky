import Foundation
import Testing
@testable import dinky

struct WorkspaceRecoveryStateTests {
    private func identity(_ id: UInt32, seen: Double = 1) -> Window.Identity {
        .init(id: id, pid: 10, firstSeen: Date(timeIntervalSince1970: seen))
    }

    @Test func `Window churn leaves no cached titles or pending moves`() {
        var state = WorkspaceRecoveryState()
        for id in UInt32(1)...1_000 {
            let window = identity(id)
            state.cacheTitle("Session", for: window)
            let submitted = state.beginMove(window, to: 5)
            #expect(submitted)
            state.remove(window)
        }
        #expect(state.titles.isEmpty)
        #expect(state.moves.isEmpty)
    }

    @Test func `Title changes invalidate only the changed window`() {
        var state = WorkspaceRecoveryState()
        let old = identity(1), other = identity(2)
        state.cacheTitle("Old", for: old)
        state.cacheTitle("Other", for: other)
        state.invalidateTitle(old)
        #expect(state.titles[old] == nil)
        #expect(state.titles[other] == "Other")
        state.cacheTitle("New", for: old)
        #expect(state.titles[old] == "New")
    }

    @Test func `Reused window IDs do not inherit titles or moves`() {
        var state = WorkspaceRecoveryState()
        let old = identity(1), new = identity(1, seen: 2)
        state.cacheTitle("Old", for: old)
        let oldSubmitted = state.beginMove(old, to: 5)
        #expect(oldSubmitted)
        state.retain(live: [new], destinations: [new: 5])
        #expect(state.titles.isEmpty)
        #expect(state.moves.isEmpty)
        let newSubmitted = state.beginMove(new, to: 5)
        #expect(newSubmitted)
    }

    @Test func `Delayed arrival suppresses duplicate requests until confirmed`() {
        var state = WorkspaceRecoveryState()
        var history = WindowRestorationHistory()
        let window = identity(1)
        let submitted = state.beginMove(window, to: 5)
        #expect(submitted)
        let prematureArrival = state.confirmMove(window, on: 1, history: &history)
        #expect(!prematureArrival)
        #expect(!history.wasRestored(window))
        let duplicateSubmitted = state.beginMove(window, to: 5)
        #expect(!duplicateSubmitted)
        let arrived = state.confirmMove(window, on: 5, history: &history)
        #expect(arrived)
        #expect(history.wasRestored(window))
        #expect(history.returnedDuringChange(window))
        let duplicateArrival = state.confirmMove(window, on: 5, history: &history)
        #expect(!duplicateArrival)
        #expect(state.moves.isEmpty)
    }

    @Test func `Immediate arrivals and rejected requests leave no pending move`() {
        var state = WorkspaceRecoveryState()
        var history = WindowRestorationHistory()
        let window = identity(1)
        let submitted = state.beginMove(window, to: 5)
        #expect(submitted)
        let arrived = state.confirmMove(window, on: 5, history: &history)
        #expect(arrived)
        #expect(history.wasRestored(window))
        #expect(history.returnedDuringChange(window))
        let secondSubmitted = state.beginMove(window, to: 6)
        #expect(secondSubmitted)
        state.rejectMove(window)
        #expect(state.moves.isEmpty)
        let retrySubmitted = state.beginMove(window, to: 6)
        #expect(retrySubmitted)
    }

    @Test func `Changed or removed destinations discard outstanding requests`() {
        var state = WorkspaceRecoveryState()
        let changed = identity(1), removed = identity(2)
        let changedSubmitted = state.beginMove(changed, to: 5)
        #expect(changedSubmitted)
        let removedSubmitted = state.beginMove(removed, to: 6)
        #expect(removedSubmitted)
        state.retain(live: [changed, removed], destinations: [changed: 7])
        #expect(state.moves.isEmpty)
        let newDestinationSubmitted = state.beginMove(changed, to: 7)
        #expect(newDestinationSubmitted)
    }

    @Test func `A new display transition clears titles and allows another return`() {
        var state = WorkspaceRecoveryState()
        let window = identity(1)
        state.cacheTitle("Session", for: window)
        let submitted = state.beginMove(window, to: 5)
        #expect(submitted)
        state.reset()
        #expect(state.titles.isEmpty)
        #expect(state.moves.isEmpty)
        let nextTransitionSubmitted = state.beginMove(window, to: 5)
        #expect(nextTransitionSubmitted)
    }
}
