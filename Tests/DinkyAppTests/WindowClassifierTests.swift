import AppKit
import Testing
@testable import dinky

@MainActor
struct WindowClassifierTests {
    private func window(_ id: UInt32, pid: Int32 = 1, seen: Date = Date()) -> Window {
        Window(identity: .init(id: id, pid: pid, firstSeen: seen), appName: "Test", bundleID: "test")
    }

    private var metadata: WindowMetadata {
        WindowMetadata(kind: .normal, resizable: true, title: "test", lacksFullscreen: false)
    }

    @Test func `A slow app cannot block the UI thread or classification of another app`() async {
        let started = Completion()
        let release = DispatchSemaphore(value: 0)
        let slowDone = Completion()
        let fastDone = Completion()
        let value = metadata
        let classifier = WindowClassifier(read: { window in
            #expect(!Thread.isMainThread)
            if window.pid == 1 {
                DispatchQueue.main.async { started.signal() }
                _ = release.wait(timeout: .now() + 3)
            }
            return value
        })
        classifier.request(window(10)) { result in
            #expect(Thread.isMainThread)
            #expect(result?.resizable == true)
            slowDone.signal()
        }
        #expect(await started.wait())
        classifier.request(window(20, pid: 2)) { _ in fastDone.signal() }
        #expect(await fastDone.wait())
        release.signal()
        #expect(await slowDone.wait())
    }

    @Test func `Repeated window events coalesce into one classification`() async {
        let release = DispatchSemaphore(value: 0)
        let done = Completion()
        let value = metadata
        let classifier = WindowClassifier(read: { _ in
            _ = release.wait(timeout: .now() + 2)
            return value
        })
        let target = window(10)
        #expect(classifier.request(target) { _ in done.signal() })
        #expect(!classifier.request(target) { _ in Issue.record("duplicate result") })
        release.signal()
        #expect(await done.wait())
    }

    @Test func `A reused window id never receives a result for the closed window`() async {
        let started = Completion()
        let release = DispatchSemaphore(value: 0)
        let done = Completion()
        let value = metadata
        let old = window(10)
        let replacement = window(10, seen: old.identity.firstSeen + 1)
        let classifier = WindowClassifier(read: { window in
            if window.identity == old.identity {
                DispatchQueue.main.async { started.signal() }
                _ = release.wait(timeout: .now() + 2)
            }
            return value
        })
        classifier.request(old) { _ in Issue.record("closed identity received a result") }
        #expect(await started.wait())
        classifier.forget(old.id)
        classifier.request(replacement) { _ in done.signal() }
        release.signal()
        #expect(await done.wait())
    }

    @Test func `Unavailable AX metadata retries a bounded number of times`() async {
        let done = Completion()
        var attempts = 0
        let classifier = WindowClassifier(retryDelay: 0, maxAttempts: 5, read: { _ in
            attempts += 1
            return nil
        })
        classifier.request(window(10)) { result in
            #expect(result == nil)
            #expect(attempts == 5)
            done.signal()
        }
        #expect(await done.wait())
    }

    @Test func `Disable cancels in-flight classification before delivering it`() async {
        let started = Completion()
        let release = DispatchSemaphore(value: 0)
        let done = Completion()
        let value = metadata
        let classifier = WindowClassifier(read: { window in
            if window.id == 10 {
                DispatchQueue.main.async { started.signal() }
                _ = release.wait(timeout: .now() + 2)
            }
            return value
        })
        classifier.request(window(10)) { _ in Issue.record("canceled request completed") }
        #expect(await started.wait())
        classifier.cancel()
        classifier.request(window(20)) { _ in done.signal() }
        release.signal()
        #expect(await done.wait())
    }
}

/// A bounded callback wait that yields the main actor, where classifier completions are delivered.
@MainActor
private final class Completion {
    private var signaled = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func signal() {
        #expect(!signaled, "completion must run once")
        signaled = true
        continuation?.resume(returning: true)
        continuation = nil
    }

    func wait() async -> Bool {
        if signaled { return true }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.continuation?.resume(returning: false)
                self.continuation = nil
            }
        }
    }
}
