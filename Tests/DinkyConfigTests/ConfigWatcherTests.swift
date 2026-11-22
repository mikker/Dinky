import Foundation
import Testing
@testable import DinkyConfig

struct ConfigWatcherTests {
    // ConfigWatcher reports on the main queue after the write returns, so wait on semaphores off the main actor.
    @Test func `Fires on change`() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "dinky-\(UUID().uuidString).toml")
        try "workspaces = 3\n".write(to: url, atomically: false, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let changed = DispatchSemaphore(value: 0)  // reloaded
        let broken = DispatchSemaphore(value: 0)  // error reported
        let watcher = ConfigWatcher(url: url) { result in
            switch result {
            case .success(let config) where config.workspaces == 4: changed.signal()
            case .failure(let error) where error.path == "gap": broken.signal()
            default: break
            }
        }
        defer { watcher.stop() }

        try "workspaces = 4\n".write(to: url, atomically: false, encoding: .utf8)
        #expect(changed.wait(timeout: .now() + 1) == .success, "reloaded")

        // Atomic save: a new file renamed over the old one.
        try "gap = 4\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(broken.wait(timeout: .now() + 1) == .success, "error reported")
    }

    @Test func `Fires when the config's directory is trashed and replaced by a symlink`() throws {
        let tmp = FileManager.default.temporaryDirectory
        let dir = tmp.appending(path: "dinky-\(UUID().uuidString)")
        let trashed = dir.appendingPathExtension("trashed"), dotfiles = dir.appendingPathExtension("dotfiles")
        defer { for each in [dir, trashed, dotfiles] { try? FileManager.default.removeItem(at: each) } }
        for each in [dir, dotfiles] { try FileManager.default.createDirectory(at: each, withIntermediateDirectories: true) }
        let url = dir.appending(path: "dinky.toml")
        try "workspaces = 3\n".write(to: url, atomically: false, encoding: .utf8)
        try "workspaces = 3\n".write(to: dotfiles.appending(path: "dinky.toml"), atomically: false, encoding: .utf8)
        let seen = DispatchSemaphore(value: 0)
        let watcher = watch(url, workspaces: 4, seen)
        defer { watcher.stop() }
        try FileManager.default.moveItem(at: dir, to: trashed)
        Thread.sleep(forTimeInterval: 0.3)
        try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: dotfiles)
        Thread.sleep(forTimeInterval: 0.6)
        try "workspaces = 4\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(seen.wait(timeout: .now() + 1) == .success)
    }

    @Test func `A stopped watcher stays stopped while its file is missing`() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "dinky-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let reported = DispatchSemaphore(value: 0)
        let watcher = ConfigWatcher(url: url) { _ in reported.signal() }
        watcher.stop()
        try "workspaces = 4\n".write(to: url, atomically: false, encoding: .utf8)
        // The missing file is polled every 0.5 s, and a reload follows 0.1 s after the file appears.
        #expect(reported.wait(timeout: .now() + 1.5) == .timedOut)
    }

    /// A config in one directory with `dinky.toml` a symlink to it in another, as a dotfiles checkout sets it up.
    private func linkedConfig() throws -> (link: URL, target: URL, dirs: [URL]) {
        let tmp = FileManager.default.temporaryDirectory
        let a = tmp.appending(path: "dinky-a-\(UUID().uuidString)"), b = tmp.appending(path: "dinky-b-\(UUID().uuidString)")
        for dir in [a, b] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let target = a.appending(path: "dinky.toml"), link = b.appending(path: "dinky.toml")
        try "workspaces = 3\n".write(to: target, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return (link, target, [a, b])
    }

    private func watch(_ url: URL, workspaces: Int, _ seen: DispatchSemaphore) -> ConfigWatcher {
        ConfigWatcher(url: url) { result in
            if case .success(let config) = result, config.workspaces == workspaces { seen.signal() }
        }
    }

    @Test func `Fires when a file is renamed over the symlink`() throws {
        let (link, _, dirs) = try linkedConfig()
        defer { for dir in dirs { try? FileManager.default.removeItem(at: dir) } }
        let seen = DispatchSemaphore(value: 0)
        let watcher = watch(link, workspaces: 4, seen)
        defer { watcher.stop() }
        let replacement = dirs[1].appending(path: "new.toml")
        try "workspaces = 4\n".write(to: replacement, atomically: false, encoding: .utf8)
        #expect(rename(replacement.path, link.path) == 0)
        #expect(seen.wait(timeout: .now() + 1) == .success)
    }

    @Test func `Fires when the symlink is pointed elsewhere`() throws {
        let (link, _, dirs) = try linkedConfig()
        defer { for dir in dirs { try? FileManager.default.removeItem(at: dir) } }
        let other = dirs[0].appending(path: "other.toml")
        try "workspaces = 5\n".write(to: other, atomically: false, encoding: .utf8)
        let seen = DispatchSemaphore(value: 0)
        let watcher = watch(link, workspaces: 5, seen)
        defer { watcher.stop() }
        // As `ln -sf` does: a new link renamed over the old one.
        let staged = dirs[1].appending(path: "staged.toml")
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: other)
        #expect(rename(staged.path, link.path) == 0)
        #expect(seen.wait(timeout: .now() + 1) == .success)
    }

    @Test func `Fires when the symlink's target is saved atomically`() throws {
        let (link, target, dirs) = try linkedConfig()
        defer { for dir in dirs { try? FileManager.default.removeItem(at: dir) } }
        let seen = DispatchSemaphore(value: 0)
        let watcher = watch(link, workspaces: 4, seen)
        defer { watcher.stop() }
        try "workspaces = 4\n".write(to: target, atomically: true, encoding: .utf8)
        #expect(seen.wait(timeout: .now() + 1) == .success)
    }

    @Test func `Another file changing next to the config does not reload it`() throws {
        let (link, _, dirs) = try linkedConfig()
        defer { for dir in dirs { try? FileManager.default.removeItem(at: dir) } }
        let reported = DispatchSemaphore(value: 0)
        let watcher = ConfigWatcher(url: link) { _ in reported.signal() }
        defer { watcher.stop() }
        try "x".write(to: dirs[1].appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        // A reload resets the binding mode, so it must not happen for a neighbour.
        #expect(reported.wait(timeout: .now() + 0.5) == .timedOut)
    }
}
