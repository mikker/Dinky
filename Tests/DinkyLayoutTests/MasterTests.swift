import CoreGraphics
import Testing
@testable import DinkyLayout

/// A master workspace 1000 by 600 without gaps, windows 1...n inserted in order, so 1 is the master and n is focused.
private func master(_ n: Int, _ side: MasterSide = .left) -> Workspace {
    var ws = Workspace(bounds: rect(0, 0, 1000, 600), algorithm: .master)
    ws.setMasterSide(side)
    for id in 0..<n { ws.insert(WindowID(id + 1)) }
    return ws
}

private func frames(_ ws: Workspace) -> [WindowID: CGRect] { ws.layout().frames }

struct MasterGeometryTests {
    @Test func `A lone window fills the screen`() {
        #expect(frames(master(1))[1] == rect(0, 0, 1000, 600))
    }

    @Test func `The second window opens the stack beside the master`() {
        let f = frames(master(2))
        #expect(f[1] == rect(0, 0, 600, 600))
        #expect(f[2] == rect(600, 0, 400, 600))
    }

    @Test func `Later windows join the bottom of the stack`() {
        var ws = master(3)
        ws.focus(2)
        ws.insert(4)
        #expect(ws.windows == [1, 2, 3, 4])
        let f = frames(ws)
        #expect(f[1] == rect(0, 0, 600, 600))
        #expect(f[2] == rect(600, 0, 400, 200))
        #expect(f[4] == rect(600, 400, 400, 200))
    }

    @Test func `The right side puts the master on the right`() {
        let f = frames(master(3, .right))
        #expect(f[1] == rect(400, 0, 600, 600))
        #expect(f[2] == rect(0, 0, 400, 300))
        #expect(f[3] == rect(0, 300, 400, 300))
    }

    @Test func `Gaps go between the master and the stack`() {
        var ws = Workspace(bounds: rect(0, 0, 1000, 600), gaps: Gaps(all: 10), algorithm: .master)
        ws.insert(1)
        ws.insert(2)
        #expect(frames(ws)[1] == rect(10, 10, 582, 580))
        #expect(frames(ws)[2] == rect(602, 10, 388, 580))
    }
}

struct MasterLifecycleTests {
    @Test func `An emptied stack gives the master the whole screen`() {
        var ws = master(2)
        ws.remove(2)
        #expect(frames(ws)[1] == rect(0, 0, 1000, 600))
        ws.insert(3)
        #expect(frames(ws)[3] == rect(600, 0, 400, 600), "the stack opens again")
    }

    @Test func `Closing the master promotes the top of the stack`() {
        var ws = master(3)
        ws.remove(1)
        #expect(ws.windows == [2, 3])
        #expect(frames(ws)[2] == rect(0, 0, 600, 600))
        #expect(frames(ws)[3] == rect(600, 0, 400, 600))
    }

    @Test func `Closing the master with one window stacked leaves that window alone`() {
        var ws = master(2)
        ws.remove(1)
        #expect(frames(ws)[2] == rect(0, 0, 1000, 600))
        #expect(ws.focused == 2)
    }

    @Test func `Closing a stacked window keeps the others in order`() {
        var ws = master(4)
        ws.remove(3)
        #expect(ws.windows == [1, 2, 4])
        #expect(frames(ws)[4] == rect(600, 300, 400, 300))
    }

    @Test func `A reopened stack takes the configured share again`() {
        var ws = master(2)
        ws.focus(1)
        let changed1 = ws.resize(by: 100)
        #expect(changed1)
        #expect(frames(ws)[1]!.width == 700)
        ws.remove(2)
        ws.insert(3)
        #expect(frames(ws)[1]!.width == 600)
    }

    @Test func `Closing the master hands the focus to the window promoted`() {
        var ws = master(4)
        ws.focus(1)
        ws.remove(1)
        #expect(ws.focused == 2)
        #expect(frames(ws)[2] == rect(0, 0, 600, 600))
        #expect(frames(ws)[4] == rect(600, 300, 400, 300))
    }

