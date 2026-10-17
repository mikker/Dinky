import CoreGraphics
import Testing
@testable import DinkyLayout

/// Three windows in 1000x600: 1 on the left, 2 above 3 on the right.
private func three() -> Workspace { workspace(3) }

struct NeighborTests {
    @Test func `Left from either right window is one`() {
        #expect(three().neighbor(of: 2, .left) == 1)
        #expect(three().neighbor(of: 3, .left) == 1)
    }

    @Test func `Up and down within right column`() {
        #expect(three().neighbor(of: 3, .up) == 2)
        #expect(three().neighbor(of: 2, .down) == 3)
    }

    @Test func `Right from one prefers most recent`() {
        var ws = three()
        ws.focus(2)
        ws.focus(1)
        #expect(ws.neighbor(of: 1, .right) == 2)
        ws.focus(3)
        ws.focus(1)
        #expect(ws.neighbor(of: 1, .right) == 3)
    }

    @Test func `No neighbour at edges`() {
        #expect(three().neighbor(of: 1, .left) == nil)
        #expect(three().neighbor(of: 1, .up) == nil)
        #expect(three().neighbor(of: 2, .right) == nil)
        #expect(three().neighbor(of: 3, .down) == nil)
    }

    @Test func `Focus direction moves focus`() {
        var ws = three()
        #expect(ws.focus(.left) == true)
        #expect(ws.focused == 1)
        #expect(ws.focus(.left) == false)
    }

    @Test func `Accordion neighbours follow child order`() {
        var ws = workspace(3, algorithm: .dwindle(.accordion))
        #expect(ws.neighbor(of: 3, .left) == 2)
        ws.focus(1)
        #expect(ws.neighbor(of: 1, .right) == 2)
    }
}

struct SwapAndMoveTests {
    @Test func `Move swaps with sibling window`() {
        var ws = workspace(3, bounds: rect(0, 0, 3000, 500))
        ws.focus(1)
        ws.move(.right)
        #expect(shape(ws.root) == "h[2 1 3]")
    }

    @Test func `Move out of container at edge`() {
        var ws = three()
        #expect(ws.move(.right) == true)
        #expect(shape(ws.root) == "h[1 2 3]")
    }

    @Test func `Move across axis leaves container`() {
        var ws = three()
        ws.move(.left)
        #expect(shape(ws.root) == "h[1 3 2]")
    }

    @Test func `Move into sibling container`() {
        var ws = three()
        ws.focus(1)
        ws.move(.right)
        #expect(shape(ws.root) == "v[2 3 1]")
    }

    @Test func `Move at workspace edge does nothing`() {
        var ws = three()
        ws.focus(1)
        #expect(ws.move(.left) == false)
        #expect(shape(ws.root) == "h[1 v[2 3]]")
    }

    @Test func `Move past a root accordion edge leaves it for a tile`() {
        var ws = workspace(3, algorithm: .dwindle(.accordion))
        #expect(ws.move(.right) == true)
        #expect(shape(ws.root) == "h[ah[1 2] 3]")
        #expect(ws.move(.left) == true, "moving back enters the accordion at its near edge")
        #expect(shape(ws.root) == "ah[1 2 3]")
    }

    @Test func `Move at the edge of a lone accordion window does nothing`() {
        var ws = workspace(1, algorithm: .dwindle(.accordion))
        #expect(ws.move(.right) == false)
        #expect(shape(ws.root) == "ah[1]")
    }

    @Test func `Move across root wraps it`() {
        var ws = workspace(2)
        ws.focus(1)
        ws.move(.down)
        #expect(shape(ws.root) == "v[2 1]")
    }
}

struct JoinTests {
    @Test func `Join wraps neighbour window`() {
        var ws = workspace(3, bounds: rect(0, 0, 3000, 500))
        ws.focus(2)
        #expect(ws.join(.right) == true)
        #expect(shape(ws.root) == "h[1 v[2 3]]")
        #expect(ws.focused == 2)
    }

