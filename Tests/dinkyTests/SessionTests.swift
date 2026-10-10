import Foundation
import Testing
@testable import DinkyLayout
@testable import dinky

struct SessionTests {
    private let launched = Date(timeIntervalSince1970: 10)
    private let visible = CGRect(x: 0, y: 38, width: 3440, height: 1402)

    private func window(_ id: UInt32, space: UInt64 = 815, seen: Double = 20, pid: Int32 = 10) -> Window {
        var window = Window(identity: .init(id: id, pid: pid, firstSeen: Date(timeIntervalSince1970: seen)),
                            appName: "Test", bundleID: "test.app")
        window.spaceID = space
        window.frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        window.isDocument = true
        window.isOrderedIn = true
        window.isVisible = true
        return window
    }

    private func display(current: UInt64 = 815) -> RecoveryDisplay {
        .init(uuid: "main", visibleFrame: visible, userSpaces: [3, 815, 816], currentSpace: current)
    }

    private func workspace() -> Workspace {
        var workspace = Workspace(bounds: visible)
        workspace.insert(2)
        workspace.insert(1)
        workspace.focus(1)
        workspace.resize(by: 150, along: .horizontal)
        return workspace
    }

    private func journal(floating: Bool = false, override: Bool? = nil) -> Session.Journal {
        let entry = Session.Entry(id: 1, pid: 10, bundleID: "test.app", firstSeen: Date(timeIntervalSince1970: 20),
                                  appLaunched: launched, spaceID: 815,
                                  frame: CGRect(x: 150, y: 120, width: 900, height: 650),
                                  displayVisibleFrame: visible, floating: floating, floatingOverride: override)
        var second = window(2)
        second.frame = CGRect(x: 1100, y: 120, width: 900, height: 650)
        let other = Session.Entry(id: 2, pid: second.pid, bundleID: second.bundleID, firstSeen: second.identity.firstSeen,
                                  appLaunched: launched, spaceID: 815, frame: second.frame,
                                  displayVisibleFrame: visible, floating: false, floatingOverride: nil)
        return .init(windows: floating ? [entry] : [entry, other],
                     spaces: floating ? [] : [.init(id: 815, layout: WorkspaceSnapshot(workspace()))])
    }

    private func prepare(_ session: Session, _ journal: Session.Journal, windows: [UInt32: Window]) {
        session.prepare(journal, windows: windows, spaces: [3, 815, 816], launchDate: { _ in launched })
    }

    @Test func `A restart restores the saved order and splits before the first layout`() {
        let session = Session(), saved = journal()
        let windows = [UInt32(1): window(1, seen: 50), 2: window(2, seen: 50)]
        prepare(session, saved, windows: windows)
        var current = workspace()
        current.flatten()
        let placements = windows.mapValues { _ in Placement(floating: false, space: 815) }
        #expect(session.restore(815, workspace: &current, windows: windows, placements: placements, held: []) == .restored)
        #expect(current.root == saved.spaces[0].layout.root)
        #expect(current.windows == [2, 1])
        #expect(session.pendingSpaces.isEmpty)
        #expect(session.restore(815, workspace: &current, windows: windows, placements: placements, held: []) == .none)
    }

    @Test func `Classification and native tab holds delay the first saved layout`() {
        let session = Session(), windows = [UInt32(1): window(1), 2: window(2)]
        prepare(session, journal(), windows: windows)
        var current = workspace()
        let before = current
        let first = [UInt32(1): Placement(floating: false, space: 815)]
        #expect(session.restore(815, workspace: &current, windows: windows, placements: first, held: []) == .waiting)
        #expect(current == before)
        let both = windows.mapValues { _ in Placement(floating: false, space: 815) }
        #expect(session.restore(815, workspace: &current, windows: windows, placements: both, held: [2]) == .waiting)
        #expect(session.restore(815, workspace: &current, windows: windows, placements: both, held: []) == .restored)
    }

    @Test func `Windows moved while dinky was off keep their new native Spaces`() {
        let session = Session(), windows = [UInt32(1): window(1, space: 816), 2: window(2)]
        prepare(session, journal(), windows: windows)
        #expect(session.pendingWindows[1] == nil)
        var current = Workspace(bounds: visible)
        current.insert(2)
        let placements = [UInt32(1): Placement(floating: false, space: 816), 2: Placement(floating: false, space: 815)]
        #expect(session.restore(815, workspace: &current, windows: windows, placements: placements, held: []) == .restored)
        #expect(current.windows == [2])
        #expect(session.pendingWindows[2]?.spaceID == 815)
        #expect(session.floatingJobs(windows: windows, placements: placements, displays: [display()]).isEmpty)
    }

