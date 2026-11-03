import Foundation
import Testing
@testable import dinky

struct FrameApplierLifecycleTests {
    /// Construct the production writer, but never look up an AX element, submit a PID, or touch user storage.
    @Test func disableOrQuitInOverviewAdmitsRestorationButNotStaleLayoutWork() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let applier = FrameApplier(supportURL: support)
        let oldLayout = try #require(applier.permit)
        applier.updateLayoutState(enabled: true, overview: true)
        #expect(applier.permit == nil)
        applier.updateLayoutState(enabled: false, overview: true)
        let restoration = try #require(applier.permit)
        #expect(applier.allows(restoration))
        #expect(!applier.allows(oldLayout), "queued layout/animation/raise work must not revive")
        applier.updateLayoutState(enabled: false, overview: false)
        #expect(applier.allows(restoration), "native exit must not interrupt explicit restoration")
        applier.updateLayoutState(enabled: false, overview: true)
        #expect(applier.allows(restoration), "disabled overview entry is not layout suspension")
        applier.updateLayoutState(enabled: true, overview: true)
        #expect(applier.permit == nil)
        #expect(!applier.allows(restoration))
        applier.updateLayoutState(enabled: true, overview: false)
        #expect(applier.allows(try #require(applier.permit)))
        #expect(!applier.allows(oldLayout))
        #expect(!applier.allows(restoration))
    }

    @Test func repeatedEnabledStatePropagationDoesNotCancelCurrentLayout() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let applier = FrameApplier(supportURL: support)
        let current = try #require(applier.permit)
        applier.updateLayoutState(enabled: true, overview: false)
        #expect(applier.allows(current))
    }
}
