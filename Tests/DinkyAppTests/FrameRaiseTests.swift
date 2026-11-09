import Testing
@testable import dinky

struct FrameRaiseTests {
    @Test func aStaleLayoutCannotUndoNativeMinimization() {
        #expect(!FrameApplier.mayRaise(minimized: true))
    }

    @Test func anUnsupportedOrMissingMinimizedStateStillAllowsStacking() {
        #expect(FrameApplier.mayRaise(minimized: nil))
    }

    @Test func aKnownUnminimizedWindowCanStillBeStacked() {
        #expect(FrameApplier.mayRaise(minimized: false))
    }
}
