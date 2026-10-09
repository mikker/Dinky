import CoreGraphics

/// Directional commands and resize. Each returns false when there was nothing to do.
extension Workspace {
    /// Smallest share a window can be resized down to.
    static let minimumRatio = 0.1

    /// The window in `direction` from `id`. Uses a virtual layout where accordions are split like tiles,
    /// so stacked accordion children still have a left and right. Ties go to the most recently focused window.
    public func neighbor(of id: WindowID, _ direction: Direction) -> WindowID? {
        var layout = Layout()
        root.layout(in: bounds, gaps: .zero, padding: 0, virtual: true, into: &layout)
        guard let from = layout.frames[id] else { return nil }
        let candidates = layout.order.compactMap { other -> (id: WindowID, distance: CGFloat)? in
            guard other != id, let to = layout.frames[other] else { return nil }
            let distance = switch direction {
            case .left: from.midX - to.midX
            case .right: to.midX - from.midX
            case .up: from.midY - to.midY
            case .down: to.midY - from.midY
            }
            let overlaps = direction.orientation == .horizontal
                ? min(from.maxY, to.maxY) > max(from.minY, to.minY)
                : min(from.maxX, to.maxX) > max(from.minX, to.minX)
            return distance > 0 && overlaps ? (other, distance) : nil
        }
        return candidates.min { $0.distance < $1.distance }?.id
    }

    /// Swap two windows' places in the tree, keeping both tiles' sizes. Focus stays where it was.
    @discardableResult
    public mutating func swap(_ first: WindowID, _ second: WindowID) -> Bool {
        guard first != second, let a = root.path(of: first), let b = root.path(of: second) else { return false }
        root.modify(at: Array(a.dropLast())) { $0.replace(at: a.last!, with: .window(second)) }
        root.modify(at: Array(b.dropLast())) { $0.replace(at: b.last!, with: .window(first)) }
        if let focused { focus(focused) }
        return true
    }

    /// Move the focused window one step in `direction`, AeroSpace style: swap with a sibling window, enter a
    /// sibling container, or leave the container at its edge. At the workspace edge, wraps the root in a new
    /// container along that axis, so a window leaves a root accordion for a tile beside it; if the root already
    /// tiles that way, does nothing.
    @discardableResult
    public mutating func move(_ direction: Direction) -> Bool {
        isFullscreen = false
        guard let focused, let path = root.path(of: focused) else { return false }
        if case .fixed = algorithm, isFixedTree {
            let (column, row) = switch direction {
            case .left: (path[0] - 1, path[1])
            case .right: (path[0] + 1, path[1])
            case .up: (path[0], path[1] - 1)
            case .down: (path[0], path[1] + 1)
            }
            guard root.children.indices.contains(column), root.container(at: [column]).children.indices.contains(row) else { return false }
            let target = [column, row]
            if let other = root.node(at: target).windows.first { return swap(focused, other) }
            removeFixedWindow(at: path)
            root.modify(at: [column]) { $0.replace(at: row, with: .window(focused)) }
            trimEmptyOverflow()
            focus(focused)
            return true
        }
        let axis = direction.orientation, forward = direction.isForward, layout = tiledLayout()
        let parentPath = Array(path.dropLast()), index = path.last!
        let parent = root.container(at: parentPath)
        let sibling = index + (forward ? 1 : -1)
        if axisOfContainer(at: parentPath, in: layout) == axis, parent.children.indices.contains(sibling) {
            if case .window(let other) = parent.children[sibling] { return swap(focused, other) }
            var destination = parentPath + [sibling]
            while case .container(let c) = root.node(at: destination), axisOfContainer(at: destination, in: layout) != axis {
                destination.append(c.activeIndex)
            }
            detach(path, adjusting: &destination)
            if case .container(let c) = root.node(at: destination) {
                root.modify(at: destination) { $0.insert(.window(focused), at: forward ? 0 : c.children.count) }
            } else {
                root.modify(at: Array(destination.dropLast())) { $0.insert(.window(focused), at: destination.last! + 1) }
            }
        } else if let depth = path.indices.dropLast().last(where: { axisOfContainer(at: Array(path.prefix($0)), in: layout) == axis }) {
            var outer = Array(path.prefix(depth + 1))
            detach(path, adjusting: &outer)
            root.modify(at: Array(outer.dropLast())) { $0.insert(.window(focused), at: outer.last! + (forward ? 1 : 0)) }
        } else if axisOfContainer(at: [], in: layout) != axis || (root.mode == .accordion && root.children.count > 1) {
            root.modify(at: parentPath) { $0.remove(at: index) }
            root = Container(ContainerOrientation(axis), .tiles, [.container(root)])
            root.insert(.window(focused), at: forward ? 1 : 0)
        } else {
            return false
        }
        normalize()
        focus(focused)
        return true
    }

