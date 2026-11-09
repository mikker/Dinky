import Foundation
import Testing
import DinkyConfig
@testable import dinky

struct ClassificationSettlementTests {
    private func coordinator() -> Coordinator {
        Coordinator(displays: DisplayModel(), config: Config(),
                    applier: FrameApplier(supportURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("dinky-settlement-\(UUID())")))
    }

    @Test func eventBurstCannotConsumeTheSettlingInterval() {
        let owner = coordinator()
        for index in 0..<1000 {
            #expect(owner.awaitClassification(67, unsettled: true, now: 100 + Double(index) / 1000))
        }
        #expect(owner.settlements[67]?.deadline == 101)
        #expect(!owner.awaitClassification(67, unsettled: true, now: 101))
        #expect(owner.settlements.isEmpty)
    }

    @Test func readyWindowDoesNotWaitAndCancelsAnyRetry() {
        let owner = coordinator()
        #expect(!owner.awaitClassification(67, unsettled: false, now: 100))
        #expect(owner.settlements.isEmpty)
        #expect(owner.awaitClassification(67, unsettled: true, now: 100))
        #expect(!owner.awaitClassification(67, unsettled: false, now: 100.2))
        #expect(owner.settlements.isEmpty)
    }

    @Test func missingAXAndResizeSettlingShareOneDeadline() {
        let owner = coordinator()
        // AX is missing at first; when it appears, resizing is still unavailable.
        #expect(owner.awaitClassification(67, unsettled: true, now: 100))
        let original = owner.settlements[67]
        #expect(owner.awaitClassification(67, unsettled: true, now: 100.8))
        #expect(owner.settlements[67] === original)
        #expect(!owner.awaitClassification(67, unsettled: true, now: 101.01))
    }

    @Test func forgettingWindowInvalidatesItsRetryAndReusedIDStartsFresh() {
        let owner = coordinator()
        #expect(owner.awaitClassification(67, unsettled: true, now: 100))
        let original = owner.settlements[67]
        owner.forget(67)
        #expect(owner.settlements.isEmpty)
        #expect(owner.awaitClassification(67, unsettled: true, now: 100.1))
        #expect(owner.settlements[67] !== original)
        #expect(owner.settlements[67]?.deadline == 101.1)
    }

    @Test func windowsHaveIndependentDeadlines() {
        let owner = coordinator()
        #expect(owner.awaitClassification(67, unsettled: true, now: 100))
        #expect(owner.awaitClassification(68, unsettled: true, now: 100.8))
        #expect(!owner.awaitClassification(67, unsettled: true, now: 101))
        #expect(owner.awaitClassification(68, unsettled: true, now: 101))
    }
}
