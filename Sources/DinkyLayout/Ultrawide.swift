import CoreGraphics

public enum TilingAlignment: Sendable {
    case left, center, right
}

extension Workspace {
    var limitsAspectRatio: Bool {
        guard case .dwindle = algorithm else { return false }
        return windowMaxAspectRatio.isFinite && windowMaxAspectRatio > 0
            && displayAspectRatio >= ultrawideMinAspectRatio && !windows.isEmpty
    }

    /// Resolve auto orientations before narrowing the area, so searching for a width cannot flip a
    /// container's axis halfway through. The stored tree and its ratios remain unchanged.
    func tilingTree() -> Container {
        guard limitsAspectRatio else { return root }
        var full = Layout()
        root.layout(in: gaps.inset(bounds), gaps: gaps, padding: accordionPadding, minimums: minimumSizes, into: &full)
        func resolved(_ container: Container, at path: [Int]) -> Container {
            var copy = container
            if let rect = full.containerRects[path] { copy.orientation = ContainerOrientation(container.axis(in: rect)) }
            for i in copy.children.indices {
                if case .container(let child) = copy.children[i] {
                    copy.replace(at: i, with: .container(resolved(child, at: path + [i])))
                }
            }
            return copy
        }
        return resolved(root, at: [])
    }

    func tilingBounds(for tree: Container) -> CGRect {
        let available = gaps.inset(bounds)
        guard limitsAspectRatio, available.width > 0, available.height > 0 else { return available }
        func aligned(_ width: CGFloat) -> CGRect {
            let width = min(available.width, max(0, width))
            let offset: CGFloat = switch tilingAlignment {
            case .left: 0
            case .center: (available.width - width) / 2
            case .right: available.width - width
            }
            return CGRect(x: available.minX + offset, y: available.minY, width: width, height: available.height)
        }
        if let manualTilingWidth { return aligned(manualTilingWidth) }

        // Keep the width above the tree's structural gaps and known minimum widths. Minimums take
        // priority when they make the requested aspect ratio impossible without changing the tree.
        func minimumWidth(_ node: Node) -> CGFloat {
            switch node {
            case .window(let id): return max(0, minimumSizes[id]?.width ?? 0)
            case .container(let c):
                let widths = c.children.map(minimumWidth)
                guard !widths.isEmpty else { return 0 }
                if c.orientation != .horizontal { return widths.max()! }
                return c.mode == .tiles
                    ? widths.reduce(0, +) + gaps.horizontal * CGFloat(widths.count - 1)
                    : widths.max()! + accordionPadding * CGFloat(min(widths.count - 1, 2))
            }
        }
        func fits(_ width: CGFloat) -> Bool {
            var layout = Layout()
            tree.layout(in: aligned(width), gaps: gaps, padding: accordionPadding, minimums: minimumSizes, into: &layout)
            return layout.frames.allSatisfy { id, frame in
                frame.height > 0 && frame.width <= max(windowMaxAspectRatio * frame.height,
                                                       minimumSizes[id]?.width ?? 0) + 1
            }
        }
        if fits(available.width) { return available }
        var low = min(available.width, max(1, minimumWidth(.container(tree))))
        var high = available.width
        // With axes fixed, tile widths are monotonic. Find the widest fitting area to quarter-point
        // precision; rounding of individual tile edges is allowed one point above the ratio.
        while high - low > 0.25 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        return aligned(low)
    }

    /// A height-changing gesture on a lone constrained tile leaves tiling, preserving the user's frame.
    public func limitsManualHeightResize(of id: WindowID) -> Bool {
        limitsAspectRatio && fullscreen == nil && windows == [id]
    }

    /// Start a manual resize from the current area. The automatic cap stays suspended until tiled
    /// membership changes. Width-only resizing of a lone tile also changes the area's width.
    mutating func resizeTilingArea(_ id: WindowID, to width: CGFloat) -> Bool {
        guard limitsAspectRatio, fullscreen == nil, width.isFinite, width > 0, contains(id) else { return false }
        let area = tilingBounds(for: tilingTree())
        if windows.count == 1 {
            let new = min(gaps.inset(bounds).width, max(width, minimumSizes[id]?.width ?? 0))
            guard abs(new - area.width) >= 0.5 else { return false }
            manualTilingWidth = new
            return true
        }
        manualTilingWidth = area.width
        return false
    }
}
