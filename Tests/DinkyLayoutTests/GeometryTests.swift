import CoreGraphics
import Testing
@testable import DinkyLayout

struct TilesTests {
    @Test(arguments: [ContainerOrientation.horizontal, .vertical], [0, 10])
    func `Tiled parents relax accordion peeks before feasible content minima`(orientation: ContainerOrientation, gap: Int) {
        let first = Container(orientation, .accordion, [.window(1), .window(2), .window(3)])
        let second = Container(orientation, .accordion, [.window(4), .window(5), .window(6)])
        var parent = Container(orientation, .tiles, [.container(first), .window(7), .container(second)])
        parent.setRatios([0.05, 0.9, 0.05])
        var layout = Layout()
        parent.layout(in: rect(10, 20, 1000, 1000), gaps: Gaps(all: CGFloat(gap)), padding: 30,
                      minimums: [2: CGSize(width: 400, height: 400), 5: CGSize(width: 400, height: 400),
                                 7: CGSize(width: 100, height: 100)], into: &layout)
        for id: WindowID in [2, 5, 7] {
            let frame = layout.frames[id]!
            #expect(rect(10, 20, 1000, 1000).contains(frame))
            let extent = orientation == .horizontal ? frame.width : frame.height
            #expect(extent >= (id == 7 ? 100 : 400))
        }
        let a = layout.containerRects[[0]]!, b = layout.containerRects[[2]]!
        if orientation == .horizontal {
            #expect(layout.frames[7]!.minX - a.maxX == CGFloat(gap))
            #expect(b.minX - layout.frames[7]!.maxX == CGFloat(gap))
        } else {
            #expect(layout.frames[7]!.minY - a.maxY == CGFloat(gap))
            #expect(b.minY - layout.frames[7]!.maxY == CGFloat(gap))
        }
    }

    // Seed 7 of the VM fuzz: Finder (3) next to a TextEdit window (4) whose minimum is not known yet, in a
    // column the root squeezed to Finder's minimum. Window 4 got a tile 0 pt wide, hanging off the display.
    @Test func `A window whose minimum is unknown keeps a usable tile beside one at its minimum`() {
        let row = Container(.horizontal, .tiles, [.window(3), .window(4)])
        let column = Container(.vertical, .tiles, [.container(row), .window(5)])
        var root = Container(.horizontal, .tiles, [.window(1), .window(2), .container(column)])
        root.setRatios([0.33, 0.33, 0.34])
        var layout = Layout()
        root.layout(in: rect(8, 38, 1008, 664), gaps: Gaps(all: 8), padding: 30,
                    minimums: [3: CGSize(width: 475, height: 0)], into: &layout)
        for (id, frame) in layout.frames {
            #expect(rect(8, 38, 1008, 664).contains(frame), "window \(id) at \(frame)")
            #expect(frame.width >= 100, "window \(id) at \(frame)")
        }
    }

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
    @Test(arguments: [ContainerOrientation.horizontal, .vertical], [1, 2, 3, 6])
    func `Peeks leave content along either axis with fitting or impossible minima`(axis: ContainerOrientation, count: Int) {
        var container = Container(axis, .accordion, (1...count).map { .window(WindowID($0)) })
        let bounds = rect(10, 20, 12, 12)
        for active in 0..<count {
            container.active = active
            for minimum: CGFloat in [0, 8, 40] {
                let targets = container.accordionRects(in: bounds, padding: 30, minimums: Array(repeating: minimum, count: count))
                for target in targets {
                    #expect(bounds.contains(target))
                    #expect(target.width > 0 && target.height > 0)
                    let extent = axis == .horizontal ? target.width : target.height
                    #expect(extent >= min(12, max(4, minimum)))
                }
            }
        }
    }

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

    @Test func `Fullscreen width narrows the window and centres it`() {
        var ws = workspace(3, bounds: rect(0, 0, 1010, 610), gaps: Gaps(all: 10))
        let tiled = ws.layout().frames
        ws.fullscreenWidth = 0.5
        ws.focus(2)
        ws.toggleFullscreen()
        #expect(ws.layout().frames[2] == rect(258, 10, 495, 590))
        #expect(ws.layout().frames[1] == tiled[1], "the tiles underneath are not narrowed")
        ws.toggleFullscreen()
        #expect(ws.layout().frames == tiled)
    }

    @Test func `A lone window has its own centred width but fullscreen keeps its width`() {
        for algorithm in [TilingAlgorithm.dwindle(.tiles), .scrolling, .master] {
            var ws = workspace(1, bounds: rect(0, 0, 1010, 610), gaps: Gaps(all: 10), algorithm: algorithm)
            ws.fullscreenWidth = 1
            ws.loneWindowWidth = 0.75
            #expect(ws.layout().frames[1] == rect(134, 10, 743, 590))
            ws.toggleFullscreen()
            #expect(ws.layout().frames[1] == rect(10, 10, 990, 590))
            ws.fullscreenWidth = 0.5
            #expect(ws.layout().frames[1] == rect(258, 10, 495, 590))
            ws.toggleFullscreen()
            #expect(ws.layout().frames[1] == rect(134, 10, 743, 590))
        }
        var grid = workspace(1, algorithm: .fixed(rows: 1, columns: 2, expand: .columns))
        grid.loneWindowWidth = 0.75
        #expect(grid.layout().frames[1] == rect(0, 0, 500, 600), "a reserved grid cell is not narrowed")
    }

    @Test func `An unset lone window width falls back to fullscreen width`() {
        var ws = workspace(1)
        ws.fullscreenWidth = 0.6
        #expect(ws.layout().frames[1] == rect(200, 0, 600, 600))
        ws.insert(2)
        #expect(ws.layout().frames[1] == rect(0, 0, 500, 600), "two windows share the width")
        var scrolling = workspace(1, algorithm: .scrolling)
        scrolling.fullscreenWidth = 0.6
        #expect(scrolling.layout().frames[1] == rect(200, 0, 600, 600), "a lone column fills the display, so it is centred too")
        var grid = workspace(1, algorithm: .fixed(rows: 1, columns: 2, expand: .columns))
        grid.fullscreenWidth = 0.6
        #expect(grid.layout().frames[1] == rect(0, 0, 500, 600), "a lone window in a fixed grid keeps its cell")
        var whole = workspace(1)
        whole.fullscreenWidth = 1
        #expect(whole.layout().frames[1] == rect(0, 0, 1000, 600))
    }

    @Test func `Removing fullscreen window clears it`() {
        var ws = workspace(3)
        ws.toggleFullscreen()
        ws.remove(3)
        #expect(ws.fullscreen == nil)
    }
}

struct LayoutExcludingTests {
    @Test func `Excluding a window drops its frame and its place in the order`() {
        let layout = workspace(3).layout()
        let without = layout.excluding(2)
        #expect(without.frames == layout.frames.filter { $0.key != 2 })
        #expect(without.order == layout.order.filter { $0 != 2 })
    }

    @Test func `Excluding nothing or a window not laid out changes nothing`() {
        let layout = workspace(3).layout()
        #expect(layout.excluding(nil) == layout)
        #expect(layout.excluding(9) == layout)
    }
}
