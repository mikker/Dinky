import Foundation
import Testing
@testable import DinkyConfig

// Each watcher observes shared ancestors too. Keep resource-intensive lifecycle probes sequential.
@Suite(.serialized)
struct ConfigPathWatcherTests {
    @Test func directoryLinkRetarget() throws {
        let f = try Fixture()
        defer { f.remove() }
        let link = f.root.appending(path: "config")
        try f.link(link, to: "a")
        let reports = Reports(link.appending(path: "dinky.toml"))
        defer { reports.stop() }

        try f.link(link, to: "b")
        reports.next(4)
        try f.write(5, in: "b")
        reports.next(5)
        try f.write(6, in: "a")
        reports.quiet()
    }

    @Test func absoluteDirectoryLinkRetarget() throws {
        let f = try Fixture()
        defer { f.remove() }
        let link = f.root.appending(path: "config")
        try f.link(link, to: f.root.appending(path: "a").path)
        let reports = Reports(link.appending(path: "dinky.toml"))
        defer { reports.stop() }
        try f.link(link, to: f.root.appending(path: "b").path)
        reports.next(4)
    }

    @Test(arguments: ["directory", "file"])
    func intermediateLinkRetarget(kind: String) throws {
        let f = try Fixture()
        defer { f.remove() }
        let hops = try f.directory("hops")
        let first = f.root.appending(path: "config")
        let second = hops.appending(path: "selected")
        let suffix = kind == "file" ? "/dinky.toml" : ""
        try f.link(second, to: "../a" + suffix)
        try f.link(first, to: "hops/selected")
        let url = kind == "file" ? first : first.appending(path: "dinky.toml")
        let reports = Reports(url)
        defer { reports.stop() }

        try f.link(second, to: "../b" + suffix)
        reports.next(4)
        try f.write(5, in: "b", atomic: false)
        reports.next(5)
    }

    @Test func targetSideAncestorRetarget() throws {
        let f = try Fixture()
        defer { f.remove() }
        let route = f.root.appending(path: "route")
        let config = f.root.appending(path: "config")
        try f.write(3, in: "tree-a/nested/config")
        try f.write(4, in: "tree-b/nested/config")
        try f.link(route, to: "tree-a")
        try f.link(config, to: "route/nested/config")
        let reports = Reports(config.appending(path: "dinky.toml"))
        defer { reports.stop() }
        try f.link(route, to: "tree-b")
        reports.next(4)
    }