    @Test func `A master on the right keeps its side as windows close`() {
        var ws = master(3, .right)
        ws.remove(1)
        #expect(frames(ws)[2] == rect(400, 0, 600, 600), "the top of the stack takes the master's place")
        #expect(frames(ws)[3] == rect(0, 0, 400, 600))
        var emptied = master(2, .right)
        emptied.remove(2)
        #expect(frames(emptied)[1] == rect(0, 0, 1000, 600))
        emptied.insert(3)
        #expect(frames(emptied)[3] == rect(0, 0, 400, 600), "the stack opens again on the left")
        var promoted = master(2, .right)
        promoted.remove(1)
        #expect(frames(promoted)[2] == rect(0, 0, 1000, 600))
    }

    @Test func `A tab replacing a window keeps its place in the master layout`() {
        var ws = master(3)
        ws.focus(1)
        ws.replace(1, with: 9)
        ws.replace(3, with: 8)
        #expect(ws.masterWindow == 9)
        #expect(ws.focused == 9)
        #expect(frames(ws)[9] == rect(0, 0, 600, 600))
        #expect(frames(ws)[8] == rect(600, 300, 400, 300))
        ws.insert(10)
        #expect(ws.windows == [9, 2, 8, 10], "new windows still join the stack")
    }

    @Test func `Every window closing leaves an empty master workspace`() {
        var ws = master(3)
        for id: WindowID in [2, 1, 3] { ws.remove(id) }
        #expect(ws.windows.isEmpty)
        ws.insert(4)
        #expect(frames(ws)[4] == rect(0, 0, 1000, 600))
    }
}

struct MasterCommandTests {
    @Test func `Swapping a stacked window with the master keeps both tiles and the focus`() {
        var ws = master(3)
        ws.focus(3)
        let changed2 = ws.swapWithMaster()
        #expect(changed2)
        #expect(ws.windows == [3, 2, 1])
        #expect(ws.focused == 3)
        #expect(frames(ws)[3] == rect(0, 0, 600, 600))
    }

    @Test func `Swapping from the master trades it with the top of the stack`() {
        var ws = master(3)
        ws.focus(1)
        let changed3 = ws.swapWithMaster()
        #expect(changed3)
        #expect(ws.windows == [2, 1, 3])
        #expect(ws.focused == 1)
    }

    @Test func `Swapping works the same with the master on the right`() {
        var ws = master(3, .right)
        ws.focus(3)
        let changed = ws.swapWithMaster()
        #expect(changed)
        #expect(ws.masterWindow == 3)
        #expect(ws.focused == 3)
        #expect(frames(ws)[3] == rect(400, 0, 600, 600))
        #expect(frames(ws)[1] == rect(0, 300, 400, 300))
    }

    @Test func `Swapping with nothing stacked does nothing`() {
        var ws = master(1)
        let changed4 = ws.swapWithMaster()
        #expect(!changed4)
        var tiles = Workspace(bounds: rect(0, 0, 1000, 600))
        tiles.insert(1)
        tiles.insert(2)
        let changed5 = tiles.swapWithMaster()
        #expect(!changed5, "only a master workspace has a master")
    }

    @Test func `The stack switches between tiles and a vertical accordion`() {
        var ws = master(3)
        ws.focus(1)
        ws.setLayout(.accordion, nil)
        #expect(ws.container(of: 3)?.mode == .accordion)
        #expect(ws.containerAxis(of: 3) == .vertical)
        #expect(ws.container(of: 1)?.mode == .tiles, "the master stays a tile")
        ws.remove(2)
        ws.remove(3)
        ws.insert(4)
        #expect(ws.container(of: 4)?.mode == .accordion, "a stack opened again keeps its mode")
        ws.setLayout(.tiles, nil)
        #expect(ws.container(of: 4)?.mode == .tiles)
    }

    @Test func `Layout commands see the stack from every window`() {
        var ws = master(1)
        #expect(ws.layoutContainer(of: 1)?.container.mode == .tiles)
        #expect(ws.layoutContainer(of: 1)?.axis == .vertical, "a stack not open yet")
        ws.setLayout(.accordion, nil)
        #expect(ws.layoutContainer(of: 1)?.container.mode == .accordion)
        ws.insert(2)
        #expect(ws.layoutContainer(of: 1)?.container.mode == .accordion)
        #expect(ws.layoutContainer(of: 2)?.container.mode == .accordion)
        var tiles = Workspace(bounds: rect(0, 0, 1000, 600))
        tiles.insert(1)
        #expect(tiles.layoutContainer(of: 1)?.container == tiles.container(of: 1), "elsewhere, the window's own container")
        #expect(ws.layoutContainer(of: 9) == nil)
    }

