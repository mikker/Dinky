import Foundation
import Testing
@testable import dinky

struct BorderTests {
    private func window(_ id: UInt32, space: UInt64 = 1, orderedIn: Bool = true, document: Bool = true,
                        visible: Bool = true, minimized: Bool = false) -> Window {
        var window = Window(identity: .init(id: id, pid: 1, firstSeen: Date(timeIntervalSince1970: 0)),
                            appName: nil, bundleID: nil)
        window.spaceID = space
        window.isOrderedIn = orderedIn
        window.isDocument = document
        window.isVisible = visible
        window.isMinimized = minimized
        return window
    }

    private func lone(_ windows: [Window], visible: Set<UInt64> = [1]) -> Set<UInt32> {
        BorderManager.loneWindows(in: windows, visibleSpaces: visible)
    }

    @Test func `A window alone on its Space is lone`() {
        #expect(lone([window(1)]) == [1])
    }

    @Test func `Two windows on one Space are not lone`() {
        #expect(lone([window(1), window(2)]).isEmpty)
    }

    @Test func `Windows not shown do not count`() {
        #expect(lone([window(1), window(2, minimized: true)]) == [1])
        #expect(lone([window(1), window(2, orderedIn: false)]) == [1])
        #expect(lone([window(1), window(2, visible: false)]) == [1])
        #expect(lone([window(1), window(2, document: false)]) == [1])
    }

    @Test func `A window on a hidden Space is never lone and does not count`() {
        #expect(lone([window(1, space: 2)]).isEmpty)
        #expect(lone([window(1), window(2, space: 2)]) == [1])
    }

    @Test func `Each visible Space is counted on its own`() {
        #expect(lone([window(1, space: 1), window(2, space: 2)], visible: [1, 2]) == [1, 2])
        #expect(lone([window(1, space: 1), window(2, space: 2), window(3, space: 2)], visible: [1, 2]) == [1])
    }
}