    /// Put the focused window into the neighbouring subtree in `direction`: into it if it is a container
    /// across the axis, else into a new container wrapping the neighbour. Adapted from AeroSpace's join-with.
    @discardableResult
    public mutating func join(_ direction: Direction) -> Bool {
        isFullscreen = false
        guard let focused, let path = root.path(of: focused) else { return false }
        let forward = direction.isForward, offset = forward ? 1 : -1, layout = tiledLayout()
        guard let depth = path.indices.last(where: { depth in
            let prefix = Array(path.prefix(depth))
            return axisOfContainer(at: prefix, in: layout) == direction.orientation
                && root.container(at: prefix).children.indices.contains(path[depth] + offset)
        }) else { return false }
        var target = Array(path.prefix(depth)) + [path[depth] + offset]
        detach(path, adjusting: &target)
        let across = direction.orientation.opposite
        // Asked after the detach: the target may have grown into the space the window left.
        switch root.node(at: target) {
        case .container(let c) where axisOfContainer(at: target) == across:
            root.modify(at: target) { $0.insert(.window(focused), at: forward ? 0 : c.children.count) }
        case let node:
            let pair: [Node] = forward ? [.window(focused), node] : [node, .window(focused)]
            root.modify(at: Array(target.dropLast())) { $0.replace(at: target.last!, with: .container(Container(ContainerOrientation(across), .tiles, pair))) }
        }
        normalize()
        focus(focused)
        return true
    }

    /// Grow (positive) or shrink the focused window by `delta` points along its nearest tiles container's axis,
    /// or the nearest one running along `axis` if given. Siblings give or take space proportionally; no share
    /// drops below `minimumRatio` and the window does not shrink below its minimum size. False when nothing
    /// visibly changed.
    @discardableResult
    public mutating func resize(by delta: CGFloat, along axis: Orientation? = nil) -> Bool {
        isFullscreen = false
        guard let focused, var path = root.path(of: focused) else { return false }
        if abs(delta) >= 0.5, let frame = tiledLayout().frames[focused] {
            let horizontal = (axis ?? containerAxis(of: focused)) == .horizontal
            if resizeTilingArea(focused, to: horizontal ? frame.width + delta : frame.width) { return true }
        }
        let layout = tiledLayout()
        while let index = path.popLast() {
            let parent = root.container(at: path)
            let rect = rect(at: path, in: layout), along = axisOfContainer(at: path, in: layout)
            guard parent.mode == .tiles, parent.children.count > 1, axis ?? along == along else { continue }
            // The children share the container's extent less the gaps between them, as `tileRects` splits it.
            let extent = (along == .horizontal ? rect.width : rect.height) - gaps.inner(along) * CGFloat(parent.children.count - 1)
            let smallest = parent.children[index].minimumExtent(along, gap: gaps.inner(along), padding: accordionPadding, minimumSizes)
            let old = parent.ratios[index]
            let smallestOther = parent.ratios.enumerated().filter { $0.offset != index }.map(\.element).min()!
            let lower = max(Self.minimumRatio, min(Double(smallest / extent), old))
            let upper = 1 - Self.minimumRatio * (1 - old) / smallestOther
            let new = min(max(old + Double(delta / extent), lower), upper)
            guard abs(new - old) > 1e-9 else { return false }
            let (oldRoot, oldFrame) = (root, tiledLayout().frames[focused])
            let scale = (1 - new) / (1 - old)
            root.modify(at: path) { c in c.setRatios(c.ratios.enumerated().map { $0.offset == index ? new : $0.element * scale }) }
            // A step the minimum sizes swallow whole is undone, so the ratios do not drift out of sight.
            if tiledLayout().frames[focused] == oldFrame { root = oldRoot; return false }
            return true
        }
        return false
    }

    /// Remove the leaf at `path` without normalizing, shifting `other` if it pointed past the removed sibling.
    private mutating func detach(_ path: [Int], adjusting other: inout [Int]) {
        let level = path.count - 1
        root.modify(at: Array(path.prefix(level))) { $0.remove(at: path[level]) }
        if other.count > level, Array(other.prefix(level)) == Array(path.prefix(level)), other[level] > path[level] {
            other[level] -= 1
        }
    }
}
