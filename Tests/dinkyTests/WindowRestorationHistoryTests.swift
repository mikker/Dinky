import Foundation
import Testing
@testable import dinky

struct WindowRestorationHistoryTests {
    private let identity = Window.Identity(id: 1, pid: 10, firstSeen: Date(timeIntervalSince1970: 1))

    @Test func `Reconnect allows restoration again without treating the window as newly opened`() {
        var history = WindowRestorationHistory()
        history.noteReturn(identity)
        #expect(history.returnedDuringChange(identity))
        history.beginDisplayChange()
        #expect(!history.returnedDuringChange(identity))
        #expect(history.wasRestored(identity))
        history.noteReturn(identity)
        #expect(history.returnedDuringChange(identity))
    }

    @Test func `Closed windows and reused IDs do not inherit restoration status`() {
        var history = WindowRestorationHistory()
        history.noteReturn(identity)
        let replacement = Window.Identity(id: 1, pid: 10, firstSeen: Date(timeIntervalSince1970: 2))
        #expect(!history.wasRestored(replacement))
        history.retain([replacement])
        #expect(!history.wasRestored(identity))
        #expect(!history.returnedDuringChange(identity))
        #expect(!history.wasRestored(replacement))
    }
}
