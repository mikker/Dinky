import AppKit
import DinkyConfig
import DinkyLayout
import Testing
@testable import dinky

/// Established placements only: no model subscriptions, AX reads or live frame writes.
struct WindowTrackingTests {
    enum Departure: CaseIterable {
        case orderedOut, invisible, nonDocument, raisedLevel, minimized

        func apply(to window: inout Window) {
            switch self {
            case .orderedOut: window.isOrderedIn = false
            case .invisible: window.isVisible = false
            case .nonDocument: window.isDocument = false
            case .raisedLevel: window.level = 3
            case .minimized:
                window.isMinimized = true
                window.isVisible = false
            }
        }
    }

    private let sibling: UInt32 = 900_081

    private func fixture(space: UInt64 = 10) -> (Coordinator, Window) {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let display = Display(uuid: "test", id: 0, frame: bounds, visibleArea: bounds,
                              isMain: true, spaces: [10, 20], userSpaces: [10, 20], currentSpaceID: 10)
        let displays = DisplayModel(readSnapshot: { [display] })
        displays.reconcile()
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("dinky-tracking-\(UUID())")
        var window = Window(identity: .init(id: 900_079, pid: -1, firstSeen: .distantPast),
                            appName: "Editor", bundleID: "com.example.editor", spaceID: space,
                            isOrderedIn: true, isDocument: true, isVisible: true)
        var workspace = Workspace(bounds: bounds)
        workspace.insert(window.id)
        workspace.insert(sibling)
        workspace.focus(window.id)
        window.frame = workspace.layout().frames[window.id]!
        let owner = Coordinator(displays: displays, config: Config(), applier: FrameApplier(supportURL: support),
                                model: WindowModel(windows: [window]))
        owner.workspaces[space] = workspace
        owner.placements[window.id] = Placement(floating: false, space: space)
        owner.placements[sibling] = Placement(floating: false, space: space)
        return (owner, window)
    }

    @Test(arguments: Departure.allCases)
    func departingWindowReleasesItsTile(_ departure: Departure) throws {
        let (owner, original) = fixture()
        let before = try #require(owner.workspaces[10]?.layout().frames[sibling])
        var window = original
        departure.apply(to: &window)
        owner.track(window)
        #expect(owner.placements[window.id]?.space == nil)
        #expect(owner.workspaces[10]?.windows == [sibling])
        #expect(owner.layouts.dirty.contains(10))
        let after = try #require(owner.workspaces[10]?.layout().frames[sibling])
        #expect(after.width > before.width)
    }

    @Test func normalWindowOnHiddenSpaceKeepsItsTile() {
        let (owner, window) = fixture(space: 20)
        owner.track(window)
        #expect(owner.placements[window.id]?.space == 20)
        #expect(owner.workspaces[20]?.windows == [window.id, sibling])
        #expect(owner.layouts.dirty.isEmpty)
    }

    @Test func returningWindowAcquiresATileAgain() {
        let (owner, original) = fixture()
        var window = original
        window.isOrderedIn = false
        owner.track(window)
        #expect(owner.workspaces[10]?.windows == [sibling])
        window.isOrderedIn = true
        owner.track(window)
        #expect(owner.placements[window.id]?.space == 10)
        #expect(Set(owner.workspaces[10]?.windows ?? []) == [window.id, sibling])
    }

    private func inactiveTab(_ window: Window) -> Window {
        var hidden = window
        hidden.spaceID = 0
        hidden.isVisible = false
        hidden.isOrderedIn = false
        hidden.isMinimized = true
        return hidden
    }

    @MainActor @Test(arguments: [true, false])
    func newTabKeepsTheLeftTile(oldTabHiddenFirst: Bool) throws {
        let (owner, original) = fixture()
        let right = try #require(owner.workspaces[10]?.layout().frames[sibling])
        let newcomer = Window(identity: .init(id: 900_080, pid: original.pid, firstSeen: Date()),
                              appName: original.appName, bundleID: original.bundleID, frame: original.frame,
                              spaceID: 10, isOrderedIn: true, isDocument: true, isVisible: true)
        owner.placements[newcomer.id] = Placement(floating: false, space: nil)
        let hidden = inactiveTab(original)

        for window in oldTabHiddenFirst ? [hidden, newcomer] : [newcomer, hidden] {
            owner.track(window)
            #expect(owner.workspaces[10]?.layout().frames[sibling] == right)
        }
        #expect(owner.workspaces[10]?.layout().frames[newcomer.id] == original.frame)
        #expect(owner.workspaces[10]?.focused == newcomer.id)
        #expect(owner.placements[original.id]?.space == nil)
        #expect(owner.placements[newcomer.id]?.space == 10)
        #expect(owner.heldTabs.isEmpty)
    }

    @MainActor @Test func hiddenTabWithoutAReplacementReleasesItsTile() async throws {
        let (owner, original) = fixture()
        owner.track(inactiveTab(original))
        let release = try #require(owner.departingTabs[original.id])
        await withCheckedContinuation { continuation in
            release.notify(queue: .main) { continuation.resume() }
        }
        #expect(owner.placements[original.id]?.space == nil)
        #expect(owner.workspaces[10]?.windows == [sibling])
    }

    @Test func aFloatingWindowNeverAcquiresATile() {
        let (owner, window) = fixture()
        owner.workspaces[10]?.remove(window.id)
        owner.placements[window.id] = Placement(floating: true, space: nil)
        owner.track(window)
        #expect(owner.workspaces[10]?.windows == [sibling])
        #expect(owner.placements[window.id]?.floating == true)
        #expect(owner.placements[window.id]?.space == nil)
    }
}