    @Test func `A different process or app launch cannot inherit the saved layout`() {
        let saved = journal()
        for changedPID in [false, true] {
            let session = Session()
            let windows = [UInt32(1): window(1, pid: changedPID ? 99 : 10), 2: window(2, pid: changedPID ? 99 : 10)]
            session.prepare(saved, windows: windows, spaces: [815], launchDate: { _ in
                changedPID ? launched : Date(timeIntervalSince1970: 30)
            })
            #expect(session.pendingWindows.isEmpty)
            #expect(session.pendingSpaces.isEmpty)
        }
    }

    @Test func `A reused runtime identity or a subsequent Space move is dropped`() {
        let session = Session()
        prepare(session, journal(floating: true, override: true), windows: [1: window(1)])
        let replacement = window(1, seen: 60)
        #expect(session.floatingOverride(for: replacement) == nil)
        #expect(session.floatingJobs(windows: [1: replacement], placements: [1: .init(floating: true, space: nil)],
                                     displays: [display()]).isEmpty)
        #expect(session.pendingWindows.isEmpty)
        prepare(session, journal(floating: true, override: true), windows: [1: window(1)])
        let moved = window(1, space: 816)
        #expect(session.floatingOverride(for: moved) == nil)
        #expect(session.floatingJobs(windows: [1: moved], placements: [1: .init(floating: true, space: nil)],
                                     displays: [display(current: 816)]).isEmpty)
        #expect(session.pendingWindows.isEmpty)
    }

    @Test func `Closed leaves and new windows use the saved tree without retaining stale leaves`() {
        let session = Session(), windows = [UInt32(1): window(1), 3: window(3, seen: 60)]
        prepare(session, journal(), windows: windows)
        var current = Workspace(bounds: visible)
        current.insert(1)
        current.insert(3)
        let placements = windows.mapValues { _ in Placement(floating: false, space: 815) }
        #expect(session.restore(815, workspace: &current, windows: windows, placements: placements, held: []) == .restored)
        #expect(Set(current.windows) == [1, 3])
    }

    @Test func `Pending inactive layouts are saved intact until their first visit`() {
        let session = Session(), saved = journal(), windows = [UInt32(1): window(1), 2: window(2)]
        prepare(session, saved, windows: windows)
        let next = session.snapshot(workspaces: [:], windows: windows, placements: [:],
                                    displays: [display(current: 3)], launchDate: { _ in launched })
        #expect(next.spaces == saved.spaces)
        #expect(next.windows.map(\.frame) == saved.windows.map(\.frame))
        #expect(session.floatingJobs(windows: windows, placements: [:], displays: [display(current: 3)]).isEmpty)
    }

    @Test func `Floating windows restore once on their current Space without raising or switching`() {
        let session = Session(), saved = journal(floating: true, override: true), windows = [UInt32(1): window(1)]
        prepare(session, saved, windows: windows)
        let placements = [UInt32(1): Placement(floating: true, space: nil, floatingOverride: true)]
        #expect(session.floatingOverride(for: windows[1]!) == true)
        #expect(session.floatingJobs(windows: windows, placements: placements, displays: [display(current: 3)]).isEmpty)
        let jobs = session.floatingJobs(windows: windows, placements: placements, displays: [display()])
        #expect(jobs.count == 1)
        #expect(jobs.first?.frame == saved.windows[0].frame)
        #expect(session.floatingJobs(windows: windows, placements: placements, displays: [display()]).isEmpty)
    }

    @Test func `Hidden and minimized floating windows wait for show events`() {
        let session = Session(), saved = journal(floating: true)
        for minimized in [false, true] {
            var hidden = window(1)
            hidden.isMinimized = minimized
            hidden.isOrderedIn = minimized
            prepare(session, saved, windows: [1: hidden])
            let placements = [UInt32(1): Placement(floating: true, space: nil)]
            #expect(session.floatingJobs(windows: [1: hidden], placements: placements, displays: [display()]).isEmpty)
            #expect(session.pendingWindows.count == 1)
            #expect(session.floatingJobs(windows: [1: window(1)], placements: placements, displays: [display()]).count == 1)
        }
    }

    @Test func `Current tiling classification overrides a saved floating frame`() {
        let session = Session(), windows = [UInt32(1): window(1)]
        prepare(session, journal(floating: true, override: true), windows: windows)
        #expect(session.floatingJobs(windows: windows, placements: [1: .init(floating: false, space: 815)],
                                     displays: [display()]).isEmpty)
        #expect(session.pendingWindows.isEmpty)
    }

    @Test func `Floating frames adapt to the monitor that currently owns the native Space`() {
        let session = Session(), saved = journal(floating: true), windows = [UInt32(1): window(1)]
        prepare(session, saved, windows: windows)
        let other = RecoveryDisplay(uuid: "other", visibleFrame: CGRect(x: -1600, y: -900, width: 1600, height: 900),
                                    userSpaces: [815], currentSpace: 815)
        let jobs = session.floatingJobs(windows: windows, placements: [1: .init(floating: true, space: nil)], displays: [other])
        #expect(jobs.first?.frame == recoveryFrame(saved.windows[0].frame!, from: visible, on: other.visibleFrame))
        #expect(jobs.first.map { other.visibleFrame.contains($0.frame) } == true)
    }

    @Test func `Saving prunes closed entries and Space snapshots`() {
        let session = Session()
        prepare(session, journal(), windows: [1: window(1), 2: window(2)])
        let empty = session.snapshot(workspaces: [:], windows: [:], placements: [:],
                                     displays: [display()], launchDate: { _ in launched })
        #expect(empty.windows.isEmpty)
        #expect(empty.spaces.isEmpty)
    }

    @Test func `Closed pending windows and their layouts release runtime memory`() {
        let session = Session()
        prepare(session, journal(), windows: [1: window(1), 2: window(2)])
        session.prune(windows: [:], spaces: [815])
        #expect(session.pendingWindows.isEmpty)
        #expect(session.pendingSpaces.isEmpty)
    }

    @Test func `Tiling animation frame changes do not change the saved session`() {
        let session = Session(), tree = workspace(), placements = [UInt32(1): Placement(floating: false, space: 815),
                                                                  2: Placement(floating: false, space: 815)]
        var windows = [UInt32(1): window(1), 2: window(2)]
        let first = session.snapshot(workspaces: [815: tree], windows: windows, placements: placements,
                                     displays: [display()], launchDate: { _ in launched })
        windows[1]!.frame = CGRect(x: 900, y: 200, width: 1200, height: 900)
        let animation = session.snapshot(workspaces: [815: tree], windows: windows, placements: placements,
                                         displays: [display()], launchDate: { _ in launched })
        #expect(first == animation)
        #expect(first.windows.allSatisfy { $0.frame == nil && $0.displayVisibleFrame == nil })
    }

    @Test func `Manual floating choices and their latest frames are saved`() {
        let session = Session(), first = window(1), placement = Placement(floating: true, space: nil, floatingOverride: true)
        let saved = session.snapshot(workspaces: [:], windows: [1: first], placements: [1: placement],
                                     displays: [display()], launchDate: { _ in launched })
        #expect(saved.windows.first?.floatingOverride == true)
        #expect(saved.windows.first?.frame == first.frame)
        var moved = first
        moved.frame = CGRect(x: 300, y: 400, width: 900, height: 700)
        moved.spaceID = 816
        let changed = session.snapshot(workspaces: [:], windows: [1: moved], placements: [1: placement],
                                       displays: [display(current: 816)], launchDate: { _ in launched })
        #expect(changed.windows.first?.frame == moved.frame)
        #expect(changed.windows.first?.spaceID == 816)
        #expect(changed != saved)
    }

    @Test func `Untiled workspaces retain their floating frames without a floating classification`() {
        let session = Session(), windows = [UInt32(1): window(1)], placements = [UInt32(1): Placement(floating: false, space: nil)]
        let saved = session.snapshot(workspaces: [:], windows: windows, placements: placements,
                                     displays: [display()], untiledSpaces: [815], launchDate: { _ in launched })
        #expect(saved.windows.first?.floating == true)
        #expect(saved.windows.first?.frame == windows[1]?.frame)
        prepare(session, journal(floating: true), windows: windows)
        #expect(session.floatingJobs(windows: windows, placements: placements, displays: [display()], untiledSpaces: [815]).count == 1)
    }

    @Test func `Quitting before a floating write finishes preserves its intended frame`() {
        let session = Session(), windows = [UInt32(1): window(1)], saved = journal(floating: true, override: true)
        let placements = [UInt32(1): Placement(floating: true, space: nil, floatingOverride: true)]
        prepare(session, saved, windows: windows)
        let jobs = session.floatingJobs(windows: windows, placements: placements, displays: [display()])
        let duringWrite = session.snapshot(workspaces: [:], windows: windows, placements: placements,
                                           displays: [display()], launchDate: { _ in launched })
        #expect(duringWrite.windows[0].frame == saved.windows[0].frame)
        #expect(duringWrite.windows[0].frame != windows[1]?.frame)
        #expect(session.floatingJobs(windows: windows, placements: placements, displays: [display()]).isEmpty)
        session.finished(jobs, results: jobs.map { FrameResult(job: $0, target: $0.frame, got: $0.frame) })
        var landed = windows
        landed[1]!.frame = jobs[0].frame
        let afterWrite = session.snapshot(workspaces: [:], windows: landed, placements: placements,
                                          displays: [display()], launchDate: { _ in launched })
        #expect(afterWrite.windows[0].frame == jobs[0].frame)
    }

    @Test func `Launch dates tolerate JSON rounding without accepting another launch`() {
        let session = Session(), windows = [UInt32(1): window(1), 2: window(2)]
        session.prepare(journal(), windows: windows, spaces: [815], launchDate: { _ in launched.addingTimeInterval(0.0000001) })
        #expect(session.pendingWindows.count == 2)
        session.prepare(journal(), windows: windows, spaces: [815], launchDate: { _ in launched.addingTimeInterval(1) })
        #expect(session.pendingWindows.isEmpty)
    }

    @Test func `New members are inserted after every saved member survives`() {
        let session = Session(), windows = [UInt32(1): window(1), 2: window(2), 3: window(3, seen: 60)]
        prepare(session, journal(), windows: windows)
        var current = workspace()
        current.insert(3)
        let placements = windows.mapValues { _ in Placement(floating: false, space: 815) }
        #expect(session.restore(815, workspace: &current, windows: windows, placements: placements, held: []) == .restored)
        #expect(Set(current.windows) == [1, 2, 3])
    }

    @Test func `Duplicate entries missing Spaces and unsupported versions do not restore`() {
        let session = Session(), saved = journal(), windows = [UInt32(1): window(1), 2: window(2)]
        let duplicate = Session.Journal(windows: saved.windows + [saved.windows[0]], spaces: saved.spaces)
        prepare(session, duplicate, windows: windows)
        #expect(session.pendingWindows.isEmpty)
        var future = saved
        future.version = 2
        prepare(session, future, windows: windows)
        #expect(session.pendingWindows.isEmpty)
        session.prepare(saved, windows: windows, spaces: [3], launchDate: { _ in launched })
        #expect(session.pendingWindows.isEmpty)
        #expect(session.pendingSpaces.isEmpty)
    }

    @Test func `Identical state does not rewrite the journal and saved JSON round trips`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json"), session = Session(url: url), saved = journal()
        #expect(session.save(saved))
        let first = try Data(contentsOf: url)
        #expect(!session.save(saved))
        #expect(try Data(contentsOf: url) == first)
        #expect(session.load() == saved)
        let empty = Session.Journal(windows: [], spaces: [])
        #expect(session.save(empty))
        #expect(session.load() == empty)
    }

    @Test @MainActor func `Event bursts coalesce and pausing blocks late saves of untiled frames`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = Session(url: directory.appendingPathComponent("session.json"))
        var current = journal()
        var reads = 0
        session.startSaving { reads += 1; return current }
        for _ in 0..<1000 { session.saveSoon() }
        try await Task.sleep(for: .milliseconds(650))
        #expect(reads == 1)
        #expect(session.load() == current)
        session.saveSoon()
        session.pause()
        let beforeUntiling = current
        current = Session.Journal(windows: [], spaces: [])
        for _ in 0..<1000 { session.saveSoon() }
        try await Task.sleep(for: .milliseconds(650))
        #expect(reads == 2)
        #expect(session.load() == beforeUntiling)
        session.resume()
        try await Task.sleep(for: .milliseconds(650))
        #expect(reads == 3)
        #expect(session.load() == current)
    }

    @Test func `An immediate quit saves the latest edits before the debounce runs`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = Session(url: directory.appendingPathComponent("session.json"))
        let current = journal()
        session.startSaving { current }
        session.saveSoon()
        session.pause()
        #expect(session.load() == current)
    }

    @Test func `Corrupt session files are ignored without touching the recovery journal`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json"), recovery = directory.appendingPathComponent("journal.json")
        try Data("not JSON".utf8).write(to: url)
        let original = Data("recovery state".utf8)
        try original.write(to: recovery)
        #expect(Session(url: url).load() == nil)
        #expect(try Data(contentsOf: recovery) == original)
    }
}
