import CoreGraphics
import DinkyLayout
import Foundation
import Testing
@testable import dinky

struct RefocusTargetTests {
    @Test func locatesAClosedWindowUsingItsLastFrame() {
        let frames = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        let displays = frames.enumerated().map { index, frame in
            Display(uuid: "\(index)", id: 0, frame: frame, visibleArea: frame, isMain: index == 0,
                    spaces: [UInt64(index + 1)], userSpaces: [UInt64(index + 1)], currentSpaceID: UInt64(index + 1))
        }
        let model = DisplayModel(readSnapshot: { displays })
        model.reconcile()
        #expect(model.display(containing: CGRect(x: 1200, y: 100, width: 400, height: 300))?.currentSpaceID == 2)
        #expect(model.display(containing: CGRect(x: -1000, y: 100, width: 400, height: 300)) == nil)
    }

    @Test(arguments: [false, true])
    func repairsOnlyMissingOrStaleKeyboardFocus(removed: Bool) {
        let input = RefocusInput(counts: [1, 2, 3, 4, 5])
        let source = RefocusWindow(id: 9, pid: 42, space: 10, display: "left")
        let repair = FocusRepair(leaving: source, removed: removed, input: input)
        #expect(repair.allows(keyboard: RefocusWindow(id: 0, pid: 0, space: 0, display: nil), input: input))
        #expect(repair.allows(keyboard: source, input: input))
        #expect(!repair.allows(keyboard: RefocusWindow(id: 3, pid: 42, space: 10, display: "left"), input: input))
        #expect(!repair.allows(keyboard: nil, input: input))
    }

    @Test func removalRepairsOnlyTheSameAppsOtherDisplayRedirect() {
        let input = RefocusInput(counts: [1, 2, 3, 4, 5, 6])
        let repair = FocusRepair(leaving: RefocusWindow(id: 9, pid: 42, space: 10, display: "left"), removed: true, input: input)
        #expect(repair.allows(keyboard: RefocusWindow(id: 3, pid: 42, space: 20, display: "right"), input: input))
        #expect(!repair.allows(keyboard: RefocusWindow(id: 3, pid: 99, space: 20, display: "right"), input: input))
        #expect(!repair.allows(keyboard: RefocusWindow(id: 3, pid: 42, space: 11, display: "left"), input: input))
        #expect(!repair.allows(keyboard: RefocusWindow(id: 3, pid: 42, space: 20, display: nil), input: input))
        #expect(!repair.allows(keyboard: RefocusWindow(id: 3, pid: 42, space: 0, display: "right"), input: input))
        let unknown = FocusRepair(leaving: RefocusWindow(id: 9, pid: 0, space: 10, display: "left"), removed: true, input: input)
        #expect(!unknown.allows(keyboard: RefocusWindow(id: 3, pid: 0, space: 20, display: "right"), input: input))
    }

    @Test func minimizeLeavesTheSameAppsOtherDisplayKeyWindowAlone() {
        let input = RefocusInput(counts: [1, 2, 3, 4, 5, 6])
        let repair = FocusRepair(leaving: RefocusWindow(id: 9, pid: 42, space: 10, display: "left"), removed: false, input: input)
        #expect(!repair.allows(keyboard: RefocusWindow(id: 3, pid: 42, space: 20, display: "right"), input: input))
    }

    @Test func aCompletedTabDragCannotAuthorizeARepair() {
        let input = RefocusInput(counts: [1, 2, 3, 4, 5, 6], dragged: true)
        let repair = FocusRepair(leaving: RefocusWindow(id: 9, pid: 42, space: 10, display: "left"), removed: true, input: input)
        #expect(!repair.allows(keyboard: RefocusWindow(id: 3, pid: 42, space: 20, display: "right"), input: input))
        #expect(!repair.allows(keyboard: RefocusWindow(id: 0, pid: 0, space: 0, display: nil), input: input))
    }

    @Test(arguments: 0..<8)
    func laterInputSupersedesTheRepair(event: Int) {
        let input = RefocusInput(counts: Array(1...8))
        var changed = input.counts
        changed[event] += 1
        let repair = FocusRepair(leaving: RefocusWindow(id: 9, pid: 42, space: 10, display: "left"), removed: true, input: input)
        #expect(!repair.allows(keyboard: RefocusWindow(id: 0, pid: 0, space: 0, display: nil), input: RefocusInput(counts: changed)))
        #expect(!repair.allows(keyboard: RefocusWindow(id: 3, pid: 42, space: 20, display: "right"), input: RefocusInput(counts: changed)))
    }

