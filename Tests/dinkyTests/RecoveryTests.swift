import Foundation
import Testing
@testable import DinkyLayout
@testable import dinky

struct RecoveryTests {
    private let visible = CGRect(x: 0, y: 38, width: 1710, height: 1074)
    private let original = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let tiled = CGRect(x: 8, y: 46, width: 1694, height: 1058)

    private func window(_ id: UInt32, space: UInt64 = 815, seen: Double = 1) -> Window {
        var window = Window(identity: .init(id: id, pid: 10, firstSeen: Date(timeIntervalSince1970: seen)),
                            appName: "Test", bundleID: "test.app")
        window.frame = original
        window.spaceID = space
        window.isDocument = true
        window.isOrderedIn = true
        window.isVisible = true
        return window
    }

    private func display(current: UInt64 = 815) -> RecoveryDisplay {
        .init(uuid: "main", visibleFrame: visible, userSpaces: [3, 814, 815, 816], currentSpace: current)
    }

    private func state(space: UInt64 = 815, frame: CGRect? = nil, shown: Bool = true, pid: Int32 = 10) -> RecoveryWindowState {
        .init(pid: pid, space: space, frame: frame ?? tiled, isOnScreen: shown)
    }

    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recovery: Recovery
        var url: URL { directory.appendingPathComponent("journal.json") }
        init() {
            recovery = Recovery(url: directory.appendingPathComponent("journal.json"))
            recovery.resume()
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func journal() throws -> Recovery.Journal {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(Recovery.Journal.self, from: Data(contentsOf: url))
        }
    }

    @Test func `A window already on its original Space restores its frame`() {
        let f = Fixture(), window = window(1)
        f.recovery.capture(window, display: display())
        var current = state()
        var requested: [FrameJob] = []
        f.recovery.restore(windows: [1: window], displays: [display()], read: { _ in current }, write: { jobs in
            requested = jobs
            current = state(frame: jobs[0].frame)
            return jobs.map { FrameResult(job: $0, target: $0.frame, got: $0.frame) }
        })
        #expect(requested.count == 1)
        #expect(requested.first?.frame == original)
        #expect(current.space == 815)
        #expect(f.recovery.recoverable == 0)
        #expect(!FileManager.default.fileExists(atPath: f.url.path))
    }

    @Test func `Inactive Spaces stay untouched and can be restored by a later explicit attempt`() throws {
        let f = Fixture(), window = window(1, space: 816)
        f.recovery.capture(window, display: display())
        var current = state(space: 816)
        var calls = 0
        f.recovery.restore(windows: [1: window], displays: [display()], read: { _ in current }, write: { jobs in
            calls += jobs.count
            return []
        })
        #expect(calls == 0)
        #expect(try f.journal().windows.map(\.id) == [1])
        #expect(f.recovery.recoverable == 1)
        f.recovery.restore(windows: [1: window], displays: [display(current: 816)], read: { _ in current }, write: { jobs in
            calls += jobs.count
            current = state(space: 816, frame: jobs[0].frame)
            return jobs.map { FrameResult(job: $0, target: $0.frame, got: $0.frame) }
        })
        #expect(calls == 1)
        #expect(current.space == 816)
        #expect(f.recovery.recoverable == 0)
    }

    @Test func `Hidden minimized and fullscreen windows remain pending`() throws {
        let f = Fixture()
        let windows = Dictionary(uniqueKeysWithValues: (UInt32(1)...3).map { ($0, window($0)) })
        for window in windows.values { f.recovery.capture(window, display: display()) }
        let states: [UInt32: RecoveryWindowState] = [1: state(shown: false), 2: state(shown: false), 3: state(space: 999)]
        var requested: [FrameJob] = []
        f.recovery.restore(windows: windows, displays: [display()], read: { states[$0] }, write: { requested = $0; return [] })
        #expect(requested.isEmpty)
        #expect(try f.journal().windows.count == 3)
    }

