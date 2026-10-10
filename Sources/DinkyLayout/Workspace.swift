import CoreGraphics

/// How new windows are placed in a workspace. Dwindle carries the root's layout mode.
public enum TilingAlgorithm: Equatable, Sendable, Codable {
    case dwindle(LayoutMode)
    case fixed(rows: Int, columns: Int, expand: FixedExpansion)
}

public enum FixedExpansion: Equatable, Sendable, Codable {
    case rows, columns, accordion
}

/// One Space's tiling state: the tree, focus, fullscreen and the geometry settings used to lay it out.
public struct Workspace: Equatable, Sendable {
    /// The Space's visible rect, top-left origin.
    public var bounds: CGRect
    public var gaps: Gaps
    public var accordionPadding: CGFloat
    /// Whether a container switching to accordion follows its longer side (`auto`), unless a `layout` command
    /// chose its orientation.
    public var autoOrientAccordions: Bool
    public private(set) var algorithm: TilingAlgorithm
    /// The tree. The root is always a container, possibly empty.
    public internal(set) var root: Container
    /// The focused window, if any.
    public internal(set) var focused: WindowID?
    /// Whether the focused window is shown fullscreen over the tree. Focusing another window or any layout
    /// command ends it.
    var isFullscreen = false
    /// The window shown fullscreen over the tree, if any.
    public var fullscreen: WindowID? { isFullscreen ? focused : nil }
    /// Sizes windows refused to go below. Tiles grow to them when their siblings can give the space.
    public var minimumSizes: [WindowID: CGSize] = [:]

    /// An empty workspace laid out by `algorithm`. A dwindle accordion root with `autoOrientAccordions` starts
    /// `auto`, as a container switched to accordion would, so it runs top to bottom on a tall display.
    public init(bounds: CGRect, gaps: Gaps = .zero, accordionPadding: CGFloat = 30, autoOrientAccordions: Bool = false,
                algorithm: TilingAlgorithm = .dwindle(.tiles)) {
        self.bounds = bounds
        self.gaps = gaps
        self.accordionPadding = accordionPadding
        self.autoOrientAccordions = autoOrientAccordions
        self.algorithm = algorithm
        switch algorithm {
        case .dwindle(let mode):
            root = Container(mode == .accordion && autoOrientAccordions ? .auto : .horizontal, mode)
        case .fixed(let rows, let columns, _):
            precondition(rows > 0 && columns > 0)
            root = Self.fixedRoot(rows: rows, columns: columns)
        }
    }

    /// All windows in tree order.
    public var windows: [WindowID] { Node.container(root).windows }

    /// Whether the window is tiled here.
    public func contains(_ id: WindowID) -> Bool { root.path(of: id) != nil }

    /// Insert a window and focus it. Fixed workspaces fill empty cells before expanding. If a tree command
    /// has changed the template structure, use the focused-leaf split instead of discarding the edits.
    public mutating func insert(_ id: WindowID) {
        guard !contains(id) else { return }
        if case .fixed(let rows, let columns, _) = algorithm, windows.isEmpty, !isFixedTree {
            root = Self.fixedRoot(rows: rows, columns: columns)
        }
        if case .fixed(_, _, let expansion) = algorithm, insertIntoFixed(id, expand: expansion) {
            return focus(id)
        }
        guard let focused, let path = root.path(of: focused) else {
            root.insert(.window(id), at: root.children.count)
            return focus(id)
        }
        let layout = tiledLayout(), leaf = layout.frames[focused] ?? gaps.inset(bounds)
        let axis: Orientation = leaf.width >= leaf.height ? .horizontal : .vertical
        let parentPath = Array(path.dropLast()), index = path.last!
        let joins = axisOfContainer(at: parentPath, in: layout) == axis || root.container(at: parentPath).children.count == 1
        root.modify(at: parentPath) { parent in
            if parent.children.count == 1, parent.orientation != .auto { parent.orientation = ContainerOrientation(axis) }
            if joins || parent.mode == .accordion {
                parent.insert(.window(id), at: index + 1)
            } else {
                parent.replace(at: index, with: .container(Container(ContainerOrientation(axis), .tiles, [.window(focused), .window(id)])))
            }
        }
        focus(id)
    }