    @Test func `An auto-orienting accordion stack still runs top to bottom`() {
        var ws = Workspace(bounds: rect(0, 0, 3000, 600), autoOrientAccordions: true, algorithm: .master)
        for id: WindowID in [1, 2, 3] { ws.insert(id) }
        ws.setLayout(.accordion, nil)
        #expect(ws.containerAxis(of: 2) == .vertical)
    }

    @Test func `Moving swaps with the neighbour and keeps the shape`() {
        var ws = master(3)
        ws.focus(1)
        let changed6 = ws.move(.right)
        #expect(changed6)
        #expect(ws.windows == [3, 2, 1], "the stack's most recent window comes across")
        let changed7 = ws.move(.down)
        #expect(!changed7, "nothing below the bottom of the stack")
        let changed8 = ws.move(.up)
        #expect(changed8)
        #expect(ws.windows == [3, 1, 2])
        #expect(!master(2).withFocus(1).moved(.left))
        ws.insert(4)
        #expect(ws.container(of: 4) == ws.container(of: 2), "new windows still join the stack")
    }

    @Test func `Balancing restores the configured share and evens the stack`() {
        var ws = master(3)
        ws.focus(1)
        ws.resize(by: 100)
        ws.focus(2)
        ws.resize(by: 100)
        ws.balanceSizes()
        let f = frames(ws)
        #expect(f[1] == rect(0, 0, 600, 600))
        #expect(f[2] == rect(600, 0, 400, 300))
    }

    @Test func `Switching to master makes the focused window the master`() {
        var ws = Workspace(bounds: rect(0, 0, 1000, 600))
        for id: WindowID in [1, 2, 3] { ws.insert(id) }
        ws.focus(2)
        ws.setAlgorithm(.master)
        #expect(ws.windows == [2, 1, 3], "the others stack in their order")
        #expect(ws.focused == 2)
        #expect(frames(ws)[2] == rect(0, 0, 600, 600))
        #expect(ws.container(of: 1)?.mode == .tiles, "tiled windows stack as tiles")
        ws.focus(3)
        ws.setMasterSide(.right)
        #expect(frames(ws)[2] == rect(400, 0, 600, 600), "changing sides keeps the master")
        ws.setAlgorithm(.dwindle(.tiles))
        #expect(ws.windows == [2, 1, 3], "the master first")
        #expect(ws.focused == 3)
    }

    @Test func `Switching from scrolling lays the columns out as master and stack`() {
        var ws = Workspace(bounds: rect(0, 0, 1000, 600), algorithm: .scrolling)
        for id: WindowID in [1, 2, 3] { ws.insert(id) }
        ws.focus(2)
        ws.setAlgorithm(.master)
        #expect(ws.windows == [2, 1, 3])
        #expect(frames(ws)[2] == rect(0, 0, 600, 600))
        #expect(frames(ws)[1] == rect(600, 0, 400, 300))
        #expect(frames(ws)[3] == rect(600, 300, 400, 300))
        #expect(ws.container(of: 1)?.mode == .tiles)
    }

    @Test func `Windows shown as an accordion stack as one`() {
        var ws = Workspace(bounds: rect(0, 0, 1000, 600), algorithm: .dwindle(.accordion))
        for id: WindowID in [1, 2, 3] { ws.insert(id) }
        ws.focus(1)
        ws.setAlgorithm(.master)
        #expect(ws.windows == [1, 2, 3])
        #expect(ws.container(of: 2)?.mode == .accordion)
        #expect(ws.containerAxis(of: 2) == .vertical)
    }

    @Test func `The stack takes the mode most of the other windows had`() {
        var ws = Workspace(bounds: rect(0, 0, 1000, 600))
        for id: WindowID in [1, 2, 3] { ws.insert(id) }
        ws.focus(2)
        ws.setLayout(.accordion, nil)
        #expect(ws.container(of: 3)?.mode == .accordion, "2 and 3 share an accordion beside 1")
        ws.focus(1)
        ws.setAlgorithm(.master)
        #expect(ws.container(of: 2)?.mode == .accordion)
        var mixed = Workspace(bounds: rect(0, 0, 1000, 600))
        for id: WindowID in [1, 2, 3] { mixed.insert(id) }
        mixed.focus(2)
        mixed.setLayout(.accordion, nil)
        mixed.setAlgorithm(.master)
        #expect(mixed.container(of: 1)?.mode == .tiles, "one accordion window against one tiled one is no majority")
    }

