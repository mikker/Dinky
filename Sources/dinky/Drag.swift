import AppKit
import DinkyLayout

// Dragging a tiled window with the mouse. On release, a drag that moved one edge of the window on an axis is a
// resize: the tree takes the new size and the other tiles make room. Any other drag is a move: dropping it with the
// pointer over another tile swaps the two, anywhere else puts it back. While a move is under way, placeholders
// outline the window's tile and the one it would swap with. Only frames that change while the mouse button is
// down count as a drag, which keeps dinky's own frame writes and apps moving themselves out of it.
extension Coordinator {
    func noteFrameChange(of id: WindowID) {
        if dragging == id { return showPlaceholders() }
        // Only tiled windows have a Space.
        guard dragging == nil, placements[id]?.space != nil, !isAnimating(id), mouseButtonDown else { return }
        dragging = id
        showPlaceholders()
        watchDragEnd()
    }

    private func watchDragEnd() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let id = self.dragging else { return }
            if self.mouseButtonDown {
                self.showPlaceholders()
                self.watchDragEnd()
            } else {
                self.dragging = nil
                self.placeholders.hide()
                self.dropped(id)
            }
        }
    }

    private func dropped(_ id: WindowID) {
        guard let key = placements[id]?.space, let layout = workspaces[key]?.layout(), let window = model.windows[id],
              let expected = layout.frames[id], !window.frame.isClose(to: expected, within: 2) else { return }
        if let edges = movedEdges(from: expected, to: window.frame) {
            if let workspace = workspaces[key], workspace.limitsManualHeightResize(of: id),
               abs(window.frame.height - expected.height) > 5 {
                setFloating(id, true)
                return
            }
            edit(key) { $0.resize(id, to: window.frame.size, moving: edges) }
        } else if let target = dropTarget(of: id, in: layout) {
            edit(key) { $0.swap(id, target) }
        }
        dirty.insert(key)
        flush()
    }

    /// Outline the dragged window's tile and the tile it would swap with, while the drag is a move.
    private func showPlaceholders() {
        guard config.drag.placeholders, let id = dragging, let key = placements[id]?.space,
              let layout = workspaces[key]?.layout(), let home = layout.frames[id], let window = model.windows[id],
              !window.frame.isClose(to: home, within: 2), movedEdges(from: home, to: window.frame) == nil
        else { return placeholders.hide() }
        placeholders.show(dragged: id, home: home, target: dropTarget(of: id, in: layout).flatMap { layout.frames[$0] },
                          cornerRadius: CGFloat(window.cornerRadius))
    }

    /// The tile under the pointer that a dragged window swaps with, the frontmost where tiles overlap. The
    /// placeholders and the drop both ask this, so what is outlined is what happens.
    private func dropTarget(of id: WindowID, in layout: Layout) -> WindowID? {
        guard let pointer = CGEvent(source: nil)?.location else { return nil }
        return layout.order.first { $0 != id && layout.frames[$0]!.contains(pointer) }
    }

    /// The edges a resize moved, going from the tile to the dropped frame: on each axis, one edge moved more than
    /// 2 pt and the other stayed. Nil for a move, where some axis had both edges move, or nothing did.
    private func movedEdges(from tile: CGRect, to frame: CGRect) -> Set<Direction>? {
        let axes = [((Direction.left, tile.minX, frame.minX), (Direction.right, tile.maxX, frame.maxX)),
                    ((Direction.up, tile.minY, frame.minY), (Direction.down, tile.maxY, frame.maxY))]
        var edges: Set<Direction> = []
        for (lead, trail) in axes {
            let moved = [lead, trail].filter { abs($0.2 - $0.1) > 2 }.map(\.0)
            if moved.count == 2 { return nil }
            edges.formUnion(moved)
        }
        return edges.isEmpty ? nil : edges
    }

    private var mouseButtonDown: Bool { CGEventSource.buttonState(.combinedSessionState, button: .left) }
}
