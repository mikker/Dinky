import CoreGraphics
import Testing
@testable import DinkyLayout

struct TilesTests {
    @Test(arguments: zip(1...5, [
        [1: rect(0, 0, 1000, 600)],
        [1: rect(0, 0, 500, 600), 2: rect(500, 0, 500, 600)],
        [1: rect(0, 0, 500, 600), 2: rect(500, 0, 500, 300), 3: rect(500, 300, 500, 300)],
        [1: rect(0, 0, 500, 600), 2: rect(500, 0, 500, 300), 3: rect(500, 300, 250, 300), 4: rect(750, 300, 250, 300)],
        [1: rect(0, 0, 500, 600), 2: rect(500, 0, 500, 300), 3: rect(500, 300, 250, 300),
         4: rect(750, 300, 250, 150), 5: rect(750, 450, 250, 150)],
    ] as [[WindowID: CGRect]]))
    func `Tiles without gaps`(windows: Int, frames: [WindowID: CGRect]) {
        #expect(workspace(windows).layout().frames == frames)
    }

    // Outer gaps of 10 leave (10, 10, 990, 590); inner gaps of 10 sit between siblings.
    @Test(arguments: zip(1...5, [
        [1: rect(10, 10, 990, 590)],
        [1: rect(10, 10, 490, 590), 2: rect(510, 10, 490, 590)],
        [1: rect(10, 10, 490, 590), 2: rect(510, 10, 490, 290), 3: rect(510, 310, 490, 290)],
        [1: rect(10, 10, 490, 590), 2: rect(510, 10, 490, 290), 3: rect(510, 310, 240, 290), 4: rect(760, 310, 240, 290)],
        [1: rect(10, 10, 490, 590), 2: rect(510, 10, 490, 290), 3: rect(510, 310, 240, 290),
         4: rect(760, 310, 240, 140), 5: rect(760, 460, 240, 140)],
    ] as [[WindowID: CGRect]]))
    func `Tiles with gaps`(windows: Int, frames: [WindowID: CGRect]) {
        let bounds = rect(0, 0, 1010, 610), gaps = Gaps(all: 10)
        #expect(workspace(windows, bounds: bounds, gaps: gaps).layout().frames == frames)
    }

    @Test func `Uneven outer gaps`() {
        let gaps = Gaps(horizontal: 0, vertical: 0, top: 30, bottom: 10, left: 5, right: 15)
        #expect(workspace(1, gaps: gaps).layout().frames[1] == rect(5, 30, 980, 560))
    }

    @Test func `Edges are rounded without holes`() {
        var ws = workspace(3, bounds: rect(0, 0, 3000, 500))
        ws.bounds = rect(0, 0, 1000, 500)
        let f = ws.layout().frames
        #expect([f[1]!.width, f[2]!.width, f[3]!.width] == [333, 334, 333])
        #expect(f[1]!.maxX == f[2]!.minX)
        #expect(f[2]!.maxX == f[3]!.minX)
    }

    @Test func `Changing bounds keeps topology`() {
        var ws = workspace(5)
        let before = ws.root
        ws.bounds = rect(0, 0, 600, 1000)
        _ = ws.layout()
        #expect(ws.root == before)
        #expect(ws.layout().frames[1] == rect(0, 0, 300, 1000))
    }

    @Test func `Layout is deterministic`() {
        let a = workspace(5, gaps: Gaps(all: 8)), b = workspace(5, gaps: Gaps(all: 8))
        #expect(a == b)
        #expect(a.layout() == b.layout())
        #expect(a.layout() == a.layout())
    }

    @Test func `Focused window is frontmost`() {
        var ws = workspace(5)
        ws.focus(2)
        #expect(ws.layout().order.first == 2)
        #expect(Set(ws.layout().order) == [1, 2, 3, 4, 5])
    }
}

struct AccordionTests {
    @Test func `Single child fills rect`() {
        #expect(workspace(1, algorithm: .dwindle(.accordion)).layout().frames[1] == rect(0, 0, 1000, 600))
    }

    @Test func `Middle focused neighbours peek on both sides`() {
        var ws = workspace(3, algorithm: .dwindle(.accordion))
        ws.focus(2)
        let layout = ws.layout()
        #expect(layout.frames == [1: rect(0, 0, 970, 600), 2: rect(30, 0, 940, 600), 3: rect(30, 0, 970, 600)])
        #expect(layout.order == [2, 1, 3])
    }