    @Test func `Only successful frames are removed after partial restoration`() throws {
        let f = Fixture(), one = window(1), two = window(2)
        f.recovery.capture(one, display: display())
        f.recovery.capture(two, display: display())
        var states = [UInt32(1): state(), 2: state()]
        f.recovery.restore(windows: [1: one, 2: two], displays: [display()], read: { states[$0] }, write: { jobs in
            let job = jobs.first { $0.id == 1 }!
            states[1] = state(frame: job.frame)
            return [FrameResult(job: job, target: job.frame, got: job.frame)]
        })
        #expect(try f.journal().windows.map(\.id) == [2])
        #expect(f.recovery.recoverable == 1)
        f.recovery.resume()
        #expect(f.recovery.recoverable == 1)
    }

    @Test func `Closed windows and reused identities are discarded without frame writes`() {
        let f = Fixture(), old = window(1), closed = window(2), new = window(1, seen: 2)
        f.recovery.capture(old, display: display())
        f.recovery.capture(closed, display: display())
        var writes = 0
        f.recovery.restore(windows: [1: new], displays: [display()], read: { _ in state() }, write: { writes += $0.count; return [] })
        #expect(writes == 0)
        #expect(f.recovery.recoverable == 0)
    }

    @Test func `A changed native owner is never restored`() {
        let f = Fixture(), window = window(1)
        f.recovery.capture(window, display: display())
        var writes = 0
        f.recovery.restore(windows: [1: window], displays: [display()], read: { _ in state(pid: 11) }, write: { writes += $0.count; return [] })
        #expect(writes == 0)
        #expect(f.recovery.recoverable == 0)
    }

    @Test(arguments: [true, false]) func `Space drift or a refused frame is retained even when the writer reports success`(spaceDrift: Bool) throws {
        let f = Fixture(), window = window(1)
        f.recovery.capture(window, display: display())
        var current = state()
        f.recovery.restore(windows: [1: window], displays: [display()], read: { _ in current }, write: { jobs in
            current = state(space: spaceDrift ? 3 : 815, frame: spaceDrift ? jobs[0].frame : tiled)
            return jobs.map { FrameResult(job: $0, target: $0.frame, got: $0.frame) }
        })
        #expect(try f.journal().windows.count == 1)
        #expect(f.recovery.recoverable == 1)
    }

    @Test func `Monitor changes use current native Spaces to choose each restore monitor`() {
        let f = Fixture(), one = window(1), two = window(2, space: 999)
        f.recovery.capture(one, display: display())
        f.recovery.capture(two, display: display())
        let external = RecoveryDisplay(uuid: "external", visibleFrame: CGRect(x: -3440, y: -1440, width: 3440, height: 1402),
                                       userSpaces: [999], currentSpace: 999)
        var states = [UInt32(1): state(), 2: state(space: 999)]
        var requested: [FrameJob] = []
        f.recovery.restore(windows: [1: one, 2: two], displays: [display(), external], read: { states[$0] }, write: { jobs in
            requested = jobs
            for job in jobs { states[job.id] = state(space: job.id == 1 ? 815 : 999, frame: job.frame) }
            return jobs.map { FrameResult(job: $0, target: $0.frame, got: $0.frame) }
        })
        #expect(requested.first { $0.id == 1 }?.frame == original)
        #expect(requested.first { $0.id == 2 }?.frame == CGRect(x: -3340, y: -1378, width: 800, height: 600))
        #expect(states[1]?.space == 815)
        #expect(states[2]?.space == 999)
        #expect(f.recovery.recoverable == 0)
    }

    @Test func `App minimums beyond the requested bounds do not count as a successful restore`() throws {
        let f = Fixture(), window = window(1)
        f.recovery.capture(window, display: display())
        var current = state()
        f.recovery.restore(windows: [1: window], displays: [display()], read: { _ in current }, write: { jobs in
            let job = jobs[0]
            let grown = CGRect(origin: job.frame.origin, size: CGSize(width: 2000, height: 1200))
            current = state(frame: grown)
            return [FrameResult(job: job, target: grown, got: grown)]
        })
        #expect(f.recovery.recoverable == 1)
        #expect(try f.journal().windows.first?.frame == original)
    }

