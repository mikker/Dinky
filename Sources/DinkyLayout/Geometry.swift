import CoreGraphics

/// Gaps in points: `horizontal` between side-by-side siblings, `vertical` between stacked ones,
/// the rest at the workspace edge.
public struct Gaps: Equatable, Sendable {
    public var horizontal: CGFloat
    public var vertical: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat
    public var left: CGFloat
    public var right: CGFloat

    /// No gaps at all.
    public static let zero = Gaps(all: 0)

    public init(horizontal: CGFloat, vertical: CGFloat, top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) {
        self.horizontal = horizontal
        self.vertical = vertical
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    /// The same gap everywhere.
    public init(all: CGFloat) {
        self.init(horizontal: all, vertical: all, top: all, bottom: all, left: all, right: all)
    }

    /// The gap between siblings of a container running along `axis`.
    public func inner(_ axis: Orientation) -> CGFloat { axis == .horizontal ? horizontal : vertical }

    /// `rect` shrunk by the outer gaps. Rects are top-left origin, as AX uses.
    public func inset(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + left, y: rect.minY + top,
               width: rect.width - left - right, height: rect.height - top - bottom)
    }
}

/// The result of a layout pass.
public struct Layout: Equatable, Sendable {
    /// Frame per window, top-left origin.
    public var frames: [WindowID: CGRect] = [:]
    /// Windows front to back: the first should be frontmost.
    public var order: [WindowID] = []
    /// The rectangle each container was laid out in, by its path from the root. Empty containers included.
    var containerRects: [[Int]: CGRect] = [:]
    var containerAxes: [[Int]: Orientation] = [:]

    public init(frames: [WindowID: CGRect] = [:], order: [WindowID] = []) {
        self.frames = frames
        self.order = order
    }

    /// Equal when windows get the same frames in the same order; container rects follow from those.
    public static func == (a: Layout, b: Layout) -> Bool { a.frames == b.frames && a.order == b.order }
}

extension Container {
    /// The axis children run along in `rect`: the set orientation, or for `auto` the longer side (a square is horizontal).
    public func axis(in rect: CGRect) -> Orientation {
        switch orientation {
        case .horizontal: .horizontal
        case .vertical: .vertical
        case .auto: rect.width >= rect.height ? .horizontal : .vertical
        }
    }

    /// Lay out this container in `rect`: tiles split by ratios with the inner gap for its axis between siblings,
    /// accordion children overlap with neighbours peeking out by `padding`. `virtual` lays accordions out as tiles.
    /// `minimums` are sizes windows refused to go below; tiles grow to them when their siblings can give the space.
    /// Records `rect` as the rect of the container at `path`.
    func layout(in rect: CGRect, gaps: Gaps, padding: CGFloat, minimums: [WindowID: CGSize] = [:],
                virtual: Bool = false, path: [Int] = [], into result: inout Layout) {
        result.containerRects[path] = rect
        let tiled = mode == .tiles || virtual, axis = axis(in: rect), gap = gaps.inner(axis)
        result.containerAxes[path] = axis
        let rects = tiled
            ? tileRects(in: rect, gap: gap, minimums: children.map { $0.minimumExtent(axis, gap: gap, padding: padding, minimums) })
            : accordionRects(in: rect, padding: padding)
        for i in stackingOrder {
            switch children[i] {
            case .window(let id):
                result.frames[id] = rects[i]
                result.order.append(id)
            case .container(let c):
                c.layout(in: rects[i], gaps: gaps, padding: padding, minimums: minimums, virtual: virtual,
                         path: path + [i], into: &result)
            }
        }
    }

    /// Child indices front to back: the active child, then by distance from it, lower index first on ties.
    var stackingOrder: [Int] {
        children.indices.sorted { (abs($0 - activeIndex), $0) < (abs($1 - activeIndex), $1) }
    }

    /// Split `rect` along the orientation by ratios, `gap` between children, edges rounded to whole points.
    /// Children below their `minimums` extent are grown to it, taken from the others, when everyone fits.
    func tileRects(in rect: CGRect, gap: CGFloat, minimums: [CGFloat] = []) -> [CGRect] {
        let horizontal = axis(in: rect) == .horizontal
        let origin = horizontal ? rect.minX : rect.minY
        let extent = horizontal ? rect.width : rect.height
        let available = extent - gap * CGFloat(max(children.count - 1, 0))
        let sizes = fit(ratios.map { available * CGFloat($0) }, minimums: minimums, total: available)
        var start = origin
        return sizes.map { size in
            let end = start + size
            let (a, b) = (start.rounded(), end.rounded())
            start = end + gap
            return horizontal
                ? CGRect(x: a, y: rect.minY, width: b - a, height: rect.height)
                : CGRect(x: rect.minX, y: a, width: rect.width, height: b - a)
        }
    }

    /// Accordion rects: each child gets `rect` shrunk along the axis so neighbours of the active child peek out.
    /// Adapted from AeroSpace's layoutAccordion (MIT, github.com/nikitabobko/AeroSpace).
    func accordionRects(in rect: CGRect, padding p: CGFloat) -> [CGRect] {
        let last = children.count - 1, active = activeIndex, horizontal = axis(in: rect) == .horizontal
        return children.indices.map { i in
            let (lead, trail): (CGFloat, CGFloat) = switch i {
            case 0 where last == 0: (0, 0)
            case 0: (0, p)
            case last: (p, 0)
            case active - 1: (0, 2 * p)
            case active + 1: (2 * p, 0)
            default: (p, p)
            }
            return horizontal
                ? CGRect(x: rect.minX + lead, y: rect.minY, width: rect.width - lead - trail, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY + lead, width: rect.width, height: rect.height - lead - trail)
        }
    }
}

/// `sizes` with every entry raised to its minimum, the difference taken from the others in proportion to
/// their size. Unchanged when the minimums do not all fit in `total`.
func fit(_ sizes: [CGFloat], minimums: [CGFloat], total: CGFloat) -> [CGFloat] {
    guard minimums.count == sizes.count, minimums.reduce(0, +) <= total else { return sizes }
    var pinned = Set<Int>()
    var result = sizes
    while let short = result.indices.first(where: { !pinned.contains($0) && result[$0] < minimums[$0] - 0.5 }) {
        pinned.insert(short)
        let free = sizes.indices.filter { !pinned.contains($0) }
        let left = total - pinned.map { minimums[$0] }.reduce(0, +)
        let weight = free.map { sizes[$0] }.reduce(0, +)
        for i in pinned { result[i] = minimums[i] }
        for i in free { result[i] = weight > 0 ? left * sizes[i] / weight : left / CGFloat(free.count) }
    }
    return result
}

extension Node {
    /// The smallest extent along `axis` this subtree can take without a window going below its minimum.
    /// An `auto` container counts as running across `axis`: a tile's longer side is usually across its parent's axis.
    func minimumExtent(_ axis: Orientation, gap: CGFloat, padding: CGFloat, _ minimums: [WindowID: CGSize]) -> CGFloat {
        switch self {
        case .window(let id):
            guard let size = minimums[id] else { return 0 }
            return axis == .horizontal ? size.width : size.height
        case .container(let c):
            let each = c.children.map { $0.minimumExtent(axis, gap: gap, padding: padding, minimums) }
            guard c.orientation == ContainerOrientation(axis), !each.isEmpty else { return each.max() ?? 0 }
            return c.mode == .tiles
                ? each.reduce(0, +) + gap * CGFloat(each.count - 1)
                : each.max()! + padding * CGFloat(min(each.count - 1, 2))
        }
    }
}
