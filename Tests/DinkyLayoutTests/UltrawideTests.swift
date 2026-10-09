import CoreGraphics
import Testing
@testable import DinkyLayout

struct UltrawideTests {
    private func wide(_ count: Int = 1) -> Workspace {
        var ws = workspace(count, bounds: rect(-908, -1410, 3440, 1400), gaps: Gaps(all: 8))
        ws.displayAspectRatio = 3440 / 1440
        ws.windowMaxAspectRatio = 1.5
        return ws
    }

    private func assertLimited(_ ws: Workspace) {
        for (id, frame) in ws.layout().frames {
            #expect(frame.width <= max(frame.height * 1.5, ws.minimumSizes[id]?.width ?? 0) + 1)
            #expect(frame.width > 0 && frame.height > 0)
        }
    }

    @Test func `Detection uses the full monitor and the limit is opt in`() {
        for (ratio, active) in [(1920.0 / 1080, false), (2.299, false), (2.3, true), (3440.0 / 1440, true), (5120.0 / 1440, true), (1440.0 / 3440, false)] {
            var ws = wide()
            ws.displayAspectRatio = ratio
            #expect((ws.layout().frames[1]!.width < 3424) == active)
        }
        var ws = wide()
        ws.windowMaxAspectRatio = 0
        #expect(ws.layout().frames[1] == rect(-900, -1402, 3424, 1384))
        ws.windowMaxAspectRatio = 1.5
        ws.ultrawideMinAspectRatio = 3
        #expect(ws.layout().frames[1]!.width == 3424)
    }

    @Test func `Alignment uses available area after asymmetric gaps`() {
        var ws = wide()
        ws.gaps = Gaps(horizontal: 8, vertical: 8, top: 30, bottom: 10, left: 40, right: 80)
        let available = ws.gaps.inset(ws.bounds)
        for alignment in [TilingAlignment.left, .center, .right] {
            ws.tilingAlignment = alignment
            let frame = ws.layout().frames[1]!
            assertLimited(ws)
            #expect(frame.height == available.height)
            #expect(frame.minY == available.minY)
            switch alignment {
            case .left: #expect(abs(frame.minX - available.minX) <= 1)
            case .center: #expect(abs(frame.midX - available.midX) <= 1)
            case .right: #expect(abs(frame.maxX - available.maxX) <= 1)
            }
        }
    }

    @Test func `Two windows on a very wide monitor still have a cap`() {
        var ws = wide(2)
        ws.bounds.size.width = 5120
        ws.displayAspectRatio = 5120 / 1440
        let tree = ws.root
        assertLimited(ws)
        let frames = ws.layout().frames
        #expect(frames[1]!.maxX + 8 == frames[2]!.minX)
        #expect(frames[1]!.width > 2000)
        #expect(ws.root == tree)
        ws.insert(3)
        assertLimited(ws)
        ws.remove(3)
        assertLimited(ws)
    }

    @Test func `Stacked tiles constrain width using their own height`() {
        var ws = wide(3)
        ws.root = Container(.horizontal, .tiles, [.window(1), .container(Container(.vertical, .tiles, [.window(2), .window(3)]))])
        assertLimited(ws)
        let frames = ws.layout().frames
        #expect(frames[2]!.height < frames[1]!.height)
        #expect(frames[2]!.width < 1100)
        #expect(frames[2]!.maxY + 8 == frames[3]!.minY)
    }

    @Test func `Minimum widths take priority and fullscreen bypasses the cap`() {
        var ws = wide()
        ws.minimumSizes[1] = CGSize(width: 2500, height: 400)
        #expect(ws.layout().frames[1]!.width >= 2500)
        ws.toggleFullscreen()
        #expect(ws.layout().frames[1] == ws.gaps.inset(ws.bounds))
        ws.toggleFullscreen()
        #expect(ws.layout().frames[1]!.width < 2502)
        ws.minimumSizes[1] = CGSize(width: 5000, height: 400)
        #expect(ws.layout().frames[1]!.width == 3424)
    }

    @Test func `Fixed templates keep their reserved cells`() {
        var ws = wide()
        ws.setAlgorithm(.fixed(rows: 2, columns: 2, expand: .columns))
        let before = ws.layout()
        ws.windowMaxAspectRatio = 0
        #expect(ws.layout() == before)
    }

    @Test func `Auto and accordion geometry remain consistent`() {
        for mode in [LayoutMode.tiles, .accordion] {
            var ws = wide(2)
            ws.root = Container(.auto, mode, [.window(1), .window(2)])
            assertLimited(ws)
            #expect(ws.containerAxis(of: 1) == .horizontal)
            #expect(ws.root.orientation == .auto)
            let first = ws.layout()
            #expect(ws.layout() == first)
        }
    }

    @Test func `Manual mouse and command widths survive repeated layout passes`() {
        var ws = wide()
        let mouseResized = ws.resize(1, to: CGSize(width: 2800, height: 1384), moving: [.right])
        #expect(mouseResized)
        for _ in 0..<5 { #expect(abs(ws.layout().frames[1]!.width - 2800) <= 1) }
        ws.toggleFullscreen()
        #expect(ws.layout().frames[1]!.width == 3424)
        ws.toggleFullscreen()
        #expect(abs(ws.layout().frames[1]!.width - 2800) <= 1)
        let commandResized = ws.resize(by: 100, along: .horizontal)
        #expect(commandResized)
        #expect(abs(ws.layout().frames[1]!.width - 2900) <= 1)
        #expect(ws.limitsManualHeightResize(of: 1))
        ws.insert(2)
        #expect(ws.manualTilingWidth == nil)
        assertLimited(ws)
        ws.remove(2)
        assertLimited(ws)
    }

    @Test func `Manual resize of several tiles preserves the chosen split`() {
        var ws = wide(2)
        ws.bounds.size.width = 5120
        ws.displayAspectRatio = 5120 / 1440
        let before = ws.layout().frames[2]!
        let commandResized = ws.resize(by: 200, along: .horizontal)
        #expect(commandResized)
        let after = ws.layout()
        #expect(after.frames[2]!.width > before.width + 190)
        #expect(ws.manualTilingWidth != nil)
        #expect(ws.layout() == after)
        #expect(!ws.limitsManualHeightResize(of: 2))
    }

    @Test func `Smart resize follows a vertical container and preserves the area width`() {
        var ws = wide(2)
        ws.root = Container(.vertical, .tiles, [.window(1), .window(2)])
        let before = ws.layout().frames[2]!
        let resized = ws.resize(by: 100)
        #expect(resized)
        let after = ws.layout().frames[2]!
        #expect(after.height > before.height + 90)
        #expect(after.width == before.width)
        #expect(ws.layout().frames[2] == after)
    }

    @Test func `No op resize does not suspend automatic sizing`() {
        var ws = wide(2)
        let frame = ws.layout().frames[2]!
        let mouseResized = ws.resize(2, to: frame.size)
        let commandResized = ws.resize(by: 0, along: .horizontal)
        #expect(!mouseResized && !commandResized)
        #expect(ws.manualTilingWidth == nil)
    }

}