    /// Remove a window. Its share goes to its siblings, redundant containers collapse.
    /// If it was focused, focus moves to the window that took its place.
    public mutating func remove(_ id: WindowID) {
        guard let path = root.path(of: id) else { return }
        if case .fixed = algorithm, isFixedTree {
            removeFixedWindow(at: path)
            trimEmptyOverflow()
        } else {
            root.modify(at: Array(path.dropLast())) { $0.remove(at: path.last!) }
            normalize()
        }
        if windows.isEmpty, case .fixed(let rows, let columns, _) = algorithm {
            root = Self.fixedRoot(rows: rows, columns: columns)
        }
        if focused == id {
            isFullscreen = false
            focused = nil
            if let next = root.mostRecentWindow ?? windows.first { focus(next) }
        }
    }

    static var emptyCell: Node { .container(Container(.horizontal)) }

    mutating func removeFixedWindow(at path: [Int]) {
        let cell = Array(path.prefix(2))
        if path.count == 3, case .container(let stack) = root.node(at: cell) {
            root.modify(at: cell) { $0.remove(at: path[2]) }
            if stack.children.count == 2, case .container(let remaining) = root.node(at: cell) {
                root.modify(at: [cell[0]]) { $0.replace(at: cell[1], with: remaining.children[0]) }
            }
        } else {
            root.modify(at: [cell[0]]) { $0.replace(at: cell[1], with: Self.emptyCell) }
        }
    }

    /// Reserved cells stay; trailing rows or columns created by overflow disappear once empty.
    mutating func trimEmptyOverflow() {
        guard case .fixed(let reservedRows, let reservedColumns, let expand) = algorithm else { return }
        switch expand {
        case .columns:
            while root.children.count > reservedColumns, root.children.last!.windows.isEmpty {
                root.remove(at: root.children.count - 1)
            }
        case .rows:
            while root.container(at: [0]).children.count > reservedRows {
                let last = root.container(at: [0]).children.count - 1
                guard root.children.indices.allSatisfy({ root.node(at: [$0, last]).windows.isEmpty }) else { break }
                for column in root.children.indices { root.modify(at: [column]) { $0.remove(at: last) } }
            }
        case .accordion: break
        }
    }

    private static func fixedColumn(rows: Int) -> Node {
        .container(Container(.vertical, .tiles, (0..<rows).map { _ in emptyCell }))
    }

    private static func fixedRoot(rows: Int, columns: Int) -> Container {
        Container(.horizontal, .tiles, (0..<columns).map { _ in fixedColumn(rows: rows) })
    }

    /// Recognize the template in the tree. A manual tree command may break this shape; it must not be
    /// silently undone just because another window appeared.
    var isFixedTree: Bool {
        guard root.orientation == .horizontal, root.mode == .tiles,
              let first = root.children.first, case .container(let firstColumn) = first,
              !firstColumn.children.isEmpty else { return false }
        return root.children.allSatisfy { node in
            guard case .container(let column) = node, column.orientation == .vertical,
                  column.mode == .tiles, column.children.count == firstColumn.children.count else { return false }
            return column.children.allSatisfy { cell in
                switch cell {
                case .window: true
                case .container(let c): c.children.isEmpty || (c.mode == .accordion
                    && c.children.allSatisfy { if case .window = $0 { true } else { false } })
                }
            }
        }
    }

    /// Fill the first hole in row-major order, or add a row/column, or stack in the last cell.
    private mutating func insertIntoFixed(_ id: WindowID, expand: FixedExpansion) -> Bool {
        guard isFixedTree else { return false }
        let rows = root.container(at: [0]).children.count
        let columns = root.children.count
        for row in 0..<rows {
            for column in 0..<columns where root.node(at: [column, row]).windows.isEmpty {
                root.modify(at: [column]) { $0.replace(at: row, with: .window(id)) }
                return true
            }
        }
        switch expand {
        case .columns:
            root.insert(Self.fixedColumn(rows: rows), at: columns)
            root.modify(at: [columns]) { $0.replace(at: 0, with: .window(id)) }
        case .rows:
            for column in 0..<columns { root.modify(at: [column]) { $0.insert(Self.emptyCell, at: rows) } }
            root.modify(at: [0]) { $0.replace(at: rows, with: .window(id)) }
        case .accordion:
            let cell = [columns - 1, rows - 1]
            switch root.node(at: cell) {
            case .window(let existing):
                root.modify(at: [cell[0]]) { $0.replace(at: cell[1], with: .container(Container(.horizontal, .accordion, [.window(existing), .window(id)]))) }
            case .container:
                root.modify(at: cell) { $0.insert(.window(id), at: $0.children.count) }
            }
        }
        return true
    }