    @Test func `Join into neighbour container`() {
        var ws = three()
        ws.focus(1)
        ws.join(.right)
        #expect(shape(ws.root) == "v[1 2 3]")
    }

    @Test func `Join from inside container`() {
        var ws = three()
        ws.join(.left)
        #expect(shape(ws.root) == "h[v[1 3] 2]")
    }

    @Test func `Join without neighbour fails`() {
        var ws = three()
        ws.focus(1)
        #expect(ws.join(.left) == false)
    }
}

struct ResizeTests {
    @Test func `Resize grows along parent axis`() {
        var ws = workspace(2)
        ws.focus(1)
        #expect(ws.resize(by: 100) == true)
        assertRatios(ws.root.ratios, [0.6, 0.4])
        #expect(ws.layout().frames[1] == rect(0, 0, 600, 600))
    }

    @Test func `Resize uses nearest parent`() {
        var ws = three() // 3 sits in the right column, 600 tall
        ws.resize(by: 60)
        #expect(shape(ws.root) == "h[1 v[2 3]]")
        assertRatios(ws.root.ratios, [0.5, 0.5])
        #expect(ws.layout().frames[3] == rect(500, 240, 500, 360))
    }

    @Test func `Resize clamps at minimum`() {
        var ws = workspace(2)
        ws.resize(by: 5000)
        assertRatios(ws.root.ratios, [0.1, 0.9])
        #expect(ws.resize(by: 50) == false)
        ws.resize(by: -5000)
        assertRatios(ws.root.ratios, [0.9, 0.1])
    }

    @Test func `Resize keeps every sibling above minimum`() {
        var ws = workspace(3, bounds: rect(0, 0, 3000, 500))
        ws.resize(by: 5000)
        assertRatios(ws.root.ratios, [0.1, 0.1, 0.8])
    }

    @Test func `Resize by and resize to share the extent between the gaps`() {
        let gaps = Gaps(horizontal: 10, vertical: 0, top: 0, bottom: 0, left: 0, right: 0)
        var by = workspace(2, gaps: gaps), to = by
        #expect(by.layout().frames[2] == rect(505, 0, 495, 600))
        #expect(by.resize(by: 100) == true)
        #expect(to.resize(2, to: CGSize(width: 595, height: 600), moving: [.left]) == true)
        #expect(by.layout().frames[1] == rect(0, 0, 395, 600))
        #expect(by.layout().frames[2] == rect(405, 0, 595, 600))
        #expect(to.layout() == by.layout())
    }

    @Test func `Single window cannot resize`() {
        var ws = workspace(1)
        #expect(ws.resize(by: 50) == false)
    }
}

struct SplitTests {
    @Test func `Split gives the dragged window the chosen half of the target's tile`() {
        var ws = workspace(3)
        #expect(shape(ws.root) == "h[1 v[2 3]]")
        #expect(ws.split(1, with: 3, on: .down) == true)
        #expect(shape(ws.root) == "h[v[1 3] 2]")
        #expect(ws.layout().frames[1] == rect(0, 0, 500, 300))
        #expect(ws.layout().frames[3] == rect(0, 300, 500, 300))
        #expect(ws.split(2, with: 1, on: .left) == true)
        #expect(shape(ws.root) == "h[3 1 2]")
        #expect(ws.layout().frames[1] == rect(500, 0, 250, 600))
        #expect(ws.focused == 3)
    }

    @Test func `Split between siblings turns the pair`() {
        var ws = workspace(2)
        #expect(ws.split(2, with: 1, on: .up) == true)
        #expect(shape(ws.root) == "v[1 2]")
        #expect(ws.split(1, with: 1, on: .up) == false)
        #expect(ws.split(1, with: 99, on: .up) == false)
    }

    @Test func `Fixed and scrolling layouts do not split`() {
        #expect(!workspace(2, algorithm: .fixed(rows: 1, columns: 2, expand: .columns)).canSplit(1, with: 2))
        #expect(!workspace(2, algorithm: .scrolling).canSplit(1, with: 2))
    }
}
