import Foundation
import Testing
@testable import dinky

struct WindowVisibilityTests {
    private func document() -> Window {
        var window = Window(identity: .init(id: 1, pid: 1, firstSeen: Date()), appName: "Test", bundleID: "test.app")
        window.isDocument = true
        window.isVisible = true
        window.isOrderedIn = true
        return window
    }

    @Test func `On screen document with an inconsistent ordered flag can tile`() {
        var window = document()
        window.isOrderedIn = false
        #expect(!window.isNormal)
        window.isOnScreen = true
        #expect(window.isNormal)
        #expect(window.isShown)
    }

    @Test func `Genuinely hidden and inactive tab windows stay out of tiling`() {
        var window = document()
        window.isOrderedIn = false
        window.isOnScreen = false
        #expect(!window.isNormal)
        #expect(!window.isShown)
        window.isOnScreen = true
        window.isAppHidden = true
        #expect(!window.isShown)
        #expect(!window.isNormal)
    }

    @Test func `Minimized and invisible documents do not tile`() {
        var window = document()
        window.isMinimized = true
        window.isOnScreen = true
        #expect(!window.isNormal)
        window.isMinimized = false
        window.isVisible = false
        #expect(!window.isNormal)
    }

    @Test func `Screen visibility does not make helper windows eligible`() {
        var window = document()
        window.isOnScreen = true
        window.isDocument = false
        #expect(!window.isNormal)
        window.isDocument = true
        window.level = 1
        #expect(!window.isNormal)
    }

    @Test func `Fallback expires when the document leaves the screen`() {
        var window = document()
        window.isOrderedIn = false
        window.isOnScreen = true
        #expect(window.isNormal)
        window.isOnScreen = false
        #expect(!window.isNormal)
    }
}