    @Test func `Flattening rebuilds a shape a join broke`() {
        var ws = master(3)
        ws.focus(3)
        let changed9 = ws.join(.left)
        #expect(changed9)
        ws.flatten()
        #expect(ws.windows == [1, 3, 2], "in the order the broken tree had")
        #expect(frames(ws)[1] == rect(0, 0, 600, 600))
        #expect(frames(ws)[2] == rect(600, 300, 400, 300))
    }

    @Test func `After a join, new windows open beside the focused one`() {
        var ws = master(3)
        ws.focus(3)
        let joined = ws.join(.left)
        #expect(joined)
        #expect(!ws.isMasterTree)
        ws.insert(4)
        #expect(ws.container(of: 4) == ws.container(of: 3), "like a fixed template a tree command changed")
        #expect(frames(ws)[3] == rect(0, 300, 300, 300))
        #expect(frames(ws)[4] == rect(300, 300, 300, 300))
        #expect(frames(ws)[2] == rect(600, 0, 400, 600), "the rest stays put")
    }

    @Test func `Switching from master to scrolling keeps the master order`() {
        var ws = master(3)
        ws.focus(3)
        let swapped = ws.swapWithMaster()
        #expect(swapped)
        #expect(ws.windows == [3, 2, 1])
        ws.setAlgorithm(.scrolling)
        #expect(ws.windows == [3, 2, 1], "the master first, then the stack from the top")
        #expect(ws.focused == 3)
    }

    @Test func `Leaving master for dwindle keeps the stack's mode`() {
        var ws = Workspace(bounds: rect(0, 0, 1000, 600), algorithm: .master)
        for id: WindowID in [1, 2, 3] { ws.insert(id) }
        ws.setLayout(.accordion, nil)
        ws.setAlgorithm(.dwindle(.tiles))
        #expect(ws.container(of: 1)?.mode == .accordion, "the windows were shown as an accordion")
        var tiled = Workspace(bounds: rect(0, 0, 1000, 600), algorithm: .master)
        for id: WindowID in [1, 2, 3] { tiled.insert(id) }
        tiled.setAlgorithm(.dwindle(.accordion))
        #expect(tiled.container(of: 1)?.mode == .tiles, "an accordion config does not surprise")
        let widths = [1, 2, 3].map { frames(tiled)[$0]!.width }
        #expect(widths.allSatisfy { abs($0 - widths[0]) <= 1 }, "equal shares again: \(widths)")
        tiled.flatten()
        #expect(tiled.container(of: 1)?.mode == .accordion, "flatten rebuilds from the config")
    }

    @Test func `Switching from master on the right to dwindle puts the master first`() {
        var ws = master(3, .right)
        #expect(ws.windows == [2, 3, 1], "the stack comes first in the tree")
        ws.setAlgorithm(.dwindle(.tiles))
        #expect(ws.windows == [1, 2, 3])
        #expect(ws.focused == 3)
    }

    @Test func `A fullscreen window covers the master layout and leaves it as it was`() {
        var ws = master(3)
        ws.focus(2)
        ws.toggleFullscreen()
        #expect(frames(ws)[2] == rect(0, 0, 1000, 600))
        #expect(ws.masterWindow == 1)
        #expect(ws.layout().order.first == 2)
        ws.toggleFullscreen()
        #expect(frames(ws)[1] == rect(0, 0, 600, 600))
        #expect(frames(ws)[2] == rect(600, 0, 400, 300))
    }

    @Test func `Swapping with the master ends fullscreen`() {
        var ws = master(3)
        ws.focus(2)
        ws.toggleFullscreen()
        let swapped = ws.swapWithMaster()
        #expect(swapped)
        #expect(ws.fullscreen == nil)
        #expect(frames(ws)[2] == rect(0, 0, 600, 600))
    }

    @Test func `A window opening over a fullscreen one joins the stack and ends fullscreen`() {
        var ws = master(2)
        ws.focus(1)
        ws.toggleFullscreen()
        ws.insert(3)
        #expect(ws.fullscreen == nil)
        #expect(ws.masterWindow == 1)
        #expect(frames(ws)[3] == rect(600, 300, 400, 300))
    }