    @Test func `Timed out and unreadable frame writes keep their original records`() throws {
        let f = Fixture(), window = window(1)
        f.recovery.capture(window, display: display())
        f.recovery.restore(windows: [1: window], displays: [display()], read: { _ in state() }, write: { _ in [] })
        #expect(try f.journal().windows.first?.frame == original)
        #expect(f.recovery.recoverable == 1)
    }

    @Test func `The first untiled frame is kept when subsequent observations are tiled`() throws {
        let f = Fixture()
        var window = window(1, space: 3)
        f.recovery.capture(window, display: display())
        window.frame = tiled
        window.spaceID = 816
        f.recovery.capture(window, display: display())
        f.recovery.restore(windows: [1: window], displays: [display()], read: { _ in state(space: 816) }, write: { _ in [] })
        let entry = try #require(f.journal().windows.first)
        #expect(entry.frame == original)
        #expect(entry.spaceID == 3)
        #expect(entry.displayUUID == "main")
        #expect(entry.displayVisibleFrame == visible)
    }

    @Test func `A frame already restored needs no write and clears its record`() {
        let f = Fixture(), window = window(1)
        f.recovery.capture(window, display: display())
        var writes = 0
        f.recovery.restore(windows: [1: window], displays: [display()], read: { _ in state(frame: original) }, write: { writes += $0.count; return [] })
        #expect(writes == 0)
        #expect(f.recovery.recoverable == 0)
    }

    @Test func `Old journals decode without optional display metadata`() throws {
        let entry = Recovery.Entry(id: 1, pid: 10, bundleID: "test.app", firstSeen: Date(timeIntervalSince1970: 1),
                                   frame: original, spaceID: 3)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(entry)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "displayUUID")
        object.removeValue(forKey: "displayVisibleFrame")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(Recovery.Entry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.frame == original)
        #expect(decoded.spaceID == 3)
        #expect(decoded.displayUUID == nil)
        #expect(decoded.displayVisibleFrame == nil)
    }
    @Test func `Undo restores frames before moving back to an inactive original Space`() {
        let f = Fixture(), window = window(1, space: 3)
        f.recovery.capture(window, display: display())
        var current = state()
        var operations: [String] = []
        f.recovery.restore(windows: [1: window], displays: [display()], read: { _ in current }, write: { jobs in
            operations.append("frame")
            current = state(frame: jobs[0].frame)
            return jobs.map { FrameResult(job: $0, target: $0.frame, got: $0.frame) }
        }, move: { id, target in
            #expect(id == 1 && target == 3)
            operations.append("space")
            current = state(space: target, frame: current.frame, shown: false)
            return true
        })
        #expect(operations == ["frame", "space"])
        #expect(current.space == 3)
        #expect(f.recovery.recoverable == 0)
    }

    @Test func `A deleted original Space keeps each window on its current Space`() {
        let f = Fixture(), window = window(1, space: 700)
        f.recovery.capture(window, display: display())
        var current = state()
        var moves = 0
        f.recovery.restore(windows: [1: window], displays: [display()], read: { _ in current }, write: { jobs in
            current = state(frame: jobs[0].frame)
            return jobs.map { FrameResult(job: $0, target: $0.frame, got: $0.frame) }
        }, move: { _, _ in moves += 1; return false })
        #expect(moves == 0)
        #expect(current.space == 815)
        #expect(f.recovery.recoverable == 0)
    }

    @Test(arguments: [true, false]) func `Refused or unconfirmed undo moves remain journaled`(accepted: Bool) throws {
        let f = Fixture(), window = window(1, space: 3)
        f.recovery.capture(window, display: display())
        var current = state(frame: original)
        var moves = 0
        f.recovery.restore(windows: [1: window], displays: [display()], read: { _ in current }, write: { _ in [] },
                           move: { _, _ in moves += 1; return accepted })
        #expect(moves == 1)
        #expect(try f.journal().windows.count == 1)
        current = state(space: 3, frame: original, shown: false)
        f.recovery.restore(windows: [1: window], displays: [display()], read: { _ in current }, write: { _ in [] },
                           move: { _, _ in moves += 1; return false })
        #expect(moves == 1)
        #expect(f.recovery.recoverable == 0)
    }

}
