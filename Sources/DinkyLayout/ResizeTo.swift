import CoreGraphics

/// Resizing a window to a size, as a mouse drag on its edge or corner does.
extension Workspace {
    /// Give the window `size`, the tree's ratios following. `edges` names the edges that moved: right and down
    /// for the right and bottom edges, left and up for the left and top ones. Along each axis where the size
    /// differs, the nearest tiles container running along it with a neighbour on the moved side changes its
    /// ratios, the difference going to or coming from that neighbour only; with no edge named for an axis, both
    /// neighbours share it. No share drops below `minimumRatio` and no tile below its minimum size. An accordion
    /// child resizes its accordion, whose children share one rectangle. Does nothing in fullscreen.
    /// False when nothing changed.
    @discardableResult
    public mutating func resize(_ id: WindowID, to size: CGSize, moving edges: Set<Direction> = []) -> Bool {
        guard fullscreen == nil, let frame = tiledLayout().frames[id],
              abs(size.width - frame.width) >= 0.5 || abs(size.height - frame.height) >= 0.5 else { return false }
        var changed = resizeTilingArea(id, to: size.width)
        for axis in [Orientation.horizontal, .vertical] {
            guard let frame = tiledLayout().frames[id] else { return false }
            let delta = axis == .horizontal ? size.width - frame.width : size.height - frame.height
            guard abs(delta) >= 0.5 else { continue }
            if resize(id, by: delta, along: axis, edge: edges.first { $0.orientation == axis }) { changed = true }
        }
        return changed
    }

    /// Grow (positive) or shrink the subtree holding the window along `axis` by `delta` points, taking the
    /// difference from its neighbour on the `edge` side, or from both neighbours when `edge` is nil.
    private mutating func resize(_ id: WindowID, by delta: CGFloat, along axis: Orientation, edge: Direction?) -> Bool {
        guard var path = root.path(of: id) else { return false }
        let layout = tiledLayout()
        while let index = path.popLast() {
            let parent = root.container(at: path)
            let sides = edge.map { [$0.isForward ? index + 1 : index - 1] } ?? [index - 1, index + 1]
            let neighbours = sides.filter { parent.children.indices.contains($0) }
            let rect = rect(at: path, in: layout)
            guard parent.mode == .tiles, !neighbours.isEmpty, axisOfContainer(at: path, in: layout) == axis else { continue }
            let gap = gaps.inner(axis)
            let available = (axis == .horizontal ? rect.width : rect.height) - gap * CGFloat(parent.children.count - 1)
            // A share may shrink to the larger of `minimumRatio` and its minimum size, unless it is already below.
            func floor(_ i: Int) -> Double {
                let smallest = parent.children[i].minimumExtent(axis, gap: gap, padding: accordionPadding, minimumSizes)
                return min(parent.ratios[i], max(Self.minimumRatio, Double(smallest / available)))
            }
            var ratios = parent.ratios
            let share = Double(delta / available) / Double(neighbours.count)
            for n in neighbours {
                let step = share > 0 ? min(share, ratios[n] - floor(n)) : max(share, floor(index) - ratios[index])
                ratios[index] += step
                ratios[n] -= step
            }
            guard zip(ratios, parent.ratios).contains(where: { abs($0 - $1) > 1e-9 }) else { return false }
            root.modify(at: path) { $0.setRatios(ratios) }
            return true
        }
        return false
    }
}