    @Test func `Resizing the master changes its share but not the configured size`() {
        var ws = master(3)
        ws.focus(2)
        let widened = ws.resize(by: -100, along: .horizontal)
        #expect(widened, "a stacked window's width is the master's share too")
        #expect(frames(ws)[1] == rect(0, 0, 700, 600))
        #expect(frames(ws)[2] == rect(700, 0, 300, 300))
        #expect(ws.masterSize == 0.6)
        let dragged = ws.resize(1, to: CGSize(width: 550, height: 600), moving: [.right])
        #expect(dragged)
        #expect(frames(ws)[1] == rect(0, 0, 550, 600))
        #expect(frames(ws)[3] == rect(550, 300, 450, 300))
        ws.balanceSizes()
        #expect(frames(ws)[1] == rect(0, 0, 600, 600))
    }

    @Test func `A new size from the config waits for balance or a stack opened again`() {
        var ws = master(2)
        ws.masterSize = 0.5
        #expect(frames(ws)[1] == rect(0, 0, 600, 600), "an open stack keeps its share")
        ws.balanceSizes()
        #expect(frames(ws)[1] == rect(0, 0, 500, 600))
        ws.remove(2)
        ws.masterSize = 0.7
        ws.insert(3)
        #expect(frames(ws)[1] == rect(0, 0, 700, 600))
    }

    @Test func `A new side from the config keeps the master, the stack and its mode`() {
        var ws = master(3)
        ws.setLayout(.accordion, nil)
        ws.focus(2)
        ws.setMasterSide(.right)
        #expect(ws.masterWindow == 1)
        #expect(ws.focused == 2)
        #expect(frames(ws)[1] == rect(400, 0, 600, 600))
        #expect(ws.container(of: 2)?.mode == .accordion)
        #expect(ws.container(of: 2) == ws.container(of: 3))
        ws.setMasterSide(.left)
        #expect(frames(ws)[1] == rect(0, 0, 600, 600))
        #expect(ws.windows == [1, 2, 3])
    }

    @Test func `A window floated leaves the master layout and tiles again at the bottom of the stack`() {
        // The coordinator takes a floating window out of the workspace and inserts it again when it tiles.
        var ws = master(3)
        ws.remove(1)
        #expect(ws.masterWindow == 2, "floating the master promotes the top of the stack")
        ws.insert(1)
        #expect(ws.windows == [2, 3, 1])
        #expect(frames(ws)[1] == rect(600, 300, 400, 300))
        ws.remove(3)
        ws.remove(1)
        #expect(frames(ws)[2] == rect(0, 0, 1000, 600), "floating the whole stack gives the master the screen")
    }
}

private extension Workspace {
    func withFocus(_ id: WindowID) -> Workspace {
        var copy = self
        copy.focus(id)
        return copy
    }

    func moved(_ direction: Direction) -> Bool {
        var copy = self
        return copy.move(direction)
    }
}

struct MasterCenterTests {
    @Test func `With one window stacked the centred master takes the left`() {
        let f = frames(master(2, .center))
        #expect(f[1] == rect(0, 0, 600, 600))
        #expect(f[2] == rect(600, 0, 400, 600))
    }

    @Test func `The second stacked window centres the master and opens the left stack`() {
        let f = frames(master(3, .center))
        #expect(f[3] == rect(0, 0, 200, 600))
        #expect(f[1] == rect(200, 0, 600, 600))
        #expect(f[2] == rect(800, 0, 200, 600), "the first stacked window stays on the right")
    }

    @Test func `New windows alternate between the stacks, right first`() {
        let ws = master(5, .center)
        #expect(ws.windows == [3, 5, 1, 2, 4])
        #expect(ws.masterOrder == [1, 2, 3, 4, 5])
        let f = frames(ws)
        #expect(f[2] == rect(800, 0, 200, 300))
        #expect(f[4] == rect(800, 300, 200, 300))
        #expect(f[5] == rect(0, 300, 200, 300))
    }

    @Test func `Gaps go between the stacks and the centred master`() {
        var ws = Workspace(bounds: rect(0, 0, 1000, 600), gaps: Gaps(all: 10), algorithm: .master)
        ws.setMasterSide(.center)
        for id: WindowID in [1, 2, 3] { ws.insert(id) }
        let f = frames(ws)
        #expect(f[3] == rect(10, 10, 192, 580))
        #expect(f[1] == rect(212, 10, 576, 580))
        #expect(f[2] == rect(798, 10, 192, 580))
    }