    private var fixedWindows: [WindowID] {
        let rows = root.container(at: [0]).children.count
        return (0..<rows).flatMap { row in
            root.children.indices.flatMap { root.node(at: [$0, row]).windows }
        }
    }

    /// Switch algorithms. Changing the template deliberately rearranges the existing windows once.
    public mutating func setAlgorithm(_ new: TilingAlgorithm) {
        guard algorithm != new else { return }
        algorithm = new
        rebuild()
    }

    /// Lay the windows out afresh in the configured layout, keeping their order and focus.
    private mutating func rebuild() {
        let ids = isFixedTree ? fixedWindows : windows
        switch algorithm {
        case .dwindle(let mode):
            root = Container(mode == .accordion && autoOrientAccordions ? .auto : .horizontal, mode, ids.map(Node.window))
        case .fixed(let rows, let columns, let expand):
            root = Self.fixedRoot(rows: rows, columns: columns)
            for id in ids { _ = insertIntoFixed(id, expand: expand) }
        }
        if let focused { focus(focused) }
    }

    /// Put `new` in `old`'s place, keeping its size, focus and fullscreen: another tab of the same native tab group
    /// became the one shown. Does nothing if `old` is not here or `new` already is.
    public mutating func replace(_ old: WindowID, with new: WindowID) {
        guard let path = root.path(of: old), !contains(new) else { return }
        root.modify(at: Array(path.dropLast())) { $0.replace(at: path.last!, with: .window(new)) }
        if focused == old { focused = new }
        minimumSizes[old] = nil
    }

    /// Undo every tree edit: the windows go back into the configured layout, in order, with equal ratios.
    public mutating func flatten() {
        isFullscreen = false
        rebuild()
    }

    /// Focus a window and mark it most recent along its path, so accordions show it on top.
    /// Ends fullscreen unless it is the fullscreen window.
    public mutating func focus(_ id: WindowID) {
        guard let path = root.path(of: id) else { return }
        if focused != id { isFullscreen = false }
        focused = id
        for depth in path.indices {
            root.modify(at: Array(path.prefix(depth))) { $0.active = path[depth] }
        }
    }

    /// Focus the neighbour in `direction`. At the edge, `wrapping` focuses the window at the opposite edge
    /// instead. Returns false when there is nothing to focus.
    @discardableResult
    public mutating func focus(_ direction: Direction, wrapping: Bool = false) -> Bool {
        guard let focused,
              let target = neighbor(of: focused, direction) ?? (wrapping ? edgeWindow(direction.opposite) : nil),
              target != focused else { return false }
        focus(target)
        return true
    }

    /// The window snapped to the `side` edge: containers along that axis give their first or last child,
    /// the others their most recently focused one. Adapted from AeroSpace's findLeafWindowRecursive(snappedTo:).
    public func edgeWindow(_ side: Direction) -> WindowID? {
        if case .fixed = algorithm, isFixedTree {
            // A boundary cell may be empty. Find the outermost occupied one instead of descending into a hole.
            let frames = tiledLayout().frames
            let focusedFrame = focused.flatMap { frames[$0] }
            func rank(_ frame: CGRect) -> (CGFloat, CGFloat) {
                let edge: CGFloat = switch side {
                case .left: frame.minX
                case .right: -frame.maxX
                case .up: frame.minY
                case .down: -frame.maxY
                }
                let across = side.orientation == .horizontal
                    ? abs(frame.midY - (focusedFrame?.midY ?? bounds.midY))
                    : abs(frame.midX - (focusedFrame?.midX ?? bounds.midX))
                return (edge, across)
            }
            return frames.keys.min { a, b in
                let first = rank(frames[a]!), second = rank(frames[b]!)
                return first == second ? a < b : first < second
            }
        }
        let layout = tiledLayout()
        var container = root, path: [Int] = []
        while !container.children.isEmpty {
            let index = axisOfContainer(at: path, in: layout) != side.orientation ? container.activeIndex
                : side.isForward ? container.children.count - 1 : 0
            switch container.children[index] {
            case .window(let id): return id
            case .container(let c): (container, path) = (c, path + [index])
            }
        }
        return nil
    }

