// The layout tree: containers with orientation, mode and ratios; leaves are windows. No AppKit here.

/// Opaque window identifier, the WindowServer window number.
public typealias WindowID = UInt32

/// Axis along which a container places its children.
public enum Orientation: Equatable, Sendable {
    case horizontal, vertical

    /// The other axis.
    public var opposite: Orientation { self == .horizontal ? .vertical : .horizontal }
}

/// How a container picks its axis: fixed, or `auto`, along the longer side of its rectangle (a square runs
/// horizontally). `auto` is resolved wherever the rectangle is known, see `Container.axis(in:)`.
public enum ContainerOrientation: Equatable, Sendable, Codable {
    case horizontal, vertical, auto

    public init(_ axis: Orientation) { self = axis == .horizontal ? .horizontal : .vertical }
}

/// How a container shows its children: side by side, or stacked with neighbours peeking out.
public enum LayoutMode: Equatable, Sendable, Codable {
    case tiles, accordion
}

/// A direction for focus, swap, move and join-with.
public enum Direction: Equatable, Sendable {
    case left, right, up, down

    /// The axis this direction moves along.
    public var orientation: Orientation { self == .left || self == .right ? .horizontal : .vertical }
    /// True for right and down, the directions of increasing child index.
    public var isForward: Bool { self == .right || self == .down }
    /// The direction pointing the other way.
    public var opposite: Direction {
        switch self {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }
}

/// A node in the tree: a window leaf or a container.
public indirect enum Node: Equatable, Sendable, Codable {
    case window(WindowID)
    case container(Container)

    /// Window ids in this subtree, in tree order.
    public var windows: [WindowID] {
        switch self {
        case .window(let id): [id]
        case .container(let c): c.children.flatMap(\.windows)
        }
    }
}

/// A container: ordered children with ratios that sum to 1.
public struct Container: Equatable, Sendable, Codable {
    public var orientation: ContainerOrientation
    public var mode: LayoutMode
    /// Whether a `layout` command chose the orientation, so switching to accordion keeps it.
    public var orientationChosen = false
    public private(set) var children: [Node] = []
    public private(set) var ratios: [Double] = []
    /// Index of the most recently focused child. Drives accordion stacking.
    public internal(set) var active = 0

    /// A container with the given children, if any, and equal ratios.
    public init(_ orientation: ContainerOrientation, _ mode: LayoutMode = .tiles, _ children: [Node] = []) {
        self.orientation = orientation
        self.mode = mode
        self.children = children
        self.ratios = children.map { _ in 1 / Double(children.count) }
    }

    /// The active child index, clamped to the children (removing the last child can leave `active` past the end).
    public var activeIndex: Int { min(active, max(children.count - 1, 0)) }

    /// Insert a child at `index`; it gets 1/(n+1) and the others shrink proportionally.
    mutating func insert(_ node: Node, at index: Int) {
        let n = Double(children.count)
        ratios = ratios.map { $0 * n / (n + 1) }
        ratios.insert(1 / (n + 1), at: index)
        children.insert(node, at: index)
        if index <= active && children.count > 1 { active += 1 }
    }

    /// Remove the child at `index`, giving its share to the others proportionally.
    mutating func remove(at index: Int) {
        let share = ratios.remove(at: index)
        children.remove(at: index)
        let rest = 1 - share
        ratios = rest > 0 ? ratios.map { $0 / rest } : ratios.map { _ in 1 / Double(ratios.count) }
        if index < active { active -= 1 }
    }

    /// Replace the child at `index`, keeping its ratio.
    mutating func replace(at index: Int, with node: Node) {
        children[index] = node
    }

    /// Set all ratios at once. Callers keep them summing to 1.
    mutating func setRatios(_ new: [Double]) {
        precondition(new.count == children.count)
        ratios = new
    }

    /// Equal ratios here and in every container below.
    mutating func balance() {
        ratios = children.map { _ in 1 / Double(children.count) }
        for i in children.indices {
            if case .container(var c) = children[i] {
                c.balance()
                children[i] = .container(c)
            }
        }
    }

    /// Path (child indices from this container) to a window, if present.
    func path(of id: WindowID) -> [Int]? {
        for (i, child) in children.enumerated() {
            switch child {
            case .window(let w) where w == id: return [i]
            case .container(let c): if let p = c.path(of: id) { return [i] + p }
            default: continue
            }
        }
        return nil
    }

    /// The window reached by following active children down, nil if there are no windows.
    var mostRecentWindow: WindowID? {
        guard !children.isEmpty else { return nil }
        switch children[activeIndex] {
        case .window(let id): return id
        case .container(let c): return c.mostRecentWindow
        }
    }

    /// The node at a non-empty path.
    func node(at path: [Int]) -> Node {
        let child = children[path[0]]
        guard path.count > 1, case .container(let c) = child else { return child }
        return c.node(at: Array(path.dropFirst()))
    }

    /// The container at `path` (empty path is self).
    func container(at path: [Int]) -> Container {
        guard !path.isEmpty, case .container(let c) = node(at: path) else { return self }
        return c
    }

    /// Run `body` on the container at `path` (empty path is self).
    @discardableResult
    mutating func modify<T>(at path: [Int], _ body: (inout Container) -> T) -> T {
        guard let first = path.first else { return body(&self) }
        guard case .container(var c) = children[first] else { preconditionFailure("path does not lead to a container") }
        let result = c.modify(at: Array(path.dropFirst()), body)
        children[first] = .container(c)
        return result
    }

    /// Collapse redundant structure bottom-up without changing geometry: drop empty containers,
    /// replace single-child containers with their child, splice children of same-orientation, same-mode containers.
    /// `auto` containers are not spliced: their axis depends on their own rectangle.
    mutating func normalize() {
        var newChildren: [Node] = [], newRatios: [Double] = [], newActive = 0
        for (i, child) in children.enumerated() {
            if i == activeIndex { newActive = newChildren.count }
            var node = child
            if case .container(var c) = node {
                c.normalize()
                node = c.children.count == 1 ? c.children[0] : .container(c)
            }
            switch node {
            case .container(let c) where c.children.isEmpty:
                continue
            case .container(let c) where c.orientation == orientation && orientation != .auto && c.mode == mode:
                if i == activeIndex { newActive += c.activeIndex }
                newChildren += c.children
                newRatios += c.ratios.map { $0 * ratios[i] }
            default:
                newChildren.append(node)
                newRatios.append(ratios[i])
            }
        }
        let total = newRatios.reduce(0, +)
        children = newChildren
        ratios = newRatios.map { $0 / total }
        active = newActive
    }
}
