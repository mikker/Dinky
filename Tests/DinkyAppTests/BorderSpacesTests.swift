import AppKit
import DinkyConfig
import Testing
@testable import dinky

@MainActor
struct BorderSpacesTests {
    private func display(_ current: UInt64, uuid: String = "display", user: [UInt64] = [1, 2]) -> Display {
        Display(uuid: uuid, id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), isMain: true,
                spaces: [1, 2, 3], userSpaces: user, currentSpaceID: current)
    }

    @Test func `A display-model change refreshes border visibility and focus without a raw event`() async {
        var focused: UInt32 = 10
        let manager = BorderManager(config: Borders(), model: WindowModel(), displays: [display(1)],
                                    isAnimating: { _ in false }, focusedWindow: { focused })
        #expect(manager.visibleSpaces == [1])
        #expect(manager.focusedID == 10)
        focused = 20
        // This is the display-model observer path used for polling and NSWorkspace notifications.
        manager.spacesChanged([display(2)])
        #expect(manager.visibleSpaces == [2])
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(manager.focusedID == 20)
    }

    @Test func `Fullscreen arrival and a disconnected display cannot leave stale border visibility`() {
        let manager = BorderManager(config: Borders(), model: WindowModel(),
                                    displays: [display(1), display(2, uuid: "second")],
                                    isAnimating: { _ in false }, focusedWindow: { 0 })
        #expect(manager.visibleSpaces == [1, 2])
        manager.spacesChanged([display(3)])
        #expect(manager.visibleSpaces.isEmpty)
        manager.spacesChanged([display(2)])
        #expect(manager.visibleSpaces == [2])
        manager.spacesChanged([])
        #expect(manager.visibleSpaces.isEmpty)
    }

    @Test func `Duplicate display observations do not queue more focus reads`() async {
        var reads = 0
        let manager = BorderManager(config: Borders(), model: WindowModel(), displays: [display(1)],
                                    isAnimating: { _ in false }, focusedWindow: { reads += 1; return 0 })
        manager.spacesChanged([display(2)])
        manager.spacesChanged([display(2)])
        manager.spacesChanged([display(2)])
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) { continuation.resume() }
        }
        #expect(reads == 3, "one initial read, one coalesced refresh and one settling recheck")
    }

    @Test func `Fallback arrival rechecks focus after it settles without a front-app event`() async {
        var reads = 0
        let manager = BorderManager(config: Borders(), model: WindowModel(), displays: [display(1)],
                                    isAnimating: { _ in false }, focusedWindow: {
                                        reads += 1
                                        return reads <= 2 ? 0 : 20
                                    })
        manager.spacesChanged([display(2)])
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) { continuation.resume() }
        }
        #expect(reads == 3)
        #expect(manager.focusedID == 20)
    }
}
