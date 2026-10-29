import CoreGraphics
import Testing
@testable import DinkyLayout

/// The gutter parked windows show in, either side of the columns.
private let peek = Workspace.peek

/// A scrolling workspace with windows 1...n inserted in order, so n is focused and in view. Its columns go
/// between 0 and 1000, inside the gutters, when it has no gaps or walls.
private func strip(_ n: Int, width: Double = 0.5, gaps: Gaps = .zero, walls: Set<Direction> = []) -> Workspace {
    var ws = Workspace(bounds: rect(-peek, 0, 1000 + 2 * peek, 600), gaps: gaps, algorithm: .scrolling)
    ws.columnWidth = width
    ws.walls = walls
    for id in 0..<n { ws.insert(WindowID(id + 1)) }
    return ws
}

/// Left edges of the windows as the strip lays them out, on screen or not.
private func lefts(_ ws: Workspace) -> [CGFloat] {
    let frames = ws.tiledLayout().frames
    return ws.windows.map { frames[$0]!.minX }
}

struct ScrollingGeometryTests {
    @Test func `A lone column fills the screen`() {
        #expect(strip(1).layout().frames[1] == rect(-peek, 0, 1000 + 2 * peek, 600))
    }

    @Test func `Columns that fit are centred`() {
        let ws = strip(2, width: 0.49)
        #expect(ws.layout().frames[1] == rect(10, 0, 490, 600))
        #expect(ws.layout().frames[2] == rect(500, 0, 490, 600))
    }

    @Test func `Inner and outer gaps match on both sides`() {
        let ws = strip(2, width: 0.49, gaps: Gaps(all: 10))
        #expect(ws.layout().frames[1] == rect(15, 10, 480, 580))
        #expect(ws.layout().frames[2] == rect(505, 10, 480, 580))
    }

    @Test func `A new column opens right of the focused one and scrolls into view`() {
        var ws = strip(3)
        #expect(lefts(ws) == [-475, 25, 525], "the last column reaches into the empty gutter")
        ws.focus(1)
        ws.insert(4)
        #expect(ws.windows == [1, 4, 2, 3])
        #expect(lefts(ws) == [-25, 475, 975, 1475])
    }

    @Test func `Focusing scrolls as little as shows the column`() {
        var ws = strip(4)
        #expect(lefts(ws) == [-975, -475, 25, 525])
        ws.focus(.left)
        #expect(lefts(ws) == [-975, -475, 25, 525], "already in view")
        ws.focus(.left)
        #expect(lefts(ws) == [-500, 0, 500, 1000])
        ws.focus(.right)
        #expect(lefts(ws) == [-500, 0, 500, 1000], "already in view")
    }

    @Test func `Scrolled out windows hang off the edge with a sliver showing`() {
        var ws = strip(4)
        ws.focus(2)
        let frames = ws.layout().frames
        #expect(frames[1]!.maxX == 0, "peek showing, in the left gutter")
        #expect(frames[2]!.minX == 0)
        #expect(frames[4]!.minX == 1000, "peek showing, in the right gutter")
    }

    @Test func `Columns keep an inner gap from the slivers`() {
        var ws = strip(4, gaps: Gaps(all: 10))
        ws.focus(2)
        let frames = ws.layout().frames
        #expect(frames[1]!.maxX == 0)
        #expect(frames[2]!.minX == 10)
        #expect(frames[3]!.maxX == 990)
        #expect(frames[4]!.minX == 1000)
    }

    @Test func `The columns in view stay a gap from their neighbours, slack or not`() {
        var ws = strip(3, width: 0.49, gaps: Gaps(all: 10))
        var frames = ws.layout().frames
        #expect(frames[1]!.maxX == 40, "the slack widens the sliver")
        #expect(frames[2]!.minX == 50)
        #expect(frames[3]!.maxX == 1015, "the end column reaches the outer gap")
        ws.focus(1)
        frames = ws.layout().frames
        #expect(frames[1]!.minX == -15)
        #expect(frames[3]!.minX - frames[2]!.maxX == 10)
    }

    @Test func `At a wall scrolled out windows stay on screen behind the ones in view`() {
        var ws = strip(4, walls: [.left, .right])
        ws.focus(2)
        let layout = ws.layout()
        #expect(layout.frames[2]!.minX == -peek, "no gutter at a wall")
        #expect(layout.frames[1]!.minX == -peek)
        #expect(layout.frames[4]!.minX == 500)
        #expect(layout.order == [2, 1, 3, 4])
    }

    @Test func `Partly visible columns stay where the strip puts them`() {
        var ws = strip(3, width: 0.4)
        ws.focus(1)
        #expect(ws.layout().frames[3]!.minX == 775)
        #expect(!ws.isInView(3))
        #expect(ws.isInView(2))
    }

    @Test func `A column grows to its windows minimum width`() {
        var ws = strip(2)
        ws.minimumSizes[1] = CGSize(width: 700, height: 0)
        ws.focus(1)
        #expect(ws.layout().frames[1]!.width == 700)
        #expect(lefts(ws) == [-25, 675])
    }

    @Test func `Closing the last column scrolls back`() {
        var ws = strip(3)
        ws.remove(3)
        #expect(ws.focused == 2)
        #expect(lefts(ws) == [0, 500])
    }

    @Test func `The strip stays the root with one column left`() {
        var ws = strip(2)
        ws.join(.left)
        #expect(shape(ws.root) == "h[v[1 2]]")
        #expect(ws.layout().frames[1] == rect(-peek, 0, 1000 + 2 * peek, 300))
    }
}

