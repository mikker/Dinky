import Foundation
import Testing
@testable import DinkyLayout

struct FrameWritesTests {
    @Test func pauseRejectsNewWritesAndInvalidatesQueuedRaises() throws {
        let writes = FrameWrites()
        let queuedRaise = try #require(writes.permit)
        writes.transition(to: .overview)
        #expect(writes.permit == nil)
        #expect(!writes.allows(queuedRaise))
        writes.transition(to: .layout)
        #expect(!writes.allows(queuedRaise), "a raise waiting on a hung app must not revive on exit")
        #expect(writes.allows(try #require(writes.permit)))
    }

    @Test func disablingDuringOverviewAllowsRestorationWithoutRevivingLayoutPermits() throws {
        let writes = FrameWrites()
        let old = try #require(writes.permit)
        writes.transition(to: .overview)
        writes.transition(to: .restoration)
        #expect(!writes.allows(old))
        let restoration = try #require(writes.permit)
        #expect(writes.allows(restoration))
        #expect(!writes.transition(to: .restoration), "overview exit while disabled must not cancel restoration")
        writes.transition(to: .overview)
        #expect(writes.permit == nil, "re-enabling in overview must not admit automatic writes")
        #expect(!writes.allows(restoration))
    }

    @Test func aFrameWriteInterruptedBetweenAttributesStopsTheRemainingCalls() throws {
        let writes = FrameWrites()
        let permit = try #require(writes.permit)
        var attributes: [String] = []
        for attribute in ["size", "position", "size"] {
            guard writes.allows(permit) else { break }
            attributes.append(attribute)
            // Entry while the first system call is executing, then exit before it returns.
            writes.transition(to: .overview)
            writes.transition(to: .layout)
        }
        #expect(attributes == ["size"])
    }

    @Test func staleCompletionsCannotReconcileAnOldLayoutAfterOverviewExit() throws {
        let writes = FrameWrites()
        let completion = try #require(writes.permit)
        writes.transition(to: .overview)
        writes.transition(to: .layout)
        let finalLayout = try #require(writes.permit)
        #expect(!writes.allows(completion))
        #expect(writes.allows(finalLayout))
        writes.transition(to: .overview)
        writes.transition(to: .layout)
        #expect(!writes.allows(finalLayout))
    }
}
