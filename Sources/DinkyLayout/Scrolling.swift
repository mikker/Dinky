import CoreGraphics

// The scrolling layout, after Hyprland's (and niri's): the root is a row of columns, each a window or a stack of
// windows, as wide as its own share of the screen whatever the number of columns, so the row runs past the
// screen edges and scrolls to keep the focused column in view. A lone column fills the screen, columns that fit
// are centred, and focusing a column scrolls just far enough to show it whole.
//
// macOS cannot clip another app's window at the screen edge, so a window scrolled out of view is parked
// instead: on an edge with nothing beyond it, it hangs off the screen with `peek` points left on, in a gutter
// the columns keep an inner gap clear of; on an edge with another display beyond it, it stops flush at the
// border, behind the columns in view, so it never shows on the other display.

extension Workspace {
    /// How much of a parked window stays on screen. The WindowServer takes any position that leaves a little of
    /// a window on screen, but pulls one asked to go wholly off back until 40 points show.
    static let peek: CGFloat = 25

    /// Narrowest a column can be resized to, as a share of the screen.
    static let minimumColumnWidth = 0.1

    public var isScrolling: Bool { algorithm == .scrolling }

    /// Put a window in a new column right of the focused one, at the default width.
    mutating func insertColumn(_ id: WindowID) {
        let index = focused.flatMap { root.path(of: $0) }.map { $0[0] + 1 } ?? root.children.count
        root.insert(.window(id), at: index)
        columnWidths[id] = columnWidth
    }

    /// The width of column `index` as a share: its windows all have it.
    func width(ofColumn index: Int) -> Double {
        root.children[index].windows.lazy.compactMap { columnWidths[$0] }.first ?? columnWidth
    }

    /// Give every window of column `index` the width `share`, kept between the narrowest a column goes and the
    /// whole screen.
    mutating func setWidth(ofColumn index: Int, _ share: Double) {
        let share = min(max(share, Self.minimumColumnWidth), 1)
        for id in root.children[index].windows { columnWidths[id] = share }
    }

    /// Where the columns go: inside the outer gaps, and with more than one column also clear of the parked
    /// windows' gutter on each side without a wall, by half an inner gap, which with a column's own half makes
    /// a whole one. Column widths are shares of its width.
    var stripArea: CGRect {
        let area = gaps.inset(bounds)
        guard root.children.count > 1 else { return area }
        let clear = Self.peek + gaps.horizontal / 2
        let left = walls.contains(.left) ? 0 : max(clear - gaps.left, 0)
        let right = walls.contains(.right) ? 0 : max(clear - gaps.right, 0)
        return CGRect(x: area.minX + left, y: area.minY, width: area.width - left - right, height: area.height)
    }

    /// Each column's start and width in points along the strip, from its left edge. Half an inner gap is part
    /// of a column on each side that has a neighbour, so neighbours end up a whole gap apart. A lone column is
    /// as wide as the screen; any other is its share of it, grown to fit its windows' minimum widths.
    func columnSpans(in area: CGRect) -> [(start: CGFloat, width: CGFloat)] {
        let count = root.children.count, gap = gaps.horizontal
        var start: CGFloat = 0
        return root.children.indices.map { i in
            let insets = (i > 0 ? gap / 2 : 0) + (i < count - 1 ? gap / 2 : 0)
            let minimum = root.children[i].minimumExtent(.horizontal, gap: gap, padding: accordionPadding, minimumSizes)
            let width = count == 1 ? area.width : max((area.width * CGFloat(width(ofColumn: i))).rounded(), minimum + insets)
            defer { start += width }
            return (start, width)
        }
    }

    /// The scroll offset the layout uses. The strip never scrolls past either end, and the column at an end
    /// reaches into the gutter there, which nothing is parked in, out to the outer gap. A strip that fits
    /// between the outer gaps is centred.
    func offset(for spans: [(start: CGFloat, width: CGFloat)], in area: CGRect) -> CGFloat {
        let total = spans.last.map { $0.start + $0.width } ?? 0, inset = gaps.inset(bounds)
        let first = area.minX - inset.minX, last = total - area.width - (inset.maxX - area.maxX)
        guard first < last else { return (first + (total - inset.width) / 2).rounded() }
        return min(max(scrollOffset, first), last)
    }

    /// Scroll as little as shows the window's column whole, as Hyprland's `fit` does. A column wider than the
    /// screen is centred.
    mutating func reveal(_ id: WindowID) {
        guard isScrolling, let index = root.path(of: id)?.first else { return }
        let area = stripArea, spans = columnSpans(in: area), column = spans[index]
        let current = offset(for: spans, in: area)
        scrollOffset = column.width > area.width
            ? column.start - (area.width - column.width) / 2
            : min(max(current, column.start + column.width - area.width), column.start)
    }