struct ScrollingCommandTests {
    @Test func `Move swaps a lone window's column with its neighbour, width and all`() {
        var ws = strip(3)
        ws.focus(1)
        #expect(ws.resize(by: 100) == true)
        #expect(ws.move(.right) == true)
        #expect(ws.windows == [2, 1, 3])
        #expect(ws.tiledLayout().frames[1]!.width == 600)
        var single = strip(1)
        #expect(single.move(.right) == false)
    }

    @Test func `Move left or right takes a window out of a shared column`() {
        var ws = strip(3)
        ws.focus(2)
        ws.join(.left)
        #expect(shape(ws.root) == "h[v[1 2] 3]")
        #expect(ws.move(.right) == true)
        #expect(shape(ws.root) == "h[1 2 3]")
        ws.join(.left)
        #expect(ws.move(.left) == true)
        #expect(shape(ws.root) == "h[2 1 3]")
    }

    @Test func `Move up and down stay within the column`() {
        var ws = strip(2)
        ws.join(.left)
        #expect(ws.move(.up) == true)
        #expect(shape(ws.root) == "h[v[2 1]]")
        #expect(ws.move(.up) == false)
        #expect(shape(ws.root) == "h[v[2 1]]")
        var lone = strip(2)
        #expect(lone.move(.down) == false)
    }

    @Test func `Join takes the width of the column it joins`() {
        var ws = strip(3)
        ws.focus(3)
        #expect(ws.resize(by: 200) == true)
        ws.focus(2)
        #expect(ws.join(.right) == true)
        #expect(shape(ws.root) == "h[1 v[2 3]]")
        #expect(ws.tiledLayout().frames[2]!.width == 700)
    }

    @Test func `Join from deep in a column goes into the neighbouring column`() {
        var ws = strip(5)
        let nested = Container(.horizontal, .tiles, [.window(3), .window(4)])
        ws.root = Container(.horizontal, .tiles, [.window(1), .container(Container(.vertical, .tiles, [.window(2), .container(nested)])), .window(5)])
        ws.columnWidths[1] = 0.3
        ws.focus(4)
        #expect(ws.join(.left) == true)
        #expect(shape(ws.root) == "h[v[1 4] v[2 3] 5]")
        #expect(ws.tiledLayout().frames[4]!.width == 300, "the width of the column it joined")
    }

    @Test func `Resizing width changes the column, height the stack`() {
        var ws = strip(2)
        #expect(ws.resize(by: 100, along: .horizontal) == true)
        #expect(ws.tiledLayout().frames[2]!.width == 600)
        #expect(ws.resize(by: 100, along: .vertical) == false, "a lone window has no stack")
        ws.join(.left)
        #expect(ws.resize(by: 60, along: .vertical) == true)
        #expect(ws.tiledLayout().frames[2]!.height == 360)
    }

    @Test func `A lone column cannot be resized out of sight`() {
        var ws = strip(1)
        #expect(ws.resize(by: 100) == false)
        ws.insert(2)
        #expect(ws.tiledLayout().frames[1]!.width == 500)
    }

    @Test func `Dragging an edge sets the column width`() {
        var ws = strip(2)
        #expect(ws.resize(2, to: CGSize(width: 400, height: 600), moving: [.left]) == true)
        #expect(ws.tiledLayout().frames[2]!.width == 400)
    }

    @Test func `Balance resets every column to the default width`() {
        var ws = strip(2)
        ws.resize(by: 200)
        ws.balanceSizes()
        #expect(lefts(ws) == [0, 500])
    }

    @Test func `Flatten gives every window a column of its own`() {
        var ws = strip(3)
        ws.join(.left)
        ws.flatten()
        #expect(shape(ws.root) == "h[1 2 3]")
    }

    @Test func `Layout commands leave the strip alone`() {
        var ws = strip(2)
        ws.setMode(.accordion)
        ws.setOrientation(.vertical)
        #expect(shape(ws.root) == "h[1 2]")
        ws.join(.left)
        ws.setMode(.accordion)
        #expect(shape(ws.root) == "h[av[1 2]]")
    }

    @Test func `Switching to scrolling keeps the windows in order`() {
        var ws = workspace(3)
        ws.columnWidth = 0.5
        ws.setAlgorithm(.scrolling)
        #expect(shape(ws.root) == "h[1 2 3]")
        #expect(lefts(ws) == [-425, 50, 525], "columns 475 wide between the gutters")
    }

    @Test func `A swipe goes to the next column until the last`() {
        var ws = strip(3)
        #expect(ws.swipeTarget(.left) == 2)
        #expect(ws.swipeTarget(.right) == nil, "past the last column the swipe switches Space")
        ws.focus(1)
        #expect(ws.swipeTarget(.left) == nil)
        #expect(ws.swipeTarget(.right) == 2)
        #expect(ws.swipeTarget(.up) == nil && ws.swipeTarget(.down) == nil, "a column of one window")
        #expect(strip(1).swipeTarget(.left) == nil && strip(1).swipeTarget(.right) == nil)
    }

    @Test func `A swipe leaves a stacked column for its neighbour, or moves within it`() {
        var ws = strip(3)
        ws.join(.left)
        #expect(shape(ws.root) == "h[1 v[2 3]]")
        #expect(ws.swipeTarget(.right) == nil)
        #expect(ws.swipeTarget(.left) == 1)
        #expect(ws.swipeTarget(.up) == 2)
        #expect(ws.swipeTarget(.down) == nil, "past the bottom the swipe opens App Exposé")
    }
}