    @Test func relativeTargetsResolveBeforeDotDot() throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.directory("routes")
        for name in ["tree", "other"] { _ = try f.directory(name + "/branch") }
        try f.write(3, in: "tree/picked")
        try f.write(4, in: "other/picked")
        let jump = f.root.appending(path: "routes/jump")
        try f.link(jump, to: "../tree/branch")
        let config = f.root.appending(path: "config")
        try f.link(config, to: "routes/jump/../picked")
        let reports = Reports(config.appending(path: "dinky.toml"))
        defer { reports.stop() }
        try f.link(jump, to: "../other/branch")
        reports.next(4)
    }

    @Test func newDependencyChainWithTheSameFinalFile() throws {
        let f = try Fixture()
        defer { f.remove() }
        let first = f.root.appending(path: "config")
        let old = f.root.appending(path: "old")
        let live = f.root.appending(path: "live")
        try f.link(old, to: "a")
        try f.link(live, to: "a")
        try f.link(first, to: "old")
        let reports = Reports(first.appending(path: "dinky.toml"))
        defer { reports.stop() }

        try f.link(first, to: "live")
        reports.next(3) // Selection dependencies changed even though the final inode did not.
        try f.link(live, to: "b")
        reports.next(4)
        try f.link(old, to: "b")
        reports.quiet()
    }

    @Test func lexicalAncestorMovedAway() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write(3, in: "ancestor/config")
        let ancestor = f.root.appending(path: "ancestor")
        let reports = Reports(ancestor.appending(path: "config/dinky.toml"))
        defer { reports.stop() }
        try FileManager.default.moveItem(at: ancestor, to: f.root.appending(path: "retired"))
        try f.write(4, in: "ancestor/config")
        reports.next(4)
        try f.write(5, in: "retired/config")
        reports.quiet()
    }

    @Test(arguments: [false, true])
    func unresolvedPathRecovers(loop: Bool) throws {
        let f = try Fixture()
        defer { f.remove() }
        let config = f.root.appending(path: "config")
        let other = f.root.appending(path: "other")
        try f.link(config, to: loop ? "other" : "missing/nested")
        if loop { try f.link(other, to: "config") }
        let reports = Reports(config.appending(path: "dinky.toml"))
        defer { reports.stop() }
        Thread.sleep(forTimeInterval: 0.65) // Exercise recovery polling, not only the initial sources.
        if loop { try f.link(other, to: "b") }
        else { try f.write(4, in: "missing/nested") }
        reports.next(4)
    }

    @Test func neighborsOnEveryDependencyStayQuiet() throws {
        let f = try Fixture()
        defer { f.remove() }
        let hops = try f.directory("hops")
        let selected = hops.appending(path: "selected")
        try f.link(selected, to: "../a")
        let config = f.root.appending(path: "config")
        try f.link(config, to: "hops/selected")
        let reports = Reports(config.appending(path: "dinky.toml"))
        defer { reports.stop() }
        for dir in [f.root, hops, f.root.appending(path: "a")] {
            try "notes".write(to: dir.appending(path: "notes"), atomically: true, encoding: .utf8)
        }
        reports.quiet()
        try f.write(4, in: "a", atomic: false)
        reports.next(4)
    }

    @Test func inPlaceWriteWithPreservedModificationTime() throws {
        let f = try Fixture()
        defer { f.remove() }
        let file = f.root.appending(path: "a/dinky.toml")
        let date = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]!
        let reports = Reports(file)
        defer { reports.stop() }
        try f.write(4, in: "a", atomic: false)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        reports.next(4)
    }

    @Test func healthyObservationDoesNotPoll() throws {
        let f = try Fixture()
        defer { f.remove() }
        let lock = NSLock()
        var opened = 0
        let reports = Reports(f.root.appending(path: "a/dinky.toml"), openObservation: { name in
            lock.lock()
            opened += 1
            lock.unlock()
            return open(name, O_EVTONLY)
        })
        defer { reports.stop() }
        lock.lock()
        let initial = opened
        lock.unlock()
        reports.quiet(for: 0.75)
        lock.lock()
        let final = opened
        lock.unlock()
        #expect(initial > 0)
        #expect(final == initial)
    }

    @Test func observationRecoveryLoadsAnUnobservedInPlaceEdit() throws {
        let f = try Fixture()
        defer { f.remove() }
        let file = f.root.appending(path: "a/dinky.toml")
        let lock = NSLock()
        var available = false
        let reports = Reports(file, openObservation: { name in
            lock.lock()
            let allowed = available
            lock.unlock()
            return name == file.path && !allowed ? -1 : open(name, O_EVTONLY)
        })
        defer { reports.stop() }
        try f.write(4, in: "a", atomic: false)
        reports.quiet(for: 0.75) // An unsuccessful recovery attempt must not emit repeated callbacks.
        lock.lock()
        available = true
        lock.unlock()
        reports.next(4) // No second write or identity change after observation recovers.
    }

    @Test func deinitializationReleasesPathDescriptors() throws {
        let f = try Fixture()
        defer { f.remove() }
        let file = f.root.appending(path: "a/dinky.toml")
        for i in 0..<80 {
            var watcher: ConfigWatcher? = ConfigWatcher(url: file) { _ in }
            weak var released = watcher
            if i.isMultiple(of: 2) { watcher?.stop() }
            watcher = nil
            #expect(released == nil)
        }
        // Cancellation closes descriptors asynchronously. Inspect the actual open descriptor table.
        func descriptors() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap { name in
                guard let fd = Int32(name) else { return nil }
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                guard fcntl(fd, F_GETPATH, &path) == 0 else { return nil }
                let value = String(cString: path)
                return value.contains(f.root.lastPathComponent) ? value : nil
            }
        }
        for _ in 0..<50 {
            if try descriptors().isEmpty { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(try descriptors().isEmpty)
    }

    @Test func repeatedRetargetingAndStop() throws {
        let f = try Fixture()
        defer { f.remove() }
        let config = f.root.appending(path: "config")
        try f.link(config, to: "a")
        let reports = Reports(config.appending(path: "dinky.toml"))
        defer { reports.stop() }
        for i in 0..<12 {
            try f.link(config, to: i.isMultiple(of: 2) ? "b" : "a")
            reports.next(i.isMultiple(of: 2) ? 4 : 3)
        }
        reports.stop()
        try f.link(config, to: "b")
        reports.quiet(for: 0.8)
    }
}

private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "dinky-path-\(UUID().uuidString)")

    init() throws {
        try write(3, in: "a")
        try write(4, in: "b")
    }

    func directory(_ name: String) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ count: Int, in name: String, atomic: Bool = true) throws {
        let dir = try directory(name)
        try "workspaces = \(count)\n".write(to: dir.appending(path: "dinky.toml"), atomically: atomic, encoding: .utf8)
    }

    func link(_ url: URL, to destination: String) throws {
        let staged = url.deletingLastPathComponent().appending(path: "staged-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: staged.path, withDestinationPath: destination)
        guard rename(staged.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class Reports {
    private var watcher: ConfigWatcher?
    private let lock = NSLock()
    private var results: [Result<Config, ConfigError>] = []
    private let ready = DispatchSemaphore(value: 0)

    init(_ url: URL, openObservation: @escaping (String) -> Int32 = { open($0, O_EVTONLY) }) {
        watcher = ConfigWatcher(url: url, openObservation: openObservation) { [weak self] result in
            guard let self else { return }
            lock.lock()
            results.append(result)
            lock.unlock()
            ready.signal()
        }
    }

    func next(_ workspaces: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        let deadline = DispatchTime.now() + 2
        while ready.wait(timeout: deadline) == .success {
            lock.lock()
            let result = results.removeFirst()
            lock.unlock()
            if case .success(let config) = result, config.workspaces == workspaces { return }
        }
        Issue.record("Did not load workspaces = \(workspaces)", sourceLocation: sourceLocation)
    }

    func quiet(for seconds: Double = 0.35, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(ready.wait(timeout: .now() + seconds) == .timedOut, sourceLocation: sourceLocation)
    }

    func stop() { watcher?.stop() }
}