    /// The window a trackpad swipe toward `direction` focuses: the focused window's neighbour that way along a
    /// scrolling strip. Nil past the last column, where the swipe switches Space instead, and off the strip.
    public func swipeTarget(_ direction: Direction) -> WindowID? {
        guard isScrolling, direction.orientation == .horizontal, let focused else { return nil }
        return neighbor(of: focused, direction)
    }

    /// The strip laid out at the current scroll offset, windows anywhere along it, on screen or not. The focused
    /// column comes first in the stacking, then the others by distance from it.
    func stripLayout() -> Layout {
        var result = Layout()
        let area = stripArea, spans = columnSpans(in: area), offset = offset(for: spans, in: area)
        let gap = gaps.horizontal, last = root.children.count - 1
        result.containerRects[[]] = gaps.inset(bounds)
        for i in root.stackingOrder {
            let span = spans[i]
            let lead = i > 0 ? gap / 2 : 0, trail = i < last ? gap / 2 : 0
            let x = area.minX + span.start - offset
            let (a, b) = ((x + lead).rounded(), (x + span.width - trail).rounded())
            let rect = CGRect(x: a, y: area.minY, width: b - a, height: area.height)
            switch root.children[i] {
            case .window(let id):
                result.frames[id] = rect
                result.order.append(id)
            case .container(let c):
                c.layout(in: rect, gaps: gaps, padding: accordionPadding, minimums: minimumSizes, path: [i], into: &result)
            }
        }
        return result
    }

    /// Where a window of the strip goes on screen: where the strip puts it while at least `peek` of it is on
    /// screen, so a neighbour of the columns in view stays a gap from them, else hanging off the edge with `peek`
    /// left on, under that neighbour. At a wall it stays wholly on screen instead, behind the columns.
    func parked(_ frame: CGRect) -> CGRect {
        var x = frame.minX
        x = min(x, walls.contains(.right) ? bounds.maxX - frame.width : bounds.maxX - Self.peek)
        x = max(x, walls.contains(.left) ? bounds.minX : bounds.minX + Self.peek - frame.width)
        return CGRect(x: x, y: frame.minY, width: frame.width, height: frame.height)
    }

    /// Whether the strip shows the whole window now. Always true outside the scrolling layout.
    public func isInView(_ id: WindowID) -> Bool {
        guard isScrolling, let frame = tiledLayout().frames[id] else { return true }
        return frame.minX >= bounds.minX - 1 && frame.maxX <= bounds.maxX + 1
    }

    /// `move` in the strip. Left and right take a window that shares its column out into a new column on that
    /// side, and swap a column of its own with its neighbour. Up and down only move it within its column.
    mutating func moveInStrip(_ direction: Direction) -> Bool {
        guard let focused, let path = root.path(of: focused) else { return false }
        let column = path[0], forward = direction.isForward
        if direction.orientation == .horizontal {
            if path.count > 1 {
                let share = width(ofColumn: column)
                root.modify(at: Array(path.dropLast())) { $0.remove(at: path.last!) }
                root.insert(.window(focused), at: column + (forward ? 1 : 0))
                columnWidths[focused] = share
            } else {
                let other = column + (forward ? 1 : -1)
                guard root.children.indices.contains(other) else { return false }
                let node = root.children[other]
                root.replace(at: other, with: root.children[column])
                root.replace(at: column, with: node)
            }
            normalize()
            focus(focused)
            return true
        }
        return path.count > 1 && moveInTree(direction)
    }

    /// `join-with` in the strip: left and right put the window into the neighbouring column, at that column's
    /// width; up and down work as in any tree, within the column.
    mutating func joinInStrip(_ direction: Direction) -> Bool {
        guard direction.orientation == .horizontal, let focused, let column = root.path(of: focused)?.first else {
            return joinInTree(direction)
        }
        let neighbour = column + (direction.isForward ? 1 : -1)
        guard root.children.indices.contains(neighbour) else { return false }
        let share = width(ofColumn: neighbour)
        // Joined at the root, so a window deep in its column still lands in the neighbouring column.
        guard joinInTree(direction, atRoot: true), let joined = root.path(of: focused)?.first else { return false }
        setWidth(ofColumn: joined, share)
        reveal(focused)
        return true
    }

    /// Grow (positive) or shrink the focused window's column by `delta` points. False when nothing visibly changed.
    mutating func resizeColumn(by delta: CGFloat) -> Bool {
        guard let focused, let column = root.path(of: focused)?.first else { return false }
        let old = width(ofColumn: column)
        let (before, offset) = (tiledLayout(), scrollOffset)
        setWidth(ofColumn: column, old + Double(delta / stripArea.width))
        reveal(focused)
        // A step a lone column or the minimum sizes swallow whole is undone, so the width does not drift out of sight.
        guard tiledLayout() == before else { return true }
        setWidth(ofColumn: column, old)
        scrollOffset = offset
        return false
    }
}
