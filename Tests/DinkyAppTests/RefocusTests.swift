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

    @Test func repairsOnlyMissingOrStaleKeyboardFocus() {
        let input = RefocusInput(counts: [1, 2, 3, 4, 5])
        #expect(input.allowsRepair(leaving: 9, keyboard: 0, input: input))
        #expect(input.allowsRepair(leaving: 9, keyboard: 9, input: input))
        #expect(!input.allowsRepair(leaving: 9, keyboard: 3, input: input))
        #expect(!input.allowsRepair(leaving: 9, keyboard: nil, input: input))
    }

    @Test(arguments: 0..<5)
    func laterInputSupersedesTheRepair(event: Int) {
        let input = RefocusInput(counts: [1, 2, 3, 4, 5])
        var changed = input.counts
        changed[event] += 1
        #expect(!input.allowsRepair(leaving: 9, keyboard: 0, input: RefocusInput(counts: changed)))
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

struct FocusLossTests {
    let input = RefocusInput(counts: [1, 2, 3, 4, 5])

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