    /// Give every container in the tree equal ratios.
    public mutating func balanceSizes() {
        isFullscreen = false
        root.balance()
    }

    /// The window's parent container, nil if the window is not here.
    public func container(of id: WindowID) -> Container? {
        root.path(of: id).map { root.container(at: Array($0.dropLast())) }
    }

    /// The axis of the window's parent container, `auto` resolved, nil if the window is not here.
    public func containerAxis(of id: WindowID) -> Orientation? {
        root.path(of: id).map { axisOfContainer(at: Array($0.dropLast())) }
    }

    /// The axis the container at `path` runs along now, `auto` resolved from the rectangle it is laid out in,
    /// so minimum sizes count as they do on screen.
    func axisOfContainer(at path: [Int]) -> Orientation {
        axisOfContainer(at: path, in: tiledLayout())
    }

    /// The axis of the container at `path` in `layout`, for callers asking about several containers at once.
    func axisOfContainer(at path: [Int], in layout: Layout) -> Orientation {
        root.container(at: path).axis(in: rect(at: path, in: layout))
    }

    /// The rectangle the container at `path` is laid out in, gaps and minimum sizes applied.
    func rect(at path: [Int], in layout: Layout) -> CGRect {
        layout.containerRects[path] ?? gaps.inset(bounds)
    }

    /// Set the layout mode of the focused window's parent container. Ratios are kept, so tiles come back as they were.
    public mutating func setMode(_ mode: LayoutMode) { setLayout(mode, nil) }

    /// Set the orientation of the focused window's parent container, and remember that it was chosen.
    public mutating func setOrientation(_ orientation: ContainerOrientation) { setLayout(nil, orientation) }

    /// Set the mode, the orientation or both of the focused window's parent container, then tidy the tree once,
    /// so the container is not merged into its parent halfway. With `autoOrientAccordions`, a container becoming
    /// an accordion turns `auto` unless a command chose its orientation.
    public mutating func setLayout(_ mode: LayoutMode?, _ orientation: ContainerOrientation?) {
        isFullscreen = false
        guard let focused, let path = root.path(of: focused) else { return }
        root.modify(at: Array(path.dropLast())) { c in
            if let mode {
                if mode == .accordion, c.mode != .accordion, autoOrientAccordions, !c.orientationChosen { c.orientation = .auto }
                c.mode = mode
            }
            if let orientation {
                c.orientation = orientation
                c.orientationChosen = true
            }
        }
        normalize()
    }

    /// Toggle fullscreen for the focused window. The tree is not changed.
    public mutating func toggleFullscreen() {
        if focused != nil { isFullscreen.toggle() }
    }

    /// Frames and stacking for every window. A fullscreen window covers the bounds minus outer gaps and comes first.
    public func layout() -> Layout {
        var result = tiledLayout()
        if let fullscreen {
            result.frames[fullscreen] = gaps.inset(bounds)
            result.order = [fullscreen] + result.order.filter { $0 != fullscreen }
        }
        return result
    }

    /// The layout ignoring fullscreen, used for geometry questions.
    func tiledLayout() -> Layout {
        var result = Layout()
        root.layout(in: gaps.inset(bounds), gaps: gaps, padding: accordionPadding, minimums: minimumSizes, into: &result)
        return result
    }

    /// Tidy the tree after an edit, and unwrap a root whose only child is a container.
    mutating func normalize() {
        root.normalize()
        if root.children.count == 1, case .container(let only) = root.children[0] { root = only }
    }
}
