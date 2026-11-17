import Foundation
import Testing
import DinkyCommands
import DinkyConfig
import DinkyLayout
@testable import dinky

struct BorderRuleIntegrationTests {
    private let auxiliary = Window(identity: .init(id: 900_078, pid: -1, firstSeen: .distantPast),
                                   appName: "Editor", bundleID: "com.example.editor", isDocument: true)
    private let document = Window(identity: .init(id: 900_079, pid: -1, firstSeen: .distantPast),
                                  appName: "Editor", bundleID: "com.example.editor", isDocument: true)
    private let borderConfig = """
    [[borders.rules]]
    app-id = 'com.example.editor'
    window-identifier = '^Settings$'
    enabled = false
    """

    private func coordinator(config: Config, facts: WindowFactsCache, windows: [Window] = []) -> Coordinator {
        Coordinator(displays: DisplayModel(), config: config,
                    applier: FrameApplier(supportURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("dinky-borders-\(UUID())")),
                    windowFacts: facts, model: WindowModel(windows: windows))
    }

    @Test(arguments: [true, false])
    func borderOnlyReloadRefreshesExistingWindowsWithoutLayoutOrCommands(_ floating: Bool) throws {
        let placementRules = """
        [[rules]]
        run = ['layout floating', 'exec-and-forget echo must-not-replay', 'move-window-to-workspace 4']
        """
        var reads: [UInt32] = []
        let facts = WindowFactsCache(read: { window in
            reads.append(window.id)
            return WindowFacts(title: "Untitled", kind: .normal,
                               identifier: window.id == auxiliary.id ? "Settings" : "Document")
        }, schedule: { _, _ in Issue.record("Complete facts must not retry") })
        var previous = try Config.parse(placementRules)
        previous.borders.enabled = false // No live border windows in this synthetic test.
        let owner = coordinator(config: previous, facts: facts, windows: [auxiliary, document])
        owner.placements[auxiliary.id] = Placement(floating: floating, space: nil)
        owner.placements[document.id] = Placement(floating: !floating, space: nil)
        owner.enqueueWindowRule = { _, _ in Issue.record("Decoration must not enqueue a placement command") }
        // flush would consume this pending work, even without displays. Border-only reload must not flush it.
        owner.layouts.dirty.insert(78)
        let changed = try Config.parse("[borders]\nenabled = false\n\(borderConfig)\n\(placementRules)")
        #expect(!owner.update(config: changed)) // AppState must also skip WorkspaceNumbers.arrange/reconcile.
        #expect(Set(reads) == [auxiliary.id, document.id])
        #expect(owner.layouts.dirty == [78])
        #expect(owner.placements[auxiliary.id]?.floating == floating)
        #expect(owner.placements[document.id]?.floating == !floating)
        #expect(owner.settlements.isEmpty)
        #expect(owner.workspaces.isEmpty)
        var enabledBorders = changed.borders
        enabledBorders.enabled = true
        #expect(!facts.decorates(auxiliary, config: enabledBorders))
        #expect(facts.decorates(document, config: enabledBorders))
        #expect(owner.windowFacts.facts(for: auxiliary)?.identifier == "Settings")
        // Removing the exclusion takes effect on the same windows too.
        #expect(!owner.update(config: previous))
        #expect(facts.decorates(auxiliary, config: Borders()))
        #expect(owner.layouts.dirty == [78])
    }

    @Test func unchangedReloadStillFlushesLayoutAndRequestsSpaceArrangement() {
        var config = Config()
        config.borders.enabled = false
        let facts = WindowFactsCache(read: { _ in Issue.record("No decoration selectors need AX"); return nil })
        let owner = coordinator(config: config, facts: facts)
        owner.layouts.dirty.insert(78)
        #expect(owner.update(config: config)) // AppState must retry WorkspaceNumbers.arrange.
        #expect(owner.layouts.dirty.isEmpty) // The normal layout flush consumed pending work.
    }

