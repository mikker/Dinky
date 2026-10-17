import AppKit
import DinkyLayout

// Dragging a tiled window with the mouse. On release, a drag that moved one edge of the window on an axis is a
// resize: the tree takes the new size and the other tiles make room. Any other drag is a move: dropping it with the
// pointer over another tile swaps the two, anywhere else puts it back. Holding the pointer still over a tile for a
// moment first splits that tile instead: the dragged window takes the half the pointer is in. While a move is under
// way, placeholders outline the window's tile and where it would land. Only frames that change while the mouse
// button is down count as a drag, which keeps dinky's own frame writes and apps moving themselves out of it.

/// The tile the pointer rests on during a drag. Once it has stayed put for `[drag] hold-ms`, the drop splits the
/// tile, until the pointer leaves it.
struct DragHold {
    /// How far the pointer may drift and still be holding still.
    static let slack: CGFloat = 12

    let target: WindowID
    var at: CGPoint
    var since = Date()
    var armed = false
}

extension Coordinator {
    func noteFrameChange(of id: WindowID) {
        if dragging == id { return followDrag() }
        // Only tiled windows have a Space. Disabled, dinky leaves drags alone.
        guard enabled, dragging == nil, placements[id]?.space != nil, !isAnimating(id), mouseButtonDown else { return }
        dragging = id
        followDrag()
        watchDragEnd()
    }

    private func watchDragEnd() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let id = self.dragging else { return }
            if self.mouseButtonDown {
                self.followDrag()
                self.watchDragEnd()
            } else {
                self.dragging = nil
                self.placeholders.hide()
                self.dropped(id)
                self.dragHold = nil
            }
        }
    }

    /// Lets go of the drag under way without acting on its release, as when dinky is disabled mid-drag.
    func cancelDrag() {
        guard dragging != nil else { return }
        dragging = nil
        dragHold = nil
        placeholders.hide()
    }

    private func dropped(_ id: WindowID) {
        guard let key = placements[id]?.space, let workspace = workspaces[key], let window = model.windows[id] else { return }
        let layout = workspace.layout()
        guard let expected = layout.frames[id], !window.frame.isClose(to: expected, within: 2) else { return }
        if let edges = movedEdges(from: expected, to: window.frame) {
            edit(key) { $0.resize(id, to: window.frame.size, moving: edges) }
        } else if let drop = drop(of: id, in: workspace, layout) {
            edit(key) {
                if let side = drop.side { $0.split(drop.target, with: id, on: side) } else { $0.swap(id, drop.target) }
            }
        }
        dirty.insert(key)
        flush()
    }

    /// Notes where the pointer rests and outlines the dragged window's tile and where a drop would put it, while
    /// the drag is a move.
    private func followDrag() {
        guard let id = dragging, let key = placements[id]?.space, let workspace = workspaces[key],
              let window = model.windows[id] else { return placeholders.hide() }
        let layout = workspace.layout()
        guard let home = layout.frames[id], !window.frame.isClose(to: home, within: 2),
              movedEdges(from: home, to: window.frame) == nil else {
            dragHold = nil
            return placeholders.hide()
        }
        noteHold(over: dropTarget(of: id, in: layout))
        guard config.drag.placeholders else { return }
        let landing = drop(of: id, in: workspace, layout).flatMap { drop -> CGRect? in
            guard let side = drop.side else { return layout.frames[drop.target] }
            // The tree as the drop would leave it, so the outline is the tile the window gets.
            var split = workspace
            split.split(drop.target, with: id, on: side)
            return split.layout().frames[id]
        }
        placeholders.show(dragged: id, home: home, target: landing, cornerRadius: CGFloat(window.cornerRadius))
    }

    /// Follows the pointer from tile to tile: resting on one for `hold-ms` arms a split of it.
    private func noteHold(over target: WindowID?) {
        guard config.drag.holdToSplit, let target, let pointer else { return dragHold = nil }
        guard var hold = dragHold, hold.target == target else { return dragHold = DragHold(target: target, at: pointer) }
        if !hold.armed {
            if hypot(pointer.x - hold.at.x, pointer.y - hold.at.y) > DragHold.slack {
                hold.at = pointer
                hold.since = Date()
            } else if Date().timeIntervalSince(hold.since) * 1000 >= Double(config.drag.holdMs) {
                hold.armed = true
            }
        }
        dragHold = hold
    }

    /// What dropping the dragged window now does: swap it with `target`, or with a `side`, split the tile it
    /// was held over and take that half, the one the pointer is in. The placeholders and the drop both ask this,
    /// so what is outlined is what happens.
    private func drop(of id: WindowID, in workspace: Workspace, _ layout: Layout) -> (target: WindowID, side: Direction?)? {
        guard let target = dropTarget(of: id, in: layout) else { return nil }
        guard let hold = dragHold, hold.armed, hold.target == target, workspace.canSplit(target, with: id),
              let pointer, let tile = layout.frames[target] else { return (target, nil) }
        let x = (pointer.x - tile.midX) / tile.width, y = (pointer.y - tile.midY) / tile.height
        return (target, abs(x) >= abs(y) ? (x < 0 ? .left : .right) : (y < 0 ? .up : .down))
    }

    /// The tile under the pointer, the frontmost where tiles overlap.
    private func dropTarget(of id: WindowID, in layout: Layout) -> WindowID? {
        guard let pointer else { return nil }
        return layout.order.first { $0 != id && layout.frames[$0]!.contains(pointer) }
    }

    private var pointer: CGPoint? { CGEvent(source: nil)?.location }

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