    @Test func `Closing a window keeps the stacks even`() {
        var ws = master(4, .center)
        ws.remove(3)
        #expect(ws.windows == [4, 1, 2], "the bottom of the right stack opens the left one again")
        #expect(frames(ws)[4] == rect(0, 0, 200, 600))
        #expect(frames(ws)[1] == rect(200, 0, 600, 600))
        var five = master(5, .center)
        five.remove(2)
        five.remove(4)
        #expect(five.windows == [3, 1, 5], "the left stack hands its bottom to the emptied right one")
        var master5 = master(5, .center)
        master5.remove(1)
        master5.remove(4)
        #expect(master5.windows == [3, 2, 5], "so does it when the right one empties for a closing master")
    }

    @Test func `With one window left stacked the master goes back to the left`() {
        var ws = master(3, .center)
        ws.remove(3)
        #expect(frames(ws)[1] == rect(0, 0, 600, 600))
        #expect(frames(ws)[2] == rect(600, 0, 400, 600))
        var right = master(3, .center)
        right.remove(2)
        #expect(right.windows == [1, 3], "the left stack comes round to the right")
        #expect(frames(right)[3] == rect(600, 0, 400, 600))
        right.insert(4)
        #expect(right.windows == [4, 1, 3])
    }

    @Test func `Closing the centred master promotes the top of the right stack`() {
        var ws = master(4, .center)
        ws.focus(1)
        ws.remove(1)
        #expect(ws.focused == 2)
        #expect(ws.windows == [3, 2, 4])
        #expect(frames(ws)[2] == rect(200, 0, 600, 600))
        var three = master(3, .center)
        three.remove(1)
        #expect(three.windows == [2, 3])
        #expect(frames(three)[2] == rect(0, 0, 600, 600))
    }

    @Test func `Resizing the centred master widens it into both stacks and survives the row changing`() {
        var ws = master(3, .center)
        ws.focus(1)
        let widened = ws.resize(by: 100, along: .horizontal)
        #expect(widened)
        #expect(frames(ws)[1] == rect(150, 0, 700, 600))
        #expect(frames(ws)[3] == rect(0, 0, 150, 600))
        ws.remove(3)
        #expect(frames(ws)[1] == rect(0, 0, 700, 600), "the master keeps its share beside one stack")
        ws.insert(4)
        #expect(frames(ws)[1] == rect(150, 0, 700, 600))
        ws.balanceSizes()
        #expect(frames(ws)[1] == rect(200, 0, 600, 600))
    }

    @Test func `Layout commands change both stacks`() {
        var ws = master(2, .center)
        ws.setLayout(.accordion, nil)
        ws.insert(3)
        #expect(ws.container(of: 3)?.mode == .accordion, "a stack opened later takes the mode")
        ws.setLayout(.tiles, nil)
        #expect(ws.container(of: 2)?.mode == .tiles)
        #expect(ws.container(of: 3)?.mode == .tiles)
    }

    @Test func `Swapping from the centred master trades it with the top of the right stack`() {
        var ws = master(4, .center)
        ws.focus(1)
        let swapped = ws.swapWithMaster()
        #expect(swapped)
        #expect(ws.masterWindow == 2)
        #expect(ws.focused == 1)
        #expect(frames(ws)[1] == rect(800, 0, 200, 300))
    }

    @Test func `Focus and move cross the master between the stacks`() {
        var ws = master(3, .center)
        ws.focus(1)
        let left = ws.focus(.left)
        #expect(left)
        #expect(ws.focused == 3)
        let moved = ws.move(.right)
        #expect(moved)
        #expect(ws.masterWindow == 3, "move swaps with the neighbour, keeping the shape")
        #expect(ws.windows == [1, 3, 2])
    }

    @Test func `Switching the side to center and back keeps the master order`() {
        var ws = master(4)
        ws.setMasterSide(.center)
        #expect(ws.windows == [3, 1, 2, 4])
        #expect(frames(ws)[1] == rect(200, 0, 600, 600))
        ws.setMasterSide(.left)
        #expect(ws.windows == [1, 2, 3, 4])
    }
}