    @Test func classificationPopulatesSharedDecorationSnapshot() throws {
        let facts = WindowFactsCache(read: { _ in Issue.record("Drawing must not query AX"); return nil })
        let owner = coordinator(config: try Config.parse(borderConfig), facts: facts)
        _ = owner.classify(auxiliary, kind: .normal, resizable: true, title: "Untitled",
                           identifier: "Settings", lacksFullscreen: false) { _, _ in }
        #expect(!facts.decorates(auxiliary, config: owner.config.borders))
        #expect(owner.windowFacts.facts(for: auxiliary)?.identifier == "Settings")
        owner.forget(auxiliary.id)
        #expect(facts.facts(for: auxiliary) == nil)
        #expect(owner.windowFacts.facts(for: auxiliary) == nil)
    }

    @Test func missingAXThenLateIdentifierSettlesWithoutPlacement() throws {
        var pending: [() -> Void] = []
        var snapshots: [WindowFacts?] = [nil,
            WindowFacts(title: "", kind: nil, identifier: nil),
            WindowFacts(title: "Untitled", kind: .normal, identifier: "Settings")]
        let facts = WindowFactsCache(read: { _ in snapshots.removeFirst() }, schedule: { _, work in pending.append(work) })
        let owner = coordinator(config: try Config.parse(borderConfig), facts: facts)
        owner.placements[auxiliary.id] = Placement(floating: true, space: nil)
        owner.enqueueWindowRule = { _, _ in Issue.record("Fact settling must not replay commands") }
        facts.refresh(auxiliary)
        #expect(facts.decorates(auxiliary, config: owner.config.borders))
        #expect(pending.count == 1)
        pending.removeFirst()()
        #expect(pending.count == 1)
        pending.removeFirst()()
        #expect(pending.isEmpty)
        #expect(!facts.decorates(auxiliary, config: owner.config.borders))
        #expect(owner.placements[auxiliary.id]?.floating == true)
        #expect(owner.layouts.dirty.isEmpty)
    }

    @Test func unsupportedIdentifiersHaveBoundedRetriesAndNoDrawReads() throws {
        var pending: [() -> Void] = []
        var reads = 0
        let facts = WindowFactsCache(read: { _ in
            reads += 1
            return WindowFacts(title: "Untitled", kind: .normal, identifier: nil)
        }, schedule: { _, work in pending.append(work) })
        facts.refresh(auxiliary)
        facts.refresh(auxiliary) // Events share one retry chain.
        #expect(pending.count == 1)
        for _ in 0..<5 { pending.removeFirst()() }
        #expect(pending.isEmpty)
        #expect(reads == 7)
        let borders = try Config.parse(borderConfig).borders
        for _ in 0..<100 { #expect(facts.decorates(auxiliary, config: borders)) }
        #expect(reads == 7)
    }

    @Test func titleRefreshDoesNotReclassifyAndFailedReadsKeepLastSnapshot() throws {
        let borders = try Config.parse("[[borders.rules]]\ntitle = '^Settings$'\nenabled = false").borders
        var snapshot: WindowFacts? = WindowFacts(title: "Document", kind: .normal, identifier: "Window")
        let facts = WindowFactsCache(read: { _ in snapshot }, schedule: { _, _ in })
        facts.refresh(auxiliary)
        #expect(facts.decorates(auxiliary, config: borders))
        snapshot?.title = "Settings"
        facts.refresh(auxiliary)
        #expect(!facts.decorates(auxiliary, config: borders))
        snapshot = nil
        facts.refresh(auxiliary)
        #expect(!facts.decorates(auxiliary, config: borders))
    }

    @Test func forgetCancelsRetryAndReusedWindowIDsCannotReuseFacts() {
        var pending: [() -> Void] = []
        var reads = 0
        let facts = WindowFactsCache(read: { _ in reads += 1; return nil },
                                     schedule: { _, work in pending.append(work) })
        facts.record(auxiliary, facts: WindowFacts(title: "Old", kind: .normal, identifier: "Settings"))
        facts.refresh(auxiliary)
        facts.forget(auxiliary.id)
        pending.removeFirst()()
        #expect(reads == 1)
        let reused = Window(identity: .init(id: auxiliary.id, pid: -2, firstSeen: Date()),
                            appName: "Other", bundleID: "com.other.app")
        #expect(facts.facts(for: reused) == nil)
        facts.record(auxiliary, facts: WindowFacts(title: "Old", kind: .normal, identifier: "Settings"))
        #expect(facts.facts(for: reused) == nil)
        facts.refresh(reused)
        #expect(facts.facts(for: reused) == nil)
    }
}
