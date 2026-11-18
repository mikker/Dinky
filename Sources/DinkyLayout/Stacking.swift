import CoreGraphics

extension Layout {
    /// Windows to raise, back to front, so overlapping windows (accordion, fullscreen) stack as `order` says
    /// wherever that shows. `current` is the on-screen order, front to back. Empty when it already agrees;
    /// plain tiles never overlap.
    ///
    /// Each raise briefly puts that window on top, and makes it its app's key window, before the ones meant to
    /// be in front of it are raised again: a visible flash. So raising is kept to the fewest windows from the
    /// front, only the order of two windows whose overlap shows somewhere counts (where windows above both
    /// cover it, either may be on top). Once every foreground window is above its overlapping neighbours,
    /// nothing is raised just to fix which background window peeks out at an edge. Disjoint tiles can each be
    /// foreground; in an accordion only its front window is. Switching accordion focus normally raises nothing.
    public func raises(current: [WindowID]) -> [WindowID] {
        let stack = order.filter { id in
            frames.keys.contains { $0 != id && overlaps($0, id) }
        }
        // A window is foreground only if no earlier window in the desired order overlaps it.
        let foreground = stack.indices.filter { i in
            !stack[..<i].contains { overlaps($0, stack[i]) }
        }
        if foreground.allSatisfy({ i in
            current.first { stack.contains($0) && overlaps($0, stack[i]) } == stack[i]
        }) { return [] }
        let position = Dictionary(current.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        // Raising the first `n` of the stack, back to front, puts them on top in order; the rest keep their
        // current order, which must already be right. With n = stack.count there is no rest, so one n fits.
        let n = (0...stack.count).first { n in
            let rest = n..<stack.count
            return rest.allSatisfy { i in
                rest.allSatisfy { j in
                    guard i < j, showsOrder(stack, i, j) else { return true }
                    guard let above = position[stack[i]], let below = position[stack[j]] else { return false }
                    return above < below
                }
            }
        }!
        return Array(stack.prefix(n).reversed())
    }

    private func overlaps(_ a: WindowID, _ b: WindowID) -> Bool {
        !frames[a]!.intersection(frames[b]!).isEmpty
    }

    /// Whether it shows which of `stack[i]` and `stack[j]` (i < j) is on top: part of their overlap is not
    /// covered by the windows meant to be above both.
    private func showsOrder(_ stack: [WindowID], _ i: Int, _ j: Int) -> Bool {
        let shared = frames[stack[i]]!.intersection(frames[stack[j]]!)
        guard !shared.isEmpty else { return false }
        let above = stack[..<i].map { frames[$0]! }
        return !above.reduce([shared]) { rest, cover in rest.flatMap { $0.subtracting(cover) } }.isEmpty
    }
}

extension CGRect {
    /// The parts of this rect outside `other`, as up to four rects.
    func subtracting(_ other: CGRect) -> [CGRect] {
        let cut = intersection(other)
        guard !cut.isEmpty else { return [self] }
        var parts: [CGRect] = []
        if cut.minY > minY { parts.append(CGRect(x: minX, y: minY, width: width, height: cut.minY - minY)) }
        if cut.maxY < maxY { parts.append(CGRect(x: minX, y: cut.maxY, width: width, height: maxY - cut.maxY)) }
        if cut.minX > minX { parts.append(CGRect(x: minX, y: cut.minY, width: cut.minX - minX, height: cut.height)) }
        if cut.maxX < maxX { parts.append(CGRect(x: cut.maxX, y: cut.minY, width: maxX - cut.maxX, height: cut.height)) }
        return parts
    }
}