    @Test(arguments: [LayoutMode.tiles, .accordion])
    func removalAndStackingUseTheSameSuccessor(mode: LayoutMode) {
        var workspace = Workspace(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800), algorithm: .dwindle(mode))
        for id in [WindowID(1), 2, 3] { workspace.insert(id) }
        workspace.focus(2)
        workspace.remove(2)
        #expect(workspace.focused != nil)
        #expect(workspace.focused != 2)
        #expect(workspace.layout().frames[workspace.focused!] != nil)
        // The coordinator uses this same focus for close, minimize and move-away, rather than another history.
        let successor = workspace.focused
        workspace.focus(successor!)
        #expect(workspace.focused == successor)
    }
}

struct FocusDepartureTests {
    let input = RefocusInput(counts: [1, 2, 3, 4, 5])

    @Test func aLaterDepartureUsesItsNotificationInput() {
        let later = RefocusInput(counts: [4, 3, 4, 4, 5])
        // A tab/pane close or a save sheet did not remove the window. There is no command record to retain.
        #expect(FocusDeparture().hadFocus(3, focused: 3, input: later))
    }

    @Test func theFocusedWindowHadFocus() {
        #expect(FocusDeparture().hadFocus(3, focused: 3, input: input))
    }

    @Test func aLossToNoWindowRemainsOwnedWithoutATimeout() {
        var loss = FocusDeparture()
        loss.changed(from: 3, to: 0, input: input)
        #expect(loss.hadFocus(3, focused: 0, input: input))
    }

    @Test func aWindowTheUserHadLeftDidNotHaveFocus() {
        var loss = FocusDeparture()
        loss.changed(from: 3, to: 5, input: input)
        #expect(!loss.hadFocus(3, focused: 5, input: input))
    }

    @Test func aDepartureCanRedirectBeforeTheCloseNotification() {
        var loss = FocusDeparture()
        loss.changed(from: 3, to: 5, input: input, departed: true)
        #expect(loss.hadFocus(3, focused: 5, input: input))
        #expect(!loss.hadFocus(3, focused: 5, input: RefocusInput(counts: [2, 2, 3, 4, 5])))
    }

    @Test func explicitFocusCancelsEvenBeforeTheCloseAndFocusEventsArrive() {
        var loss = FocusDeparture()
        loss.cancel(focused: 3, input: input)
        #expect(!loss.hadFocus(3, focused: 3, input: input))
        loss.changed(from: 3, to: 5, input: input, departed: true)
        #expect(!loss.hadFocus(3, focused: 5, input: input))
    }

    @Test func focusingTheSameWindowDoesNotSuppressItsNextCloseCommand() {
        var loss = FocusDeparture()
        loss.cancel(focused: 3, input: input)
        let close = RefocusInput(counts: [2, 2, 3, 4, 5])
        #expect(loss.hadFocus(3, focused: 3, input: close))
    }

    @Test func anotherWindowEndsOwnershipEvenIfItAlsoLosesFocus() {
        var loss = FocusDeparture()
        loss.changed(from: 3, to: 0, input: input)
        loss.changed(from: 0, to: 5, input: input)
        loss.changed(from: 5, to: 0, input: input)
        #expect(!loss.hadFocus(3, focused: 0, input: input))
        #expect(loss.hadFocus(5, focused: 0, input: input))
    }

    @Test func inputEndsOwnershipEvenWhenItLeavesNoKeyWindow() {
        var loss = FocusDeparture()
        loss.changed(from: 3, to: 0, input: input)
        #expect(!loss.hadFocus(3, focused: 0, input: RefocusInput(counts: [2, 2, 3, 4, 5])))
    }

    @Test func reusedIDsDoNotInheritOwnership() {
        var loss = FocusDeparture()
        loss.changed(from: 3, to: 0, input: input)
        loss.forget(3)
        #expect(!loss.hadFocus(3, focused: 0, input: input))
    }

    @Test func noWindowDoesNotReplaceTheOwner() {
        var loss = FocusDeparture()
        loss.changed(from: 3, to: 0, input: input)
        loss.changed(from: 0, to: 0, input: input)
        #expect(loss.hadFocus(3, focused: 0, input: input))
    }
}
