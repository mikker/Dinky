import DinkyLayout
import Foundation
import Testing
@testable import dinky

struct RefocusTargetTests {
    @Test func picksTheWindowFocusedLast() {
        #expect(Coordinator.refocusTarget(recent: [5, 1], front: [3, 1], leaving: 9, eligible: { _ in true }) == 5)
    }

    @Test func skipsTheLeavingWindowAndIneligibleOnes() {
        // 7 had focus on another display; 4 is the window that left.
        let eligible: Set<WindowID> = [1, 3]
        #expect(Coordinator.refocusTarget(recent: [7, 4, 1], front: [3, 1], leaving: 4, eligible: eligible.contains) == 1)
    }

    @Test func fallsBackToTheFrontmostWindowNeverFocused() {
        #expect(Coordinator.refocusTarget(recent: [4], front: [4, 2, 3], leaving: 4, eligible: { _ in true }) == 2)
    }

    @Test func readsTheSpaceOnlyWhenNoRecentWindowIsEligible() {
        var read = false
        func front() -> [WindowID] { read = true; return [2] }
        #expect(Coordinator.refocusTarget(recent: [1], front: front(), leaving: 9, eligible: { _ in true }) == 1)
        #expect(!read)
    }

    @Test func nothingToFocusOnAnEmptySpace() {
        #expect(Coordinator.refocusTarget(recent: [], front: [], leaving: 1, eligible: { _ in true }) == nil)
        #expect(Coordinator.refocusTarget(recent: [1], front: [1], leaving: 1, eligible: { _ in true }) == nil)
    }
}

struct FocusLossTests {
    @Test func theFocusedWindowHadFocus() {
        #expect(FocusLosses().hadFocus(3, focused: 3, at: 10))
    }

    @Test func aWindowThatLostFocusAsItClosedHadFocus() {
        // macOS moves focus off a closing window a moment before the close arrives.
        var losses = FocusLosses()
        losses.lost(3, at: 10)
        #expect(losses.hadFocus(3, focused: 5, at: 10.07))
    }

    @Test func aWindowTheUserHadLeftDidNotHaveFocus() {
        // Focus moved to another display, then the window closed by itself (`sleep 1; exit`).
        var losses = FocusLosses()
        losses.lost(3, at: 10)
        #expect(!losses.hadFocus(3, focused: 5, at: 10.5))
    }

    @Test func eachWindowKeepsItsOwnLoss() {
        // Two focus changes before the close: 3 lost focus to 0, then 0 to 5 on another display.
        var losses = FocusLosses()
        losses.lost(3, at: 10)
        losses.lost(0, at: 10.02)
        #expect(losses.hadFocus(3, focused: 5, at: 10.05))
    }

    @Test func oldLossesAreDroppedAndRepeatsReplaced() {
        var losses = FocusLosses()
        losses.lost(3, at: 10)
        losses.lost(3, at: 10.05)
        #expect(losses.count == 1)
        losses.lost(4, at: 11)
        #expect(losses.count == 1)
        #expect(!losses.hadFocus(3, focused: 5, at: 11))
    }

    @Test func unknownForgottenAndLaterLossesDoNotCount() {
        var losses = FocusLosses()
        losses.lost(3, at: 10)
        losses.lost(4, at: 10.01)
        losses.forget(3)
        #expect(!losses.hadFocus(3, focused: 5, at: 10.02))
        #expect(!losses.hadFocus(6, focused: 5, at: 10.02))
        // A loss stamped after the time asked about does not count either.
        #expect(!losses.hadFocus(4, focused: 5, at: 10))
    }

    @Test func theClockKeepsMovingForward() {
        let first = FocusLosses.now
        #expect(FocusLosses.now >= first)
    }
}