    @Test func `Last focused previous peeks on left`() {
        let layout = workspace(3, algorithm: .dwindle(.accordion)).layout() // 3 is focused
        #expect(layout.frames == [1: rect(0, 0, 970, 600), 2: rect(0, 0, 940, 600), 3: rect(30, 0, 970, 600)])
        #expect(layout.order == [3, 2, 1])
    }

    @Test func `First focused next peeks on right`() {
        var ws = workspace(3, algorithm: .dwindle(.accordion))
        ws.focus(1)
        let layout = ws.layout()
        #expect(layout.frames == [1: rect(0, 0, 970, 600), 2: rect(60, 0, 940, 600), 3: rect(30, 0, 970, 600)])
        #expect(layout.order == [1, 2, 3])
    }

    @Test func `Vertical accordion peeks along height`() {
        var ws = workspace(2, bounds: rect(0, 0, 600, 1000), algorithm: .dwindle(.accordion))
        ws.focus(1)
        #expect(ws.layout().frames == [1: rect(0, 0, 600, 970), 2: rect(0, 30, 600, 970)])
    }

    @Test func `Accordion respects outer gaps`() {
        let ws = workspace(2, bounds: rect(0, 0, 1020, 620), gaps: Gaps(all: 10), algorithm: .dwindle(.accordion))
        #expect(ws.layout().frames == [1: rect(10, 10, 970, 600), 2: rect(40, 10, 970, 600)])
    }

    @Test func `Stacking order is stable across focus changes`() {
        var ws = workspace(5, algorithm: .dwindle(.accordion))
        ws.focus(3)
        #expect(ws.layout().order == [3, 2, 4, 1, 5])
        ws.focus(1)
        ws.focus(3)
        #expect(ws.layout().order == [3, 2, 4, 1, 5])
    }

    @Test func `Accordion remembers top child when focus leaves`() {
        var ws = workspace(3) // h[1 v[2 3]]
        ws.focus(2)
        ws.setMode(.accordion)
        ws.focus(1)
        #expect(ws.layout().order == [1, 2, 3])
    }
}

struct FullscreenTests {
    @Test func `Fullscreen window fills bounds minus outer gaps`() {
        var ws = workspace(3, bounds: rect(0, 0, 1010, 610), gaps: Gaps(all: 10))
        ws.focus(2)
        ws.toggleFullscreen()
        let layout = ws.layout()
        #expect(layout.frames[2] == rect(10, 10, 990, 590))
        #expect(layout.order.first == 2)
    }

    @Test func `Fullscreen leaves tree and other frames alone`() {
        var ws = workspace(3)
        let root = ws.root, frames = ws.layout().frames
        ws.toggleFullscreen()
        #expect(ws.root == root)
        #expect(ws.layout().frames[1] == frames[1])
        #expect(ws.layout().frames[2] == frames[2])
    }

    @Test func `Toggle twice restores`() {
        var ws = workspace(3)
        let layout = ws.layout()
        ws.toggleFullscreen()
        #expect(ws.fullscreen == 3)
        ws.toggleFullscreen()
        #expect(ws.fullscreen == nil)
        #expect(ws.layout() == layout)
    }

    @Test func `Removing fullscreen window clears it`() {
        var ws = workspace(3)
        ws.toggleFullscreen()
        ws.remove(3)
        #expect(ws.fullscreen == nil)
    }
}

struct PlacementTests {
    @Test func `Windows on their tiles are placed`() {
        let layout = workspace(3).layout()
        #expect(layout.isPlaced(in: layout.frames, within: 0))
        let nudged = layout.frames.mapValues { $0.offsetBy(dx: 1.5, dy: -1.5) }
        #expect(layout.isPlaced(in: nudged, within: 2))
        #expect(!layout.isPlaced(in: nudged, within: 1))
    }

    @Test func `A window off its tile or missing is not placed`() {
        let layout = workspace(2).layout()
        var actual = layout.frames
        actual[2] = actual[2]!.offsetBy(dx: 40, dy: 0)
        #expect(!layout.isPlaced(in: actual, within: 2))
        actual[2] = nil
        #expect(!layout.isPlaced(in: actual, within: 2))
    }

    @Test func `An empty layout is placed`() {
        #expect(workspace(0).layout().isPlaced(in: [:], within: 2))
    }
}
